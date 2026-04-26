#!/bin/bash

# Copyright (c) 2023 Ben Westgate
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

###############################################################################
# Sets environment variable, asks which Bitcoin implementation to install, and launches install-core or install-knots
###############################################################################

export VERSION='v0.7.3-alpha'
export WAYLAND_DISPLAY="" # Needed for zenity dialogs to have window icon
export ICON="--window-icon=$HOME/.local/share/icons/bot128.png"
export DOTFILES='/live/persistence/TailsData_unlocked/dotfiles'
readonly SECURITY_IN_A_BOX_URL="https://securityinabox.org/en/"
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$1" == "--version" ]; then
  echo "Bitcoin on Tails version $VERSION"
  exit 0
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

  if ((already_installed)); then
    # Already installed — just ensure persistence features are on, no migration.
    # shellcheck disable=SC1091
    . "$HOME/.profile"
    persistent-setup
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
    bitcoin_impl=$(zenity --list --radiolist \
        --title="Choose a Bitcoin implementation" \
        --text="<b>No default selected — please pick one.</b>\n\nBoth are full-node implementations of the Bitcoin protocol." \
        --column="Pick" --column="Implementation" --column="Notes" \
        FALSE "core"  "Bitcoin Core — reference implementation, multi-signer verification (3 signatures)" \
        FALSE "knots" "Bitcoin Knots — Luke Dashjr's fork, single-signer verification" \
        --width=720 --height=380 \
        "$ICON" --icon-name=bitcoin128) || {
          zenity --error --title="No implementation selected" --text="You must choose Bitcoin Core or Bitcoin Knots to continue." --ellipsize "$ICON"
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
      *)
        zenity --error --title="No implementation selected" --text="You must choose Bitcoin Core or Bitcoin Knots to continue." --ellipsize "$ICON"
        exit 1
        ;;
    esac
    wait
    # Display info about IBD, keeping Tails private and extra reading material
    zenity --info --title='Setup almost complete' --icon-name=bot128 "$ICON" --text='The Bitcoin blockchain has begun syncing automatically.\nMake sure no one messes with the PC.\n\nTo lock the screen for privacy, press ❖+L (⊞+L or ⌘+L)\n\nIt is safer to exit Bitcoin (Ctrl+Q), <a href="https://tails.net/doc/first_steps/shutdown/index.en.html">shutdown Tails</a> and take your Bitcoin on Tails USB stick with you or store it in a safe place than leave Tails running unattended where people you distrust could tamper with it.\n\nIf you want to learn more about using Tails safely read the <a href="https://tails.net/doc/index.en.html">documentation</a>.\n\nAnother excellent read to improve your physical and digital security tactics is the <a href="'"$SECURITY_IN_A_BOX_URL"'">Security in-a-Box</a> website.'
    # Offer Sparrow Wallet as an optional add-on. Sparrow connects to the local
    # Bitcoin Core/Knots node over localhost RPC for maximum privacy.
    if zenity --question \
        --title='Install Sparrow Wallet?' \
        --text='<b>Sparrow Wallet</b> is a Bitcoin wallet focused on security and privacy. It can connect to your Bitcoin node so your wallet queries never leak to third-party servers.\n\nInstall Sparrow Wallet now?\n\n(You can also install it later by opening a terminal and running <tt>install-sparrow</tt>.)' \
        --ok-label='Yes, install Sparrow' --cancel-label='Not now' \
        "$ICON" --icon-name=bitcoin128; then
        install-sparrow || zenity --warning --title="Sparrow install did not complete" \
            --text="Sparrow Wallet installation was cancelled or failed. You can retry later by running <tt>install-sparrow</tt> from a terminal." \
            --ellipsize "$ICON"
    fi
    zenity --info --title="Bitcoin on Tails install successful" --text="Bitcoin on Tails $VERSION has been installed." "$ICON" --icon-name=bot128
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
    zenity --info --title="Bitcoin on Tails update successful" --text="Bitcoin on Tails has been updated to $VERSION." "$ICON" --icon-name=bot128
  fi
  exit 0
fi
exit 1
