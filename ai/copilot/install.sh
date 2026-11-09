#!/usr/bin/env bash
set -euo pipefail

if (($# > 1)) || { (($# == 1)) && [[ "$1" != --check ]]; }; then
  echo "Usage: ${0##*/} [--check]" >&2
  exit 2
fi

if [[ -x "$HOME/.local/bin/copilot" ]]; then
  echo "Copilot CLI already installed; use copilot update to upgrade it."
  exit 0
fi
if [[ "${1:-}" == --check ]]; then
  echo "[dry-run] Would install latest Copilot CLI to $HOME/.local/bin."
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/../../libexec/lib/artifacts.sh"
PATH="$HOME/.local/bin:$PATH" PREFIX="$HOME/.local" VERSION=latest \
  run_remote_installer https://gh.io/copilot-install bash
test -x "$HOME/.local/bin/copilot"
