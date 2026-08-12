# Vekil AI proxy

Vekil is the local proxy that routes both Claude Code and Codex to upstream
models (via Copilot). It replaced the old LiteLLM setup. This directory holds
its installer (`install.sh`), lifecycle helper reference, and the shell
integration (`env.zsh`) that points the clients at the proxy.

- Proxy lifecycle script: `bin/vekil-proxy`
- Autostart unit template: `ai/vekil/vekil.service`
- Shell integration (sourced early from `core/shell/zshrc.symlink`): `ai/vekil/env.zsh`
- Codex config + auth installer: `ai/codex/install.sh`
- Migration background: `VEKIL_MIGRATION_HANDOFF.md` (repo root)

## Autostart

`env.zsh` is deliberately read-only: it checks `/readyz` and, if the proxy is
down, unsets the managed variables and returns. It never starts the proxy. So
something else has to, or every shell after a reboot silently gets no
`ANTHROPIC_BASE_URL` and Claude/Codex bypass the proxy.

On Linux with a systemd user manager, `ai/vekil/install.sh` installs a user
service from the `ai/vekil/vekil.service` template, substituting the repo path
into `ExecStart`, then enables it and turns on lingering (so the user manager
survives logout and starts at boot).

```bash
systemctl --user status vekil       # is it up?
systemctl --user restart vekil      # after auth changes or a version bump
journalctl --user -u vekil -n 50    # startup output (proxy's own log is bin/vekil-proxy logs)
```

Notes:

- The unit is `Type=oneshot` + `RemainAfterExit=yes`. `vekil-proxy start`
  daemonizes and returns once `/readyz` answers; the proxy stays in the unit's
  cgroup, so `systemctl --user stop vekil` shuts it down properly.
- `ExecStartPre` waits up to 30s for the Docker bridge. The proxy binds to that
  bridge so devcontainers can reach it via `host.docker.internal`; without the
  wait, a boot race binds it to loopback and container access breaks silently.
- A terminal opened in the first second or two after boot can still lose the
  race and start without the variables. Open a new shell.
- If you set `VEKIL_PORT`, `VEKIL_BIN`, `VEKIL_STATE_DIR`, `VEKIL_TOKEN_DIR`, or
  `VEKIL_INSTALL_DIR`, the installer skips the service and starts the proxy
  directly — the unit runs with no environment and would otherwise manage a
  different proxy than you asked for. Same fallback when there is no systemd
  user manager (containers, CI, macOS): set `VEKIL_SKIP_SERVICE=1` to force it.
- Lingering needs polkit permission. If the installer warns, run
  `sudo loginctl enable-linger $USER`.

## Shutdown failures

`vekil-proxy stop` verifies the recorded PID and process start identity after
both graceful termination and, when needed, SIGKILL. Graceful shutdown waits
for `VEKIL_STOP_TIMEOUT` (15 seconds by default); confirmation after SIGKILL
uses `VEKIL_KILL_CONFIRM_TIMEOUT` (2 seconds, accepted range 0–30).

If the same process survives, the command returns nonzero, preserves
`proxy.pid`, and writes a private `proxy-stop-failed` record. While that exact
process remains alive, `vekil-proxy status` reports
`STOP_FAILED host=... port=... pid=...` before considering endpoint health.
Correct the condition preventing termination and rerun `vekil-proxy stop`;
ownership and failure records are removed only after the recorded process is
confirmed gone. A later successful start also clears the failure record.


## How the two clients reach the proxy

Claude and Codex are routed by **two different mechanisms** — worth knowing,
because they fail independently.

| Client | Routing mechanism | Set by |
|--------|-------------------|--------|
| Claude | Reads `ANTHROPIC_BASE_URL` from the environment | `env.zsh` exports it |
| Codex  | Ignores base-URL env vars; needs `config.toml` or a `-c` override | `env.zsh` defines a `codex` shell function injecting `-c openai_base_url=…` |

Vekil v0.14.0 sends Copilot Claude models through their native Anthropic
Messages route. That preserves Claude Code's `Anthropic-Beta` headers, but
Copilot rejects the experimental Advisor Tool header. While `env.zsh` manages
the Anthropic proxy endpoint it therefore also exports
`CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1`. The value uses the same ownership rules as
the managed endpoint: an explicit user value is preserved, unavailable-proxy
cleanup removes only the Vekil-owned value, and `claude-direct` removes the
managed value so direct Anthropic sessions can use Advisor Tool.

Because Codex ignores `OPENAI_BASE_URL`, the managed `codex` shell function is
what actually routes it. In an interactive shell, confirm both are active:

```zsh
print $ANTHROPIC_BASE_URL      # → http://<proxy-host>:1337   (Claude route)
whence -v codex                # → shell function, not the raw mise binary (Codex route)
print ${+functions[codex]}     # → 1
```

If `codex` resolves to the raw binary instead of the function, the shell hasn't
sourced `env.zsh` (e.g. a minimal or non-interactive shell) — Codex will bypass
the proxy.

## Codex first-run auth

Codex shows its interactive **"Sign in with ChatGPT"** onboarding whenever
`~/.codex/auth.json` is missing — even though `env.zsh` already supplies
`OPENAI_API_KEY=dummy` and the proxy accepts it. On a fresh machine the file
never existed, so `codex` dropped to the sign-in prompt.

`ai/codex/install.sh` now provisions this automatically (`ensure_auth`): it
writes a placeholder apikey `auth.json` when none exists, and never overwrites
an existing one (so a real ChatGPT/API login is preserved). If you ever need to
do it by hand:

```bash
printf 'dummy' | codex login --with-api-key
```

The `426 Upgrade Required` line Codex prints on start is harmless: with
`wire_api = "responses"` it probes a WebSocket first, the proxy declines, and it
falls back to HTTPS streaming (the successful request).

## Model list — is it kept up to date?

**The available catalog is live.** Vekil serves whatever upstream currently
offers; nothing in this repo pins the list. Query it any time:

```bash
./bin/vekil-proxy models      # curls /v1/models and prints the current model IDs
```

As upstream adds or removes models, this list follows automatically.

**One default is hardcoded and does NOT auto-follow** - you own this string:

- `ai/codex/config.toml`:
  ```toml
  model = "gpt-5.6-sol"        # Codex default (not a filter - any served model still selectable)
  ```

If upstream ever retires that exact ID, requests using the default fail
until you update the string. (This is what caused the original
`gpt-5-6-sol` vs `gpt-5.6-sol` mismatch.) When in doubt, run
`./bin/vekil-proxy models` to see the current truth.

**Claude is deliberately not pinned.** Neither `env.zsh` nor
`bin/vekil-proxy env` exports `ANTHROPIC_MODEL`, so model choice stays with
Claude Code's own config (`settings.json` and the `/model` picker). An export
here would win over both, silently: it once pinned every session to
`claude-opus-5` (200k context) while `settings.json` asked for a 1M-context
variant, which showed up only as constant compaction.

## Accessing Claude/Codex inside a devcontainer

You do **not** run a second proxy in the container — the clients reach the Vekil
proxy running on the **host**. Three pieces cooperate:

1. **Endpoint switching (automatic).** `env.zsh` detects the container and swaps
   the proxy host from the Docker-bridge address to `host.docker.internal`:
   ```zsh
   if [[ -e /.dockerenv || -n $REMOTE_CONTAINERS || -n $CODESPACES ]]; then
     _vekil_env_host=host.docker.internal
   ```
2. **`host.docker.internal` must resolve.** On Linux/WSL2 it doesn't by default.
   The compose override adds `extra_hosts: ["host.docker.internal:host-gateway"]`.
   Missing this is the most common devcontainer failure.
3. **Config is seeded, not mounted.** The seed model mounts `~/.dotfiles`
   read-only at `/host-seed`, copies it container-local, then runs
   `ai/codex/install.sh` inside the container — which now also writes
   `auth.json`. See
   `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`.

### Workflow

1. **Host:** ensure the proxy is running and authenticated —
   `./bin/vekil-proxy status` (start with `./bin/vekil-proxy start`). The
   container has no Vekil binary or credentials of its own.
2. **Bring the container up:** from the project dir, `bin/claude-devcontainer-up`.
3. **Inside:** the seed script has run the Codex installer and your shell sources
   `env.zsh`, so `claude` and `codex` route through `host.docker.internal:1337`.

### Verify inside a running container

```bash
curl -fsS http://host.docker.internal:1337/readyz   # proxy reachable from container?
print $ANTHROPIC_BASE_URL                            # → http://host.docker.internal:1337
whence -v codex                                      # → shell function (routed)
```

This path assumes a compose-based devcontainer with the override and
`local-seed.sh` in place. If a project doesn't have them yet, the
`my:project-claude-setup` skill sets them up.
