#!/usr/bin/env bash
# tools/projectmux/migrate-from-dev.sh -- retire the Bash dev workspace
# platform's *installed* assets (design §13 step 8).
#
# Deleting tools/dev/ removes the sources. It does not remove what those
# sources installed: a systemd user unit, hooks living in a running tmux
# server's memory, and a state directory. This script removes those, and is
# the reason step 8 is a migration rather than a `git rm`.
#
# It lives here, not in tools/dev/, because the same change deletes that
# directory -- a script cannot ship inside the tree it removes -- and because
# the new application is the right owner of the migration off the old one.
#
# Idempotent, and safe to run before or after the deletion lands: nothing here
# tests for a tools/dev/ file. Hooks are matched by the `dev-event` command
# string they still carry, which is the only evidence that survives in a
# server started weeks ago.

set -euo pipefail

# shellcheck source=bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DEV_STATE_ROOT="${DEV_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/dev}"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DEV_UNIT_NAME="dev-autostart.service"
DEV_UNIT="$SYSTEMD_USER_DIR/$DEV_UNIT_NAME"
PROJECTMUX_UNIT_NAME="projectmux-autostart.service"
PROJECTMUX_UNIT="$SYSTEMD_USER_DIR/$PROJECTMUX_UNIT_NAME"

# The substring every managed hook carries, in every revision of
# dev.tmux.conf. Matching the *whole* command against the repo's current
# dev.tmux.conf would be stricter and wrong: the live hooks on this machine
# were set by an older revision (no 'pane=#{@dev_pane}' argument) and tmux has
# expanded ~ to an absolute path, so an exact comparison misses all four,
# takes the preserve branch, and leaves every hook set forever.
HOOK_MARKER="dev-event"

# Global hooks, then the one registered with -gw. pane-died is global-WINDOW
# scoped (dev.tmux.conf), invisible to `show-hooks -g` and to
# `show-hooks -w -t <window>`; only `show-hooks -gw` reports it.
GLOBAL_HOOKS=(session-closed client-attached client-detached)
WINDOW_HOOKS=(pane-died)

# Dated so the validation window has something to fall back to. Removing it is
# a separate, explicit act: design §13 promises no data migration, so this
# directory is a safety net, not a source.
BACKUP_SUFFIX="${MIGRATE_BACKUP_SUFFIX:-$(date +%Y%m%d)}"

tmux_cmd() {
  if [[ -n "${PROJECTMUX_TMUX_SOCKET:-}" ]]; then
    tmux -L "$PROJECTMUX_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# Same gate as tools/dev/install.sh:30-41: `systemctl --user` always acts on
# the invoking user's real manager regardless of HOME, so a sandboxed test run
# must not reach it.
systemd_user_available() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  [[ "${DEV_SKIP_SERVICE:-0}" != "1" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local real_home
  real_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [[ -n "$real_home" && "$HOME" == "$real_home" ]] || return 1
  systemctl --user show-environment >/dev/null 2>&1 || return 1
}

# Disable the old unit BEFORE enabling the new one: both drive the same tmux
# server at login, and a window where both are enabled is a race.
migrate_service() {
  if ! systemd_user_available; then
    log_info "No systemd user manager available; skipping unit migration."
    return 0
  fi

  if systemctl --user list-unit-files "$DEV_UNIT_NAME" >/dev/null 2>&1 &&
    [[ -n "$(systemctl --user list-unit-files --no-legend "$DEV_UNIT_NAME" 2>/dev/null)" ]]; then
    systemctl --user disable --now "$DEV_UNIT_NAME" >/dev/null 2>&1 ||
      log_warning "Could not disable $DEV_UNIT_NAME; continuing."
    log_info "Disabled $DEV_UNIT_NAME."
  fi

  # Removing the repo template does not remove the installed copy, which is a
  # rendered regular file rather than a symlink.
  if [[ -e "$DEV_UNIT" ]]; then
    rm -f -- "$DEV_UNIT"
    log_info "Removed $DEV_UNIT."
  fi

  systemctl --user daemon-reload

  if [[ -f "$PROJECTMUX_UNIT" ]]; then
    systemctl --user enable "$PROJECTMUX_UNIT_NAME" >/dev/null
    log_success "Enabled $PROJECTMUX_UNIT_NAME."
  else
    log_warning "$PROJECTMUX_UNIT not installed; run tools/projectmux/install.sh."
  fi
}

# scope_flag is the show-hooks/set-hook scope: -g or -gw. Unsetting is done per
# ARRAY INDEX, not per hook name: a user who appended their own handler to the
# same hook keeps it, and only the managed entry beside it goes.
unset_managed_hooks() {
  local scope_flag="$1"
  shift
  local -a names=("$@")

  local listing line name_idx name value found candidate
  listing=$(tmux_cmd show-hooks "$scope_flag" 2>/dev/null || true)
  [[ -n "$listing" ]] || return 0

  while IFS= read -r line; do
    # show-hooks lists EVERY hook name tmux knows, set or not. An unset hook is
    # a bare name with no index and no value; only a set one renders as
    # "name[N] <command>". Without this guard the preserve branch fires on
    # tmux's own ~60 unset defaults on every run.
    [[ "$line" == *"["*"] "* ]] || continue
    name_idx=${line%% *}
    value=${line#* }
    name=${name_idx%%\[*}

    found=0
    for candidate in "${names[@]}"; do
      [[ "$name" == "$candidate" ]] && found=1 && break
    done
    ((found)) || continue

    if [[ "$value" != *"$HOOK_MARKER"* ]]; then
      # The design's explicit instruction: unset "only when they still match
      # the managed dev-event commands; otherwise warn and preserve the
      # user's replacement".
      log_warning "Preserving $name_idx: no longer the managed command."
      continue
    fi

    tmux_cmd set-hook "${scope_flag}u" "$name_idx"
    log_info "Unset managed hook $name_idx."
  done <<<"$listing"
}

migrate_hooks() {
  if ! tmux_cmd has-session >/dev/null 2>&1; then
    log_info "No tmux server running; no live hooks to unset."
    return 0
  fi
  unset_managed_hooks -g "${GLOBAL_HOOKS[@]}"
  unset_managed_hooks -gw "${WINDOW_HOOKS[@]}"
}

migrate_state() {
  local backup="${DEV_STATE_ROOT}.bak-${BACKUP_SUFFIX}"

  if [[ ! -d "$DEV_STATE_ROOT" ]]; then
    log_info "No dev state directory at $DEV_STATE_ROOT."
    return 0
  fi

  if [[ -e "$backup" ]]; then
    log_warning "$backup already exists; leaving $DEV_STATE_ROOT in place."
    return 0
  fi

  mv -- "$DEV_STATE_ROOT" "$backup"
  log_success "Backed up dev state to $backup."
  log_info "Remove it explicitly once the validation window closes."
}

main() {
  migrate_service
  migrate_hooks
  migrate_state
}

main "$@"
