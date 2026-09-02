# Firstp1ck Pi Web UI Machine-Local Trial Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task.

**Goal:** Replace the failed Piface trial with a pinned Firstp1ck Pi Web UI 0.10.3 standalone service, prove permission-dialog and reconnect recovery locally, then expose it only through Tailscale Serve.

**Architecture:** An integrity-locked npm runtime starts Firstp1ck Pi Web UI on `127.0.0.1:31415` under a systemd user service. It launches the exact existing Earendil Pi CLI through its durable RPC supervisor in an already-verified linked worktree. Tailscale Serve is added only after local permission, reconnect, Abort, worktree, and shutdown gates pass.

**Tech Stack:** Node 26.5.0 through mise, npm package-lock v3, `@firstpick/pi-package-webui@0.10.3`, Earendil Pi 0.84.4, systemd user service, Tailscale 1.102.3

**Spec:** `ai/pi/pi-webui-trial-design.md`

## Global Constraints

- This plan is a machine-local trial. Do not modify the tracked dotfiles runtime/package/service configuration; permanent integration is a separate immediate follow-up after acceptance.
- Do not use `pi install`, `npm install -g`, `npx`, optional Firstp1ck companions, package-update controls, migration controls, voice/TTS, or `node-pty`.
- Install exactly `@firstpick/pi-package-webui@0.10.3` from npm with the approved package integrity and a retained complete `package-lock.json`.
- Execute no npm lifecycle scripts; install with `npm ci --ignore-scripts --omit=optional`.
- Bind only to `127.0.0.1:31415`; never use Firstp1ck's network-open control, `0.0.0.0`, direct LAN exposure, or Tailscale Funnel.
- Pass the exact current Earendil Pi launcher with `--pi`; stop if package identity or version differs from `@earendil-works/pi-coding-agent 0.84.4`.
- Use only the verified linked worktree `/home/tng/.dotfiles/tmp/worktrees/piface-smoke`; never create a session in the primary checkout.
- Treat the Web UI and every trusted tailnet client as full WSL-account control. Browser-owned file, Git, package, update, and network actions bypass Pi permissions.
- Use only non-sensitive prompts and files. Do not print full environments, transcript bodies, auth data, browser cookies/storage values, supervisor tokens, remote PINs, or permission payload bodies.
- Stop on missing/ineffective permission UI, silent approval, lost dialog, ineffective Abort, unrecoverable reconnect, wrong cwd/Pi identity, unexpected listener, direct LAN access, Funnel, or credential disclosure.
- Machine-local tasks produce no Git commits. Commit only this plan/spec branch.

## Machine-Local Files

- Preserve: `~/.local/share/piface-runtime/`, `~/.local/share/piface/`, and the failed Piface evidence
- Create: `~/.local/share/pi-webui-runtime/package.json`
- Create: `~/.local/share/pi-webui-runtime/package-lock.json`
- Create: `~/.local/share/pi-webui-runtime/node_modules/`
- Create: `~/.config/systemd/user/pi-webui.service`
- Create: `~/.local/share/pi-webui/evaluation-2026-09-02.md`
- Runtime state: `~/.pi/webui/settings.json`, `~/.local/state/pi-webui/`, and `~/.pi/agent/sessions/`
- Reuse: `/home/tng/.dotfiles/tmp/worktrees/piface-smoke`

---

### Task 1: Retire the failed Piface service without deleting evidence

**Produces:** no Piface listener/child; disabled service; clean retained smoke worktree and evaluation artifacts

- [ ] **Step 1: Capture bounded failed-state metadata**

Run:

```bash
curl --fail --silent http://127.0.0.1:7832/api/sessions \
  | jq '[.[] | {piface_id, session_name, status, working_dir, session_file}]'
systemctl --user is-enabled piface.service
systemctl --user is-active piface.service
ss -ltnp '( sport = :7832 )'
git -C /home/tng/.dotfiles/tmp/worktrees/piface-smoke status --short --branch
```

Expected: one stuck live `piface-smoke` session, active/enabled Piface, loopback-only listener, and clean smoke worktree. Do not print transcript content.

- [ ] **Step 2: Close the stuck Piface session through its API**

Derive the session ID from the local API and issue the documented kill request:

```bash
piface_id=$(curl --fail --silent http://127.0.0.1:7832/api/sessions \
  | jq -er '.[] | select(.session_name == "piface-smoke") | .piface_id')
curl --fail --silent --show-error -X POST \
  "http://127.0.0.1:7832/api/sessions/$piface_id/kill" | jq .
```

Expected: session status becomes closed and the smoke-worktree Pi child exits. If the API cannot close it, stop for diagnosis rather than killing unrelated processes.

- [ ] **Step 3: Stop and disable the Piface service**

Run:

```bash
systemctl --user disable --now piface.service
! systemctl --user is-active --quiet piface.service
! systemctl --user is-enabled --quiet piface.service
! ss -ltn '( sport = :7832 )' | tail -n +2 | grep -q .
```

Expected: no listener on 7832 and no Pi child with cwd at the smoke worktree. Preserve the unit, runtime, lock, state, transcript, and evaluation record for final disposition.

- [ ] **Step 4: Initialize the replacement evaluation record**

Run:

```bash
install -d -m 0700 ~/.local/share/pi-webui
install -m 0600 /dev/null ~/.local/share/pi-webui/evaluation-2026-09-02.md
```

Record the Piface failure classification, retained evidence paths, clean worktree result, and Piface disabled/stopped result without prompt or permission payload contents.

---

### Task 2: Build and audit the integrity-locked npm runtime

**Produces:** exact Firstp1ck 0.10.3 installation under `~/.local/share/pi-webui-runtime/` with retained lock and no lifecycle/optional install

- [ ] **Step 1: Verify prerequisites and absence**

Run:

```bash
mise exec -- node --version
mise exec -- npm --version
test ! -e ~/.local/share/pi-webui-runtime
```

Expected: Node is 26.5.0, npm is available, and no replacement runtime exists. Stop rather than overwrite an unknown directory.

- [ ] **Step 2: Create the exact package declaration**

Create `~/.local/share/pi-webui-runtime/package.json` exactly:

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

Set the runtime directory mode 0700 and package file mode 0600.

- [ ] **Step 3: Resolve the lock without installing or running scripts**

Run:

```bash
mise exec -- npm install \
  --prefix ~/.local/share/pi-webui-runtime \
  --package-lock-only \
  --ignore-scripts \
  --omit=optional \
  --save-exact

test ! -e ~/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui
```

Expected: lockfile created, executable not installed.

- [ ] **Step 4: Validate the complete lock and approved package integrity**

Run:

```bash
LOCK=~/.local/share/pi-webui-runtime/package-lock.json mise exec -- node - <<'JS'
const fs = require('node:fs');
const lock = JSON.parse(fs.readFileSync(process.env.LOCK, 'utf8'));
const expectedIntegrity = 'sha512-46Hmgv/ccINvexRof3w7JzVoutrBcQ06OC2RiLh/aU1MAZvv7Uss6M0CgHkjb8fzzDaspNgihAbu+U0R0TGafQ==';
if (lock.lockfileVersion !== 3) throw new Error(`unexpected lockfileVersion ${lock.lockfileVersion}`);
if (lock.packages?.['']?.dependencies?.['@firstpick/pi-package-webui'] !== '0.10.3') {
  throw new Error('root dependency is not exact 0.10.3');
}
const selected = lock.packages?.['node_modules/@firstpick/pi-package-webui'];
if (selected?.version !== '0.10.3' || selected?.integrity !== expectedIntegrity) {
  throw new Error('Firstp1ck version/integrity mismatch');
}
for (const [path, entry] of Object.entries(lock.packages || {})) {
  if (path === '') continue;
  if (entry.link) throw new Error(`link dependency: ${path}`);
  if (!String(entry.resolved || '').startsWith('https://registry.npmjs.org/')) {
    throw new Error(`non-registry dependency: ${path}: ${entry.resolved}`);
  }
  if (!String(entry.integrity || '').startsWith('sha512-')) {
    throw new Error(`missing SHA-512 integrity: ${path}`);
  }
}
console.log(`validated ${Object.keys(lock.packages).length - 1} registry packages`);
JS
chmod 0600 ~/.local/share/pi-webui-runtime/package-lock.json
sha256sum ~/.local/share/pi-webui-runtime/package-lock.json
```

Expected: every non-root package is an integrity-locked npm registry artifact and selected package integrity matches the approved value.

- [ ] **Step 5: Install exactly from the lock with scripts and optionals disabled**

Run and compare the lock hash before/after:

```bash
sha256sum ~/.local/share/pi-webui-runtime/package-lock.json
mise exec -- npm ci \
  --prefix ~/.local/share/pi-webui-runtime \
  --ignore-scripts \
  --omit=optional
sha256sum ~/.local/share/pi-webui-runtime/package-lock.json
```

Expected: hashes identical; `node-pty` absent; no lifecycle scripts executed.

- [ ] **Step 6: Verify installed artifact identity and focused upstream tests**

Run:

```bash
mise exec -- npm ls \
  --prefix ~/.local/share/pi-webui-runtime \
  --omit=optional \
  --depth=0

mise exec -- node - <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const root = path.join(process.env.HOME, '.local/share/pi-webui-runtime');
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'node_modules/@firstpick/pi-package-webui/package.json')));
if (pkg.name !== '@firstpick/pi-package-webui' || pkg.version !== '0.10.3') throw new Error('identity mismatch');
if (!fs.existsSync(path.join(root, 'node_modules/.bin/pi-webui'))) throw new Error('launcher missing');
if (fs.existsSync(path.join(root, 'node_modules/node-pty'))) throw new Error('optional node-pty installed');
console.log(`${pkg.name}@${pkg.version}`);
JS

cd ~/.local/share/pi-webui-runtime/node_modules/@firstpick/pi-package-webui
mise exec -- node tests/rpc-supervisor-protocol.test.mjs
mise exec -- node tests/questionnaire-dialog.test.mjs
mise exec -- node tests/mobile-static.test.mjs
```

Expected: direct dependency exact; focused transport/dialog/reconnect/Abort static tests pass with pristine output. Run `npm audit --prefix ~/.local/share/pi-webui-runtime --omit=optional` and stop on a production vulnerability before service creation.

---

### Task 3: Install and verify the loopback-only Web UI service

**Produces:** enabled healthy `pi-webui.service`, exact Pi child in smoke worktree, no ingress route

- [ ] **Step 1: Reverify the smoke worktree and exact Pi identity**

Run:

```bash
git -C /home/tng/.dotfiles/tmp/worktrees/piface-smoke status --short --branch
git -C /home/tng/.dotfiles/tmp/worktrees/piface-smoke rev-parse --git-dir
git -C /home/tng/.dotfiles/tmp/worktrees/piface-smoke rev-parse --git-common-dir
mise exec -- pi --version
readlink -f /home/tng/.local/share/mise/installs/node/26.5.0/bin/pi
```

Walk upward from the resolved target and assert the owning package is `@earendil-works/pi-coding-agent` version `0.84.4`. Stop on dirty worktree, primary-checkout identity, or Pi mismatch.

- [ ] **Step 2: Verify no collision**

Run:

```bash
test ! -e ~/.config/systemd/user/pi-webui.service
! systemctl --user is-active --quiet pi-webui.service
! ss -ltn '( sport = :31415 )' | tail -n +2 | grep -q .
tailscale serve status --json 2>/dev/null | jq .
tailscale funnel status --json 2>/dev/null | jq .
```

Expected: no unit/listener and empty Serve/Funnel.

- [ ] **Step 3: Create the unit**

Write `~/.config/systemd/user/pi-webui.service`:

```ini
[Unit]
Description=Firstp1ck Pi Web UI remote interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/mise exec -- %h/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui --host 127.0.0.1 --port 31415 --cwd /home/tng/.dotfiles/tmp/worktrees/piface-smoke --pi %h/.local/share/mise/installs/node/26.5.0/bin/pi --no-remote-auth --name pi-webui-smoke
ExecStop=/usr/bin/curl --fail --silent --show-error -X POST http://127.0.0.1:31415/api/shutdown
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
```

Set mode 0600 and validate with `systemd-analyze --user verify` before loading.

- [ ] **Step 4: Enable/start and verify health**

Run:

```bash
systemctl --user daemon-reload
systemctl --user enable --now pi-webui.service
systemctl --user is-enabled pi-webui.service
systemctl --user is-active pi-webui.service
curl --retry 20 --retry-delay 1 --retry-connrefused \
  --fail --silent http://127.0.0.1:31415/api/health \
  | jq -e '.ok == true and .webuiVersion == "0.10.3" and .piVersion == "0.84.4"'
```

Expected: service enabled/active and health identity exact.

- [ ] **Step 5: Verify listener, tab cwd, and child identity**

Run bounded status checks:

```bash
ss -ltnp '( sport = :31415 )'
curl --fail --silent 'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0' \
  | jq '{ok, data: {webuiVersion: .data.webuiVersion, piVersion: .data.piVersion, network: .data.network, tabs: [.data.tabs[] | {id,title,cwd,running,pid,command}]}}'
```

Expected: only `127.0.0.1:31415`; initial tab cwd is the smoke worktree; child is running with the explicit Pi launcher. Assign the status-reported child PID to `pi_pid`, verify `/proc/$pi_pid/cwd`, and internally resolve its selected Pi path without dumping environment.

- [ ] **Step 6: Verify LAN confinement and clean startup logs**

Request the WSL eth0 IPv4 at port 31415 and expect failure. Inspect at most 150 journal lines. Stop on direct LAN success, missing Pi, unexpected migration/package install, credential content, or startup error.

---

### Task 4: Prove permission-dialog, reconnect, Abort, and worktree behavior

**Produces:** browser-observed compatibility evidence for the exact Piface failure path

- [ ] **Step 1: Establish baseline UI and cwd**

Open `http://127.0.0.1:31415`. Confirm the initial tab is `pi-webui-smoke`, model `github-copilot/gpt-5.6-sol` is selectable, and cwd is `/home/tng/.dotfiles/tmp/worktrees/piface-smoke`.

- [ ] **Step 2: Test deny and normal recovery**

Ask Pi to use Bash for exactly `printf "$HOME"`. Confirm the permission dialog shows Approve, approve-for-session, Deny, and deny-with-reason choices. Choose Deny. Confirm the browser sends the matching `extension_ui_response`, the Bash tool is blocked, and a later harmless prompt receives a response.

- [ ] **Step 3: Test pending-dialog reconnect replay**

Trigger the same permission dialog, do not answer it, and reload the browser. Confirm the same pending dialog is restored and clearly marked pending/recovered. Deny it and confirm the session answers a later harmless prompt.

- [ ] **Step 4: Test Abort cancellation of a hidden pending dialog**

Trigger the same permission dialog again. While it is pending, invoke the Web UI Abort control using its required hold gesture. Confirm the dialog closes/cancels, the tool does not execute, the tab returns idle, and a later harmless prompt receives a normal response.

- [ ] **Step 5: Test normal streaming controls**

Verify streaming output, steering/follow-up ordering, queue visibility, and Abort of a harmless long model response. No test may create primary-checkout changes.

- [ ] **Step 6: Test files and Git diff in the worktree**

Ask Pi to create `pi-webui-smoke.txt` containing `non-sensitive pi webui trial`. Confirm Files and Git/Diff show it under the smoke worktree. Do not use browser commit/push/update/package/network controls. Remove the test file through a reviewed worktree operation and verify clean status.

- [ ] **Step 7: Verify bounded server evidence**

Inspect status/event metadata and transcript structure only. Confirm permission requests resolve/cancel, no Bash result exists for denied/cancelled commands, subsequent prompts complete, session JSONL is mode 0600, and no secret values were logged. Append pass/fail observations to the evaluation record.

Any failure in Steps 2–4 stops the replacement trial and prevents Tailscale Serve configuration.

---

### Task 5: Verify lifecycle and clean shutdown semantics

**Produces:** evidence that browser/service reconnect works and deliberate stop removes supervisor/Pi children

- [ ] **Step 1: Record non-secret tab/supervisor identifiers**

Use `/api/webui-status?detailed=1&events=0` to record tab ID, cwd, session-file path, Web UI PID, Pi PID, and supervisor running status. Do not record supervisor/recovery tokens.

- [ ] **Step 2: Restart only the service and verify reconnection**

Run `systemctl --user restart pi-webui.service`, wait for health, and verify the intended tab/session/cwd reconnects according to the documented durable-supervisor behavior. Browser history must replay and a new prompt must work.

- [ ] **Step 3: Exercise deliberate clean stop**

Capture the current Web UI, supervisor, and Pi PIDs. Run:

```bash
systemctl --user stop pi-webui.service
! systemctl --user is-active --quiet pi-webui.service
```

Verify `ExecStop` called `/api/shutdown`, port 31415 closed, and all captured supervisor/Pi child PIDs exited. Any orphaned managed process fails the gate.

- [ ] **Step 4: Start cleanly and verify no stale blocker**

Start the service, wait for health, open the browser, and confirm no stale permission dialog or unrecoverable busy state remains. Verify the smoke worktree is clean and only loopback listens.

- [ ] **Step 5: Inspect persistence metadata and modes**

Inspect owner/mode/path metadata for `~/.pi/webui/settings.json`, `~/.local/state/pi-webui/`, runtime declaration/lock, unit, evaluation record, and the smoke session JSONL. Inspect browser storage key names and clear only non-sensitive smoke drafts/snapshots after recording categories. Do not print stored values.

---

### Task 6: Publish through tailnet-only HTTPS and decide acceptance

**Produces:** accepted tailnet-only trial or complete rollback, followed by permanent-dotfiles design work

- [ ] **Step 1: Reconfirm all local gates and empty ingress**

Require Tasks 1–5 reviews clean. Verify health, loopback-only listener, failed WSL LAN request, clean smoke worktree, empty Serve status, and empty Funnel status.

- [ ] **Step 2: Configure exact Serve route**

Confirm installed syntax with `tailscale serve --help`, then run:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:31415
```

Verify exactly one HTTPS handler proxies to loopback 31415 and Funnel remains empty.

- [ ] **Step 3: Test from a trusted tailnet client**

From the trusted phone/laptop, open the concrete HTTPS URL, load the existing smoke tab, send a non-sensitive prompt, answer a permission dialog with Deny, reload/replay a pending dialog, and Abort a pending dialog. Disconnect the client from Tailscale and verify loss of access, then reconnect.

- [ ] **Step 4: Reconfirm no direct LAN exposure or network rebind**

From a LAN peer without Tailscale, request the WSL LAN IPv4 on port 31415 and expect failure. On WSL, confirm only `127.0.0.1:31415` listens. Confirm no network-open action occurred and Funnel is empty.

- [ ] **Step 5: Exercise Serve removal/restoration**

Remove the route with installed supported syntax, expected:

```bash
tailscale serve --bg --https=443 off
```

Confirm remote URL unavailable while loopback remains healthy, then restore the exact route and reverify Funnel empty.

- [ ] **Step 6: Present explicit acceptance decision**

Present pass/fail evidence for package integrity, exact Pi identity, service confinement, permission deny, dialog replay, Abort recovery, files/diff worktree scope, restart, clean shutdown, and tailnet/LAN boundaries. Ask whether to keep or roll back; do not infer acceptance.

- [ ] **Step 7a: On acceptance**

Leave `pi-webui.service` enabled and Serve active. Keep Piface disabled. Preserve both evaluation records until permanent dotfiles integration lands. Immediately begin the separately reviewed dotfiles design/plan for Tailscale repository bootstrap, WSL package declaration, locked runtime, service reconciliation, tests, docs, and rollback.

- [ ] **Step 7b: On rollback**

Remove Serve first. POST `/api/shutdown`, disable/stop `pi-webui.service`, verify no managed processes/listener, and preserve runtime/state/evidence unless the operator separately confirms exact deletion paths. Never wildcard-delete Pi sessions or unrelated browser/Pi state.
