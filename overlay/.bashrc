# ~/.bashrc — managed by Bitcoin on Tails (BoT).
#
# WHY THIS FILE EXISTS:
#   Tails' GNOME Console launches an interactive non-login shell, which only
#   sources ~/.bashrc. Debian's default ~/.profile (which adds ~/.local/bin
#   to PATH) is therefore NEVER sourced in a fresh Console window — and
#   without ~/.local/bin on PATH, BoT's scripts (b, install-core, btcprice,
#   utxoracle, utxoracle-serve, bot-menu, etc.) are not findable by name.
#   We fix that here, plus replicate the standard Debian interactive-shell
#   defaults so you don't lose history/aliases/prompt.
#
# DESIGN:
#   - Self-contained. Does NOT source /etc/skel/.bashrc, because Tails locks
#     /etc/skel down (the amnesia user can't read it — sourcing fails).
#   - Standard Debian boilerplate inlined verbatim so behavior matches what
#     you'd get on a stock Debian install (history dedup, append-on-exit,
#     `ll`/`la`/`l` aliases, color prompt where the terminal supports it).
#   - Then adds ~/.local/bin and the persistent BoT bin to PATH.
#
# This file is rsynced from $BOT_DIR/overlay/.bashrc to $DOTFILES/.bashrc
# by `b`, then symlinked into ~/.bashrc by `link-dotfiles`. For the symlink
# to survive reboots, the Dotfiles persistence feature must be ON.

# If not running interactively, don't do anything. (Standard Debian guard.)
case $- in
    *i*) ;;
      *) return;;
esac

# --- Standard Debian interactive defaults ----------------------------------

# History settings
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend

# Resize handling
shopt -s checkwinsize

# Colored prompt where supported. Falls back to a plain one otherwise.
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" \
                         || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# Common ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Color prompt detection (matches Debian default behavior).
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac
if [ -n "${color_prompt:-}" ]; then
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\u@\h:\w\$ '
fi
unset color_prompt

# --- BoT additions ---------------------------------------------------------

# Add ~/.local/bin to PATH for non-login shells.
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi

# Defensive: also reach the persistent BoT bin even if symlinks didn't get
# recreated this boot (e.g. if Tails' Dotfiles persistence is off, or
# link-dotfiles hasn't run yet).
_bot_persistent_bin="/live/persistence/TailsData_unlocked/dotfiles/.local/bin"
if [ -d "$_bot_persistent_bin" ]; then
    case ":$PATH:" in
        *":$_bot_persistent_bin:"*) ;;
        *) PATH="$PATH:$_bot_persistent_bin" ;;
    esac
fi
unset _bot_persistent_bin

export PATH

# Source any user-supplied .bashrc.d snippets (custom env, aliases, etc.).
if [ -d "$HOME/.bashrc.d" ]; then
    for _bashrc_d in "$HOME/.bashrc.d/"*.sh; do
        [ -r "$_bashrc_d" ] && . "$_bashrc_d"
    done
    unset _bashrc_d
fi
