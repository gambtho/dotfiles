#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/log-helper"

COMMON_DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

PHASE_FAILURES=()
PHASE_WARNINGS=()
CURL_DOWNLOAD_ARGS=(
  --fail
  --show-error
  --location
  --connect-timeout 10
  --max-time 120
  --retry 3
)

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

next_backup_path() {
  local destination="$1"
  local candidate="${destination}.backup"
  local timestamp suffix=0

  if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  candidate="${destination}.backup.${timestamp}"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="${destination}.backup.${timestamp}.${suffix}"
  done
  printf '%s\n' "$candidate"
}

link_policy_for_action() {
  case "$1" in
    s) printf '%s\n' skip ;;
    S) printf '%s\n' skip-all ;;
    o) printf '%s\n' replace ;;
    O) printf '%s\n' replace-all ;;
    b) printf '%s\n' backup ;;
    B) printf '%s\n' backup-all ;;
    *) printf '%s\n' skip ;;
  esac
}

prompt_link_policy() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local action

  log_warning "$label already exists at $destination (source: $source)." >&2
  printf '%s' '[s]kip, [S]kip all, [o]verwrite, [O]verwrite all, [b]ackup, [B]ackup all? ' >&2
  IFS= read -r -n 1 action </dev/tty || action=s
  printf '\n' >&2
  link_policy_for_action "$action"
}

reconcile_link() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local policy="$4"
  local mode="$5"
  local backup moved_to="" keep_backup=false

  [[ "$policy" == skip || "$policy" == replace || "$policy" == backup ]] || return 2
  [[ "$mode" == apply || "$mode" == check ]] || return 2

  if [[ -L "$destination" && "$(readlink "$destination")" == "$source" ]]; then
    log_info "$label already linked."
    return 0
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    case "$policy" in
      skip)
        log_info "Skipped $label at $destination"
        return 0
        ;;
      replace)
        if [[ "$mode" == check ]]; then
          log_info "[dry-run] Would replace $label at $destination"
          return 0
        fi
        moved_to=$(next_backup_path "$destination")
        mv -- "$destination" "$moved_to" || return
        ;;
      backup)
        backup=$(next_backup_path "$destination")
        if [[ "$mode" == check ]]; then
          log_info "[dry-run] Would back up $label to $backup"
          return 0
        fi
        mv -- "$destination" "$backup" || return
        moved_to=$backup
        keep_backup=true
        ;;
    esac
  elif [[ "$mode" == check ]]; then
    log_info "[dry-run] Would link $source -> $destination"
    return 0
  fi

  if ! ln -s -- "$source" "$destination"; then
    if [[ -n "$moved_to" && ! -e "$destination" && ! -L "$destination" ]]; then
      mv -- "$moved_to" "$destination" || true
    fi
    return 1
  fi
  if [[ -n "$moved_to" && "$keep_backup" != true ]]; then
    rm -rf -- "$moved_to"
  fi
  log_success "Linked $source to $destination"
}

require_remote_installers() {
  if [[ "${ALLOW_REMOTE_INSTALLERS:-0}" != 1 ]]; then
    printf '%s\n' "Remote installer execution is disabled. Re-run with ALLOW_REMOTE_INSTALLERS=1 after reviewing the installer source." >&2
    return 1
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download_verified_artifact() {
  local url="$1"
  local expected="$2"
  local destination="$3"
  local mode="${4:-0644}"
  local temporary actual

  temporary=$(mktemp "${destination}.download.XXXXXX") || return 1
  if ! curl "${CURL_DOWNLOAD_ARGS[@]}" "$url" --output "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  actual=$(sha256_file "$temporary")
  if [[ "$actual" != "$expected" ]]; then
    printf 'checksum mismatch for %s: expected %s, got %s\n' "$url" "$expected" "$actual" >&2
    rm -f -- "$temporary"
    return 1
  fi
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$destination"
}

install_pinned_mise() {
  local destination="$1"
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest
  # shellcheck source=config/versions.env
  source "$COMMON_DOTFILES_ROOT/config/versions.env"

  case "$arch" in
    x86_64)
      asset="mise-${MISE_VERSION}-linux-x64"
      digest="$MISE_LINUX_X64_SHA256"
      ;;
    aarch64 | arm64)
      asset="mise-${MISE_VERSION}-linux-arm64"
      digest="$MISE_LINUX_ARM64_SHA256"
      ;;
    *)
      printf 'unsupported architecture for mise install: %s\n' "$arch" >&2
      return 2
      ;;
  esac
  mkdir -p "$(dirname "$destination")"
  download_verified_artifact "$MISE_RELEASE_BASE/$asset" "$digest" "$destination" 0755
}

install_pinned_yq() {
  local destination="$1"
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest
  # shellcheck source=config/versions.env
  source "$COMMON_DOTFILES_ROOT/config/versions.env"

  case "$arch" in
    x86_64)
      asset=yq_linux_amd64
      digest="$YQ_LINUX_AMD64_SHA256"
      ;;
    aarch64 | arm64)
      asset=yq_linux_arm64
      digest="$YQ_LINUX_ARM64_SHA256"
      ;;
    *)
      printf 'unsupported architecture for yq install: %s\n' "$arch" >&2
      return 2
      ;;
  esac
  mkdir -p "$(dirname "$destination")"
  download_verified_artifact "$YQ_RELEASE_BASE/$asset" "$digest" "$destination" 0755
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

  if ! curl "${CURL_DOWNLOAD_ARGS[@]}" "$url" --output "$script"; then
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

validate_vekil_access_token() {
  local access_token_file="$1"
  [[ -e "$access_token_file" || -L "$access_token_file" ]] || return 0
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be absent or a regular file: %s\n' "$access_token_file" >&2
    return 1
  }

  chmod 0600 "$access_token_file" || return 1
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be a regular file: %s\n' "$access_token_file" >&2
    return 1
  }
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
