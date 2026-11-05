#!/usr/bin/env bash
# Explicit host opt-in, separate from the agent review automations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
NAME=dotfiles-cache-prune

usage() {
  printf 'Usage: %s --apply | --check\n' "$0"
}

require_systemd() {
  if [[ "$(uname -s)" != Linux ]] || ! command -v systemctl >/dev/null 2>&1; then
    printf 'cache-maintenance: Linux with systemd user services is required\n' >&2
    return 1
  fi
}

check() {
  require_systemd
  local load started
  load="$(systemctl --user show "$NAME.timer" --property=LoadState --value)" || return 1
  if [[ "$load" == not-found ]]; then
    printf 'cache-maintenance: not installed; opt in with make cache-maintenance\n'
    return 0
  fi
  systemctl --user list-timers --all --no-pager "$NAME.timer" || return 1
  started="$(systemctl --user show "$NAME.service" --property=ExecMainStartTimestamp --value)" || return 1
  if [[ -z "$started" ]]; then
    printf 'cache-maintenance: service has never run\n'
  else
    systemctl --user show "$NAME.service" --property=Result,ExecMainStatus,ExecMainStartTimestamp || return 1
  fi
  printf 'Logs: journalctl --user -u %s.service\n' "$NAME"
}

apply() {
  require_systemd
  # The service executes the canonical checkout, never implementation worktrees.
  if [[ "$(git -C "$REPO_ROOT" rev-parse --git-dir)" != "$(git -C "$REPO_ROOT" rev-parse --git-common-dir)" ]]; then
    printf 'cache-maintenance: run from the primary checkout, not a linked worktree\n' >&2
    return 1
  fi
  if [[ "$REPO_ROOT" != "$HOME/.dotfiles" ]]; then
    printf 'cache-maintenance: units expect the checkout at %s\n' "$HOME/.dotfiles" >&2
    return 1
  fi
  local service_path tool
  service_path="$(sed -n 's/^Environment=PATH=//p' "$SCRIPT_DIR/systemd/$NAME.service")"
  service_path="${service_path//'%h'/$HOME}"
  [[ -n "$service_path" ]] || {
    printf 'cache-maintenance: service PATH is missing\n' >&2
    return 1
  }
  for tool in bash du flock ps timeout mkdir chmod; do
    if ! PATH="$service_path" command -v "$tool" >/dev/null 2>&1; then
      printf 'cache-maintenance: %s is not on the service PATH: %s\n' "$tool" "$service_path" >&2
      return 1
    fi
  done
  [[ -f "$REPO_ROOT/libexec/cache-prune" ]] || {
    printf 'cache-maintenance: cache-prune helper is missing\n' >&2
    return 1
  }
  mkdir -p "$UNIT_DIR"
  install -m 644 "$SCRIPT_DIR/systemd/$NAME.service" "$UNIT_DIR/"
  install -m 644 "$SCRIPT_DIR/systemd/$NAME.timer" "$UNIT_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now "$NAME.timer"
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != yes ]]; then
    printf 'cache-maintenance: linger is off; user timers need an active login (loginctl enable-linger)\n' >&2
  fi
  check
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
case "$1" in
  --apply) apply ;;
  --check) check ;;
  --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
