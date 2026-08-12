# Fall back when nvim is absent. Containers and minimal hosts get these dotfiles
# without the OS package layer that supplies the binary, and an EDITOR pointing
# at a missing command breaks `git commit`, `git rebase -i`, and every tool that
# shells out to $EDITOR — with a confusing error that names git, not the editor.
#
# core.editor is deliberately NOT set in gitconfig: it outranks $EDITOR, so
# hard-coding nvim there would defeat this whole chain. Git's own fallback ends
# at vi, which is the same last resort used here.
if (( $+commands[nvim] )); then
  export EDITOR='nvim'
elif (( $+commands[vim] )); then
  export EDITOR='vim'
elif (( $+commands[vi] )); then
  export EDITOR='vi'
else
  # Nothing to point at — minimal images ship none of the three. Leave EDITOR
  # unset rather than naming a missing binary, so consumers use their own
  # defaults instead of failing on exec.
  unset EDITOR
fi
export GPG_TTY=$(tty)
export CLICOLOR=1