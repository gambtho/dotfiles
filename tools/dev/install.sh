#!/usr/bin/env bash
# tools/dev/install.sh -- state directories, the dev-autostart user unit, and a
# check that the committed tmux marker block is in place.
#
# bin/dev is deliberately NOT symlinked: ~/.dotfiles/bin is already first on
# PATH via core/path.zsh, so the dispatcher is callable as installed.

set -euo pipefail

# shellcheck source=bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEV_STATE_ROOT="${DEV_STATE_ROOT:-$HOME/.local/state/dev}"
SERVICE_TEMPLATE="$DOTFILES_ROOT/tools/dev/dev-autostart.service"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_UNIT="$SYSTEMD_USER_DIR/dev-autostart.service"
TMUX_CONF="$DOTFILES_ROOT/tools/tmux/tmux.conf.symlink"
MARKER_START="# dev-workspace-config-start"
MARKER_END="# dev-workspace-config-end"

create_state_dirs() {
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks" "$DEV_STATE_ROOT/sessions"
  chmod 0700 "$DEV_STATE_ROOT"
}

# `systemctl --user` always acts on the invoking user's real manager, ignoring
# HOME. Writing the unit into XDG_CONFIG_HOME is harmless in a sandbox, but
# reloading and enabling would mutate state outside it -- so gate only those.
systemd_user_available() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  [[ "${DEV_SKIP_SERVICE:-0}" != "1" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local real_home
  real_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [[ -n "$real_home" && "$HOME" == "$real_home" ]] || return 1
  # A user manager only exists for a real login session (absent in containers,
  # SSH ForceCommand, and CI).
  systemctl --user show-environment >/dev/null 2>&1 || return 1
  [[ -f "$SERVICE_TEMPLATE" && ! -L "$SERVICE_TEMPLATE" ]] || return 1
}

# Generated from the repo template so DOTFILES_ROOT is baked in and the unit
# stays a regular file -- systemd does not follow unit symlinks predictably.
install_service_unit() {
  mkdir -p "$SYSTEMD_USER_DIR"

  local staged escaped_root
  staged=$(mktemp "$SYSTEMD_USER_DIR/.dev-autostart.service.XXXXXX")
  # Escape the replacement so a repo path containing sed metacharacters (\, &,
  # or the | delimiter) is substituted literally instead of corrupting the unit.
  escaped_root=${DOTFILES_ROOT//\\/\\\\}
  escaped_root=${escaped_root//|/\\|}
  escaped_root=${escaped_root//&/\\&}
  sed "s|@DOTFILES_ROOT@|$escaped_root|g" "$SERVICE_TEMPLATE" >"$staged"
  chmod 0644 "$staged"

  if [[ -f "$SERVICE_UNIT" ]] && cmp -s "$staged" "$SERVICE_UNIT"; then
    rm -f "$staged"
  else
    command mv -f "$staged" "$SERVICE_UNIT"
    log_info "Installed dev-autostart user service at $SERVICE_UNIT."
  fi

  if ! systemd_user_available; then
    log_info "No systemd user manager available; unit written but not enabled."
    return 0
  fi
  systemctl --user daemon-reload
  systemctl --user enable dev-autostart.service >/dev/null
}

# The marker block is committed to tmux.conf.symlink (Task 16), not injected
# here. Verify rather than write, so a lost block is reported instead of
# silently re-added on top of a hand edit.
verify_tmux_marker() {
  if grep -qF "$MARKER_START" "$TMUX_CONF" && grep -qF "$MARKER_END" "$TMUX_CONF"; then
    return 0
  fi
  log_warning "tmux marker block missing from $TMUX_CONF; dev hooks will not load."
  return 1
}

main() {
  create_state_dirs
  install_service_unit
  verify_tmux_marker
}

main "$@"
