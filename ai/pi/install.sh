#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../bin/common.sh"

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=config/versions.env
source "$ROOT/config/versions.env"
# shellcheck source=ai/pi/cleanup-legacy.sh
source "$ROOT/ai/pi/cleanup-legacy.sh"
# shellcheck source=ai/pi/migrate-security-stack.sh
source "$ROOT/ai/pi/migrate-security-stack.sh"

MODE=apply
PI_AI_RESET_MUTABLE_CONFIG="${PI_AI_RESET_MUTABLE_CONFIG:-0}"
PI_AGENT_DIR=""
WEB_CONFIG_PATH=""
AMP_SETTINGS_PATH=""
CANONICAL_DOTFILES_ROOT=""
MANAGED_SOURCE_ROOTS=()
managed_extensions=(herdr-agent-state.ts worktree-guard.ts)

usage() {
  printf 'usage: %s [--check]\n' "$0"
}

resolve_pi_paths() {
  if [[ -n "${PI_CODING_AGENT_DIR:-}" && "$PI_CODING_AGENT_DIR" != /* ]]; then
    log_warning "PI_CODING_AGENT_DIR must be absolute: $PI_CODING_AGENT_DIR"
    return 1
  fi
  if [[ "/${PI_CODING_AGENT_DIR:-}/" == *'/./'* ||
    "/${PI_CODING_AGENT_DIR:-}/" == *'/../'* ]]; then
    log_warning "PI_CODING_AGENT_DIR must not contain dot segments: $PI_CODING_AGENT_DIR"
    return 1
  fi
  case "$PI_AI_RESET_MUTABLE_CONFIG" in
    0 | 1) ;;
    *)
      log_warning "PI_AI_RESET_MUTABLE_CONFIG must be 0 or 1."
      return 1
      ;;
  esac

  PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
    WEB_CONFIG_PATH="$PI_AGENT_DIR/web-search.json"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    WEB_CONFIG_PATH="$XDG_CONFIG_HOME/pi/web-search.json"
  else
    WEB_CONFIG_PATH="$HOME/.pi/web-search.json"
  fi
  AMP_SETTINGS_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/amp/settings.json"
  export AMP_SETTINGS_PATH
  CANONICAL_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"

  MANAGED_SOURCE_ROOTS=("$ROOT")
  if [[ (-e "$CANONICAL_DOTFILES_ROOT" || -L "$CANONICAL_DOTFILES_ROOT") &&
    "$CANONICAL_DOTFILES_ROOT" != "$ROOT" ]]; then
    MANAGED_SOURCE_ROOTS+=("${CANONICAL_DOTFILES_ROOT%/}")
  fi
}

is_production_agent_dir() {
  local production="$HOME/.pi/agent" requested_real production_real
  [[ "$PI_AGENT_DIR" == "$production" ]] && return 0
  [[ -d "$PI_AGENT_DIR" && -d "$production" ]] || return 1
  requested_real=$(cd "$PI_AGENT_DIR" && pwd -P)
  production_real=$(cd "$production" && pwd -P)
  [[ "$requested_real" == "$production_real" ]]
}

assert_safe_pi_source() {
  [[ "$MODE" == apply ]] || return 0
  is_production_agent_dir || return 0
  [[ -d "$CANONICAL_DOTFILES_ROOT" ]] || return 0

  local canonical_real
  canonical_real=$(cd "$CANONICAL_DOTFILES_ROOT" && pwd -P)
  if [[ "$canonical_real" != "$ROOT" ]]; then
    log_warning "Refusing to publish production Pi configuration from a noncanonical checkout."
    log_warning "Use an isolated absolute PI_CODING_AGENT_DIR for pre-integration smoke tests, or rerun from the canonical checkout at $CANONICAL_DOTFILES_ROOT."
    return 1
  fi
}

is_recognized_source_link() {
  local destination=$1 suffix=$2 target root
  [[ -L "$destination" ]] || return 1
  target=$(readlink "$destination")
  for root in "${MANAGED_SOURCE_ROOTS[@]}"; do
    [[ "$target" == "${root%/}/$suffix" ]] && return 0
  done
  return 1
}

render_pi_baseline() {
  local source=$1 output=$2
  jq --arg token '__PI_AGENT_DIR__' --arg replacement "$PI_AGENT_DIR" '
    walk(
      if type == "object" then
        with_entries(.key |= gsub($token; $replacement))
      elif type == "string" then
        gsub($token; $replacement)
      else
        .
      end
    )
  ' "$source" >"$output"
  if [[ "$output" != /dev/stdout ]]; then
    jq empty "$output"
  fi
}

rendered_baseline_contents() {
  local source=$1
  render_pi_baseline "$source" /dev/stdout
}

atomic_publish_file() {
  local source=$1 destination=$2 file_mode=$3 staged
  staged=$(mktemp "${destination}.tmp.XXXXXX")
  if ! /usr/bin/install -m "$file_mode" "$source" "$staged"; then
    rm -f "$staged"
    return 1
  fi
  if ! mv -f "$staged" "$destination"; then
    rm -f "$staged"
    return 1
  fi
}

publish_rendered_baseline() {
  local source=$1 destination=$2 file_mode=$3 candidate
  candidate=$(mktemp "${destination}.candidate.XXXXXX")
  if ! render_pi_baseline "$source" "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  atomic_publish_file "$candidate" "$destination" "$file_mode"
  rm -f "$candidate"
}

backup_regular_contents() {
  local source=$1 destination=$2 backup
  backup=$(next_backup_path "$destination")
  if ! cp -L -- "$source" "$backup"; then
    rm -f "$backup"
    return 1
  fi
  printf '%s\n' "$backup"
}

reconcile_mutable_file() {
  local source=$1 destination=$2 label=$3 file_mode=$4 legacy_suffix="${5:-}"
  local parent rendered backup candidate
  parent=$(dirname "$destination")

  jq empty "$source" >/dev/null
  rendered=$(rendered_baseline_contents "$source")

  if [[ -L "$destination" ]]; then
    if [[ -z "$legacy_suffix" ]] || ! is_recognized_source_link "$destination" "$legacy_suffix"; then
      log_warning "Refusing foreign mutable symlink for $label at $destination"
      return 1
    fi
    if [[ "$MODE" == check ]]; then
      if [[ -e "$destination" && "$PI_AI_RESET_MUTABLE_CONFIG" == 0 ]]; then
        log_info "[dry-run] Would convert $label to a regular file preserving current contents: $destination"
      else
        log_info "[dry-run] Would replace recognized $label link with baseline: $destination"
      fi
      return 0
    fi

    mkdir -p "$parent"
    if [[ -e "$destination" ]]; then
      backup=$(backup_regular_contents "$destination" "$destination")
      if [[ "$PI_AI_RESET_MUTABLE_CONFIG" == 0 ]]; then
        candidate=$(mktemp "${destination}.candidate.XXXXXX")
        cat -- "$destination" >"$candidate"
        rm -- "$destination"
        atomic_publish_file "$candidate" "$destination" "$file_mode"
        rm -f "$candidate"
        log_success "Converted $label to a regular file; preserved legacy contents and backed them up at $backup"
        return 0
      fi
      rm -- "$destination"
      publish_rendered_baseline "$source" "$destination" "$file_mode"
      log_success "Reset $label from baseline; backup: $backup"
      return 0
    fi

    rm -- "$destination"
    publish_rendered_baseline "$source" "$destination" "$file_mode"
    log_success "Replaced dangling managed $label link with baseline at $destination"
    return 0
  fi

  if [[ -e "$destination" && ! -f "$destination" ]]; then
    log_warning "Refusing non-file mutable destination for $label at $destination"
    return 1
  fi

  if [[ -f "$destination" ]]; then
    if cmp -s <(printf '%s\n' "$rendered") "$destination"; then
      log_info "$label already matches its baseline at $destination"
      return 0
    fi
    if [[ "$PI_AI_RESET_MUTABLE_CONFIG" == 0 ]]; then
      log_info "$label preserved at $destination; set PI_AI_RESET_MUTABLE_CONFIG=1 to replace it with the tracked baseline."
      return 0
    fi
    if [[ "$MODE" == check ]]; then
      log_info "[dry-run] Would back up and reset $label at $destination"
      return 0
    fi
    backup=$(backup_regular_contents "$destination" "$destination")
    publish_rendered_baseline "$source" "$destination" "$file_mode"
    log_success "Reset $label from baseline; backup: $backup"
    return 0
  fi

  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would install $label baseline at $destination"
    return 0
  fi
  mkdir -p "$parent"
  publish_rendered_baseline "$source" "$destination" "$file_mode"
  log_success "Installed $label baseline at $destination"
}

reset_permission_policy_for_sandbox_retirement() {
  local source=$1 destination=$2 settings=$3 sandbox_source backup rendered
  sandbox_source='git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72'
  [[ -f "$settings" ]] || return 0
  jq -e 'type == "object"' "$settings" >/dev/null || {
    log_warning "Cannot safely inspect Pi package inventory at $settings"
    return 1
  }
  jq -e 'has("packages")' "$settings" >/dev/null || return 0
  jq -e '(.packages | type) == "array"' "$settings" >/dev/null || {
    log_warning "Cannot safely inspect Pi package inventory at $settings"
    return 1
  }
  jq -e --arg source "$sandbox_source" '
    [.packages[] | if type == "string" then . else .source end] | index($source) != null
  ' "$settings" >/dev/null || return 0

  rendered=$(rendered_baseline_contents "$source")
  if [[ -f "$destination" ]] && cmp -s <(printf '%s\n' "$rendered") "$destination"; then
    return 0
  fi
  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would reset Pi permission policy before retiring pi-sandbox at $destination"
    return 0
  fi

  if [[ -f "$destination" ]]; then
    backup=$(backup_regular_contents "$destination" "$destination")
  fi
  publish_rendered_baseline "$source" "$destination" 0644
  log_success "Reset Pi permission policy before retiring pi-sandbox${backup:+; backup: $backup}"
}

remove_retired_sandbox_exclusion() {
  local destination=$1 backup candidate source
  source='git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72'
  [[ -f "$destination" ]] || return 0
  jq -e --arg source "$source" '
    (.excludedExtensionPackages // []) | index($source) != null
  ' "$destination" >/dev/null || return 0

  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would remove the retired pi-sandbox child exclusion from $destination"
    return 0
  fi

  backup=$(backup_regular_contents "$destination" "$destination")
  candidate=$(mktemp "${destination}.candidate.XXXXXX")
  jq --arg source "$source" '
    .excludedExtensionPackages = [
      .excludedExtensionPackages[] | select(. != $source)
    ]
  ' "$destination" >"$candidate"
  atomic_publish_file "$candidate" "$destination" 0600
  rm -f "$candidate"
  log_success "Removed retired pi-sandbox child exclusion; backup: $backup"
}

settings_candidate_contents() {
  local source=$1 destination=$2 use_runtime=$3
  if [[ "$use_runtime" == true ]]; then
    jq -s '.[0] as $runtime | .[1] as $baseline | $runtime + {packages: $baseline.packages}' \
      "$destination" "$source"
  else
    cat "$source"
  fi
}

reconcile_pi_settings() {
  local source=$1 destination=$2 parent use_runtime=false backup raw
  parent=$(dirname "$destination")
  jq -e 'type == "object"' "$source" >/dev/null

  if [[ -L "$destination" ]]; then
    if ! is_recognized_source_link "$destination" 'ai/pi/settings.json'; then
      log_warning "Refusing foreign mutable symlink for Pi settings at $destination"
      return 1
    fi
    if [[ -e "$destination" && "$PI_AI_RESET_MUTABLE_CONFIG" == 0 ]]; then
      jq -e 'type == "object"' "$destination" >/dev/null || {
        log_warning "Existing Pi settings must be a JSON object: $destination"
        return 1
      }
      use_runtime=true
    fi
  elif [[ -e "$destination" ]]; then
    [[ -f "$destination" ]] || {
      log_warning "Refusing non-file Pi settings destination at $destination"
      return 1
    }
    jq -e 'type == "object"' "$destination" >/dev/null || {
      log_warning "Existing Pi settings must be a JSON object: $destination"
      return 1
    }
    [[ "$PI_AI_RESET_MUTABLE_CONFIG" == 0 ]] && use_runtime=true
  fi

  if [[ -f "$destination" && ! -L "$destination" ]] &&
    cmp -s <(settings_candidate_contents "$source" "$destination" "$use_runtime") "$destination"; then
    log_info "Pi settings packages already match the tracked baseline at $destination"
    return 0
  fi

  if [[ "$MODE" == check ]]; then
    if [[ -L "$destination" ]]; then
      log_info "[dry-run] Would convert Pi settings to a regular file at $destination"
    elif [[ -e "$destination" ]]; then
      log_info "[dry-run] Would reconcile Pi settings packages at $destination"
    else
      log_info "[dry-run] Would install Pi settings baseline at $destination"
    fi
    return 0
  fi

  mkdir -p "$parent"
  if [[ -e "$destination" && (-L "$destination" || "$PI_AI_RESET_MUTABLE_CONFIG" == 1) ]]; then
    backup=$(backup_regular_contents "$destination" "$destination")
    log_info "Backed up Pi settings to $backup"
  fi

  raw=$(mktemp "${destination}.candidate.XXXXXX")
  settings_candidate_contents "$source" "$destination" "$use_runtime" >"$raw"
  if [[ -L "$destination" ]]; then
    rm -- "$destination"
  fi
  atomic_publish_file "$raw" "$destination" 0644
  rm -f "$raw"
  log_success "Reconciled tracked Pi packages while preserving runtime settings at $destination"
}

reconcile_private_runtime_directory() {
  local destination=$1
  if [[ -L "$destination" || (-e "$destination" && ! -d "$destination") ]]; then
    log_warning "Refusing non-directory or symlinked private Pi runtime directory at $destination"
    return 1
  fi
  if [[ "$MODE" == check ]]; then
    if [[ ! -d "$destination" ]]; then
      log_info "[dry-run] Would create private Pi runtime directory at $destination"
    fi
    return 0
  fi
  mkdir -p "$destination"
  chmod 0700 "$destination"
}

reconcile_extension_directory() {
  local destination=$1
  if [[ -L "$destination" ]]; then
    if ! is_recognized_source_link "$destination" 'ai/pi/extensions'; then
      log_warning "Refusing foreign Pi extension-directory symlink at $destination"
      return 1
    fi
    if [[ "$MODE" == check ]]; then
      log_info "[dry-run] Would convert the managed Pi extension link to a real directory: $destination"
      return 0
    fi
    rm -- "$destination"
    mkdir -p "$destination"
    log_success "Converted the Pi extension link to a real directory at $destination"
    return 0
  fi
  if [[ -e "$destination" && ! -d "$destination" ]]; then
    log_warning "Refusing non-directory Pi extensions destination at $destination"
    return 1
  fi
  if [[ ! -d "$destination" ]]; then
    if [[ "$MODE" == check ]]; then
      log_info "[dry-run] Would create Pi extensions directory at $destination"
    else
      mkdir -p "$destination"
    fi
  fi
}

is_managed_extension_name() {
  local candidate=$1 name
  for name in "${managed_extensions[@]}"; do
    [[ "$candidate" == "$name" ]] && return 0
  done
  return 1
}

is_owned_extension_target() {
  local target=$1 root
  for root in "${MANAGED_SOURCE_ROOTS[@]}"; do
    [[ "$target" == "${root%/}/ai/pi/extensions/"* ]] && return 0
  done
  return 1
}

reconcile_authored_extensions() {
  local destination=$1 entry target basename
  reconcile_extension_directory "$destination"

  if [[ -d "$destination" ]]; then
    while IFS= read -r -d '' entry; do
      target=$(readlink "$entry")
      basename=$(basename "$entry")
      if is_owned_extension_target "$target" && ! is_managed_extension_name "$basename"; then
        if [[ "$MODE" == check ]]; then
          log_info "[dry-run] Would prune retired managed Pi extension link: $entry"
        else
          rm -- "$entry"
          log_info "Pruned retired managed Pi extension link: $entry"
        fi
      fi
    done < <(find "$destination" -mindepth 1 -maxdepth 1 -type l -print0)
  fi

  for entry in "${managed_extensions[@]}"; do
    reconcile_link "$ROOT/ai/pi/extensions/$entry" "$destination/$entry" \
      "Pi extension $entry" backup "$MODE"
  done
}

reconcile_authored_directory() {
  local destination=$1 label=$2
  if [[ -L "$destination" || (-e "$destination" && ! -d "$destination") ]]; then
    log_warning "Refusing non-directory or symlinked $label at $destination"
    return 1
  fi
  if [[ "$MODE" == check ]]; then
    if [[ ! -d "$destination" ]]; then
      log_info "[dry-run] Would create $label at $destination"
    fi
    return 0
  fi
  mkdir -p "$destination"
}

reconcile_authored_links() {
  local destination="$PI_AGENT_DIR/agents" entry
  reconcile_authored_directory "$destination" "Pi agents directory"

  reconcile_link "$ROOT/ai/pi/AGENTS.md" "$PI_AGENT_DIR/AGENTS.md" \
    "Pi global AGENTS.md" backup "$MODE"
  reconcile_link "$ROOT/ai/pi/keybindings.json" "$PI_AGENT_DIR/keybindings.json" \
    "Pi keybindings" backup "$MODE"

  for entry in rush smart deep review; do
    reconcile_link "$ROOT/ai/pi/agents/$entry.md" "$destination/$entry.md" \
      "Pi agent $entry" backup "$MODE"
  done
}

install_pi() {
  mkdir -p "$HOME/.local/bin"
  npm install -g --prefix "$HOME/.local" --ignore-scripts \
    "@earendil-works/pi-coding-agent@$PI_VERSION"
}

ensure_pinned_npm_packages() {
  local pi_binary="$HOME/.local/bin/pi" specifications package_name package_version
  local package_manifest installed_version source settings_source="$PI_AGENT_DIR/settings.json"
  [[ "$MODE" == check ]] && settings_source="$ROOT/ai/pi/settings.json"
  if ! specifications=$(jq -r '
    .packages[]
    | if type == "object" then .source else . end
    | select(type == "string")
    | capture("^npm:(?<name>(?:@[^/@]+/)?[^@]+)@(?<version>[^@]+)$")
    | [.name, .version]
    | @tsv
  ' "$settings_source"); then
    log_warning "Could not enumerate pinned npm packages from Pi settings."
    return 1
  fi

  while IFS=$'\t' read -r package_name package_version; do
    [[ -n "$package_name" && -n "$package_version" ]] || continue
    package_manifest="$PI_AGENT_DIR/npm/node_modules/$package_name/package.json"
    installed_version=""
    if [[ -f "$package_manifest" && ! -L "$package_manifest" ]]; then
      installed_version=$(jq -r '.version // empty' "$package_manifest" 2>/dev/null || true)
    fi
    [[ "$installed_version" == "$package_version" ]] && continue

    source="npm:$package_name@$package_version"
    if [[ "$MODE" == check ]]; then
      log_info "[dry-run] Would install missing or mismatched pinned Pi package $source"
      continue
    fi
    PI_CODING_AGENT_DIR="$PI_AGENT_DIR" "$pi_binary" install "$source"
    if [[ ! -f "$package_manifest" || -L "$package_manifest" ]] ||
      [[ "$(jq -r '.version // empty' "$package_manifest" 2>/dev/null || true)" != "$package_version" ]]; then
      log_warning "Pi did not install the expected package version for $source"
      return 1
    fi
  done <<<"$specifications"

  if [[ "$MODE" == apply ]] && ! jq -s -e '.[0].packages == .[1].packages' \
    "$PI_AGENT_DIR/settings.json" "$ROOT/ai/pi/settings.json" >/dev/null; then
    log_warning "Pi package installation changed the tracked package inventory unexpectedly."
    return 1
  fi
}

main() {
  if [[ $# -gt 1 ]]; then
    usage >&2
    return 2
  fi
  case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  resolve_pi_paths
  assert_safe_pi_source
  migrate_pi_security_stack "$MODE" "$PI_AGENT_DIR" "$AMP_SETTINGS_PATH" \
    "${MANAGED_SOURCE_ROOTS[@]}"

  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would remove positively identified Vekil, Claude, and Codex integration remnants"
    log_info "[dry-run] Would install Pi $PI_VERSION into $HOME/.local"
  else
    cleanup_legacy_ai
    if [[ ! -x "$HOME/.local/bin/pi" ]] ||
      [[ "$("$HOME/.local/bin/pi" --version 2>/dev/null || true)" != "$PI_VERSION" ]]; then
      command_exists npm || {
        log_warning "npm is required to install Pi."
        return 1
      }
      install_pi
      log_success "Installed Pi $PI_VERSION."
    else
      log_info "Pi $PI_VERSION is already installed at $HOME/.local/bin/pi."
    fi
  fi

  reconcile_authored_extensions "$PI_AGENT_DIR/extensions"
  if [[ "$MODE" == apply ]]; then
    mkdir -p "$PI_AGENT_DIR"
  fi

  # Establish the permission boundary before removing pi-sandbox from the
  # runtime package inventory. Any unsafe or malformed policy aborts first.
  reconcile_private_runtime_directory "$PI_AGENT_DIR/extensions/pi-permission-system"
  reconcile_mutable_file "$ROOT/ai/pi/config/permission-system.json" \
    "$PI_AGENT_DIR/extensions/pi-permission-system/config.json" \
    "Pi permission policy" 0644
  reset_permission_policy_for_sandbox_retirement \
    "$ROOT/ai/pi/config/permission-system.json" \
    "$PI_AGENT_DIR/extensions/pi-permission-system/config.json" \
    "$PI_AGENT_DIR/settings.json"

  reconcile_pi_settings "$ROOT/ai/pi/settings.json" "$PI_AGENT_DIR/settings.json"
  reconcile_authored_links
  reconcile_mutable_file "$ROOT/ai/pi/config/modes.json" "$PI_AGENT_DIR/modes.json" \
    "Pi modes" 0644 'ai/pi/modes.json'
  reconcile_mutable_file "$ROOT/ai/pi/config/subagents.json" "$PI_AGENT_DIR/subagents.json" \
    "Pi subagent settings" 0600
  remove_retired_sandbox_exclusion "$PI_AGENT_DIR/subagents.json"
  reconcile_mutable_file "$ROOT/ai/pi/config/web-search.json" "$WEB_CONFIG_PATH" \
    "Pi web access settings" 0600

  ensure_pinned_npm_packages
  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would reconcile Pi packages from settings.json"
    return 0
  fi

  PI_CODING_AGENT_DIR="$PI_AGENT_DIR" "$HOME/.local/bin/pi" update --extensions
  log_success "Pi configuration and packages are ready. Run /login and choose GitHub Copilot if this machine is not authenticated."
}

main "$@"
