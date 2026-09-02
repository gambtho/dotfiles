# Firstp1ck Pi Web UI Trial Design

## Status

Approved replacement for the failed Piface 0.0.4 trial.

This remains a machine-local compatibility and security evaluation. Permanent
dotfiles integration follows immediately only if the trial passes its required
gates.

## Goal

Run Firstp1ck Pi Web UI as a persistent browser control plane for the existing
Earendil Pi installation inside WSL, expose it only through Tailscale Serve,
and verify that permission dialogs, reconnect recovery, worktree isolation,
and service lifecycle behave correctly before managing it from dotfiles.

## Why Piface was rejected

Piface 0.0.4 passed package, service, model-discovery, linked-worktree, and basic
RPC checks but failed the required permission-dialog gate.

The failure is confirmed in the published `v0.0.4` source at commit
`6172144f221b5f6e2240d9ca1bb7cc522607ef62`:

- the README advertises extension UI dialogs;
- the session frontend handles `extension_ui_request` with
  `TODO: show extension UI modal` and discards the event;
- no frontend path sends `extension_ui_response`;
- Pi therefore remains blocked on the pending permission selection;
- the permission system's RPC fallback invokes `ui.select` without an abort
  signal or timeout, so Pi's normal Abort command does not resolve that dialog;
- when the last Piface browser disconnects, Piface discards its per-session
  event queue, while reconnect replays messages but not the unanswered dialog.

The observed transcript ended with a Bash tool call and no tool result. Resetting
the page lost the prompt and subsequent commands received no response. No
Tailscale Serve route was configured, so the failed service was never exposed
to the tailnet.

Piface is therefore not eligible for permanent dotfiles integration in its
current form. Retain its evaluation record and dependency lock as evidence
until the replacement trial is accepted or rolled back.

## Selected replacement

Use `@firstpick/pi-package-webui` version `0.10.3`, evaluated from repository
commit `292ebdb0fc601c1089f26e8d616c7feb081b39fb` and npm integrity:

```text
sha512-46Hmgv/ccINvexRof3w7JzVoutrBcQ06OC2RiLh/aU1MAZvv7Uss6M0CgHkjb8fzzDaspNgihAbu+U0R0TGafQ==
```

The implementation, not only its README, addresses the Piface failure:

- tracks blocking `select`, `confirm`, `input`, and `editor` requests;
- persists pending requests in server-owned tab state;
- replays them to reconnecting browser clients;
- sends `extension_ui_response` back to Pi;
- cancels hidden pending requests when Abort is invoked;
- reports pending-request counts and blocked-tab state;
- includes focused tests for dialog routing, reconnect replay, cancellation,
  and raw response transport.

It also supplies the required multi-tab sessions, model/thinking controls,
files, Git status/diffs, uploads, workspaces, and mobile layout.

## Architecture

```text
Trusted tailnet browser
        |
        | tailnet-only HTTPS :443
        v
Tailscale Serve inside WSL
        |
        | http://127.0.0.1:31415
        v
Firstp1ck Pi Web UI systemd user service
        |
        | standalone launcher + durable RPC supervisor
        v
Exact existing Earendil pi executable --mode rpc
        |
        v
Existing linked Git worktrees and ~/.pi/agent state
```

Tailscale remains installed and authenticated from the Piface trial. The new
trial does not configure Serve until all loopback compatibility gates pass.
Funnel remains prohibited.

## Trial runtime

Create a dedicated machine-local npm project at:

```text
~/.local/share/pi-webui-runtime/
```

Its package declaration contains exactly one direct dependency:

```json
{
  "name": "pi-webui-runtime",
  "version": "0.0.0",
  "private": true,
  "dependencies": {
    "@firstpick/pi-package-webui": "0.10.3"
  }
}
```

Generate and retain `package-lock.json`. Validate before installation that:

- the root dependency is exactly `0.10.3`;
- the selected package's recorded integrity matches the approved npm value;
- every registry package entry has an HTTPS npm registry source and an
  integrity digest;
- no Git, file, link, workspace, or arbitrary HTTP dependency is present;
- no npm lifecycle script is executed during installation.

Install with `npm ci --ignore-scripts --omit=optional`. Omitting optional
packages excludes `node-pty`; Linux RPC chat, files, Git, and the permission UI
do not require it. Optional PTY/app-runner functionality is outside this trial.

Do not use `npm install -g`, `npx`, `pi install`, or Firstp1ck's optional-package
installer during the trial. The current Pi package inventory and settings must
remain unchanged.

## Exact Pi identity

The service must pass `--pi` with the exact existing Pi launcher resolved during
preflight. The expected current identity is:

```text
@earendil-works/pi-coding-agent 0.84.4
```

The expected current mise installation resolves through Node 26.5.0. Record the
launcher, real target, owning package name/version, and the actual child cwd.
Do not dump the child environment. An upgrade during evaluation invalidates the
identity gate and requires revalidation.

## Piface retirement during the trial

Before installing the replacement service:

1. preserve the Piface evaluation record and uv lock;
2. archive/close the stuck Piface session through its API if possible;
3. stop and disable `piface.service`;
4. verify no process listens on port 7832 and no Piface Pi child remains;
5. leave `~/.local/share/piface-runtime/` and its state in place for rollback
   evidence until final disposition.

Do not delete the shared smoke worktree. Reuse it for the replacement trial only
if it remains clean and is still listed by `git worktree list`.

## Service design

Create a machine-local unit at:

```text
~/.config/systemd/user/pi-webui.service
```

The intended command is equivalent to:

```text
/usr/bin/mise exec -- ~/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui \
  --host 127.0.0.1 \
  --port 31415 \
  --cwd /home/tng/.dotfiles/tmp/worktrees/piface-smoke \
  --pi <verified-exact-pi-launcher> \
  --no-remote-auth \
  --name pi-webui-smoke
```

The standalone launcher does not open a browser automatically. The unit uses an
owner-only umask, restart-on-failure, `NoNewPrivileges`, and `PrivateTmp`.

A normal `SIGTERM` intentionally leaves Firstp1ck's durable RPC supervisor and
Pi tabs running. The service must therefore use an `ExecStop` command that POSTs
to the loopback-only `/api/shutdown` endpoint. That endpoint shuts down the Web
UI and its managed RPC supervisor without preserving tabs. Verify no supervisor
or Pi child remains after a deliberate stop.

Validate the unit with `systemd-analyze --user verify` before enabling it.

## Security model

Treat the Web UI as full WSL-account control. It can:

- prompt and steer Pi;
- run direct browser-owned file and Git operations outside Pi permissions;
- edit Pi settings, tools, and skills through browser-native controls;
- install optional packages after an explicit browser action;
- expose its listener to `0.0.0.0` through the network-open endpoint;
- update or restart its own runtime through browser controls.

For the trial:

- bind only to `127.0.0.1:31415`;
- never use the Open-to-network control;
- never enable its optional Remote Web UI companion;
- never install optional features or apply updates from the browser;
- never use Funnel;
- create and use Pi tabs only in verified linked worktrees;
- use only non-sensitive prompts and files;
- verify listener confinement after every lifecycle or network-control test.

Tailscale Serve proxies from loopback, so tailnet clients appear local to the
application and can reach APIs the application labels localhost-only. This is
accepted only because the tailnet contains the user's trusted devices and the
Web UI is already treated as full account control. A compromised tailnet device
has the WSL user's authority. The direct-LAN prohibition remains operationally
binding and is verified from a non-tailnet LAN peer.

The Web UI has no server-side allowlist that prevents selecting a primary
checkout. Linked-worktree-only use is therefore an operator policy, not an
application guarantee. Primary-checkout sessions fail the trial.

## Persistence and data

Expected machine-local state includes:

- `~/.pi/webui/settings.json`;
- `~/.local/state/pi-webui/` supervisor and run-registry state;
- existing `~/.pi/agent/sessions/` JSONL transcripts and uploads;
- browser local/session storage for drafts and display state;
- `~/.local/share/pi-webui-runtime/` package declaration, lock, and install.

Use the same Pi agent directory and port across service restarts so the durable
supervisor can reconnect. Do not manually delete Web UI state while tabs are
active.

The evaluation record moves to:

```text
~/.local/share/pi-webui/evaluation-2026-09-02.md
```

It is owner-only and contains versions, hashes, paths, bounded metadata, gate
results, and deviations—but no credentials, transcript bodies, permission
payload contents, cookies, PINs, or auth tokens.

## Evaluation order

### Gate 1: package and identity

- npm package and lock integrity pass;
- package version is exactly `0.10.3`;
- no lifecycle scripts or optional package install run;
- exact Earendil Pi launcher/package/version is selected.

### Gate 2: service confinement

- service is enabled, active, and healthy;
- only `127.0.0.1:31415` listens;
- WSL LAN-address access fails;
- Piface remains stopped;
- no Serve/Funnel route exists.

### Gate 3: permission and recovery — first browser gate

Using the clean linked smoke worktree:

1. trigger the permission system with `printf "$HOME"`;
2. verify the browser renders all permission choices;
3. deny and verify the tool is blocked while the session recovers;
4. trigger another permission dialog and reload before answering;
5. verify the same pending dialog is replayed after reconnect;
6. trigger another permission dialog and use Abort;
7. verify the hidden request is cancelled and a later prompt receives a normal
   response;
8. verify no command executes without the selected decision.

Any hang, lost dialog, ineffective Abort, silent approval, or unrecoverable tab
fails the trial immediately.

### Gate 4: worktree and product behavior

- actual Pi child cwd is the linked smoke worktree;
- model discovery and GitHub Copilot operation succeed;
- streaming, steering, follow-up queue, and normal Abort work;
- files and Git diff remain rooted in the smoke worktree;
- direct browser file/Git operations are recognized as permission bypasses;
- session history and state survive browser reconnect and service restart;
- clean shutdown removes managed supervisor/Pi children.

### Gate 5: tailnet-only HTTPS

Only after Gates 1–4 pass:

```text
tailscale serve --bg --https=443 http://127.0.0.1:31415
```

Then verify:

- trusted tailnet browser control works over HTTPS;
- disconnecting the client from Tailscale removes access;
- direct WSL LAN access to port 31415 fails;
- Funnel is empty;
- listener remains loopback-only;
- the network-open and optional-package controls were not used.

### Gate 6: restart and rollback

- browser reconnect replay works;
- service restart reconnects intended managed state;
- `/api/shutdown` followed by service stop leaves no supervisor/Pi child;
- Serve removal makes the tailnet URL unavailable while loopback behavior is
  separately understood;
- rollback instructions preserve or explicitly delete each state category.

## Acceptance

The replacement trial succeeds only if every required gate passes, especially
permission deny, reconnect replay, Abort recovery, linked-worktree execution,
clean shutdown, and tailnet-only exposure.

On success, immediately design and implement permanent dotfiles ownership for:

- official Ubuntu Noble Tailscale repository bootstrap;
- the WSL `tailscale` package declaration;
- exact Firstp1ck version and integrity-locked npm runtime;
- systemd user service installation/reconciliation;
- runtime validation and installer tests;
- security and rollback documentation.

Permanent integration must not register Firstp1ck as a Pi package unless a
separate evaluation demonstrates that its extension resources are needed. The
standalone control plane is the default integration.

On failure, remove any Tailscale Serve route, disable and cleanly stop the Web
UI, retain the evaluation record, and ask whether to preserve or delete its
runtime/state. Tailscale itself remains independently useful and may still be
added to dotfiles with separate approval.

## Deferred work

- optional `node-pty` and app runners;
- voice, speech, and TTS companions;
- Remote Web UI LAN/PIN companion;
- optional-package installation and self-update controls;
- a server-side linked-worktree-only policy;
- upstream Piface fixes or worktree-selector contribution.
