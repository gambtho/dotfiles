#!/usr/bin/env bash

set -e
source "$(dirname "$0")/../../bin/common.sh"

MISE_TOML="$(dirname "$0")/../mise/mise.local.toml.symlink"

install_lang() {
    # Ensure mise.toml exists
    if [[ ! -f "$MISE_TOML" ]]; then
        log_error "Mise.toml file not found at $MISE_TOML"
        exit 1
    fi

    local upgrade=false
    local langs="go python java node ruby"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upgrade|-u)
                upgrade=true
                shift
                ;;
            --langs)
                langs="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    log_info "Installing languages: $langs"

    for lang in $langs; do
        case "$lang" in
            go)
                GO_VERSION=$(get_version_from_mise "go" "$MISE_TOML")
                log_info "  Go: $GO_VERSION"
                install_or_update "go" "$GO_VERSION" "go version | awk '{print \$3}' | sed 's/go//'" "$upgrade"
                ;;
            python)
                PYTHON_VERSION=$(get_version_from_mise "python" "$MISE_TOML")
                log_info "  Python: $PYTHON_VERSION"
                install_or_update "python" "$PYTHON_VERSION" "python --version 2>&1 | awk '{print \$2}'" "$upgrade"
                ;;
            java)
                JAVA_VERSION=$(get_version_from_mise "java" "$MISE_TOML")
                log_info "  Java: $JAVA_VERSION"
                install_or_update "java" "$JAVA_VERSION" "java -version 2>&1 | awk -F '\"' '/version/ {print \$2}'" "$upgrade"
                ;;
            node)
                NODE_VERSION=$(get_version_from_mise "node" "$MISE_TOML")
                log_info "  Node: $NODE_VERSION"
                install_or_update "node" "$NODE_VERSION" "node -v | sed 's/v//'" "$upgrade"
                ;;
            ruby)
                RUBY_VERSION=$(get_version_from_mise "ruby" "$MISE_TOML")
                log_info "  Ruby: $RUBY_VERSION"
                install_or_update "ruby" "$RUBY_VERSION" "ruby --version 2>&1 | awk '{print \$2}'" "$upgrade"
                ;;
            *)
                log_warning "Unknown language: $lang"
                ;;
        esac
    done

    # Neovim: uses "stable" version tracking, handled separately from versioned tools
    log_info "Installing/updating neovim via mise..."
    mise use -g neovim@stable 2>/dev/null && log_success "Neovim updated to $(nvim --version | head -1)" || log_warning "Failed to install neovim via mise"

    # tree-sitter CLI: required by nvim-treesitter (main branch) to build parsers
    log_info "Installing/updating tree-sitter-cli via mise..."
    mise use -g "npm:tree-sitter-cli@latest" >/dev/null 2>&1 && log_success "tree-sitter-cli updated to $(tree-sitter --version 2>/dev/null | awk '{print $2}')" || log_warning "Failed to install tree-sitter-cli via mise"
}

install_lang "$@"
