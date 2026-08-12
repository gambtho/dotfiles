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
# shipped config turns version_check off and `bin/versions check` becomes the
# one place a new release is noticed. Run `make pins-update` to move the pin.

set -euo pipefail

# shellcheck source=bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=config/versions.env
source "$DOTFILES_ROOT/config/versions.env"

HERDR_INSTALL_DIR="${HERDR_INSTALL_DIR:-$HOME/.local/bin}"
HERDR_BIN="$HERDR_INSTALL_DIR/herdr"
HERDR_STATE_ROOT="${HERDR_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr}"
MARKER_FILE="$HERDR_STATE_ROOT/installed-version"
# Herdr resolves its own config directory to ~/.config/herdr and keeps runtime
# state there too -- sockets, logs, and session.json. That is why this is a
# rendered copy rather than a config/herdr/ directory symlink: bin/relink would
# point the whole directory into the repo and herdr would write live sockets
# and logs into a git checkout.
HERDR_CONFIG_ROOT="${HERDR_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr}"
CONFIG_TEMPLATE="$DOTFILES_ROOT/tools/herdr/config.toml.template"
# The shipped config binds prefix+d and prefix+shift+s to this plugin's actions,
# so a machine with the config but not the plugin has two dead keys.
HERDR_PLUGIN_ID="devcontainer"

STAGED_BIN=""
STAGED_MARKER=""
STAGED_CONFIG=""
DOWNLOAD_DIR=""

cleanup() {
  local path
  for path in "$STAGED_BIN" "$STAGED_MARKER" "$STAGED_CONFIG"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
  [[ -n "$DOWNLOAD_DIR" ]] && rm -rf -- "$DOWNLOAD_DIR"
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
# publish_staged_file in bin/common.sh.
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
  # unrelated phase of bin/install.
  if ! cmp -s "$STAGED_CONFIG" "$config"; then
    log_warning "$config differs from the shipped defaults; leaving it as-is."
  fi
  rm -f -- "$STAGED_CONFIG"
  STAGED_CONFIG=""
  return 0
}

# Herdr's own plugin registry is the authority on what is installed, so this
# reads it instead of keeping a marker file. A marker can disagree with reality
# after a hand `herdr plugin uninstall` -- exactly the desync that forces
# install_pinned_binary to re-check the binary alongside its version file.
plugin_source_field() {
  local field="$1"
  "$HERDR_BIN" plugin list --json 2>/dev/null |
    jq -r --arg id "$HERDR_PLUGIN_ID" --arg field "$field" \
      '.result.plugins[]? | select(.plugin_id == $id) | .source[$field] // empty' \
      2>/dev/null || true
}

# Unlike the binary, this cannot be verified against a committed digest: Herdr
# resolves the ref to a commit and builds it from source on this machine. The
# tag is the pin, which is why config/versions.env records a ref and no SHA.
install_plugin() {
  local kind ref

  if [[ ! -x "$HERDR_BIN" ]]; then
    log_warning "Herdr is not installed at $HERDR_BIN; skipping the $HERDR_PLUGIN_ID plugin."
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_warning "jq is required to inspect installed Herdr plugins; skipping $HERDR_PLUGIN_ID."
    return 0
  fi

  kind=$(plugin_source_field kind)
  ref=$(plugin_source_field requested_ref)

  # A linked checkout is someone developing the plugin. Replacing it with a
  # tagged release would silently discard their working tree from the pane path,
  # and the bootstrap has no business making that call.
  if [[ "$kind" == "local" ]]; then
    log_info "$HERDR_PLUGIN_ID is linked from a local checkout; leaving it alone."
    return 0
  fi

  if [[ "$kind" == "github" && "$ref" == "$HERDR_DEVCONTAINER_REF" ]]; then
    log_info "$HERDR_PLUGIN_ID $HERDR_DEVCONTAINER_REF is already installed."
    return 0
  fi

  # Only needed on the install path: the plugin manifest's build hook runs
  # `cargo build --release`, so there is no prebuilt artifact to fall back to.
  if ! command -v cargo >/dev/null 2>&1; then
    log_warning "cargo is required to build the $HERDR_PLUGIN_ID plugin; skipping."
    return 0
  fi

  # Replacing an install pinned to a different ref: uninstall first rather than
  # relying on install-over-existing semantics. The plugin keeps its own config
  # under ~/.config/herdr-devcontainer, so nothing the user set is discarded.
  if [[ -n "$kind" ]]; then
    log_info "Replacing $HERDR_PLUGIN_ID (${ref:-$kind}) with $HERDR_DEVCONTAINER_REF..."
    "$HERDR_BIN" plugin uninstall "$HERDR_PLUGIN_ID" >/dev/null 2>&1 || true
  fi

  # Never fatal. Plugin commands go through the running Herdr server's socket
  # API, so a first bootstrap that has not started Herdr yet cannot register
  # anything -- and that must not take down every later phase of bin/install.
  log_info "Installing $HERDR_DEVCONTAINER_REPO $HERDR_DEVCONTAINER_REF..."
  if "$HERDR_BIN" plugin install "$HERDR_DEVCONTAINER_REPO" \
    --ref "$HERDR_DEVCONTAINER_REF" --yes; then
    log_success "Installed $HERDR_PLUGIN_ID $HERDR_DEVCONTAINER_REF."
  else
    log_warning "Could not install $HERDR_PLUGIN_ID; rerun after Herdr has started once."
  fi
  return 0
}

report_plan() {
  printf 'Herdr install plan:\n'
  printf '  version:    %s\n' "$HERDR_VERSION"
  printf '  binary:     %s\n' "$HERDR_BIN"
  printf '  state:      %s\n' "$HERDR_STATE_ROOT"
  printf '  config:     %s\n' "$HERDR_CONFIG_ROOT/config.toml"
  printf '  plugin:     %s@%s\n' "$HERDR_DEVCONTAINER_REPO" "$HERDR_DEVCONTAINER_REF"
  printf '  installed:  %s\n' "$(installed_marker || printf '(none)')"
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

  install_pinned_binary "$arch"
  install_config
  install_plugin
}

if [[ "${HERDR_INSTALL_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
