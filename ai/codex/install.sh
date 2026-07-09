#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

link_file() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "Codex $label already linked."
            return
        fi
        log_info "Removing existing $label symlink -> $current"
        rm "$dst"
    elif [ -f "$dst" ]; then
        log_info "Backing up existing $label to ${dst}.backup"
        mv "$dst" "${dst}.backup"
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

main() {
    check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
        log_info "Dry-run mode: showing what would be linked"
    fi

    if [[ "$check_only" == true ]]; then
        log_info "[dry-run] Would ensure \$HOME/.codex exists"
        log_info "[dry-run] Would link $DOTFILES_ROOT/codex/config.toml -> $HOME/.codex/config.toml"
        return
    fi

    mkdir -p "$HOME/.codex"
    link_file "$DOTFILES_ROOT/codex/config.toml" "$HOME/.codex/config.toml" "config"
}

main "$@"
