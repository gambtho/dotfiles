#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MARKETPLACE_DIR="$DOTFILES_ROOT/ai/marketplace"

remove_legacy_commands_symlink() {
  if [ -L "$HOME/.claude/commands" ]; then
    local target
    target=$(readlink "$HOME/.claude/commands")
    log_info "Removing legacy ~/.claude/commands symlink (was -> $target)"
    rm "$HOME/.claude/commands"
  fi
}

# Remove symlinks left behind by the old OpenCode/Copilot bridge and installers.
# Only removes links whose target points into a now-deleted path inside this
# dotfiles repo (ai/opencode, ai/copilot, or a removed plugin agent/skill) — an
# unrelated user symlink is never touched.
remove_stale_bridge_symlinks() {
  local roots=(
    "$HOME/.config/opencode/skills" "$HOME/.config/opencode/agents"
    "$HOME/.config/opencode/commands"
    "$HOME/.copilot/skills" "$HOME/.copilot/agents"
  )
  local dir link target
  for dir in "${roots[@]}"; do
    [ -d "$dir" ] || continue
    for link in "$dir"/* "$dir"; do
      [ -L "$link" ] || continue
      target=$(readlink "$link")
      # Stale if it points into the deleted opencode/copilot trees, or is a
      # broken link into this repo (e.g. a bridged plugin agent we removed).
      case "$target" in
        *"$DOTFILES_ROOT/ai/opencode/"* | *"$DOTFILES_ROOT/ai/copilot/"*)
          log_info "Removing stale bridge symlink: $link -> $target"
          rm "$link"
          ;;
        "$DOTFILES_ROOT"/*)
          if [ ! -e "$link" ]; then
            log_info "Removing dangling repo symlink: $link -> $target"
            rm "$link"
          fi
          ;;
      esac
    done
  done
}

marketplace_already_added() {
  local f="$HOME/.claude/plugins/known_marketplaces.json"
  [ -f "$f" ] || return 1
  command_exists python3 || return 1
  python3 - "$f" "$MARKETPLACE_DIR" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
entry = data.get("guarzo") or {}
source = entry.get("source") or {}
expected = sys.argv[2]
sys.exit(0 if source.get("path") == expected and entry.get("installLocation") == expected else 1)
PY
}

write_marketplace_registry() {
  local registry="$HOME/.claude/plugins/known_marketplaces.json"
  command_exists python3 || log_error "python3 is required to update the Claude marketplace registry."
  mkdir -p "$(dirname "$registry")"
  python3 - "$registry" "$MARKETPLACE_DIR" <<'PY'
import datetime
import json
import os
import sys

path, marketplace = sys.argv[1:]
try:
    with open(path) as fh:
        data = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

data["guarzo"] = {
    "source": {"source": "directory", "path": marketplace},
    "installLocation": marketplace,
    "lastUpdated": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}

temporary = path + ".tmp"
with open(temporary, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(temporary, path)
PY
}

plugin_already_installed() {
  local f="$HOME/.claude/plugins/installed_plugins.json"
  [ -f "$f" ] || return 1
  command_exists python3 || return 1
  python3 - "$f" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sys.exit(0 if "my@guarzo" in (data.get("plugins") or {}) else 1)
PY
}

install_marketplace_and_plugin() {
  if ! command_exists claude; then
    log_warning "claude CLI not found; skipping marketplace install. Run ai/claude/install.sh first."
    return 1
  fi

  if marketplace_already_added; then
    log_info "Marketplace 'guarzo' already registered at $MARKETPLACE_DIR."
  else
    log_info "Registering 'guarzo' marketplace at $MARKETPLACE_DIR"
    write_marketplace_registry
  fi

  if plugin_already_installed; then
    log_info "Plugin 'my@guarzo' already installed — skipping install."
  else
    log_info "Installing 'my' plugin from 'guarzo' marketplace"
    claude plugin install my@guarzo
  fi

  log_success "Marketplace + plugin ready."
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    log_info "Dry-run mode: showing marketplace actions"
    log_info "[dry-run] Would remove the legacy Claude commands symlink if present"
    log_info "[dry-run] Would remove stale OpenCode and Copilot bridge symlinks"
    log_info "[dry-run] Would ensure the guarzo marketplace and my plugin are installed"
    return 0
  fi

  remove_legacy_commands_symlink
  remove_stale_bridge_symlinks
  install_marketplace_and_plugin
}

main "$@"
