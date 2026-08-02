# Fall back when nvim is absent. Containers and minimal hosts get these dotfiles
# without the OS package layer that supplies the binary, and an EDITOR pointing
# at a missing command breaks `git commit`, `git rebase -i`, and every tool that
# shells out to $EDITOR — with a confusing error that names git, not the editor.
if (( $+commands[nvim] )); then
  export EDITOR='nvim'
elif (( $+commands[vim] )); then
  export EDITOR='vim'
else
  export EDITOR='vi'
fi
export GPG_TTY=$(tty)
export CLICOLOR=1