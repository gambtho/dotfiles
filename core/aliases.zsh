# Only alias when nvim exists; otherwise `vi` would shadow the real vi/vim with
# a command-not-found. See the EDITOR fallback in core/env.zsh.
(( $+commands[nvim] )) && alias vi='nvim'