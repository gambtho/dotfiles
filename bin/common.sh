#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/log-helper"

PHASE_FAILURES=()
PHASE_WARNINGS=()

run_phase() {
  local requirement="$1"
  local name="$2"
  shift 2

  log_info "Starting phase: $name"
  if "$@"; then
    log_success "Completed phase: $name"
    return 0
  fi

  if [[ "$requirement" == required ]]; then
    PHASE_FAILURES+=("$name")
    printf 'Required phase failed: %s\n' "$name" >&2
  else
    PHASE_WARNINGS+=("$name")
    log_warning "Optional phase failed: $name"
  fi
  return 0
}

finish_phases() {
  local name
  for name in "${PHASE_WARNINGS[@]}"; do
    printf 'WARNING: %s\n' "$name"
  done
  for name in "${PHASE_FAILURES[@]}"; do
    printf 'FAILED: %s\n' "$name" >&2
  done
  ((${#PHASE_FAILURES[@]} == 0))
}

require_remote_installers() {
  if [[ "${ALLOW_REMOTE_INSTALLERS:-0}" != 1 ]]; then
    printf '%s\n' "Remote installer execution is disabled. Re-run with ALLOW_REMOTE_INSTALLERS=1 after reviewing the installer source." >&2
    return 1
  fi
}

run_remote_installer() {
  local url="$1"
  local script
  local status
  local argument_index
  local script_placed=false
  local -a command
  shift

  if (($# == 0)); then
    printf 'Remote installer command is required for %s.\n' "$url" >&2
    return 1
  fi
  command=("$@")

  require_remote_installers || return 1
  script=$(mktemp) || return 1

  if ! curl --fail --show-error --location "$url" --output "$script"; then
    rm -f "$script"
    return 1
  fi

  for argument_index in "${!command[@]}"; do
    if [[ "${command[$argument_index]}" == "{}" ]]; then
      command[argument_index]="$script"
      script_placed=true
    fi
  done
  if [[ "$script_placed" != true ]]; then
    command+=("$script")
  fi

  if "${command[@]}"; then
    status=0
  else
    status=$?
  fi
  rm -f "$script"
  return "$status"
}

# Check if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Function to detect the operating system
detect_os() {
  case "$(uname)" in
    Darwin)
      OS="macOS"
      ;;
    Linux)
      if grep -qE "(Microsoft|WSL)" /proc/version &>/dev/null; then
        OS="WSL"
      elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" == "ubuntu" ]; then
          OS="Ubuntu"
        else
          #OS=$NAME
          OS="Unsupported"
        fi
      else
        OS="Unsupported"
        #OS="Linux"
      fi
      ;;
    *)
      OS="Unsupported"
      ;;
  esac
  export OS
  # echo "Detected OS: $OS"
}
