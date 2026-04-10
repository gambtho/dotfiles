# Work profile — sources all work-specific configuration
export WORK_PROFILE=1

for file in $DOTFILES/work/*.zsh; do
  source "$file"
done
