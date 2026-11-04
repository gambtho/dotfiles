#!/usr/bin/env bash
set -euo pipefail

if [[ -x "$HOME/.local/bin/copilot" ]]; then
  echo "Copilot CLI already installed; use copilot update to upgrade it."
  exit 0
fi
if [[ "${1:-}" == --check ]]; then
  echo "[dry-run] Would install latest Copilot CLI to $HOME/.local/bin."
  exit 0
fi

installer=$(mktemp)
trap 'rm -f "$installer"' EXIT
curl -fsSL https://gh.io/copilot-install -o "$installer"
PATH="$HOME/.local/bin:$PATH" PREFIX="$HOME/.local" VERSION=latest bash "$installer"
test -x "$HOME/.local/bin/copilot"
