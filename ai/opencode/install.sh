#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

install_opencode() {
    log_info "Installing OpenCode..."
    npm install -g opencode-ai
    log_success "OpenCode installed."
}

update_opencode() {
    log_info "Updating OpenCode..."
    npm update -g opencode-ai
    log_success "OpenCode updated."
}

link_dir() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "OpenCode $label already linked."
            return
        fi
        log_info "Removing existing $label symlink -> $current"
        rm "$dst"
    elif [ -d "$dst" ]; then
        # Merge any files not already in dotfiles, then replace with symlink
        for f in "$dst"/*; do
            [ -f "$f" ] || continue
            local base
            base=$(basename "$f")
            if [ ! -f "$src/$base" ]; then
                log_info "Preserving existing $label: $base"
                cp "$f" "$src/$base"
            fi
        done
        rm -rf "$dst"
    fi

    if [[ "$check_only" == true ]]; then
        log_info "[dry-run] Would link $src -> $dst"
        return
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

link_file() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "OpenCode $label already linked."
            return
        fi
        log_info "Removing existing $label symlink -> $current"
        rm "$dst"
    elif [ -f "$dst" ]; then
        log_info "Backing up existing $label to ${dst}.backup"
        mv "$dst" "${dst}.backup"
    fi

    if [[ "$check_only" == true ]]; then
        log_info "[dry-run] Would link $src -> $dst"
        return
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

main() {
    check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
        log_info "Dry-run mode: showing what would be linked/installed"
    fi

    if [[ "$check_only" == true ]]; then
        if command_exists opencode; then
            log_info "[dry-run] OpenCode is installed, would update"
        else
            log_info "[dry-run] OpenCode not installed, would install via npm"
        fi
    else
        if command_exists opencode; then
            log_info "OpenCode is already installed."
            update_opencode
        else
            if command_exists npm; then
                install_opencode
            else
                log_warning "npm not found. Install Node.js/npm first, then re-run."
                return 1
            fi
        fi
    fi

    mkdir -p "$HOME/.config/opencode"

    link_dir "$DOTFILES_ROOT/opencode/commands" "$HOME/.config/opencode/commands" "commands"
    link_dir "$DOTFILES_ROOT/opencode/agents" "$HOME/.config/opencode/agents" "agents"
    link_file "$DOTFILES_ROOT/opencode/opencode.json" "$HOME/.config/opencode/opencode.json" "config"

    # Link each skill from dotfiles into the skills directory
    if [ -d "$DOTFILES_ROOT/opencode/skills" ]; then
        mkdir -p "$HOME/.config/opencode/skills"
        for skill_dir in "$DOTFILES_ROOT/opencode/skills"/*/; do
            [ -d "$skill_dir" ] || continue
            local skill_name
            skill_name=$(basename "$skill_dir")
            link_dir "$DOTFILES_ROOT/opencode/skills/$skill_name" "$HOME/.config/opencode/skills/$skill_name" "skill: $skill_name"
        done
    fi

    # Link DCP config if it exists
    if [ -f "$DOTFILES_ROOT/opencode/dcp.jsonc" ]; then
        link_file "$DOTFILES_ROOT/opencode/dcp.jsonc" "$HOME/.config/opencode/dcp.jsonc" "DCP config"
    fi

    # Install plugin dependencies
    if [ -f "$DOTFILES_ROOT/opencode/.opencode/package.json" ]; then
        if [[ "$check_only" == true ]]; then
            log_info "[dry-run] Would run npm install in .opencode/"
        else
            log_info "Installing plugin dependencies..."
            (cd "$DOTFILES_ROOT/opencode/.opencode" && npm install --silent)
            log_success "Plugin dependencies installed."
        fi
    fi
}

main "$@"
