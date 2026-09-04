#!/usr/bin/env bash
# Remove only the proven Pi Web UI service, with opt-in state cleanup.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Reuse platform, identity, runtime, worktree, unit, and route validation.
# shellcheck source=ai/pi/webui/tailscale.sh
source "$SCRIPT_DIR/tailscale.sh"

remove_runtime=0
remove_worktree=0
unit_present=0
service_active=0

usage() {
  printf 'usage: %s [--remove-runtime] [--remove-worktree]\n' "$0"
}

set_paths() {
  resolve_source
  resolve_mise
  resolve_pi
  STATE_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}/pi-webui
  INSTALLED_RUNTIME=$STATE_ROOT/runtime/current
  LANDING_WORKTREE=$STATE_ROOT/worktrees/dotfiles
  RUNTIME_LAUNCHER=$INSTALLED_RUNTIME/node_modules/.bin/pi-webui
  UNIT_PATH=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pi-webui.service
  export STATE_ROOT INSTALLED_RUNTIME LANDING_WORKTREE RUNTIME_LAUNCHER UNIT_PATH
}

preflight() {
  require_supported_platform
  set_paths
  [[ $(route_state) == empty ]] || fail 'remove the Tailscale Serve route before rollback'

  if systemctl --user is-active pi-webui.service >/dev/null 2>&1; then
    service_active=1
  fi
  if path_exists "$UNIT_PATH"; then
    validate_unit "$UNIT_PATH"
    unit_present=1
  else
    [[ "$service_active" -eq 0 ]] || fail 'active Pi Web UI service has no managed unit'
  fi

  if [[ "$remove_runtime" -eq 1 ]] && path_exists "$INSTALLED_RUNTIME"; then
    [[ "$service_active" -eq 0 ]] || fail 'runtime removal requires an inactive service'
    require_managed_directory "$INSTALLED_RUNTIME" 'installed runtime'
    "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$INSTALLED_RUNTIME"
  fi
  if [[ "$remove_worktree" -eq 1 ]] && path_exists "$LANDING_WORKTREE"; then
    validate_landing_worktree "$LANDING_WORKTREE"
    ! path_exists "$LANDING_WORKTREE/.pi" || fail 'worktree removal requires complete absence of .pi'
  fi
}

remove_service() {
  local listeners
  if [[ "$unit_present" -eq 1 ]]; then
    systemctl --user stop pi-webui.service
    systemctl --user disable pi-webui.service
    rm -f -- "$UNIT_PATH"
    systemctl --user daemon-reload
  fi
  listeners=$(ss -ltnH 'sport = :31415') || fail 'cannot inspect Pi Web UI listener'
  [[ -z "$listeners" ]] || fail 'a listener remains on port 31415'
}

main() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --remove-runtime) [[ "$remove_runtime" -eq 0 ]] || { usage >&2; return 2; }; remove_runtime=1 ;;
      --remove-worktree) [[ "$remove_worktree" -eq 0 ]] || { usage >&2; return 2; }; remove_worktree=1 ;;
      *) usage >&2; return 2 ;;
    esac
  done

  preflight
  remove_service
  if [[ "$remove_runtime" -eq 1 ]] && path_exists "$INSTALLED_RUNTIME"; then
    rm -rf -- "$INSTALLED_RUNTIME"
  fi
  if [[ "$remove_worktree" -eq 1 ]] && path_exists "$LANDING_WORKTREE"; then
    git -C "$SOURCE_ROOT" worktree remove "$LANDING_WORKTREE"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
