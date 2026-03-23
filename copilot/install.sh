#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

link_agents() {
    local src="$DOTFILES_ROOT/copilot/agents"
    local dst="$HOME/.copilot/agents"

    mkdir -p "$HOME/.copilot"

    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" == "$src" ]; then
            log_info "Copilot agents already linked."
            return
        fi
        log_info "Removing existing agents symlink -> $current"
        rm "$dst"
    elif [ -d "$dst" ]; then
        # Preserve any agents not already in dotfiles, then replace with symlink
        for f in "$dst"/*.agent.md; do
            [ -f "$f" ] || continue
            local base
            base=$(basename "$f")
            if [ ! -f "$src/$base" ]; then
                log_info "Preserving existing agent: $base"
                cp "$f" "$src/$base"
            fi
        done
        rm -rf "$dst"
    fi

    ln -s "$src" "$dst"
    log_success "Linked $src to $dst"
}

link_skills() {
    local skills_src="$DOTFILES_ROOT/copilot/skills"
    local skills_dst="$HOME/.copilot/skills"

    mkdir -p "$skills_dst"

    # Link each skill subdirectory individually so user can have other skills too
    for skill_dir in "$skills_src"/*/; do
        [ -d "$skill_dir" ] || continue
        local skill_name
        skill_name=$(basename "$skill_dir")
        local src="$skills_src/$skill_name"
        local dst="$skills_dst/$skill_name"

        if [ -L "$dst" ]; then
            local current
            current=$(readlink "$dst")
            if [ "$current" == "$src" ]; then
                log_info "Skill '$skill_name' already linked."
                continue
            fi
            log_info "Removing existing skill symlink '$skill_name' -> $current"
            rm "$dst"
        elif [ -d "$dst" ]; then
            # Preserve any files not already in dotfiles
            for f in "$dst"/*; do
                [ -f "$f" ] || continue
                local base
                base=$(basename "$f")
                if [ ! -f "$src/$base" ]; then
                    log_info "Preserving existing skill file: $skill_name/$base"
                    cp "$f" "$src/$base"
                fi
            done
            rm -rf "$dst"
        fi

        ln -s "$src" "$dst"
        log_success "Linked skill '$skill_name': $src -> $dst"
    done
}

main() {
    log_info "Setting up Copilot CLI agents and skills..."

    link_agents
    link_skills

    log_success "Copilot CLI setup complete."
}

main "$@"
