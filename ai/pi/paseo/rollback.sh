#!/usr/bin/env bash
# Explicit backend disablement; state, runtime and the domain proxy remain intact.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/common.sh"
[[ $# -eq 0 ]] || {
  printf 'usage: %s\n' "$0" >&2
  exit 2
}
paseo_selected || {
  fail 'backend rollback requires DOTFILES_PASEO_ENABLED=1'
  exit 1
}
require_supported_platform
resolve_source
validate_apply_source
resolve_mise
resolve_pi
set_managed_paths
validate_state_root
validate_launcher
validate_unit
read_service_state paseo.service
[[ "$SERVICE_FRAGMENT" == "$UNIT_PATH" ]] || {
  fail 'loaded unit is foreign'
  exit 1
}
if [[ "$SERVICE_ACTIVE_STATE" == active ]]; then
  require_quiescent
  systemctl --user stop paseo.service
fi
systemctl --user disable paseo.service
printf 'Paseo disabled; runtime, state, proxy and original Pi sessions preserved\n'
