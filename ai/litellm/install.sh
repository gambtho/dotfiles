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

install_uv() {
    if command_exists uv; then
        log_info "uv already installed: $(uv --version)"
        return
    fi
    if ! command_exists curl; then
        log_warning "curl not found; cannot install uv. Install curl first."
        return 1
    fi
    log_info "Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # The installer drops uv in ~/.local/bin; put it on PATH for the rest of this script.
    export PATH="$HOME/.local/bin:$PATH"
    if command_exists uv; then
        log_success "uv installed: $(uv --version)"
    else
        log_warning "uv installed but not on PATH; ensure ~/.local/bin is on PATH."
        return 1
    fi
}

install_litellm() {
    # uv tool install puts the binary at ~/.local/share/uv/tools/litellm/bin/litellm
    # and shims it into ~/.local/bin/litellm. Check the canonical path directly so
    # we don't depend on PATH state.
    local litellm_bin="$HOME/.local/share/uv/tools/litellm/bin/litellm"
    if [ -x "$litellm_bin" ] || command_exists litellm; then
        log_info "litellm already installed."
        return
    fi
    if ! command_exists uv; then
        log_warning "uv not available; skipping litellm install."
        return 1
    fi
    # Pinned to 3.13 because orjson (a litellm dep) doesn't ship wheels for 3.14 yet.
    log_info "Installing litellm[proxy] via uv (Python 3.13)..."
    uv tool install --python 3.13 'litellm[proxy]'
    log_success "litellm installed."
}

main() {
    log_info "Setting up LiteLLM proxy..."

    install_uv || log_warning "uv install failed; litellm step will be skipped."
    install_litellm || log_warning "litellm install failed; copilot-proxy won't start until fixed."
    link_config

    log_success "LiteLLM setup complete."
    log_info "First run needs a one-time GitHub Copilot OAuth device flow — see the"
    log_info "header of bin/copilot-proxy (step 3) for the command."
}

main "$@"
