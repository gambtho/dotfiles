# Piface Machine-Local Trial Implementation Plan

> **SUPERSEDED — DO NOT EXECUTE.** Piface failed the permission-dialog acceptance gate and was replaced by the supported Firstp1ck setup in `ai/pi/webui/README.md`. This document is retained only as historical evaluation evidence.

> **Historical instructions:** The unchecked tasks and commands below describe the retired trial and are not an active operator workflow.

**Goal:** Install and evaluate a pinned Piface 0.0.4 service inside WSL, exposed only through tailnet-only Tailscale Serve and used only with an existing disposable linked worktree.

**Architecture:** A system Tailscale daemon inside Ubuntu WSL provides tailnet identity and HTTPS Serve ingress to Piface on `127.0.0.1:7832`. A systemd user service runs a hash-locked Python 3.12 Piface environment through `mise exec`, and Piface owns Earendil Pi RPC child processes using the existing `~/.pi/agent` configuration.

**Tech Stack:** Ubuntu 24.04 WSL2, Tailscale stable packages and Serve, systemd user services, uv/Python 3.12, Piface 0.0.4, Earendil Pi 0.84.4 RPC mode, Git linked worktrees

**Spec:** `ai/pi/piface-trial-design.md`

## Global Constraints

- The trial is machine-local: do not add runtime installers, service units, dependency locks, or package pins to the dotfiles repository.
- Use Piface exactly `0.0.4` under Python `>=3.12,<3.13`; retain and install from a complete `uv.lock` with distribution hashes.
- Bind Piface only to `127.0.0.1:7832`.
- Use Tailscale Serve only; never enable Funnel or expose Piface on `0.0.0.0`, `::`, or the WSL LAN address.
- Disable Piface speech, TTS, and direnv for the trial.
- Create Piface sessions only in paths verified by `git worktree list` as linked worktrees; never use a primary checkout.
- Use only non-sensitive prompts and files during the initial smoke test.
- Do not dump full process environments, Pi auth, or session contents into terminal logs. Inspect only named metadata and explicitly selected non-sensitive trial records.
- Stop on Pi RPC incompatibility, empty GitHub Copilot model inventory, permission-dialog failure, unexpected listener exposure, credential disclosure, or primary-checkout mutation.
- Commands requiring `sudo` and browser-based Tailscale authentication are explicit operator checkpoints; the agent must not bypass Pi's privilege-escalation deny.
- Machine-local operational tasks produce no Git commits. Commit only changes to this plan/spec branch.

## Machine-Local Files

- Create: `~/.local/share/piface-runtime/pyproject.toml` — direct runtime requirement and Python range
- Create: `~/.local/share/piface-runtime/uv.lock` — complete resolved Python dependency graph and hashes
- Create: `~/.local/share/piface-runtime/.venv/` — uv-synchronized Piface runtime
- Create: `~/.config/systemd/user/piface.service` — loopback-only Piface user service
- Create: `~/.local/share/piface/evaluation-2026-09-02.md` — command/result record with no secrets
- Existing mutable state: `~/.local/share/piface/state.json`
- Existing Pi state: `~/.pi/agent/` and project-scoped session directories below `~/.pi/agent/sessions/`
- Temporary linked worktree: `/home/tng/.dotfiles/tmp/worktrees/piface-smoke`

---

### Task 1: Establish Tailscale inside WSL

**Files:**
- Create as root: `/usr/share/keyrings/tailscale-archive-keyring.gpg`
- Create as root: `/etc/apt/sources.list.d/tailscale.list`
- Modify as root: system package database and `tailscaled.service` enablement
- Create: Tailscale node state under the package-managed default location

**Interfaces:**
- Consumes: Ubuntu 24.04 Noble, working WSL systemd, the operator's private tailnet
- Produces: an authenticated WSL Tailscale node and working `tailscale`/`tailscaled`, with no Serve or Funnel route yet

- [ ] **Step 1: Confirm the precondition and record the absence/current state**

Run without privilege:

```bash
cat /etc/os-release | grep -E '^(ID|VERSION_ID|VERSION_CODENAME)='
command -v tailscale || true
systemctl is-active tailscaled.service || true
```

Expected before first installation: Ubuntu reports `ID=ubuntu`, `VERSION_ID="24.04"`, and `VERSION_CODENAME=noble`; `tailscale` is absent and `tailscaled.service` is inactive or unknown.

- [ ] **Step 2: Ask the operator to install the official Noble package**

The operator, not the agent, runs these commands after reviewing the two `pkgs.tailscale.com` URLs:

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt-get update
sudo apt-get install tailscale
```

Expected: package installation completes without adding an installer script or piping shell code to a privileged shell.

- [ ] **Step 3: Verify package and daemon installation**

Run:

```bash
command -v tailscale
tailscale version
systemctl is-enabled tailscaled.service
systemctl is-active tailscaled.service
```

Expected: CLI exists; system service is enabled and active. If inactive, the operator runs `sudo systemctl enable --now tailscaled.service`, then repeat this step.

- [ ] **Step 4: Ask the operator to authenticate the WSL node**

The operator runs:

```bash
sudo tailscale up
```

Expected: Tailscale prints a login URL; the operator authenticates it to the confirmed single-user tailnet. Do not place an auth key in shell history or the plan.

- [ ] **Step 5: Verify authenticated state and absence of public ingress**

Run:

```bash
tailscale status --json \
  | jq '{BackendState, Self: {HostName: .Self.HostName, DNSName: .Self.DNSName, Online: .Self.Online, TailscaleIPs: .Self.TailscaleIPs}}'
tailscale serve status --json 2>/dev/null || true
tailscale funnel status --json 2>/dev/null || true
```

Expected: `BackendState` is `Running`, `Self.Online` is true, and no Piface Serve or Funnel route exists.

- [ ] **Step 6: Start the machine-local evaluation record**

Create `~/.local/share/piface/evaluation-2026-09-02.md` with owner-only permissions and record only the Tailscale version, WSL node DNS name, online result, and that Funnel is disabled:

```bash
install -d -m 0700 ~/.local/share/piface
install -m 0600 /dev/null ~/.local/share/piface/evaluation-2026-09-02.md
```

Do not record Tailscale node keys, auth URLs, cookies, or Pi credentials.

---

### Task 2: Build the hash-locked Piface runtime

**Files:**
- Create: `~/.local/share/piface-runtime/pyproject.toml`
- Create: `~/.local/share/piface-runtime/uv.lock`
- Create: `~/.local/share/piface-runtime/.venv/`
- Modify: `~/.local/share/piface/evaluation-2026-09-02.md`

**Interfaces:**
- Consumes: `uv 0.11.3`, a uv-managed Python 3.12 interpreter, PyPI package `piface==0.0.4`
- Produces: `%h/.local/share/piface-runtime/.venv/bin/piface` and an inspected immutable dependency lock

- [ ] **Step 1: Verify the runtime does not already exist**

Run:

```bash
test ! -e ~/.local/share/piface-runtime/pyproject.toml
test ! -e ~/.local/share/piface-runtime/uv.lock
test ! -e ~/.local/share/piface-runtime/.venv/bin/piface
```

Expected: all commands succeed. If any file exists, stop and inspect it rather than overwriting an unknown installation.

- [ ] **Step 2: Create the runtime project declaration**

Write `~/.local/share/piface-runtime/pyproject.toml` exactly:

```toml
[project]
name = "piface-runtime"
version = "0.0.0"
requires-python = ">=3.12,<3.13"
dependencies = ["piface==0.0.4"]

[tool.uv]
package = false
```

Set the directory and file owner-only:

```bash
chmod 0700 ~/.local/share/piface-runtime
chmod 0600 ~/.local/share/piface-runtime/pyproject.toml
```

- [ ] **Step 3: Resolve without installing**

Run:

```bash
uv lock --directory ~/.local/share/piface-runtime --python 3.12
```

Expected: `uv.lock` is created and `.venv/` is still absent.

- [ ] **Step 4: Validate the complete lock before installation**

Run this bounded structural check:

```bash
python3 - <<'PY'
from pathlib import Path
import tomllib

lock_path = Path.home() / ".local/share/piface-runtime/uv.lock"
lock = tomllib.loads(lock_path.read_text())
packages = lock.get("package", [])
assert packages, "lock has no packages"
assert any(p.get("name") == "piface" and p.get("version") == "0.0.4" for p in packages)
for package in packages:
    if package.get("name") == "piface-runtime":
        continue
    source = package.get("source", {})
    assert "registry" in source, f"non-registry source: {package.get('name')}: {source}"
    artifacts = []
    if isinstance(package.get("sdist"), dict):
        artifacts.append(package["sdist"])
    artifacts.extend(package.get("wheels", []))
    assert artifacts, f"no locked artifacts: {package.get('name')}"
    assert all(str(a.get("hash", "")).startswith("sha256:") for a in artifacts), (
        f"missing hash: {package.get('name')}"
    )
print(f"validated {len(packages)} locked packages")
PY
chmod 0600 ~/.local/share/piface-runtime/uv.lock
sha256sum ~/.local/share/piface-runtime/uv.lock
```

Expected: only the local virtual root lacks a registry artifact; every resolved dependency has SHA-256 distribution hashes. Record the lock SHA-256 in the evaluation record.

- [ ] **Step 5: Synchronize exactly from the lock**

Run:

```bash
before=$(sha256sum ~/.local/share/piface-runtime/uv.lock)
uv sync --directory ~/.local/share/piface-runtime --locked --no-dev

after=$(sha256sum ~/.local/share/piface-runtime/uv.lock)
test "$before" = "$after"
```

Expected: sync succeeds and does not modify `uv.lock`.

- [ ] **Step 6: Verify runtime identity and packaged frontend**

Run:

```bash
~/.local/share/piface-runtime/.venv/bin/python - <<'PY'
from importlib.metadata import distribution, version
from pathlib import Path
import piface

assert version("piface") == "0.0.4"
assert tuple(map(int, __import__("platform").python_version_tuple()[:2])) == (3, 12)
static = Path(piface.__file__).parent / "static" / "index.html"
assert static.is_file(), f"published frontend missing: {static}"
dist = distribution("piface")
print(f"piface={dist.version}")
print(f"python={__import__('platform').python_version()}")
print(f"frontend={static}")
PY
uv tree --directory ~/.local/share/piface-runtime --locked
```

Expected: Piface is 0.0.4, Python is 3.12.x, the built frontend exists, and `uv tree` succeeds without changing the lock. Append the package/Python versions and dependency tree to the evaluation record.

---

### Task 3: Install the loopback-only Piface user service

**Files:**
- Create: `~/.config/systemd/user/piface.service`
- Modify: systemd user-manager state
- Modify: `~/.local/share/piface/evaluation-2026-09-02.md`

**Interfaces:**
- Consumes: locked Piface executable from Task 2 and `/usr/bin/mise`
- Produces: an automatically enabled Piface service listening only on `127.0.0.1:7832`

- [ ] **Step 1: Verify no listener or service collision**

Run:

```bash
test ! -e ~/.config/systemd/user/piface.service
! systemctl --user is-active --quiet piface.service
! ss -ltn '( sport = :7832 )' | tail -n +2 | grep -q .
```

Expected: no existing unit, active service, or listener. Stop on collision and identify the owner.

- [ ] **Step 2: Record the intended Pi resolution before service creation**

Run:

```bash
mise exec -- pi --version
pi_cli=$(mise exec -- bash -lc 'readlink -f "$(command -v pi)"')
printf '%s\n' "$pi_cli"
```

Then identify the owning package from the resolved CLI path without reading `auth.json`:

```bash
pi_cli=$(mise exec -- bash -lc 'readlink -f "$(command -v pi)"')
PI_CLI_PATH="$pi_cli" mise exec -- node - <<'JS'
const fs = require('node:fs');
const path = require('node:path');
let current = fs.realpathSync(process.env.PI_CLI_PATH);
current = fs.statSync(current).isDirectory() ? current : path.dirname(current);
while (current !== path.dirname(current)) {
  const candidate = path.join(current, 'package.json');
  if (fs.existsSync(candidate)) {
    const pkg = JSON.parse(fs.readFileSync(candidate, 'utf8'));
    if (pkg.name?.includes('pi-coding-agent')) {
      console.log(JSON.stringify({path: candidate, name: pkg.name, version: pkg.version}));
      process.exit(0);
    }
  }
  current = path.dirname(current);
}
throw new Error('owning pi-coding-agent package.json not found');
JS
```

Expected package name: `@earendil-works/pi-coding-agent`; expected current version: `0.84.4`. Record path, package name, and version.

- [ ] **Step 3: Write the service unit exactly**

Create `~/.config/systemd/user/piface.service`:

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

Set mode `0600`.

- [ ] **Step 4: Validate the unit before loading it**

Run:

```bash
systemd-analyze --user verify ~/.config/systemd/user/piface.service
```

Expected: exit 0 with no diagnostics.

- [ ] **Step 5: Enable and start Piface**

Run:

```bash
systemctl --user daemon-reload
systemctl --user enable --now piface.service
systemctl --user is-enabled piface.service
systemctl --user is-active piface.service
```

Expected: enabled and active. On failure, inspect `journalctl --user -u piface.service -n 100 --no-pager`, stop, and do not configure Serve.

- [ ] **Step 6: Verify health and listener confinement**

Run:

```bash
curl --fail --silent --show-error http://127.0.0.1:7832/api/health | jq -e '.status == "ok"'
ss -ltnp '( sport = :7832 )'
lan_ip=$(ip -4 -json addr show dev eth0 | jq -r '.[0].addr_info[] | select(.scope=="global") | .local' | head -1)
test -n "$lan_ip"
! curl --connect-timeout 2 --fail --silent "http://$lan_ip:7832/api/health"
```

Expected: loopback health is `ok`; the only listener is `127.0.0.1:7832`; the WSL LAN-address request fails.

- [ ] **Step 7: Inspect bounded startup logs**

Run:

```bash
journalctl --user -u piface.service -n 100 --no-pager
```

Expected: Piface starts, state path is `~/.local/share/piface/state.json`, model preloading does not report missing Pi/RPC failures, and no credential values appear. Record only status and error summaries, not full prompts or tokens.

---

### Task 4: Verify Pi compatibility in a disposable linked worktree

**Files:**
- Create: `/home/tng/.dotfiles/tmp/worktrees/piface-smoke/` via `git worktree add`
- Create temporarily: local branch `test/piface-smoke`
- Modify: `~/.local/share/piface/state.json` through Piface APIs
- Create: one Pi session JSONL under `~/.pi/agent/sessions/`
- Modify: `~/.local/share/piface/evaluation-2026-09-02.md`

**Interfaces:**
- Consumes: healthy loopback Piface API and current `/home/tng/.dotfiles` repository
- Produces: a live non-ephemeral Piface session whose actual execution directory is a verified linked worktree

- [ ] **Step 1: Create and verify the disposable worktree**

Run from `/home/tng/.dotfiles` after fetching `origin/main`:

```bash
git fetch origin main
test ! -e /home/tng/.dotfiles/tmp/worktrees/piface-smoke
! git show-ref --verify --quiet refs/heads/test/piface-smoke
git worktree add /home/tng/.dotfiles/tmp/worktrees/piface-smoke \
  -b test/piface-smoke origin/main

git -C /home/tng/.dotfiles/tmp/worktrees/piface-smoke status --short --branch
```

Expected: clean `test/piface-smoke` linked worktree. Confirm `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir` and no superproject is reported.

- [ ] **Step 2: Verify Piface model discovery before creating a session**

Run:

```bash
curl --fail --silent http://127.0.0.1:7832/api/models \
  | jq -e '.models | any(.provider == "github-copilot" and .id == "gpt-5.6-sol")'
```

Expected: true. If the model list is empty or the configured GitHub Copilot model is absent, stop for RPC/auth diagnosis.

- [ ] **Step 3: Create the session through the local API with an explicit worktree path**

Run:

```bash
curl --fail --silent --show-error \
  -X POST http://127.0.0.1:7832/api/sessions \
  -H 'Content-Type: application/json' \
  --data '{
    "working_dir": "/home/tng/.dotfiles/tmp/worktrees/piface-smoke",
    "provider": "github-copilot",
    "model": "gpt-5.6-sol",
    "thinking_level": "medium",
    "session_name": "piface-smoke",
    "shared": true,
    "use_direnv": false
  }' \
  | tee /tmp/piface-smoke-session.json
jq -er '.piface_id' /tmp/piface-smoke-session.json
```

Expected: HTTP 201 and a Piface session ID. `shared: true` is acceptable only because `working_dir` was independently verified as a linked worktree.

- [ ] **Step 4: Verify the persisted execution directory**

Run, replacing the shell variable only with the ID read from the non-sensitive response:

```bash
piface_id=$(jq -er '.piface_id' /tmp/piface-smoke-session.json)
curl --fail --silent "http://127.0.0.1:7832/api/sessions/$piface_id" \
  | jq -e '.working_dir == "/home/tng/.dotfiles/tmp/worktrees/piface-smoke" and .status == "live"'
```

Expected: true. Stop if the directory differs.

- [ ] **Step 5: Verify the actual Pi child identity without dumping its environment**

Find the Piface service PID and select exactly one direct Pi RPC child whose cwd is the smoke worktree:

```bash
piface_pid=$(systemctl --user show piface.service -p MainPID --value)
pi_pid=$(
  for candidate_pid in $(pgrep -P "$piface_pid"); do
    candidate_cwd=$(readlink -f "/proc/$candidate_pid/cwd" 2>/dev/null || true)
    candidate_cmd=$(tr '\0' ' ' <"/proc/$candidate_pid/cmdline" 2>/dev/null || true)
    if [ "$candidate_cwd" = /home/tng/.dotfiles/tmp/worktrees/piface-smoke ] \
      && [[ "$candidate_cmd" == *"--mode rpc"* ]]; then
      printf '%s\n' "$candidate_pid"
    fi
  done
)
[[ "$pi_pid" =~ ^[0-9]+$ ]]

readlink -f "/proc/$pi_pid/cwd"
tr '\0' ' ' <"/proc/$pi_pid/cmdline"; printf '\n'
agent_dir=$(tr '\0' '\n' <"/proc/$pi_pid/environ" | grep '^PI_CODING_AGENT_DIR=' || true)
printf '%s\n' "${agent_dir:-PI_CODING_AGENT_DIR unset; default ~/.pi/agent applies}"
```

Expected: cwd is the smoke worktree; cmdline identifies the same Earendil Pi CLI path/package recorded in Task 3; agent directory is `/home/tng/.pi/agent` explicitly or by verified default. Never print the other environment entries.

- [ ] **Step 6: Perform browser RPC/UI smoke tests over loopback**

Open `http://127.0.0.1:7832`, select `piface-smoke`, and use non-sensitive content to verify:

1. Send a prompt asking Pi to report the current directory; confirm it reports the smoke worktree.
2. Send a second prompt while streaming as a steering or follow-up message; confirm ordering.
3. Start a harmless longer response and use Abort; confirm the session settles.
4. Ask Pi to run `printf "$HOME"` so the permission system produces an extension UI confirmation; deny it and confirm the tool is blocked.
5. Run `!!pwd` and confirm Piface executes it outside model context; record this as the expected permission-bypass boundary.
6. Ask Pi to create `piface-smoke.txt` containing `non-sensitive piface trial`; confirm the Files and Diff tabs show it.
7. Remove `piface-smoke.txt` through a reviewed worktree operation and confirm the worktree returns clean.

Expected: all events stream, the permission dialog is actionable, direct Piface bash behavior is understood, and no primary checkout changes.

- [ ] **Step 7: Verify transcript and upload location metadata**

Read the smoke session record to identify its `session_file`. Verify the file is beneath `~/.pi/agent/sessions/`, mode is not group/world-readable, and any upload path is under that session directory's `uploads/_shared/`. Do not print the full JSONL. Inspect only the known non-sensitive smoke entries and confirm `!command`/tool output retention matches the design.

---

### Task 5: Publish Piface through tailnet-only HTTPS

**Files:**
- Modify: Tailscale Serve configuration
- Modify: `~/.local/share/piface/evaluation-2026-09-02.md`

**Interfaces:**
- Consumes: authenticated WSL Tailscale node and healthy loopback Piface service
- Produces: persistent tailnet-only HTTPS URL proxying to `127.0.0.1:7832`

- [ ] **Step 1: Confirm Piface is healthy and Funnel remains off**

Run:

```bash
curl --fail --silent http://127.0.0.1:7832/api/health | jq -e '.status == "ok"'
tailscale funnel status --json 2>/dev/null || true
```

Expected: Piface healthy; no Funnel route.

- [ ] **Step 2: Confirm installed Serve syntax**

Run:

```bash
tailscale serve --help
```

Expected: installed version supports `--bg`, `--https=443`, and an HTTP backend target. If syntax differs from the next step, stop and update the execution command from official help rather than guessing.

- [ ] **Step 3: Configure persistent Serve ingress**

Run:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7832
```

Expected: command reports a concrete tailnet-only HTTPS URL for the authenticated WSL node and a proxy to `http://127.0.0.1:7832`.

- [ ] **Step 4: Verify Serve configuration and no Funnel**

Run:

```bash
tailscale serve status --json | jq .
tailscale funnel status --json 2>/dev/null || true
```

Expected: exactly one intended HTTPS handler points to loopback Piface; no Funnel handler exists. Record the tailnet DNS URL and redacted status summary.

- [ ] **Step 5: Test from the trusted remote device**

On a phone or laptop connected to the operator's tailnet:

1. Open the Serve HTTPS URL.
2. Confirm the dashboard and `piface-smoke` session load.
3. Send one non-sensitive prompt and observe streaming.
4. Confirm the Files and Diff tabs show only the smoke worktree context used in Task 4.

Expected: HTTPS works only while the device is connected to Tailscale. Disconnect that client from Tailscale and confirm the URL is unreachable, then reconnect.

- [ ] **Step 6: Confirm direct LAN access still fails**

From a LAN peer without Tailscale, request port 7832 at the WSL LAN IPv4 address recorded in Task 3, Step 6, using the `/api/health` path.

Expected: connection fails. If it succeeds, immediately stop Piface and remove the Serve route before diagnosis.

---

### Task 6: Test restart, persistence, and fail-closed behavior

**Files:**
- Modify: `~/.local/share/piface/state.json`
- Modify: the smoke Pi session JSONL and browser site data
- Modify: `~/.local/share/piface/evaluation-2026-09-02.md`

**Interfaces:**
- Consumes: live non-ephemeral `piface-smoke` session and active Serve route
- Produces: evidence for service recovery, known persistence, and endpoint shutdown behavior

- [ ] **Step 1: Record non-secret pre-restart identifiers**

Record the Piface session ID, session status, worktree path, and Pi session-file path. Do not copy transcript bodies, auth data, Tailscale node keys, or cookies.

- [ ] **Step 2: Restart Piface and verify session restoration**

Run:

```bash
systemctl --user restart piface.service
systemctl --user is-active piface.service
curl --retry 10 --retry-delay 1 --retry-connrefused \
  --fail --silent http://127.0.0.1:7832/api/health | jq -e '.status == "ok"'
```

Then query the saved session ID and verify status is `live`, working directory is the smoke worktree, and session file is unchanged. In the browser, confirm history replay and send one non-sensitive continuation.

- [ ] **Step 3: Inspect bounded server-side persistence**

Run metadata-only checks:

```bash
stat -c '%a %U %G %n' \
  ~/.local/share/piface-runtime/pyproject.toml \
  ~/.local/share/piface-runtime/uv.lock \
  ~/.config/systemd/user/piface.service \
  ~/.local/share/piface/state.json
journalctl --user -u piface.service -n 200 --no-pager
```

Expected: authored runtime/unit files are owner-only; state is not group/world-readable; journal contains lifecycle and command metadata but no credentials/tokens. Inspect only the smoke session's known non-sensitive JSONL entries and upload directory metadata.

- [ ] **Step 4: Inspect and clear browser retention on a test client**

In browser developer tools for the Piface Tailscale origin:

1. Inspect `localStorage` and `sessionStorage` keys for theme/skin, recent files, session snapshots, composer drafts, scratch text, and view state.
2. Confirm any retained content comes only from the non-sensitive smoke trial.
3. Use the browser's “clear site data” control.
4. Reload and confirm drafts, scratch text, and snapshots are gone while server-side session history remains available.

Expected: client-side cleanup is complete for that origin and does not delete server-side Pi/Piface state.

- [ ] **Step 5: Verify backend failure is visible through Serve**

Run:

```bash
systemctl --user stop piface.service
! curl --connect-timeout 2 --fail --silent http://127.0.0.1:7832/api/health
```

From the tailnet client, confirm the HTTPS endpoint does not serve a stale working control plane while Piface is stopped. Then restart Piface and confirm recovery:

```bash
systemctl --user start piface.service
curl --retry 10 --retry-delay 1 --retry-connrefused \
  --fail --silent http://127.0.0.1:7832/api/health | jq -e '.status == "ok"'
```

- [ ] **Step 6: Verify Serve route removal and restoration**

First record `tailscale serve status --json`. Then remove the route using syntax confirmed by installed help, expected to be:

```bash
tailscale serve --bg --https=443 off
```

Expected: the tailnet URL becomes unavailable while loopback Piface remains healthy. Restore the exact reviewed route:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7832
```

Verify status again and confirm Funnel remains absent.

---

### Task 7: Decide trial acceptance and leave a reversible state

**Files:**
- Finalize: `~/.local/share/piface/evaluation-2026-09-02.md`
- Optionally remove: smoke Piface session, smoke Pi session/upload data, `/home/tng/.dotfiles/tmp/worktrees/piface-smoke`, and `test/piface-smoke`
- Preserve on acceptance: Piface runtime, unit, state, Pi sessions, and Tailscale Serve route

**Interfaces:**
- Consumes: all evaluation evidence from Tasks 1–6
- Produces: either an accepted running trial or a complete rollback with explicitly chosen data retention

- [ ] **Step 1: Complete the acceptance checklist in the evaluation record**

Record pass/fail for:

- locked dependency graph and lock hash;
- Python/Piface versions;
- actual Earendil Pi child path/package/agent directory;
- loopback-only listener and failed LAN access;
- tailnet-only Serve and absent Funnel;
- GitHub Copilot model discovery;
- linked-worktree execution;
- streaming, steering/follow-up, abort, permission UI, Files, Diff, and direct `!!` boundary;
- service restart/session restoration;
- server/browser persistence inspection and browser cleanup;
- backend-stop and Serve-route-removal behavior.

Do not mark an item passed without its command or manual observation from this run.

- [ ] **Step 2: Present the operator decision checkpoint**

If every required item passed, ask exactly whether to:

1. keep the machine-local trial running;
2. roll back runtime/service/Serve while preserving state;
3. roll back and, after separate confirmation, delete the disposable trial data.

Do not infer acceptance from absence of a response.

- [ ] **Step 3a: On acceptance, clean only the disposable worktree after closing its session**

Close/archive the Piface smoke session first. Confirm the worktree is clean, then remove it and delete its local branch using the repository's reviewed worktree cleanup flow. Preserve the smoke Pi/Piface session records unless the operator separately requests deletion. Leave `piface.service` enabled and the Tailscale Serve route active.

- [ ] **Step 3b: On rollback, stop ingress and service before removing runtime files**

Run in order:

```bash
tailscale serve --bg --https=443 off
systemctl --user disable --now piface.service
rm ~/.config/systemd/user/piface.service
systemctl --user daemon-reload
```

Preserve `~/.local/share/piface-runtime/pyproject.toml` and `uv.lock` with the evaluation record if reproducibility is desired, then remove `.venv/`. Leave Piface state, Pi sessions/uploads, browser data, worktrees, and the WSL Tailscale node intact unless the operator explicitly selects full cleanup.

- [ ] **Step 3c: On explicitly confirmed full cleanup, remove only identified trial data**

After showing exact paths and receiving confirmation, remove the smoke session's identified Pi JSONL/upload data, Piface smoke record/state only if no other sessions need it, the smoke worktree/branch through the reviewed Git cleanup flow, the Piface runtime directory, and Piface browser-origin site data on each test client. Never delete all `~/.pi/agent/sessions/` or unrelated Piface state by wildcard.

- [ ] **Step 4: Record deferred follow-ups without implementing them**

Add evaluation notes for:

- whether Piface should become dotfiles-managed;
- whether TTS merits separate evaluation;
- any Earendil RPC compatibility issues;
- the upstream worktree-selector issue/PR, based on Piface commit `6172144f221b5f6e2240d9ca1bb7cc522607ef62` and verified against upstream HEAD before submission.

Do not start the upstream PR or permanent dotfiles integration as part of this trial plan.
