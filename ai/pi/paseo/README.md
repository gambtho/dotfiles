# Paseo: opt-in phone and browser access to Pi

Paseo **0.11.2** uses the existing native Pi host (1.1+), its credentials,
extensions and original session files. The application has its own frozen npm
runtime; it does not install, pin or update Pi itself. Firstp1ck is retired.

## Machine selection

Nothing in ordinary `make ai`, `ai-check`, dot-install, dot-update or the
personal/work/server profiles installs Paseo. Explicitly select a machine:

```bash
DOTFILES_PASEO_ENABLED=1 make ai-paseo-check
DOTFILES_PASEO_ENABLED=1 make ai-paseo
```

The flag has **no enabling default**. Unset/empty/0 checks skip (and indicate an
existing installation); mutations refuse. Invalid values fail. To persist
selection, export it in that machine's untracked local shell configuration,
not a shared tracked profile. It is an operator opt-in, not authentication or
an OS security boundary. No hostname or hardware fingerprints are used.

An installed/enabled `paseo.service` subsequently autostarts without inheriting
that shell flag. Unsetting the flag does not stop/delete the service. The
supported platform is Ubuntu 24.04 Noble under WSL with user systemd. Startup
before login requires deliberately enabled user lingering. This starts when
WSL boots; it does not arrange for Windows to launch WSL.

## Canonical setup and password bootstrap

Apply only from the reviewed, clean canonical primary checkout at origin/main,
never an implementation worktree. Check works without deploying. Stop Pi before
changing linked Pi resources or running its native extension updates. Before a
Paseo service replacement, close active agents, approvals, terminals and running
workspace scripts, and avoid starting new work during the maintenance window.
The installer checks activity twice; unavailable/busy status refuses replacement.

Reconciliation reads this node's `Self.DNSName` from `tailscale status --json`,
removes its trailing dot, and adds that exact hostname to the static
`config.json` baseline (`localhost`, `127.0.0.1`, `pi.dpao.la`). Validation
requires that complete managed list; wildcards and stale node names are not
accepted. Tailscale must already expose a valid node DNS name before preparation
or reconciliation. This is runtime ingress configuration, not machine selection;
`DOTFILES_PASEO_ENABLED` remains the sole provisioning opt-in.

Managed paths (respecting XDG data/config overrides):

- `~/.local/share/paseo/runtimes/current`: locked application runtime
- `~/.local/share/paseo/home`: private mutable Paseo state
- `~/.local/share/paseo/paseo`: exact-home launcher
- `~/.config/systemd/user/paseo.service`: foreground supervisor/cgroup

First apply installs only validated runtime/config/launcher and exits **2** when
no password exists. It does not start an unauthenticated daemon or replace an
existing trial service. Follow the exact launcher command printed by apply:

```bash
~/.local/share/paseo/paseo daemon set-password
DOTFILES_PASEO_ENABLED=1 make ai-paseo
```

Password setup is interactive and works without a daemon. Do not put passwords
in arguments or tracked files. With XDG overrides use the printed path, not a
global `paseo` binary with an ambiguous default home. This is a **fresh setup**:
trial preferences, password, daemon identity and agent registry are not adopted.
Original Pi JSONL sessions/repositories/authentication stay in their original
locations and can be imported into Paseo again.

The launcher and unit neutralize the reviewed daemon override environment
variables (listen, auth, hosts/CORS, relay, home, etc.) without stripping provider
credentials. First-install defaults enable the bundled web UI and Pi provider;
Paseo MCP/injection, browser-agent tools, optional service-proxy layers and
third-party plugins start off. These are not switches for Pi's own resources.
Later optional preferences/passwords are preserved; networking and native Pi
entry-point invariants are reconciled. Extra configured listeners must stay
loopback-only. Paseo's built-in localhost script proxy is distinct from its
optional additional proxy layers.

## Existing private domain

The retained topology is:

```text
Tailnet-only raw TCP 443 → Caddy 127.0.0.1:8443 → Paseo 127.0.0.1:31415
```

Backend installation never changes DNS, Caddy, credentials or Tailscale routes.
The Caddy templates remain byte-identical. Deployed legacy identifiers stay
`pi-webui-caddy.service`, `/usr/local/lib/pi-webui/`, `/etc/pi-webui-caddy/` and
`/var/lib/pi-webui-caddy/`; their names do not mean Firstp1ck still runs.
Existing certificates, encrypted GoDaddy credential and Tailscale identity are
preserved. Funnel, foreign/extra routes, wrong DNS, LAN/wildcard listeners and
unidentified artifacts refuse management. TLS probes verify CA trust, hostname,
validity and authenticated instance-bound backend status, not just HTTP 200.

Existing-domain inspection and explicit reconciliation:

```bash
DOTFILES_PASEO_ENABLED=1 make ai-paseo-domain-check
DOTFILES_PASEO_ENABLED=1 make ai-paseo-domain-setup
```

For a fresh gateway, first provision the backend and GoDaddy encrypted credential
`/etc/credstore.encrypted/godaddy-api-token` through private operator handling;
never place its plaintext in this repository, argv or logs. Set DNS A for
`pi.dpao.la` to the single online Tailscale IPv4, with no AAAA/CNAME. The explicit
proxy sequence is:

```bash
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/tailscale.sh check
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/tailscale.sh serve-legacy
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/custom-domain.sh setup
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/custom-domain.sh migrate
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/custom-domain.sh check
```

`migrate` displays the route change and requires immediate interactive approval.
Already-raw ingress does not need migration; do not switch the working route
just to replay fresh-install steps. The helper pins the existing reviewed
Tailscale/Caddy/module identities; updates are deliberate operations. Caddy setup
has a five-minute outer readiness bound and restores prior files/enablement/
activity on failure. Backend readiness is bounded to about 30 seconds.

## Phone, browser and terminal handoff

Use `pi.dpao.la`, port **443**, SSL on, and the freshly chosen password. The
compiled browser UI may need a one-time **Direct connection** setup. Browser
assets can load without a password; API/WebSocket access remains authenticated.

Paseo resumes the original Pi session ID/file through a separate RPC process;
it does not attach to a running terminal process. To hand off one session:

1. Close/Archive that Paseo agent, not merely its screen or Cancel.
2. Run `pi --resume` in the terminal and select the session.
3. Exit terminal Pi, then reopen the corresponding Paseo agent.

The daemon stays running; other sessions are unaffected. Do not operate the same
session concurrently from both runtimes. After fresh installation, import the
existing native Pi session before using its corresponding Paseo agent.

## Recovery, disablement and explicit retirement

```bash
systemctl --user status paseo.service
journalctl --user -u paseo.service
systemctl --user restart paseo.service
```

Restart interrupts all hosted processes; close work first. Foreground
`daemon run`, `KillMode=control-group` and restart-on-failure are service-owned;
do not run detached `daemon start` alongside it.

The installer recognizes only the exact independently created trial wrapper,
unit and frozen runtime. Unknown units/state, symlinked destinations and retained
transaction evidence refuse replacement. Legacy `pi-webui.service` must already
be inactive and disabled. Offline validation precedes the port handoff; failures
restore the preceding runtime/config/launcher/unit bytes, reload systemd, and
restore enablement/activity. Recovery failure retains a private `.apply.*`
directory and lock for inspection; never erase this evidence blindly.

After successful trial replacement, rollback evidence is retained until an
explicit, separately approved cleanup:

```bash
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/install.sh --retire-trial
```

This requires a healthy managed replacement and positively identified inactive
trial. It removes the exact trial tree and obsolete `password.txt`, never follows
repository/session symlink targets, and refuses unknown files, mounts, Git trees
or foreign ownership. Original Pi sessions/auth/repositories remain untouched.
Installed Firstp1ck caches/worktrees and old unit backup files are separate
operator cleanup targets; none are deleted implicitly.

Explicit backend disablement:

```bash
DOTFILES_PASEO_ENABLED=1 bash ai/pi/paseo/rollback.sh
```

This stops/disables only the identified idle managed backend. Runtime/state and
the proxy remain; it does **not** resurrect the retired trial. For explicit domain
teardown use `custom-domain.sh rollback` (restore legacy ingress) or
`custom-domain.sh rollback --full` (leave Serve empty). Certificates, encrypted
credential and Tailscale identity remain. Do not confuse teardown with automatic
transaction recovery.

## Security and verification limits

Authentication/private ingress are not sandboxing. Paseo and browser-native
operations have the user's account authority, including native Pi resources.
Third-party plugins are trusted unsandboxed code and require deliberate opt-in.

The pinned graph's renewed audit reports **11 vulnerabilities: 3 low, 3 moderate,
5 high, 0 critical**. This is not a clean/hardened dependency graph. Findings include
MCP OAuth-client credential forwarding and reachable Markdown/linkify denial of
service. Disabling Paseo MCP does not cure browser-rendering issues, and optional
features can alter reachability. Do not run automatic `npm audit fix --force`.
For this dotfiles change, the browser-rendering availability risk is explicitly
accepted for private, single-user, password-protected, Tailscale-only use. This
is a known deferred issue, not a clean audit result: hostile or pathological
chat/model output can stall Markdown rendering despite private ingress. It does
not authorize deployment, public/multi-user exposure, or newly enabled features.
Reassess before broadening access or enabling remote MCP OAuth clients/providers.

Upstream remediation is a separate follow-up. Prefer a verified Paseo release
with rebuilt browser assets; npm dependency overrides alone do not repair its
already-bundled browser renderer. Do not blindly accept npm's suggested downgrade.
Live rollout remains separately approved. Never infer production safety from
isolated tests.

Repository gates: `make validate`, `make syntax`, `make lint`, focused Bats and
`make check` with the selected native SDK. The provider-free smoke uses separate
HOME/XDG/Pi directories, all providers disabled, no copied auth and a private
ephemeral port. After separately approved canonical rollout, verify HTTPS login
protection, WSS/session retrieval, stop/start port ownership and the actual iPhone.
Full WSL reboot/device confirmation are distinct from isolated verification.
