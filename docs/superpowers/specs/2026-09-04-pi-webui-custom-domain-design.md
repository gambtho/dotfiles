# Tailnet-only custom HTTPS hostname for Pi Web UI

## Goal

Make the existing Pi Web UI available at `https://pi.dpao.la` without adding
public, LAN, or wildcard ingress. Public GoDaddy DNS points the hostname to the
WSL node's current Tailscale IPv4 address. Tailscale Serve forwards raw TCP 443
to a loopback-only Caddy listener, and Caddy terminates TLS and proxies to the
existing loopback-only Firstp1ck service:

```text
pi.dpao.la
  -> public GoDaddy A 100.84.88.33
  -> WSL Tailscale IP:443
  -> Tailscale Serve raw TCP
  -> Caddy 127.0.0.1:8443
  -> Firstp1ck 127.0.0.1:31415
```

Caddy obtains and renews a certificate for `pi.dpao.la` through ACME DNS-01
using the `caddy-dns/godaddy` module and a dedicated GoDaddy classic Production
key. Tailscale remains the remote transport and authorization boundary. Funnel,
direct LAN exposure, HTTP-01 ingress, Tailscale TLS termination, and additional
Serve routes remain forbidden.

## Established state and prerequisite

The implementation starts from `origin/main` at merge commit
`bc3b0974f4eadb5756d0eb376b4173e8f7e035e8` for PR #16. The current live state
was inspected read-only:

- Firstp1ck `0.10.3` is active at exactly `127.0.0.1:31415`.
- Tailscale `1.102.3` is online as
  `personal-desktop.tail74aee.ts.net` with IPv4 `100.84.88.33`.
- The only Serve route is Tailscale-terminated HTTPS 443 proxying to
  `http://127.0.0.1:31415`; its human status is tailnet-only.
- Caddy is not installed, no Caddy service is active, and port 8443 is unused.
- `dpao.la` is authoritative at GoDaddy and `pi.dpao.la` has no A record.

There is a known Pi version split:

- the repository, Firstp1ck runtime, health contract, and `~/.local/bin/pi` pin
  Pi `0.84.4`;
- the mise-selected package named by the installed service now resolves to Pi
  `0.85.0`;
- the still-running process reports `0.84.4` because it predates the on-disk
  upgrade;
- the existing read-only Web UI checker correctly refuses this state before
  ingress validation.

This PR does not upgrade, downgrade, repin, or bypass Pi validation. Source
implementation and fixture tests may proceed, but custom-domain setup and live
route migration must refuse until Pi alignment is separately approved and a
strict Firstp1ck preflight passes. That preflight requires the pinned Pi
identity, installed runtime, managed unit, active service, exact loopback
listener, and health response; it does not rely on the existing checker's
permissive pre-install behavior. A restart or WSL reboot before alignment may
launch Pi `0.85.0` and is an explicit operational risk.

## Trust and disclosure model

The custom hostname does not add application authentication. Every browser user
allowed through the existing tailnet ACL/grant boundary retains full authority
of the WSL account, as documented by the existing runbook. The
`@gotgenes/pi-permission-system` package and policy remain unchanged.

The public record is intentionally:

```dns
pi.dpao.la.  A  100.84.88.33
```

This discloses the hostname and CGNAT-range Tailscale address publicly. ACME
issuance also discloses the hostname through Certificate Transparency. The
address remains unroutable without Tailscale connectivity and applicable
tailnet policy. Some client resolvers or browsers may reject a public DNS answer
in `100.64.0.0/10` through DNS-rebinding or Private Network Access defenses, so
expected clients must be tested. The design neither creates a CNAME to the
MagicDNS name nor automates DNS changes. If the node is deleted and re-enrolled,
a changed Tailscale IP causes a hard stale-DNS failure until the operator
manually updates GoDaddy.

## Repository interface and ownership

The custom-domain layer remains opt-in and separate from ordinary Pi and
Firstp1ck reconciliation. It adds:

- `ai/pi/webui/custom-domain.sh`: read-only checks, candidate-first setup,
  migration, restoration, and custom-domain rollback.
- `ai/pi/webui/Caddyfile.in`: exact loopback TLS proxy configuration.
- `ai/pi/webui/pi-webui-caddy.service.in`: dedicated hardened system unit.
- `ai/pi/webui/caddy-entrypoint.sh`: credential-to-environment adapter that
  execs Caddy without putting the secret in argv or logs.
- focused additions to `ai/pi/webui/tailscale.sh` for legacy and raw route
  classification and exact route operations.
- focused additions to `ai/pi/webui/rollback.sh` only where the new route state
  must be understood; Caddy-specific removal remains owned by
  `custom-domain.sh`.
- runbook updates in `ai/pi/webui/README.md`.
- behavior tests in `tests/pi_webui.bats`.
- explicit `ai-webui-domain-check` and `ai-webui-domain-setup` Make targets.

`make ai`, `make ai-check`, `make ai-webui`, normal package reconciliation, the
Firstp1ck runtime lock, and the permission policy do not acquire custom-domain
side effects. `ai-webui-check` intentionally changes only its accepted ingress
state from the legacy HTTPS route to empty or the approved raw route; this is a
required behavior change, not an ordinary `make ai` side effect. Live migration
and rollback remain explicit script commands rather than implicit dependencies
of setup or ordinary Make targets.

## Pinned Caddy build

Stock Caddy does not include `dns.providers.godaddy`. Setup builds a private
candidate using the existing mise-managed Go toolchain and these explicit
versions:

- Caddy `v2.11.4`;
- xcaddy `v0.4.7`;
- `github.com/caddy-dns/godaddy` `v1.2.0`.

The intended build is equivalent to:

```bash
go run github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 \
  build v2.11.4 \
  --with github.com/caddy-dns/godaddy@v1.2.0 \
  --output <private-candidate>/caddy
```

Package download and candidate construction require separate operator approval.
Before publication, setup checks the executable identity, Caddy version,
`dns.providers.godaddy` module presence, Caddyfile adaptation, Caddy
configuration validation, and the rendered systemd unit. A failed build or
validation leaves the live system unchanged. The private binary is installed
under `/usr/local/lib/pi-webui/`; it does not replace `/usr/bin/caddy` or claim
an unrelated `caddy.service`.

If the pinned combination does not compile or validate, setup stops. Changing a
pin requires a reviewed source change and rerunning all verification rather
than selecting an unpinned latest version.

## Caddy configuration

The effective Caddyfile is:

```caddyfile
{
	admin off
	auto_https disable_redirects
	https_port 8443

	servers {
		protocols h1 h2
	}
}

pi.dpao.la {
	bind 127.0.0.1

	tls {
		dns godaddy {
			api_token {env.GODADDY_API_TOKEN}
		}
	}

	reverse_proxy 127.0.0.1:31415
}
```

`https_port 8443` changes Caddy's internal listener without changing the client
port expected behind forwarding. `bind 127.0.0.1` forbids wildcard, IPv6, LAN,
and Tailscale-interface binding. `auto_https disable_redirects` preserves
certificate automation while preventing an automatic port 80 listener.
Restricting protocols to `h1 h2` prevents an HTTP/3 UDP listener. `admin off`
prevents a local or remote admin endpoint; configuration changes therefore use
an explicit service restart, not the admin API. DNS-01 disables the need for
HTTP-01 or TLS-ALPN public ingress.

The GoDaddy module accepts only a classic credential formatted as
`<GODADDY_API_KEY>:<GODADDY_API_SECRET>` and sends legacy `sso-key`
authentication to the production Domains v1 API. The credential is broad and
deprecated. The implementation documents rotation and isolates provider use so
a later PAT-capable module can replace it.

The module manages `_acme-challenge.pi.dpao.la`. GoDaddy's `PUT` and `DELETE`
operations replace or remove the complete TXT RRset for that name, so the
runbook reserves that exact record name for this certificate flow and forbids
unrelated values or concurrent certificate clients there.

## System service and credentials

Caddy runs as a dedicated system service named `pi-webui-caddy.service`, not as
the WSL user service that owns Firstp1ck. The rendered unit is equivalent to:

```ini
[Unit]
Description=Pi Web UI custom-domain TLS proxy
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=notify
DynamicUser=yes
StateDirectory=pi-webui-caddy
Environment=HOME=/var/lib/pi-webui-caddy
Environment=XDG_DATA_HOME=/var/lib/pi-webui-caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/pi-webui-caddy/config
LoadCredentialEncrypted=godaddy-api-token
ExecStart=/usr/local/lib/pi-webui/caddy-entrypoint
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
AmbientCapabilities=
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Implementation verifies the final unit with `systemd-analyze verify` and keeps
only directives supported by Ubuntu 24.04's systemd 255 and Caddy's actual
readiness behavior. Port 8443 requires no bind capability. The system service
cannot order directly against the user's `pi-webui.service`; Caddy may briefly
return 502 during boot until Firstp1ck starts, and health checks verify each
service independently.

The operator creates an encrypted systemd credential interactively under
`/etc/credstore.encrypted/`. The plaintext is never accepted as a script
argument and is not stored in Git, the Caddyfile, the unit, a shell command, or
an environment file. At startup systemd decrypts it into the unit's private,
read-only credentials directory. `caddy-entrypoint` validates that the
credential file exists, exports it as `GODADDY_API_TOKEN`, and uses `exec` to
start the dedicated Caddy binary. It omits Caddy's `--environ` flag to avoid
logging the secret. The secret exists only in the service's protected
credential file and Caddy process environment while running. The password
manager remains the recovery copy for a host-bound encrypted credential.

Caddy certificate and ACME account state persist under
`/var/lib/pi-webui-caddy/`. Journald captures service diagnostics. Restart uses
`on-failure` with a bounded start rate.

## Read-only custom-domain check

`make ai-webui-domain-check` performs no mutation and reports each boundary
separately:

1. supported WSL/systemd platform and the unresolved/resolved Pi identity;
2. exact Tailscale client release `1.102.3`, daemon `Version` from the same
   release, and one online Tailscale node IPv4;
3. public authoritative and client DNS answers;
4. exact managed Caddy binary, module, Caddyfile, entrypoint, and unit;
5. active Caddy service and exactly one TCP listener at
   `127.0.0.1:8443`;
6. no Caddy listener on port 80, UDP 8443, wildcard, IPv6, Tailscale, or WSL LAN
   addresses;
7. a currently trusted, unexpired certificate for `pi.dpao.la`;
8. proxied `/api/health` through local Caddy with SNI and normal CA validation;
9. Firstp1ck health at exactly `127.0.0.1:31415`;
10. exact Tailscale Serve and Funnel classification.

DNS must contain exactly one A answer matching the node's current Tailscale
IPv4, no CNAME, and no AAAA. Missing, multiple, stale, or conflicting answers
are hard failures. The helper never writes DNS.

Caddy setup validates the classic credential with a non-mutating authenticated
zone/record read without printing request headers, response headers, or the
credential. Certificate readiness is established only after approved setup has
started Caddy, DNS-01 has completed, and local trusted TLS and proxy health both
succeed while the legacy route remains active.

## Tailscale route contract

For installed Tailscale `1.102.3`, official syntax for raw forwarding is:

```bash
sudo tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443
```

The installed version's source defines this JSON representation:

```json
{
  "TCP": {
    "443": {
      "TCPForward": "127.0.0.1:8443"
    }
  }
}
```

Every custom-domain route check or operation first requires
`tailscale version --json` to report client release `1.102.3` and
`tailscale status --json` to report a daemon `Version` from release `1.102.3`.
A version mismatch fails before route classification or mutation. Supporting a
new release requires capturing its help and status output, reviewing its source
schema, updating fixtures, and changing the pinned supported version in source.

The route checker combines `tailscale serve status --json`,
`tailscale funnel status --json`, human Serve status, and node status. It fails
closed on unexpected nonempty keys or disagreement. It recognizes:

- `empty`: no Serve configuration;
- `legacy-exact`: one Tailscale-terminated HTTPS 443 root proxy to
  `http://127.0.0.1:31415`, tailnet-only;
- `raw-exact`: one raw `TCPForward` on 443 to `127.0.0.1:8443`,
  tailnet-only.

It rejects every other state, including Funnel, HTTP or HTTPS termination on the
new route, `TerminateTLS`, Web handlers, extra ports, extra targets, foreign
backends, and unknown nonempty fields.

The human `tailscale serve status` tree is parsed against the exact 1.102.3
formatter (`cmd/tailscale/cli/serve_legacy.go`, `printTCPStatusTree` and
`printWebStatusTree`, dispatched from `serve_status.go`). A node-level raw TCP
forward renders as:

```text
|-- tcp://<magicdns-name>:443 (tailnet only)
|-- tcp://<tailscale-ip>:443          one line per Status.TailscaleIPs
|--> tcp://127.0.0.1:8443
```

Address lines are rendered through `net.JoinHostPort`, so an IPv6 address is
bracketed and a dual-stack node prints one line per family. The classifier
therefore compares the address lines as a set against the node's own
`Self.TailscaleIPs`, requires each expected address exactly once and no extra
line, and requires the exact `(tailnet only)` descriptor: `Funnel on` and
`TLS-terminated TCP` change that descriptor and are refused. It also refuses to
classify when `Status.TailscaleIPs` and `Self.TailscaleIPs` disagree.

Acceptance is caller-specific:

- `tailscale.sh check` and normal post-change validation accept only `empty` or
  `raw-exact`;
- initial custom-domain setup requires exactly `legacy-exact` but calls the
  classifier directly rather than the steady-state ingress check;
- migration accepts only `legacy-exact` as its source and `raw-exact` as its
  result;
- automatic restoration accepts only `empty` or `raw-exact` before restoring
  `legacy-exact`.

This preserves fail-closed ownership without requiring the pre-migration legacy
route to satisfy the new steady-state checker.

The JSON expectation is based on the exact installed release's source because
observing it live would require a route mutation. The approved migration must
capture and report the actual JSON immediately after publication. A mismatch is
a failed migration and triggers restoration where safe; no success is reported
until the live schema is confirmed.

The helper never uses `tailscale serve reset`. Exact commands are:

```bash
# Remove old route
sudo tailscale serve --https=443 off

# Publish new route
sudo tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443

# Remove new route
sudo tailscale serve --tcp=443 off

# Restore old route
sudo tailscale serve --bg --https=443 http://127.0.0.1:31415
```

`tailscale.sh serve` and `serve-off` own the raw route exclusively. Because the
raw route is meaningless before Caddy exists, the transitional legacy route has
its own explicit public verbs, `serve-legacy` and `serve-legacy-off`, which
first install and full uninstall use. Both remain exact and Funnel-free and
reuse the same classifier.

## Setup flow

The explicit setup target is candidate-first and does not alter Tailscale Serve:

1. Require the canonical primary checkout at clean `origin/main` for apply;
   allow linked worktrees only for check and tests.
2. Run a strict preflight that requires the pinned external Pi identity, exact
   installed Firstp1ck runtime, exact managed unit, active service, one listener
   at `127.0.0.1:31415`, and valid health response. Any absent component is a
   hard failure before build, credential access, or publication.
3. Require Tailscale client and daemon release `1.102.3` and exactly
   `legacy-exact` route state.
4. Require exact public DNS to the current Tailscale IPv4.
5. Require the encrypted credential to exist; validate GoDaddy API access
   without exposing it.
6. Refuse foreign Caddy binaries, configs, units, state ownership, or listeners.
   An existing binary at the managed path is reconcilable only when it is
   executable and reports exactly Caddy `v2.11.4` with exactly
   `dns.providers.godaddy` at `v1.2.0` from `github.com/caddy-dns/godaddy`
   (`caddy list-modules --packages` and `--versions --packages`).
7. Build and validate a private pinned Caddy candidate.
8. Render and validate the exact Caddyfile, entrypoint, and system unit.
9. Publish only the dedicated managed paths, reload systemd, and start/enable
   `pi-webui-caddy.service`.
10. Wait, bounded, for DNS-01 issuance and verify local certificate trust,
    hostname, expiry, loopback listener, and proxied Firstp1ck health. The
    retry loop paces that wait with 15 attempts, a 10-second probe bound, and
    a 5-second interval, and the whole readiness operation — the loop plus
    every authoritative installed, listener, LAN, and TLS/health check — runs
    inside one 290-second `timeout` with 5 seconds of kill grace, so the
    documented five minutes is a wall-clock guarantee even though the LAN
    probes scale with the host's interface count. Every readiness, health,
    LAN, and legacy probe also carries explicit connect and total timeouts,
    and each `openssl s_client` handshake is bounded by `timeout`.
11. Leave the legacy Serve route untouched and report readiness for a separately
    approved migration.

A pre-publication failure removes only candidate files. A failure after managed
publication restores the prior managed binary, Caddyfile, entrypoint, unit,
enablement, and activity where they existed. Each cleanup flag is raised before
the call it describes, so a command that mutates and then reports failure still
triggers restoration; an enablement introduced by the run is undone while the
unit file still exists, because `systemctl disable` cannot remove an enablement
symlink for a deleted unit. Prior enablement and activity are read from
systemd's state words rather than from exit status alone, so a D-Bus or manager
error aborts before publication instead of being recorded as
disabled/inactive. Restoration does not delete certificates, credentials, Pi
state, Tailscale state, or unrelated Caddy installations.

## Migration transaction

Migration is a separate interactive operation. Immediately before mutation it
repeats all external-boundary checks and requires:

- resolved Pi identity and a passing existing Web UI check;
- exact DNS to the current Tailscale IPv4;
- exact managed and healthy Caddy state;
- one `127.0.0.1:8443` listener and no forbidden listeners;
- a trusted certificate for `pi.dpao.la` and healthy proxy response;
- exactly `legacy-exact` Serve state and no Funnel.

It displays the DNS record, credential mechanism, exact unit/config paths, old
and new route commands, rollback commands, and expected interruption, then asks
immediately before mutation. On approval it:

1. removes the exact old HTTPS route;
2. requires empty state;
3. publishes the exact raw TCP route;
4. captures and classifies actual JSON and human status;
5. verifies `https://pi.dpao.la/api/health` through the Tailscale address;
6. rechecks listeners, certificate, Firstp1ck, and Funnel;
7. requires operator confirmation that a separate trusted tailnet client works.

The expected interruption is several seconds. Existing browser WebSockets will
disconnect because the origin changes. Firstp1ck and its Pi process are not
restarted. After success, `https://pi.dpao.la` is canonical and the old
`.ts.net` HTTPS URL no longer works because raw forwarding presents Caddy's
custom-host certificate and site.

On command failure, timeout, failed verification, operator rejection, EOF,
`INT`, or `TERM`, migration restores the old route when the observed state is
empty or exactly `raw-exact`:

1. remove `raw-exact` if present;
2. require empty state;
3. publish the exact legacy HTTPS route;
4. verify `legacy-exact` and old-URL health;
5. report the original failure and restoration result.

If a foreign or additional route appears concurrently, automatic recovery
refuses to overwrite it and reports the exact observed state plus manual
recovery commands. Restoration failure is reported prominently and never
masked by the initiating error.

Off-tailnet failure cannot be proven from the WSL node. After migration the
operator separately verifies success from a trusted tailnet client and failure
from a client with Tailscale disconnected.

## Rollback and retained state

Custom-domain rollback has two modes:

- migration rollback (`custom-domain.sh rollback`) removes `raw-exact`,
  restores `legacy-exact`, verifies the old URL, then stops/disables and
  removes the managed Caddy service. From an already-`legacy-exact` route it
  reports that no restoration was needed and still proves the old URL before
  teardown;
- full removal (`custom-domain.sh rollback --full`) removes the exact raw or
  exact transitional legacy route, leaves Serve empty, removes the managed
  Caddy service artifacts, and then permits the existing Web UI rollback flow.

The Web UI rollback refuses to run while either route is published and names
the exact command that removes it.

Default rollback preserves:

- `/var/lib/pi-webui-caddy/` certificates and ACME state;
- the encrypted GoDaddy credential;
- Firstp1ck runtime and landing worktree;
- Pi settings, sessions, transcripts, and supervisor state;
- backups and retained evidence;
- Tailscale package, node identity, and ACL/grant boundary.

Credential and certificate deletion require separate explicit flags and are not
part of migration recovery. Foreign units, binaries, configs, routes, state
owners, or listeners are refused rather than removed.

## Testing

Meaningful behavior is implemented test-first in `tests/pi_webui.bats`. Focused
coverage includes:

1. hostname fixed exactly to `pi.dpao.la`;
2. Caddy listening only at `127.0.0.1:8443` and proxying only to
   `127.0.0.1:31415`;
3. admin API, automatic redirects, port 80, wildcard listeners, and HTTP/3
   disabled;
4. exact custom binary/module identity and candidate validation before
   publication;
5. systemd credential use with no token, private key, PEM, or ACME state in
   tracked source, rendered config, argv, or logs;
6. missing, multiple, stale, CNAME, and unexpected-AAAA DNS states;
7. empty, `legacy-exact`, `raw-exact`, Funnel, terminated-TLS, foreign, and
   additional Serve states;
8. no route mutation on Pi, DNS, Caddy, listener, certificate, or health
   preflight failure;
9. exact old-route removal and new-route publication order;
10. restoration after publication, status, TLS, proxy-health, or operator
    verification failure;
11. refusal to overwrite unexpected post-mutation route state;
12. both ports 31415 and 8443 unreachable on discovered non-Tailscale WSL LAN
    addresses;
13. rollback preserving Caddy state, credential, settings, transcripts,
    worktrees, evidence, and Tailscale identity;
14. ordinary `make ai`, `make ai-check`, and `make ai-webui` behavior remaining
    unchanged, with the intentional `ai-webui-check` route-policy change tested
    separately;
15. caller-specific route acceptance for steady-state check, initial setup,
    migration, and restoration;
16. Tailscale client or daemon version mismatch refusing classification and
    mutation;
17. strict Firstp1ck setup preflight rejecting absent runtime, unit, service,
    listener, or health before build or credential access;
18. only explicit custom-domain setup/check targets invoking the new subsystem.

Fixtures and command stubs exercise source behavior without DNS mutation,
credential use, package installation, certificate issuance, service changes, or
Tailscale mutation. Tests stay proportionate and do not reintroduce adversarial
same-user inode, syscall, signal-boundary, or exhaustive transaction hardening.

## Verification and review

Before opening the PR, run:

- focused `bats tests/pi_webui.bats`;
- `make check`;
- Bash syntax, ShellCheck, and shfmt through repository targets;
- candidate Caddy adaptation and validation in an isolated fixture or staged
  build after package/build approval;
- `systemd-analyze verify` for the rendered unit;
- read-only checks against the live installation, with the known Pi drift
  reported rather than bypassed;
- `polish-core --fix`, diff inspection, and fresh verification;
- one independent blocker-only review.

No completion claim is made without exact command results. The final report
includes changed files, decisions, live read-only findings, remaining risks,
and the separate PR URL.

Before any live DNS change, credential decryption, package/build action,
certificate issuance, service publication, Pi alignment, or Serve mutation, the
operator receives the exact commands and expected effects and must explicitly
approve that phase.
