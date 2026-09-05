#!/usr/bin/env bash
# Read-only checks, candidate-first setup, migration, and rollback for the
# tailnet-only custom HTTPS hostname (pi.dpao.la) in front of Pi Web UI.
#
# This file currently defines only the static Caddy source contract shared by
# later setup/migration/rollback tasks: fixed managed paths, the exact tracked
# Caddyfile and unit renderers, and a source-only integrity check. It has no
# CLI entry point yet.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Reuse platform, identity, unit, and Tailscale route helpers.
# shellcheck source=ai/pi/webui/tailscale.sh
source "$SCRIPT_DIR/tailscale.sh"

readonly CUSTOM_HOSTNAME=pi.dpao.la
readonly CADDY_VERSION=2.11.4
readonly XCADDY_VERSION=0.4.7
readonly GODADDY_MODULE_VERSION=1.2.0
readonly CADDY_PREFIX=/usr/local/lib/pi-webui
readonly CADDY_BINARY=$CADDY_PREFIX/caddy
readonly CADDY_ENTRYPOINT=$CADDY_PREFIX/caddy-entrypoint
readonly CADDY_CONFIG=/etc/pi-webui-caddy/Caddyfile
readonly CADDY_UNIT=/etc/systemd/system/pi-webui-caddy.service
readonly CADDY_CREDENTIAL=/etc/credstore.encrypted/godaddy-api-token
# Consumed by later setup/migration/rollback tasks; not read within this file.
export CUSTOM_HOSTNAME CADDY_VERSION XCADDY_VERSION GODADDY_MODULE_VERSION \
  CADDY_PREFIX CADDY_BINARY CADDY_ENTRYPOINT CADDY_CONFIG CADDY_UNIT CADDY_CREDENTIAL

# Matches a PEM private-key header or a colon-joined pair of long
# alphanumeric tokens (the shape of a GoDaddy classic `key:secret`
# credential), the same pattern used to scan tracked source in tests.
readonly CREDENTIAL_PATTERN='(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|[A-Za-z0-9]{20,}:[A-Za-z0-9]{20,})'
readonly -a CADDY_MANAGED_SOURCE_FILES=(
  "$SCRIPT_DIR/Caddyfile.in"
  "$SCRIPT_DIR/pi-webui-caddy.service.in"
  "$SCRIPT_DIR/caddy-entrypoint.sh"
  "$SCRIPT_DIR/custom-domain.sh"
)

render_caddyfile() { cat "$SCRIPT_DIR/Caddyfile.in"; }

# shellcheck disable=SC2120 # entrypoint override is used by later staged-build tasks
render_caddy_unit() {
  local entrypoint=${1:-$CADDY_ENTRYPOINT} rendered
  safe_unit_path "$entrypoint" || return 1
  rendered=$(<"$SCRIPT_DIR/pi-webui-caddy.service.in")
  rendered=${rendered//@CADDY_ENTRYPOINT@/$entrypoint}
  [[ "$rendered" != *'@CADDY_ENTRYPOINT@'* ]] || fail 'Caddy unit substitution failed'
  printf '%s\n' "$rendered"
}

validate_caddy_source() {
  local entrypoint_script=$SCRIPT_DIR/caddy-entrypoint.sh rendered file

  [[ -f "$SCRIPT_DIR/Caddyfile.in" && ! -L "$SCRIPT_DIR/Caddyfile.in" ]] ||
    fail 'tracked Caddyfile template is unavailable'
  [[ -f "$SCRIPT_DIR/pi-webui-caddy.service.in" && ! -L "$SCRIPT_DIR/pi-webui-caddy.service.in" ]] ||
    fail 'tracked Caddy unit template is unavailable'
  [[ -f "$entrypoint_script" && ! -L "$entrypoint_script" && -x "$entrypoint_script" ]] ||
    fail 'Caddy entrypoint script must be an executable regular file'

  rendered=$(render_caddyfile) || return 1
  [[ "$rendered" != *'{{'*'}}'* && "$rendered" != *'@'*'@'* ]] ||
    fail 'Caddyfile contains an unresolved placeholder'
  rendered=$(render_caddy_unit) || return 1
  [[ "$rendered" != *'@'*'@'* ]] ||
    fail 'Caddy unit contains an unresolved placeholder'

  for file in "${CADDY_MANAGED_SOURCE_FILES[@]}"; do
    ! grep -Eq "$CREDENTIAL_PATTERN" "$file" ||
      fail "managed Caddy source contains credential-like material: $file"
  done
}
