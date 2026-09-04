#!/usr/bin/env bash
# Validate and explicitly manage tailnet-only Pi Web UI ingress.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Reuse the installer's platform, identity, unit, and health contracts.
# shellcheck source=ai/pi/webui/install.sh
source "$SCRIPT_DIR/install.sh"

readonly BACKEND=http://127.0.0.1:31415
readonly KEY_URL=https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
readonly KEY_SHA=3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39
readonly SOURCE_LINE='deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main'

set_tailscale_paths() {
  local root=${PI_WEBUI_TAILSCALE_ROOT:-}
  if [[ -n "$root" ]]; then
    require_test_override "$root"
  fi
  KEYRING=$root/usr/share/keyrings/tailscale-archive-keyring.gpg
  APT_SOURCE=$root/etc/apt/sources.list.d/tailscale.list
}

require_tailscale_daemon() {
  systemctl is-active tailscaled >/dev/null || fail 'tailscaled is not active'
}

require_tailscale() {
  local status
  require_tailscale_daemon
  status=$(tailscale status --json) || fail 'cannot read Tailscale status'
  node - "$status" <<'NODE' || fail 'Tailscale is not authenticated and online'
const value = JSON.parse(process.argv[2]);
if (value.BackendState !== 'Running' || value.Self?.Online !== true) process.exit(1);
NODE
}

route_state() {
  local serve funnel human
  serve=$(tailscale serve status --json) || fail 'cannot read Tailscale Serve state'
  funnel=$(tailscale funnel status --json) || fail 'cannot read Tailscale Funnel state'
  human=$(tailscale serve status) || fail 'cannot read human Tailscale Serve status'
  node - "$serve" "$funnel" "$human" "$BACKEND" <<'NODE' || fail 'Tailscale route is foreign, additional, public, or ambiguous'
const [serveText, funnelText, human, backend] = process.argv.slice(2);
const canonical = value => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(
    Object.keys(value).sort().map(key => [key, canonical(value[key])])
  );
  return value;
};
const empty = value => {
  if (value == null) return true;
  if (Array.isArray(value)) return value.length === 0;
  return typeof value === 'object' && Object.values(value).every(empty);
};
const serve = JSON.parse(serveText);
const funnel = JSON.parse(funnelText);
if (JSON.stringify(canonical(serve)) !== JSON.stringify(canonical(funnel))) process.exit(1);
if (empty(serve)) { console.log('empty'); process.exit(0); }
if (!serve || Array.isArray(serve) || typeof serve !== 'object') process.exit(1);
if (Object.keys(serve).some(key => !['TCP', 'Web', 'AllowFunnel'].includes(key) && !empty(serve[key]))) process.exit(1);
const tcpKeys = Object.keys(serve.TCP || {});
const webKeys = Object.keys(serve.Web || {});
if (tcpKeys.length !== 1 || tcpKeys[0] !== '443' || webKeys.length !== 1) process.exit(1);
const tcp = serve.TCP['443'];
if (!tcp || tcp.HTTPS !== true || Object.entries(tcp).some(([key, value]) => key !== 'HTTPS' && !empty(value))) process.exit(1);
const hostKey = webKeys[0];
if (!hostKey.endsWith(':443')) process.exit(1);
const web = serve.Web[hostKey];
if (!web || Object.keys(web).some(key => key !== 'Handlers' && !empty(web[key]))) process.exit(1);
const handlers = web.Handlers;
if (!handlers || Object.keys(handlers).length !== 1 || !handlers['/'] ||
    handlers['/'].Proxy !== backend || Object.entries(handlers['/']).some(([key, value]) => key !== 'Proxy' && !empty(value))) process.exit(1);
const allow = serve.AllowFunnel;
if (allow && (Object.keys(allow).length !== 1 || allow[hostKey] !== false)) process.exit(1);
const host = hostKey.slice(0, -4);
const lines = human.split(/\r?\n/).map(line => line.trim().replace(/\s+/g, ' ')).filter(Boolean);
if (lines.length !== 2 || lines[0] !== `https://${host} (tailnet only)` ||
    lines[1] !== `|-- / proxy ${backend}`) process.exit(1);
console.log('exact');
NODE
}

check_local_service() {
  local strict=${1:-0}
  resolve_source
  resolve_mise
  resolve_pi
  "$SOURCE_ROOT/bin/validate-pi-webui" --tracked-only
  set_managed_paths
  validate_landing_worktree "$LANDING_WORKTREE"
  if path_exists "$INSTALLED_RUNTIME"; then
    "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$INSTALLED_RUNTIME"
  else
    [[ "$strict" -eq 0 ]] || fail 'installed runtime is unavailable'
  fi
  if path_exists "$UNIT_PATH"; then
    validate_unit "$UNIT_PATH"
  else
    [[ "$strict" -eq 0 ]] || fail 'installed service unit is unavailable'
  fi
  if systemctl --user is-active pi-webui.service >/dev/null 2>&1; then
    validate_active_health "$PI_LAUNCHER"
  else
    [[ "$strict" -eq 0 ]] || fail 'Pi Web UI service is not active'
  fi
}

check_lan() {
  local addresses interface address count=0
  addresses=$(ip -o -4 addr show scope global |
    awk '{ interface=$2; for (i=3; i<=NF; i++) if ($i == "inet") { split($(i+1), a, "/"); print interface, a[1] } }') ||
    fail 'cannot inspect global IPv4 addresses'
  while read -r interface address; do
    [[ -n "$address" && "$interface" != tailscale0 ]] || continue
    ((count += 1))
    if curl --silent --show-error --connect-timeout 1 "http://$address:31415/" >/dev/null 2>&1; then
      fail "Pi Web UI is reachable on LAN address $address"
      return 1
    fi
  done <<<"$addresses"
  [[ "$count" -gt 0 ]] || fail 'no non-Tailscale global IPv4 address is available'
}

check_all() {
  require_supported_platform
  check_local_service
  require_tailscale
  route_state >/dev/null
  check_lan
  printf 'Tailscale state is valid\n'
}

install_tailscale() {
  local temporary key source hash
  require_supported_platform
  set_tailscale_paths
  if path_exists "$KEYRING"; then
    [[ -f "$KEYRING" && ! -L "$KEYRING" ]] || fail 'existing Tailscale keyring is not a regular file'
    hash=$(sha256sum "$KEYRING" | awk '{print $1}')
    [[ "$hash" == "$KEY_SHA" ]] || fail 'existing Tailscale keyring is not managed'
  fi
  if path_exists "$APT_SOURCE"; then
    [[ -f "$APT_SOURCE" && ! -L "$APT_SOURCE" && "$(<"$APT_SOURCE")" == "$SOURCE_LINE" ]] ||
      fail 'existing Tailscale apt source is not managed'
  fi
  temporary=$(mktemp -d)
  chmod 0700 "$temporary"
  trap 'rm -rf -- "$temporary"' EXIT
  key=$temporary/tailscale.gpg
  source=$temporary/tailscale.list
  curl --fail --silent --show-error --location "$KEY_URL" -o "$key"
  hash=$(sha256sum "$key" | awk '{print $1}')
  [[ "$hash" == "$KEY_SHA" ]] || fail 'downloaded Tailscale key has the wrong SHA-256'
  printf '%s\n' "$SOURCE_LINE" >"$source"
  sudo install -o root -g root -m 0644 "$key" "$KEYRING"
  sudo install -o root -g root -m 0644 "$source" "$APT_SOURCE"
  sudo apt-get update
  sudo apt-get install --yes tailscale
  rm -rf -- "$temporary"
  trap - EXIT
}

serve() {
  local state
  require_supported_platform
  check_local_service 1
  require_tailscale
  state=$(route_state)
  [[ "$state" == empty || "$state" == exact ]] || fail 'Tailscale route is not owned'
  sudo tailscale serve --bg --https=443 "$BACKEND"
  [[ $(route_state) == exact ]] || fail 'Tailscale Serve publication did not produce the exact route'
}

serve_off() {
  require_supported_platform
  require_tailscale_daemon
  [[ $(route_state) == exact ]] || fail 'refusing to remove a foreign or empty route'
  sudo tailscale serve --https=443 off
  [[ $(route_state) == empty ]] || fail 'Tailscale route remains after removal'
}

uninstall_tailscale() {
  require_supported_platform
  require_tailscale_daemon
  [[ $(route_state) == empty ]] || fail 'remove the active Tailscale route before uninstalling'
  set_tailscale_paths
  if path_exists "$KEYRING"; then
    [[ -f "$KEYRING" && ! -L "$KEYRING" && "$(sha256sum "$KEYRING" | awk '{print $1}')" == "$KEY_SHA" ]] ||
      fail 'refusing to remove a foreign Tailscale keyring'
  fi
  if path_exists "$APT_SOURCE"; then
    [[ -f "$APT_SOURCE" && ! -L "$APT_SOURCE" && "$(<"$APT_SOURCE")" == "$SOURCE_LINE" ]] ||
      fail 'refusing to remove a foreign Tailscale apt source'
  fi
  sudo apt-get remove --yes tailscale
  sudo rm -f -- "$KEYRING" "$APT_SOURCE"
}

usage() {
  printf 'usage: %s help|check|install|up|serve|serve-off|uninstall\n' "$0"
}

main() {
  [[ $# -eq 1 ]] || {
    usage >&2
    return 2
  }
  case "$1" in
    help) usage ;;
    check) check_all ;;
    install) install_tailscale ;;
    up)
      require_supported_platform
      sudo tailscale up
      ;;
    serve) serve ;;
    serve-off) serve_off ;;
    uninstall) uninstall_tailscale ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
