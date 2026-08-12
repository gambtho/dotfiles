#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../bin/common.sh"

install_tools() {
  local profile="${DOTFILES_PROFILE:-personal}"
  if [[ "$profile" == server ]]; then
    mise install --yes node python
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
