# Vekil AI proxy

Vekil is the local proxy that routes both Claude Code and Codex to upstream
models (via Copilot). It replaced the old LiteLLM setup. This directory holds
its installer (`install.sh`), lifecycle helper reference, and the shell
integration (`env.zsh`) that points the clients at the proxy.

- Proxy lifecycle script: `bin/vekil-proxy`
- Shell integration (sourced from `core/shell/load-custom.zsh`): `ai/vekil/env.zsh`
- Codex config + auth installer: `ai/codex/install.sh`
- Migration background: `VEKIL_MIGRATION_HANDOFF.md` (repo root)

## How the two clients reach the proxy

Claude and Codex are routed by **two different mechanisms** — worth knowing,
because they fail independently.

| Client | Routing mechanism | Set by |
|--------|-------------------|--------|
| Claude | Reads `ANTHROPIC_BASE_URL` from the environment | `env.zsh` exports it |
| Codex  | Ignores base-URL env vars; needs `config.toml` or a `-c` override | `env.zsh` defines a `codex` shell function injecting `-c openai_base_url=…` |

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

**Two defaults are hardcoded and do NOT auto-follow** — you own these strings:

- `ai/codex/config.toml`:
  ```toml
  model = "gpt-5.6-sol"        # Codex default (not a filter — any served model still selectable)
  ```
- `ai/vekil/env.zsh`:
  ```zsh
  export ANTHROPIC_MODEL=claude-opus-4.8   # Claude default
  ```

If upstream ever retires one of these exact IDs, requests using the default fail
until you update the string. (This is what caused the original
`gpt-5-6-sol` vs `gpt-5.6-sol` mismatch.) When in doubt, run
`./bin/vekil-proxy models` to see the current truth.

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
