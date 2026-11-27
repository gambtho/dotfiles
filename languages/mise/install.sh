#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../libexec/common.sh"

install_tools() {
  local profile="${DOTFILES_PROFILE:-personal}"
  if [[ "$profile" == server ]]; then
    # git-lfs is here because the global gitconfig and hooks call it on every
    # profile; without it every commit and push warns.
    mise install --yes node python git-lfs
  else
    mise install --yes
  fi
}

main() {
  if ! command_exists mise; then
    printf '%s\n' "mise is not installed. Install system packages before runtime tools." >&2
    return 1
  fi

  install_tools
}

main "$@"
