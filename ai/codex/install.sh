#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BASE_CONFIG="$DOTFILES_ROOT/codex/config.toml"
LOCAL_PROJECTS="$DOTFILES_ROOT/codex/projects.local.toml"
MARKETPLACE_DIR="$DOTFILES_ROOT/marketplace"

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

render_config() {
  local codex_home="$1"
  local dst="$codex_home/config.toml"
  local temporary
  local marketplace_path

  temporary=$(mktemp "$codex_home/config.toml.XXXXXX")
  marketplace_path=$(printf '%s' "$MARKETPLACE_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')

  cat "$BASE_CONFIG" >"$temporary"
  if [ -f "$LOCAL_PROJECTS" ]; then
    printf '\n' >>"$temporary"
    cat "$LOCAL_PROJECTS" >>"$temporary"
  fi
  cat >>"$temporary" <<EOF

[marketplaces.guarzo]
source_type = "local"
source = "$marketplace_path"
EOF

  mv "$temporary" "$dst"
  log_success "Generated Codex config at $dst"
}

refresh_personal_plugin() {
  local codex_home="$1"
  if ! command_exists codex; then
    log_warning "Codex CLI not found; skipping personal plugin refresh."
    return 0
  fi

  CODEX_HOME="$codex_home" codex plugin add my@guarzo
  log_success "Refreshed my@guarzo from the local marketplace."
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
    log_info "[dry-run] Would generate $codex_home/config.toml from $BASE_CONFIG"
    if [ -f "$LOCAL_PROJECTS" ]; then
      log_info "[dry-run] Would merge machine-local projects from $LOCAL_PROJECTS"
    fi
    log_info "[dry-run] Would register the local marketplace at $MARKETPLACE_DIR"
    log_info "[dry-run] Would link $DOTFILES_ROOT/codex/AGENTS.md -> $codex_home/AGENTS.md"
    log_info "[dry-run] Would refresh my@guarzo from the local marketplace"
    return
  fi

  mkdir -p "$codex_home"
  render_config "$codex_home"
  link_file "$DOTFILES_ROOT/codex/AGENTS.md" "$codex_home/AGENTS.md" "global AGENTS.md"
  refresh_personal_plugin "$codex_home"
}

main "$@"
