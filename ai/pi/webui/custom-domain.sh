#!/usr/bin/env bash
# Read-only checks, candidate-first setup, migration, and rollback for the
# tailnet-only custom HTTPS hostname (pi.dpao.la) in front of Pi Web UI.
#
# This file implements the static Caddy source contract (fixed managed paths,
# the exact tracked Caddyfile/unit renderers, and a source-only integrity
# check), the full read-only `check` CLI verb (strict Firstp1ck preflight,
# DNS, installed Caddy, listener, and TLS/health validation, plus route
# classification), the candidate-first `setup` verb (credential
# validation, pinned private Caddy build, bounded publication, and automatic
# restoration), the transactional `migrate` verb (plan display, immediate
# approval, exact route replacement, tailnet verification, and automatic
# legacy restoration), and the conservative `rollback` verb (legacy ingress
# restoration plus removal of only the exact managed Caddy artifacts).

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
# certificate, and proxy health. The retry loop only paces that wait: its
# worst case is attempts * probe timeout + (attempts - 1) * interval =
# 15 * 10 + 14 * 5 = 220 seconds, which leaves room inside the hard deadline
# below for the authoritative installed/listener/LAN/TLS/health checks that
# always follow it (the trailing validate_caddy_tls_health alone is bounded
# by TLS_HANDSHAKE_TIMEOUT + PROBE_MAX_TIME = 45 seconds), so a still-unready
# service normally fails with its own exact boundary error.
readonly CADDY_READY_ATTEMPTS_DEFAULT=15
readonly CADDY_READY_INTERVAL_DEFAULT=5
readonly CADDY_READY_PROBE_TIMEOUT=10
# The real bound on readiness, which arithmetic alone cannot provide:
# validate_caddy_listener's check_lan() and check_caddy_lan() probe every
# non-Tailscale global IPv4 address, so the cost of the authoritative checks
# scales with the host's interface count. wait_for_caddy_ready() therefore
# runs the loop and every authoritative check inside one `timeout`, making the
# documented "at most five minutes" a wall-clock guarantee: 290 seconds plus
# 5 seconds of kill grace = 295 seconds, whatever the interface count.
readonly CADDY_READY_DEADLINE_DEFAULT=290
readonly CADDY_READY_KILL_GRACE=5
# Explicit bounds for every other network and TLS probe, so a black-holed
# packet path fails within a known deadline instead of hanging a mutation
# window open.
readonly PROBE_CONNECT_TIMEOUT=5
readonly PROBE_MAX_TIME=30
readonly TLS_HANDSHAKE_TIMEOUT=15
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
export CADDY_READY_PROBE_TIMEOUT PROBE_CONNECT_TIMEOUT PROBE_MAX_TIME TLS_HANDSHAKE_TIMEOUT

render_caddyfile() { cat "$SCRIPT_DIR/Caddyfile.in"; }

# shellcheck disable=SC2120 # entrypoint override is used by later staged-build tasks
render_caddy_unit() {
  local entrypoint=${1:-$CADDY_ENTRYPOINT} rendered
  safe_unit_path "$entrypoint" || return 1
  rendered=$(<"$SCRIPT_DIR/pi-webui-caddy.service.in")
  rendered=${rendered//@CADDY_ENTRYPOINT@/$entrypoint}
  [[ "$rendered" != *'@CADDY_ENTRYPOINT@'* ]] || {
    fail 'Caddy unit substitution failed'
    return 1
  }
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
  path_exists "$INSTALLED_RUNTIME" || {
    fail 'installed runtime is unavailable'
    return 1
  }
  "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$INSTALLED_RUNTIME"
  path_exists "$UNIT_PATH" || {
    fail 'installed service unit is unavailable'
    return 1
  }
  validate_landing_worktree "$LANDING_WORKTREE"
  validate_unit "$UNIT_PATH"
  validate_active_health "$PI_LAUNCHER"
}

# Emits the node's single online Tailscale IPv4 in 100.64.0.0/10. Fails
# closed on an offline node, zero or multiple IPv4 addresses, or an address
# outside the CGNAT range GoDaddy DNS is expected to publish.
current_tailscale_ipv4() {
  local status
  status=$(tailscale status --json) || {
    fail 'cannot read Tailscale status'
    return 1
  }
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
    a=$(dig +short A "$CUSTOM_HOSTNAME" "@$server") || {
      fail "cannot query A for $CUSTOM_HOSTNAME at $server"
      return 1
    }
    aaaa=$(dig +short AAAA "$CUSTOM_HOSTNAME" "@$server") || {
      fail "cannot query AAAA for $CUSTOM_HOSTNAME at $server"
      return 1
    }
    cname=$(dig +short CNAME "$CUSTOM_HOSTNAME" "@$server") || {
      fail "cannot query CNAME for $CUSTOM_HOSTNAME at $server"
      return 1
    }
  else
    a=$(dig +short A "$CUSTOM_HOSTNAME") || {
      fail "cannot query A for $CUSTOM_HOSTNAME"
      return 1
    }
    aaaa=$(dig +short AAAA "$CUSTOM_HOSTNAME") || {
      fail "cannot query AAAA for $CUSTOM_HOSTNAME"
      return 1
    }
    cname=$(dig +short CNAME "$CUSTOM_HOSTNAME") || {
      fail "cannot query CNAME for $CUSTOM_HOSTNAME"
      return 1
    }
  fi
  a=$(printf '%s\n' "$a" | normalize_dns_answer)
  aaaa=$(printf '%s\n' "$aaaa" | normalize_dns_answer)
  cname=$(printf '%s\n' "$cname" | normalize_dns_answer)
  [[ -z "$aaaa" ]] || {
    fail "unexpected AAAA answer for $CUSTOM_HOSTNAME"
    return 1
  }
  [[ -z "$cname" ]] || {
    fail "unexpected CNAME answer for $CUSTOM_HOSTNAME: $cname"
    return 1
  }
  count=$(printf '%s\n' "$a" | grep -c . || true)
  [[ "$count" -eq 1 ]] || {
    fail "expected exactly one A answer for $CUSTOM_HOSTNAME; got $count"
    return 1
  }
  [[ "$a" == "$expected" ]] || fail "stale Tailscale IPv4 for $CUSTOM_HOSTNAME: got $a, expected $expected"
}

# Requires $DNS_ZONE to have at least one authoritative name server, then
# requires every view -- the client's normal resolver and each authoritative
# server directly -- to agree on one exact A equal to the current Tailscale
# IPv4 with no CNAME or AAAA. Never writes DNS.
validate_public_dns() {
  local ipv4 authoritative server
  ipv4=$(current_tailscale_ipv4) || return 1
  authoritative=$(dig +short NS "$DNS_ZONE") || {
    fail "cannot read authoritative name servers for $DNS_ZONE"
    return 1
  }
  authoritative=$(printf '%s\n' "$authoritative" | normalize_dns_answer)
  [[ -n "$authoritative" ]] || {
    fail "$DNS_ZONE has no authoritative name server"
    return 1
  }

  validate_dns_view '' "$ipv4" || return 1
  while IFS= read -r server; do
    [[ -n "$server" ]] || continue
    validate_dns_view "$server" "$ipv4" || return 1
  done <<<"$authoritative"
}

# Requires $path to be a real, non-symlink, root-owned regular file.
require_managed_caddy_artifact() {
  local path=$1 label=$2 owner
  [[ -f "$path" && ! -L "$path" ]] || {
    fail "$label is unavailable"
    return 1
  }
  owner=$(stat -c %u "$path") || {
    fail "cannot inspect $label ownership"
    return 1
  }
  [[ "$owner" == 0 ]] || fail "$label must be owned by root"
}

# Requires the Caddy binary at $CADDY_BINARY to be the exact pinned private
# build: executable, reporting $SUPPORTED_CADDY_VERSION, and carrying exactly
# the pinned GoDaddy module at exactly the pinned module version. This is the
# only identity available for a compiled artifact, so it gates reconciling
# over, validating, and removing an existing binary alike.
validate_caddy_binary_identity() {
  local version modules
  [[ -x "$CADDY_BINARY" ]] || {
    fail 'managed Caddy binary is not executable'
    return 1
  }
  version=$("$CADDY_BINARY" version) || {
    fail 'cannot read managed Caddy version'
    return 1
  }
  [[ "$version" == "$SUPPORTED_CADDY_VERSION"* ]] || {
    fail "managed Caddy is not $SUPPORTED_CADDY_VERSION"
    return 1
  }
  modules=$("$CADDY_BINARY" list-modules --packages) || {
    fail 'cannot read managed Caddy modules'
    return 1
  }
  validate_godaddy_module_line "$modules" || return 1
  modules=$("$CADDY_BINARY" list-modules --versions --packages) || {
    fail 'cannot read managed Caddy module versions'
    return 1
  }
  validate_godaddy_module_version_line "$modules"
}

# Requires the installed Caddy binary, entrypoint, Caddyfile, and unit to be
# exact root-owned managed artifacts byte-identical to the tracked renderers,
# the installed Caddy version to be $SUPPORTED_CADDY_VERSION, the GoDaddy DNS
# module to be present, and the dedicated system service to be active.
validate_installed_caddy() {
  set_caddy_paths
  require_managed_caddy_artifact "$CADDY_BINARY" 'managed Caddy binary' || return 1
  [[ -x "$CADDY_BINARY" ]] || {
    fail 'managed Caddy binary is not executable'
    return 1
  }
  require_managed_caddy_artifact "$CADDY_ENTRYPOINT" 'managed Caddy entrypoint' || return 1
  [[ -x "$CADDY_ENTRYPOINT" ]] || {
    fail 'managed Caddy entrypoint is not executable'
    return 1
  }
  require_managed_caddy_artifact "$CADDY_CONFIG" 'managed Caddyfile' || return 1
  require_managed_caddy_artifact "$CADDY_UNIT" 'managed Caddy unit' || return 1

  cmp -s <(render_caddyfile) "$CADDY_CONFIG" || {
    fail 'installed Caddyfile differs from the managed configuration'
    return 1
  }
  cmp -s <(render_caddy_unit "$CADDY_ENTRYPOINT") "$CADDY_UNIT" || {
    fail 'installed Caddy unit differs from the managed configuration'
    return 1
  }

  systemctl is-active "$CADDY_SERVICE" >/dev/null || {
    fail 'Caddy service is not active'
    return 1
  }

  validate_caddy_binary_identity
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
  [[ "$count" -eq 1 ]] || {
    fail "managed Caddy must list exactly one $EXPECTED_GODADDY_MODULE module; found $count"
    return 1
  }
  line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [[ "$line" == "$EXPECTED_GODADDY_MODULE $EXPECTED_GODADDY_PACKAGE" ]] ||
    fail "managed Caddy must map module $EXPECTED_GODADDY_MODULE to exactly $EXPECTED_GODADDY_PACKAGE; got: $line"
}

# The same exact-line contract for `list-modules --versions --packages`, which
# Caddy v2.11.4 renders as "<module id> <go module version> <go module path>"
# (cmd/commandfuncs.go printModuleInfo prints the version before the package
# and appends the same " => <path>" and " [<error>]" annotations). Pinning the
# module version is what distinguishes the approved private build from a
# same-named module built against a different provider release.
validate_godaddy_module_version_line() {
  local modules=$1 line count module_pattern
  module_pattern=${EXPECTED_GODADDY_MODULE//./\\.}
  line=$(printf '%s\n' "$modules" | grep -E "^[[:space:]]*${module_pattern}([[:space:]]|$)" || true)
  count=$(printf '%s\n' "$line" | grep -c . || true)
  [[ "$count" -eq 1 ]] || {
    fail "managed Caddy must list exactly one $EXPECTED_GODADDY_MODULE module; found $count"
    return 1
  }
  line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [[ "$line" == "$EXPECTED_GODADDY_MODULE v$GODADDY_MODULE_VERSION $EXPECTED_GODADDY_PACKAGE" ]] ||
    fail "managed Caddy must provide $EXPECTED_GODADDY_MODULE at exactly v$GODADDY_MODULE_VERSION from $EXPECTED_GODADDY_PACKAGE; got: $line"
}

# Mirrors tailscale.sh's check_lan() for the Caddy listener: no non-Tailscale
# global WSL LAN address may reach the loopback-only 8443 listener.
check_caddy_lan() {
  local addresses interface address count=0
  addresses=$(ip -o -4 addr show scope global |
    awk '{ interface=$2; for (i=3; i<=NF; i++) if ($i == "inet") { split($(i+1), a, "/"); print interface, a[1] } }') || {
    fail 'cannot inspect global IPv4 addresses'
    return 1
  }
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
#
# Each match is captured and then tested for emptiness rather than piped into
# `grep -q`: `grep -q` exits on its first match, which SIGPIPEs the producer
# and, under `set -o pipefail`, turns a real forbidden-listener match into a
# failed pipeline that an `if` would read as "no match".
validate_caddy_listener() {
  local tcp udp addresses matches count
  tcp=$(ss -ltnH) || {
    fail 'cannot inspect Caddy TCP listeners'
    return 1
  }
  udp=$(ss -lunH) || {
    fail 'cannot inspect Caddy UDP listeners'
    return 1
  }

  matches=$(printf '%s\n' "$tcp" | awk 'NF && $4 ~ /:80$/ { print $4 }') || {
    fail 'cannot inspect Caddy TCP listeners'
    return 1
  }
  [[ -z "$matches" ]] || {
    fail 'unexpected Caddy listener on port 80'
    return 1
  }
  matches=$(printf '%s\n' "$udp" | awk 'NF && $4 ~ /:8443$/ { print $4 }') || {
    fail 'cannot inspect Caddy UDP listeners'
    return 1
  }
  [[ -z "$matches" ]] || {
    fail 'unexpected Caddy UDP listener on port 8443'
    return 1
  }

  addresses=$(printf '%s\n' "$tcp" | awk 'NF && $4 ~ /:8443$/ { print $4 }') || {
    fail 'cannot inspect Caddy TCP listeners'
    return 1
  }
  count=$(printf '%s\n' "$addresses" | awk 'NF { count++ } END { print count+0 }')
  [[ "$count" -eq 1 ]] || {
    fail 'expected exactly one Caddy listener on port 8443'
    return 1
  }
  [[ "$addresses" == '127.0.0.1:8443' ]] || {
    fail 'Caddy listener is not loopback-only at 127.0.0.1:8443'
    return 1
  }

  check_lan || return 1
  check_caddy_lan
}

# Requires a currently trusted, unexpired, correctly named certificate at
# $address:$port and a proxied /api/health response matching the exact
# Firstp1ck health contract, without bypassing normal CA verification.
validate_caddy_certificate_and_health() {
  local address=$1 port=$2 url=$3 certificate health
  certificate=$(timeout "$TLS_HANDSHAKE_TIMEOUT" \
    openssl s_client -connect "$address:$port" -servername "$CUSTOM_HOSTNAME" \
    -verify_return_error </dev/null 2>&1) || {
    fail "certificate for $CUSTOM_HOSTNAME is not trusted at $address:$port"
    return 1
  }
  printf '%s\n' "$certificate" |
    openssl x509 -checkhost "$CUSTOM_HOSTNAME" -checkend "$CERT_MIN_VALIDITY_SECONDS" -noout || {
    fail "certificate for $CUSTOM_HOSTNAME is invalid, expired, or hostname-mismatched"
    return 1
  }

  health=$(curl --fail --silent --show-error \
    --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
    --resolve "$CUSTOM_HOSTNAME:$port:$address" \
    "$url") || {
    fail "Caddy-proxied Pi Web UI health endpoint failed at $url"
    return 1
  }
  node - "$PI_LAUNCHER" "$health" <<'NODE' || fail 'Caddy-proxied Pi Web UI health identity is invalid'
const launcher = process.argv[2];
const response = JSON.parse(process.argv[3]);
const data = response;
const network = data?.network;
if (response.ok !== true || data?.webuiVersion !== '0.10.4' || data?.piVersion !== '0.85.1' ||
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

# Verifies the loopback listener Caddy actually serves.
validate_caddy_tls_health() {
  validate_caddy_certificate_and_health 127.0.0.1 8443 "https://$CUSTOM_HOSTNAME:8443/api/health"
}

# Verifies the published ingress the way a tailnet client reaches it: through
# the node's Tailscale IPv4 on port 443, which only answers once the raw TCP
# Serve route forwards to Caddy. Proving the tailnet path is the point of the
# migration, so this cannot be replaced by the loopback check.
validate_caddy_tls_health_through_tailnet() {
  local ipv4
  ipv4=$(current_tailscale_ipv4) || return 1
  validate_caddy_certificate_and_health "$ipv4" 443 "https://$CUSTOM_HOSTNAME/api/health"
}

# Read-only custom-domain check. Runs the strict Firstp1ck preflight,
# Tailscale version/online checks, DNS, source integrity, installed Caddy
# state, listener/TLS health, and route classification, in that order, so
# nothing mutation-adjacent runs before every boundary has been proven.
# `empty` or the transitional `legacy-exact` route is accepted as a
# pre-install state only when no managed Caddy artifact exists. `raw-exact`
# always requires a healthy Caddy backend. route_state() already fails closed
# on any foreign or additional route, so no other value can reach the final
# case.
check_domain() {
  local route
  strict_firstpick_preflight
  require_tailscale
  require_tailscale_version
  validate_public_dns
  validate_caddy_source
  set_caddy_paths
  route=$(route_state) || return 1

  if [[ "$route" == empty || "$route" == legacy-exact ]] &&
    ! path_exists "$CADDY_BINARY" && ! path_exists "$CADDY_ENTRYPOINT" &&
    ! path_exists "$CADDY_CONFIG" && ! path_exists "$CADDY_UNIT"; then
    printf 'custom domain is not yet installed; Tailscale route is %s\n' "$route"
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
  [[ -f "$CADDY_CREDENTIAL" && ! -L "$CADDY_CREDENTIAL" ]] || {
    fail "encrypted GoDaddy credential is unavailable: $CADDY_CREDENTIAL"
    return 1
  }
  owner=$(stat -c %u "$CADDY_CREDENTIAL") || {
    fail 'cannot inspect the encrypted GoDaddy credential'
    return 1
  }
  [[ "$owner" == 0 ]] || {
    fail 'encrypted GoDaddy credential must be owned by root'
    return 1
  }
  mode=$(stat -c %a "$CADDY_CREDENTIAL") || {
    fail 'cannot inspect encrypted GoDaddy credential permissions'
    return 1
  }
  [[ $((8#$mode & 8#077)) -eq 0 ]] || {
    fail 'encrypted GoDaddy credential must not be group- or world-accessible'
    return 1
  }

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
# one must be a root-owned regular file, each present static artifact must be
# byte-identical to its tracked source, and a present binary must prove the
# exact pinned Caddy and GoDaddy-module identity. Without the binary check a
# foreign root-owned executable at the managed path would be silently
# overwritten by publication.
require_reconcilable_caddy_state() {
  local index destination
  caddy_artifact_contract
  for index in "${!CADDY_ARTIFACT_DESTS[@]}"; do
    destination=${CADDY_ARTIFACT_DESTS[index]}
    path_exists "$destination" || continue
    require_managed_caddy_artifact "$destination" "${CADDY_ARTIFACT_LABELS[index]}" || return 1
  done
  if path_exists "$CADDY_BINARY"; then
    validate_caddy_binary_identity || return 1
  fi
  if path_exists "$CADDY_ENTRYPOINT"; then
    cmp -s "$SCRIPT_DIR/caddy-entrypoint.sh" "$CADDY_ENTRYPOINT" || {
      fail 'refusing to replace a foreign managed Caddy entrypoint'
      return 1
    }
  fi
  if path_exists "$CADDY_CONFIG"; then
    cmp -s <(render_caddyfile) "$CADDY_CONFIG" || {
      fail 'refusing to replace a foreign managed Caddyfile'
      return 1
    }
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

  version=$("$candidate/caddy" version) || {
    fail 'cannot read candidate Caddy version'
    return 1
  }
  [[ "$version" == "$SUPPORTED_CADDY_VERSION"* ]] ||
    fail "candidate Caddy is not $SUPPORTED_CADDY_VERSION"
  modules=$("$candidate/caddy" list-modules --packages) ||
    fail 'cannot read candidate Caddy modules'
  validate_godaddy_module_line "$modules"
  modules=$("$candidate/caddy" list-modules --versions --packages) ||
    fail 'cannot read candidate Caddy module versions'
  validate_godaddy_module_version_line "$modules"

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
  CADDY_PRIOR_ENABLED=$(query_unit_state is-enabled "${CADDY_PRIOR_PRESENT[3]}") || return 1
  CADDY_PRIOR_ACTIVE=$(query_unit_state is-active "${CADDY_PRIOR_PRESENT[3]}") || return 1
}

# systemd answers both is-enabled and is-active with a state word on stdout
# and a nonzero status for the negative states, so a bare exit-status test
# reads a D-Bus or manager error as "disabled"/"inactive" and silently loses
# the prior state restoration has to put back. Only a recognized state word
# is accepted; an absent unit file is the normal first-install case and is
# the one situation where an empty answer is not an error.
query_unit_state() {
  local verb=$1 unit_present=$2 answer
  answer=$(systemctl "$verb" "$CADDY_SERVICE" 2>/dev/null) || true
  case "$answer" in
    enabled | enabled-runtime | alias | static | indirect | generated | transient | active | activating | reloading | refreshing)
      printf '1\n'
      return 0
      ;;
    disabled | masked | masked-runtime | linked | linked-runtime | inactive | deactivating | failed | maintenance)
      printf '0\n'
      return 0
      ;;
  esac
  if [[ "$unit_present" -eq 0 && (-z "$answer" || "$answer" == not-found) ]]; then
    printf '0\n'
    return 0
  fi
  fail "cannot determine systemd $verb state for $CADDY_SERVICE"
  return 1
}

# Publishes one root-owned artifact atomically: install to a sibling
# temporary path with the final mode, then rename over the destination. A
# failed rename leaves no half-published sibling behind.
publish_caddy_artifact() {
  local source=$1 destination=$2 mode=$3 temporary=$2.pi-webui-new
  sudo install -o root -g root -m "$mode" "$source" "$temporary" || return 1
  sudo mv -f "$temporary" "$destination" || {
    sudo rm -f -- "$temporary" || true
    return 1
  }
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

# Selects the bounded wall-clock deadline for the whole readiness operation.
# Resolved in the parent, because the worker itself runs under it. Tests may
# shorten it through the usual Bats-only override guard.
caddy_ready_deadline() {
  CADDY_READY_DEADLINE=$CADDY_READY_DEADLINE_DEFAULT
  if [[ -n ${PI_WEBUI_TEST_READY_DEADLINE:-} ]]; then
    require_test_override "$STATE_ROOT"
    CADDY_READY_DEADLINE=$PI_WEBUI_TEST_READY_DEADLINE
  fi
}

# Cheap, side-effect-free readiness signal that only paces the bounded wait:
# the service is running and a normally CA-verified request already reaches
# the proxied health endpoint, which cannot happen before DNS-01 issuance
# completes. The probe carries its own explicit bound so one stalled attempt
# cannot outlast the whole documented budget. Every command is explicitly
# status-checked because this function is called from a condition, where Bash
# suppresses errexit. The authoritative validation runs afterwards, under
# normal error handling.
caddy_ready_signal() {
  systemctl is-active "$CADDY_SERVICE" >/dev/null 2>&1 || return 1
  curl --fail --silent --show-error \
    --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$CADDY_READY_PROBE_TIMEOUT" \
    --resolve "$CUSTOM_HOSTNAME:8443:127.0.0.1" \
    "https://$CUSTOM_HOSTNAME:8443/api/health" >/dev/null 2>&1 || return 1
}

# The readiness operation itself: pace until the cheap signal answers, then
# require the full installed, listener, LAN, and TLS/health state to be
# exact. Runs as the child of wait_for_caddy_ready()'s `timeout`, in a
# subprocess that re-sources this script, so it must depend only on exported
# state: the managed and Caddy paths, PI_LAUNCHER, STATE_ROOT, and the
# Bats-only overrides all are, and no credential is in the environment here.
caddy_readiness_worker() {
  local attempt
  caddy_ready_budget
  for ((attempt = 1; attempt <= CADDY_READY_ATTEMPTS; attempt++)); do
    if caddy_ready_signal; then break; fi
    [[ "$attempt" -lt "$CADDY_READY_ATTEMPTS" ]] || break
    sleep "$CADDY_READY_INTERVAL"
  done
  validate_installed_caddy
  validate_caddy_listener
  validate_caddy_tls_health
}

# Waits for readiness under one hard wall-clock deadline. A still-unready
# service fails with the exact remaining boundary error; an operation that
# outlasts the deadline fails with the deadline error. Both return nonzero to
# publish_caddy_candidate, so setup's cleanup and restoration are unchanged.
#
# `timeout` runs the worker in its own process group, so expiry ends every
# probe the worker started rather than leaving one behind past the bound.
wait_for_caddy_ready() {
  local status=0
  command -v timeout >/dev/null || {
    fail 'timeout is required to bound the Caddy readiness wait'
    return 1
  }
  caddy_ready_deadline
  timeout --kill-after="$CADDY_READY_KILL_GRACE" "$CADDY_READY_DEADLINE" \
    bash -c 'source "$1"; caddy_readiness_worker' bash "$SCRIPT_DIR/custom-domain.sh" || status=$?
  # 124 is coreutils' expiry status; 137 is the SIGKILL --kill-after sends
  # when the worker did not stop on the first signal.
  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    fail "Caddy readiness exceeded its $CADDY_READY_DEADLINE-second deadline"
    return 1
  fi
  return "$status"
}

# Publishes the validated candidate, reloads systemd, enables and restarts the
# dedicated service, and waits for readiness. The Tailscale route is never
# touched.
#
# Every cleanup flag is raised before the call it describes, not after: a
# command that mutates and then reports failure would otherwise leave a side
# effect that restoration never learns about.
publish_caddy_candidate() {
  local index destination
  for index in "${!CADDY_ARTIFACT_DESTS[@]}"; do
    destination=${CADDY_ARTIFACT_DESTS[index]}
    sudo install -d -o root -g root -m 0755 "$(dirname "$destination")" || return 1
    CADDY_PUBLISHED[index]=1
    publish_caddy_artifact "$CADDY_STAGING/${CADDY_ARTIFACT_NAMES[index]}" \
      "$destination" "${CADDY_ARTIFACT_MODES[index]}" || return 1
  done
  caddy_daemon_reloaded=1
  sudo systemctl daemon-reload || return 1
  caddy_enablement_changed=1
  sudo systemctl enable "$CADDY_SERVICE" || return 1
  # restart, not start: start is a no-op for an already-active unit, which
  # would leave a prior Caddy process serving the previous binary in memory
  # while every on-disk and endpoint check passes. restart also starts an
  # inactive or newly installed unit, so first install is unchanged.
  caddy_started=1
  sudo systemctl restart "$CADDY_SERVICE" || return 1
  wait_for_caddy_ready
}

# Stops the candidate, restores prior enablement while the unit still exists,
# restores every published artifact in reverse order, reloads systemd, and
# restores prior activity. Certificates, ACME state, and the encrypted
# credential are never removed. A failed restoration retains and reports the
# private staging path.
restore_prior_caddy() {
  local failed=0 index destination temporary
  set +e
  if [[ "$caddy_started" -eq 1 ]]; then
    sudo systemctl stop "$CADDY_SERVICE" || failed=1
    caddy_started=0
  fi
  # `systemctl disable` needs the unit file to resolve its [Install] section,
  # so an enablement introduced by this run has to be undone before the file
  # is removed; otherwise the symlink survives as dangling enablement.
  if [[ "$caddy_enablement_changed" -eq 1 && "$CADDY_PRIOR_ENABLED" -eq 0 ]]; then
    if sudo systemctl disable "$CADDY_SERVICE"; then
      caddy_enablement_changed=0
    else
      failed=1
    fi
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

# ---------------------------------------------------------------------------
# Migration transaction
# ---------------------------------------------------------------------------

# Bats-only marker that lets a signal test wait until the blocking
# confirmation is genuinely reached instead of racing a fixed sleep.
readonly MIGRATION_BLOCK_MARKER=.migration-confirm-block
# Bounded blocking wait (60s) in short steps so a queued INT or TERM trap runs
# promptly instead of waiting out one long sleep.
readonly MIGRATION_BLOCK_ATTEMPTS=600
# The systemd StateDirectory= the managed unit owns; rollback preserves it.
readonly CADDY_STATE_DIRECTORY=/var/lib/pi-webui-caddy

migration_restore_armed=0
MIGRATION_PID=
LEGACY_ROUTE_ACTION=none

# Emits the node's MagicDNS name without the trailing dot: the legacy
# `.ts.net` URL that migration retires and restoration proves again.
tailscale_dns_name() {
  local status
  status=$(tailscale status --json) || {
    fail 'cannot read Tailscale status'
    return 1
  }
  node - "$status" <<'NODE' || fail 'cannot read the node MagicDNS name'
const status = JSON.parse(process.argv[2]);
const dns = typeof status?.Self?.DNSName === 'string' ? status.Self.DNSName.replace(/\.$/, '') : '';
if (!dns) process.exit(1);
console.log(dns);
NODE
}

# Prints the exact literal plan an operator approves: the DNS record, the
# credential mechanism, the managed unit and config paths, both routes, every
# command this transaction may run, and the expected interruption. No
# credential material is read or printed.
show_migration_plan() {
  local ipv4
  ipv4=$(current_tailscale_ipv4) || return 1
  printf '%s\n' \
    "Migration plan for $CUSTOM_HOSTNAME" \
    "DNS: $CUSTOM_HOSTNAME A $ipv4" \
    "Credential: LoadCredentialEncrypted=$CREDENTIAL_NAME" \
    "Unit: $CADDY_UNIT" \
    "Config: $CADDY_CONFIG" \
    "Old: HTTPS 443 -> $LEGACY_BACKEND" \
    "New: TCP 443 -> $RAW_TARGET" \
    "Remove old: sudo tailscale serve --https=443 off" \
    "Publish new: sudo tailscale serve --bg --tcp=443 $RAW_TARGET" \
    "Rollback: remove TCP 443, then restore HTTPS 443 -> $LEGACY_BACKEND" \
    "Rollback commands: sudo tailscale serve --tcp=443 off; sudo tailscale serve --bg --https=443 $LEGACY_BACKEND" \
    "Interruption: normally several seconds; browser WebSockets disconnect"
}

# Blocks until a signal arrives, so a test can prove INT and TERM restoration
# at the exact point where a real operator would be reading their screen.
wait_for_confirmation_signal() {
  local attempt
  : >"$STATE_ROOT/$MIGRATION_BLOCK_MARKER" || return 1
  for ((attempt = 0; attempt < MIGRATION_BLOCK_ATTEMPTS; attempt++)); do
    sleep 0.1
  done
  return 1
}

# Reads one answer from the operator's terminal and accepts only an exact
# `yes`; EOF or anything else rejects. The answer is never taken from the
# ambient environment in production: an override is honored only under the
# usual Bats-only guard, so a stray variable on a real host fails closed.
confirm_migration_step() {
  local prompt=$1 variable=$2 answer=''
  if [[ -n ${!variable+set} ]]; then
    require_test_override "$STATE_ROOT" || return 1
    case "${!variable}" in
      eof) return 1 ;;
      block) wait_for_confirmation_signal || return 1 ;;
      *) answer=${!variable} ;;
    esac
  else
    printf '%s' "$prompt" >/dev/tty || return 1
    IFS= read -r answer </dev/tty || return 1
  fi
  [[ "$answer" == yes ]] || return 1
}

# Reports the live Serve JSON and human status so the exact published schema
# is confirmed from the running daemon rather than assumed from the release.
# Serve state contains routes only; no credential can appear here.
report_serve_schema() {
  local serve human
  serve=$(tailscale serve status --json) || {
    fail 'cannot read Tailscale Serve state'
    return 1
  }
  human=$(tailscale serve status) || {
    fail 'cannot read human Tailscale Serve status'
    return 1
  }
  printf 'Observed Serve JSON: %s\n' "$serve"
  printf 'Observed Serve status:\n%s\n' "$human"
}

# Prints the exact commands an operator needs when automatic restoration
# refuses to act, together with the state actually observed.
report_manual_recovery() {
  local human
  human=$(tailscale serve status 2>&1) || human='unavailable'
  printf 'observed Tailscale Serve status:\n%s\n' "$human" >&2
  printf 'manual recovery, after confirming the observed route is not wanted:\n' >&2
  printf '  sudo tailscale serve --tcp=443 off\n' >&2
  printf '  sudo tailscale serve --bg --https=443 %s\n' "$LEGACY_BACKEND" >&2
}

# Proves the retired MagicDNS URL actually answers. Rollback runs this before
# any Caddy teardown, whether the legacy route was just restored or was
# already published, so the old URL is never assumed to work.
require_legacy_url_health() {
  local legacy_host
  legacy_host=$(tailscale_dns_name) || return 1
  curl --fail --silent --show-error \
    --connect-timeout "$PROBE_CONNECT_TIMEOUT" --max-time "$PROBE_MAX_TIME" \
    "https://$legacy_host/api/health" >/dev/null || {
    printf 'error: the legacy route did not answer https://%s/api/health\n' "$legacy_host" >&2
    return 1
  }
}

# Restores the exact legacy HTTPS route. It acts only from `empty` or
# `raw-exact`, treats an already-published `legacy-exact` as nothing to do,
# and refuses to overwrite any other state. LEGACY_ROUTE_ACTION reports which
# of those happened so callers never claim a mutation that did not occur.
# Every step is status-checked explicitly because this runs from a trap and
# from condition contexts, where Bash suppresses errexit inside the called
# function.
restore_legacy_route() {
  local state
  LEGACY_ROUTE_ACTION=none
  state=$(route_state) || {
    printf 'error: cannot classify the Tailscale route; refusing automatic restoration\n' >&2
    report_manual_recovery
    return 1
  }
  case "$state" in
    raw-exact) serve_raw_off || return 1 ;;
    empty) ;;
    legacy-exact)
      LEGACY_ROUTE_ACTION=already-present
      printf 'the legacy route is already published; no restoration was needed\n' >&2
      return 0
      ;;
    *)
      printf 'error: unexpected Tailscale route state %s; refusing to overwrite it\n' "$state" >&2
      report_manual_recovery
      return 1
      ;;
  esac
  require_route_state empty || return 1
  serve_legacy || return 1
  require_route_state legacy-exact || return 1
  require_legacy_url_health || return 1
  LEGACY_ROUTE_ACTION=restored
}

# Runs from the ERR, INT, and TERM traps. It preserves the status that
# initiated recovery, restores the legacy route where that is safe, and
# reports a restoration failure separately from the original error so neither
# masks the other.
#
# ERR traps are inherited by command substitutions once errtrace is set, so
# recovery acts only in the shell that armed it; a subshell just propagates
# its own failure.
migration_recover() {
  local status=$1 reason=${2:-}
  [[ "$BASHPID" == "$MIGRATION_PID" ]] || return "$status"
  [[ "$migration_restore_armed" -eq 1 ]] || return "$status"
  migration_restore_armed=0
  trap - ERR INT TERM
  set +E
  [[ "$status" -ne 0 ]] || status=1
  [[ -z "$reason" ]] || printf 'error: migration aborted: %s\n' "$reason" >&2
  printf 'error: migration failed with status %s; restoring the legacy route\n' "$status" >&2
  if restore_legacy_route; then
    if [[ "${LEGACY_ROUTE_ACTION:-none}" == restored ]]; then
      printf 'legacy route restored: HTTPS 443 -> %s\n' "$LEGACY_BACKEND" >&2
    fi
  else
    printf 'error: RESTORATION FAILED; the tailnet route needs manual recovery\n' >&2
  fi
  exit "$status"
}

# Interactive, transactional migration from the legacy HTTPS Serve route to
# raw TCP forwarding in front of the managed Caddy service.
#
# Every external boundary is proven again before any trap is installed or any
# route command runs, so a preflight failure cannot mutate the route. The
# apply-source check setup performs is deliberately not repeated: migration
# publishes no source artifact, and a recovery-adjacent operation must not be
# blocked by an unrelated checkout state.
migrate_domain() {
  local legacy_host

  require_supported_platform
  strict_firstpick_preflight
  require_tailscale
  require_tailscale_version
  validate_public_dns
  validate_caddy_source
  set_caddy_paths
  require_route_state legacy-exact
  validate_installed_caddy
  validate_caddy_listener
  validate_caddy_tls_health
  legacy_host=$(tailscale_dns_name)

  show_migration_plan
  confirm_migration_step 'Type yes to migrate now: ' MIGRATION_CONFIRM ||
    fail 'migration was not approved; nothing was changed'

  # errtrace makes the ERR trap fire for failures inside called functions,
  # which is where every route command lives.
  MIGRATION_PID=$BASHPID
  migration_restore_armed=1
  set -E
  trap 'migration_recover $?' ERR
  trap 'migration_recover 130 "signal INT"' INT
  trap 'migration_recover 143 "signal TERM"' TERM

  serve_legacy_off
  require_route_state empty
  serve_raw
  require_route_state raw-exact
  report_serve_schema
  validate_caddy_tls_health_through_tailnet
  validate_caddy_tls_health
  # validate_caddy_listener re-runs check_lan for 31415 and check_caddy_lan
  # for 8443, so both LAN boundaries are rechecked here.
  validate_caddy_listener

  if ! confirm_migration_step \
    "Confirm https://$CUSTOM_HOSTNAME works from a separate trusted tailnet client (yes): " \
    TAILNET_CLIENT_CONFIRM; then
    migration_recover 1 'operator rejection'
  fi

  # The route can change concurrently while verification and confirmation run,
  # so success is reported only after one final exact reclassification
  # immediately before recovery is disarmed. A mismatch fails and is handed to
  # the same safe recovery rules as any other post-mutation failure.
  require_route_state raw-exact

  migration_restore_armed=0
  trap - ERR INT TERM
  set +E
  printf 'custom domain migrated: https://%s is now canonical\n' "$CUSTOM_HOSTNAME"
  printf 'the previous https://%s Web UI URL is no longer valid: raw TCP forwarding presents the %s certificate and site\n' \
    "$legacy_host" "$CUSTOM_HOSTNAME"
}

# ---------------------------------------------------------------------------
# Custom-domain rollback
# ---------------------------------------------------------------------------

# Requires every managed Caddy artifact to be an exact, root-owned, managed
# artifact before anything is removed. The three static files are compared
# byte-for-byte with their tracked renderers; the built binary is identified
# by its pinned version and its exact GoDaddy module provenance. Unlike
# validate_installed_caddy(), an inactive service is acceptable: rollback must
# still work when Caddy is already stopped.
require_removable_caddy_artifacts() {
  require_managed_caddy_artifact "$CADDY_BINARY" 'managed Caddy binary' || return 1
  [[ -x "$CADDY_BINARY" ]] || {
    fail 'managed Caddy binary is not executable'
    return 1
  }
  require_managed_caddy_artifact "$CADDY_ENTRYPOINT" 'managed Caddy entrypoint' || return 1
  require_managed_caddy_artifact "$CADDY_CONFIG" 'managed Caddyfile' || return 1
  require_managed_caddy_artifact "$CADDY_UNIT" 'managed Caddy unit' || return 1

  cmp -s "$SCRIPT_DIR/caddy-entrypoint.sh" "$CADDY_ENTRYPOINT" || {
    fail 'refusing to remove a foreign managed Caddy entrypoint'
    return 1
  }
  cmp -s <(render_caddyfile) "$CADDY_CONFIG" || {
    fail 'refusing to remove a foreign managed Caddyfile'
    return 1
  }
  cmp -s <(render_caddy_unit "$CADDY_ENTRYPOINT") "$CADDY_UNIT" || {
    fail 'refusing to remove a foreign managed Caddy unit'
    return 1
  }

  validate_caddy_binary_identity ||
    fail "refusing to remove a foreign Caddy binary: not $SUPPORTED_CADDY_VERSION with $EXPECTED_GODADDY_PACKAGE@v$GODADDY_MODULE_VERSION"
}

# Removes only the exact managed Caddy service artifacts. The caller is
# responsible for having brought the Tailscale route to the state it wants
# and for reclassifying it immediately before this runs.
remove_managed_caddy() {
  sudo systemctl stop "$CADDY_SERVICE"
  sudo systemctl disable "$CADDY_SERVICE"
  sudo rm -f -- "$CADDY_UNIT" "$CADDY_CONFIG" "$CADDY_ENTRYPOINT" "$CADDY_BINARY"
  sudo systemctl daemon-reload
}

# Conservative custom-domain rollback: restore legacy ingress, prove the old
# URL answers, then remove only the exact managed Caddy service artifacts.
#
# `--full` is the removal path the Web UI rollback needs instead: it takes the
# exact raw or exact transitional legacy route down to empty, removes the same
# managed artifacts, and leaves Serve empty so ai/pi/webui/rollback.sh can run.
#
# Certificates, ACME state, the encrypted credential, Pi state, the managed
# Web UI runtime and worktree, and the Tailscale node identity are all
# preserved in both modes; deleting any of them would require its own explicit
# flag and is deliberately not offered here. The strict Firstp1ck preflight is
# not repeated: restoration itself proves the legacy URL answers, which is the
# behavior that matters, and rollback must stay available when other managed
# state has drifted.
rollback_domain() {
  local mode=${1:-default} route
  require_supported_platform
  resolve_source
  set_managed_paths
  require_tailscale_daemon
  require_tailscale
  validate_caddy_source
  set_caddy_paths
  require_removable_caddy_artifacts

  route=$(route_state) || return 1
  if [[ "$mode" == full ]]; then
    case "$route" in
      raw-exact) serve_raw_off || fail 'custom-domain rollback could not remove the raw route; the Caddy service was left untouched' ;;
      legacy-exact) serve_legacy_off || fail 'custom-domain rollback could not remove the legacy route; the Caddy service was left untouched' ;;
      empty) ;;
      *) fail "unexpected Tailscale route state for custom-domain rollback: $route" ;;
    esac
    # Reclassify immediately before teardown. A concurrent republication
    # between removal and teardown would otherwise leave live ingress in front
    # of artifacts that are about to be deleted.
    require_route_state empty
    remove_managed_caddy
    printf 'custom domain removed: Tailscale Serve is empty and %s is removed\n' "$CADDY_SERVICE"
    printf 'run %s/rollback.sh next to remove the Pi Web UI service\n' "$SCRIPT_DIR"
  else
    case "$route" in
      raw-exact)
        restore_legacy_route ||
          fail 'custom-domain rollback could not restore the legacy route; the Caddy service was left untouched'
        ;;
      legacy-exact)
        printf 'the legacy route is already published; no restoration was needed\n'
        require_legacy_url_health ||
          fail 'the already-published legacy route did not answer; the Caddy service was left untouched'
        ;;
      *) fail "unexpected Tailscale route state for custom-domain rollback: $route" ;;
    esac
    require_route_state legacy-exact
    remove_managed_caddy
    printf 'custom domain rolled back: legacy HTTPS 443 -> %s is published and %s is removed\n' \
      "$LEGACY_BACKEND" "$CADDY_SERVICE"
  fi
  printf 'preserved: %s, %s, Pi state, Web UI state, and the Tailscale node identity\n' \
    "$CADDY_CREDENTIAL" "$CADDY_STATE_DIRECTORY"
}

usage() {
  printf 'usage: %s check|setup|migrate|rollback [--full]\n' "$0"
}

main() {
  case "${1:-}" in
    check | setup | migrate)
      [[ $# -eq 1 ]] || {
        usage >&2
        return 2
      }
      ;;
    rollback)
      [[ $# -eq 1 || ($# -eq 2 && "$2" == --full) ]] || {
        usage >&2
        return 2
      }
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
  case "$1" in
    check) check_domain ;;
    setup) setup_domain ;;
    migrate) migrate_domain ;;
    rollback)
      if [[ ${2:-} == --full ]]; then
        rollback_domain full
      else
        rollback_domain default
      fi
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
