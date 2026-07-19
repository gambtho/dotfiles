export DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
export ZSH="$DOTFILES"
unset WORK_PROFILE SERVER_PROFILE

typeset directory file platform profile

for file in "$DOTFILES"/core/path.zsh "$DOTFILES"/languages/*/path.zsh(N); do
  source "$file"
done

for directory in "$DOTFILES/core" "$DOTFILES/languages" "$DOTFILES/tools"; do
  for file in "$directory"/**/*.zsh(N); do
    [[ "$file" == "$DOTFILES/core/shell/load-custom.zsh" ]] && continue
    [[ "$file" == */path.zsh || "$file" == */completion.zsh ]] && continue
    source "$file"
  done
done

case "$(uname)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) platform=unknown ;;
esac
for file in "$DOTFILES/platforms/$platform"/*.zsh(N); do
  source "$file"
done

profile=personal
if [[ -r "$HOME/.dotfiles-profile" ]]; then
  profile="$(tr -d '[:space:]' <"$HOME/.dotfiles-profile")"
fi
case "$profile" in
  personal) source "$DOTFILES/profiles/personal.zsh" ;;
  work) source "$DOTFILES/profiles/work.zsh" ;;
  server) source "$DOTFILES/profiles/server.zsh" ;;
  *) source "$DOTFILES/profiles/personal.zsh" ;;
esac

[[ -r "$HOME/.localrc" ]] && source "$HOME/.localrc"
true
