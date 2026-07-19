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

marketplace_already_added() {
    local f="$HOME/.claude/settings.json"
    [ -f "$f" ] || return 1
    command_exists python3 || return 1
    python3 - "$f" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sys.exit(0 if "guarzo" in (data.get("extraKnownMarketplaces") or {}) else 1)
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
        log_info "Marketplace 'guarzo' already registered — skipping add."
    else
        log_info "Adding 'guarzo' marketplace from $MARKETPLACE_DIR"
        claude plugin marketplace add --scope user "$MARKETPLACE_DIR"
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
    remove_legacy_commands_symlink
    install_marketplace_and_plugin
}

main "$@"
