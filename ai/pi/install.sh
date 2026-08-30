#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../bin/common.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=config/versions.env
source "$ROOT/config/versions.env"
# shellcheck source=ai/pi/cleanup-legacy.sh
source "$ROOT/ai/pi/cleanup-legacy.sh"

check_only=false

link_pi_file() {
  local source=$1 destination=$2 label=$3 mode=apply
  [[ "$check_only" == true ]] && mode=check
  reconcile_link "$source" "$destination" "Pi $label" backup "$mode"
}

install_pi() {
  mkdir -p "$HOME/.local/bin"
  npm install -g --prefix "$HOME/.local" --ignore-scripts \
    "@earendil-works/pi-coding-agent@$PI_VERSION"
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    check_only=true
    log_info "[dry-run] Would remove positively identified Vekil, Claude, and Codex integration remnants"
    log_info "[dry-run] Would install Pi $PI_VERSION into $HOME/.local"
  else
    cleanup_legacy_ai
    if [[ ! -x "$HOME/.local/bin/pi" ]] ||
      [[ "$("$HOME/.local/bin/pi" --version 2>/dev/null || true)" != "$PI_VERSION" ]]; then
      command_exists npm || {
        log_warning "npm is required to install Pi."
        return 1
      }
      install_pi
      log_success "Installed Pi $PI_VERSION."
    else
      log_info "Pi $PI_VERSION is already installed at $HOME/.local/bin/pi."
    fi
  fi

  if [[ "$check_only" != true ]]; then
    mkdir -p "$HOME/.pi/agent" "$HOME/.config/amp"
  fi
  link_pi_file "$ROOT/ai/pi/settings.json" "$HOME/.pi/agent/settings.json" settings
  link_pi_file "$ROOT/ai/pi/AGENTS.md" "$HOME/.pi/agent/AGENTS.md" "global AGENTS.md"
  link_pi_file "$ROOT/ai/pi/keybindings.json" "$HOME/.pi/agent/keybindings.json" keybindings
  link_pi_file "$ROOT/ai/pi/modes.json" "$HOME/.pi/agent/modes.json" modes
  link_pi_file "$ROOT/ai/pi/extensions" "$HOME/.pi/agent/extensions" extensions
  link_pi_file "$ROOT/ai/pi/permissions.json" "$HOME/.config/amp/settings.json" permissions

  if [[ "$check_only" == true ]]; then
    log_info "[dry-run] Would reconcile Pi packages from settings.json"
    return 0
  fi

  "$HOME/.local/bin/pi" update --extensions
  log_success "Pi configuration and packages are ready. Run /login and choose GitHub Copilot if this machine is not authenticated."
}

main "$@"
