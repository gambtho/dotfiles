#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MARKETPLACE_DIR="$DOTFILES_ROOT/ai/marketplace"
PLUGIN_DIR="$MARKETPLACE_DIR/plugins/my"

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

bridge_to_tool() {
    local tool_name="$1"
    local target_root="$2"

    if [ ! -d "$target_root" ]; then
        log_info "${tool_name} not detected at $target_root — skipping bridge."
        return 0
    fi

    if [ ! -w "$target_root" ]; then
        log_warning "${tool_name} dir $target_root is not writable (owned by another user?) — skipping bridge."
        return 0
    fi

    for d in skills agents; do
        local plugin_subdir="$PLUGIN_DIR/$d"
        local target_subdir="$target_root/$d"
        [ -d "$plugin_subdir" ] || continue
        mkdir -p "$target_subdir"
        for item in "$plugin_subdir"/*; do
            [ -e "$item" ] || continue
            local name
            name=$(basename "$item")
            local link="$target_subdir/$name"
            if [ -L "$link" ] && [ "$(readlink "$link")" = "$item" ]; then
                continue
            fi
            if [ -e "$link" ] && [ ! -L "$link" ]; then
                log_warning "${tool_name} ${d}/${name} exists and is not a symlink — leaving alone."
                continue
            fi
            ln -snf "$item" "$link"
            log_success "${tool_name}: linked ${d}/${name}"
        done
    done
}

main() {
    remove_legacy_commands_symlink
    install_marketplace_and_plugin
    bridge_to_tool "OpenCode" "$HOME/.config/opencode"
    bridge_to_tool "Copilot"  "$HOME/.copilot"
}

main "$@"
