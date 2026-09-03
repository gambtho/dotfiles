# Permanent Pi Web UI integration plan

> **Execution:** Use subagent-driven development task-by-task. Tests lead implementation; each task receives independent review before the next begins.

**Goal:** Persist the accepted Firstp1ck `0.10.3` and Tailscale Serve setup in dotfiles without changing normal `make ai`, weakening Pi permissions, exposing LAN/Funnel, or losing the accepted rollback path.

**Supported target:** Ubuntu 24.04 Noble under WSL with systemd user services. Other systems receive a clear unsupported result and no mutation.

## Accepted behavior and limitations

- The Web UI listens only on `127.0.0.1:31415`; Tailscale Serve is the only remote ingress.
- Funnel and Firstp1ck network-open remain prohibited.
- The phone/tailnet, permission deny/replay, browser persistence, Serve removal/restoration, and clean shutdown gates passed.
- While a permission modal is open, dialog Deny/Cancel is the accepted recovery path; run-level Abort is unavailable until the modal resolves.
- Service crash/restart recovery may create a fresh tab; saved transcripts are manually resumable.
- The permanent service starts in a managed detached linked worktree at `~/.local/share/pi-webui/worktrees/dotfiles`. Firstp1ck may still open project-specific linked worktrees; linked-worktree-only use remains operational policy plus the existing Pi worktree guard.

## Architecture decisions

1. Add explicit `make ai-webui` and mutation-free `make ai-webui-check`; normal `make ai` and `bin/install` remain unchanged.
2. Keep the integration under `ai/pi/webui/` rather than expanding the main Pi installer.
3. Commit the accepted exact `package.json` and hardened npm lock. Install with `npm ci --ignore-scripts --omit=optional`; never use `pi install`, global npm, Firstp1ck self-update, optional companions, or `node-pty`.
4. Build and validate a sibling candidate runtime before stopping a known-good service. Promote atomically enough to restore the previous runtime, unit, worktree commit, and active state after a post-stop failure.
5. Render the systemd unit from a tracked template because the Pi launcher and durable worktree paths are machine-specific. Retain the accepted mise wrapper, loopback bind, `/api/shutdown`, `Restart=on-failure`, default control-group cleanup, owner-only umask, `NoNewPrivileges`, and `PrivateTmp`.
6. Treat Tailscale package installation, authentication, Serve enablement, and Serve removal as explicit operator subcommands. Own and validate the official Noble repository setup, but never store credentials or enable Funnel.
7. Default rollback removes remote ingress first, cleanly disables the service, and preserves runtime, worktree, transcripts, settings, Tailscale identity, and trial evidence. Destructive cleanup requires separate explicit flags and ownership/cleanliness checks.

## Tracked file map

Create:

- `ai/pi/webui/runtime/package.json`
- `ai/pi/webui/runtime/package-lock.json`
- `ai/pi/webui/pi-webui.service.in`
- `ai/pi/webui/install.sh`
- `ai/pi/webui/tailscale.sh`
- `ai/pi/webui/rollback.sh`
- `ai/pi/webui/README.md`
- `bin/validate-pi-webui`
- `tests/pi_webui.bats`

Modify:

- `Makefile`
- `README.md`
- `ai/README.md`

## Task 1: Lock the tracked runtime and validator

**Produces:** offline proof that the authored runtime is exactly the accepted package graph.

1. Add failing Bats cases for wrong Firstp1ck version/integrity, lock hash drift, missing SHA-512 integrity, non-registry/link dependencies, root scripts/optional dependencies, and prohibited `node-pty` installation.
2. Copy the accepted `package.json` and hardened lock byte-for-byte into `ai/pi/webui/runtime/`.
3. Implement `bin/validate-pi-webui` with tracked-runtime and installed-runtime modes. Require lockfile v3, exact root dependency, accepted Firstp1ck integrity, exactly the six hardened Earendil entries, registry-only SHA-512 entries, and accepted lock SHA-256.
4. Validate shell syntax, fixture mutations, and the real tracked lock.
5. Commit: `test: lock Pi Web UI runtime`.

## Task 2: Add transactional runtime and worktree installation

**Produces:** a candidate runtime and durable linked worktree without service mutation.

1. Add failing tests using temporary homes/repos and command stubs for platform gating, exact Pi identity, candidate `npm ci` flags, no `pi install`, foreign/symlink worktree refusal, dirty-worktree preservation, creation, and clean detached updates.
2. Implement `ai/pi/webui/install.sh --check|--apply` preflight:
   - require Noble WSL, systemd user availability, `mise`, Node/npm, and exact Earendil Pi `0.84.4`;
   - resolve the canonical source repository/common Git directory;
   - validate tracked runtime before network/install actions.
3. Build a sibling candidate runtime with the exact tracked manifest/lock, run scriptless optional-free `npm ci`, and validate installed identity, lock immutability, launcher presence, and `node-pty` absence.
4. Manage `~/.local/share/pi-webui/worktrees/dotfiles` as a detached linked worktree belonging to the canonical source repo. Refuse symlinks, foreign repos, primary checkout, and any dirty tracked/untracked state. Update only a clean detached worktree and retain its prior commit for rollback.
5. Commit: `feat: add Pi Web UI runtime installer`.

## Task 3: Reconcile the service and migrate the accepted trial

**Produces:** a rendered owner-only unit and verified loopback service using the durable worktree.

1. Add failing tests for token rendering, exact accepted unit properties, mode `0600`, `systemd-analyze --user verify` before load, candidate-before-stop ordering, health/listener/cwd/Pi checks, and restoration of a previously active unit/runtime/worktree after failure.
2. Add `pi-webui.service.in` with rendered runtime, worktree, and exact Pi launcher tokens.
3. Extend the installer to validate all candidates before stopping the service; publish the runtime/unit; daemon-reload; restore prior enablement intent; and require exact health, loopback listener, durable cwd, Pi identity, and no unexpected network mode.
4. During migration, leave the accepted Serve route unchanged. Adopt an exact accepted runtime when safe, replace the temporary smoke cwd with the durable worktree, and restore the trial unit/runtime/cwd automatically on failed verification.
5. Verify deliberate stop is orphan-free and restart returns a fresh valid durable-worktree tab.
6. Commit: `feat: manage Pi Web UI service`.

## Task 4: Add Tailscale and rollback helpers

**Produces:** explicit privileged operations with strict ingress validation and reversible Web UI ownership.

1. Add tests for Noble WSL gating; official key/source/package commands; no remote shell execution; separate `check|install|up|serve|serve-off|uninstall` actions; exact Serve backend; Funnel rejection; and shared Serve/Funnel status semantics.
2. Implement `tailscale.sh`:
   - `check` is read-only;
   - `install` uses the official Noble key/source and explicit sudo operations, validating the downloaded key digest before publication;
   - `up` performs interactive authentication without storing keys;
   - `serve` preflights local health and configures only HTTPS 443 root to `http://127.0.0.1:31415`;
   - `serve-off` removes that route;
   - `uninstall` is explicit and refuses while Serve is active.
3. Implement `rollback.sh`: refuse while Serve remains active; cleanly disable/stop only a proven managed unit; verify no listener/scoped child; preserve state by default; gate runtime/worktree deletion behind explicit ownership and cleanliness checks.
4. Commit: `feat: manage Pi Web UI ingress and rollback`.

## Task 5: Add public targets and operations documentation

**Produces:** discoverable opt-in setup, checks, limitations, update ceremony, and rollback.

1. Add `ai-webui` and `ai-webui-check` Make targets without changing `ai` or global install orchestration.
2. Document the operator sequence, full-account-control trust model, Windows-host-vs-WSL URL behavior, managed landing worktree and project worktree selection, exact pins, update process, accepted limitations, Tailscale checkpoints, health checks, and rollback in `ai/pi/webui/README.md`.
3. Add concise links/instructions to `README.md` and `ai/README.md`.
4. Verify documentation commands against installed CLI help and scripts.
5. Commit: `docs: add Pi Web UI operations`.

## Task 6: Migrate, polish, and verify the live setup

**Produces:** permanent dotfiles-managed runtime/service/Serve with the accepted behavior.

1. Run tracked checks before migration; capture current unit/runtime/worktree/Serve state without sensitive content.
2. Run `make ai-webui`; verify service cwd changes from the disposable smoke worktree to the managed durable linked worktree while the exact Serve route remains intact.
3. Verify exact runtime/Pi versions, owner-only files, loopback-only listener, direct LAN failure, exact tailnet Serve route, no Funnel targets, permission configuration unchanged, and clean source/landing worktrees.
4. Exercise deliberate service stop/start and confirm orphan-free fresh-tab recovery. Recheck tailnet HTTPS and local loopback.
5. Run `bats tests/pi_webui.bats`, `bash bin/validate-pi-webui`, `make ai-webui-check`, `bash bin/validate-ai --verbose`, and the repository test target.
6. Run `polish-core --fix`, inspect any edits, rerun verification, and use `change-explainer` for the final write-up.
7. Obtain independent final code review, resolve all blocking findings, and commit fixes.

## Adaptation points

- If the installed npm or Tailscale CLI changes lock/Serve semantics, stop rather than weakening validation.
- If the durable worktree is dirty or foreign, preserve it and require operator resolution.
- If candidate health fails after service stop, restore the exact prior unit/runtime/worktree and active state before reporting failure.
- If the existing Serve route differs from the accepted single loopback proxy, do not overwrite it automatically.
- If a clean shutdown leaves managed children, rollback the service change and retain evidence.

## Explicit exclusions

- No macOS, non-WSL, non-Noble, or non-systemd service implementation.
- No change to normal `make ai` or `bin/install`.
- No Funnel, direct LAN bind, remote companion/PIN, optional voice/package-management features, `node-pty`, lifecycle scripts, or Firstp1ck self-update.
- No enforcement of project worktree selection inside Firstp1ck.
- No strict live-tab continuity across crashes/restarts.
- No deletion of trial evidence, Pi transcripts/settings, Tailscale identity, or unrelated machine-local state.
