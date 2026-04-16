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
}

main "$@"
