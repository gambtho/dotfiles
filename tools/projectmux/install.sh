#!/usr/bin/env bash
# tools/projectmux/install.sh -- install the pinned ProjectMux release, its
# default configuration, and its (deliberately un-enabled) user unit.
#
# This installer owns installation policy only: which release is pinned, that
# it verifies against a committed digest, and that it lands atomically. It
# contains no workspace logic -- that is the application's job, including any
# migration of existing state.

set -euo pipefail

# shellcheck source=bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=config/versions.env
source "$DOTFILES_ROOT/config/versions.env"

PROJECTMUX_INSTALL_DIR="${PROJECTMUX_INSTALL_DIR:-$HOME/.local/bin}"
PROJECTMUX_BIN="$PROJECTMUX_INSTALL_DIR/projectmux"
PROJECTMUX_STATE_DIR="${PROJECTMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/projectmux}"
MARKER_FILE="$PROJECTMUX_STATE_DIR/installed-version"
PROJECTMUX_CONFIG_ROOT="${PROJECTMUX_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/projectmux}"
# shellcheck disable=SC2034 # consumed by install_config, added in a later task
DEFAULTS_TEMPLATE="$DOTFILES_ROOT/tools/projectmux/defaults.yaml.template"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# shellcheck disable=SC2034 # consumed by install_unit, added in a later task
UNIT_TEMPLATE="$DOTFILES_ROOT/tools/projectmux/projectmux-autostart.service"
SERVICE_UNIT="$SYSTEMD_USER_DIR/projectmux-autostart.service"
PROJECTMUX_REPOSITORY_ROOTS="${PROJECTMUX_REPOSITORY_ROOTS:-$HOME/workspace}"

# Staging paths, cleared as soon as each is published. cleanup removes whatever
# is still named here, so an interrupted run leaves no dotfile litter in
# ~/.local/bin -- and, because nothing is ever published under its final name
# until the rename, no partial file on PATH either.
STAGED_BIN=""
STAGED_MARKER=""
STAGED_CONFIG=""
STAGED_UNIT=""
DOWNLOAD_DIR=""

cleanup() {
  local path
  for path in "$STAGED_BIN" "$STAGED_MARKER" "$STAGED_CONFIG" "$STAGED_UNIT"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
  [[ -n "$DOWNLOAD_DIR" ]] && rm -rf -- "$DOWNLOAD_DIR"
  return 0
}
trap cleanup EXIT

# Upstream publishes linux/amd64 and linux/arm64 only, and the workspace
# platform this replaces is Linux-only too. Refuse rather than install
# something that cannot run.
require_platform() {
  local os arch
  os="${PROJECTMUX_OS:-$(uname -s)}"
  arch="${PROJECTMUX_ARCH:-$(uname -m)}"

  if [[ "$os" != Linux && "$os" != linux ]]; then
    printf 'ProjectMux supports Linux only; refusing to install on: %s\n' "$os" >&2
    return 1
  fi

  case "$arch" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *)
      printf 'Unsupported ProjectMux architecture: %s\n' "$arch" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$arch"
}

# Unlike ai/vekil/install.sh:273 this accepts a symlinked directory: a
# symlinked ~/.local/bin is ordinary here, and every write still goes through
# publish_file, whose mv -T refuses to descend into a directory destination.
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
# both a real directory and a symlink pointing at one. Everything else -- a
# symlink to a file, a regular file, or nothing at all -- is a legitimate
# destination that mv -Tf will replace in a single atomic step.
validate_install_target() {
  local path="$1"
  if [[ -d "$path" ]]; then
    printf 'Refusing to replace directory: %s\n' "$path" >&2
    return 1
  fi
  return 0
}

# The one way a managed file reaches its final name. -T is what makes this
# safe: without it, mv follows a symlinked destination and drops the staged
# file *inside* the target directory instead of replacing the link.
publish_file() {
  local staged="$1" destination="$2"
  validate_install_target "$destination" || return 1
  command mv -Tf "$staged" "$destination"
}

# Absent, unreadable, or a symlink -> no marker. A symlinked marker is treated
# as absent rather than followed, so a planted link cannot make the installer
# believe a version is present that is not.
#
# Only the trailing newline written by write_marker is stripped here (command
# substitution does that for free); interior whitespace is preserved verbatim
# so a local-binary marker recording a path under a space-containing directory
# round-trips unmangled.
installed_marker() {
  [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || return 1
  local value
  value=$(<"$MARKER_FILE")
  printf '%s' "$value"
}

# The marker goes through the same stage-then-rename as every other managed
# file, so a concurrent reader never sees a half-written version string.
write_marker() {
  local value="$1"
  prepare_destination_directory "$PROJECTMUX_STATE_DIR"
  STAGED_MARKER=$(mktemp "$PROJECTMUX_STATE_DIR/.installed-version.XXXXXX")
  printf '%s\n' "$value" >"$STAGED_MARKER"
  chmod 0644 "$STAGED_MARKER"
  publish_file "$STAGED_MARKER" "$MARKER_FILE"
  STAGED_MARKER=""
}

# PROJECTMUX_LOCAL_BINARY points at a developer build. It is symlinked rather
# than copied so a rebuild takes effect without re-running the installer, and
# so `test -L` alone distinguishes override mode from a pinned install.
install_local_binary() {
  local local_binary="$PROJECTMUX_LOCAL_BINARY"

  # Each refusal gets its own message: "not executable" and "is a directory"
  # send the developer to very different fixes. -d is checked before -e so a
  # directory does not fall through to the generic missing-file message.
  if [[ "$local_binary" != /* ]]; then
    printf 'PROJECTMUX_LOCAL_BINARY must be an absolute path: %s\n' "$local_binary" >&2
    return 1
  fi
  if [[ -d "$local_binary" ]]; then
    printf 'PROJECTMUX_LOCAL_BINARY is a directory: %s\n' "$local_binary" >&2
    return 1
  fi
  if [[ ! -e "$local_binary" ]]; then
    printf 'PROJECTMUX_LOCAL_BINARY does not exist: %s\n' "$local_binary" >&2
    return 1
  fi
  if [[ ! -x "$local_binary" ]]; then
    printf 'PROJECTMUX_LOCAL_BINARY is not executable: %s\n' "$local_binary" >&2
    return 1
  fi

  prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
  validate_install_target "$PROJECTMUX_BIN" || return 1

  # mktemp reserves the name by creating a regular file, and ln -s refuses to
  # write over an existing path, so the reservation has to be released before
  # the link is made. The window is inside the destination directory and under
  # a dot-prefixed name, never at the published name on PATH.
  STAGED_BIN=$(mktemp "$PROJECTMUX_INSTALL_DIR/.projectmux.XXXXXX")
  rm -f "$STAGED_BIN"
  ln -s "$local_binary" "$STAGED_BIN"
  publish_file "$STAGED_BIN" "$PROJECTMUX_BIN"
  STAGED_BIN=""

  write_marker "local:$local_binary"
  log_success "Using local ProjectMux build at $local_binary (pin unchanged)."
}

install_binary() {
  local arch="$1"
  if [[ -n "${PROJECTMUX_LOCAL_BINARY:-}" ]]; then
    install_local_binary
  else
    install_pinned_binary "$arch"
  fi
}

report_plan() {
  printf 'ProjectMux install plan:\n'
  printf '  version:    %s\n' "$PROJECTMUX_VERSION"
  printf '  binary:     %s\n' "$PROJECTMUX_BIN"
  printf '  state:      %s\n' "$PROJECTMUX_STATE_DIR"
  printf '  config:     %s\n' "$PROJECTMUX_CONFIG_ROOT"
  printf '  unit:       %s (written, not enabled)\n' "$SERVICE_UNIT"
  printf '  installed:  %s\n' "$(installed_marker || printf '(none)')"
  if [[ -n "${PROJECTMUX_LOCAL_BINARY:-}" ]]; then
    printf '  override:   %s (pin unchanged)\n' "$PROJECTMUX_LOCAL_BINARY"
  fi
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    report_plan
    return 0
  fi

  # Split from the assignment on purpose: `local arch=$(...)` takes the exit
  # status of `local`, not of the command, so the platform refusal would be
  # swallowed and the install would continue on an unsupported host.
  local arch
  arch=$(require_platform)

  install_binary "$arch"
  install_config
  install_unit
}

if [[ "${PROJECTMUX_INSTALL_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
