#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Satoshi Coffee Co. — see LICENSE.
#
# utxoracle-serve.py — local HTTP price oracle backed by UTXOracle.
#
# Bound to 127.0.0.1 only. Refuses non-loopback connections at the handler
# level too. Recomputes the UTXOracle Block Window Price when a new
# confirmed block arrives (license Section 2.9 — Consensus-Compatible Use).
# Caches historical UTXOracle Consensus Prices by date in memory.
#
# Endpoints (all GET):
#   /                                 — status page (HTML)
#   /api/v3/simple/price?ids=bitcoin&vs_currencies=usd
#                                     — CoinGecko-shape JSON
#   /v2/prices/BTC-USD/spot           — Coinbase-shape JSON
#   /price                            — native shape, latest Block Window Price
#   /price?date=YYYY-MM-DD            — native shape, UTXOracle Consensus Price for that date
#   /healthz                          — liveness probe ({"ok": true})
#
# License compliance:
#   - All price-bearing JSON responses include _meta.source naming the
#     output canonically ("UTXOracle Block Window Price" / "UTXOracle
#     Consensus Price") per UTXOracle License Section 2.4.
#   - Status page surfaces canonical labels and the YouTube live-stream link
#     per Section 2.7.
#   - Server only refreshes on new confirmed-block height changes — never
#     sub-block or mempool — per Section 4 prohibition on live/real-time use.
#   - Loopback-only binding ensures this is not a "public-facing service."

import http.server
import socketserver
import json
import os
import sys
import subprocess
import threading
import time
import signal
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# --- Configuration ----------------------------------------------------------

HOST = "127.0.0.1"
DEFAULT_PORT = 17601   # adjacent to BoT's bitcoind RPC port (17600)

DOTFILES = Path(os.environ.get(
    "DOTFILES",
    "/live/persistence/TailsData_unlocked/dotfiles",
))
DATA_DIR = Path(os.environ.get(
    "DATA_DIR",
    "/live/persistence/TailsData_unlocked/Persistent/.bitcoin",
))

UTXO_DIR = DOTFILES / ".local/share/bot/utxoracle"
UTXO_PY = UTXO_DIR / "UTXOracle.py"
OUTPUT_DIR = UTXO_DIR / "output"

STATE_DIR = DOTFILES / ".local/state/bot"
LOG_FILE = STATE_DIR / "utxoracle-serve.log"
PID_FILE_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
PID_FILE = PID_FILE_DIR / "utxoracle-serve.pid"

# Constants used in JSON _meta and the status page
LICENSE_NOTE = (
    "Powered by UTXOracle (https://utxo.live), used under UTXOracle License "
    "v1.0 — Consensus-Compatible Use. Local-only, non-commercial, "
    "no live/sub-block updates."
)
YOUTUBE_LINK = "https://www.youtube.com/channel/UCXN7Xa_BF7dqLErzOmS-B7Q/live"

# --- Cache state ------------------------------------------------------------

_cache = {
    "block_window": None,   # dict or None
    "by_date": {},          # date_str -> dict
    "last_error": None,
}
_cache_lock = threading.Lock()


# --- Helpers ----------------------------------------------------------------

def log(msg):
    """Append a line to the log file and stderr."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    line = "[{ts}] {msg}\n".format(
        ts=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        msg=msg,
    )
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except OSError:
        pass
    sys.stderr.write(line)
    sys.stderr.flush()


def get_block_count():
    """Return current block height via bitcoin-cli. Raises on failure."""
    result = subprocess.run(
        ["bitcoin-cli", "-datadir={}".format(DATA_DIR), "getblockcount"],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "bitcoin-cli getblockcount failed: " + (result.stderr.strip() or "<no stderr>")
        )
    return int(result.stdout.strip())


def run_utxoracle(args):
    """Invoke UTXOracle.py with the given args. Returns the parsed price (int) or None."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    cmd = ["python3", str(UTXO_PY), "-p", str(DATA_DIR)] + list(args)
    result = subprocess.run(
        cmd, capture_output=True, text=True, timeout=900, cwd=str(OUTPUT_DIR),
    )
    raw = result.stdout
    price = None
    for line in raw.splitlines():
        if "price:" in line and "$" in line:
            try:
                amt = line.split("$")[-1]
                amt = amt.replace(",", "").strip().split()[0]
                price = int(amt)
                break
            except (ValueError, IndexError):
                continue
    return price, raw, result.returncode


def update_block_window(force=False):
    """Recompute the UTXOracle Block Window Price from the last 144 confirmed blocks."""
    log("Computing UTXOracle Block Window Price (last 144 confirmed blocks)...")
    try:
        height = get_block_count()
    except Exception as e:
        with _cache_lock:
            _cache["last_error"] = "getblockcount: " + str(e)
        log("Cannot reach bitcoind: " + str(e))
        return False

    price, raw, rc = run_utxoracle(["-rb"])
    if price is None:
        with _cache_lock:
            _cache["last_error"] = "UTXOracle returned no parseable price (rc={})".format(rc)
        log("UTXOracle did not produce a parseable price (rc={})".format(rc))
        return False

    with _cache_lock:
        _cache["block_window"] = {
            "label": "UTXOracle Block Window Price",
            "description": "USD price derived from the most recent 144 confirmed blocks.",
            "price_usd": price,
            "last_block_height": height,
            "computed_at_unix": int(time.time()),
            "computed_at_iso": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        _cache["last_error"] = None
    log("Block Window Price: ${} at height {}".format(price, height))
    return True


def get_historical(date_str):
    """Look up UTXOracle Consensus Price for a YYYY-MM-DD date. Cached after first hit."""
    with _cache_lock:
        if date_str in _cache["by_date"]:
            return _cache["by_date"][date_str]

    # Validate format
    try:
        datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        return None

    utxo_date = date_str.replace("-", "/")
    log("Computing UTXOracle Consensus Price for {}...".format(date_str))
    price, raw, rc = run_utxoracle(["-d", utxo_date])
    if price is None:
        log("No price for {} (rc={})".format(date_str, rc))
        return None

    entry = {
        "label": "UTXOracle Consensus Price",
        "description": "24-hour daily average for {} from confirmed blocks.".format(date_str),
        "date": date_str,
        "price_usd": price,
        "computed_at_unix": int(time.time()),
        "computed_at_iso": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    with _cache_lock:
        _cache["by_date"][date_str] = entry
    return entry


# --- Block watcher thread ---------------------------------------------------

def block_watcher():
    """Recompute the Block Window Price whenever the chain tip advances."""
    last_height = -1
    while True:
        try:
            height = get_block_count()
            if height != last_height:
                if last_height != -1:
                    log("New block detected: {} (was {})".format(height, last_height))
                if update_block_window():
                    last_height = height
        except Exception as e:
            log("block_watcher: " + str(e))
        time.sleep(30)   # 30 s poll — well within once-per-block license bound


# --- HTTP handler -----------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):

    server_version = "utxoracle-serve/0.9"

    def do_GET(self):
        # Paranoid: refuse non-loopback even though we're bound to 127.0.0.1.
        if self.client_address[0] != "127.0.0.1":
            self.send_error(403, "Loopback only")
            return

        url = urlparse(self.path)
        path = url.path
        query = parse_qs(url.query)

        try:
            if path in ("/", "/index.html"):
                self.serve_status()
            elif path == "/api/v3/simple/price":
                self.serve_coingecko(query)
            elif path == "/v2/prices/BTC-USD/spot":
                self.serve_coinbase()
            elif path == "/price":
                self.serve_native(query)
            elif path == "/healthz":
                self.serve_json({"ok": True}, 200)
            else:
                self.send_error(404, "Unknown endpoint")
        except Exception as e:
            log("Handler exception on {}: {}".format(path, e))
            self.send_error(500, "Internal error")

    def log_message(self, fmt, *args):
        # Route Python's stdlib logger through our log() so we get one stream.
        log("HTTP: {} - {}".format(self.client_address[0], fmt % args))

    # --- response helpers ---

    def _attach_meta(self, payload):
        payload.setdefault("_meta", {})
        payload["_meta"]["license"] = LICENSE_NOTE
        payload["_meta"]["live_stream"] = YOUTUBE_LINK
        return payload

    def serve_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # --- endpoint handlers ---

    def serve_coingecko(self, query):
        ids = query.get("ids", [""])[0].lower()
        vs = query.get("vs_currencies", ["usd"])[0].lower()
        with _cache_lock:
            bw = _cache["block_window"]
        if not bw:
            self.send_error(503, "Price not yet computed — try again in a moment")
            return

        if "bitcoin" not in ids.split(","):
            self.serve_json(self._attach_meta({}))
            return

        out = {"bitcoin": {}}
        for currency in vs.split(","):
            if currency == "usd":
                out["bitcoin"]["usd"] = bw["price_usd"]
        out["_meta"] = {
            "source": bw["label"],
            "block_height": bw["last_block_height"],
            "computed_at": bw["computed_at_iso"],
        }
        self._attach_meta(out)
        self.serve_json(out)

    def serve_coinbase(self):
        with _cache_lock:
            bw = _cache["block_window"]
        if not bw:
            self.send_error(503, "Price not yet computed — try again in a moment")
            return
        out = {
            "data": {
                "base": "BTC",
                "currency": "USD",
                "amount": "{:.2f}".format(float(bw["price_usd"])),
            },
            "_meta": {
                "source": bw["label"],
                "block_height": bw["last_block_height"],
                "computed_at": bw["computed_at_iso"],
            },
        }
        self._attach_meta(out)
        self.serve_json(out)

    def serve_native(self, query):
        date_str = query.get("date", [None])[0]
        if date_str:
            entry = get_historical(date_str)
            if not entry:
                self.send_error(404, "No UTXOracle Consensus Price available for that date")
                return
            self._attach_meta(entry)
            self.serve_json(entry)
            return
        with _cache_lock:
            bw = _cache["block_window"]
        if not bw:
            self.send_error(503, "Price not yet computed — try again in a moment")
            return
        payload = dict(bw)
        self._attach_meta(payload)
        self.serve_json(payload)

    def serve_status(self):
        with _cache_lock:
            bw = _cache["block_window"]
            err = _cache["last_error"]
            historical_count = len(_cache["by_date"])

        if bw:
            price_block = (
                '<p><span class="canonical">{label}:</span> '
                '<strong>${price:,}</strong><br>'
                'Last computed: {iso}<br>'
                'Block height: {h}</p>'
            ).format(
                label=bw["label"], price=bw["price_usd"],
                iso=bw["computed_at_iso"], h=bw["last_block_height"],
            )
        else:
            price_block = "<p>(no price computed yet — wait for the first block-watcher cycle)</p>"

        err_block = ""
        if err:
            err_block = '<p style="color:#ff6666">Last error: <code>{}</code></p>'.format(err)

        body = """<!DOCTYPE html>
<html>
<head>
<title>utxoracle-serve — Bitcoin on Tails</title>
<meta charset="utf-8">
<style>
 body {{ background:#0a0a0a; color:#dddddd; font-family:monospace;
        padding:30px; max-width:760px; margin:auto; line-height:1.5; }}
 h1 {{ color:cyan; margin-bottom:0.2em; }}
 h2 {{ color:lime; margin-top:30px; }}
 code, pre {{ background:#1a1a1a; padding:2px 6px; border-radius:3px;
              color:#dddddd; }}
 pre {{ padding:12px; overflow-x:auto; white-space:pre; }}
 .canonical {{ color:lime; font-weight:bold; }}
 a {{ color:cyan; }}
 .note {{ color:#888; font-size:13px; }}
</style>
</head>
<body>

<h1>utxoracle-serve</h1>
<p class="note">Local Bitcoin price oracle, derived from your own node's
transaction data via <a href="https://utxo.live">UTXOracle</a>.
Bound to <code>127.0.0.1</code> only.
Updates once per confirmed block (no live or sub-block data).</p>

<h2>Current price</h2>
{price_block}{err_block}
<p class="note">Historical lookups cached this session: {hist}</p>

<h2>Endpoints</h2>
<pre>GET /api/v3/simple/price?ids=bitcoin&amp;vs_currencies=usd   (CoinGecko-shape)
GET /v2/prices/BTC-USD/spot                                (Coinbase-shape)
GET /price                                                  (native, latest Block Window Price)
GET /price?date=YYYY-MM-DD                                  (native, UTXOracle Consensus Price for that date)
GET /healthz                                                (liveness)
GET /                                                       (this page)</pre>

<h2>Use with Sparrow Wallet</h2>
<p>Sparrow Wallet does not currently support custom price-source URLs in
its stable releases. This server is here as a foundation: any tool that
takes a custom URL can use it today, and we are filing a feature request
upstream with Sparrow to add a Custom URL exchange source.</p>
<p>Until that lands, your Sparrow currency setting is best left at
<strong>None</strong> (strict privacy) or one of its built-in sources
(reaches out over Tor).</p>

<h2>License</h2>
<p>Outputs labeled here as <span class="canonical">UTXOracle Block Window Price</span>
(latest 144 confirmed blocks) and <span class="canonical">UTXOracle Consensus Price</span>
(24-hour daily average) are computed using the unmodified UTXOracle algorithm
per the UTXOracle License v1.0.</p>
<p class="note">{license}</p>
<p>Live stream:
<a href="{yt}" target="_blank" rel="noopener noreferrer">UTXOracle Live Stream on YouTube</a>
<span class="note">(external link — opens YouTube/Google in your browser if clicked)</span></p>

</body>
</html>
""".format(
            price_block=price_block, err_block=err_block,
            hist=historical_count, license=LICENSE_NOTE, yt=YOUTUBE_LINK,
        )
        body_bytes = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


# --- Process management -----------------------------------------------------

def write_pid():
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))


def remove_pid():
    try:
        if PID_FILE.exists():
            PID_FILE.unlink()
    except OSError:
        pass


def already_running():
    if not PID_FILE.exists():
        return None
    try:
        pid = int(PID_FILE.read_text().strip())
    except (ValueError, OSError):
        PID_FILE.unlink(missing_ok=True)
        return None
    try:
        os.kill(pid, 0)   # signal 0 = liveness check
        return pid
    except ProcessLookupError:
        PID_FILE.unlink(missing_ok=True)
        return None


# --- Main -------------------------------------------------------------------

def parse_args(argv):
    port = DEFAULT_PORT
    show_help = False
    args = list(argv[1:])
    while args:
        a = args.pop(0)
        if a in ("--help", "-h"):
            show_help = True
        elif a == "--port" and args:
            port = int(args.pop(0))
        else:
            print("Unknown argument: " + a, file=sys.stderr)
            show_help = True
    return port, show_help


def main(argv):
    port, show_help = parse_args(argv)
    if show_help:
        print(
            "Usage: utxoracle-serve.py [--port N]\n"
            "  --port N    Bind to 127.0.0.1:N (default {})\n"
            "  --help      Show this message".format(DEFAULT_PORT),
            file=sys.stderr,
        )
        return 0

    pid = already_running()
    if pid:
        print("utxoracle-serve already running (pid {})".format(pid), file=sys.stderr)
        return 2

    if not UTXO_PY.exists():
        print("UTXOracle.py missing at {}".format(UTXO_PY), file=sys.stderr)
        print("Re-run `b` to repair the BoT install.", file=sys.stderr)
        return 3

    write_pid()

    def handle_sig(signum, frame):
        log("Received signal {} — shutting down.".format(signum))
        remove_pid()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    log("utxoracle-serve starting on http://{}:{}".format(HOST, port))
    log("UTXOracle.py: {}".format(UTXO_PY))
    log("Bitcoin datadir: {}".format(DATA_DIR))

    # Kick off the block watcher in the background.
    watcher = threading.Thread(target=block_watcher, daemon=True)
    watcher.start()

    try:
        with socketserver.TCPServer((HOST, port), Handler) as httpd:
            httpd.serve_forever()
    except OSError as e:
        log("Could not bind {}:{} — {}".format(HOST, port, e))
        remove_pid()
        return 4
    finally:
        remove_pid()


if __name__ == "__main__":
    sys.exit(main(sys.argv) or 0)
