#!/usr/bin/env bash

set -euo pipefail

valid_migration_mode() {
  [[ "$1" == apply || "$1" == check ]]
}

retire_amp_settings_link() {
  local path=$1 mode=$2
  shift 2
  local target root recognized=false
  valid_migration_mode "$mode" || return 2

  if [[ ! -L "$path" ]]; then
    if [[ -e "$path" ]]; then
      log_warning "Preserving real Amp settings at $path"
    fi
    return 0
  fi

  target=$(readlink "$path")
  for root in "$@"; do
    if [[ "$target" == "${root%/}/ai/pi/permissions.json" ]]; then
      recognized=true
      break
    fi
  done

  if [[ "$recognized" != true ]]; then
    log_warning "Preserving foreign Amp settings symlink at $path -> $target"
    return 0
  fi
  if [[ "$mode" == check ]]; then
    log_info "[dry-run] Would remove retired managed Amp settings link at $path"
    return 0
  fi

  rm -- "$path"
  log_info "Removed retired managed Amp settings link at $path"
}

retire_amp_permissions() {
  local path=$1 mode=$2 temporary
  valid_migration_mode "$mode" || return 2
  [[ -e "$path" || -L "$path" ]] || return 0

  if [[ ! -f "$path" || -L "$path" ]] || ! jq -e 'type == "object"' "$path" >/dev/null 2>&1; then
    log_warning "Preserving malformed, non-object, or non-regular Amp state at $path"
    return 0
  fi
  if ! jq -e 'has("permissions")' "$path" >/dev/null; then
    return 0
  fi
  if [[ "$mode" == check ]]; then
    log_info "[dry-run] Would remove retired Amp permissions from $path"
    return 0
  fi

  temporary=$(mktemp "${path}.tmp.XXXXXX")
  if ! jq 'del(.permissions)' "$path" >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if jq -e 'length == 0' "$temporary" >/dev/null; then
    rm -- "$path"
    rm -f "$temporary"
    log_info "Removed Amp state after retiring its only permissions entry at $path"
    return 0
  fi

  chmod 0600 "$temporary"
  mv -f "$temporary" "$path"
  log_info "Removed retired Amp permissions while preserving other state at $path"
}

brave_skill_frontmatter_matches() {
  local skill_file=$1
  awk '
    NR == 1 {
      if ($0 != "---") exit 1
      next
    }
    $0 == "---" {
      closed = 1
      exit found ? 0 : 1
    }
    /^name:[[:space:]]*brave-search[[:space:]]*$/ { found = 1 }
    END {
      if (!closed) exit 1
    }
  ' "$skill_file"
}

quarantine_legacy_brave_skill() {
  local source=$1 destination=$2 mode=$3
  valid_migration_mode "$mode" || return 2
  [[ -e "$source" || -L "$source" ]] || return 0

  if [[ ! -d "$source" || -L "$source" || ! -f "$source/SKILL.md" ]] ||
    ! brave_skill_frontmatter_matches "$source/SKILL.md"; then
    log_warning "Preserving Brave skill candidate whose identity is not exact: $source"
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    log_warning "Preserving Brave skill because quarantine destination already exists: $destination"
    return 0
  fi
  if [[ "$mode" == check ]]; then
    log_info "[dry-run] Would quarantine retired Brave skill from $source to $destination"
    return 0
  fi

  mkdir -p "$(dirname "$destination")"
  mv -- "$source" "$destination"
  log_info "Quarantined retired Brave skill at $destination"
}

migrate_pi_security_stack() {
  local mode=$1 pi_agent_dir=$2 amp_settings_path=$3
  shift 3
  valid_migration_mode "$mode" || return 2

  retire_amp_settings_link "$amp_settings_path" "$mode" "$@"
  retire_amp_permissions "$pi_agent_dir/amplike.json" "$mode"
  quarantine_legacy_brave_skill \
    "$pi_agent_dir/skills/pi-skills/brave-search" \
    "$pi_agent_dir/disabled-skills/pi-skills-brave-search" \
    "$mode"
}
