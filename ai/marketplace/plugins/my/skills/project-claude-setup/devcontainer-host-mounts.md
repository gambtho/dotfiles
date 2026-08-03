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

**Check the override is actually loaded.** Read the `dockerComposeFile` value in `devcontainer.json` and confirm `docker-compose.override.yml` is one of its entries. That value may be a single string or an array — read a string as a one-item list before concluding the override is missing. The Dev Containers CLI / VS Code only load the compose files named there — a sibling override that is *not* listed is silently ignored, so the seed never runs and `claude` never appears in the container. This is the single most common reason "the setup didn't work." If the override is missing from the array, do not just write the override and stop — resolve the listing first (see next paragraph).

**Resolving a missing override entry (asks the user).** Adding `docker-compose.override.yml` to `dockerComposeFile` requires editing the git-tracked `devcontainer.json`, which is otherwise off-limits. This is a sanctioned exception, but never silent: ask the user first. Present the trade-off — "The override won't load unless it's listed in `dockerComposeFile` in the tracked `.devcontainer/devcontainer.json`. I can add it there (one line), but that file is tracked and the change will show in `git status`; if this repo is a fork/OSS project, keep it as a local-only commit and don't push it upstream. Alternatively I can leave the file untouched and give you the line to add manually." If they approve the edit, add the override to the list (matching the existing style; if the current value is a plain string, convert it to an array of the original string plus the override) and flag it clearly in the final report as a tracked change. If they decline, write the override + seed as normal but tell them plainly it will NOT take effect until the entry is added, and hand them the exact edit.

Dockerfile, devcontainer.json, and base Compose files are inspection-only, with ONE sanctioned exception: adding the override to `dockerComposeFile` in `devcontainer.json` when the user has approved it (above). Nothing else in these files may be changed.

Never edit a project Dockerfile or a base Compose file. Never edit `devcontainer.json` except for the user-approved `dockerComposeFile` entry above — and never touch any other key in it.

The only permitted devcontainer writes are the gitignored `docker-compose.override.yml`, `local-seed.sh`, the user-approved `dockerComposeFile` entry in `devcontainer.json`, and `.git/info/exclude` entries needed for the two local files.

Capture the initial `git status --short` output before any write, **and a copy of the tracked `devcontainer.json` content** (e.g. `git show :.devcontainer/devcontainer.json` plus the working-tree file). Status alone is insufficient: if that file is already modified for unrelated reasons, a further unauthorized edit does not change its status line and would go undetected.

At final verification, run `git status --short` and compare its output byte-for-byte with the initial snapshot, **and diff `devcontainer.json` against the captured copy**. The only permitted content difference is the user-approved `dockerComposeFile` entry; any other tracked modification is reported without staging, reverting, or repairing it.

Report any new tracked devcontainer change without staging or reverting it.

## Step 2 — Discover the service name and container user

These values vary per project and must be filled in correctly, otherwise mounts or the seed command land in the wrong place.

**Service name.** Open `.devcontainer/docker-compose.yml`. The override must target the same top-level service. Most projects use `app`, but some name it after the project (e.g. `wanderer:` in the wanderer repo). Use whichever name appears under `services:` in the base compose file. If `devcontainer.json` has a `service:` key, that is authoritative.

**In-container user — the single most error-prone value in this skill.** Two DIFFERENT users are in play and confusing them is the classic failure:

- **The remoteUser** — the user VS Code opens terminals and runs the Claude extension as. **This is the ONLY user that matters for mount targets and the seed home.** Its `~/.zshrc` must get the Vekil hook; its `~/.claude` must get the config. Claude Code reads `$HOME/.claude` where `$HOME` is *this* user's home.
- **The seed-command user** — whoever the compose `command:` (which runs `local-seed.sh`) executes as. This is the image `Config.User`, and it is frequently **`root`** or a *different* user than the remoteUser. It is NOT authoritative for anything — the seed must write to the remoteUser's home explicitly, never its own `$HOME` (see "Seed runs as a possibly-different user" below).

**Resolve the remoteUser, in this order:**

1. **`remoteUser` in `.devcontainer/devcontainer.json`** if set — this is what VS Code honors, so it is authoritative for the terminal/extension user. Verify it exists in the built image's passwd (a stale `remoteUser` pointing at a user a feature removed is a bug).
2. **Read the VS Code-launched container directly** (NOT a container you spun up by hand — see the multi-container trap below):
   ```bash
   # find the container the Dev Containers CLI / VS Code started FOR THIS
   # WORKSPACE — the label records the host folder, so filter on it rather than
   # taking whatever devcontainer happens to be running first.
   #
   # `devcontainer.local_folder` records the path as the CLIENT saw it. Under
   # Windows+WSL that is a UNC path (\\wsl.localhost\Ubuntu\home\you\proj), so
   # matching a POSIX $PWD finds nothing on a container that is running fine.
   # devcontainer.config_file and the compose working_dir label are always
   # POSIX — try them before giving up.
   devcontainer_cid() {
     # $1 workspace folder (default $PWD); $2 optional service name override.
     local d="${1:-$PWD}" svc="${2:-}" cfg wd cid
     cfg="$d/.devcontainer/devcontainer.json"
     [ -f "$cfg" ] || cfg="$d/devcontainer.json"
     # Compose working_dir is the dir holding the FIRST dockerComposeFile, which is
     # not always <root>/.devcontainer — nested and root-level layouts both exist.
     wd="$(dirname "$cfg")"
     if command -v jq >/dev/null 2>&1 && [ -f "$cfg" ]; then
       local first
       first="$(sed 's://.*::' "$cfg" | jq -r '
         (.dockerComposeFile // empty) | if type=="array" then .[0] else . end' \
         2>/dev/null)"
       [ -n "$first" ] && [ "$first" != null ] \
         && wd="$(cd "$(dirname "$cfg")" && cd "$(dirname "$first")" && pwd)"
       [ -n "$svc" ] || svc="$(sed 's://.*::' "$cfg" | jq -r '.service // empty' 2>/dev/null)"
     fi
     # local_folder first: exact and unambiguous when it matches. It records the
     # path as the CLIENT saw it, so under Windows+WSL it is a UNC path and a POSIX
     # $PWD never matches — hence the POSIX fallbacks below.
     cid="$(docker ps -q --filter "label=devcontainer.local_folder=$d")"
     [ -z "$cid" ] && cid="$(docker ps -q --filter "label=devcontainer.config_file=$cfg")"
     if [ -z "$cid" ]; then
       # working_dir alone matches EVERY service in the project — the app container
       # AND every sidecar (postgres, redis). Without an exact service filter this
       # returns several IDs and the caller's one-ID guard aborts on a healthy
       # setup. Require the service; if devcontainer.json does not name one, say so
       # rather than guessing which sidecar is the dev container.
       if [ -z "$svc" ]; then
         echo "devcontainer_cid: no 'service' in $cfg — pass it as \$2" >&2
         return 1
       fi
       cid="$(docker ps -q \
         --filter "label=com.docker.compose.project.working_dir=$wd" \
         --filter "label=com.docker.compose.service=$svc")"
     fi
     printf '%s' "$cid"
   }
   CID="$(devcontainer_cid)"
   [ -n "$CID" ] || { docker ps --filter label=devcontainer.local_folder \
     --format '{{.ID}}\t{{.Names}}\t{{.Label "devcontainer.local_folder"}}'
     echo "no devcontainer for $PWD — pick the matching ID above"; exit 1; }
   [ "$(printf '%s\n' "$CID" | wc -l)" -eq 1 ] \
     || { echo "multiple containers for $PWD; disambiguate manually"; exit 1; }
   # the configured remoteUser, if devcontainer.json sets one:
   REMOTE_USER="$(jq -r '.remoteUser // empty' .devcontainer/devcontainer.json 2>/dev/null)"
   # else the container's own login user — NEVER uid 1000, and NEVER
   # `docker inspect .Config.User` (that is the seed-command user, often root):
   [ -n "$REMOTE_USER" ] || REMOTE_USER="$(docker exec "$CID" sh -c 'id -un')"
   # confirm it is a real passwd user and take its home from passwd field 6.
   # Pass the name as a positional arg, never interpolated into the sh -c text,
   # so a devcontainer.json value cannot inject shell:
   REMOTE_HOME="$(docker exec "$CID" sh -c 'getent passwd "$1" | cut -d: -f6' _ "$REMOTE_USER")"
   [ -n "$REMOTE_HOME" ] || { echo "remoteUser '$REMOTE_USER' not in container passwd"; exit 1; }
   echo "container=$CID user=$REMOTE_USER home=$REMOTE_HOME"
   ```
   **`$REMOTE_USER` and `$REMOTE_HOME` resolved here are the single source of truth** for every mount target, the seed's `SEED_USER`/`SEED_HOME`, and every verification command in Step 5. Do not re-derive either value later from uid 1000, from `.Config.User`, or by concatenating `/home/$REMOTE_USER` — images pin homes independently of the login name.
3. `USER` instruction in the Dockerfile (last one wins).
4. **Last resort, nothing built yet:** base image default from the table below — a guess to confirm on first `up`, not a fact.

| Base image | Default user (unverified guess) |
|---|---|
| `mcr.microsoft.com/devcontainers/javascript-node` | `node` (sometimes rebased to `vscode` by features — verify) |
| `mcr.microsoft.com/devcontainers/typescript-node` | `node` (sometimes rebased to `vscode` by features — verify) |
| `mcr.microsoft.com/devcontainers/base:ubuntu` (and most language variants) | `vscode` |
| `mcr.microsoft.com/devcontainers/universal` | `codespace` |
| Custom Dockerfile with no `USER` | `root` (warn — bind mounts will be owned by root) |

**The multi-container trap (this is what actually goes wrong).** Running `docker compose up` yourself to "inspect the container" creates a SEPARATE container from the one VS Code launched — and the two can resolve uid 1000 to different users (e.g. your manual `up` shows `vscode` while the VS Code container runs terminals as `node`). Every `docker exec` you then run inspects the wrong container, "confirms" the wrong user, and every test passes while the user's real terminal stays broken. **Do not create your own container to inspect.** Read the VS Code-launched one, or — most reliable of all — ask the user to run `id; echo $HOME` in their actual VS Code terminal and treat that as ground truth. `docker … exec zsh -lic` also forces a login shell that may differ from their terminal; the user's own prompt is authoritative.

**A directory existing at the guessed home proves nothing** — Docker materializes any missing bind/volume mount target as a root-owned directory, so `/home/vscode` can "exist" purely because a prior wrong mount created it, even when no `vscode` user exists in passwd. Confirm the home belongs to a real passwd user (`getent passwd <user> | cut -d: -f6`), not merely that the path is present. Config seeded into a home no shell uses as `$HOME` is invisible even though the seed logs success.

If you can't determine the remoteUser from any signal, ask. Do not guess between `vscode` / `node` / `developer` — getting it wrong silently mounts into a path the shell never visits.

**Workspace path.** Resolve `workspaceFolder` from `devcontainer.json`. If it is absent, inspect the base compose volume target. Do not assume `/workspace` or `/workspaces/<name>`.

**Base foreground command.** Read the base service's `command`. The override replaces this scalar, so the seed wrapper must `exec` the original foreground command after seeding. If the base command is `sleep infinity`, preserve that exact command.

**Seed runs as a possibly-different user — write to the remoteUser's home explicitly.** The compose `command:` that runs `local-seed.sh` executes as the image `Config.User`, which is often `root` or a user *other than* the remoteUser. Two consequences the seed must handle:

- **Never key the seed off its own `$HOME`.** When the seed runs as root, `$HOME` is `/root`; keying ownership repair, the `~/.zshrc` hook, or the config copy off `$HOME` writes to the wrong home and the remoteUser's terminal sees nothing. Use the `$REMOTE_USER` / `$REMOTE_HOME` pair resolved above (`SEED_USER=$REMOTE_USER`, `SEED_HOME=$REMOTE_HOME`) and resolve its uid/gid with `id -u "$REMOTE_USER"` / `id -g "$REMOTE_USER"`. Do **not** write `SEED_HOME=/home/<remoteUser>`: the passwd home is the only correct value, and it is frequently not `/home/<name>` (e.g. `root` → `/root`, or an image that pins `/home/node` for a user named `vscode`).
- **Do all writes as the remoteUser and chown to it.** If the seed runs as root, use `runuser -u <remoteUser> -- <cmd>` (or `chown -R <uid>:<gid>` after writing) so every seeded file is owned by the remoteUser. If the seed runs as a non-root user that differs from the remoteUser, it needs passwordless `sudo` to chown/write into the remoteUser's home — confirm the image provides it (`sudo -n true`), and if not, stop and report the setup as unsupported rather than seeding into the wrong home. When the seed user IS the remoteUser and is non-root, the original sudo-chown approach applies. Root seed users need no sudo. Inspect the Dockerfile only; never add users, packages, or sudo config to it.

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
claude-local-home       →  {REMOTE_HOME}/.claude              named volume
dotfiles-local-home     →  {REMOTE_HOME}/.dotfiles            named volume
```

`{REMOTE_HOME}` is the passwd home resolved in Step 2 — used verbatim, never rebuilt as `/home/{USER}`. The template below writes `/home/{USER}` because that is the common case; substitute the real `$REMOTE_HOME` whenever it differs (`/root` for a root remoteUser, or any image that pins a home unrelated to the login name). A named volume mounted at a path the login shell does not use as `$HOME` is invisible to Claude Code even though every mount and the seed log look healthy.

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

For the **optional** directory mounts above (`~/.ssh`, `~/.config/gh`, `~/.pi`,
project-specific dirs), a missing host directory is not a failure mode — Docker
creates an empty one at container start, which just means the tool isn't on the
host yet. Don't add `if`-checks or skip mounts on that basis.

The `/host-seed/.claude` allowlist is the exception, and it is not optional: check
each of the five sources with `test -e` while generating the override and emit only
the mounts whose sources exist. Docker materializes a missing bind source as a
*directory*, so an absent `settings.json` would appear in the container as an empty
directory and break the seed copy — and an absent `commands/` would silently shadow
nothing while looking mounted. Emitting all five unconditionally is a bug, not a
convenience.

## Step 4 — Write the local override and seed script

Write to the same directory as the base compose file (per Step 1). If the base is `.devcontainer/docker-compose.yml`, the override is `.devcontainer/docker-compose.override.yml`; if the base lives at the project root, the override lives at the project root too.

**The override only takes effect if it is listed in `dockerComposeFile` — file placement alone is NOT enough.** A bare `docker compose up` auto-merges a sibling `docker-compose.override.yml`, but the Dev Containers CLI and VS Code do not: they pass explicit `-f` flags for exactly the files named in the `dockerComposeFile` array and nothing else. So a sibling override is silently ignored under the real launch path. Step 1 must confirm the override is in that array; if it is not, see the "Ensure the override is loaded" step below before writing anything else.

Use this template, filling in `{SERVICE}`, `{USER}`, `{WORKSPACE}`, and `{BASE_COMMAND}` from Step 2, and `{SEED_SCRIPT}` from Step 1 — the container-visible path of the `local-seed.sh` written next to the base compose file, which is not always under `.devcontainer/`. **`{USER}` is `$REMOTE_USER`** (the terminal/extension user resolved in Step 2), which may differ from whoever the `command:` runs as. Every `/home/{USER}` path below is shorthand for `$REMOTE_HOME` — replace the whole prefix, not just the username, whenever the resolved passwd home is not `/home/$REMOTE_USER`. The mount targets and the seed's `SEED_HOME` must both be that exact home, or the config lands where the terminal never looks.

```yaml
# LOCAL, GITIGNORED. Claude and dotfiles are read-only seed sources. The seed
# script copies them container-local so container writes cannot reach the host.
services:
  {SERVICE}:
    volumes:
      # Emit only the allowlist entries whose host source exists (see Step 3):
      #   for p in settings.json CLAUDE.md config commands skills; do
      #     [ -e "$HOME/.claude/$p" ] && echo "      - ~/.claude/$p:/host-seed/.claude/$p:ro,cached"
      #   done
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
      bash -c "bash {SEED_SCRIPT}; exec {BASE_COMMAND}"
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

Write the seed script at `{SEED_SCRIPT}` (the `local-seed.sh` sibling of the base compose file, from Step 1 — same path the `command:` above executes) with:

```bash
#!/usr/bin/env bash
# Local-only devcontainer seed (gitignored). Copies the authored subset of the
# host ~/.claude into a CONTAINER-LOCAL ~/.claude so nothing the container writes
# can reach the host. The expensive copy/install steps are guarded by a
# versioned sentinel: bump SEED_VERSION whenever those steps change and existing
# containers re-run them on next start without a manual volume wipe.
#
# CRITICAL: this compose `command:` may run as root or as a user OTHER than the
# remoteUser whose terminal/extension actually use the seeded config. So this
# script does NOT use $HOME — it hardcodes the remoteUser's home (SEED_HOME,
# filled in from Step 2) and writes everything there, owned by that user. Keep
# SEED_USER / SEED_HOME in sync with the named-volume targets in the override.
set -euo pipefail

# Bump this whenever the gated steps below (copies, installers) change so
# already-seeded containers refresh instead of silently keeping stale state.
SEED_VERSION=8

# The remoteUser (Step 2) — the user VS Code opens terminals as and whose
# ~/.claude Claude Code reads. NOT necessarily the user running this script.
#
# Resolve BOTH values empirically and once. Do not assume uid 1000 is the
# remoteUser, and do not assume the home is /home/$SEED_USER: images pin homes
# like /home/node, /home/vscode, or /root independently of the name, and a
# guessed home seeds a directory the login shell never reads (mounts "work",
# seed logs success, Claude Code sees nothing). Every mount target and seed
# path below derives from SEED_HOME, so getting it wrong here is silent.
SEED_USER="{USER}"
SEED_HOME="$(getent passwd "$SEED_USER" | cut -d: -f6)"
if [ -z "$SEED_HOME" ]; then
  echo "❌ seed: cannot resolve passwd home for '$SEED_USER' — refusing to guess" >&2
  exit 1
fi
SEED_UID="$(id -u "$SEED_USER")"
SEED_GID="$(id -g "$SEED_USER")"

SEED_CLAUDE="/host-seed/.claude"
SEED_DOTFILES="/host-seed/.dotfiles"
CLAUDE_HOME="$SEED_HOME/.claude"
DOTFILES_HOME="$SEED_HOME/.dotfiles"
SENTINEL="$CLAUDE_HOME/.seeded"

# Stable root for personal overlay symlinks (see the block that creates it).
# Constant in production; DOTFILES_LINK_ROOT is a test-only override, and it is
# the same variable bin/common.sh honours, so both branches below agree.
STABLE_LINK_ROOT="${DOTFILES_LINK_ROOT:-/opt/dotfiles}"

# Run a command as the remoteUser regardless of who this script runs as. If the
# script runs as root, `runuser` needs no password; if it runs as a non-root
# user that differs from SEED_USER, prefix with sudo (confirmed available in
# Step 2). If the script already runs AS SEED_USER, this still works.
if [ "$(id -u)" -eq 0 ]; then
  as_user() { runuser -u "$SEED_USER" -- "$@"; }
  SUDO=""
elif [ "$(id -un)" = "$SEED_USER" ]; then
  as_user() { "$@"; }
  SUDO="sudo"
else
  as_user() { sudo -u "$SEED_USER" -- "$@"; }
  SUDO="sudo"
fi

# --- Always-run block (before the sentinel) --------------------------------
# Everything here runs on EVERY launch, even when the sentinel is current, so it
# survives a rebuild that wiped the ephemeral writable layer. This covers:
# ownership repair, the Vekil zsh hook, the ~/.local/bin PATH entry, the
# default-shell switch, the dotfiles refresh, and the claude/codex installs —
# because all of those targets are either re-derived cheaply or live in the
# ephemeral layer, NOT the persisted named volume the sentinel guards.

# Named-volume mountpoints can start as root:root. Repair them to the remoteUser
# every launch. mkdir first: on a fresh volume the home subdirs may not exist yet.
echo "🌱 seed: repairing container-local volume ownership ($SEED_HOME)"
$SUDO mkdir -p "$CLAUDE_HOME" "$DOTFILES_HOME"
$SUDO chown -R "$SEED_UID:$SEED_GID" "$CLAUDE_HOME" "$DOTFILES_HOME"

# Load Vekil's endpoint variables and managed Codex wrapper in container zsh
# sessions. Write into the remoteUser's ~/.zshrc so their terminal sources it.
# Keep this before the sentinel so existing volumes gain the hook.
VEKIL_ENV_HOOK='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
ZSHRC="$SEED_HOME/.zshrc"

$SUDO touch "$ZSHRC"

# Source the mirrored dotfiles via their own entry point, so container shells
# get the same aliases, PATH, and EDITOR fallback as the host. This belongs in
# the seed rather than the tracked Dockerfile: it is only meaningful alongside
# the ~/.dotfiles mount from the (gitignored) override, and a teammate without
# that mount would just carry dead code.
#
# load-custom.zsh is the supported entry point and sources core/, languages/,
# tools/, platforms/ and the profile itself. Do NOT glob `$DOTFILES/**/*.zsh`:
# that glob also matches load-custom.zsh, so the whole tree loads twice —
# aliases redefined, PATH entries duplicated. It also prints a stray
# `file=/…/load-custom.zsh` line before every prompt, because the loop leaves
# $file set and load-custom.zsh re-declares it via `typeset`, which echoes
# name=value when TYPESET_SILENT is off (zsh's default).
#
# It must land BEFORE the Vekil hook: ai/vekil/env.zsh owns the endpoint/model
# variables and has to get the last word, but core/ (which load-custom.zsh
# sources) also sets some of them. Appending is only correct on a FRESH zshrc,
# where the Vekil block below has not run yet. Two other states exist on an
# already-seeded volume, which is exactly the upgrade path this block serves:
# the Vekil hook present and this one absent (appending would land after it),
# and — left behind by every seed older than this one — BOTH present in the
# wrong order. Checking only for our own hook's presence declares that second
# state fixed and latches the inverted precedence forever.
#
# So compare positions, and let one awk cover both repairs: it drops any
# existing copy wherever it sits, then re-emits it above the Vekil line.
DOTFILES_LOAD_HOOK='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'
# Count, don't just locate. The first match's position says nothing about copies
# below it, so a zshrc holding two hooks — one correctly placed — reads as
# already-correct and the tree sources twice forever, which is the duplicate-
# alias/duplicate-PATH failure this hook exists to avoid.
# `|| true`: under `set -o pipefail` a non-matching grep would abort the seed.
load_n="$(grep -Fxc "$DOTFILES_LOAD_HOOK" "$ZSHRC" 2>/dev/null || true)"
load_at="$(grep -Fxn "$DOTFILES_LOAD_HOOK" "$ZSHRC" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
vekil_at="$(grep -Fxn "$VEKIL_ENV_HOOK" "$ZSHRC" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
if [ "${load_n:-0}" -gt 1 ] \
  || { [ -n "$vekil_at" ] && { [ "${load_n:-0}" -eq 0 ] || [ "$load_at" -gt "$vekil_at" ]; }; }; then
  ZSHRC_TMP="$(mktemp)"
  # Exact line match on the whole hook, not a substring: awk -v takes the
  # value literally and neither hook contains a backslash. Dropping every copy
  # before re-emitting one is what makes both the reorder and the de-duplicate
  # path converge on the same single correctly-placed line; the END clause
  # covers de-duplicating a zshrc that has no Vekil hook to anchor against.
  awk -v hook="$DOTFILES_LOAD_HOOK" -v vekil="$VEKIL_ENV_HOOK" '
    $0 == hook { next }
    $0 == vekil && !ins { print hook; print ""; ins = 1 }
    { print }
    END { if (!ins) print hook }
  ' "$ZSHRC" >"$ZSHRC_TMP"
  # cp, not mv: writing through the existing path keeps the file's owner and
  # mode, which matter because the terminal user may not be the seed user.
  $SUDO cp "$ZSHRC_TMP" "$ZSHRC"
  rm -f "$ZSHRC_TMP"
  echo "🌱 seed: configured dotfiles shell integration"
elif [ "${load_n:-0}" -eq 0 ]; then
  # No Vekil hook yet — its own block below appends after this one, so a plain
  # append already lands in the right order.
  printf '\n%s\n' "$DOTFILES_LOAD_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: configured dotfiles shell integration"
fi

if ! grep -Fqx "$VEKIL_ENV_HOOK" "$ZSHRC" 2>/dev/null; then
  printf '\n%s\n' "$VEKIL_ENV_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: configured Vekil shell integration"
fi

# The native Claude Code installer drops the binary in ~/.local/bin, which most
# base images do not have on PATH. Add it for interactive shells so `claude`
# resolves after the seed installs it. Kept in the always-run block so existing
# volumes gain the PATH entry without a full reseed.
LOCALBIN_HOOK='[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"'
if ! grep -Fqx "$LOCALBIN_HOOK" "$ZSHRC" 2>/dev/null; then
  printf '%s\n' "$LOCALBIN_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: added ~/.local/bin to PATH"
fi
$SUDO chown "$SEED_UID:$SEED_GID" "$ZSHRC"

# Vekil's shell integration (env.zsh, sourced above) is zsh-only, and it is what
# points claude and codex at the proxy (ANTHROPIC_BASE_URL / OPENAI_BASE_URL). If
# the remoteUser's default shell is bash, an interactive terminal never sources
# env.zsh, so claude launched from it misses the proxy entirely — the classic
# "claude isn't picking up the vekil proxy" symptom. Make zsh the remoteUser's
# login shell so terminals inherit the proxy env. /etc/passwd lives in the
# writable layer and is reset on rebuild, so this re-applies every launch (kept in
# the always-run block, not the gate). This is FATAL, not best-effort: a quiet
# skip leaves a bash login shell that silently bypasses the proxy, which is the
# exact symptom this block exists to prevent. The fix belongs to the user (a base
# image with zsh, or an override that installs it), so fail loudly and say so.
if ! command -v zsh >/dev/null 2>&1; then
  echo "❌ seed: zsh not found — Vekil's env.zsh is zsh-only, so the proxy" >&2
  echo "   would be silently bypassed. Install zsh in the image/override." >&2
  exit 1
fi
ZSH_PATH="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "$SEED_USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "$ZSH_PATH" ]; then
  if command -v chsh >/dev/null 2>&1 && $SUDO chsh -s "$ZSH_PATH" "$SEED_USER" >/dev/null 2>&1; then
    echo "🌱 seed: set $SEED_USER default shell to zsh"
  elif { [ -w /etc/passwd ] || [ "$(id -u)" -eq 0 ]; } \
    && $SUDO sed -i "s#^\($SEED_USER:.*:\)[^:]*\$#\1$ZSH_PATH#" /etc/passwd; then
    echo "🌱 seed: set $SEED_USER default shell to zsh (via /etc/passwd)"
  else
    echo "❌ seed: could not set $SEED_USER's login shell to zsh — neither chsh" >&2
    echo "   nor a writable /etc/passwd is available. Terminals would open bash" >&2
    echo "   and bypass the Vekil proxy." >&2
    exit 1
  fi
fi

# Git excludes for the personal overlay. The overlay's import shims and personal
# settings are kept out of git by the HOST's global core.excludesFile — but that
# config never reaches the container, so without this the shims show as untracked
# in the container's `git status`. Seed a container-local ~/.gitignore for the
# remoteUser and point core.excludesFile at it. Always-run block: git config
# lives in the ephemeral layer and resets on rebuild.
#
# ONLY list personal-overlay artifacts. Do NOT ignore CLAUDE.md or .claude/
# wholesale like the host ~/.gitignore does — inside a project checkout those are
# frequently REAL tracked files (many public and private repos commit their own
# CLAUDE.md and .claude/ contents), and a blanket ignore would hide them from
# `git status` and `git add`. The host can afford the broad patterns because its
# overlay files are personal symlinks; the container cannot.
GITIGNORE="$SEED_HOME/.gitignore"
if ! as_user test -f "$GITIGNORE"; then
  as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*~
*.swp

# Personal Claude Code overlay shims (symlinked in from ~/.dotfiles/projects/).
CLAUDE.local.md
AGENTS.local.md
.claude/settings.local.json
**/.claude/settings.local.json

# Personal docker-compose overrides.
docker-compose.override.yml
docker-compose.override.yaml
GITEOF
  echo "🌱 seed: wrote container-local ~/.gitignore"
fi
as_user git config --global core.excludesFile "$GITIGNORE"

# Personal overlay files can also live INSIDE .claude/ as symlinks pointing into
# ~/.dotfiles/projects/ (e.g. .claude/agents/<name>.md, .claude/commands/...). We
# can't blanket-ignore .claude/ (it holds real tracked project files), and the
# set changes as the overlay grows, so discover the exact overlay symlinks each
# launch and maintain them in a marked, rewritten section of ~/.gitignore. Match
# by the symlink's target TEXT (find -lname), which works in the container even
# though the /home/<host-user>/... target is unresolvable here. The pattern is
# deliberately NOT '*/.dotfiles/projects/*': links created after the stable-root
# change target /opt/dotfiles/projects/... with no leading dot, and missing them
# puts personal overlay files — CLAUDE.md included — into container git status.
# {WORKSPACE} is the workspaceFolder from Step 2. Repo-relative paths.
WORKSPACE="{WORKSPACE}"
GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# <<< overlay symlinks (auto) <<<"
if [ -d "$WORKSPACE" ]; then
  overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*dotfiles/projects/*' \
    -not -path './node_modules/*' 2>/dev/null | sed 's#^\./##' | sort)"
  # Rewrite the marked block: strip any existing one, then append the current set.
  new_gitignore="$(as_user sed "/^${GI_MARK_BEGIN}$/,/^${GI_MARK_END}$/d" "$GITIGNORE")"
  {
    printf '%s\n' "$new_gitignore"
    printf '%s\n' "$GI_MARK_BEGIN"
    [ -n "$overlay_links" ] && printf '%s\n' "$overlay_links"
    printf '%s\n' "$GI_MARK_END"
  } | as_user tee "$GITIGNORE" >/dev/null
  n="$(printf '%s' "$overlay_links" | grep -c . || true)"
  echo "🌱 seed: refreshed ~/.gitignore overlay-symlink list ($n entries)"
fi

# Refresh dotfiles container-local, then install the tools whose targets live in
# the EPHEMERAL writable layer (claude → ~/.local/bin, codex → ~/.codex). All
# three are in the ALWAYS-RUN block, NOT the versioned gate, for one reason: the
# sentinel lives in the persisted claude-local-home named volume, but these
# targets are wiped on every rebuild. If they were gated, a rebuild would keep
# the old sentinel, the gate would exit "already seeded," and the container would
# come up with NO claude binary and NO codex config — the "claude is missing /
# not using the proxy after rebuild" bug. Guards (command -v / file presence)
# keep warm restarts cheap: only a genuinely absent tool reinstalls.
#
# Every step runs as the remoteUser via as_user so files land owned by them, not
# by root/the seed user. Dotfiles first, because the installers live under
# ~/.dotfiles. rsync -a --delete makes the container tree an EXACT mirror of the
# read-only host seed — files removed upstream are pruned, not left stale (the
# named volume persists across rebuilds, so without --delete a deleted path
# lingers until a manual wipe). Fall back to cp -a where rsync is absent.
if [ -d "$SEED_DOTFILES" ]; then
  if command -v rsync >/dev/null 2>&1; then
    # -c checksums instead of the default size+mtime quick check. The quick
    # check compares mtime at 1-second resolution, so a same-size edit made
    # within a second of the previous sync is skipped -- silently, and this
    # tree decides the model. 40M of unchanged files hashes fast enough that
    # correctness is the better trade here.
    as_user rsync -ac --delete "$SEED_DOTFILES/" "$DOTFILES_HOME/"
    echo "🌱 seed: mirrored ~/.dotfiles via rsync ($(du -sh "$DOTFILES_HOME" | cut -f1))"
  else
    # No non-pruning fallback. DOTFILES_HOME persists across rebuilds and the
    # always-run installers below EXECUTE files from it, so a stale installer
    # deleted upstream would keep running. Wipe-then-copy prunes equivalently.
    as_user find "$DOTFILES_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    as_user cp -a "$SEED_DOTFILES/." "$DOTFILES_HOME/"
    echo "🌱 seed: rebuilt ~/.dotfiles via wipe+cp (no rsync) ($(du -sh "$DOTFILES_HOME" | cut -f1))"
  fi
fi

# Stable link root: /opt/dotfiles -> this container's dotfiles checkout.
#
# Personal overlay symlinks in the workspace (.claude/skills, .claude/agents,
# CLAUDE.md, ...) are bind-mounted from the host and store an ABSOLUTE target.
# Written as /home/<host-user>/.dotfiles/... they dangle here, because this
# container has a different $HOME — that is the "devcontainer can't see the
# project skills" bug, and it silently takes out CLAUDE.md too. They are now
# written as /opt/dotfiles/projects/..., which each environment points at its
# own checkout. The host side is established by ~/.dotfiles/bin/relink; this is
# the container side. Both sides stay writable and independent: this root
# resolves into the dotfiles named volume, so container writes never reach the
# host.
#
# ALWAYS-RUN, never gated: /opt lives in the ephemeral writable layer and is
# wiped by every rebuild, while the sentinel persists in a named volume. Gating
# it would leave a rebuilt container reporting "already seeded" with every
# overlay link dangling. Must come after the mirror above — the helper refuses
# a target that is not a directory.
#
# The mirrored dotfiles own the root path so it is defined once; the literal
# fallback keeps this seed working against a checkout predating the helper.
if [ -r "$DOTFILES_HOME/bin/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/bin/common.sh"
fi
if command -v ensure_stable_link_root >/dev/null 2>&1; then
  ensure_stable_link_root "$DOTFILES_HOME"
elif [ -e "$STABLE_LINK_ROOT" ] && [ ! -L "$STABLE_LINK_ROOT" ]; then
  # Same guard the helper applies: a real file or directory there is somebody
  # else's, and `ln -sfn` would either fail obscurely or plant the link inside
  # it. Say what to do instead of reporting a generic creation failure.
  echo "⚠️  seed: $STABLE_LINK_ROOT exists and is not a symlink — move it aside" >&2
  echo "   and restart; overlay links will dangle in this container until then." >&2
elif $SUDO mkdir -p "$(dirname "$STABLE_LINK_ROOT")" \
  && $SUDO ln -sfn "$DOTFILES_HOME" "$STABLE_LINK_ROOT"; then
  echo "🌱 seed: $STABLE_LINK_ROOT -> $DOTFILES_HOME (literal fallback)"
else
  # Non-fatal, and deliberately so: overlay links then keep their
  # $HOME-absolute targets, which is the pre-existing behaviour rather than a
  # regression. Taking the container down over it would be worse.
  echo "⚠️  seed: could not create $STABLE_LINK_ROOT — personal overlay links" >&2
  echo "   (.claude/skills, CLAUDE.md, ...) will dangle in this container." >&2
fi

# Managed global git hooks — most importantly commit-msg, which strips
# Co-authored-by trailers from locally-authored commits. On the host these are
# installed by symlinking ~/.git-hooks -> ~/.dotfiles/core/git/git-hooks.symlink,
# but that symlink is never seeded into the container. Point core.hooksPath
# straight at the mirrored dotfiles copy instead: no symlink to maintain, and it
# follows the repo automatically on every refresh.
#
# MUST come after the ~/.dotfiles mirror above — the hooks only exist once that
# has run. Always-run block: git config lives in the ephemeral layer and resets
# on rebuild, same as core.excludesFile.
#
# Non-fatal, unlike the Vekil proxy steps: a missing hook costs one commit
# trailer rather than silently routing traffic off-proxy. Warn, don't exit.
HOOKS_DIR="$DOTFILES_HOME/core/git/git-hooks.symlink"
if as_user test -x "$HOOKS_DIR/commit-msg"; then
  as_user git config --global core.hooksPath "$HOOKS_DIR"
  echo "🌱 seed: pointed core.hooksPath at $HOOKS_DIR"
else
  echo "⚠️  seed: $HOOKS_DIR/commit-msg missing or not executable — global git" >&2
  echo "   hooks not configured; Co-authored-by trailers will not be stripped." >&2
fi

# Claude CLI binary (ephemeral target). Run as the remoteUser via a login shell
# so the installer sees their PATH and installs into their home.
# Probe the concrete install path, NOT `bash -lc command -v`: the PATH entry for
# ~/.local/bin is added to ~/.zshrc, which a bash login shell never sources, so
# the PATH probe misses an existing binary and reinstalls on every warm restart.
#
# SUPPLY CHAIN: the default path sets ALLOW_REMOTE_INSTALLERS=1, which opts past
# the dotfiles guard and fetches https://claude.ai/install.sh UNPINNED — a
# rebuild executes whatever upstream currently serves. That is accepted here
# because the seed only ever runs against the user's own devcontainer (see
# SKILL.md rule #12). A project that needs supply-chain pinning sets
# CLAUDE_CLI_INSTALL_CMD (via the override's `environment:`) to a command that
# installs a pinned, checksum-verified artifact into $SEED_HOME/.local/bin; the
# remote installer is then never invoked. Note `ai/claude/install.sh` itself has
# no version/checksum support — the pinned artifact must come from the project.
if as_user test -x "$SEED_HOME/.local/bin/claude" || as_user bash -lc 'command -v claude >/dev/null 2>&1'; then
  echo "🌱 seed: claude already installed for $SEED_USER — skipping CLI install"
elif [ -n "${CLAUDE_CLI_INSTALL_CMD:-}" ]; then
  echo "🌱 seed: installing Claude Code CLI via pinned CLAUDE_CLI_INSTALL_CMD"
  as_user bash -lc "$CLAUDE_CLI_INSTALL_CMD" \
    || echo "⚠️  seed: pinned claude CLI install failed (non-fatal)"
elif [ -x "$DOTFILES_HOME/ai/claude/install.sh" ]; then
  echo "🌱 seed: installing Claude Code CLI (unpinned upstream installer)"
  as_user env ALLOW_REMOTE_INSTALLERS=1 bash "$DOTFILES_HOME/ai/claude/install.sh" || echo "⚠️  seed: claude CLI install failed (non-fatal)"
fi

# Codex config (ephemeral target ~/.codex).
#
# Guard on the BINARY, not the config. Both ~/.codex/config.toml and
# ~/.local/bin live in the ephemeral layer, but the installer writes config even
# when it cannot produce a binary (it treats a missing CLI as a soft skip).
# Testing config.toml therefore latches: config present, `codex` missing, and
# the installer skipped on every subsequent start.
if as_user test -x "$SEED_HOME/.local/bin/codex"; then
  echo "🌱 seed: codex already present"
elif [ -x "$DOTFILES_HOME/ai/codex/install.sh" ]; then
  echo "🌱 seed: linking Codex config"
  as_user bash "$DOTFILES_HOME/ai/codex/install.sh" || echo "⚠️  seed: codex install failed (non-fatal)"
fi

# Neovim (ephemeral target ~/.local). The dotfiles set EDITOR=nvim and ship
# config/nvim, but nothing in them installs the binary — on a normal host it
# arrives via the apt/brew package lists, which a devcontainer image never runs.
# An EDITOR pointing at a missing command breaks `git commit` and
# `git rebase -i` with an error that names git, not the editor. (core/env.zsh
# falls back to vim, so this is the intended editor rather than a hard
# requirement — hence non-fatal throughout.)
#
# Not apt: Debian bookworm ships 0.7.2 and config/nvim uses vim.uv + lazy.nvim,
# which need 0.10+. Not the Dockerfile either: this is a personal-dotfiles
# requirement, so it belongs with the mount that enables it. Version and
# checksums come from the mirrored config/versions.env, so the download is
# pinned and verified — unlike the claude CLI path above.
# `-f` as well as `-x`: both follow symlinks, so the normal shape (bin/nvim ->
# nvim-dist/bin/nvim) still passes, while a directory — which `-x` alone reports
# as executable — no longer counts as "already installed" and silently skips.
if as_user test -f "$SEED_HOME/.local/bin/nvim" && as_user test -x "$SEED_HOME/.local/bin/nvim"; then
  echo "🌱 seed: nvim already present"
elif [ -r "$DOTFILES_HOME/config/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/config/versions.env"
  case "$(uname -m)" in
    x86_64) NVIM_ARCH=linux-x86_64 NVIM_SHA="${NVIM_SHA256_X86_64:-}" ;;
    aarch64 | arm64) NVIM_ARCH=linux-arm64 NVIM_SHA="${NVIM_SHA256_ARM64:-}" ;;
    *) NVIM_ARCH="" ;;
  esac
  if [ -z "$NVIM_ARCH" ]; then
    echo "⚠️  seed: no neovim build for $(uname -m) — skipping (EDITOR falls back to vim)"
  else
    echo "🌱 seed: installing neovim $NVIM_VERSION ($NVIM_ARCH)"
    NVIM_TMP="$(mktemp -d)"
    NVIM_URL="https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-${NVIM_ARCH}.tar.gz"
    # Every step is inside the `if` condition, so a failure anywhere falls
    # through to the non-fatal message instead of killing the seed under
    # `set -e` — an optional editor must never cost the container its start.
    # Deployment is part of the chain rather than a trailing block: an unchecked
    # mv/ln can leave ~/.local/bin/nvim dangling while "neovim ready" prints,
    # and a dangling EDITOR fails `git commit` with an error naming git.
    #
    # Timeouts are bounded for the same reason. curl's default is no timeout at
    # all, so a blackholed connection to the release CDN hangs the seed forever
    # and the container never finishes starting.
    #
    # The whole tree ships, not just the binary: nvim needs its runtime/ share
    # dir, so symlinking the bare binary gives an nvim that starts and then
    # cannot find its own runtime files.
    #
    # Staged into nvim-dist.new and validated there before the existing runtime
    # is touched. Removing nvim-dist first would destroy a working editor to
    # make room for a download that may not survive the checksum or the chown —
    # reachable whenever bin/nvim is missing or broken but the tree beneath it
    # is fine, which is precisely when this branch runs on a warm container.
    #
    # The chown must land or the tree must already belong to the seed user: a
    # runtime the remoteUser cannot write is one lazy.nvim cannot update, and
    # `test -x` alone would happily accept it.
    NVIM_DIST="$SEED_HOME/.local/share/nvim-dist"
    if curl -fsSL --connect-timeout 10 --max-time 300 \
      -o "$NVIM_TMP/nvim.tar.gz" "$NVIM_URL" \
      && echo "$NVIM_SHA  $NVIM_TMP/nvim.tar.gz" | sha256sum -c - >/dev/null 2>&1 \
      && tar -xzf "$NVIM_TMP/nvim.tar.gz" -C "$NVIM_TMP" \
      && [ -d "$NVIM_TMP/nvim-$NVIM_ARCH" ] \
      && as_user mkdir -p "$SEED_HOME/.local/share" "$SEED_HOME/.local/bin" \
      && as_user rm -rf "$NVIM_DIST.new" \
      && mv "$NVIM_TMP/nvim-$NVIM_ARCH" "$NVIM_DIST.new" \
      && { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null \
        || [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } \
      && as_user test -x "$NVIM_DIST.new/bin/nvim" \
      && as_user rm -rf "$NVIM_DIST" \
      && mv "$NVIM_DIST.new" "$NVIM_DIST" \
      && as_user ln -sf "$NVIM_DIST/bin/nvim" "$SEED_HOME/.local/bin/nvim" \
      && as_user test -x "$SEED_HOME/.local/bin/nvim"; then
      echo "🌱 seed: neovim ready"
    else
      echo "⚠️  seed: neovim install failed (non-fatal; EDITOR falls back to vim)"
    fi
    as_user rm -rf "$NVIM_DIST.new"
    rm -rf "$NVIM_TMP"
  fi
fi

# Point nvim at the mirrored dotfiles config, the way the host install does.
# Without this the binary starts bare and none of config/nvim applies.
# Always-run: ~/.config is in the ephemeral layer. Replaced unconditionally when
# it is a symlink, but a real directory is left alone — that would be someone's
# own container-local config, and clobbering it is not this script's call.
if [ -d "$DOTFILES_HOME/config/nvim" ]; then
  as_user mkdir -p "$SEED_HOME/.config"
  if as_user test -L "$SEED_HOME/.config/nvim" || ! as_user test -e "$SEED_HOME/.config/nvim"; then
    as_user ln -sfn "$DOTFILES_HOME/config/nvim" "$SEED_HOME/.config/nvim"
    echo "🌱 seed: linked ~/.config/nvim to dotfiles"
  else
    echo "⚠️  seed: ~/.config/nvim is a real directory — leaving it alone"
  fi
fi

# tree-sitter CLI (ephemeral target ~/.local/bin). config/nvim pins
# nvim-treesitter to its `main` branch, whose installer shells out to
# `tree-sitter build` for EVERY parser — there is no fallback to a bare `cc`, so
# a container with gcc but no CLI still fails every parser with
# `Error during "tree-sitter build": ... ENOENT ... (cmd): 'tree-sitter'`, on the
# bootstrap set (bash, c, lua, markdown, vimdoc, ...) at the first nvim launch.
# On a host the CLI arrives from mise (`npm:tree-sitter-cli` in
# config/mise/config.toml); the seed never runs mise, so it is supplied here as a
# pinned release binary. Keep TREE_SITTER_VERSION in step with the mise pin.
#
# Always-run for the same reason as nvim: ~/.local/bin is the ephemeral writable
# layer, so a version-gated step would be skipped as "already seeded" and the
# binary would be gone after every rebuild.
#
# Non-fatal throughout, like nvim: treesitter highlighting is a nicety, and an
# editor that opens without it beats a container that will not start.
#
# Two guards, in this order, and the order matters. `command -v` alone is NOT
# enough: the seed runs as a container `command:`, whose PATH does not include
# ~/.local/bin, so on every warm start our own installed binary would look
# missing and be re-downloaded (26MB) each launch. The path test is the
# PATH-independent guard for what this block installed; the `command -v` probe
# only catches a CLI the image itself supplies somewhere else on PATH.
if as_user test -f "$SEED_HOME/.local/bin/tree-sitter" \
  && as_user test -x "$SEED_HOME/.local/bin/tree-sitter"; then
  echo "🌱 seed: tree-sitter already present"
elif as_user sh -c 'command -v tree-sitter >/dev/null 2>&1'; then
  echo "🌱 seed: tree-sitter already present (image-provided)"
elif [ -r "$DOTFILES_HOME/config/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/config/versions.env"
  case "$(uname -m)" in
    x86_64) TS_ARCH=linux-x64 TS_SHA="${TREE_SITTER_SHA256_X86_64:-}" ;;
    aarch64 | arm64) TS_ARCH=linux-arm64 TS_SHA="${TREE_SITTER_SHA256_ARM64:-}" ;;
    *) TS_ARCH="" TS_SHA="" ;;
  esac
  # TS_SHA is checked here, not left to the verify step: an unpinned checksum
  # would otherwise cost a 26MB download before failing, every single start.
  if [ -z "$TS_ARCH" ] || [ -z "$TS_SHA" ] || [ -z "${TREE_SITTER_VERSION:-}" ]; then
    echo "⚠️  seed: no pinned tree-sitter build for $(uname -m) — skipping (treesitter parsers will not compile)"
  else
    echo "🌱 seed: installing tree-sitter $TREE_SITTER_VERSION ($TS_ARCH)"
    TS_TMP="$(mktemp -d)"
    TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
    # The release asset is a single gzipped binary (.gz), NOT a tarball — there
    # is no directory to extract and no runtime tree to place beside it.
    #
    # Staged as tree-sitter.new on the destination filesystem and validated by
    # actually RUNNING it before the final mv. `test -x` is not enough: these are
    # dynamically linked against glibc, so on a musl base image the file is
    # executable and still dies with "not found" at exec time — which would
    # surface later as the same confusing treesitter build failure this block
    # exists to fix, only now with a binary sitting in place looking installed.
    #
    # Bounded curl timeouts for the same reason as nvim: the default is no
    # timeout at all, so a blackholed CDN would hang container start forever.
    if curl -fsSL --connect-timeout 10 --max-time 300 \
      -o "$TS_TMP/tree-sitter.gz" "https://github.com/tree-sitter/tree-sitter/releases/download/v${TREE_SITTER_VERSION}/tree-sitter-${TS_ARCH}.gz" \
      && echo "$TS_SHA  $TS_TMP/tree-sitter.gz" | sha256sum -c - >/dev/null 2>&1 \
      && gunzip -c "$TS_TMP/tree-sitter.gz" > "$TS_TMP/tree-sitter" \
      && as_user mkdir -p "$SEED_HOME/.local/bin" \
      && rm -f "$TS_BIN.new" \
      && cp "$TS_TMP/tree-sitter" "$TS_BIN.new" \
      && chmod 0755 "$TS_BIN.new" \
      && { chown "$SEED_UID:$SEED_GID" "$TS_BIN.new" 2>/dev/null \
        || [ -z "$(find "$TS_BIN.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } \
      && as_user "$TS_BIN.new" --version >/dev/null 2>&1 \
      && as_user mv "$TS_BIN.new" "$TS_BIN"; then
      echo "🌱 seed: tree-sitter ready"
    else
      echo "⚠️  seed: tree-sitter install failed (non-fatal; treesitter parsers will not compile)"
    fi
    rm -f "$TS_BIN.new"
    rm -rf "$TS_TMP"
  fi
fi

# --- Versioned gate --------------------------------------------------------
# ---------------------------------------------------------------------------
# AUTHORED ~/.claude COPY — ALWAYS-RUN, deliberately ABOVE the version gate.
#
# Clause 2 of the two-clause rule: the target persists (claude-local-home), but
# the SOURCE IS THE HOST. SEED_VERSION lives in this script, so the gate cannot
# observe a host-side edit — gating this copy pins the container to whatever the
# host looked like at first seed, through any number of rebuilds, with the fresh
# value sitting unread in the read-only mount one directory away. Unconditional
# costs ~9ms for a ~12K tree, so there is nothing worth protecting. Do NOT
# substitute rsync: absent from many base images, pointless at this size, and
# `rm -rf` + `cp -a` already deletes host-removed files.
#
# PRUNE FIRST, UNCONDITIONALLY. The destination lives in the PERSISTED
# claude-local-home volume, so anything not removed here survives every rebuild.
# Removing inside an `if source exists` guard is the bug: when the host DELETES
# settings.json / CLAUDE.md / config / commands / skills, the guard never fires,
# the stale copy is left behind, and the next sentinel stamp preserves it
# forever. Clearing first makes the seed converge on the host in both
# directions. It also fixes nesting: `cp -a src/commands dst/commands` copies
# *into* an existing destination, producing ~/.claude/commands/commands on the
# second copy.
#
# Only these five seed-owned paths are pruned. ~/.claude/plugins (marketplace),
# the sentinel, and all runtime state are deliberately untouched.
# The prune runs even when $SEED_CLAUDE is absent entirely — removing the whole
# mount is just the limiting case of deleting every file in it, and leaving the
# stale copies behind there would be the same bug.
# ---------------------------------------------------------------------------
echo "🌱 seed: creating container-local $CLAUDE_HOME"
as_user mkdir -p "$CLAUDE_HOME"

for item in settings.json CLAUDE.md; do
  as_user rm -rf "$CLAUDE_HOME/$item"
  if [ -e "$SEED_CLAUDE/$item" ]; then
    as_user cp -a "$SEED_CLAUDE/$item" "$CLAUDE_HOME/$item"
  fi
done
for dir in config commands skills; do
  as_user rm -rf "$CLAUDE_HOME/$dir"
  if [ -d "$SEED_CLAUDE/$dir" ]; then
    as_user cp -a "$SEED_CLAUDE/$dir" "$CLAUDE_HOME/$dir"
  fi
done
if [ -d "$SEED_CLAUDE" ]; then
  echo "🌱 seed: refreshed authored ~/.claude subset from host"
else
  echo "🌱 seed: no $SEED_CLAUDE mount — pruned seed-owned ~/.claude paths"
fi

# ---------------------------------------------------------------------------
# PLUGIN REGISTRY HOME-PATH REPAIR — always-run, deliberately ABOVE the gate.
# The registry records ABSOLUTE paths. When the container user changes (root →
# vscode/node/developer), every recorded path still names the OLD home while the
# payloads live under the new one, and Claude reports `cache-miss` for every
# plugin — the marketplace looks un-downloaded when nothing is actually missing.
# This lives in the persisted volume, so no rebuild clears it.
#
# NOT gated: the source is container runtime state, which SEED_VERSION cannot
# observe, so gating latches the break the way any state-blind guard does.
# The rewrite is a no-op once paths are correct, so running it always is free.
#
# The /.claude|/.dotfiles suffix is a load-bearing anchor: a bare /root also
# matches the //rootly.com and /Rootly-AI-Labs URLs in the official catalog.
# ---------------------------------------------------------------------------
plugin_home_repair() {
  local dir="$CLAUDE_HOME/plugins"
  [ -d "$dir" ] || return 0
  local repaired="" f tmp
  for f in "$dir/known_marketplaces.json" "$dir/installed_plugins.json"; do
    [ -f "$f" ] || continue
    # mktemp in the registry's OWN directory: an exclusive create beats the
    # predictable "$f.seed.$$", and staying on the same filesystem is what keeps
    # the later rename atomic rather than a copy.
    tmp="$(mktemp "$f.seed.XXXXXX" 2>/dev/null)" || continue
    sed -E "s#(/root|/home/[^\"/]+)(/\.(claude|dotfiles))#${SEED_HOME}\2#g" \
      "$f" >"$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    if cmp -s "$f" "$tmp"; then
      rm -f "$tmp"
      continue
    fi
    # Validate BEFORE replacing: a truncated or malformed registry is worse than
    # a stale one — Claude fails to start rather than reporting cache-miss. No
    # jq means no way to know which one we produced, so skip rather than write
    # unverified: the un-repaired registry still works, just with cache-miss.
    if ! command -v jq >/dev/null 2>&1; then
      echo "⚠️  seed: jq unavailable — cannot verify rewritten $(basename "$f"), leaving original"
      rm -f "$tmp"
      continue
    fi
    if ! jq -e . "$tmp" >/dev/null 2>&1; then
      echo "⚠️  seed: rewritten $(basename "$f") is not valid JSON — leaving original"
      rm -f "$tmp"
      continue
    fi
    # Carry owner+mode onto the temp file, then rename. `cat >"$f"` would
    # preserve them by writing through the inode, but it truncates first: an
    # interrupt mid-write leaves a half-written registry with no way back.
    # rename(2) is atomic, so the file is either fully old or fully new.
    #
    # Both must hold. Renaming a temp file that kept the seed user's owner or a
    # default mode hands the registry to the wrong identity, and Claude then
    # cannot write it — the same cache-miss symptom this function exists to fix,
    # now permanent. A stale registry is the better failure.
    #
    # chown FAILING is not itself the problem, though: a non-root seed cannot
    # call chown(2) at all on some kernels, yet mktemp already created the file
    # as that same user, so the ownership is right anyway. Test the outcome, not
    # the exit status — that covers the root and non-root seeds with one branch.
    if ! chown --reference="$f" "$tmp" 2>/dev/null \
      && [ "$(stat -c '%u:%g' "$tmp" 2>/dev/null)" != "$(stat -c '%u:%g' "$f" 2>/dev/null)" ]; then
      echo "⚠️  seed: could not carry owner onto $(basename "$f") — leaving original"
      rm -f "$tmp"
      continue
    fi
    if ! chmod --reference="$f" "$tmp" 2>/dev/null; then
      echo "⚠️  seed: could not carry mode onto $(basename "$f") — leaving original"
      rm -f "$tmp"
      continue
    fi
    # A failed rename leaves the ORIGINAL in place, which is the safe outcome —
    # but say so. Silence here is indistinguishable from "nothing needed
    # repairing", and $repaired stays empty either way, so the next start would
    # be the only hint. Not stamping is handled by the caller; this just has to
    # not claim success.
    if mv -f "$tmp" "$f"; then
      repaired="$repaired $(basename "$f")"
    else
      echo "⚠️  seed: could not replace $(basename "$f") — original left intact, retrying next start"
    fi
    rm -f "$tmp"
  done
  # Same fallout: ~/.claude symlinks aimed at the dead home. Match the TARGET
  # against the legacy-home pattern — a bare "is it dangling" test also deletes
  # the user's own broken symlinks, which this script has no business touching.
  # Use `if`, not a trailing && chain: under `set -e` a loop body ending false
  # kills the script, and on a fresh volume nothing matches, so that is NORMAL.
  local link target
  for link in "$CLAUDE_HOME"/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      "$SEED_HOME"/*) ;;                                  # correct home: not ours to judge
      /root/.claude/* | /root/.dotfiles/* \
        | /home/*/.claude/* | /home/*/.dotfiles/*)
        rm -f "$link"
        repaired="$repaired $(basename "$link")"
        ;;
    esac
  done
  [ -n "$repaired" ] && echo "🌱 seed: repaired stale home paths in plugin registry:$repaired"
  return 0
}
plugin_home_repair

# ---------------------------------------------------------------------------
# DRIFT CHECK — runs on BOTH the gated-skip and reseed paths.
# Compares CONTENT against the host mount rather than trusting the sentinel, so
# it reports staleness no matter the cause — including a seed still running the
# old layout where this copy sat below the gate. This is the check that turns
# "why is my model wrong" from a debugging session into a line in the log.
# Advisory only: never exits nonzero, so a false positive cannot block startup.
# ---------------------------------------------------------------------------
config_drift_check() {
  local drift=""
  # The SAME five seed-owned paths the copy above manages. Comparing a subset
  # would pass while commands/ or skills/ were stale.
  for item in settings.json CLAUDE.md config commands skills; do
    local src="$SEED_CLAUDE/$item" dst="$CLAUDE_HOME/$item"
    # Both directions. An `[ -e "$src" ] || continue` guard is the bug it is
    # meant to catch: a path DELETED on the host but still present in the
    # persisted volume is exactly the stale-copy case, and skipping absent
    # sources makes it invisible.
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
      drift="$drift $item(missing)"
    elif [ ! -e "$src" ] && [ -e "$dst" ]; then
      drift="$drift $item(orphaned)"
    elif [ -d "$src" ] || [ -d "$dst" ]; then
      # --no-dereference is REQUIRED here, not a nicety. ~/.claude/skills is a
      # tree of symlinks into ~/.agents, which is deliberately NOT mounted, so a
      # dereferencing diff compares two unreachable targets and reports drift
      # between byte-identical trees — a FAIL on every single start.
      diff --no-dereference -rq "$src" "$dst" >/dev/null 2>&1 \
        || drift="$drift $item"
    elif [ -e "$src" ]; then
      cmp -s "$src" "$dst" || drift="$drift $item"
    fi
  done
  if [ -n "$drift" ]; then
    echo "   FAIL  ~/.claude differs from host mount:$drift"
    echo "         seed may predate the always-run config copy — re-copy"
    echo "         local-seed.sh from the project-claude-setup skill"
  else
    echo "   PASS  authored ~/.claude matches host mount"
  fi
  return 0
}

# Invoked here, ABOVE the gate, so it runs on BOTH paths — the gated-skip exit
# below and the reseed path. Placed after the copy so it verifies the result of
# this run rather than the previous one.
config_drift_check

# ---------------------------------------------------------------------------
# VERSION GATE — installers only, from here down.
# ---------------------------------------------------------------------------
# Skip the gated INSTALL steps only when the sentinel already records this
# SEED_VERSION. An empty legacy sentinel (the pre-versioning contract) is NOT
# treated as current: it falls through once so the versioned steps run and the
# sentinel gets stamped, after which the gate is a plain version match. A bump
# likewise re-runs them. The Vekil hook and the authored-config copy above run
# regardless. A read that FAILS (permission/IO) also falls through to the
# reseed path so the later sentinel write surfaces the error.
#
# NOTE what is NOT below this gate: the authored ~/.claude copy. Its target
# persists, but its SOURCE IS THE HOST, and SEED_VERSION lives in this file —
# so a host-side edit bumps no version and a gated copy would never see it.
# See clause 2 of the two-clause rule (SKILL.md item 15).
if [ -f "$SENTINEL" ] && SEEN_VERSION="$(cat "$SENTINEL")" 2>/dev/null \
   && [ "$SEEN_VERSION" = "$SEED_VERSION" ]; then
  echo "🌱 seed: already seeded (v$SEEN_VERSION) — skipping installers"
  exit 0
fi
if [ -f "$SENTINEL" ] && [ -z "${SEEN_VERSION:-}" ]; then
  echo "🌱 seed: migrating legacy unstamped sentinel to v$SEED_VERSION"
fi
echo "🌱 seed: seeding to v$SEED_VERSION"

# Reinstall my@guarzo marketplace + plugins into container-local ~/.claude.
# This is correctly gated: it targets the PERSISTED claude-local-home named
# volume, so once installed it survives rebuilds and only needs re-running on a
# SEED_VERSION bump. (Dotfiles refresh, claude binary, and codex config moved to
# the always-run block above because their targets are ephemeral and would vanish
# on rebuild while this sentinel persisted.)
# A failed install must NOT be stamped: the sentinel is the only thing standing
# between a half-populated ~/.claude/plugins and a permanent skip on every later
# launch. Record the failure and leave the sentinel alone so the next run retries.
MARKETPLACE_OK=1
if [ -x "$DOTFILES_HOME/ai/marketplace/install.sh" ]; then
  echo "🌱 seed: installing my@guarzo marketplace + plugin"
  as_user bash "$DOTFILES_HOME/ai/marketplace/install.sh" || {
    MARKETPLACE_OK=0
    echo "⚠️  seed: marketplace install failed — NOT stamping sentinel; next launch retries"
  }
fi

# Register the GitHub-hosted marketplaces that settings.json's `enabledPlugins`
# refers to. A marketplace that is enabled but never registered fails with the
# SAME `cache-miss` string as a stale path (signal 7) for an unrelated reason,
# so fix both or the errors only half clear. The authored ~/.claude allowlist
# deliberately excludes plugins/ (hundreds of MB), so this cannot arrive by copy.
#
# Correctly gated: target persists in the volume, source is this template.
# List "registry-name repo" pairs explicitly — the key comes from the
# marketplace MANIFEST, not the repo path (techwolf-ai/ai-first-toolkit
# registers as `techwolf-ai-first`), so it cannot be derived, and a guard that
# guesses it never matches and re-adds on every single seed.
# Probed as SEED_USER, not as whoever runs the seed: the CLI installs into
# $SEED_HOME/.local/bin, which is not on root's PATH, so a root-run seed asking
# `command -v claude` gets "no" while the user's shell finds it fine. And an
# unavailable CLI clears MARKETPLACE_OK rather than silently skipping — skipping
# stamps the sentinel, and the gated block then never retries the registration.
if as_user sh -c 'command -v claude >/dev/null 2>&1'; then
  mp_registry="$CLAUDE_HOME/plugins/known_marketplaces.json"
  while read -r mp_name mp_repo; do
    [ -n "$mp_name" ] || continue
    # Exact top-level key, not a substring of arbitrary file text: a plain grep
    # for "name" also matches it inside a description, a plugin entry, or
    # another marketplace's nested JSON, and then silently skips registration.
    # No jq (or unreadable/invalid JSON) => fall through and register; adding an
    # already-present marketplace is idempotent, skipping a missing one is not.
    if [ -f "$mp_registry" ] && command -v jq >/dev/null 2>&1 \
       && jq -e --arg n "$mp_name" 'type == "object" and has($n)' \
            "$mp_registry" >/dev/null 2>&1; then
      continue
    fi
    echo "🌱 seed: registering marketplace $mp_name ($mp_repo)"
    as_user claude plugin marketplace add "$mp_repo" >/dev/null 2>&1 || {
      MARKETPLACE_OK=0
      echo "⚠️  seed: could not register $mp_repo (needs network) — NOT stamping sentinel"
    }
  done <<'MARKETPLACES'
claude-plugins-official anthropics/claude-plugins-official
MARKETPLACES
else
  MARKETPLACE_OK=0
  echo "⚠️  seed: claude CLI not on $SEED_USER's PATH — marketplaces not registered, NOT stamping sentinel"
fi

# 3. Stamp the sentinel with the current version, but only on a clean run.
if [ "$MARKETPLACE_OK" -eq 1 ]; then
  printf '%s\n' "$SEED_VERSION" | as_user tee "$SENTINEL" >/dev/null
  echo "🌱 seed: done (v$SEED_VERSION)"
else
  # Exit non-zero so the failure is visible to anything that checks. Note the
  # compose command uses `;` (not `&&`) before `exec {BASE_COMMAND}`, so the
  # container still starts — deliberately, since a degraded container the user
  # can debug beats one that will not boot. A missing installer stays non-fatal;
  # only an installer that ran and failed reports an error.
  echo "❌ seed: marketplace install failed (sentinel left at previous version)" >&2
  exit 1
fi
```

The sentinel stores a version number rather than being a bare touch-file. The always-run block (ownership, Vekil hook, PATH, default-shell, **plus the ephemeral-target installs**) executes before the gate, so those land on every container start — including after a rebuild that wiped `~/.local/bin`, `~/.codex`, and `/etc/passwd`. Only steps that satisfy **both** clauses of the gating rule (target persists in a named volume **and** source is this template) belong in the gate — in practice just the marketplace install. The authored `~/.claude` config copy targets a persisted volume but is sourced from the host mount, so it stays always-run: `SEED_VERSION` lives in this file and can never observe a host-side edit. Getting this split wrong is the "claude is missing after rebuild" bug: gating an install whose target is ephemeral means the persisted sentinel says "done" while the binary is gone. A legacy bare sentinel (empty file) predates versioning and is *not* treated as current: it migrates once through the gated steps and is then stamped, after which the gate is a plain version match. That one extra reseed is idempotent — the copies overwrite with the same authored config and the installer is re-entrant. On the skip path, `config_drift_check` compares the authored subset against the read-only mount and prints a FAIL line if they diverge — which is exactly what a seed still using the old below-the-gate layout will do.

Execute it with `bash`; an executable bit is optional. Keep both files untracked. If the project does not already ignore them, add the actual override path plus the seed script path (`$OVERRIDE_COMPOSE` and `$SEED_SCRIPT` as resolved in Step 1) to `.git/info/exclude`. For the common `.devcontainer/` layout that is:

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

Follow `SKILL.md` Step 6b. Canonical detection checks — search the directory holding the resolved compose files (`$(dirname "$BASE_COMPOSE")`, from Step 1), which is not always `.devcontainer/`:

```bash
COMPOSE_DIR="$(dirname "$BASE_COMPOSE")"
grep -rnE '~/\.claude:/home/[^:]+:cached' "$COMPOSE_DIR"
grep -rn '${HOME}:${HOME}' "$COMPOSE_DIR" 2>/dev/null || \
  grep -rnE '\$\{HOME\}/\.claude:\$\{HOME\}/\.claude' "$COMPOSE_DIR"
grep -rl '/home/vscode\|/home/node' ~/.claude/plugins/*.json 2>/dev/null
ls -l /home/*/ 2>/dev/null | grep -- '-> /home/' # inside a container only
```

Any signal means offer repair. Confirm each write, back up the override, remove writable/dual mounts, and inspect the fully merged Compose config. If a tracked base compose file still supplies host binds, replace those targets from the local override with project-scoped named volumes rather than editing the tracked base. Show host-config diffs before optional path rewrites or symlink cleanup, and require a container rebuild afterward.

## Step 5 — Verify

Once written, drive every command below off the paths and identity resolved during discovery, not off the `.devcontainer/` defaults:

```bash
# From Step 1. `dockerComposeFile` may be a string or an array, and each entry
# is relative to devcontainer.json's own directory — so `../docker-compose.yml`
# resolves to the project root, not `.devcontainer/`. Normalize every entry
# once and pass the whole list to Compose; a project with a base + a CI overlay
# breaks if you verify only the first file.
DC_DIR=".devcontainer"
mapfile -t COMPOSE_FILES < <(jq -r '
  (.dockerComposeFile | if type == "array" then . else [.] end)[]' \
  "$DC_DIR/devcontainer.json")
COMPOSE_ARGS=(); for f in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$(realpath -m "$DC_DIR/$f")")
done
BASE_COMPOSE="$(realpath -m "$DC_DIR/${COMPOSE_FILES[0]}")"
COMPOSE_DIR="$(dirname "$BASE_COMPOSE")"
OVERRIDE_COMPOSE="$COMPOSE_DIR/docker-compose.override.yml"
SEED_SCRIPT="$COMPOSE_DIR/local-seed.sh"
REMOTE_USER="<resolved in Step 2>"; REMOTE_HOME="<resolved in Step 2>"
```

1. Run `docker compose "${COMPOSE_ARGS[@]}" config` from the project root — every resolved `dockerComposeFile` entry plus the override, in that order, so the merge you inspect is the one the Dev Containers CLI actually builds. Compose will print the merged config or fail loudly on a typo. Check that the service name matches and that no host bind targets the container user's `~/.claude`, `~/.dotfiles`, or OpenCode directory. Unless the user opted into credential sharing, also confirm no host bind targets `~/.ssh` or `~/.config/gh` — an inherited base-file bind there must be shadowed with an empty named volume (Step 3), not left in the merged config. **Also confirm every home path in the merged config equals `$REMOTE_HOME`** — the passwd home resolved in Step 2, not a `/home/<name>` guess. A `/home/node` target when the user's home is `/home/vscode` means config lands where the shell never looks (the mounts "work" and the seed logs success, but Claude Code sees nothing).
2. Confirm the merged `command` contains `local-seed.sh` followed by the original foreground command.
3. Run `git check-ignore "$OVERRIDE_COMPOSE" "$SEED_SCRIPT"`, then compare `git status --short` with the initial snapshot. They must match; if a new tracked devcontainer modification appears, report it without staging or reverting it.
4. After the user rebuilds, verify. **The single most reliable check — do this first — is to ask the user to run these in their actual VS Code terminal** (not a `docker exec`, which can hit a different container or force a different shell than the terminal uses):

   ```bash
   id; echo "HOME=$HOME"                 # confirms the real remoteUser + home
   echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"   # must be non-empty (the proxy)
   claude                                # must start WITHOUT the subscription/API-key picker
   ```
   An empty `ANTHROPIC_BASE_URL` or the auth picker means the Vekil hook is not in *this* user's `~/.zshrc` — almost always because the seed targeted a different home. If `id` shows a different user or home than you assumed, the mounts and seed are pointed at the wrong place; fix `SEED_HOME`/the override targets and reseed.

   Then run the mechanical checks against the **VS Code-launched** container, not a bare service name — `docker compose exec {SERVICE}` can resolve to a container you started by hand, and its default user is often root. Re-confirm the container ID against the Step 2 identity first, then drive every check off those variables:

```bash
CID="$(devcontainer_cid)"   # this workspace's VS Code container (helper from Step 2;
                            # plain local_folder match fails on Windows+WSL UNC paths)
[ -n "$CID" ] && [ "$(printf '%s\n' "$CID" | wc -l)" -eq 1 ] \
  || { echo "no single VS Code devcontainer for $PWD — rebuild first"; exit 1; }
# REMOTE_USER / REMOTE_HOME come from Step 2. Do NOT re-derive them here from
# `docker inspect .Config.User` — that is the image/seed-command user, which is
# frequently root and is never authoritative for the terminal user. Re-confirm
# the pair against this container instead of recomputing it:
docker exec "$CID" getent passwd "$REMOTE_USER" >/dev/null \
  || { echo "remoteUser '$REMOTE_USER' not in this container's passwd"; exit 1; }
ACTUAL_HOME="$(docker exec "$CID" sh -c 'getent passwd "$1" | cut -d: -f6' _ "$REMOTE_USER")"
[ "$ACTUAL_HOME" = "$REMOTE_HOME" ] \
  || { echo "home mismatch: Step 2 said $REMOTE_HOME, container says $ACTUAL_HOME"; exit 1; }
echo "container=$CID user=$REMOTE_USER home=$REMOTE_HOME"    # sanity-check before trusting any check below
```
SEED_VERSION="$(sed -n 's/^SEED_VERSION=\([0-9][0-9]*\).*/\1/p' "$SEED_SCRIPT" | head -n1)"
[ -n "$SEED_VERSION" ] || { echo "could not read SEED_VERSION from $SEED_SCRIPT"; exit 1; }
docker exec -u "$REMOTE_USER" "$CID" sh -c 'test "$(cat "$1/.claude/.seeded")" = "$2"' _ "$REMOTE_HOME" "$SEED_VERSION"
docker exec -u "$REMOTE_USER" "$CID" grep -Fq 'ai/vekil/env.zsh' "$REMOTE_HOME/.zshrc"   # Vekil hook present
docker exec -u "$REMOTE_USER" "$CID" zsh -n "$REMOTE_HOME/.dotfiles/ai/vekil/env.zsh"   # hook target exists + parses; no /readyz probe
docker exec -u "$REMOTE_USER" "$CID" zsh -lic 'whence -v claude; claude --version'   # the CLI binary is installed AND on PATH
docker exec -u "$REMOTE_USER" "$CID" sh -c 'test "$(getent passwd "$(id -un)" | cut -d: -f7)" = "$(command -v zsh)"'   # default login shell is zsh
docker exec -u "$REMOTE_USER" "$CID" zsh -lic 'echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"'   # proxy env reaches the DEFAULT login shell (what the terminal opens), non-empty means Vekil is wired
docker exec -u "$REMOTE_USER" "$CID" test -f "$REMOTE_HOME/.claude/settings.json"   # only if that mount was emitted — see below
docker exec -u "$REMOTE_USER" "$CID" test -f "$REMOTE_HOME/.codex/config.toml"
docker exec -u "$REMOTE_USER" "$CID" zsh -lic 'print "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -v codex'
docker exec -u "$REMOTE_USER" "$CID" sh -c 'touch /host-seed/.claude/settings.json' # must fail read-only
docker exec -u "$REMOTE_USER" "$CID" sh -c 'test -e /host-seed/.claude/.credentials.json' # must fail: not mounted
```

Every check above runs with `-u "$REMOTE_USER"` against `"$CID"` (the VS Code
container and the remoteUser resolved in Step 2), not `exec`'s default. This matters most for the ownership line: with the default user
— often root — `$(id -u):$(id -g)` evaluates to `0:0` and the test compares root
against root, passing even when the named volumes were never chowned to the real
user. The `zsh -lic` line needs the same treatment or it reads root's login
environment rather than the one the seed configured.

The two `settings.json` lines are conditional on that mount being emitted. When
the host has no `~/.claude/settings.json`, Step 3 omits it from the allowlist, so
there is nothing to copy and nothing to write-test — skip both and instead
confirm the override's mount list contains only the entries whose host sources
exist, and that the seed log printed `copied authored ~/.claude subset`. Running
the exec test against an omitted mount reports a seed failure that isn't one.

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
