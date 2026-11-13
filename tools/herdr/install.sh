#!/usr/bin/env bash
# tools/herdr/install.sh -- install the pinned Herdr release and its default
# configuration.
#
# This installer owns installation policy only: which release is pinned, that
# it verifies against a committed digest, and that it lands atomically.
#
# Herdr ships its own updater (`herdr update`, `herdr channel set`) and checks
# herdr.dev in the background. That fights a committed pin: a background update
# would move the binary out from under the digest this repo records, so the
# shipped config turns version_check off. Normal install/update reports release
# drift without upgrading; `make pins-check` checks all pins. Update checksums
# manually after checksum review to move the Herdr pin.

set -euo pipefail

# shellcheck source=libexec/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../libexec/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=config/versions.env
source "$DOTFILES_ROOT/config/versions.env"

HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-$HOME/.local/bin}"
HERDR_BIN="$HERDR_INSTALL_DIR/herdr"
HERDR_STATE_ROOT="${HERDR_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr}"
MARKER_FILE="$HERDR_STATE_ROOT/installed-version"
# Herdr resolves its own config directory to ~/.config/herdr and keeps runtime
# state there too -- sockets, logs, and session.json. That is why this is a
# rendered copy rather than a config/herdr/ directory symlink: libexec/relink would
# point the whole directory into the repo and herdr would write live sockets
# and logs into a git checkout.
HERDR_CONFIG_ROOT="${HERDR_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr}"
CONFIG_TEMPLATE="${HERDR_CONFIG_TEMPLATE:-$DOTFILES_ROOT/tools/herdr/config.toml.template}"

STAGED_BIN=""
STAGED_MARKER=""
STAGED_CONFIG=""
DOWNLOAD_DIR=""
STAGED_DASHBOARD=""
STAGED_LANES=""
STAGED_LINK=""

cleanup() {
  local path
  for path in "$STAGED_BIN" "$STAGED_MARKER" "$STAGED_CONFIG" "$STAGED_LINK"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
  [[ -n "$DOWNLOAD_DIR" ]] && rm -rf -- "$DOWNLOAD_DIR"
  [[ -n "$STAGED_DASHBOARD" ]] && rm -rf -- "$STAGED_DASHBOARD"
  [[ -n "$STAGED_LANES" ]] && rm -rf -- "$STAGED_LANES"
  return 0
}
trap cleanup EXIT

# Upstream also publishes macOS assets, but this repo installs Herdr on Linux
# only: the machines that run it are WSL2, and an untested darwin path is worse
# than an honest refusal. macOS would come through platforms/macos/brewfile.
require_platform() {
  local os arch
  os="${HERDR_OS:-$(uname -s)}"
  arch="${HERDR_ARCH:-$(uname -m)}"

  if [[ "$os" != Linux && "$os" != linux ]]; then
    printf 'Herdr is installed on Linux only here; refusing to install on: %s\n' "$os" >&2
    return 1
  fi

  # Upstream names its assets by uname arch (herdr-linux-x86_64), so both
  # spellings normalise to the uname form rather than to amd64/arm64.
  case "$arch" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *)
      printf 'Unsupported Herdr architecture: %s\n' "$arch" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$arch"
}

prepare_destination_directory() {
  local dir="$1"
  if [[ -e "$dir" || -L "$dir" ]]; then
    if [[ ! -d "$dir" ]]; then
      printf 'Refusing to install into %s: not a directory.\n' "$dir" >&2
      return 1
    fi
    return 0
  fi
  mkdir -p "$dir"
}

# -d is checked first and on its own: it follows symlinks, so one test covers
# both a real directory and a symlink pointing at one.
validate_install_target() {
  local path="$1"
  if [[ -d "$path" ]]; then
    printf 'Refusing to replace directory: %s\n' "$path" >&2
    return 1
  fi
  return 0
}

# Herdr's install policy (refuse directories, replace a symlinked destination)
# over the shared rename primitive; the -T rationale lives with
# publish_staged_file in libexec/common.sh.
publish_file() {
  local staged="$1" destination="$2"
  validate_install_target "$destination" || return 1
  publish_staged_file "$staged" "$destination"
}

# A symlinked marker is treated as absent rather than followed, so a planted
# link cannot make the installer believe a version is present that is not.
installed_marker() {
  [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || return 1
  local value
  value=$(<"$MARKER_FILE")
  printf '%s' "$value"
}

write_marker() {
  local value="$1"
  prepare_destination_directory "$HERDR_STATE_ROOT"
  STAGED_MARKER=$(mktemp "$HERDR_STATE_ROOT/.installed-version.XXXXXX")
  printf '%s\n' "$value" >"$STAGED_MARKER"
  chmod 0644 "$STAGED_MARKER"
  publish_file "$STAGED_MARKER" "$MARKER_FILE"
  STAGED_MARKER=""
}

install_pinned_binary() {
  local arch="$1" asset digest bin_dir
  bin_dir=$(dirname "$HERDR_BIN")

  case "$arch" in
    x86_64)
      asset="herdr-linux-x86_64"
      digest="$HERDR_LINUX_X86_64_SHA256"
      ;;
    aarch64)
      asset="herdr-linux-aarch64"
      digest="$HERDR_LINUX_AARCH64_SHA256"
      ;;
    *) log_error "Unsupported Herdr architecture: $arch" ;;
  esac

  prepare_destination_directory "$bin_dir"
  prepare_destination_directory "$HERDR_STATE_ROOT"
  validate_install_target "$HERDR_BIN"

  # Both halves are load-bearing. The binary and the marker are published by
  # two separate renames, so an interrupted run can pair one version's binary
  # with another's marker; requiring a regular file at the destination means
  # such a pair fails the test and the next run repairs it without a lock.
  if [[ "$(installed_marker || true)" == "$HERDR_VERSION" ]] &&
    [[ -f "$HERDR_BIN" && ! -L "$HERDR_BIN" ]]; then
    log_info "Herdr $HERDR_VERSION is already installed at $HERDR_BIN."
    return 0
  fi

  command -v curl >/dev/null 2>&1 || log_error "curl is required to install Herdr."

  DOWNLOAD_DIR=$(mktemp -d)
  log_info "Downloading Herdr $HERDR_VERSION for linux/$arch..."
  download_verified_artifact "$HERDR_RELEASE_BASE/$asset" "$digest" "$DOWNLOAD_DIR/$asset" 0755

  STAGED_BIN=$(mktemp "$bin_dir/.herdr.XXXXXX")
  command cp "$DOWNLOAD_DIR/$asset" "$STAGED_BIN"
  command chmod 0755 "$STAGED_BIN"

  validate_install_target "$HERDR_BIN"
  publish_file "$STAGED_BIN" "$HERDR_BIN"
  STAGED_BIN=""

  # Only after the binary is in place. An install interrupted before this point
  # leaves the old marker, so the next run reinstalls rather than believing a
  # partial install succeeded.
  write_marker "$HERDR_VERSION"

  rm -rf -- "$DOWNLOAD_DIR"
  DOWNLOAD_DIR=""
  log_success "Installed Herdr $HERDR_VERSION at $HERDR_BIN."
}

install_config() {
  local config="$HERDR_CONFIG_ROOT/config.toml"

  prepare_destination_directory "$HERDR_CONFIG_ROOT"

  STAGED_CONFIG=$(mktemp "$HERDR_CONFIG_ROOT/.config.toml.XXXXXX")
  command cp "$CONFIG_TEMPLATE" "$STAGED_CONFIG"
  chmod 0644 "$STAGED_CONFIG"

  if [[ ! -e "$config" && ! -L "$config" ]]; then
    publish_file "$STAGED_CONFIG" "$config"
    STAGED_CONFIG=""
    log_success "Installed Herdr config at $config."
    return 0
  fi

  # The config is machine-local state the user owns -- it also holds keybindings
  # and per-machine tweaks. Report drift and move on: overwriting would silently
  # discard a hand edit, and failing would make an edited config break every
  # unrelated phase of bin/dot-install.
  if ! cmp -s "$STAGED_CONFIG" "$config"; then
    log_warning "$config differs from the shipped defaults; leaving it as-is."
  fi
  rm -f -- "$STAGED_CONFIG"
  STAGED_CONFIG=""
  return 0
}

refresh_config() {
  local config="$HERDR_CONFIG_ROOT/config.toml" backup
  prepare_destination_directory "$HERDR_CONFIG_ROOT"
  if [[ -L "$config" || (-e "$config" && ! -f "$config") ]]; then
    printf 'Refusing to refresh non-regular config: %s\n' "$config" >&2
    return 1
  fi
  if [[ -f "$config" ]] && cmp -s "$CONFIG_TEMPLATE" "$config"; then
    log_info "Herdr config already matches $CONFIG_TEMPLATE."
    return 0
  fi
  STAGED_CONFIG=$(mktemp "$HERDR_CONFIG_ROOT/.config.toml.XXXXXX")
  command cp "$CONFIG_TEMPLATE" "$STAGED_CONFIG"
  chmod 0644 "$STAGED_CONFIG"
  if [[ -f "$config" ]]; then
    backup=$(mktemp "$config.backup.XXXXXX")
    command cp "$config" "$backup"
    chmod 0600 "$backup"
    log_info "Herdr config backup: $backup"
  fi
  publish_file "$STAGED_CONFIG" "$config"
  STAGED_CONFIG=""
  log_success "Refreshed Herdr config. Apply with: herdr server reload-config"
}

install_dashboard() {
  local source="$DOTFILES_ROOT/tools/herdr/dashboard"
  local root="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles" digest version destination
  # Versioned copies keep the Python and manifest coherent across updates. The
  # public link switches atomically; an open pane keeps its loaded version.
  digest=$(cd "$source" && sha256sum dashboard.py herdr-plugin.toml | sha256sum | cut -d ' ' -f 1)
  prepare_destination_directory "$root"
  version="$root/.herdr-dashboard-$digest"
  destination="$root/herdr-dashboard"
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    printf 'Refusing to replace non-symlink dashboard path: %s\n' "$destination" >&2
    return 1
  fi
  if [[ ! -d "$version" ]]; then
    STAGED_DASHBOARD=$(mktemp -d "$root/.dashboard.XXXXXX")
    command cp "$source/dashboard.py" "$source/herdr-plugin.toml" "$STAGED_DASHBOARD/"
    chmod 0755 "$STAGED_DASHBOARD/dashboard.py"
    chmod 0644 "$STAGED_DASHBOARD/herdr-plugin.toml"
    command mv -T -- "$STAGED_DASHBOARD" "$version"
    STAGED_DASHBOARD=""
  fi
  STAGED_LINK=$(mktemp "$root/.dashboard-link.XXXXXX")
  rm -f -- "$STAGED_LINK"
  ln -s "$version" "$STAGED_LINK"
  publish_staged_file "$STAGED_LINK" "$destination"
  STAGED_LINK=""
  "$HERDR_BIN" plugin link "$destination" --enabled
  log_success "Dashboard copy installed at $destination."
}

install_lanes() {
  local source="$DOTFILES_ROOT/tools/herdr/lanes"
  local root="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles" digest version destination path
  local lane="$HERDR_INSTALL_DIR/lane"
  destination="$root/herdr-lanes"
  # Refuse both public-path conflicts before publishing either link.
  for path in "$destination" "$lane"; do
    if [[ -e "$path" && ! -L "$path" ]]; then
      printf 'Refusing to replace non-symlink lanes path: %s\n' "$path" >&2
      return 1
    fi
  done
  digest=$(cd "$source" && sha256sum lane.py needs.py dashboard-open.py | sha256sum | cut -d ' ' -f 1)
  prepare_destination_directory "$root"
  prepare_destination_directory "$HERDR_INSTALL_DIR"
  version="$root/.herdr-lanes-$digest"
  # Copy one coherent runtime; keep older versions for already-running commands.
  if [[ ! -d "$version" ]]; then
    STAGED_LANES=$(mktemp -d "$root/.lanes.XXXXXX")
    command cp "$source/lane.py" "$source/needs.py" "$source/dashboard-open.py" "$STAGED_LANES/"
    chmod 0755 "$STAGED_LANES/lane.py"
    chmod 0644 "$STAGED_LANES/needs.py" "$STAGED_LANES/dashboard-open.py"
    command mv -T -- "$STAGED_LANES" "$version"
    STAGED_LANES=""
  fi
  STAGED_LINK=$(mktemp "$root/.lanes-link.XXXXXX")
  rm -f -- "$STAGED_LINK"
  ln -s "$version" "$STAGED_LINK"
  # This target is a directory symlink: always replace the link itself. Like
  # the version-directory rename above, this Linux installer requires mv -T.
  command mv -Tf -- "$STAGED_LINK" "$destination"
  STAGED_LINK=""
  STAGED_LINK=$(mktemp "$HERDR_INSTALL_DIR/.lane-link.XXXXXX")
  rm -f -- "$STAGED_LINK"
  ln -s "$destination/lane.py" "$STAGED_LINK"
  publish_staged_file "$STAGED_LINK" "$lane"
  STAGED_LINK=""
  log_success "Lane runtime copy installed at $destination; command at $lane."
}

report_plan() {
  printf 'Herdr install plan:\n'
  printf '  version:    %s\n' "$HERDR_VERSION"
  printf '  binary:     %s\n' "$HERDR_BIN"
  printf '  state:      %s\n' "$HERDR_STATE_ROOT"
  printf '  config:     %s\n' "$HERDR_CONFIG_ROOT/config.toml"
  printf '  installed:  %s\n' "$(installed_marker || printf '(none)')"
}

main() {
  if (($# > 1)); then
    printf 'Usage: install.sh [--check|--refresh-config|--install-dashboard|--install-lanes]\n' >&2
    return 2
  fi
  case "${1:-}" in
    --check)
      report_plan
      return 0
      ;;
    --refresh-config)
      refresh_config
      return
      ;;
    --install-dashboard)
      require_platform >/dev/null
      install_dashboard
      return
      ;;
    --install-lanes)
      require_platform >/dev/null
      install_lanes
      return
      ;;
    '') ;;
    *)
      printf 'Unknown Herdr install mode: %s\n' "$1" >&2
      return 2
      ;;
  esac

  # Split from the assignment on purpose: `local arch=$(...)` takes the exit
  # status of `local`, not of the command, so the platform refusal would be
  # swallowed and the install would continue on an unsupported host.
  local arch
  arch=$(require_platform)

  install_pinned_binary "$arch"
  install_config
}

if [[ "${HERDR_INSTALL_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
