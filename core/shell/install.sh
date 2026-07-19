#!/usr/bin/env bash

set -e

# Source the common functions, including detect_os and command_exists
source "$(dirname "$0")/../../bin/common.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=config/versions.env
source "$ROOT/config/versions.env"

# Function to set the default shell to Zsh
set_default_shell_to_zsh() {
  detect_os

  local zsh_path
  zsh_path=$(which zsh)
  if [ -z "$zsh_path" ]; then
    log_error "Zsh is not installed. Please install it and try again."
    exit 1
  fi

  case "$OS" in
    macOS)
      local current_shell
      current_shell=$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')
      if [ "$current_shell" != "$zsh_path" ]; then
        if ! grep -q "$zsh_path" /etc/shells; then
          log_info "Adding zsh to /etc/shells..."
          echo "$zsh_path" | sudo tee -a /etc/shells
        fi
        log_info "Setting login shell to zsh..."
        chsh -s "$zsh_path"
      fi
      ;;
    Ubuntu | WSL)
      if [[ "$(basename "${SHELL:-}")" != zsh ]]; then
        log_info "Setting login shell to zsh..."
        sudo chsh -s "$zsh_path" "$USER"
      fi
      ;;
    *)
      log_warning "Unsupported operating system."
      exit 1
      ;;
  esac
}

install_pinned_repo() {
  local name="$1"
  local repo="$2"
  local ref="$3"
  local target="$4"
  local recursive="${5:-false}"

  if ! command_exists "git"; then
    log_error "Git is not installed. Please install it and try again."
  fi

  if [[ ! -d "$target/.git" ]]; then
    if [[ -e "$target" ]]; then
      log_error "$name target exists but is not a Git repository: $target"
    fi
    log_info "Cloning $name..."
    git clone "$repo" "$target" >/dev/null 2>&1 || log_error "Failed to clone $name."
  fi

  if ! git -C "$target" cat-file -e "$ref^{commit}" 2>/dev/null; then
    log_info "Fetching pinned $name revision..."
    git -C "$target" fetch origin >/dev/null 2>&1 || log_error "Failed to fetch $name."
  fi

  git -C "$target" checkout --detach "$ref" >/dev/null 2>&1 || log_error "Failed to check out pinned $name revision."
  if [[ "$recursive" == true ]]; then
    git -C "$target" submodule sync --recursive >/dev/null 2>&1 || log_error "Failed to sync $name submodules."
    git -C "$target" submodule update --init --recursive >/dev/null 2>&1 || log_error "Failed to update $name submodules."
  fi

  local actual_ref
  actual_ref=$(git -C "$target" rev-parse HEAD)
  if [[ "$actual_ref" != "$ref" ]]; then
    log_error "$name revision mismatch: expected $ref, got $actual_ref"
  fi
  log_success "$name is pinned at $actual_ref."
}

install_prezto() {
  install_pinned_repo "Prezto" "$PREZTO_REPO" "$PREZTO_REF" "${ZDOTDIR:-$HOME}/.zprezto" true
}

install_zsh_defer() {
  install_pinned_repo "zsh-defer" "$ZSH_DEFER_REPO" "$ZSH_DEFER_REF" "$HOME/.zsh-defer"
}

# Main function
main() {
  set_default_shell_to_zsh
  install_prezto
  install_zsh_defer
  log_success "Zsh dependencies installed."
}

main "$@"
