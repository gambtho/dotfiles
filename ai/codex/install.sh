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
        local backup="${dst}.backup"
        [ -e "$backup" ] && backup="${dst}.backup.$(date +%Y%m%d%H%M%S)"
        log_info "Backing up existing $label to $backup"
        mv "$dst" "$backup"
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

    local codex_home="${CODEX_HOME:-$HOME/.codex}"

    if [[ "$check_only" == true ]]; then
        log_info "[dry-run] Would ensure $codex_home exists"
        log_info "[dry-run] Would link $DOTFILES_ROOT/codex/config.toml -> $codex_home/config.toml"
        log_info "[dry-run] Would link $DOTFILES_ROOT/codex/AGENTS.md -> $codex_home/AGENTS.md"
        return
    fi

    mkdir -p "$codex_home"
    link_file "$DOTFILES_ROOT/codex/config.toml" "$codex_home/config.toml" "config"
    link_file "$DOTFILES_ROOT/codex/AGENTS.md" "$codex_home/AGENTS.md" "global AGENTS.md"
}

main "$@"
