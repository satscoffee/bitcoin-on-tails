# ~/.bashrc — managed by Bitcoin on Tails (BoT).
#
# WHY THIS FILE EXISTS:
#   Tails' GNOME Console launches an interactive non-login shell, which only
#   sources ~/.bashrc. Debian's default ~/.profile (which adds ~/.local/bin
#   to PATH) is therefore NEVER sourced in a fresh Console window — and
#   without ~/.local/bin on PATH, BoT's scripts (b, install-core,
#   install-knots, install-sparrow, utxoracle, bot-menu, stop-btc, etc.)
#   are not findable by name. We fix that here.
#
# DESIGN:
#   1. Source the system's default .bashrc from /etc/skel first, so we don't
#      lose any Debian/Tails defaults (history settings, prompt, aliases).
#      Tails' default .bashrc has an early `[ -z "$PS1" ] && return` for
#      non-interactive shells, which is fine — non-interactive shells don't
#      need our PATH addition either.
#   2. Add ~/.local/bin and (defensively) the BoT bin dir under Persistent
#      Storage to PATH if not already there.
#
# This file is rsynced from $BOT_DIR/overlay/.bashrc to $DOTFILES/.bashrc by
# `b`, then symlinked into ~/.bashrc by `link-dotfiles`. For the symlink to
# survive reboots, the Dotfiles persistence feature must be ON.

# 1. Source the system default .bashrc, if it exists.
if [ -f /etc/skel/.bashrc ]; then
    . /etc/skel/.bashrc
fi

# 2. BoT additions: add ~/.local/bin to PATH for non-login shells.
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi

# Defensive: also add the persistent BoT bin if it's reachable. Helps if
# ~/.local/bin symlinks somehow didn't get created on this boot — `b`,
# `install-*`, etc. will still resolve from their persistent location.
_bot_persistent_bin="/live/persistence/TailsData_unlocked/dotfiles/.local/bin"
if [ -d "$_bot_persistent_bin" ]; then
    case ":$PATH:" in
        *":$_bot_persistent_bin:"*) ;;
        *) PATH="$PATH:$_bot_persistent_bin" ;;
    esac
fi
unset _bot_persistent_bin

export PATH
