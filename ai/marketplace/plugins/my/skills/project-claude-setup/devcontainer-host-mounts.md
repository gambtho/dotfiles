# Devcontainer seed-and-copy mounts (reference)

> This file is referenced from `SKILL.md` in this directory. It is a
> copy-pasteable reference for the devcontainer step of
> `my:project-claude-setup`. No YAML frontmatter — this is not a
> separately loaded skill.

Use a local `docker-compose.override.yml` to expose SSH and `gh` auth read-only, and expose Claude Code config and dotfiles as read-only seed sources under `/host-seed`. Project-scoped named volumes at the container user's `~/.claude` and `~/.dotfiles` replace inherited host binds with the same targets. A local `local-seed.sh` copies the authored subset into those container-local volumes before the base foreground command starts. Claude Code can then write sessions, history, plugins, and other runtime state only inside the container.

Do not use `claude-merge-compose-override` for this model until that helper is updated: its current output creates writable and dual-home mounts. OpenCode is no longer bridged; the seed script links Codex with `ai/codex/install.sh`.

## When to use this

Trigger this skill when the user says things like:
- "set up the devcontainer mounts" / "add the docker compose override"
- "share my ssh keys / gh auth / Claude config / dotfiles with the container"
- "bootstrap a new project's devcontainer the way I usually do"
- starts working on a fresh project and the devcontainer comes up without their host tools

If `.devcontainer/` doesn't exist yet, stop and tell the user this skill assumes a compose-based devcontainer is already in place — offer to help create one separately, but don't invent one as part of this task.

## Step 1 — Verify the prerequisites

Confirm these exist:
- `.devcontainer/devcontainer.json`
- a compose file referenced from it — read the `dockerComposeFile` key in `devcontainer.json` to find the actual paths. The compose files commonly live under `.devcontainer/`, but some projects keep them at the project root and reference them with `../docker-compose.yml`. The override goes wherever the base compose lives, not blindly under `.devcontainer/`.

If a `docker-compose.override.yml` already exists at that location, read it before doing anything else. Preserve unrelated keys and show the diff before writing. Back it up to `<file>.backup-<timestamp>` before replacing legacy mounts.

## Step 2 — Discover the service name and container user

These values vary per project and must be filled in correctly, otherwise mounts or the seed command land in the wrong place.

**Service name.** Open `.devcontainer/docker-compose.yml`. The override must target the same top-level service. Most projects use `app`, but some name it after the project (e.g. `wanderer:` in the wanderer repo). Use whichever name appears under `services:` in the base compose file. If `devcontainer.json` has a `service:` key, that is authoritative.

**In-container user.** The mount targets must use the user's actual home path inside the container. Resolve in this order:
1. `remoteUser` in `.devcontainer/devcontainer.json` if set
2. `USER` instruction in the Dockerfile (parse the last one that wins)
3. Base image default — common ones below

| Base image | Default user |
|---|---|
| `mcr.microsoft.com/devcontainers/javascript-node` | `node` |
| `mcr.microsoft.com/devcontainers/typescript-node` | `node` |
| `mcr.microsoft.com/devcontainers/base:ubuntu` (and most language variants) | `vscode` |
| `mcr.microsoft.com/devcontainers/universal` | `codespace` |
| Custom Dockerfile with no `USER` | `root` (warn — bind mounts will be owned by root) |

If you can't determine the user from any of these signals, ask. Do not guess between `vscode` / `node` / `developer` — getting it wrong silently mounts into a path the shell never visits.

**Workspace path.** Resolve `workspaceFolder` from `devcontainer.json`. If it is absent, inspect the base compose volume target. Do not assume `/workspace` or `/workspaces/<name>`.

**Base foreground command.** Read the base service's `command`. The override replaces this scalar, so the seed wrapper must `exec` the original foreground command after seeding. If the base command is `sleep infinity`, preserve that exact command.

## Step 3 — Decide which mounts to include

The default set, in order:

```
~/.ssh                  →  /home/{USER}/.ssh                 (ro)
~/.config/gh            →  /home/{USER}/.config/gh           (ro)
~/.claude               →  /host-seed/.claude                (ro) seed source, never written
~/.dotfiles             →  /host-seed/.dotfiles              (ro) seed source
```

Container-local targets:

```
claude-local-home       →  /home/{USER}/.claude              named volume
dotfiles-local-home     →  /home/{USER}/.dotfiles            named volume
```

Compose merges service volumes by container target. These named-volume entries therefore replace legacy base-file binds targeting the same home paths instead of merely adding more mounts. If a base compose file binds host OpenCode config, add an empty `opencode-local-home` named volume at that target to shadow it; do not seed OpenCode.

Why each one:
- **`~/.ssh` (ro)**: lets the container `git push` over SSH and connect to remote hosts using the host's keys. Read-only because the container should never modify host keys.
- **`~/.config/gh` (ro)**: shares the `gh` CLI's stored auth token so `gh pr create`, `gh api`, etc. work without a fresh login inside the container.
- **`~/.claude` seed (ro)**: supplies only authored config to the seed script. The container never writes through this mount.
- **`~/.dotfiles` seed (ro)**: supplies shell config and the marketplace/Codex installers. The script copies it container-local before running installers.

Optional, ask before adding:
- **`~/.pi`** — only used in some of the user's projects (e.g. `abyssalwatch`). Don't include by default.
- **Project-specific dirs** — if the user mentions another tool's config they want shared, mount it the same way.

If a host directory doesn't exist, Docker creates an empty one when the container starts. That's not a failure mode — just means the tool isn't on the host yet. Don't add `if`-checks or skip mounts on this basis.

## Step 4 — Write the local override and seed script

Write to the same directory as the base compose file (per Step 1). If the base is `.devcontainer/docker-compose.yml`, the override is `.devcontainer/docker-compose.override.yml`; if the base lives at the project root, the override lives at the project root too. Compose's auto-merge of `*.override.yml` only kicks in when both files are siblings or both are listed in `dockerComposeFile` — putting the override in the wrong directory silently does nothing.

Use this template, filling in `{SERVICE}`, `{USER}`, `{WORKSPACE}`, and `{BASE_COMMAND}` from Step 2:

```yaml
# LOCAL, GITIGNORED. Claude and dotfiles are read-only seed sources. The seed
# script copies them container-local so container writes cannot reach the host.
services:
  {SERVICE}:
    volumes:
      - ~/.ssh:/home/{USER}/.ssh:ro
      - ~/.config/gh:/home/{USER}/.config/gh:ro
      - ~/.claude:/host-seed/.claude:ro,cached
      - ~/.dotfiles:/host-seed/.dotfiles:ro,cached
      - claude-local-home:/home/{USER}/.claude
      - dotfiles-local-home:/home/{USER}/.dotfiles
    command: >-
      bash -c "bash {WORKSPACE}/.devcontainer/local-seed.sh; exec {BASE_COMMAND}"
    configs:
      - source: gitconfig_local
        target: /home/{USER}/.gitconfig.local
        mode: 0644
    extra_hosts:
      - "host.docker.internal:host-gateway"

configs:
  gitconfig_local:
    content: |
      [credential]
          useHttpPath = true

volumes:
  claude-local-home:
  dotfiles-local-home:
```

If the base compose file has a legacy host OpenCode bind, also add:

```yaml
services:
  {SERVICE}:
    volumes:
      - opencode-local-home:/home/{USER}/.config/opencode

volumes:
  opencode-local-home:
```

This does not bridge OpenCode; it replaces the inherited host bind with an empty project-local volume.

Write `{WORKSPACE}/.devcontainer/local-seed.sh` with:

```bash
#!/usr/bin/env bash
# Local-only devcontainer seed (gitignored). Copies the authored subset of the
# host ~/.claude into a CONTAINER-LOCAL ~/.claude so nothing the container writes
# can reach the host. Idempotent: guarded by ~/.claude/.seeded.
set -euo pipefail

SEED_CLAUDE="/host-seed/.claude"
SEED_DOTFILES="/host-seed/.dotfiles"
SENTINEL="$HOME/.claude/.seeded"

if [ -f "$SENTINEL" ]; then
  echo "🌱 seed: already seeded ($SENTINEL) — skipping"
  exit 0
fi

echo "🌱 seed: creating container-local ~/.claude"
mkdir -p "$HOME/.claude"

# 1. Copy authored config subset (skip runtime state + 1.6G plugins).
if [ -d "$SEED_CLAUDE" ]; then
  for item in settings.json CLAUDE.md config; do
    [ -e "$SEED_CLAUDE/$item" ] && cp -a "$SEED_CLAUDE/$item" "$HOME/.claude/$item"
  done
  for dir in commands skills; do
    [ -d "$SEED_CLAUDE/$dir" ] && cp -a "$SEED_CLAUDE/$dir" "$HOME/.claude/$dir"
  done
  echo "🌱 seed: copied authored ~/.claude subset"
else
  echo "🌱 seed: no $SEED_CLAUDE mount — starting with empty ~/.claude"
fi

# 2. Copy dotfiles container-local (shell sourcing + marketplace/codex installers).
if [ -d "$SEED_DOTFILES" ] && [ ! -d "$HOME/.dotfiles" ]; then
  cp -a "$SEED_DOTFILES" "$HOME/.dotfiles"
  echo "🌱 seed: copied ~/.dotfiles ($(du -sh "$HOME/.dotfiles" | cut -f1))"
fi

# 3. Reinstall my@guarzo marketplace + plugins into container-local ~/.claude.
if [ -x "$HOME/.dotfiles/ai/marketplace/install.sh" ]; then
  echo "🌱 seed: installing my@guarzo marketplace + plugin"
  bash "$HOME/.dotfiles/ai/marketplace/install.sh" || echo "⚠️  seed: marketplace install failed (non-fatal)"
fi

# 4. Link Codex config (replaces OpenCode).
if [ -x "$HOME/.dotfiles/ai/codex/install.sh" ]; then
  echo "🌱 seed: linking Codex config"
  bash "$HOME/.dotfiles/ai/codex/install.sh" || echo "⚠️  seed: codex install failed (non-fatal)"
fi

# 5. Sentinel.
touch "$SENTINEL"
echo "🌱 seed: done"
```

Execute it with `bash`; an executable bit is optional. Keep both files untracked. If the project does not already ignore them, add the actual override path plus the seed script path to `.git/info/exclude`. For the common `.devcontainer/` layout:

```text
.devcontainer/docker-compose.override.yml
.devcontainer/local-seed.sh
```

Why the two non-volume blocks:

- **`extra_hosts: host.docker.internal:host-gateway`** — on Docker Desktop (macOS/Windows) this DNS name exists automatically, but on Linux and WSL2 it does not. Adding `host-gateway` makes it resolve to the host on every platform, so anything in the container that talks to a host-side service (a dev server, a database tunnel, etc.) works the same everywhere. Include it in the override unless the base compose already declares it on the same service — grep the base for `host.docker.internal` first. Duplicating works (compose merges and dedupes by host name) but adds noise.
- **`gitconfig_local` config** — sets `credential.useHttpPath = true` in a separate `~/.gitconfig.local` that the user's main gitconfig is expected to `[include]`. With this on, git's credential helper keys credentials by full URL path, which means cached creds for one repo don't get reused for another. Include this by default; the only project the user has without it is one of the older ones.

If the container user is `root`, mount targets become `/root/...` instead of `/home/{USER}/...`. Same shape otherwise.

### Why seed instead of mount

The legacy writable `~/.claude` mount let the container persist `/home/{USER}` paths and symlink targets into host config. Parallel host-home mounts made those references resolve inside the container but widened the write-back channel. Read-only `/host-seed` mounts plus container-local named volumes and copies remove that channel structurally: nothing Claude Code writes under its container-local home can reach the host.

### Repairing a legacy rw-mount project

Follow `SKILL.md` Step 6b. Canonical detection checks:

```bash
grep -rnE '~/\.claude:/home/[^:]+:cached' .devcontainer/
grep -rn '${HOME}:${HOME}' .devcontainer/ 2>/dev/null || \
  grep -rnE '\$\{HOME\}/\.claude:\$\{HOME\}/\.claude' .devcontainer/
grep -rl '/home/vscode\|/home/node' ~/.claude/plugins/*.json 2>/dev/null
ls -l /home/*/ 2>/dev/null | grep -- '-> /home/' # inside a container only
```

Any signal means offer repair. Confirm each write, back up the override, remove writable/dual mounts, and inspect the fully merged Compose config. If a tracked base compose file still supplies host binds, replace those targets from the local override with project-scoped named volumes rather than editing the tracked base. Show host-config diffs before optional path rewrites or symlink cleanup, and require a container rebuild afterward.

## Step 5 — Verify

Once written:
1. Run `docker compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml config` from the project root. Compose will print the merged config or fail loudly on a typo. Check that the service name matches and that no host bind targets the container user's `~/.claude`, `~/.dotfiles`, or OpenCode directory.
2. Confirm the merged `command` contains `local-seed.sh` followed by the original foreground command.
3. Run `git check-ignore .devcontainer/docker-compose.override.yml .devcontainer/local-seed.sh` and `git status --short` to confirm no personal config became tracked.
4. After the user rebuilds, verify container-local files and read-only seed mounts:

```bash
docker compose exec {SERVICE} test -f /home/{USER}/.claude/.seeded
docker compose exec {SERVICE} test -f /home/{USER}/.claude/settings.json
docker compose exec {SERVICE} test -f /home/{USER}/.codex/config.toml
docker compose exec {SERVICE} sh -c 'touch /host-seed/.claude/.write-test' # must fail read-only
```

5. If the devcontainer is currently running, tell the user "Rebuild Container" is required before these runtime checks.

Don't rebuild for them; that's their call.

## Things to avoid

- Don't mount Claude Code or dotfiles read-write from the host.
- Don't assume adding `/host-seed` mounts removes legacy binds from the base compose file; verify the merged config and shadow inherited targets with named volumes.
- Don't restore parallel `${HOME}:${HOME}` mounts to make absolute references resolve.
- Don't copy host plugin runtime state; reinstall the personal marketplace container-local.
- Don't add comments explaining each mount line — the file header covers the why, and per-line comments age badly when the list changes. Match the style of the user's existing override files.
- Don't promote the override into the base `docker-compose.yml`. The whole point of the override is that it's host-specific and stays out of the committed compose file (or is committed but understood as the local-dev overlay).
- Don't change the service name to `app` if the base compose uses something else. The override must target the real service.
