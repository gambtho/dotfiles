#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

link_config() {
    local src="$DOTFILES_ROOT/litellm/config.yaml"
    local dst_dir="$HOME/.config/litellm"
    local dst="$dst_dir/config.yaml"

    mkdir -p "$dst_dir"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "litellm config.yaml already linked."
            return
        fi
        log_info "Removing existing config.yaml symlink -> $current"
        rm "$dst"
    elif [ -f "$dst" ]; then
        local backup="$dst.backup.$(date +%Y%m%d%H%M%S)"
        log_info "Backing up existing config.yaml -> $backup"
        mv "$dst" "$backup"
    elif [ -e "$dst" ]; then
        local backup="$dst.backup.$(date +%Y%m%d%H%M%S)"
        log_info "Backing up existing config.yaml (non-regular) -> $backup"
        mv "$dst" "$backup"
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src -> $dst"
}

main() {
    log_info "Setting up LiteLLM proxy config..."

    link_config

    log_success "LiteLLM setup complete. Tokens in ~/.config/litellm/github_copilot/ are managed by litellm itself."
}

main "$@"
