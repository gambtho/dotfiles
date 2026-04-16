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

install_marketplace_and_plugin() {
    if ! command_exists claude; then
        log_warning "claude CLI not found; skipping marketplace install. Run ai/claude/install.sh first."
        return 1
    fi

    log_info "Adding 'guarzo' marketplace from $MARKETPLACE_DIR"
    claude plugin marketplace add --scope user "$MARKETPLACE_DIR" || \
        log_info "Marketplace 'guarzo' may already be added — continuing."

    log_info "Installing 'my' plugin from 'guarzo' marketplace"
    claude plugin install my@guarzo || \
        log_info "Plugin 'my' may already be installed — continuing."

    log_success "Marketplace + plugin installed."
}

bridge_to_tool() {
    local tool_name="$1"
    local target_root="$2"

    if [ ! -d "$target_root" ]; then
        log_info "${tool_name} not detected at $target_root — skipping bridge."
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
