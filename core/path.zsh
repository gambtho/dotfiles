typeset -U path PATH
path=(${path:#.})
path=(${path:#./bin})
path=(
  "${ZSH:-$HOME/.dotfiles}/bin"
  "$HOME/.local/bin"
  "$HOME/bin"
  /usr/local/bin
  /usr/local/sbin
  $path
)
export PATH
export MANPATH="/usr/local/man:/usr/local/mysql/man:/usr/local/git/man:${MANPATH:-}"
