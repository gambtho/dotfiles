# Devcontainer seed-and-copy mounts (reference)

> This file is referenced from `SKILL.md` in this directory. It is a
> copy-pasteable reference for the devcontainer step of
> `my:project-claude-setup`. No YAML frontmatter — this is not a
> separately loaded skill.

Use a local `docker-compose.override.yml` to expose an allowlisted subset of Claude Code config, plus dotfiles, as read-only seed sources under `/host-seed`. Only the authored-config paths the seed script copies are mounted — never all of `~/.claude`, which would expose host credentials and session transcripts to the container even read-only. Project-scoped named volumes at the container user's `~/.claude` and `~/.dotfiles` replace inherited host binds with the same targets. A local `local-seed.sh` copies the authored subset into those container-local volumes and installs a container-local zsh hook for Vekil before the base foreground command starts. Claude Code can then write sessions, history, plugins, and other runtime state only inside the container.

Host SSH keys (`~/.ssh`) and `gh` auth (`~/.config/gh`) are **not** shared by default. Both are single global host credentials: mounting them forces every container onto the same GitHub identity and key set, which breaks per-container credential isolation and can switch accounts unexpectedly between projects. The container should authenticate itself instead (`gh auth login` inside the container, a project-scoped `GH_TOKEN`, or its own key). Mount them only when the user explicitly opts in for a project that genuinely wants the host identity — see Step 3.

Do not use `claude-merge-compose-override` for this model until that helper is updated: its current output creates writable and dual-home mounts. OpenCode is no longer bridged; the seed script links Codex with `ai/codex/install.sh`.

## When to use this

Trigger this skill when the user says things like:
- "set up the devcontainer mounts" / "add the docker compose override"
- "share my ssh keys / gh auth / Claude config / dotfiles with the container"
- "bootstrap a new project's devcontainer the way I usually do"
- starts working on a fresh project and the devcontainer comes up without their host tools

Sharing host SSH keys and `gh` auth is an explicit opt-in, not automatic — the default mounts only the read-only Claude/dotfiles seed sources.

If `.devcontainer/` doesn't exist yet, stop and tell the user this skill assumes a compose-based devcontainer is already in place — offer to help create one separately, but don't invent one as part of this task.

## Step 1 — Verify the prerequisites

Confirm these exist:
- `.devcontainer/devcontainer.json`
- a compose file referenced from it — read the `dockerComposeFile` key in `devcontainer.json` to find the actual paths. The compose files commonly live under `.devcontainer/`, but some projects keep them at the project root and reference them with `../docker-compose.yml`. The override goes wherever the base compose lives, not blindly under `.devcontainer/`.

If a `docker-compose.override.yml` already exists at that location, read it before doing anything else. Preserve unrelated keys and show the diff before writing. Back it up to `<file>.backup-<timestamp>` before replacing legacy mounts.

Dockerfile, devcontainer.json, and base Compose files are inspection-only.

Never edit a project Dockerfile, `.devcontainer/devcontainer.json`, or a base Compose file.

The only permitted devcontainer writes are the gitignored `docker-compose.override.yml`, `local-seed.sh`, and `.git/info/exclude` entries needed for those two local files.

Capture the initial `git status --short` output before any write.

At final verification, run `git status --short` and compare its output byte-for-byte with the initial snapshot.

Report any new tracked devcontainer change without staging or reverting it.

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

**Volume ownership privilege.** Docker can create the named-volume mountpoints as `root:root`. For a non-root container user, confirm the image already provides passwordless `sudo` (standard devcontainer images do, or an existing Dockerfile may establish it). Inspect the Dockerfile only; never add users, packages, directories, ownership changes, or sudo configuration. If an existing container is available, verify with `sudo -n true`. If passwordless `sudo` is unavailable, stop and offer only a root-run init solution implemented in the gitignored local Compose override; otherwise report the setup as unsupported. Root containers do not need `sudo`.

## Step 3 — Decide which mounts to include

The default set, in order:

```
~/.claude/settings.json →  /host-seed/.claude/settings.json  (ro) seed source, never written
~/.claude/CLAUDE.md     →  /host-seed/.claude/CLAUDE.md      (ro) seed source
~/.claude/config        →  /host-seed/.claude/config         (ro) seed source
~/.claude/commands      →  /host-seed/.claude/commands       (ro) seed source
~/.claude/skills        →  /host-seed/.claude/skills         (ro) seed source
~/.dotfiles             →  /host-seed/.dotfiles              (ro) seed source
```

**Do not mount all of `~/.claude`.** Read-only still means readable: a whole-directory
mount exposes `.credentials.json`, `history.jsonl`, `projects/` session transcripts, and
`todos/` to every process in the container. Mount only the authored-config allowlist the
seed script actually copies — the paths above are exactly that list, so the two must stay
in sync if either changes.

Each entry must exist on the host before the container starts. Docker creates a *directory*
for a missing bind source, so a missing `settings.json` would surface in the container as an
empty directory and break the seed copy. Check with `ls` first and drop any entry the host
doesn't have, rather than mounting it and hoping.

Container-local targets:

```
claude-local-home       →  /home/{USER}/.claude              named volume
dotfiles-local-home     →  /home/{USER}/.dotfiles            named volume
```

Compose merges service volumes by container target. These named-volume entries therefore replace legacy base-file binds targeting the same home paths instead of merely adding more mounts. If a base compose file binds host OpenCode config, add an empty `opencode-local-home` named volume at that target to shadow it; do not seed OpenCode.

**Inherited ssh/gh binds.** If the merged base compose already binds the host's `~/.ssh` or `~/.config/gh` into the container (some base images do), the opt-in decision below is not enough on its own — an inherited bind leaks the host identity even when the user declined. When sharing is declined, shadow each inherited target with an empty project-scoped named volume (`ssh-local-home` at `/home/{USER}/.ssh`, `gh-local-home` at `/home/{USER}/.config/gh`) so the container starts with no host credentials. The merged-config check in Step 5 must confirm neither target resolves to a host bind.

Why each one:
- **`~/.claude` seed (ro)**: supplies only authored config to the seed script, mounted
  path-by-path so host credentials and session history are never visible in the
  container at all. The container never writes through these mounts.
- **`~/.dotfiles` seed (ro)**: supplies shell config and the marketplace/Codex installers. The script copies it container-local before running installers.

Optional, ask before adding:
- **`~/.ssh` (ro)** and **`~/.config/gh` (ro)** — host SSH keys and `gh` auth. **Off by default.** These are single global host credentials, so mounting them forces the container onto the host's GitHub identity and key set and can switch accounts unexpectedly across projects. Prefer having the container authenticate itself (`gh auth login` inside the container, a project-scoped `GH_TOKEN`, or its own key). Ask the user once: "Share host SSH keys and gh auth with this container? (default: no)". Only mount them if they say yes — SSH `ro` so the container can `git push`/reach remote hosts with the host keys; gh `ro` so `gh pr create`/`gh api` reuse the host token.
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
      - ~/.claude/settings.json:/host-seed/.claude/settings.json:ro,cached
      - ~/.claude/CLAUDE.md:/host-seed/.claude/CLAUDE.md:ro,cached
      - ~/.claude/config:/host-seed/.claude/config:ro,cached
      - ~/.claude/commands:/host-seed/.claude/commands:ro,cached
      - ~/.claude/skills:/host-seed/.claude/skills:ro,cached
      - ~/.dotfiles:/host-seed/.dotfiles:ro,cached
      - claude-local-home:/home/{USER}/.claude
      - dotfiles-local-home:/home/{USER}/.dotfiles
      # Opt-in: share the host GitHub identity. Off by default — mounting these
      # forces this container onto the host's gh account and SSH keys. Uncomment
      # only if the user asked to share host credentials for this project.
      # - ~/.ssh:/home/{USER}/.ssh:ro
      # - ~/.config/gh:/home/{USER}/.config/gh:ro
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

If the base compose file binds host `~/.ssh` or `~/.config/gh` and the user declined credential sharing, shadow those targets the same way so no host identity leaks in:

```yaml
services:
  {SERVICE}:
    volumes:
      - ssh-local-home:/home/{USER}/.ssh
      - gh-local-home:/home/{USER}/.config/gh

volumes:
  ssh-local-home:
  gh-local-home:
```

This does not bridge OpenCode; it replaces the inherited host bind with an empty project-local volume.

Write `{WORKSPACE}/.devcontainer/local-seed.sh` with:

```bash
#!/usr/bin/env bash
# Local-only devcontainer seed (gitignored). Copies the authored subset of the
# host ~/.claude into a CONTAINER-LOCAL ~/.claude so nothing the container writes
# can reach the host. The expensive copy/install steps are guarded by a
# versioned sentinel: bump SEED_VERSION whenever those steps change and existing
# containers re-run them on next start without a manual volume wipe.
set -euo pipefail

# Bump this whenever the gated steps below (copies, installers) change so
# already-seeded containers refresh instead of silently keeping stale state.
SEED_VERSION=2

SEED_CLAUDE="/host-seed/.claude"
SEED_DOTFILES="/host-seed/.dotfiles"
SENTINEL="$HOME/.claude/.seeded"

# --- Always-run block (before the sentinel) --------------------------------
# Ownership repair and the Vekil shell hook run on EVERY launch, even when the
# sentinel is current, so persisted named volumes stay recoverable and pick up
# hook changes without a full reseed.

# Named-volume mountpoints can start as root:root. Repair them every launch.
echo "🌱 seed: repairing container-local volume ownership"
if [ "$(id -u)" -ne 0 ]; then
  sudo chown -R "$(id -u):$(id -g)" "$HOME/.claude" "$HOME/.dotfiles"
fi

# Load Vekil's endpoint variables and managed Codex wrapper in container zsh
# sessions. Keep this before the sentinel so existing volumes gain the hook.
VEKIL_ENV_HOOK='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
ZSHRC="$HOME/.zshrc"

touch "$ZSHRC"
if ! grep -Fqx "$VEKIL_ENV_HOOK" "$ZSHRC"; then
  printf '\n%s\n' "$VEKIL_ENV_HOOK" >>"$ZSHRC"
  echo "🌱 seed: configured Vekil shell integration"
fi

# --- Versioned gate --------------------------------------------------------
# Skip the gated copy/install steps only when the sentinel already records this
# SEED_VERSION. An empty legacy sentinel (the pre-versioning contract) is NOT
# treated as current: it falls through once so the versioned copy/install steps
# run and the sentinel gets stamped, after which the gate is a plain version
# match. A bump likewise re-runs the steps. The Vekil hook above runs
# regardless. A read that FAILS (permission/IO) also falls through to the
# reseed path so the later sentinel write surfaces the error.
if [ -f "$SENTINEL" ] && SEEN_VERSION="$(cat "$SENTINEL")" 2>/dev/null \
   && [ "$SEEN_VERSION" = "$SEED_VERSION" ]; then
  echo "🌱 seed: already seeded (v$SEEN_VERSION) — skipping copies/installers"
  exit 0
fi
if [ -f "$SENTINEL" ] && [ -z "${SEEN_VERSION:-}" ]; then
  echo "🌱 seed: migrating legacy unstamped sentinel to v$SEED_VERSION"
fi
echo "🌱 seed: seeding to v$SEED_VERSION"

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
# The named-volume mountpoint already exists, so seed it only while it is empty.
if [ -d "$SEED_DOTFILES" ] &&
   [ -z "$(find "$HOME/.dotfiles" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  cp -a "$SEED_DOTFILES/." "$HOME/.dotfiles/"
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

# 5. Stamp the sentinel with the current version.
printf '%s\n' "$SEED_VERSION" >"$SENTINEL"
echo "🌱 seed: done (v$SEED_VERSION)"
```

The sentinel now stores a version number rather than being a bare touch-file. The always-run block (ownership + Vekil hook) executes before the gate, so hook changes land on the next container start; the gated copy/install steps re-run whenever the sentinel does not record the current `SEED_VERSION`, even on a persisted named volume that survives `--remove-existing-container`. A legacy bare sentinel (empty file) predates versioning and cannot prove it ran the versioned steps, so it is *not* treated as current: it migrates once through the gated steps and is then stamped, after which the gate is a plain version match. That one extra reseed is idempotent — the copies overwrite with the same authored config and the installers are re-entrant.

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
1. Run `docker compose -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml config` from the project root. Compose will print the merged config or fail loudly on a typo. Check that the service name matches and that no host bind targets the container user's `~/.claude`, `~/.dotfiles`, or OpenCode directory. Unless the user opted into credential sharing, also confirm no host bind targets `~/.ssh` or `~/.config/gh` — an inherited base-file bind there must be shadowed with an empty named volume (Step 3), not left in the merged config.
2. Confirm the merged `command` contains `local-seed.sh` followed by the original foreground command.
3. Run `git check-ignore .devcontainer/docker-compose.override.yml .devcontainer/local-seed.sh`, then compare `git status --short` with the initial snapshot. They must match; if a new tracked devcontainer modification appears, report it without staging or reverting it.
4. After the user rebuilds, verify container-local files and read-only seed mounts:

```bash
docker compose exec {SERVICE} sh -c 'test "$(stat -c %u:%g /home/{USER}/.claude)" = "$(id -u):$(id -g)" && test "$(stat -c %u:%g /home/{USER}/.dotfiles)" = "$(id -u):$(id -g)"'
docker compose exec {SERVICE} sh -c 'test "$(cat /home/{USER}/.claude/.seeded)" = "{SEED_VERSION}"'
docker compose exec {SERVICE} grep -Fq 'ai/vekil/env.zsh' /home/{USER}/.zshrc   # Vekil hook present
docker compose exec {SERVICE} zsh -n /home/{USER}/.dotfiles/ai/vekil/env.zsh   # hook target exists + parses; no /readyz probe
docker compose exec {SERVICE} test -f /home/{USER}/.claude/settings.json
docker compose exec {SERVICE} test -f /home/{USER}/.codex/config.toml
docker compose exec {SERVICE} zsh -lic 'print "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -v codex'
docker compose exec {SERVICE} sh -c 'touch /host-seed/.claude/settings.json' # must fail read-only
docker compose exec {SERVICE} sh -c 'test -e /host-seed/.claude/.credentials.json' # must fail: not mounted
```

The `.seeded` line checks the sentinel's *content*, not just its existence — an
empty file is a legacy pre-versioning sentinel, and treating it as current is
exactly the bug the versioned gate fixes. On a volume that predates versioning,
verify the one-time migration instead: confirm the seed log printed
`migrating legacy unstamped sentinel`, then assert the same stamped value above.
Re-running the seed a second time must print `already seeded (v{SEED_VERSION})`.

The `grep` line asserts the seed wrote the Vekil hook into the container's
`~/.zshrc`; the `zsh -n` line validates the hook *target* alone — it exits
nonzero if `~/.dotfiles/ai/vekil/env.zsh` is missing (127) or malformed (1)
**without executing it**, so it never triggers the `/readyz` probe. That keeps
"is the hook well-formed" separate from "is the proxy up": the `zsh -lic` line
below is the combined hook-plus-readiness check, where an empty `OPENAI_BASE_URL`
means the target sourced but the readiness probe failed. If the grep
fails, the seed's always-run block didn't execute — check that the running
container isn't holding a stale pre-hook `local-seed.sh` (a persisted named
volume can keep an old sentinel; a version bump refreshes the gated steps, but
only once the on-disk seed script is the current template).

Empty endpoint variables or Codex resolving to the raw binary mean the
container-local zsh hook did not load or Vekil's `/readyz` probe failed.
Inspect the hook written by `local-seed.sh` and test the proxy readiness URL.
Do not edit a Dockerfile or baked rc, source all dotfiles by glob, or add a
shell-startup retry loop unless a readiness race has been reproduced.

5. If the devcontainer is currently running, tell the user "Rebuild Container" is required before these runtime checks.

Don't rebuild for them; that's their call.

## Things to avoid

- Don't mount Claude Code or dotfiles read-write from the host.
- Never edit a project Dockerfile, `devcontainer.json`, or base Compose file; they are evidence only. Keep every devcontainer customization in the gitignored override and seed script.
- Don't assume adding `/host-seed` mounts removes legacy binds from the base compose file; verify the merged config and shadow inherited targets with named volumes.
- Don't restore parallel `${HOME}:${HOME}` mounts to make absolute references resolve.
- Don't copy host plugin runtime state; reinstall the personal marketplace container-local.
- Don't add comments explaining each mount line — the file header covers the why, and per-line comments age badly when the list changes. Match the style of the user's existing override files.
- Don't promote the override into the base `docker-compose.yml`. The whole point of the override is that it's host-specific and stays out of the committed compose file (or is committed but understood as the local-dev overlay).
- Don't change the service name to `app` if the base compose uses something else. The override must target the real service.
