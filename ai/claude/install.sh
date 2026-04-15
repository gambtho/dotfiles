#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

install_claude() {
    log_info "Installing Claude Code (native)..."
    curl -fsSL https://claude.ai/install.sh | bash
    log_success "Claude Code installed."
}

update_claude() {
    log_info "Updating Claude Code..."
    claude update
    log_success "Claude Code updated."
}

link_commands() {
    local src="$DOTFILES_ROOT/claude/commands"
    local dst="$HOME/.claude/commands"

    mkdir -p "$HOME/.claude"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "Claude commands already linked."
            return
        fi
        log_info "Removing existing commands symlink -> $current"
        rm "$dst"
    elif [ -d "$dst" ]; then
        # Merge any commands not already in dotfiles, then replace with symlink
        for f in "$dst"/*; do
            [ -f "$f" ] || continue
            local base
            base=$(basename "$f")
            if [ ! -f "$src/$base" ]; then
                log_info "Preserving existing command: $base"
                cp "$f" "$src/$base"
            fi
        done
        rm -rf "$dst"
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

main() {
    if command_exists claude; then
        log_info "Claude Code is already installed. Version: $(claude --version)"
        update_claude
    else
        if command_exists curl; then
            install_claude
        else
            log_warning "curl not found. Install curl first, then re-run."
            return 1
        fi
    fi

    link_commands
}

main "$@"
