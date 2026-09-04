# Pi Web UI Custom Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, recoverable path from `https://pi.dpao.la` through public GoDaddy DNS, Tailscale raw TCP, loopback-only Caddy TLS, and the existing loopback-only Firstp1ck service.

**Architecture:** Extend the existing Tailscale helper with version-gated, fail-closed classification for legacy HTTPS and raw TCP routes. Add a dedicated custom-domain helper that validates DNS and Firstp1ck, builds and publishes a pinned Caddy-with-GoDaddy-module system service, verifies DNS-01 TLS readiness, and migrates the exact legacy route transactionally with restoration on failure. Keep all custom-domain actions outside ordinary `make ai` and preserve credentials, certificates, Pi state, and Tailscale identity by default.

**Tech Stack:** Bash 5, Bats, Node.js for JSON validation, Tailscale CLI `1.102.3`, Caddy `v2.11.4`, xcaddy `v0.4.7`, `caddy-dns/godaddy` `v1.2.0`, systemd 255, curl, OpenSSL, dig.

**Spec:** `docs/superpowers/specs/2026-09-04-pi-webui-custom-domain-design.md`

## Global Constraints

- Work only in `/home/tng/.dotfiles/tmp/worktrees/pi-webui-custom-domain` on `feat/pi-webui-custom-domain` until integration.
- Keep Firstp1ck on exactly `127.0.0.1:31415` and Caddy on exactly TCP `127.0.0.1:8443`.
- Never enable Funnel, HTTP-01 ingress, a wildcard listener, IPv6 listener, LAN listener, Tailscale-interface listener, port 80, or HTTP/3 UDP.
- The only accepted new Serve route is raw `TCP 443 -> 127.0.0.1:8443`; reject TLS-terminated, foreign, additional, and unknown nonempty routes.
- Require Tailscale client release `1.102.3` and daemon `Version` from release `1.102.3` before custom-domain route classification or mutation.
- Keep `@gotgenes/pi-permission-system`, Firstp1ck `0.10.3`, the Pi Web UI runtime lock, and Pi pins unchanged.
- Do not upgrade, downgrade, or repin Pi. Setup and migration must fail while the mise Pi is `0.85.0` rather than the repository contract `0.84.4`.
- Never commit or log DNS API credentials, certificate private keys, PEM files, or ACME state.
- Store the GoDaddy classic Production credential through `LoadCredentialEncrypted=godaddy-api-token`; omit Caddy `--environ`.
- Do not automate GoDaddy A-record mutation. Require exactly `pi.dpao.la A $TAILSCALE_IPV4`, where the value comes from current node status, with no CNAME or AAAA.
- Preserve certificates, encrypted credentials, settings, sessions, transcripts, worktrees, backups, evidence, and Tailscale identity on default rollback.
- Every live DNS, credential, build/package, certificate, service, Pi, or Serve mutation remains separately approval-gated; source tests must not perform one.
- Follow TDD: add a focused failing Bats assertion, run it red, implement the minimum behavior, and run it green before each commit.
- Do not add adversarial same-user inode, syscall, signal-boundary, or exhaustive transaction hardening.

## File map

- Modify `ai/pi/webui/tailscale.sh`: version gate, route classifier, raw route publication/removal, legacy restoration helpers, and caller-specific accepted states.
- Create `ai/pi/webui/Caddyfile.in`: fixed Caddy global options, hostname, loopback bind, DNS provider, and backend.
- Create `ai/pi/webui/pi-webui-caddy.service.in`: dedicated hardened system unit with encrypted systemd credential and persistent state.
- Create `ai/pi/webui/caddy-entrypoint.sh`: read the systemd credential and exec the private Caddy binary without secret-bearing argv or startup environment logging.
- Create `ai/pi/webui/custom-domain.sh`: strict Firstp1ck, DNS, Caddy, certificate, setup, migration, restoration, and custom-domain rollback orchestration.
- Modify `ai/pi/webui/rollback.sh`: retain its empty-route requirement while recognizing that the custom-domain helper owns raw-route removal and Caddy cleanup.
- Modify `ai/pi/webui/README.md`: exact DNS, credential, setup, migration, validation, recovery, deprecation, and old-URL behavior.
- Modify `Makefile`: add only `ai-webui-domain-check` and `ai-webui-domain-setup` entry points.
- Modify `tests/pi_webui.bats`: all new fixture, route, template, setup, migration, and preservation coverage.
- Keep `bin/validate-pi-webui`, `ai/pi/webui/pi-webui.service.in`, runtime manifests/lock, and Pi settings unchanged unless a failing test proves a narrowly required shared validation extraction.

---

### Task 1: Version-gated Tailscale route model

**Files:**
- Modify: `ai/pi/webui/tailscale.sh:11-188`
- Modify: `tests/pi_webui.bats:399-468,811-871`

**Interfaces:**
- Consumes: existing `fail`, `require_supported_platform`, `require_tailscale_daemon`, and `require_tailscale` helpers.
- Produces: `require_tailscale_version() -> success|failure`; `route_state() -> empty|legacy-exact|raw-exact`; `require_route_state STATE...`; `serve_raw()`, `serve_raw_off()`, `serve_legacy()`, and `serve_legacy_off()`.

- [ ] **Step 1: Extend route fixtures and write failing classifier/version tests**

Add `Version` to `tailscale-status.json`, stub `tailscale version --json`, retain the current `legacy-exact` fixture, and add this raw fixture:

```bash
raw)
  printf '%s\n' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"}}}' \
    >"$TEST_ROOT/route.json"
  printf '%s\n' \
    'tcp://wsl.test.ts.net:443 (tailnet only)' \
    '|-- tcp://100.64.0.1:443' \
    '|--> tcp://127.0.0.1:8443' \
    >"$TEST_ROOT/route.txt"
  ;;
```

Add focused tests equivalent to:

```bash
@test "route classifier distinguishes empty legacy and exact raw TCP" {
  prepare_tailscale_check empty
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = empty ]

  write_route legacy-exact
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = legacy-exact ]

  write_route raw
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = raw-exact ]
}

@test "route operations reject mismatched Tailscale client or daemon versions" {
  prepare_tailscale_check raw
  export TAILSCALE_CLIENT_VERSION=1.103.0
  run_tailscale check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]

  export TAILSCALE_CLIENT_VERSION=1.102.3
  export TAILSCALE_DAEMON_VERSION=1.103.0-tforeign
  run_tailscale check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
}
```

Include rejected fixtures for `HTTPS`, `HTTP`, `TerminateTLS`, foreign `TCPForward`, another TCP port, a nonempty `Web` map, Funnel, and an unknown nonempty field.

- [ ] **Step 2: Run the new tests and verify red**

Run:

```bash
bats tests/pi_webui.bats --filter 'route classifier|mismatched Tailscale|raw TCP'
```

Expected: failures because `raw`, `require_tailscale_version`, and caller-specific classification do not exist.

- [ ] **Step 3: Implement the exact version and route classifier**

Add constants and a semantic parser in `tailscale.sh`:

```bash
readonly LEGACY_BACKEND=http://127.0.0.1:31415
readonly RAW_BACKEND=127.0.0.1:8443
readonly RAW_TARGET=tcp://127.0.0.1:8443
readonly SUPPORTED_TAILSCALE_VERSION=1.102.3

require_tailscale_version() {
  local client status
  client=$(tailscale version --json) || fail 'cannot read Tailscale client version'
  status=$(tailscale status --json) || fail 'cannot read Tailscale daemon version'
  node - "$client" "$status" "$SUPPORTED_TAILSCALE_VERSION" <<'NODE' ||
    fail 'unsupported Tailscale client or daemon version'
const [clientText, statusText, supported] = process.argv.slice(2);
const client = JSON.parse(clientText);
const status = JSON.parse(statusText);
if (client.short !== supported || typeof status.Version !== 'string' ||
    !(status.Version === supported || status.Version.startsWith(`${supported}-`))) process.exit(1);
NODE
}
```

Refactor `route_state` so it preserves the current fail-closed canonical/empty helpers, emits `legacy-exact` for the existing HTTPS shape, and emits `raw-exact` only when:

```javascript
Object.keys(serve.TCP || {}).length === 1
&& serve.TCP['443']?.TCPForward === '127.0.0.1:8443'
&& Object.entries(serve.TCP['443']).every(([key, value]) =>
  key === 'TCPForward' || empty(value))
&& empty(serve.Web)
&& empty(serve.AllowFunnel)
```

Require human status to identify `tailnet only`, the node DNS name and Tailscale IP lines, and the exact destination. Continue comparing Serve and Funnel JSON because the installed CLI exposes the same underlying config through both commands.

- [ ] **Step 4: Implement caller-specific operations**

Add:

```bash
require_route_state() {
  local actual allowed
  actual=$(route_state)
  for allowed in "$@"; do [[ "$actual" == "$allowed" ]] && return 0; done
  fail "unexpected Tailscale route state: $actual"
}

serve_raw() {
  require_tailscale_version
  require_route_state empty raw-exact
  sudo tailscale serve --bg --tcp=443 "$RAW_TARGET"
  [[ $(route_state) == raw-exact ]] || fail 'raw TCP Serve publication did not produce the exact route'
}

serve_raw_off() {
  require_tailscale_version
  [[ $(route_state) == empty ]] && return 0
  require_route_state raw-exact
  sudo tailscale serve --tcp=443 off
  [[ $(route_state) == empty ]] || fail 'raw TCP Serve route remains after removal'
}
```

Keep `serve_legacy` and `serve_legacy_off` private to migration/restoration. Change the public `serve`/`serve-off` behavior to the raw route, and make `check_all` accept only `empty raw-exact`. Do not add `reset` or Funnel commands.

- [ ] **Step 5: Run focused and existing Tailscale tests**

Run:

```bash
bats tests/pi_webui.bats --filter 'Tailscale|tailscale|route|LAN'
```

Expected: all selected tests pass; assertions now expect the raw command where public `serve` behavior changed.

- [ ] **Step 6: Commit the route model**

```bash
git add ai/pi/webui/tailscale.sh tests/pi_webui.bats
git commit -m "feat: model raw Tailscale Web UI ingress"
```

---

### Task 2: Caddy configuration and service artifacts

**Files:**
- Create: `ai/pi/webui/Caddyfile.in`
- Create: `ai/pi/webui/pi-webui-caddy.service.in`
- Create: `ai/pi/webui/caddy-entrypoint.sh`
- Create: `ai/pi/webui/custom-domain.sh`
- Modify: `tests/pi_webui.bats`

**Interfaces:**
- Consumes: shared validation helpers from `install.sh` and route helpers from `tailscale.sh`.
- Produces: `render_caddyfile()`, `render_caddy_unit()`, `validate_caddy_source()`, and fixed managed path constants used by later tasks.

- [ ] **Step 1: Add failing template and secret-isolation tests**

Extend the fixture copier to include the three new templates/scripts and write assertions equivalent to:

```bash
@test "Caddy source fixes hostname listener backend and DNS provider" {
  make_webui_fixture
  run_custom_domain_function 'render_caddyfile'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'admin off'* ]]
  [[ "$output" == *$'auto_https disable_redirects'* ]]
  [[ "$output" == *$'https_port 8443'* ]]
  [[ "$output" == *$'protocols h1 h2'* ]]
  [[ "$output" == *$'pi.dpao.la {'* ]]
  [[ "$output" == *$'bind 127.0.0.1'* ]]
  [[ "$output" == *$'api_token {env.GODADDY_API_TOKEN}'* ]]
  [[ "$output" == *$'reverse_proxy 127.0.0.1:31415'* ]]
  [[ "$output" != *'0.0.0.0'* ]]
  [[ "$output" != *'::'* ]]
}

@test "Caddy unit uses encrypted credential and no remote admin or secret argv" {
  make_webui_fixture
  run_custom_domain_function 'render_caddy_unit'
  [ "$status" -eq 0 ]
  [[ "$output" == *'LoadCredentialEncrypted=godaddy-api-token'* ]]
  [[ "$output" == *'DynamicUser=yes'* ]]
  [[ "$output" == *'StateDirectory=pi-webui-caddy'* ]]
  [[ "$output" == *'Restart=on-failure'* ]]
  [[ "$output" != *'GODADDY_API_TOKEN='* ]]
  [[ "$output" != *'--environ'* ]]
}

@test "tracked custom-domain files contain no credential or private key" {
  run grep -REn --include='*' \
    '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|[A-Za-z0-9]{20,}:[A-Za-z0-9]{20,})' \
    "$REPO_ROOT/ai/pi/webui"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run the template tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'Caddy source|Caddy unit|credential or private key'
```

Expected: failure because the artifacts and render functions are absent.

- [ ] **Step 3: Add the exact Caddyfile and credential entrypoint**

Create `Caddyfile.in` with the approved Caddyfile from the spec. Create an entrypoint with no diagnostic echo of the credential:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly credential=${CREDENTIALS_DIRECTORY:?}/godaddy-api-token
[[ -f "$credential" ]] || { printf 'error: GoDaddy credential is unavailable\n' >&2; exit 1; }
GODADDY_API_TOKEN=$(<"$credential")
[[ "$GODADDY_API_TOKEN" == *:* && "$GODADDY_API_TOKEN" != *$'\n'* ]] || {
  printf 'error: GoDaddy credential format is invalid\n' >&2
  exit 1
}
export GODADDY_API_TOKEN
exec /usr/local/lib/pi-webui/caddy run \
  --config /etc/pi-webui-caddy/Caddyfile \
  --adapter caddyfile
```

Do not accept the token as an argument and do not add `--environ`.

- [ ] **Step 4: Add the hardened system unit and render validation**

Create the unit exactly as approved in the spec, with its command written as `ExecStart=@CADDY_ENTRYPOINT@` so the same template can be verified against a real staged executable before publication. Add the initial `custom-domain.sh` shell with strict mode, sourced shared helpers, constants, path setup, render functions, and source checks:

```bash
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

render_caddyfile() { cat "$SCRIPT_DIR/Caddyfile.in"; }
render_caddy_unit() {
  local entrypoint=${1:-$CADDY_ENTRYPOINT} rendered
  safe_unit_path "$entrypoint" || return 1
  rendered=$(<"$SCRIPT_DIR/pi-webui-caddy.service.in")
  rendered=${rendered//@CADDY_ENTRYPOINT@/$entrypoint}
  [[ "$rendered" != *'@CADDY_ENTRYPOINT@'* ]] || fail 'Caddy unit substitution failed'
  printf '%s\n' "$rendered"
}
```

`validate_caddy_source` must compare exact tracked templates, reject unresolved placeholders, require executable entrypoint mode, and scan only managed source files for private-key or credential-like material without treating symbolic variable names as secrets.

- [ ] **Step 5: Run source tests and shell validation**

```bash
bats tests/pi_webui.bats --filter 'Caddy source|Caddy unit|credential or private key'
bash -n ai/pi/webui/custom-domain.sh ai/pi/webui/caddy-entrypoint.sh
shellcheck -x -S warning ai/pi/webui/custom-domain.sh ai/pi/webui/caddy-entrypoint.sh
shfmt -d -i 2 -ci ai/pi/webui/custom-domain.sh ai/pi/webui/caddy-entrypoint.sh
```

Expected: all commands pass.

- [ ] **Step 6: Commit the static Caddy boundary**

```bash
git add ai/pi/webui/Caddyfile.in ai/pi/webui/pi-webui-caddy.service.in \
  ai/pi/webui/caddy-entrypoint.sh ai/pi/webui/custom-domain.sh tests/pi_webui.bats
git commit -m "feat: define loopback Caddy Web UI service"
```

---

### Task 3: Strict read-only DNS, Firstp1ck, Caddy, and TLS checks

**Files:**
- Modify: `ai/pi/webui/custom-domain.sh`
- Modify: `tests/pi_webui.bats`

**Interfaces:**
- Consumes: `resolve_source`, `resolve_mise`, `resolve_pi`, `set_managed_paths`, `validate_landing_worktree`, `validate_unit`, `validate_active_health`, `require_tailscale`, `require_tailscale_version`, and `route_state`.
- Produces: `strict_firstpick_preflight()`, `current_tailscale_ipv4() -> IPv4`, `validate_public_dns()`, `validate_installed_caddy()`, `validate_caddy_listener()`, `validate_caddy_tls_health()`, and `check_domain()`.

- [ ] **Step 1: Write failing strict Firstp1ck and DNS tests**

Use existing fixture helpers and stubs to prove each absent component fails before any command recorded in `MUTATION_CALLS` or `CREDENTIAL_CALLS`. Add DNS fixtures through a stubbed `dig` command. Representative assertions:

```bash
@test "custom-domain preflight requires active exact Firstp1ck before credential access" {
  prepare_custom_domain_check legacy-exact
  rm -rf "$INSTALLED_RUNTIME"
  run_custom_domain check
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed runtime is unavailable'* ]]
  [ ! -s "$CREDENTIAL_CALLS" ]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "DNS must be one A equal to current Tailscale IPv4 with no aliases" {
  prepare_custom_domain_check legacy-exact
  write_dns A 100.64.0.1
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -eq 0 ]

  write_dns A 100.64.0.2
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale Tailscale IPv4'* ]]

  write_dns CNAME personal-desktop.tail74aee.ts.net.
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
}
```

Cover missing A, multiple A, AAAA, CNAME, multiple Tailscale IPv4 values, offline node, and a non-`100.64.0.0/10` address.

- [ ] **Step 2: Run strict/DNS tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'custom-domain preflight|DNS must|stale Tailscale'
```

Expected: failures because strict and DNS helpers are absent.

- [ ] **Step 3: Implement strict Firstp1ck and DNS boundaries**

Implement strict preflight without calling permissive `check_local_service`:

```bash
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
```

Parse Tailscale status in Node, require one IPv4 in `100.64.0.0/10`, and emit it. Query `dig +short NS dpao.la`, require at least one authoritative server, then query `A`, `AAAA`, and `CNAME` both through the client's normal resolver and directly against every authoritative server. Normalize trailing dots and require every view to return one exact A equal to the current Tailscale address and empty AAAA/CNAME answers.

- [ ] **Step 4: Write failing installed-Caddy/listener/TLS tests**

Stub `systemctl`, `ss`, `curl`, `openssl`, and the private Caddy binary. Cover wrong version, absent module, foreign binary/config/unit, inactive service, wildcard/IPv6/LAN/UDP/port-80 listener, certificate hostname failure, certificate expiry, and backend health failure. Include a healthy fixture with:

```bash
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners"
export CADDY_MODULES='dns.providers.godaddy'
export CADDY_VERSION_OUTPUT='v2.11.4 h1:test'
export CADDY_HEALTH_JSON="$HEALTH_JSON"
```

- [ ] **Step 5: Run installed-Caddy tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'installed Caddy|Caddy listener|Caddy TLS|certificate'
```

Expected: failures because installed-state validators are absent.

- [ ] **Step 6: Implement installed Caddy, listener, and local TLS validation**

Require root-owned regular managed artifacts at exact paths, compare rendered files byte-for-byte, require `caddy version` to identify `v2.11.4`, and require `caddy list-modules --packages` to contain exactly the expected GoDaddy package for `dns.providers.godaddy`.

For network state, parse `ss -ltnH`, `ss -lunH`, and global non-Tailscale IPv4 addresses. Require one TCP 8443 listener whose local address is exactly `127.0.0.1:8443`; reject port 80 and UDP 8443 listeners. Probe each non-Tailscale global address on 8443 and retain the existing 31415 LAN check.

Validate TLS and proxy health without bypassing CA verification:

```bash
curl --fail --silent --show-error \
  --resolve "$CUSTOM_HOSTNAME:8443:127.0.0.1" \
  "https://$CUSTOM_HOSTNAME:8443/api/health"
```

Parse the returned health JSON using the existing exact Firstp1ck version/network contract. Use `openssl s_client -connect 127.0.0.1:8443 -servername "$CUSTOM_HOSTNAME" -verify_return_error` plus `openssl x509 -checkhost "$CUSTOM_HOSTNAME" -checkend 604800 -noout` so expiry and hostname failures are explicit.

- [ ] **Step 7: Define caller-specific check behavior**

`check_domain` runs strict Firstp1ck, Tailscale version/online checks, DNS, source validation, installed Caddy validation, listener/TLS health, and route classification. It accepts `legacy-exact` only as a clearly reported `ready-to-migrate` transition when Caddy is fully healthy; steady success is `raw-exact`. It may report `empty` only as a non-published pre-install state and must never treat foreign state as informational.

Add CLI parsing with exactly:

```text
usage: custom-domain.sh check|setup|migrate|rollback
```

At this task only `check` is implemented; other accepted verbs fail with a clear `not implemented` status until their TDD tasks land, preventing accidental partial mutation.

- [ ] **Step 8: Run all read-only check tests**

```bash
bats tests/pi_webui.bats --filter 'custom-domain|DNS|Caddy|certificate|LAN'
```

Expected: all selected tests pass and mutation logs remain empty for `check`.

- [ ] **Step 9: Commit the read-only boundary**

```bash
git add ai/pi/webui/custom-domain.sh tests/pi_webui.bats
git commit -m "feat: validate Pi Web UI custom domain"
```

---

### Task 4: Candidate-first Caddy setup and credential validation

**Files:**
- Modify: `ai/pi/webui/custom-domain.sh`
- Modify: `tests/pi_webui.bats`

**Interfaces:**
- Consumes: Task 2 render functions and Task 3 strict/DNS checks.
- Produces: `validate_godaddy_credential()`, `build_caddy_candidate()`, `publish_caddy_candidate()`, `restore_prior_caddy()`, and `setup_domain()`.

- [ ] **Step 1: Write failing setup ordering and no-side-effect tests**

Create command stubs for `go`, `caddy`, `systemd-analyze`, `systemctl`, `systemd-creds`, `sudo`, `install`, and network probes. Record calls in separate build, credential, and mutation logs. Assert:

```bash
@test "setup validates Firstp1ck route DNS and credential before publication" {
  prepare_custom_domain_setup legacy-exact
  run_custom_domain setup
  [ "$status" -eq 0 ]
  first_build=$(grep -n '^go ' "$CALLS" | cut -d: -f1)
  first_publish=$(grep -n '^sudo install ' "$CALLS" | cut -d: -f1 | head -1)
  credential=$(grep -n '^credential-check$' "$CALLS" | cut -d: -f1)
  [ "$credential" -lt "$first_build" ]
  [ "$first_build" -lt "$first_publish" ]
  ! grep -F 'tailscale serve' "$CALLS"
}
```

For each failure—Pi drift, absent runtime, inactive service, wrong Tailscale version, non-legacy route, stale DNS, missing encrypted credential, API 401/403, build failure, missing module, Caddy validate failure, and systemd unit verify failure—assert no managed path or service changed. Include representative post-publication start and TLS-health failures that must restore prior files, enablement, and activity while preserving state and credential paths.

- [ ] **Step 2: Run setup tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'setup validates|setup refuses|setup restores'
```

Expected: failures because setup functions are absent.

- [ ] **Step 3: Implement canonical apply and credential preflight**

Reuse `validate_apply_source` so setup applies only from the canonical clean checkout at `origin/main`. Require `/etc/credstore.encrypted/godaddy-api-token` to be a root-owned regular file with no group/other permission bits.

Validate the credential without placing it in argv or output. Decrypt to a pipe and let a Node program read stdin, split the first colon only, send a GET for `/v1/domains/dpao.la/records`, and print only `GoDaddy DNS API credential is valid` on HTTP 200. For every other status, discard the body and return a generic status-only error. The shell shape is:

```bash
sudo systemd-creds decrypt \
  --name=godaddy-api-token \
  "$CADDY_CREDENTIAL" - |
  node -e '
const https = require("node:https");
let token = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { token += chunk; });
process.stdin.on("end", () => {
  token = token.replace(/\\r?\\n$/, "");
  if (!/^[^:\\r\\n]+:[^:\\r\\n]+$/.test(token)) process.exit(2);
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
});'
```

Use `set -o pipefail`; never enable shell tracing and never echo the decrypted input.

- [ ] **Step 4: Build and validate the pinned candidate**

Create a private staging directory, run the exact pinned xcaddy build from the spec, and validate before sudo publication:

```bash
mise exec -- go run github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 \
  build v2.11.4 \
  --with github.com/caddy-dns/godaddy@v1.2.0 \
  --output "$candidate/caddy"
```

Copy the entrypoint into the staging directory, render the unit with that real staged absolute path, then require:

```bash
cp "$SCRIPT_DIR/caddy-entrypoint.sh" "$candidate/caddy-entrypoint"
chmod 0755 "$candidate/caddy-entrypoint"
render_caddy_unit "$candidate/caddy-entrypoint" >"$candidate/pi-webui-caddy.service"
"$candidate/caddy" version
"$candidate/caddy" list-modules --packages
GODADDY_API_TOKEN=placeholder:placeholder \
  "$candidate/caddy" adapt --config "$candidate/Caddyfile" --adapter caddyfile --validate
systemd-analyze verify "$candidate/pi-webui-caddy.service"
```

Do not print adapted JSON with a real credential. Validate the candidate entrypoint with `bash -n` and ShellCheck before publication. Render the final installed unit separately with the fixed live entrypoint path and compare it byte-for-byte during installed-state checks.

- [ ] **Step 5: Implement bounded publication and restoration**

Capture prior presence, exact files, enablement, and activity in the private staging directory. Refuse unowned or nonmatching existing managed paths. Publish root-owned artifacts atomically to:

```text
/usr/local/lib/pi-webui/caddy
/usr/local/lib/pi-webui/caddy-entrypoint
/etc/pi-webui-caddy/Caddyfile
/etc/systemd/system/pi-webui-caddy.service
```

Use modes `0755`, `0755`, `0644`, and `0644`; do not copy the encrypted credential. Reload systemd, enable and start `pi-webui-caddy.service`, wait with a bounded retry loop for `127.0.0.1:8443`, DNS-01 issuance, trusted certificate, and proxy health. Keep the legacy route untouched.

On post-publication failure, stop the candidate, restore prior files in reverse order, daemon-reload, restore prior enablement/activity, and retain `/var/lib/pi-webui-caddy` plus `/etc/credstore.encrypted/godaddy-api-token`. If restoration fails, retain the private staging path and report it.

- [ ] **Step 6: Run setup and preservation tests**

```bash
bats tests/pi_webui.bats --filter 'setup|credential|candidate|Caddy state'
```

Expected: all selected tests pass; no test invokes real sudo, systemd, Go download, DNS mutation, ACME, or Tailscale mutation.

- [ ] **Step 7: Commit Caddy setup**

```bash
git add ai/pi/webui/custom-domain.sh tests/pi_webui.bats
git commit -m "feat: reconcile custom-domain Caddy service"
```

---

### Task 5: Transactional route migration, restoration, and domain rollback

**Files:**
- Modify: `ai/pi/webui/custom-domain.sh`
- Modify: `ai/pi/webui/rollback.sh`
- Modify: `tests/pi_webui.bats`

**Interfaces:**
- Consumes: exact route functions from Task 1, strict checks from Task 3, and installed Caddy checks from Task 4.
- Produces: `show_migration_plan()`, `restore_legacy_route()`, `migrate_domain()`, and `rollback_domain()`.

- [ ] **Step 1: Write failing migration order and restoration tests**

Add a stateful Tailscale stub that transitions only for exact commands. Add a confirmation stub that can answer yes, no, EOF, or block until a signal. Test the successful sequence:

```bash
@test "migration removes exact legacy route publishes raw and verifies before confirmation" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes
  run_custom_domain migrate
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --https=443 off' "$CALLS"
  grep -Fx 'sudo tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443' "$CALLS"
  [ "$(route_call_order)" = $'legacy-off\nraw-on' ]
  [ "$(current_route_fixture)" = raw-exact ]
}
```

For failures after legacy removal, after raw publication, status mismatch, local TLS failure, proxy-health failure, operator rejection, EOF, INT, and TERM, assert exact raw removal followed by exact legacy publication and final `legacy-exact`. Assert no mutation on any preflight failure. Assert a foreign post-mutation state is reported and never overwritten.

- [ ] **Step 2: Run migration tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'migration|restores legacy|foreign post-mutation'
```

Expected: failures because migration/restoration functions are absent.

- [ ] **Step 3: Implement plan display and immediate approval gate**

Before prompting, print literal values without secrets:

```text
DNS: pi.dpao.la A $TAILSCALE_IPV4
Credential: LoadCredentialEncrypted=godaddy-api-token
Old: HTTPS 443 -> http://127.0.0.1:31415
New: TCP 443 -> tcp://127.0.0.1:8443
Rollback: remove TCP 443, then restore HTTPS 443 -> http://127.0.0.1:31415
Interruption: normally several seconds; browser WebSockets disconnect
```

Use a `/dev/tty` confirmation that accepts only exact `yes`; EOF or anything else rejects. The test override is available only under `PI_WEBUI_TESTING=1` and a valid Bats root.

- [ ] **Step 4: Implement the migration state machine**

Run all strict checks before installing traps or mutating. Require exactly `legacy-exact`. After approval:

```bash
serve_legacy_off
require_route_state empty
serve_raw
require_route_state raw-exact
validate_caddy_tls_health_through_tailnet
validate_caddy_listener
check_lan
```

Capture and preserve the actual Serve JSON in command output for schema confirmation, but never any credential. Prompt for separate trusted-tailnet-client success only after automated verification. On success, disarm restoration and document that the `.ts.net` URL is no longer valid.

Use traps for `ERR`, `INT`, and `TERM`. Preserve the initiating exit status. Restoration may act only from `empty` or `raw-exact`; it removes exact raw if present, requires empty, calls `serve_legacy`, verifies `legacy-exact`, and probes the old health URL. If the state is foreign/additional, report it and refuse mutation. Always report restoration failure separately from the original error.

- [ ] **Step 5: Write failing custom-domain rollback preservation tests**

Cover migration rollback and full-removal preparation. Fingerprint:

```text
/var/lib/pi-webui-caddy
/etc/credstore.encrypted/godaddy-api-token
$HOME/.pi
$STATE_ROOT
/var/lib/tailscale
```

Assert default rollback restores legacy ingress, removes only exact managed Caddy service artifacts, and leaves every fingerprint unchanged except the unit/config/binary paths explicitly removed. Assert foreign unit/config/binary or route refusal before mutation.

- [ ] **Step 6: Implement conservative domain rollback**

`rollback_domain` requires exact managed Caddy artifacts and either `raw-exact` or `legacy-exact`. If raw, remove it and restore legacy before stopping Caddy. Stop, disable, and remove only byte-matching managed Caddy unit/config/binary/entrypoint, then daemon-reload. Preserve state and credential. Leave the existing `rollback.sh` behavior intact: it still requires empty Serve before removing Firstp1ck, and its error points operators to custom-domain rollback first when raw ingress exists.

Do not add default certificate or credential deletion flags in this implementation; preservation is the complete minimum required behavior.

- [ ] **Step 7: Run migration and rollback tests**

```bash
bats tests/pi_webui.bats --filter 'migration|restoration|custom-domain rollback|rollback preserves'
```

Expected: all selected tests pass.

- [ ] **Step 8: Commit migration and rollback**

```bash
git add ai/pi/webui/custom-domain.sh ai/pi/webui/rollback.sh tests/pi_webui.bats
git commit -m "feat: migrate Pi Web UI custom ingress safely"
```

---

### Task 6: Public targets and operator runbook

**Files:**
- Modify: `Makefile:1,22-41`
- Modify: `ai/pi/webui/README.md`
- Modify: `tests/pi_webui.bats`

**Interfaces:**
- Consumes: completed `custom-domain.sh check|setup|migrate|rollback` CLI.
- Produces: `make ai-webui-domain-check`, `make ai-webui-domain-setup`, and complete live-operation instructions.

- [ ] **Step 1: Write failing Make isolation and runbook tests**

Add tests equivalent to:

```bash
@test "custom-domain Make targets are explicit and ordinary AI targets are unchanged" {
  fixture="$TEST_ROOT/domain-make"
  mkdir -p "$fixture/ai/pi/webui" "$fixture/ai/pi"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nprintf "domain:%%s\\n" "$*" >>"$CALLS"\n' \
    >"$fixture/ai/pi/webui/custom-domain.sh"
  printf '#!/usr/bin/env bash\nprintf "ordinary:%%s\\n" "$*" >>"$CALLS"\n' \
    >"$fixture/ai/pi/install.sh"

  run make -s -C "$fixture" ai-webui-domain-check
  [ "$status" -eq 0 ]
  run make -s -C "$fixture" ai-webui-domain-setup
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = $'domain:check\ndomain:setup' ]
}
```

Add a runbook string table requiring the exact hostname, DNS record, disclosure, credential path, pinned build, Caddy listener/backend, no Funnel, setup/check/migrate/rollback commands, old/new routes, interruption, Pi drift prerequisite, certificate retention, trusted-client verification, off-tailnet verification, restart/reboot verification, and old `.ts.net` behavior.

- [ ] **Step 2: Run Make/runbook tests and verify red**

```bash
bats tests/pi_webui.bats --filter 'custom-domain Make|custom-domain runbook'
```

Expected: failures because targets and documentation are absent.

- [ ] **Step 3: Add only the two public Make targets**

Update `.PHONY` and add:

```make
ai-webui-domain-check: ## Inspect Pi Web UI custom-domain state without mutation
	bash ai/pi/webui/custom-domain.sh check

ai-webui-domain-setup: ## Build and install the opt-in custom-domain Caddy service
	bash ai/pi/webui/custom-domain.sh setup
```

Do not add either as a dependency of `ai`, `ai-check`, `ai-webui`, `install`, `update`, or `check`.

- [ ] **Step 4: Write the complete runbook**

Document these operator phases separately:

1. resolve Pi drift with separate approval;
2. create `pi.dpao.la A 100.84.88.33` manually in GoDaddy and wait for exact public answers;
3. create the encrypted credential without shell-history exposure:

```bash
sudo install -d -o root -g root -m 0700 /etc/credstore.encrypted
sudo systemd-creds encrypt --name=godaddy-api-token - \
  /etc/credstore.encrypted/godaddy-api-token
# Paste KEY:SECRET, then press Ctrl-D. Do not paste it into chat.
sudo chmod 0600 /etc/credstore.encrypted/godaddy-api-token
```

4. inspect with `make ai-webui-domain-check`;
5. approve and run `make ai-webui-domain-setup` while legacy ingress stays live;
6. inspect exact service/unit/listeners/certificate;
7. approve and run `ai/pi/webui/custom-domain.sh migrate`;
8. verify trusted-tailnet success, off-tailnet failure, loopback listeners, no LAN listener, Funnel disabled, restart behavior, WSL reboot behavior, and no orphaned processes;
9. recover with `ai/pi/webui/custom-domain.sh rollback` or the printed exact route commands.

State that classic GoDaddy credentials are broad and deprecated, reserve `_acme-challenge.pi.dpao.la`, and explain public DNS/Certificate Transparency disclosure and potential DNS-rebinding behavior.

- [ ] **Step 5: Run public-interface and focused tests**

```bash
bats tests/pi_webui.bats
```

Expected: all focused tests pass.

- [ ] **Step 6: Commit targets and documentation**

```bash
git add Makefile ai/pi/webui/README.md tests/pi_webui.bats
git commit -m "docs: add custom-domain operations runbook"
```

---

### Task 7: Full verification, polish, and independent review

**Files:**
- Modify only files justified by verification or accepted review findings.

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: a clean, verified branch ready for a separate PR; no live migration.

- [ ] **Step 1: Inspect the complete diff and secret surface**

```bash
git diff --check origin/main...HEAD
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- . ':!ai/pi/webui/runtime/package-lock.json'
git grep -nE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|GODADDY_API_(KEY|SECRET)=' -- \
  ':!docs/superpowers/specs/*' ':!docs/superpowers/plans/*'
```

Expected: no whitespace errors, no runtime-lock change, no literal credential/private key, and only requested files changed.

- [ ] **Step 2: Run focused verification**

```bash
bats tests/pi_webui.bats
bash -n ai/pi/webui/install.sh ai/pi/webui/tailscale.sh \
  ai/pi/webui/rollback.sh ai/pi/webui/custom-domain.sh \
  ai/pi/webui/caddy-entrypoint.sh
shellcheck -x -S warning ai/pi/webui/install.sh ai/pi/webui/tailscale.sh \
  ai/pi/webui/rollback.sh ai/pi/webui/custom-domain.sh \
  ai/pi/webui/caddy-entrypoint.sh
shfmt -d -i 2 -ci ai/pi/webui/install.sh ai/pi/webui/tailscale.sh \
  ai/pi/webui/rollback.sh ai/pi/webui/custom-domain.sh \
  ai/pi/webui/caddy-entrypoint.sh
```

Expected: all tests and checks pass.

- [ ] **Step 3: Run full repository verification**

```bash
make check
```

Expected: syntax, lint, Bats, Python tests, and AI validation all pass.

- [ ] **Step 4: Perform allowed staged Caddy validation only after explicit build approval**

Without installing a package or service, build the pinned candidate in a private temporary directory and run:

```bash
candidate_dir=$(mktemp -d)
candidate="$candidate_dir/caddy"
rendered_unit="$candidate_dir/pi-webui-caddy.service"
mise exec -- go run github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 \
  build v2.11.4 \
  --with github.com/caddy-dns/godaddy@v1.2.0 \
  --output "$candidate"
cp ai/pi/webui/caddy-entrypoint.sh "$candidate_dir/caddy-entrypoint"
chmod 0755 "$candidate_dir/caddy-entrypoint"
sed "s|@CADDY_ENTRYPOINT@|$candidate_dir/caddy-entrypoint|" \
  ai/pi/webui/pi-webui-caddy.service.in >"$rendered_unit"
"$candidate" version
"$candidate" list-modules --packages | grep -F 'dns.providers.godaddy'
GODADDY_API_TOKEN=validation:only \
  "$candidate" adapt --config ai/pi/webui/Caddyfile.in --adapter caddyfile --validate
systemd-analyze verify "$rendered_unit"
rm -rf -- "$candidate_dir"
```

If approval is not granted, record this verification as not run rather than weakening or simulating the completion claim.

- [ ] **Step 5: Run read-only live checks and report the known blocker**

```bash
mise exec -- pi --version
"$HOME/.local/bin/pi" --version
bash ai/pi/webui/install.sh --check
tailscale version --json
tailscale status --json
tailscale serve status --json
tailscale funnel status --json
ss -ltnup
curl --fail --silent --show-error http://127.0.0.1:31415/api/health
```

Expected before separate Pi approval: the existing checker fails on mise Pi `0.85.0` versus required `0.84.4`; no command mutates live state.

- [ ] **Step 6: Run `polish-core --fix` and inspect every edit**

Load the `polish-core` skill, run its changed-code workflow against `origin/main` with fixes enabled, inspect the resulting diff, revert any scope expansion, and rerun Steps 1–3.

- [ ] **Step 7: Request an independent blocker-only review**

Dispatch one read-only `review` subagent from a different model family. Ask it to compare `origin/main...HEAD` against the approved spec, focusing only on security boundary violations, migration/restoration correctness, credential leakage, unexpected route acceptance, and missing required tests. Apply only verified findings, then rerun Steps 1–3.

- [ ] **Step 8: Commit verification fixes if any**

```bash
git add Makefile ai/pi/webui/Caddyfile.in \
  ai/pi/webui/pi-webui-caddy.service.in \
  ai/pi/webui/caddy-entrypoint.sh ai/pi/webui/custom-domain.sh \
  ai/pi/webui/tailscale.sh ai/pi/webui/rollback.sh \
  ai/pi/webui/README.md tests/pi_webui.bats
git commit -m "fix: address custom-domain verification findings"
```

Skip this commit when the tree is already clean.

- [ ] **Step 9: Explain the completed change**

Load `change-explainer` and report files, architecture, decisions, exact verification results, unrun approval-gated checks, Pi drift, GoDaddy deprecation, public DNS/CT disclosure, DNS-rebinding risk, and the fact that no live DNS/service/certificate/Serve mutation occurred.

- [ ] **Step 10: Push and open the separate PR**

After final user approval to publish the branch:

```bash
git push -u origin feat/pi-webui-custom-domain
gh pr create --base main --head feat/pi-webui-custom-domain \
  --title 'feat: add tailnet-only Pi Web UI custom domain' \
  --body $'## Summary\n- add a pinned loopback-only Caddy DNS-01 service for pi.dpao.la\n- migrate only the exact legacy Tailscale route to raw TCP with restoration\n- preserve Pi, certificate, credential, transcript, worktree, and Tailscale state\n\n## Verification\n- bats tests/pi_webui.bats\n- make check\n- read-only live checks (Pi drift remains a live-migration blocker)'
```

Report the PR URL. Do not perform live setup or migration as part of opening the PR.
