#!/bin/bash
#
# fetch-yad-deb.sh — bundle a verified yad .deb into the BoT release tree.
#
# Run this on a Tails OS amnesic session (or any Debian Bookworm system that
# matches Tails' base) before tagging a BoT release. It downloads yad and any
# dependencies that aren't already in the Tails base image, computes their
# SHA256 sums, and writes everything to ./debs/ in this repository.
#
# Why bundled .debs: the BoT control panel (bot-menu) requires yad, which is
# not installed in Tails by default. On a fresh first-run we want the install
# to work even when the user hasn't yet enabled "Additional Software"
# persistence over Tor. The bundled .deb path in persistent-setup picks these
# files up from $DOTFILES/.local/share/bot/debs/, verifies SHA256SUMS, and
# installs offline.
#
# The script is intentionally simple — it does not try to rebuild yad from
# source or pin to a specific upstream version. Whatever Debian Bookworm is
# currently shipping is what we bundle.
#
# Usage (from this repo's root):
#     tools/fetch-yad-deb.sh
#
# Output:
#     debs/yad_*.deb
#     debs/SHA256SUMS
###############################################################################

set -euo pipefail

# Locate repo root (parent of tools/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEBS_DIR="$REPO_ROOT/debs"

# Sanity check: we want to be on a Debian-derived system with apt-get download.
if ! command -v apt-get >/dev/null 2>&1; then
    echo "fetch-yad-deb.sh: apt-get not available — run this on Tails or Debian Bookworm." >&2
    exit 1
fi

if [ ! -f /etc/os-release ] || ! grep -qE 'NAME="?(Tails|Debian)' /etc/os-release; then
    echo "fetch-yad-deb.sh: /etc/os-release does not look like Tails/Debian — refusing to run." >&2
    echo "                  Bundle a .deb from a Tails session or matching Debian release." >&2
    exit 1
fi

mkdir -p "$DEBS_DIR"
cd "$DEBS_DIR"

# Wipe any previous bundle so SHA256SUMS only ever lists what we just fetched.
rm -f yad_*.deb SHA256SUMS

echo "fetch-yad-deb.sh: refreshing apt cache (over Tor, if Tails)..."
sudo apt-get update -q

echo "fetch-yad-deb.sh: downloading yad .deb..."
# apt-get download writes to the current directory and does not require root.
apt-get download yad

# Walk yad's runtime dependency list and pull anything not already installed
# on this system. Tails is a moving target — what was bundled in Tails 6.0
# may have been dropped by 6.5 — so we err on the side of including any dep
# that isn't currently present. This may include false positives (deps
# present on a normal Debian box but missing on Tails), which is fine: extra
# .debs cost some disk but apt is happy to skip already-installed packages.
deps="$(apt-cache depends yad 2>/dev/null \
    | awk '/Depends:/ {print $2}' \
    | grep -v '^<' \
    | sort -u)"
for dep in $deps; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        echo "fetch-yad-deb.sh: bundling missing dep: $dep"
        apt-get download "$dep" 2>/dev/null || \
            echo "fetch-yad-deb.sh: warn: could not download $dep (may be a virtual package)"
    fi
done

# Sanity: at least the yad .deb must be present.
if ! ls yad_*.deb >/dev/null 2>&1; then
    echo "fetch-yad-deb.sh: no yad_*.deb downloaded — aborting." >&2
    exit 1
fi

# Hash everything we just downloaded so persistent-setup can verify before install.
sha256sum *.deb > SHA256SUMS
chmod 0644 SHA256SUMS *.deb

echo
echo "fetch-yad-deb.sh: bundle ready in $DEBS_DIR:"
ls -lh
echo
echo "Verify with:"
echo "    cd $DEBS_DIR && sha256sum -c SHA256SUMS"
echo
echo "Then commit and push:"
echo "    git add debs/"
echo "    git commit -m 'Refresh bundled yad .deb for release'"
