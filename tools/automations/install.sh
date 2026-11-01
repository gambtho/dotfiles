#!/usr/bin/env bash
# Install or inspect the weekly review timers. Opt-in per machine: `make install`
# does not run this, because each run spends model quota and opens pull requests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-automations"
NAMES=(tooling-radar dotfiles-health lane-review)

usage() {
  printf 'Usage: %s --apply | --check\n' "$0"
}

require_host() {
  local tool service_path entry real_gh=""
  local -a entries=()
  command -v systemctl >/dev/null 2>&1 || {
    printf 'automations: systemctl is required on this machine\n' >&2
    exit 1
  }
  # The timers run with the unit's PATH, not this shell's, so a tool found only
  # here would pass this check and then fail every Monday.
  service_path="$(sed -n 's/^Environment=PATH=//p' "$SCRIPT_DIR/systemd/dotfiles-automation@.service")"
  service_path="${service_path//'%h'/$HOME}"
  [[ -n "$service_path" ]] || {
    printf 'automations: the service unit does not set PATH\n' >&2
    exit 1
  }
  for tool in bwrap gh mise pi python3; do
    PATH="$service_path" command -v "$tool" >/dev/null 2>&1 || {
      printf 'automations: %s is not on the PATH the timers use: %s\n' "$tool" "$service_path" >&2
      exit 1
    }
  done
  # bin/gh satisfies the lookup above but only hands off to a real gh further
  # along the same PATH, so it does not count as gh being installed.
  IFS=: read -r -a entries <<<"$service_path"
  for entry in "${entries[@]}"; do
    if [[ -x "$entry/gh" && ! "$entry/gh" -ef "$REPO_ROOT/bin/gh" ]]; then
      real_gh="$entry/gh"
      break
    fi
  done
  [[ -n "$real_gh" ]] || {
    printf 'automations: only the bin/gh shim is on the PATH the timers use; install gh: %s\n' "$service_path" >&2
    exit 1
  }
  # The runner launches this exact path inside the sandbox, so a pi found
  # elsewhere on PATH does not help.
  [[ -x "$HOME/.pi/agent/bin/pi" ]] || {
    printf 'automations: the runner needs Pi at %s\n' "$HOME/.pi/agent/bin/pi" >&2
    exit 1
  }
}

apply() {
  require_host
  # The units run from ~/.dotfiles, so installing from a worktree would enable
  # timers for code that is not on the path they execute.
  if [[ "$(git -C "$REPO_ROOT" rev-parse --git-dir)" != "$(git -C "$REPO_ROOT" rev-parse --git-common-dir)" ]]; then
    printf 'automations: run this from the primary checkout, not a linked worktree\n' >&2
    exit 1
  fi
  if [[ "$REPO_ROOT" != "$HOME/.dotfiles" ]]; then
    printf 'automations: units expect the checkout at %s, found %s\n' "$HOME/.dotfiles" "$REPO_ROOT" >&2
    exit 1
  fi

  mkdir -p "$UNIT_DIR"
  install -m 644 "$SCRIPT_DIR/systemd/dotfiles-automation@.service" "$UNIT_DIR/"
  local name
  for name in "${NAMES[@]}"; do
    install -m 644 "$SCRIPT_DIR/systemd/dotfiles-automation@$name.timer" "$UNIT_DIR/"
  done
  systemctl --user daemon-reload
  for name in "${NAMES[@]}"; do
    systemctl --user enable --now "dotfiles-automation@$name.timer"
  done

  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
    printf 'automations: linger is off; timers only run while logged in (loginctl enable-linger)\n' >&2
  fi
  check
}

check() {
  systemctl --user list-timers --all --no-pager 'dotfiles-automation@*' || true
  local name status_file
  for name in "${NAMES[@]}"; do
    status_file="$STATE_DIR/$name.json"
    printf '\n%s: ' "$name"
    if [[ -f "$status_file" ]]; then
      cat "$status_file"
    else
      printf 'no runs yet\n'
    fi
  done
}

case "${1:-}" in
  --apply) apply ;;
  --check) check ;;
  *)
    usage >&2
    exit 2
    ;;
esac
