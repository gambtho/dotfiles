#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VEKIL_VERSION="${VEKIL_VERSION:-v0.13.3}"
INSTALL_DIR="${VEKIL_INSTALL_DIR:-$HOME/.local/bin}"
STATE_DIR="${VEKIL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vekil}"
VEKIL_BIN="${VEKIL_BIN:-$INSTALL_DIR/vekil}"
VERSION_FILE="$STATE_DIR/installed-version"
RESTART_REQUIRED_FILE="$STATE_DIR/restart-required"
RELEASE_BASE="https://github.com/sozercan/vekil/releases/download/$VEKIL_VERSION"
TOKEN_DIR="${VEKIL_TOKEN_DIR:-$HOME/.config/vekil}"
ACCESS_TOKEN_FILE="$TOKEN_DIR/access-token"
LIFECYCLE_BIN="$DOTFILES_ROOT/bin/vekil-proxy"
DOWNLOAD_DIR=""
STAGED_BIN=""
STAGED_VERSION=""
STAGED_RESTART_REQUIRED=""
VEKIL_CHANGED=0
AUTH_CHANGED=0

cleanup() {
  [[ -z "$DOWNLOAD_DIR" ]] || rm -rf "$DOWNLOAD_DIR"
  [[ -z "$STAGED_BIN" ]] || rm -f "$STAGED_BIN"
  [[ -z "$STAGED_VERSION" ]] || rm -f "$STAGED_VERSION"
  [[ -z "$STAGED_RESTART_REQUIRED" ]] || rm -f "$STAGED_RESTART_REQUIRED"
}

trap cleanup EXIT

detect_platform() {
  local os arch
  os="${VEKIL_OS:-$(uname -s)}"
  arch="${VEKIL_ARCH:-$(uname -m)}"

  case "$os" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) log_error "Unsupported Vekil operating system: $os" >&2 ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) log_error "Unsupported Vekil architecture: $arch" >&2 ;;
  esac

  printf '%s %s\n' "$os" "$arch"
}

calculate_checksum() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    log_error "Neither sha256sum nor shasum is available." >&2
  fi
}

installed_version() {
  [[ -x "$VEKIL_BIN" && -f "$VERSION_FILE" ]] || return 1
  tr -d '[:space:]' < "$VERSION_FILE"
}

validate_regular_target() {
  local path="$1"

  [[ -e "$path" || -L "$path" ]] || return 0
  [[ ! -L "$path" && -f "$path" ]] || {
    printf 'Vekil destination must be absent or a regular file: %s\n' "$path" >&2
    return 1
  }
}

prepare_destination_directory() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    [[ ! -L "$path" && -d "$path" ]] || {
      printf 'Vekil destination parent must be a real directory: %s\n' "$path" >&2
      return 1
    }
  else
    mkdir -p "$path"
  fi

  [[ ! -L "$path" && -d "$path" ]] || {
    printf 'Vekil destination parent must be a real directory: %s\n' "$path" >&2
    return 1
  }
}

persist_restart_required() {
  validate_regular_target "$RESTART_REQUIRED_FILE"
  STAGED_RESTART_REQUIRED=$(mktemp "$STATE_DIR/.restart-required.XXXXXX")
  printf '%s\n' "$VEKIL_VERSION" > "$STAGED_RESTART_REQUIRED"
  validate_regular_target "$RESTART_REQUIRED_FILE"
  command mv -f "$STAGED_RESTART_REQUIRED" "$RESTART_REQUIRED_FILE"
  STAGED_RESTART_REQUIRED=""
}

clear_restart_required() {
  validate_regular_target "$RESTART_REQUIRED_FILE"
  rm -f "$RESTART_REQUIRED_FILE"
}

require_lifecycle_helper() {
  [[ "${VEKIL_SKIP_START:-0}" == "1" ]] && return 0
  [[ -x "$LIFECYCLE_BIN" ]] || {
    printf 'Vekil lifecycle helper is missing or not executable: %s\n' "$LIFECYCLE_BIN" >&2
    return 1
  }
}

prepare_token_directory() {
  if [[ -e "$TOKEN_DIR" || -L "$TOKEN_DIR" ]]; then
    [[ ! -L "$TOKEN_DIR" && -d "$TOKEN_DIR" ]] || {
      printf 'Vekil token directory must be a real directory: %s\n' "$TOKEN_DIR" >&2
      return 1
    }
  else
    (umask 077; mkdir -p "$TOKEN_DIR")
  fi

  [[ ! -L "$TOKEN_DIR" && -d "$TOKEN_DIR" ]] || {
    printf 'Vekil token directory must be a real directory: %s\n' "$TOKEN_DIR" >&2
    return 1
  }
  chmod 0700 "$TOKEN_DIR"
}

validate_access_token() {
  [[ -e "$ACCESS_TOKEN_FILE" || -L "$ACCESS_TOKEN_FILE" ]] || return 0
  [[ ! -L "$ACCESS_TOKEN_FILE" && -f "$ACCESS_TOKEN_FILE" ]] || {
    printf 'Vekil access token must be absent or a regular file: %s\n' "$ACCESS_TOKEN_FILE" >&2
    return 1
  }

  chmod 0600 "$ACCESS_TOKEN_FILE"
  [[ ! -L "$ACCESS_TOKEN_FILE" && -f "$ACCESS_TOKEN_FILE" ]] || {
    printf 'Vekil access token must be a regular file: %s\n' "$ACCESS_TOKEN_FILE" >&2
    return 1
  }
}

require_nonempty_access_token() {
  [[ ! -L "$ACCESS_TOKEN_FILE" && -f "$ACCESS_TOKEN_FILE" && -s "$ACCESS_TOKEN_FILE" ]] || {
    printf 'Vekil login did not create a nonempty access token: %s\n' "$ACCESS_TOKEN_FILE" >&2
    return 1
  }
}

install_vekil() {
  VEKIL_CHANGED=0

  local platform os arch asset expected actual bin_dir
  bin_dir=$(dirname "$VEKIL_BIN")
  prepare_destination_directory "$bin_dir"
  prepare_destination_directory "$STATE_DIR"
  validate_regular_target "$VEKIL_BIN"
  validate_regular_target "$VERSION_FILE"
  validate_regular_target "$RESTART_REQUIRED_FILE"

  if [[ "$(installed_version 2>/dev/null || true)" == "$VEKIL_VERSION" ]]; then
    log_info "Vekil $VEKIL_VERSION is already installed at $VEKIL_BIN."
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    log_error "curl is required to install Vekil." >&2
  }

  platform=$(detect_platform)
  read -r os arch <<<"$platform"
  asset="vekil-${os}-${arch}"
  DOWNLOAD_DIR=$(mktemp -d)

  log_info "Downloading Vekil $VEKIL_VERSION for $os/$arch..."
  curl -fsSL --retry 3 "$RELEASE_BASE/$asset" -o "$DOWNLOAD_DIR/$asset"
  curl -fsSL --retry 3 "$RELEASE_BASE/checksums.txt" -o "$DOWNLOAD_DIR/checksums.txt"

  expected=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$DOWNLOAD_DIR/checksums.txt")
  [[ -n "$expected" ]] || {
    log_error "No checksum was published for $asset." >&2
  }

  actual=$(calculate_checksum "$DOWNLOAD_DIR/$asset")
  [[ "$actual" == "$expected" ]] || {
    printf 'Checksum mismatch for %s.\n' "$asset" >&2
    printf 'Expected: %s\n' "$expected" >&2
    printf 'Actual:   %s\n' "$actual" >&2
    return 1
  }

  STAGED_BIN=$(mktemp "$bin_dir/.vekil.XXXXXX")
  STAGED_VERSION=$(mktemp "$STATE_DIR/.installed-version.XXXXXX")
  command cp "$DOWNLOAD_DIR/$asset" "$STAGED_BIN"
  command chmod 0755 "$STAGED_BIN"
  printf '%s\n' "$VEKIL_VERSION" > "$STAGED_VERSION"

  prepare_destination_directory "$bin_dir"
  prepare_destination_directory "$STATE_DIR"
  validate_regular_target "$VEKIL_BIN"
  validate_regular_target "$VERSION_FILE"
  persist_restart_required
  prepare_destination_directory "$bin_dir"
  prepare_destination_directory "$STATE_DIR"
  validate_regular_target "$VEKIL_BIN"
  validate_regular_target "$VERSION_FILE"
  command mv -f "$STAGED_BIN" "$VEKIL_BIN"
  STAGED_BIN=""
  command mv -f "$STAGED_VERSION" "$VERSION_FILE"
  STAGED_VERSION=""
  VEKIL_CHANGED=1
  rm -rf "$DOWNLOAD_DIR"
  DOWNLOAD_DIR=""
  log_success "Installed Vekil $VEKIL_VERSION at $VEKIL_BIN."
}

authenticate_vekil() {
  AUTH_CHANGED=0
  [[ "${VEKIL_SKIP_AUTH:-0}" == "1" ]] && return 0

  prepare_token_directory
  validate_access_token

  local -a login_args=(login --token-dir "$TOKEN_DIR")
  local forced_auth=0
  if [[ -s "$ACCESS_TOKEN_FILE" ]]; then
    log_info "Refreshing Vekil-managed authentication..."
  else
    log_info "Creating Vekil-managed authentication..."
    login_args+=(--force)
    forced_auth=1
  fi

  if ! (umask 077; "$VEKIL_BIN" "${login_args[@]}"); then
    printf 'Vekil authentication failed for token directory: %s\n' "$TOKEN_DIR" >&2
    return 1
  fi

  prepare_token_directory
  validate_access_token
  require_nonempty_access_token
  if [[ "$forced_auth" == "1" ]]; then
    persist_restart_required
    AUTH_CHANGED=1
  fi
}

start_vekil() {
  [[ "${VEKIL_SKIP_START:-0}" == "1" ]] && return 0

  local action="start"
  local -a lifecycle_env=(
    "VEKIL_BIN=$VEKIL_BIN"
    "VEKIL_STATE_DIR=$STATE_DIR"
    "VEKIL_TOKEN_DIR=$TOKEN_DIR"
  )

  validate_regular_target "$RESTART_REQUIRED_FILE"
  [[ "$VEKIL_CHANGED" == "0" && "$AUTH_CHANGED" == "0" && ! -f "$RESTART_REQUIRED_FILE" ]] || action="restart"
  [[ -z "${VEKIL_PORT+x}" ]] || lifecycle_env+=("VEKIL_PORT=$VEKIL_PORT")
  command env "${lifecycle_env[@]}" "$LIFECYCLE_BIN" "$action"
  [[ "$action" != "restart" ]] || clear_restart_required
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    local platform os arch
    platform=$(detect_platform)
    read -r os arch <<<"$platform"
    log_info "[dry-run] Would install $VEKIL_VERSION asset vekil-${os}-${arch} to $VEKIL_BIN"
    log_info "[dry-run] Would authenticate Vekil using token directory $TOKEN_DIR and start it through bin/vekil-proxy"
    return 0
  fi

  require_lifecycle_helper
  log_info "Setting up Vekil..."
  install_vekil
  authenticate_vekil
  start_vekil
  log_success "Vekil setup complete."
}

main "$@"
