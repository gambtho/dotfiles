#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../../bin/common.sh"
# shellcheck source=config/versions.env
source "$(dirname "${BASH_SOURCE[0]}")/../../config/versions.env"

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BASE_CONFIG="$DOTFILES_ROOT/codex/config.toml"
LOCAL_PROJECTS="$DOTFILES_ROOT/codex/projects.local.toml"
MARKETPLACE_DIR="$DOTFILES_ROOT/marketplace"

link_file() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local mode=apply
  [[ "$check_only" == true ]] && mode=check
  reconcile_link "$src" "$dst" "Codex $label" backup "$mode"
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

ensure_auth() {
  # Codex shows its interactive "Sign in" onboarding whenever auth.json is
  # absent, even though the Vekil shell function supplies OPENAI_API_KEY=dummy
  # at launch. Write a placeholder apikey auth file so onboarding is skipped and
  # requests flow through the proxy. Never overwrite an existing file: it may
  # hold a real ChatGPT/API login the user established themselves.
  local codex_home="$1"
  local auth_file="$codex_home/auth.json"

  if [ -e "$auth_file" ]; then
    log_info "Codex auth already present at $auth_file; leaving untouched."
    return
  fi

  local temporary
  temporary=$(mktemp "$codex_home/auth.json.XXXXXX")
  chmod 600 "$temporary"
  cat >"$temporary" <<'EOF'
{
  "auth_mode": "apikey",
  "OPENAI_API_KEY": "dummy"
}
EOF
  mv "$temporary" "$auth_file"
  log_success "Wrote placeholder Codex auth at $auth_file (routed via Vekil)."
}

ensure_binary() {
  # ~/.local/bin is on PATH regardless of the active toolchain, so anchoring
  # here makes codex resolve from every directory and inside the container.
  if [ -x "$HOME/.local/bin/codex" ]; then
    log_info "Codex CLI already installed at $HOME/.local/bin/codex ($("$HOME/.local/bin/codex" --version 2>/dev/null || echo '?'))."
    return 0
  fi

  if command_exists codex && codex --version >/dev/null 2>&1; then
    log_info "A working codex is already on PATH ($(codex --version 2>/dev/null)); installing a toolchain-independent copy in ~/.local/bin as well."
  fi

  if ! command_exists npm; then
    log_warning "npm not found; cannot install the Codex CLI. Install Node, then re-run."
    return 0
  fi

  log_info "Installing Codex CLI @openai/codex@$CODEX_VERSION"
  if npm install -g --prefix "$HOME/.local" "@openai/codex@$CODEX_VERSION"; then
    log_success "Installed Codex CLI to $HOME/.local/bin/codex"
  else
    log_warning "Codex CLI install failed; config is in place but 'codex' will not run."
  fi
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
    if [ -e "$codex_home/auth.json" ]; then
      log_info "[dry-run] Would leave existing Codex auth at $codex_home/auth.json untouched"
    else
      log_info "[dry-run] Would write placeholder Codex auth at $codex_home/auth.json"
    fi
    link_file "$DOTFILES_ROOT/codex/AGENTS.md" "$codex_home/AGENTS.md" "global AGENTS.md"
    if [ -x "$HOME/.local/bin/codex" ]; then
      log_info "[dry-run] Codex CLI already installed at $HOME/.local/bin/codex"
    else
      log_info "[dry-run] Would install @openai/codex@$CODEX_VERSION into $HOME/.local"
    fi
    log_info "[dry-run] Would refresh my@guarzo from the local marketplace"
    return
  fi

  mkdir -p "$codex_home"
  render_config "$codex_home"
  ensure_auth "$codex_home"
  link_file "$DOTFILES_ROOT/codex/AGENTS.md" "$codex_home/AGENTS.md" "global AGENTS.md"
  # Before refresh_personal_plugin: that step shells out to `codex plugin add`.
  # Put the install prefix on PATH first so a just-installed binary is visible
  # to command_exists within this same run.
  export PATH="$HOME/.local/bin:$PATH"
  ensure_binary
  refresh_personal_plugin "$codex_home"
}

main "$@"
