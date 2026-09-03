# Pi Web UI operations

This opt-in integration runs Firstp1ck as a persistent browser interface for the
repository-managed Pi. It is supported only on **Ubuntu 24.04 Noble under WSL**
with a working systemd user manager. It is deliberately absent from normal
`make ai`, `make ai-check`, `bin/install`, `make check`, and `make test`.

## Security and access model

Treat the Web UI and every tailnet client that can reach it as **full WSL-account control**.
Browser-native file, Git, settings, package, update, and
network controls are outside Pi's tool approval flow. Use trusted devices only,
keep sensitive prompts and files out of browser sessions, and remove a device
from the tailnet if it is no longer trusted.

The managed service listens only on `127.0.0.1:31415`; Tailscale Serve is the
only remote ingress. Never enable Funnel, Firstp1ck's `network-open` control,
the remote companion, optional packages, or browser-managed updates. The
helpers neither accept nor persist auth keys or secrets: `tailscale.sh up`
performs Tailscale's interactive login. The existing Pi permission system is unchanged,
but it does not gate browser-native operations. No target or helper exposes the
Pi Web UI on the WSL LAN; the Web UI listener is confined to `127.0.0.1:31415`.
Tailscale daemon networking is separate from this Pi Web UI listener boundary.

Tailscale Serve makes tailnet requests appear local to the application. That is
why any trusted tailnet device has the WSL user's authority even though the
application remains loopback-bound.

## First installation

WSL and its systemd user manager must be running for setup, checks, browser use,
and service operations. Run this exact sequence from the canonical dotfiles
checkout; invoke the Tailscale helpers directly so their `/usr/bin/bash -p`
startup contract is preserved:

```bash
make ai
make ai-webui-check
./ai/pi/webui/tailscale.sh install
./ai/pi/webui/tailscale.sh up
make ai-webui
./ai/pi/webui/tailscale.sh serve
make ai-webui-check
```

`make ai` installs the prerequisite core Pi. The first
`make ai-webui-check` is intentionally useful before installation: it validates
the tracked lock, platform, systemd, source repository, and exact Pi identity.
An `installed runtime absent` message is informational. Before Tailscale is
installed and authenticated, the final read-only Tailscale stage is expected to
fail; continue only after reviewing that failure as the missing prerequisite.
The check performs no package, runtime, worktree, service, or route mutation.

The explicit privilege checkpoints are the direct helper actions `install`,
`up`, and `serve`. They show normal sudo prompts for official Noble repository
publication/package setup, interactive Tailscale login, and Serve route
publication respectively. `make ai-webui` itself contains no sudo: it invokes
the Web UI installer directly with `--apply`, builds and validates a candidate,
then reconciles the user service. Do not prefix the Make targets or helper
commands with sudo.

`serve` accepts only an empty route graph or the already-exact HTTPS 443 root
proxy to `http://127.0.0.1:31415`. It refuses Funnel, public targets, foreign
handlers, or additional routes rather than replacing them.

## Browser URLs

- From a browser in WSL, use `http://127.0.0.1:31415`.
- From a browser on the same Windows host, use local HTTP at
  `http://localhost:31415` through WSL localhost forwarding.
- From a phone or another trusted tailnet device, use the tailnet HTTPS URL
  printed by Tailscale Serve, never the WSL LAN address or plain HTTP.

The WSL instance and `pi-webui.service` must stay running for all three paths.
Stopping WSL or the service makes both the Windows-local and tailnet URLs
unavailable; Serve does not keep the backend alive.

## Worktree policy

The service opens in the managed landing checkout
`~/.local/share/pi-webui/worktrees/dotfiles`. The installer owns this clean,
detached linked worktree and advances it to the reviewed source commit. Do not
attach a branch, edit files, or store project work there.

For real work, select an existing project linked worktree as the tab/workspace
working directory. If one does not exist, create it outside the primary
checkout first, then select that absolute path in the Web UI:

```bash
git -C /path/to/project worktree add /path/to/project-worktrees/feature -b feature
```

Never select a primary checkout. Firstp1ck has no server-side linked-worktree
allowlist, and its browser-native writes bypass Pi permissions. The Pi worktree
guard remains useful for model-facing write tools but cannot enforce the
browser selection.

## Exact runtime and update policy

The accepted supply-chain identities are:

- `@firstpick/pi-package-webui` `0.10.3`, npm integrity
  `sha512-46Hmgv/ccINvexRof3w7JzVoutrBcQ06OC2RiLh/aU1MAZvv7Uss6M0CgHkjb8fzzDaspNgihAbu+U0R0TGafQ==`;
- `@earendil-works/pi-coding-agent` `0.84.4` for the externally selected Pi
  launcher and the six hardened nested Earendil packages;
- tracked lock SHA-256
  `39593de061e22a36668a0a0d1449e339b84e644d6c65e6b1618af9d177fc71d0`.

The installer uses the committed lock through `npm ci --ignore-scripts --omit=optional`;
lifecycle scripts, optional `node-pty`, global installs,
`pi install`, and Firstp1ck package-management controls are excluded. In
particular, do not use the browser self-update.

For an ordinary reviewed dotfiles update:

```bash
git pull --ff-only
make check
make ai
make ai-webui-check
make ai-webui
make ai-webui-check
```

The apply builds and validates a sibling candidate before stopping a known-good
service. If post-stop publication or health checks fail, it restores the prior
runtime, owner-only unit, landing-worktree commit, enablement, and active state;
candidate/transaction evidence is retained when automatic restoration itself
cannot be proved.

A retained candidate and pending transaction intentionally block another
apply. A staged candidate service unit is optional because a Task 2-only
handoff can precede unit rendering, but a unit without recognized pending
handoff evidence is ambiguous and blocks check, apply, and archive. Archive all
present artifacts only after the failure is inspected and its source fix is
installed; the action includes all present candidate artifacts:

```bash
./ai/pi/webui/install.sh --archive-pending
```

This action validates the Noble/WSL platform, owner-only state paths, matching
transaction markers and ownership tokens, source metadata, the complete
installed candidate, and any staged unit's fixed path, owner-only regular-file
shape, transaction hash when recorded, and rendered pinned-template content
before moving anything. Archive-critical commands resolve
only from the authored `/usr/bin:/bin` path, and the validator runs through
`/usr/bin/bash -p`. The action uses read-only Git `rev-parse` and `cat-file`
calls to validate source evidence; no mutating Git command is used. It acquires
the same apply lock and requires the candidate runtime, pending transaction,
any staged candidate service unit, failure root, and temporary archive to
remain on the same filesystem before moving evidence.
Before locking, it verifies that fixed coreutils `/usr/bin/mv` supports
`--no-copy`. Every evidence, publication, and restoration rename uses
`/usr/bin/mv -T --no-copy`, so an unexpected `EXDEV` failure cannot fall back
to copy-and-delete. Device checks are additional diagnostics, not the atomicity
mechanism.

Each rename is atomic on that filesystem, and the final temporary-directory
rename makes the complete archive visible under the unique bounded path
`~/.local/share/pi-webui/backups/failures/<id>`. The candidate runtime, pending
transaction, and any staged candidate service unit are retained exactly. During apply and archive lock creation,
HUP/INT/TERM are deferred from the successful lock-directory creation until
both owner-only markers are complete. The original handlers are then restored
and any deferred signal is replayed, so archive cleanup sees a fully owned lock.
A synchronous initialization failure removes only the exact newly created
partial lock state; changed or unexpected state is preserved as ambiguous.
EXIT and INT/TERM/HUP handling restores partial moves and releases only an
unchanged owned lock; if restoration cannot be proved, the helper exits nonzero
and identifies the retained temporary archive. SIGKILL cannot be deferred or handled.
It can still leave a partial lock in this tiny initialization window. The next
invocation rejects and preserves that malformed state for operator inspection.
An interruption after the final rename can return nonzero while
retaining the already-complete published archive. The action does not run npm,
alter the current service/runtime/worktree, mutate Git, or change Tailscale
routes. Existing
symlinked, foreign, permissive, colliding, partial, cross-device, or concurrently
locked state is preserved and rejected. With no candidate and no pending
transaction it reports a successful no-op.

Advancing a pin is a separate review ceremony, not routine operation. In a
linked update worktree, review the upstream tag/commit and tarball, change the
exact Firstp1ck and matching Pi versions together, regenerate the complete npm
lock with scripts and optional dependencies disabled, record the new registry
SHA-512 integrity and lock SHA-256 in the validator/tests, and update every
installer/helper identity assertion. Review the entire lock diff for only HTTPS
npm-registry SHA-512 entries and the six hardened Earendil entries. Run the
focused Bats suite and full `make check`, commit the reviewed lock and validation
constants together, then use the ordinary sequence above. Never weaken a
validator merely to accept unexplained drift.

## Status, health, and logs

These commands are read-only:

```bash
systemctl --user status pi-webui.service
curl --fail --silent http://127.0.0.1:31415/api/health
ss -ltnp '( sport = :31415 )'
journalctl --user -u pi-webui.service -n 150 --no-pager
./ai/pi/webui/tailscale.sh check
```

Healthy state is an active user service, Web UI `0.10.3`, Pi `0.84.4`, one
listener at exact loopback, `network.networkUrls` present as an exactly empty
array, an exact managed cwd/Pi
command for every tab, an unreachable WSL-LAN port, and either an empty route or
the one exact tailnet-only route.

Tailscale Funnel status shares the Serve graph in the accepted Tailscale CLI;
non-empty `tailscale funnel status --json` therefore does not by itself mean
Funnel is public. The helper compares Serve and Funnel JSON, rejects true/public
`AllowFunnel` targets, and requires the human status to say `(tailnet only)` for
the exact loopback proxy. Use the helper result (`route=empty` or
`route=exact-tailnet-only`) rather than interpreting raw shared JSON as exposure.

To deliberately stop and start the backend:

```bash
systemctl --user stop pi-webui.service
systemctl --user start pi-webui.service
```

A deliberate stop calls the loopback shutdown endpoint and must leave no Web
UI supervisor, scoped Pi child, or listener. Starting again may open a fresh
tab; see the accepted recovery limit below. The Serve route can remain
configured while stopped, but its URL has no healthy backend.

## Accepted limitations

- Browser run-level Abort is unavailable while a permission modal is open.
  Resolve the modal with Deny/Cancel; this safely answers the permission request
  but is not equivalent to run Abort. Abort becomes available after the modal
  resolves.
- A service crash or restart may create a fresh tab instead of preserving a live
  tab. Saved transcripts remain on disk; manually resume the intended session
  after recovery. Ordinary page reload and browser close/reopen preserve the
  supported browser view/preferences.

## Accepted-trial migration

The first `make ai-webui` recognizes the current accepted trial unit and
runtime, validates them, and migrates the smoke cwd to the managed landing
worktree. It leaves an unchanged accepted Serve route in place. On success, the
accepted trial runtime is retained at
`~/.local/share/pi-webui/backups/previous/accepted-trial-runtime`; the current
trial record remains at
`~/.local/share/pi-webui/evaluation-2026-09-02.md`. Earlier Piface evidence is
not removed. Failed migration restores the exact trial unit, runtime, cwd,
enablement, and activity before returning failure when that restoration can be
proved.

## Rollback and uninstall

Remove remote ingress first. This is an operator sudo checkpoint and refuses
foreign/multiple/Funnel configuration:

```bash
./ai/pi/webui/tailscale.sh serve-off
```

The default rollback then disables and cleanly stops only a proven managed
service and removes its unit:

```bash
./ai/pi/webui/rollback.sh
```

By default it preserves **settings, supervisor state, transcripts, Tailscale identity, trial evidence, and backups**,
as well as the managed runtime and
landing worktree. It never deletes uploads or unrelated Pi state.

The following destructive choices exactly match the helper interface. They are
optional and remove only a validated owner-only runtime and/or a clean detached
managed worktree; dirty, attached, foreign, symlinked, or transaction-active
state is retained with an error:

```bash
./ai/pi/webui/rollback.sh --remove-runtime
./ai/pi/webui/rollback.sh --remove-worktree
./ai/pi/webui/rollback.sh --remove-runtime --remove-worktree
```

These flags still preserve settings, transcripts, supervisor state, accepted
trial evidence, backups, and Tailscale identity. They do not uninstall
Tailscale.

To remove the Tailscale package and the exact managed Noble repository files,
first remove Serve and retire the Web UI, then run:

```bash
./ai/pi/webui/tailscale.sh uninstall
```

`uninstall` refuses an active route and uses sudo for package/repository
operations. It does not purge or log out: Tailscale identity state is preserved.
Deleting the node or its identity is intentionally outside these helpers.
