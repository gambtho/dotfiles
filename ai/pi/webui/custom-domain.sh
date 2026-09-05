#!/usr/bin/env bash
# Read-only checks, candidate-first setup, migration, and rollback for the
# tailnet-only custom HTTPS hostname (pi.dpao.la) in front of Pi Web UI.
#
# This file implements the static Caddy source contract (fixed managed paths,
# the exact tracked Caddyfile/unit renderers, and a source-only integrity
# check), the full read-only `check` CLI verb (strict Firstp1ck preflight,
# DNS, installed Caddy, listener, and TLS/health validation, plus route
# classification), and the candidate-first `setup` verb (credential
# validation, pinned private Caddy build, bounded publication, and automatic
# restoration). `migrate` and `rollback` are accepted by the CLI but report
# themselves as not implemented until their own TDD tasks land.

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
readonly CADDY_SERVICE=pi-webui-caddy.service
readonly CREDENTIAL_NAME=godaddy-api-token
readonly SUPPORTED_CADDY_VERSION=v$CADDY_VERSION
readonly EXPECTED_GODADDY_MODULE=dns.providers.godaddy
readonly EXPECTED_GODADDY_PACKAGE=github.com/caddy-dns/godaddy
readonly DNS_ZONE=dpao.la
readonly CERT_MIN_VALIDITY_SECONDS=604800
# Bounded post-publication wait for the listener, DNS-01 issuance, trusted
# certificate, and proxy health: at most five minutes.
readonly CADDY_READY_ATTEMPTS_DEFAULT=60
readonly CADDY_READY_INTERVAL_DEFAULT=5
# Real managed Caddy artifact paths. Not readonly: set_caddy_paths() (below,
# mirroring tailscale.sh's set_tailscale_paths()) reassigns them under an
# optional test root so tests never touch real system paths.
CADDY_BINARY=$CADDY_PREFIX/caddy
CADDY_ENTRYPOINT=$CADDY_PREFIX/caddy-entrypoint
CADDY_CONFIG=/etc/pi-webui-caddy/Caddyfile
CADDY_UNIT=/etc/systemd/system/pi-webui-caddy.service
CADDY_CREDENTIAL=/etc/credstore.encrypted/$CREDENTIAL_NAME
export CUSTOM_HOSTNAME CADDY_VERSION XCADDY_VERSION GODADDY_MODULE_VERSION \
  CADDY_PREFIX CADDY_BINARY CADDY_ENTRYPOINT CADDY_CONFIG CADDY_UNIT CADDY_CREDENTIAL

set_caddy_paths() {
  local root=${PI_WEBUI_CADDY_ROOT:-}
  if [[ -n "$root" ]]; then
    require_test_override "$root"
  fi
  CADDY_BINARY=$root$CADDY_PREFIX/caddy
  CADDY_ENTRYPOINT=$root$CADDY_PREFIX/caddy-entrypoint
  CADDY_CONFIG=$root/etc/pi-webui-caddy/Caddyfile
  CADDY_UNIT=$root/etc/systemd/system/pi-webui-caddy.service
  CADDY_CREDENTIAL=$root/etc/credstore.encrypted/$CREDENTIAL_NAME
  export CADDY_BINARY CADDY_ENTRYPOINT CADDY_CONFIG CADDY_UNIT CADDY_CREDENTIAL
}

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

# Pinned SHA-256 identities of the two approved static templates, the same
# exact-tracked-content contract bin/validate-pi-webui uses for the runtime
# manifest/lock. Any drift in either template — even syntactically valid,
# placeholder-free, secret-free drift — must be a reviewed source change
# that updates this pin, not a silent pass.
readonly CADDYFILE_SHA256=a0c851372d974aa647e1e37de93fc374a11b1fc7ed361f8a74a6423d4c17c1b4
readonly CADDY_UNIT_TEMPLATE_SHA256=1736be815881c48685b584f3906a1d3aa80811de118b601365c16097c4176eaf

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
  local entrypoint_script=$SCRIPT_DIR/caddy-entrypoint.sh rendered file actual_hash

  [[ -f "$SCRIPT_DIR/Caddyfile.in" && ! -L "$SCRIPT_DIR/Caddyfile.in" ]] ||
    fail 'tracked Caddyfile template is unavailable'
  [[ -f "$SCRIPT_DIR/pi-webui-caddy.service.in" && ! -L "$SCRIPT_DIR/pi-webui-caddy.service.in" ]] ||
    fail 'tracked Caddy unit template is unavailable'
  [[ -f "$entrypoint_script" && ! -L "$entrypoint_script" && -x "$entrypoint_script" ]] ||
    fail 'Caddy entrypoint script must be an executable regular file'

  actual_hash=$(sha256sum "$SCRIPT_DIR/Caddyfile.in" | awk '{print $1}')
  [[ "$actual_hash" == "$CADDYFILE_SHA256" ]] ||
    fail "tracked Caddyfile SHA-256 must be $CADDYFILE_SHA256; got $actual_hash"
  actual_hash=$(sha256sum "$SCRIPT_DIR/pi-webui-caddy.service.in" | awk '{print $1}')
  [[ "$actual_hash" == "$CADDY_UNIT_TEMPLATE_SHA256" ]] ||
    fail "tracked Caddy unit template SHA-256 must be $CADDY_UNIT_TEMPLATE_SHA256; got $actual_hash"

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

# Strict Firstp1ck preflight: every managed component must already be
# installed, matched, active, and healthy. Unlike tailscale.sh's permissive
# check_local_service(), any absent component here is a hard failure before
# DNS, Caddy, or credential access.
strict_firstpick_preflight() {
  require_supported_platform
  resolve_source
  resolve_mise
  resolve_pi
  "$SOURCE_ROOT/bin/validate-pi-webui" --tracked-only
  set_managed_paths
  path_exists "$INSTALLED_RUNTIME" || fail 'installed runtime is unavailable'
  "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$INSTALLED_RUNTIME"
  path_exists "$UNIT_PATH" || fail 'installed service unit is unavailable'
  validate_landing_worktree "$LANDING_WORKTREE"
  validate_unit "$UNIT_PATH"
  validate_active_health "$PI_LAUNCHER"
}

# Emits the node's single online Tailscale IPv4 in 100.64.0.0/10. Fails
# closed on an offline node, zero or multiple IPv4 addresses, or an address
# outside the CGNAT range GoDaddy DNS is expected to publish.
current_tailscale_ipv4() {
  local status
  status=$(tailscale status --json) || fail 'cannot read Tailscale status'
  node - "$status" <<'NODE' || fail 'no exact online Tailscale IPv4 in 100.64.0.0/10'
const status = JSON.parse(process.argv[2]);
if (status?.Self?.Online !== true) process.exit(1);
const ips = Array.isArray(status?.Self?.TailscaleIPs) ? status.Self.TailscaleIPs : [];
const v4 = ips.filter(ip => /^\d+\.\d+\.\d+\.\d+$/.test(ip));
if (v4.length !== 1) process.exit(1);
const octets = v4[0].split('.').map(Number);
if (octets[0] !== 100 || octets[1] < 64 || octets[1] > 127) process.exit(1);
console.log(v4[0]);
NODE
}

# Strips a trailing FQDN dot and blank lines so resolver and every
# authoritative server's answer compare equal regardless of formatting.
normalize_dns_answer() {
  sed -e 's/\.$//' -e '/^$/d'
}

# Requires one exact A answer equal to $expected and no AAAA/CNAME, either
# through the client's normal resolver ($server empty) or directly against
# one authoritative server.
validate_dns_view() {
  local server=$1 expected=$2 a aaaa cname count
  if [[ -n "$server" ]]; then
    a=$(dig +short A "$CUSTOM_HOSTNAME" "@$server") || fail "cannot query A for $CUSTOM_HOSTNAME at $server"
    aaaa=$(dig +short AAAA "$CUSTOM_HOSTNAME" "@$server") || fail "cannot query AAAA for $CUSTOM_HOSTNAME at $server"
    cname=$(dig +short CNAME "$CUSTOM_HOSTNAME" "@$server") || fail "cannot query CNAME for $CUSTOM_HOSTNAME at $server"
  else
    a=$(dig +short A "$CUSTOM_HOSTNAME") || fail "cannot query A for $CUSTOM_HOSTNAME"
    aaaa=$(dig +short AAAA "$CUSTOM_HOSTNAME") || fail "cannot query AAAA for $CUSTOM_HOSTNAME"
    cname=$(dig +short CNAME "$CUSTOM_HOSTNAME") || fail "cannot query CNAME for $CUSTOM_HOSTNAME"
  fi
  a=$(printf '%s\n' "$a" | normalize_dns_answer)
  aaaa=$(printf '%s\n' "$aaaa" | normalize_dns_answer)
  cname=$(printf '%s\n' "$cname" | normalize_dns_answer)
  [[ -z "$aaaa" ]] || fail "unexpected AAAA answer for $CUSTOM_HOSTNAME"
  [[ -z "$cname" ]] || fail "unexpected CNAME answer for $CUSTOM_HOSTNAME: $cname"
  count=$(printf '%s\n' "$a" | grep -c . || true)
  [[ "$count" -eq 1 ]] || fail "expected exactly one A answer for $CUSTOM_HOSTNAME; got $count"
  [[ "$a" == "$expected" ]] || fail "stale Tailscale IPv4 for $CUSTOM_HOSTNAME: got $a, expected $expected"
}

# Requires $DNS_ZONE to have at least one authoritative name server, then
# requires every view -- the client's normal resolver and each authoritative
# server directly -- to agree on one exact A equal to the current Tailscale
# IPv4 with no CNAME or AAAA. Never writes DNS.
validate_public_dns() {
  local ipv4 authoritative server
  ipv4=$(current_tailscale_ipv4) || return 1
  authoritative=$(dig +short NS "$DNS_ZONE") || fail "cannot read authoritative name servers for $DNS_ZONE"
  authoritative=$(printf '%s\n' "$authoritative" | normalize_dns_answer)
  [[ -n "$authoritative" ]] || fail "$DNS_ZONE has no authoritative name server"

  validate_dns_view '' "$ipv4" || return 1
  while IFS= read -r server; do
    [[ -n "$server" ]] || continue
    validate_dns_view "$server" "$ipv4" || return 1
  done <<<"$authoritative"
}

# Requires $path to be a real, non-symlink, root-owned regular file.
require_managed_caddy_artifact() {
  local path=$1 label=$2 owner
  [[ -f "$path" && ! -L "$path" ]] || fail "$label is unavailable"
  owner=$(stat -c %u "$path") || fail "cannot inspect $label ownership"
  [[ "$owner" == 0 ]] || fail "$label must be owned by root"
}

# Requires the installed Caddy binary, entrypoint, Caddyfile, and unit to be
# exact root-owned managed artifacts byte-identical to the tracked renderers,
# the installed Caddy version to be $SUPPORTED_CADDY_VERSION, the GoDaddy DNS
# module to be present, and the dedicated system service to be active.
validate_installed_caddy() {
  local version modules
  set_caddy_paths
  require_managed_caddy_artifact "$CADDY_BINARY" 'managed Caddy binary'
  [[ -x "$CADDY_BINARY" ]] || fail 'managed Caddy binary is not executable'
  require_managed_caddy_artifact "$CADDY_ENTRYPOINT" 'managed Caddy entrypoint'
  [[ -x "$CADDY_ENTRYPOINT" ]] || fail 'managed Caddy entrypoint is not executable'
  require_managed_caddy_artifact "$CADDY_CONFIG" 'managed Caddyfile'
  require_managed_caddy_artifact "$CADDY_UNIT" 'managed Caddy unit'

  cmp -s <(render_caddyfile) "$CADDY_CONFIG" ||
    fail 'installed Caddyfile differs from the managed configuration'
  cmp -s <(render_caddy_unit "$CADDY_ENTRYPOINT") "$CADDY_UNIT" ||
    fail 'installed Caddy unit differs from the managed configuration'

  systemctl is-active "$CADDY_SERVICE" >/dev/null ||
    fail 'Caddy service is not active'

  version=$("$CADDY_BINARY" version) || fail 'cannot read managed Caddy version'
  [[ "$version" == "$SUPPORTED_CADDY_VERSION"* ]] ||
    fail "managed Caddy is not $SUPPORTED_CADDY_VERSION"

  modules=$("$CADDY_BINARY" list-modules --packages) || fail 'cannot read managed Caddy modules'
  validate_godaddy_module_line "$modules"
}

# Requires exactly one caddy list-modules --packages line for
# $EXPECTED_GODADDY_MODULE, and requires that exact line to be the module
# paired with exactly $EXPECTED_GODADDY_PACKAGE. Caddy v2.11.4 prints one
# "<module id> <go module path>" line per module for --packages, appending
# " => <path>" for a local replace directive and " [<error>]" when module
# info could not be read (cmd/commandfuncs.go printModuleInfo), so a package
# with different provenance, a replaced package, or a module id that merely
# contains the expected name as a substring is rejected.
validate_godaddy_module_line() {
  local modules=$1 line count module_pattern
  module_pattern=${EXPECTED_GODADDY_MODULE//./\\.}
  line=$(printf '%s\n' "$modules" | grep -E "^[[:space:]]*${module_pattern}([[:space:]]|$)" || true)
  count=$(printf '%s\n' "$line" | grep -c . || true)
  [[ "$count" -eq 1 ]] ||
    fail "managed Caddy must list exactly one $EXPECTED_GODADDY_MODULE module; found $count"
  line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [[ "$line" == "$EXPECTED_GODADDY_MODULE $EXPECTED_GODADDY_PACKAGE" ]] ||
    fail "managed Caddy must map module $EXPECTED_GODADDY_MODULE to exactly $EXPECTED_GODADDY_PACKAGE; got: $line"
}

# Mirrors tailscale.sh's check_lan() for the Caddy listener: no non-Tailscale
# global WSL LAN address may reach the loopback-only 8443 listener.
check_caddy_lan() {
  local addresses interface address count=0
  addresses=$(ip -o -4 addr show scope global |
    awk '{ interface=$2; for (i=3; i<=NF; i++) if ($i == "inet") { split($(i+1), a, "/"); print interface, a[1] } }') ||
    fail 'cannot inspect global IPv4 addresses'
  while read -r interface address; do
    [[ -n "$address" && "$interface" != tailscale0 ]] || continue
    ((count += 1))
    if curl --silent --show-error --insecure --connect-timeout 1 --max-time 5 "https://$address:8443/" >/dev/null 2>&1; then
      fail "Caddy is reachable on LAN address $address"
      return 1
    fi
  done <<<"$addresses"
  [[ "$count" -gt 0 ]] || fail 'no non-Tailscale global IPv4 address is available'
}

# Requires exactly one TCP listener on port 8443, bound to exactly
# 127.0.0.1:8443; rejects a port-80 or UDP-8443 listener; and retains the
# existing 31415 LAN check alongside a matching 8443 LAN probe.
validate_caddy_listener() {
  local tcp udp addresses count
  tcp=$(ss -ltnH) || fail 'cannot inspect Caddy TCP listeners'
  udp=$(ss -lunH) || fail 'cannot inspect Caddy UDP listeners'

  if printf '%s\n' "$tcp" | awk 'NF { print $4 }' | grep -qE ':80$'; then
    fail 'unexpected Caddy listener on port 80'
  fi
  if printf '%s\n' "$udp" | awk 'NF { print $4 }' | grep -qE ':8443$'; then
    fail 'unexpected Caddy UDP listener on port 8443'
  fi

  addresses=$(printf '%s\n' "$tcp" | awk 'NF { print $4 }' | grep -E ':8443$' || true)
  count=$(printf '%s\n' "$addresses" | grep -c . || true)
  [[ "$count" -eq 1 ]] || fail 'expected exactly one Caddy listener on port 8443'
  [[ "$addresses" == '127.0.0.1:8443' ]] ||
    fail 'Caddy listener is not loopback-only at 127.0.0.1:8443'

  check_lan
  check_caddy_lan
}

# Requires a currently trusted, unexpired, correctly named certificate and a
# proxied /api/health response matching the exact Firstp1ck health contract,
# without bypassing normal CA verification.
validate_caddy_tls_health() {
  local certificate health
  certificate=$(openssl s_client -connect 127.0.0.1:8443 -servername "$CUSTOM_HOSTNAME" \
    -verify_return_error </dev/null 2>&1) ||
    fail "certificate for $CUSTOM_HOSTNAME is not trusted"
  printf '%s\n' "$certificate" |
    openssl x509 -checkhost "$CUSTOM_HOSTNAME" -checkend "$CERT_MIN_VALIDITY_SECONDS" -noout ||
    fail "certificate for $CUSTOM_HOSTNAME is invalid, expired, or hostname-mismatched"

  health=$(curl --fail --silent --show-error \
    --resolve "$CUSTOM_HOSTNAME:8443:127.0.0.1" \
    "https://$CUSTOM_HOSTNAME:8443/api/health") ||
    fail 'Caddy-proxied Pi Web UI health endpoint failed'
  node - "$PI_LAUNCHER" "$health" <<'NODE' || fail 'Caddy-proxied Pi Web UI health identity is invalid'
const launcher = process.argv[2];
const response = JSON.parse(process.argv[3]);
const data = response;
const network = data?.network;
if (response.ok !== true || data?.webuiVersion !== '0.10.3' || data?.piVersion !== '0.84.4' ||
    network?.open !== false || network?.host !== '127.0.0.1' || network?.port !== 31415 ||
    !Array.isArray(network?.networkUrls) || network.networkUrls.length !== 0 ||
    !Array.isArray(data?.tabs)) process.exit(1);
const prefix = `${launcher} --mode rpc`;
for (const tab of data.tabs) {
  if (tab.running === true && !(tab.command === prefix ||
      (typeof tab.command === 'string' && tab.command.startsWith(prefix) && /\s/.test(tab.command[prefix.length])))) {
    process.exit(1);
  }
}
NODE
}

# Read-only custom-domain check. Runs the strict Firstp1ck preflight,
# Tailscale version/online checks, DNS, source integrity, installed Caddy
# state, listener/TLS health, and route classification, in that order, so
# nothing mutation-adjacent runs before every boundary has been proven.
# `empty` is accepted only as a genuine non-published pre-install state (no
# managed Caddy artifact exists yet); any other state requires Caddy to be
# fully healthy, and `legacy-exact` is reported as ready-to-migrate rather
# than as steady-state success. route_state() already fails closed on any
# foreign or additional route, so no other value can reach the final case.
check_domain() {
  local route
  strict_firstpick_preflight
  require_tailscale
  require_tailscale_version
  validate_public_dns
  validate_caddy_source
  set_caddy_paths
  route=$(route_state) || return 1

  if [[ "$route" == empty ]] && ! path_exists "$CADDY_BINARY" && ! path_exists "$CADDY_ENTRYPOINT" &&
    ! path_exists "$CADDY_CONFIG" && ! path_exists "$CADDY_UNIT"; then
    printf 'custom domain is not yet installed\n'
    return 0
  fi

  validate_installed_caddy
  validate_caddy_listener
  validate_caddy_tls_health

  case "$route" in
    legacy-exact) printf 'custom domain is ready-to-migrate\n' ;;
    raw-exact) printf 'custom domain is raw-exact and healthy\n' ;;
    *) fail "unexpected Tailscale route state for custom domain: $route" ;;
  esac
}

# ---------------------------------------------------------------------------
# Candidate-first setup
# ---------------------------------------------------------------------------

# The fixed publication contract for the four managed artifacts, in
# publication order: destination, staged file name, mode, and label.
# restore_prior_caddy() walks the same arrays in reverse.
caddy_artifact_contract() {
  CADDY_ARTIFACT_DESTS=("$CADDY_BINARY" "$CADDY_ENTRYPOINT" "$CADDY_CONFIG" "$CADDY_UNIT")
  CADDY_ARTIFACT_NAMES=(caddy caddy-entrypoint Caddyfile installed-unit)
  CADDY_ARTIFACT_MODES=(0755 0755 0644 0644)
  CADDY_ARTIFACT_LABELS=(
    'managed Caddy binary'
    'managed Caddy entrypoint'
    'managed Caddyfile'
    'managed Caddy unit'
  )
}

# Requires the encrypted credential to be a root-owned regular file with no
# group or other permission bits, then proves the classic GoDaddy key is
# accepted by the production Domains API with a non-mutating record read.
# The plaintext never reaches argv, an environment variable, a temporary
# file, or any output: systemd-creds decrypts straight into the validator's
# standard input, and only a status-only result is reported. Shell tracing is
# never enabled here.
validate_godaddy_credential() {
  local owner mode
  [[ -f "$CADDY_CREDENTIAL" && ! -L "$CADDY_CREDENTIAL" ]] ||
    fail "encrypted GoDaddy credential is unavailable: $CADDY_CREDENTIAL"
  owner=$(stat -c %u "$CADDY_CREDENTIAL") ||
    fail 'cannot inspect the encrypted GoDaddy credential'
  [[ "$owner" == 0 ]] || fail 'encrypted GoDaddy credential must be owned by root'
  mode=$(stat -c %a "$CADDY_CREDENTIAL") ||
    fail 'cannot inspect encrypted GoDaddy credential permissions'
  [[ $((8#$mode & 8#077)) -eq 0 ]] ||
    fail 'encrypted GoDaddy credential must not be group- or world-accessible'

  set -o pipefail
  sudo systemd-creds decrypt \
    --name="$CREDENTIAL_NAME" \
    "$CADDY_CREDENTIAL" - |
    node -e '
const https = require("node:https");
let token = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { token += chunk; });
process.stdin.on("end", () => {
  token = token.replace(/\r?\n$/, "");
  if (!/^[^:\r\n]+:[^:\r\n]+$/.test(token)) process.exit(2);
  const request = https.get({
    hostname: "api.godaddy.com",
    path: "/v1/domains/dpao.la/records?limit=1",
    headers: {Authorization: `sso-key ${token}`, Accept: "application/json"},
  }, response => {
    response.resume();
    response.on("end", () => {
      if (response.statusCode === 200) {
        console.log("GoDaddy DNS API credential is valid");
      } else {
        console.error(`error: GoDaddy DNS API returned HTTP ${response.statusCode}`);
        process.exitCode = 1;
      }
    });
  });
  request.on("error", () => {
    console.error("error: GoDaddy DNS API request failed");
    process.exitCode = 1;
  });
});' ||
    fail 'GoDaddy DNS API credential validation failed'
}

# Refuses to reconcile over an existing managed path that is not an exact
# managed artifact. An absent artifact is a normal first install; a present
# one must be a root-owned regular file, and each present static artifact
# must be byte-identical to its tracked source.
require_reconcilable_caddy_state() {
  local index destination
  caddy_artifact_contract
  for index in "${!CADDY_ARTIFACT_DESTS[@]}"; do
    destination=${CADDY_ARTIFACT_DESTS[index]}
    path_exists "$destination" || continue
    require_managed_caddy_artifact "$destination" "${CADDY_ARTIFACT_LABELS[index]}"
  done
  if path_exists "$CADDY_ENTRYPOINT"; then
    cmp -s "$SCRIPT_DIR/caddy-entrypoint.sh" "$CADDY_ENTRYPOINT" ||
      fail 'refusing to replace a foreign managed Caddy entrypoint'
  fi
  if path_exists "$CADDY_CONFIG"; then
    cmp -s <(render_caddyfile) "$CADDY_CONFIG" ||
      fail 'refusing to replace a foreign managed Caddyfile'
  fi
  if path_exists "$CADDY_UNIT"; then
    cmp -s <(render_caddy_unit "$CADDY_ENTRYPOINT") "$CADDY_UNIT" ||
      fail 'refusing to replace a foreign managed Caddy unit'
  fi
}

# Builds and fully validates the pinned private candidate in a fresh 0700
# staging directory. Nothing here touches a managed path or the live service,
# so any failure leaves the system exactly as it was.
build_caddy_candidate() {
  local candidate version modules
  CADDY_STAGING=$(mktemp -d "$STATE_ROOT/.caddy-setup.XXXXXX") || return 1
  chmod 0700 "$CADDY_STAGING" || return 1
  candidate=$CADDY_STAGING

  "$MISE_LAUNCHER" exec -- go run "github.com/caddyserver/xcaddy/cmd/xcaddy@v$XCADDY_VERSION" \
    build "v$CADDY_VERSION" \
    --with "$EXPECTED_GODADDY_PACKAGE@v$GODADDY_MODULE_VERSION" \
    --output "$candidate/caddy" ||
    fail 'pinned Caddy candidate build failed'
  [[ -f "$candidate/caddy" && -x "$candidate/caddy" ]] ||
    fail 'pinned Caddy candidate binary was not produced'

  cp "$SCRIPT_DIR/caddy-entrypoint.sh" "$candidate/caddy-entrypoint" || return 1
  chmod 0755 "$candidate/caddy-entrypoint" || return 1
  bash -n "$candidate/caddy-entrypoint" ||
    fail 'candidate Caddy entrypoint failed syntax validation'
  command -v shellcheck >/dev/null ||
    fail 'ShellCheck is required to validate the candidate Caddy entrypoint'
  shellcheck "$candidate/caddy-entrypoint" ||
    fail 'candidate Caddy entrypoint failed ShellCheck'

  render_caddyfile >"$candidate/Caddyfile" || return 1
  # The staged unit names the staged entrypoint so systemd-analyze verifies a
  # real executable path; the separately rendered installed unit names the
  # fixed live entrypoint that installed-state checks compare byte-for-byte.
  render_caddy_unit "$candidate/caddy-entrypoint" >"$candidate/pi-webui-caddy.service" || return 1
  render_caddy_unit "$CADDY_ENTRYPOINT" >"$candidate/installed-unit" || return 1

  version=$("$candidate/caddy" version) || fail 'cannot read candidate Caddy version'
  [[ "$version" == "$SUPPORTED_CADDY_VERSION"* ]] ||
    fail "candidate Caddy is not $SUPPORTED_CADDY_VERSION"
  modules=$("$candidate/caddy" list-modules --packages) ||
    fail 'cannot read candidate Caddy modules'
  validate_godaddy_module_line "$modules"

  # A placeholder credential keeps the real token out of the adapted JSON,
  # which is discarded rather than printed.
  GODADDY_API_TOKEN=placeholder:placeholder \
    "$candidate/caddy" adapt --config "$candidate/Caddyfile" --adapter caddyfile --validate >/dev/null ||
    fail 'candidate Caddy configuration failed validation'
  systemd-analyze verify "$candidate/pi-webui-caddy.service" ||
    fail 'candidate Caddy unit failed systemd verification'
}

# Records prior presence, exact file contents, enablement, and activity in
# the private staging directory so restoration can be exact.
capture_prior_caddy_state() {
  local index destination
  CADDY_PRIOR_PRESENT=()
  CADDY_PRIOR_ENABLED=0
  CADDY_PRIOR_ACTIVE=0
  for index in "${!CADDY_ARTIFACT_DESTS[@]}"; do
    destination=${CADDY_ARTIFACT_DESTS[index]}
    CADDY_PRIOR_PRESENT[index]=0
    if path_exists "$destination"; then
      CADDY_PRIOR_PRESENT[index]=1
      cp "$destination" "$CADDY_STAGING/prior-${CADDY_ARTIFACT_NAMES[index]}" || return 1
    fi
  done
  if systemctl is-enabled "$CADDY_SERVICE" >/dev/null 2>&1; then CADDY_PRIOR_ENABLED=1; fi
  if systemctl is-active "$CADDY_SERVICE" >/dev/null 2>&1; then CADDY_PRIOR_ACTIVE=1; fi
}

# Publishes one root-owned artifact atomically: install to a sibling
# temporary path with the final mode, then rename over the destination.
publish_caddy_artifact() {
  local source=$1 destination=$2 mode=$3 temporary=$2.pi-webui-new
  sudo install -o root -g root -m "$mode" "$source" "$temporary" || return 1
  sudo mv -f "$temporary" "$destination" || return 1
}

# Selects the bounded readiness budget. Tests may shorten it through the
# usual Bats-only override guard; production always waits the full budget.
caddy_ready_budget() {
  CADDY_READY_ATTEMPTS=$CADDY_READY_ATTEMPTS_DEFAULT
  CADDY_READY_INTERVAL=$CADDY_READY_INTERVAL_DEFAULT
  if [[ -n ${PI_WEBUI_TEST_READY_BUDGET:-} ]]; then
    require_test_override "$STATE_ROOT"
    CADDY_READY_ATTEMPTS=${PI_WEBUI_TEST_READY_BUDGET%%:*}
    CADDY_READY_INTERVAL=${PI_WEBUI_TEST_READY_BUDGET##*:}
  fi
}

# Cheap, side-effect-free readiness signal that only paces the bounded wait:
# the service is running and a normally CA-verified request already reaches
# the proxied health endpoint, which cannot happen before DNS-01 issuance
# completes. Every command is explicitly status-checked because this function
# is called from a condition, where Bash suppresses errexit. The
# authoritative validation runs afterwards, under normal error handling.
caddy_ready_signal() {
  systemctl is-active "$CADDY_SERVICE" >/dev/null 2>&1 || return 1
  curl --fail --silent --show-error \
    --resolve "$CUSTOM_HOSTNAME:8443:127.0.0.1" \
    "https://$CUSTOM_HOSTNAME:8443/api/health" >/dev/null 2>&1 || return 1
}

# Waits, bounded, for the loopback listener, DNS-01 issuance, a trusted
# certificate, and proxied Firstp1ck health, then requires the full installed
# state to be exact. A still-unready service fails with the exact remaining
# boundary error.
wait_for_caddy_ready() {
  local attempt
  caddy_ready_budget
  for ((attempt = 1; attempt < CADDY_READY_ATTEMPTS; attempt++)); do
    if caddy_ready_signal; then break; fi
    sleep "$CADDY_READY_INTERVAL"
  done
  validate_installed_caddy
  validate_caddy_listener
  validate_caddy_tls_health
}

# Publishes the validated candidate, reloads systemd, enables and restarts the
# dedicated service, and waits for readiness. The Tailscale route is never
# touched.
publish_caddy_candidate() {
  local index destination
  for index in "${!CADDY_ARTIFACT_DESTS[@]}"; do
    destination=${CADDY_ARTIFACT_DESTS[index]}
    sudo install -d -o root -g root -m 0755 "$(dirname "$destination")" || return 1
    publish_caddy_artifact "$CADDY_STAGING/${CADDY_ARTIFACT_NAMES[index]}" \
      "$destination" "${CADDY_ARTIFACT_MODES[index]}" || return 1
    CADDY_PUBLISHED[index]=1
  done
  sudo systemctl daemon-reload || return 1
  caddy_daemon_reloaded=1
  sudo systemctl enable "$CADDY_SERVICE" || return 1
  caddy_enablement_changed=1
  # restart, not start: start is a no-op for an already-active unit, which
  # would leave a prior Caddy process serving the previous binary in memory
  # while every on-disk and endpoint check passes. restart also starts an
  # inactive or newly installed unit, so first install is unchanged.
  sudo systemctl restart "$CADDY_SERVICE" || return 1
  caddy_started=1
  wait_for_caddy_ready
}

# Stops the candidate, restores every published artifact in reverse order,
# reloads systemd, and restores prior enablement and activity. Certificates,
# ACME state, and the encrypted credential are never removed. A failed
# restoration retains and reports the private staging path.
restore_prior_caddy() {
  local failed=0 index destination temporary
  set +e
  if [[ "$caddy_started" -eq 1 ]]; then
    sudo systemctl stop "$CADDY_SERVICE" || failed=1
    caddy_started=0
  fi
  for ((index = ${#CADDY_ARTIFACT_DESTS[@]} - 1; index >= 0; index--)); do
    [[ "${CADDY_PUBLISHED[index]}" -eq 1 ]] || continue
    destination=${CADDY_ARTIFACT_DESTS[index]}
    if [[ "${CADDY_PRIOR_PRESENT[index]}" -eq 1 ]]; then
      temporary=$destination.pi-webui-restore
      if ! sudo install -o root -g root -m "${CADDY_ARTIFACT_MODES[index]}" \
        "$CADDY_STAGING/prior-${CADDY_ARTIFACT_NAMES[index]}" "$temporary" ||
        ! sudo mv -f "$temporary" "$destination"; then
        failed=1
      fi
    else
      sudo rm -f -- "$destination" || failed=1
    fi
    CADDY_PUBLISHED[index]=0
  done
  if [[ "$caddy_daemon_reloaded" -eq 1 ]]; then
    sudo systemctl daemon-reload || failed=1
    caddy_daemon_reloaded=0
  fi
  if [[ "$caddy_enablement_changed" -eq 1 ]]; then
    if [[ "$CADDY_PRIOR_ENABLED" -eq 1 ]]; then
      sudo systemctl enable "$CADDY_SERVICE" || failed=1
    else
      sudo systemctl disable "$CADDY_SERVICE" || failed=1
    fi
    caddy_enablement_changed=0
  fi
  if [[ "$CADDY_PRIOR_ACTIVE" -eq 1 ]]; then
    sudo systemctl start "$CADDY_SERVICE" || failed=1
  fi
  if [[ "$failed" -eq 0 ]]; then
    cleanup_caddy_staging || failed=1
  fi
  set -e
  if [[ "$failed" -ne 0 ]]; then
    fail "restoration failed; preserving staging path: $CADDY_STAGING"
    return 1
  fi
}

cleanup_caddy_staging() {
  [[ -n ${CADDY_STAGING:-} ]] || return 0
  path_exists "$CADDY_STAGING" || return 0
  rm -rf -- "$CADDY_STAGING"
}

# Runs on any early exit from setup: a pre-publication failure removes only
# the private candidate, and a post-publication failure restores the prior
# managed state.
caddy_setup_cleanup() {
  [[ "$caddy_setup_complete" -eq 0 ]] || return 0
  if [[ "${CADDY_PUBLISHED[*]}" == *1* || "$caddy_started" -eq 1 ||
    "$caddy_daemon_reloaded" -eq 1 || "$caddy_enablement_changed" -eq 1 ]]; then
    restore_prior_caddy || true
  else
    cleanup_caddy_staging || true
  fi
}

# Candidate-first custom-domain setup. Every external boundary is proven
# before the private build, the build is fully validated before publication,
# and publication is bounded and reversible. The Tailscale Serve route is
# deliberately left untouched: migration is a separate, explicitly approved
# operation.
#
# Recovery runs from an EXIT trap rather than from an `if` around publication
# so that normal errexit stays active throughout: Bash suppresses errexit for
# a function called in a condition, which would let a failed boundary check
# continue into the next one.
setup_domain() {
  require_supported_platform
  resolve_source
  validate_apply_source
  strict_firstpick_preflight
  require_tailscale
  require_tailscale_version
  require_route_state legacy-exact
  validate_public_dns
  validate_caddy_source
  set_caddy_paths
  validate_godaddy_credential
  require_reconcilable_caddy_state

  caddy_started=0
  caddy_daemon_reloaded=0
  caddy_enablement_changed=0
  caddy_setup_complete=0
  CADDY_PUBLISHED=(0 0 0 0)
  CADDY_PRIOR_PRESENT=(0 0 0 0)
  CADDY_PRIOR_ENABLED=0
  CADDY_PRIOR_ACTIVE=0

  trap caddy_setup_cleanup EXIT
  build_caddy_candidate
  capture_prior_caddy_state
  publish_caddy_candidate
  caddy_setup_complete=1
  trap - EXIT

  cleanup_caddy_staging
  printf 'custom domain is ready-to-migrate: %s is healthy and the legacy route is unchanged\n' \
    "$CADDY_SERVICE"
}

usage() {
  printf 'usage: %s check|setup|migrate|rollback\n' "$0"
}

main() {
  [[ $# -eq 1 ]] || {
    usage >&2
    return 2
  }
  case "$1" in
    check) check_domain ;;
    setup) setup_domain ;;
    migrate | rollback) fail "$1 is not implemented yet" ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
