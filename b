#!/bin/bash
# SPDX-License-Identifier: MIT
# Bitcoin on Tails — top-level installer / updater entry point. See LICENSE.

###############################################################################
# Sets environment variables, asks which Bitcoin implementation to install,
# and launches install-core or install-knots.
###############################################################################

export VERSION='v0.9.4-alpha'
export WAYLAND_DISPLAY="" # Needed for zenity dialogs to have window icon
export ICON="--icon=$HOME/.local/share/icons/bot128.png"
export DOTFILES='/live/persistence/TailsData_unlocked/dotfiles'
readonly SECURITY_IN_A_BOX_URL="https://securityinabox.org/en/"
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PATH hardening — runs BEFORE any dispatch, so every code path benefits.
#
# Why this matters: Tails' GNOME Console launches an interactive non-login
# shell, which does NOT source ~/.profile. The default Debian ~/.profile is
# what adds ~/.local/bin to PATH. So a freshly-opened Console window has
# neither `b` nor `install-core` / `install-knots` / `utxoracle` / etc. on
# PATH, even though all of them exist as symlinks under ~/.local/bin.
#
# The same issue bites .desktop launchers and any non-login shell. We work
# around it here so every BoT command "just works" no matter how b was
# invoked. We also source ~/.profile if it exists so anything else the user
# put in there (custom env, aliases-in-functions, etc.) is honored.
[ -f "$HOME/.profile" ] && . "$HOME/.profile" >/dev/null 2>&1 || true
for _bot_path in "$HOME/.local/bin" "$DOTFILES/.local/bin"; do
    [ -d "$_bot_path" ] || continue
    case ":$PATH:" in
        *":$_bot_path:"*) ;;
        *) export PATH="$_bot_path:$PATH" ;;
    esac
done
unset _bot_path

###############################################################################
# bot_raise_dialog TITLE
#
# Background helper that nudges a dialog with the given exact title to the
# foreground. Zenity inherits no "always-on-top" hint from GTK, so on Tails
# it sometimes opens behind the Persistent Storage app, the running terminal,
# or whatever else has focus. We poll for the window using wmctrl / xdotool
# (whichever is available — Tails ships xdotool by default) and activate it.
# Silently does nothing if neither tool is available.
###############################################################################
bot_raise_dialog() {
    local title="$1"
    [ -z "$title" ] && return 0
    (
        local i=0 wid=""
        while [ "$i" -lt 12 ]; do
            sleep 0.3
            if command -v wmctrl >/dev/null 2>&1; then
                wmctrl -F -a "$title" 2>/dev/null && break
            fi
            if command -v xdotool >/dev/null 2>&1; then
                wid=$(xdotool search --name "$title" 2>/dev/null | tail -1)
                if [ -n "$wid" ]; then
                    xdotool windowactivate "$wid" 2>/dev/null && break
                fi
            fi
            i=$((i+1))
        done
    ) >/dev/null 2>&1 &
}
export -f bot_raise_dialog

if [ "$1" == "--version" ]; then
  echo "Bitcoin on Tails version $VERSION"
  exit 0
elif [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
  cat <<EOF
Bitcoin on Tails $VERSION

Usage:
  b                  Install or update Bitcoin on Tails (interactive)
  b --status         Print a snapshot of what's installed (no network)
  b --check          Report installed + latest upstream versions (one network probe)
  b --update         Update the installed implementation to the latest patch
  b --uninstall      Uninstall the active implementation (with prompts)
  b --version        Print BoT version
  b --help           Show this message
EOF
  exit 0
elif [ "$1" == "--status" ]; then
  # Read-only status snapshot. No rsync, no install dialogs, no network.
  STATE_HOME="${XDG_STATE_HOME:-/live/persistence/TailsData_unlocked/dotfiles/.local/state}"
  CACHE_HOME="${XDG_CACHE_HOME:-/live/persistence/TailsData_unlocked/dotfiles/.cache}"
  marker="$STATE_HOME/bot/dist"
  echo "Bitcoin on Tails $VERSION"
  echo
  if [ -s "$marker" ]; then
      dist="$(head -1 "$marker" | tr -d '[:space:]')"
      case "$dist" in
          core)         echo "Implementation: Bitcoin Core"  ;;
          knots)        echo "Implementation: Bitcoin Knots" ;;
          knots-bip110) echo "Implementation: Bitcoin Knots + BIP-110 (signaling)" ;;
          *)            echo "Implementation: $dist (unknown marker value)" ;;
      esac
  elif command -v bitcoind >/dev/null 2>&1; then
      if bitcoind --version 2>/dev/null | grep -qi knots; then
          echo "Implementation: Bitcoin Knots (no marker — pre-marker install)"
      else
          echo "Implementation: Bitcoin Core (no marker — pre-marker install)"
      fi
  else
      echo "Implementation: not installed"
  fi
  if command -v bitcoind >/dev/null 2>&1; then
      echo "Bitcoin version: $(bitcoind --version 2>/dev/null | head -1 | awk '{print $NF}')"
      if bitcoin-cli -datadir="${DATA_DIR:-/live/persistence/TailsData_unlocked/Persistent/.bitcoin}" getblockchaininfo >/dev/null 2>&1; then
          echo "Daemon: running"
      else
          echo "Daemon: not running"
      fi
  fi
  if command -v Sparrow >/dev/null 2>&1 || [ -x "${DOTFILES:-/live/persistence/TailsData_unlocked/dotfiles}/.local/bin/Sparrow" ]; then
      echo "Sparrow: installed"
  else
      echo "Sparrow: not installed"
  fi
  for slug in core knots sparrow; do
      kv="$CACHE_HOME/bot/check-$slug.kv"
      [ -s "$kv" ] || continue
      iv=$(awk -F= '$1=="installed_version"{sub(/^[^=]*=/,""); print; exit}' "$kv")
      lv=$(awk -F= '$1=="latest_version"   {sub(/^[^=]*=/,""); print; exit}' "$kv")
      avail=$(awk -F= '$1=="update_available"{sub(/^[^=]*=/,""); print; exit}' "$kv")
      iso=$(awk -F= '$1=="last_check_iso" {sub(/^[^=]*=/,""); print; exit}' "$kv")
      [ -z "$lv" ] && continue
      printf 'Last %s check: %s — installed %s, latest %s%s\n' \
          "$slug" "$iso" "${iv:--}" "$lv" \
          "$( [ "$avail" = "true" ] && echo " (update available)")"
  done
  exit 0
elif [ "$1" == "--check" ] || [ "$1" == "--update" ] || [ "$1" == "--uninstall" ]; then
  # Lifecycle dispatch — route to whichever installer is active. The marker
  # file at $XDG_STATE_HOME/bot/dist is the source of truth; bitcoind --version
  # is a fallback for old installs predating the marker.
  STATE_HOME="${XDG_STATE_HOME:-/live/persistence/TailsData_unlocked/dotfiles/.local/state}"
  marker="$STATE_HOME/bot/dist"

  # PATH hardening: this branch may be reached from a context that didn't
  # source ~/.profile (e.g. the .desktop launcher, a non-login shell, the
  # initial Console session if Dotfiles haven't relinked yet). Without
  # ~/.local/bin / $DOTFILES/.local/bin on PATH, the `exec install-$dist`
  # call below fails with "command not found" even though the script exists
  # on disk. Same defensive prepend bot-menu does.
  for _bot_path in "$HOME/.local/bin" "$DOTFILES/.local/bin"; do
      [ -d "$_bot_path" ] || continue
      case ":$PATH:" in
          *":$_bot_path:"*) ;;
          *) export PATH="$_bot_path:$PATH" ;;
      esac
  done
  unset _bot_path

  dist=""
  if [ -s "$marker" ]; then
    dist="$(head -1 "$marker" | tr -d '[:space:]')"
  elif command -v bitcoind >/dev/null 2>&1; then
    if bitcoind --version 2>/dev/null | grep -qi knots; then
      dist="knots"
    else
      dist="core"
    fi
  fi
  case "$dist" in
    core|knots|knots-bip110)
      # Resolve the installer absolutely so a still-broken PATH gives a
      # clearer error than "command not found" if something else is wrong.
      installer="$(command -v "install-$dist" 2>/dev/null \
        || { [ -x "$DOTFILES/.local/bin/install-$dist" ] && echo "$DOTFILES/.local/bin/install-$dist"; })"

      # Self-heal: if the installer is missing from $DOTFILES but the
      # overlay snapshot in $INSTALLED_BOT_DIR still has it, rsync the
      # overlay back into $DOTFILES and re-link dotfiles. This recovers
      # from "files vanished from $DOTFILES somehow" without forcing the
      # user to re-clone. (Common cause: a partial rsync, manual `rm`, or
      # an interrupted earlier install.)
      if [ -z "$installer" ]; then
        installed_bot_dir="$DOTFILES/.local/share/bot"
        overlay_installer="$installed_bot_dir/overlay/.local/bin/install-$dist"
        if [ -x "$overlay_installer" ]; then
          echo "b: install-$dist missing from \$DOTFILES/.local/bin/. Restoring from $installed_bot_dir/overlay/ ..." >&2
          if rsync -rh "$installed_bot_dir/overlay/" "$DOTFILES/" 2>&1; then
              command -v link-dotfiles >/dev/null 2>&1 && link-dotfiles >/dev/null 2>&1 || true
              installer="$(command -v "install-$dist" 2>/dev/null \
                || { [ -x "$DOTFILES/.local/bin/install-$dist" ] && echo "$DOTFILES/.local/bin/install-$dist"; })"
              [ -n "$installer" ] && echo "b: restored. Continuing with --$1 ..." >&2
          fi
        fi
      fi

      if [ -z "$installer" ]; then
        echo "b: install-$dist not found on PATH or at \$DOTFILES/.local/bin/install-$dist." >&2
        echo "    PATH=$PATH" >&2
        echo "    DOTFILES=$DOTFILES" >&2
        echo "    The overlay snapshot at \$DOTFILES/.local/share/bot/overlay/ also appears to be missing this file." >&2
        echo "    To recover, run a fresh clone:" >&2
        echo "       git clone https://github.com/satscoffee/bitcoin-on-tails ~/bot && ~/bot/b" >&2
        echo "    and pick \"refresh\" when prompted (it won't redownload Bitcoin)." >&2
        exit 1
      fi
      exec "$installer" "$1"
      ;;
    *)
      echo "b: no Bitcoin implementation installed yet. Run \`b\` with no arguments to install one." >&2
      exit 1
      ;;
  esac
elif ! grep 'NAME="Tails"' /etc/os-release > /dev/null; then # Check for Tails OS.
    echo "
    YOU MUST RUN THIS SCRIPT IN TAILS OS!
    "
    read -rp "PRESS ENTER TO EXIT SCRIPT, AND RUN AGAIN FROM TAILS. "
elif [[ $(id -u) = "0" ]]; then # Check for root.
    echo "
  YOU SHOULD NOT RUN THIS SCRIPT AS ROOT!
  "
    read -rp "PRESS ENTER TO EXIT SCRIPT, AND RUN AGAIN AS $USER. "
else
  printf '\033]2;Welcome to Bitcoin on Tails!\a'

  # Detect re-run from the installed location. If $BOT_DIR is already inside
  # persistence (either directly, via the symlinked ~/.local/share/bot, or
  # anything readlink resolves into $DOTFILES), SKIP the self-install migration
  # — otherwise rsync would follow the dotfile symlinks back into $DOTFILES and
  # --remove-source-files would delete them in place, wiping the install.
  INSTALLED_BOT_DIR="$DOTFILES/.local/share/bot"
  BOT_DIR_REAL="$(readlink -f "$BOT_DIR" 2>/dev/null)"
  already_installed=0
  case "$BOT_DIR" in
      "$HOME/.local/share/bot"|"$INSTALLED_BOT_DIR") already_installed=1 ;;
  esac
  [ "$BOT_DIR_REAL" = "$INSTALLED_BOT_DIR" ] && already_installed=1
  # If b itself is a symlink pointing into $DOTFILES, this is an installed copy.
  if [ -L "$BOT_DIR/b" ]; then
      b_target="$(readlink -f "$BOT_DIR/b" 2>/dev/null)"
      [[ "$b_target" == "$DOTFILES/"* ]] && already_installed=1
  fi

  # Detect "BoT exists in Persistent Storage but I'm running b from somewhere
  # else" (e.g., a developer working tree at ~/bot). The signal is a real
  # install at $INSTALLED_BOT_DIR plus evidence that Bitcoin actually finished
  # installing — the dist marker, OR an actual bitcoind binary on disk. When
  # this fires we don't want to silently rerun the full first-install flow —
  # we offer a refresh path that just syncs the working tree's scripts into
  # Persistent Storage, no Bitcoin reinstall.
  #
  # Half-install detection: if BoT scripts are present in $INSTALLED_BOT_DIR
  # but there is no dist marker AND no bitcoind binary (e.g. the user Ctrl+C'd
  # mid-install), we deliberately do NOT set bot_already_setup. Instead we
  # fall through to the first-install branch below, which idempotently
  # refreshes the overlay and runs the install flow. This is what the user
  # almost certainly wanted — the previous run never finished.
  STATE_HOME_PROBE="${XDG_STATE_HOME:-$DOTFILES/.local/state}"
  bot_already_setup=0
  if ! ((already_installed)); then
      if [ -s "$STATE_HOME_PROBE/bot/dist" ]; then
          bot_already_setup=1
      elif [ -x "$INSTALLED_BOT_DIR/b" ]; then
          # Scripts are present, but did Bitcoin actually finish installing?
          if command -v bitcoind >/dev/null 2>&1 \
              || [ -x "$DOTFILES/.local/bin/bitcoind" ] \
              || [ -x "$DOTFILES/.local/bin/bitcoin-qt" ]; then
              bot_already_setup=1
          else
              # Half-installed: scripts copied, Bitcoin missing. Tell the user
              # what we're doing rather than silently dropping into the menu.
              echo "Bitcoin on Tails: detected a previous install that didn't finish (scripts present, bitcoind missing). Resuming install flow..." >&2
          fi
      fi
  fi

  if ((already_installed)); then
    # Already installed — just ensure persistence features are on, no migration.
    # shellcheck disable=SC1091
    . "$HOME/.profile"
    persistent-setup
  elif ((bot_already_setup)); then
    # Working-tree run on a stick that already has BoT installed. Don't force
    # a full reinstall — let the user pick what they actually wanted.
    bot_raise_dialog "Bitcoin on Tails is already installed"
    dev_choice=$(zenity --list --radiolist \
        --title="Bitcoin on Tails is already installed" \
        --text="<b>BoT is already set up in your Persistent Storage.</b>\n\nYou ran <tt>b</tt> from a working tree at:\n<tt>$BOT_DIR</tt>\n\nWhat would you like to do?" \
        --column="Pick" --column="Action" --column="Notes" \
        TRUE  "refresh"   "Sync new scripts only — no Bitcoin download" \
        FALSE "menu"      "Sync scripts, then open the BoT control panel" \
        FALSE "reinstall" "Run the full install flow again (re-downloads Bitcoin)" \
        --width=720 --height=320 \
        "$ICON" --icon=bitcoin128) || exit 0
    case "$dev_choice" in
      refresh|menu)
        # shellcheck disable=SC1091
        . "$HOME/.profile"
        # Make sure persistence is unlocked + Dotfiles feature active, otherwise
        # the rsync below silently writes to a non-persistent path.
        persistent-setup &
        until /usr/local/lib/tpscli is-unlocked && \
            /usr/local/lib/tpscli is-active Dotfiles && \
            [ -d "$DOTFILES" ] && [ -w "$DOTFILES" ]; do
            sleep 1
        done
        rsync -rvh "$BOT_DIR/overlay/" "$DOTFILES"
        rsync -rvh "$BOT_DIR"/ "$INSTALLED_BOT_DIR"
        link-dotfiles
        wait
        # Always confirm the refresh succeeded, then launch bot-menu so the
        # user sees their changes immediately. --width forces full text;
        # --ellipsize was previously truncating both lines mid-word.
        zenity --info --title="Scripts refreshed" \
            --width=560 \
            --text="BoT scripts have been synced into Persistent Storage at <b>$VERSION</b>.\n\nFrom any terminal you can now test:\n<tt>b --check</tt>, <tt>b --update</tt>, <tt>b --uninstall</tt>, or <tt>bot-menu</tt>.\n\nThe BoT control panel will open next." \
            "$ICON" --icon=bitcoin128
        exec bot-menu
        ;;
      reinstall)
        # Fall through to the standard first-install flow below.
        rsync -rvh "$BOT_DIR/overlay/" "$HOME"
        # shellcheck disable=SC1091
        . "$HOME/.profile"
        (
          persistent-setup &
          until /usr/local/lib/tpscli is-unlocked && \
            /usr/local/lib/tpscli is-active Dotfiles && \
            [ -d "$DOTFILES" ] && [ -w "$DOTFILES" ]; do
              sleep 1
          done
          rsync -rvh "$BOT_DIR/overlay/" "$DOTFILES"
          rsync -rvh "$BOT_DIR"/ "$INSTALLED_BOT_DIR"
          link-dotfiles
        ) &
        ;;
      *)
        exit 0
        ;;
    esac
  else
    # First-time install (running from a USB / Downloads extract).
    # Install Bitcoin on Tails to tmpfs
    rsync -rvh "$BOT_DIR/overlay/" "$HOME"
    # shellcheck disable=SC1091
    . "$HOME/.profile"
    (
      persistent-setup &
      until /usr/local/lib/tpscli is-unlocked && \
        /usr/local/lib/tpscli is-active Dotfiles && \
        [ -d "$DOTFILES" ] && [ -w "$DOTFILES" ]; do
          sleep 1
      done
      # Install Bitcoin on Tails to Persistent Storage. We deliberately do NOT
      # use --remove-source-files: keeping the source clone (including its .git/
      # directory) intact means the user can `git pull` from $INSTALLED_BOT_DIR
      # later for in-place updates. The source clone in $BOT_DIR remains in
      # tmpfs only until reboot.
      rsync -rvh "$BOT_DIR/overlay/" "$DOTFILES"
      rsync -rvh "$BOT_DIR"/ "$INSTALLED_BOT_DIR"
      link-dotfiles
    ) & # Run persistent setup in background
  fi
  if [ -z "$1" ]; then # Install/Update if ran without a parameter
    # Ask which Bitcoin implementation to install. No default — user must choose.
    # Three options presented as equals: Core, Knots, Knots+BIP-110.
    bot_raise_dialog "Choose a Bitcoin implementation"
    bitcoin_impl=$(zenity --list --radiolist \
        --title="Choose a Bitcoin implementation" \
        --text="<b>No default selected — please pick one.</b>\n\nAll three are full-node implementations of the Bitcoin protocol." \
        --column="Pick" --column="Implementation" --column="Notes" \
        FALSE "core"         "Bitcoin Core — reference implementation, multi-signer verification (3 signatures)" \
        FALSE "knots"        "Bitcoin Knots — Luke Dashjr's fork, single-signer verification" \
        FALSE "knots-bip110" "Bitcoin Knots + BIP-110 — non-mainline soft-fork build (chain-split risk if you don't know what this is)" \
        --width=820 --height=420 \
        "$ICON" --icon=bitcoin128) || {
          zenity --error --title="No implementation selected" --text="You must choose Bitcoin Core, Bitcoin Knots, or Bitcoin Knots + BIP-110 to continue." --ellipsize "$ICON"
          exit 1
        }
    case "$bitcoin_impl" in
      core)
        # shellcheck disable=SC1091
        . install-core
        ;;
      knots)
        # shellcheck disable=SC1091
        . install-knots
        ;;
      knots-bip110)
        # shellcheck disable=SC1091
        . install-knots-bip110
        ;;
      *)
        zenity --error --title="No implementation selected" --text="You must choose Bitcoin Core, Bitcoin Knots, or Bitcoin Knots + BIP-110 to continue." --ellipsize "$ICON"
        exit 1
        ;;
    esac
    wait
    # Display info about IBD, keeping Tails private and extra reading material
    zenity --info --title='Setup almost complete' --icon=bot128 "$ICON" --text='The Bitcoin blockchain has begun syncing automatically.\nMake sure no one messes with the PC.\n\nTo lock the screen for privacy, press ❖+L (⊞+L or ⌘+L)\n\nIt is safer to exit Bitcoin (Ctrl+Q), <a href="https://tails.net/doc/first_steps/shutdown/index.en.html">shutdown Tails</a> and take your Bitcoin on Tails USB stick with you or store it in a safe place than leave Tails running unattended where people you distrust could tamper with it.\n\nIf you want to learn more about using Tails safely read the <a href="https://tails.net/doc/index.en.html">documentation</a>.\n\nAnother excellent read to improve your physical and digital security tactics is the <a href="'"$SECURITY_IN_A_BOX_URL"'">Security in-a-Box</a> website.'
    # Offer Sparrow Wallet as an optional add-on. Sparrow connects to the local
    # Bitcoin Core/Knots node over localhost RPC for maximum privacy.
    if zenity --question \
        --title='Install Sparrow Wallet?' \
        --text='<b>Sparrow Wallet</b> is a Bitcoin wallet focused on security and privacy. It can connect to your Bitcoin node so your wallet queries never leak to third-party servers.\n\nInstall Sparrow Wallet now?\n\n(You can also install it later by opening a terminal and running <tt>install-sparrow</tt>.)' \
        --ok-label='Yes, install Sparrow' --cancel-label='Not now' \
        "$ICON" --icon=bitcoin128; then
        install-sparrow || zenity --warning --title="Sparrow install did not complete" \
            --text="Sparrow Wallet installation was cancelled or failed. You can retry later by running <tt>install-sparrow</tt> from a terminal." \
            --ellipsize "$ICON"
    fi
    zenity --info --title="Bitcoin on Tails install successful" --text="Bitcoin on Tails $VERSION has been installed." "$ICON" --icon=bot128
    # Exit by killing controlling terminal
    echo "Bitcoin on Tails installation complete! 

Closing this window in 30 seconds, press any key to abort.
"
for ((i = 30; i >= 1; i--)); do
    echo -n "$i "
    read -r -t 1 -n 1 && { printf '\n%s\n' "Aborted."; exit 0; }
done
    echo "
Closing terminal window..."
    sleep 3
    PARENT_PID=$(ps -o ppid= -p $$)
    kill -9 "$PARENT_PID"
  else
    zenity --info --title="Bitcoin on Tails update successful" --text="Bitcoin on Tails has been updated to $VERSION." "$ICON" --icon=bot128
  fi
  exit 0
fi
exit 1
