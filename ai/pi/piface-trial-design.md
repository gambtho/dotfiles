# Piface machine-local trial design

## Status

Approved in conversation on 2026-09-02. This document specifies a machine-local evaluation of Piface before any persistent dotfiles integration or upstream contribution.

## Goal

Provide a browser-based control plane for persistent Pi sessions running inside WSL, reachable only from the operator's private single-user Tailscale tailnet. The trial must preserve the existing Pi installation and credentials, avoid exposing Piface directly to the LAN or public internet, and avoid changing the machine's default Python runtime.

## Decisions

- Run Piface inside Ubuntu 24.04 WSL, where Pi and the project worktrees already live.
- Install Tailscale inside WSL. Remote access is unavailable whenever WSL is shut down; no Windows wake-up or proxy machinery is in scope.
- Start Piface automatically whenever WSL's systemd user environment starts.
- Install the published base package only, pinned to `piface==0.0.4` in a uv-managed Python 3.12 project environment with a retained `uv.lock` containing the complete resolved dependency set and distribution hashes.
- Disable speech, text-to-speech, and direnv for the initial trial.
- Use Tailscale Serve, never Funnel, as the only remote ingress.
- Bind Piface itself to `127.0.0.1:7832`.
- Use only existing linked-worktree paths when creating browser sessions. Primary-checkout sessions are out of policy during the trial.
- Keep the trial machine-local. Apart from this design document, the trial does not add Piface or Tailscale installers, service baselines, or pins to the dotfiles repository.
- Evaluate audio later. TTS can be added from the published extra; speech waits for a separately reviewed dependency path after the quarantined PyPI dependency issue is resolved.
- After a successful trial, propose an upstream UI change that exposes Piface's existing worktree-backed session support.

## Architecture

```text
Trusted phone/laptop on the operator's tailnet
                    |
                    | tailnet-only HTTPS
                    v
          Tailscale Serve inside WSL
                    |
                    | http://127.0.0.1:7832
                    v
          Piface systemd user service
                    |
                    +-- ~/.local/share/piface/state.json
                    +-- pi --mode rpc child processes
                              |
                              +-- ~/.pi/agent configuration and auth
                              +-- existing linked worktrees only
```

Piface owns its RPC child processes and can restore previously live, non-ephemeral sessions after a Piface restart. It does not attach to already-running Pi TUI processes. WSL shutdown stops Piface, its child sessions, and the WSL Tailscale node.

## Security boundary

Piface is full remote control of the WSL user account, not a read-only session viewer:

- its filesystem APIs can inspect files available to the service user;
- it starts Pi with that user's Pi credentials and permission configuration;
- `!command` executes through Pi RPC;
- `!!command` executes directly in Piface and bypasses Pi's permission extension and worktree guard;
- Piface 0.0.4 has no application-level authentication.

The trial therefore depends on the confirmed single-user, trusted-device tailnet as its authentication boundary. A compromised tailnet device can control Piface with the WSL user's authority.

Defense-in-depth requirements:

- Piface listens only on loopback.
- Only Tailscale Serve publishes the service; Funnel is never enabled.
- Port 7832 must not listen on the WSL LAN address or `0.0.0.0`.
- The Piface unit receives no secrets through service-specific environment variables.
- The service uses `UMask=0077`, `NoNewPrivileges=true`, and a private temporary directory where compatible with Pi/Piface operation.
- Browser-created sessions target only paths already verified by `git worktree list` as linked worktrees.
- The trial uses a disposable linked worktree and non-sensitive prompts/files for its first session.
- Acceptance and rollback account for server-side Pi sessions/uploads and browser-side local/session storage, not only Piface's state file and journal.

Systemd sandboxing must not be represented as complete containment. Piface and its Pi children intentionally need broad user-level access to repositories, Git common directories, Pi session/auth files, build tools, and caches. More restrictive filesystem isolation is deferred until observed access requirements can be measured.

## Installation and service lifecycle

### Tailscale

Use Tailscale's official stable Ubuntu Noble repository rather than piping a remote installer into a shell. The one-time package installation and `tailscale up` authentication are interactive operator steps because they require root privileges and browser login.

After authentication, configure persistent tailnet-only HTTPS with the installed CLI's confirmed syntax, expected for current versions to be:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7832
```

`--bg` persists the Serve configuration across Tailscale restarts. Verify with `tailscale serve status --json`. Remove the route using the exact flags reported by the installed version, expected to be:

```bash
tailscale serve --bg --https=443 off
```

Do not run `tailscale funnel`.

### Piface

Create a dedicated machine-local uv project at `~/.local/share/piface-runtime/` without changing mise's default Python 3.14 runtime. Its `pyproject.toml` is:

```toml
[project]
name = "piface-runtime"
version = "0.0.0"
requires-python = ">=3.12,<3.13"
dependencies = ["piface==0.0.4"]

[tool.uv]
package = false
```

Resolve before installing, retain the complete lock, inspect that every package comes from the expected registry with recorded distribution hashes, and then sync without permitting lock changes:

```bash
uv lock --directory ~/.local/share/piface-runtime --python 3.12
uv sync --directory ~/.local/share/piface-runtime --locked --no-dev
```

The retained `pyproject.toml` and `uv.lock` are the machine-local trial installation record. Reinstallation must use `uv sync --locked`, not a fresh unconstrained `uv tool install` or `uvx` resolution. Record `uv tree --directory ~/.local/share/piface-runtime --locked` with the trial results.

The machine-local unit lives at `~/.config/systemd/user/piface.service` and has this intended shape:

```ini
[Unit]
Description=Piface remote interface for Pi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/mise exec -- %h/.local/share/piface-runtime/.venv/bin/piface serve --host 127.0.0.1 --port 7832 --no-direnv --no-speech --no-tts
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
```

Before enabling the unit, validate it with `systemd-analyze --user verify`. Then run `systemctl --user daemon-reload` and `systemctl --user enable --now piface.service`. Logs are read through `journalctl --user -u piface.service`.

`/usr/bin/mise exec` supplies the active mise toolchain to Piface and its child processes. A matching version string alone is insufficient proof of runtime identity. Before enabling the service, record the `mise exec` resolution of `pi`, resolve its symlinks, and read the owning npm package's name/version. After Piface creates the disposable trial session, inspect only the Pi child process's executable/cmdline and the `PI_CODING_AGENT_DIR` entry from `/proc/<pid>/environ` (or establish that it is unset and therefore defaults to `~/.pi/agent`). Do not dump the full child environment. The observed child must use the same Earendil CLI path/package and intended agent directory.

## Persistence and sensitive data

The evaluation intentionally creates durable data in more places than Piface's state file:

- `~/.local/share/piface/state.json` stores Piface session metadata and upload references;
- `~/.pi/agent/sessions/` stores Pi JSONL transcripts, tool results, and Piface uploads under session-local `uploads/_shared/` paths;
- the browser origin stores theme/skin settings, recent files, session snapshots, composer drafts, per-session scratch text, and view state in `localStorage` and `sessionStorage`.

Use non-sensitive prompts and files for the first trial. Acceptance inspects the permissions and expected contents of the server-side stores, samples the trial JSONL/journal for unintended credential or token retention, and inspects browser site storage for drafts/scratch/snapshots. It does not treat Pi transcripts as secret-free; they are expected to retain user prompts, tool results, and `!command` output. On a remote device, clearing browser site data for the Piface Tailscale origin is the supported complete client-side cleanup.

## Evaluation procedure

The trial is accepted only after all of these checks pass:

1. The retained `uv.lock` contains a complete pinned resolution with distribution hashes, `uv sync --locked` succeeds without changing it, package metadata reports exactly Piface `0.0.4`, and the runtime environment uses Python 3.12.
2. The Piface service is active and restart-on-failure works.
3. The preflight path/package record and the actual Piface-spawned Pi child cmdline identify the installed Earendil package, and the child uses the intended `~/.pi/agent` directory (explicitly or by verified default). `pi --version` currently reports `0.84.4`, but that string is supporting evidence only.
4. Piface's health endpoint responds on `127.0.0.1:7832`.
5. Socket inspection shows no Piface listener on `0.0.0.0`, `::`, or the WSL LAN address.
6. Tailscale reports the WSL node online and Serve reports only a tailnet HTTPS proxy to `127.0.0.1:7832`.
7. The Serve URL works from a trusted tailnet device and is unavailable from a non-tailnet/LAN-only client.
8. Piface model discovery includes the configured GitHub Copilot models.
9. A session created in a disposable existing linked worktree can stream messages, steer/follow up, abort, display tool calls, answer extension permission dialogs, browse files, and render Git diffs.
10. Piface rejects or operational procedure prevents use of a primary-checkout path. Because version 0.0.4 does not enforce this in its UI, this remains a documented manual gate during evaluation.
11. Restarting `piface.service` restores a previously live non-ephemeral session and archived sessions remain readable.
12. `journalctl`, Piface state, the disposable trial's Pi JSONL/upload directory, and browser site storage are inspected according to the persistence section before acceptance.
13. The trial records the expected transcript and browser-retention behavior and verifies owner-only permissions for machine-local runtime/state files where applicable.
14. Stopping Piface makes the Serve URL fail closed at the backend; disabling the Serve route removes the tailnet endpoint.

Any Pi RPC incompatibility, missing model inventory, permission-dialog failure, unexpected LAN listener, credential disclosure, or primary-checkout mutation stops the rollout rather than being worked around silently.

## Rollback

Rollback preserves user data by default:

1. Disable and stop Piface: `systemctl --user disable --now piface.service`.
2. Remove the Tailscale Serve route.
3. Remove the machine-local unit and run `systemctl --user daemon-reload`.
4. Remove `~/.local/share/piface-runtime/` only after preserving its `pyproject.toml` and `uv.lock` with the evaluation record if reproducibility is still needed.
5. By default, leave `~/.local/share/piface/state.json`, Pi sessions/uploads, browser site data, and worktrees intact. Full cleanup is a separate explicit action that deletes the disposable trial session/upload data, Piface state, and the Piface origin's browser site data after confirming nothing should be retained.
6. Tailscale itself may remain installed for other use; removing the WSL tailnet node is a separate explicit action.

## Deferred work

### Dotfiles integration

If the evaluation succeeds, a separate reviewed change will:

- add explicit Piface and, if desired, Tailscale version ownership, including the reviewed complete Python lock;
- add idempotent locked installation and machine-specific service publication;
- preserve mutable Piface state and authentication;
- add installer, service, rollback, and platform tests;
- document WSL lifecycle and the lack of application-level authentication.

### Audio

TTS may later be evaluated through the published `piface[tts]` extra. Speech/audio will not use the current PyPI dependency path while its upstream `lightning` dependency is quarantined. A source-based override requires a separate supply-chain review.

### Upstream worktree UI

Piface's backend already creates worktree-backed sessions when `shared` is false or omitted and the workspace config selects `git_worktree`. In commit `6172144f221b5f6e2240d9ca1bb7cc522607ef62`, the frontend instead hard-codes `DEFAULT_NEW_SESSION_SHARED = true` and does not expose a control, so normal browser creation always sends `shared: true`.

After evaluating the product, open an upstream issue to confirm desired UX, then propose:

- an explicit Shared / Git worktree selector in the new-session form;
- worktree mode as the recommended or default selection, subject to maintainer agreement;
- request-payload tests proving the selected mode controls `shared`;
- UI tests covering form reset and clone/new-session behavior;
- documentation that distinguishes primary directories from generated worktrees and explains cleanup.

No permanent fork is part of the accepted design.
