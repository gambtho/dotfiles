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
                *"$DOTFILES_ROOT/ai/opencode/"*|*"$DOTFILES_ROOT/ai/copilot/"*)
                    log_info "Removing stale bridge symlink: $link -> $target"
                    rm "$link" ;;
                "$DOTFILES_ROOT"/*)
                    if [ ! -e "$link" ]; then
                        log_info "Removing dangling repo symlink: $link -> $target"
                        rm "$link"
                    fi ;;
            esac
        done
    done
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
    remove_stale_bridge_symlinks
    install_marketplace_and_plugin
}

main "$@"
