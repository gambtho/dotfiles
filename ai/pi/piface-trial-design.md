# Piface machine-local trial design

## Status

Approved in conversation on 2026-09-02. This document specifies a machine-local evaluation of Piface before any persistent dotfiles integration or upstream contribution.

## Goal

Provide a browser-based control plane for persistent Pi sessions running inside WSL, reachable only from the operator's private single-user Tailscale tailnet. The trial must preserve the existing Pi installation and credentials, avoid exposing Piface directly to the LAN or public internet, and avoid changing the machine's default Python runtime.

## Decisions

- Run Piface inside Ubuntu 24.04 WSL, where Pi and the project worktrees already live.
- Install Tailscale inside WSL. Remote access is unavailable whenever WSL is shut down; no Windows wake-up or proxy machinery is in scope.
- Start Piface automatically whenever WSL's systemd user environment starts.
- Install the published base package only, pinned to `piface==0.0.4` in a uv-managed Python 3.12 tool environment.
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
- The trial uses a disposable linked worktree for its first session.

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

Install the pinned package without changing mise's default Python 3.14 runtime:

```bash
uv tool install --python 3.12 'piface==0.0.4'
```

The machine-local unit lives at `~/.config/systemd/user/piface.service` and has this intended shape:

```ini
[Unit]
Description=Piface remote interface for Pi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/mise exec -- %h/.local/bin/piface serve --host 127.0.0.1 --port 7832 --no-direnv --no-speech --no-tts
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
```

Before enabling the unit, validate it with `systemd-analyze --user verify`. Then run `systemctl --user daemon-reload` and `systemctl --user enable --now piface.service`. Logs are read through `journalctl --user -u piface.service`.

`/usr/bin/mise exec` supplies the active mise toolchain to Piface and its child processes. The trial must verify that `pi --version` resolves to the configured Earendil Pi installation rather than installing or selecting `@mariozechner/pi-coding-agent` separately.

## Evaluation procedure

The trial is accepted only after all of these checks pass:

1. `piface --version` or package metadata reports exactly `0.0.4`, and the tool environment uses Python 3.12.
2. The Piface service is active and restart-on-failure works.
3. The Piface process and child environment resolve Pi to the installed Earendil build (`pi --version` currently reports `0.84.4`).
4. Piface's health endpoint responds on `127.0.0.1:7832`.
5. Socket inspection shows no Piface listener on `0.0.0.0`, `::`, or the WSL LAN address.
6. Tailscale reports the WSL node online and Serve reports only a tailnet HTTPS proxy to `127.0.0.1:7832`.
7. The Serve URL works from a trusted tailnet device and is unavailable from a non-tailnet/LAN-only client.
8. Piface model discovery includes the configured GitHub Copilot models.
9. A session created in a disposable existing linked worktree can stream messages, steer/follow up, abort, display tool calls, answer extension permission dialogs, browse files, and render Git diffs.
10. Piface rejects or operational procedure prevents use of a primary-checkout path. Because version 0.0.4 does not enforce this in its UI, this remains a documented manual gate during evaluation.
11. Restarting `piface.service` restores a previously live non-ephemeral session and archived sessions remain readable.
12. `journalctl` and Piface state are inspected for credentials, tokens, or unexpectedly retained command payloads before the trial is accepted.
13. Stopping Piface makes the Serve URL fail closed at the backend; disabling the Serve route removes the tailnet endpoint.

Any Pi RPC incompatibility, missing model inventory, permission-dialog failure, unexpected LAN listener, credential disclosure, or primary-checkout mutation stops the rollout rather than being worked around silently.

## Rollback

Rollback preserves user data by default:

1. Disable and stop Piface: `systemctl --user disable --now piface.service`.
2. Remove the Tailscale Serve route.
3. Remove the machine-local unit and run `systemctl --user daemon-reload`.
4. Uninstall Piface with `uv tool uninstall piface`.
5. Leave `~/.local/share/piface/state.json`, Pi sessions, and worktrees intact unless the operator explicitly chooses to delete them.
6. Tailscale itself may remain installed for other use; removing the WSL tailnet node is a separate explicit action.

## Deferred work

### Dotfiles integration

If the evaluation succeeds, a separate reviewed change will:

- add explicit Piface and, if desired, Tailscale version ownership;
- add idempotent installation and machine-specific service publication;
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
