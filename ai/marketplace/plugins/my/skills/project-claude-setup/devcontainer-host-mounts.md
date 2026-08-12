# Devcontainer seed-and-copy mounts (reference)

> This file is referenced from `SKILL.md` in this directory. It is a
> copy-pasteable reference for the devcontainer step of
> `my:project-claude-setup`. No YAML frontmatter — this is not a
> separately loaded skill.

Use a local `docker-compose.override.yml` to expose an allowlisted subset of Claude Code config, plus dotfiles, as read-only seed sources under `/host-seed`. Only the authored-config paths the seed script copies are mounted — never all of `~/.claude`, which would expose host credentials and session transcripts to the container even read-only. Project-scoped named volumes at the container user's `~/.claude` and `~/.dotfiles` replace inherited host binds with the same targets. A local `local-seed.sh` copies the authored subset into those container-local volumes and installs a container-local zsh hook for Vekil before the base foreground command starts. Claude Code can then write sessions, history, plugins, and other runtime state only inside the container.

Host SSH keys (`~/.ssh`) and `gh` auth (`~/.config/gh`) are **not** shared by default. Both are single global host credentials: mounting them forces every container onto the same GitHub identity and key set, which breaks per-container credential isolation and can switch accounts unexpectedly between projects. The container should authenticate itself instead (`gh auth login` inside the container, a project-scoped `GH_TOKEN`, or its own key). Mount them only when the user explicitly opts in for a project that genuinely wants the host identity — see Step 3.

The repository-managed renderer is the only supported generation path. OpenCode is not bridged; the generated override shadows its target with a container-local volume, and the seed links Codex with `ai/codex/install.sh`.

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

If a `docker-compose.override.yml` already exists at that location, read it before doing anything else. The renderer preserves unrelated keys, shows the diff, and allocates a collision-safe backup before replacing legacy mounts.

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
~/.agents/skills        →  /host-seed/.agents/skills         (ro) seed source, CONDITIONAL
~/.dotfiles             →  /host-seed/.dotfiles              (ro) seed source
```

**The `~/.agents/skills` entry is conditional — include it only when `~/.claude/skills`
actually contains links into it.** Check before adding:

```bash
find ~/.claude/skills -maxdepth 1 -xtype l -o -maxdepth 1 -type l -lname '*.agents/skills/*' | head
```

Some skill installers write `~/.claude/skills/<name>` as a *relative symlink* into
`~/.agents/skills/<name>` rather than a real directory, so that tree is usually mixed:
real directories alongside links. `cp -a` reproduces a symlink as a symlink and never
follows it, so without this mount the links arrive in the container pointing at a path
nothing ever mounted. **The resulting failure is silent in both directions** — `ls
~/.claude/skills` lists every entry, no command errors, and the skills are simply absent
from Claude. Mount `skills/` only; anything else under `~/.agents` (lockfiles, install
state) stays on the host, same allowlist principle as `~/.claude`.

Do not try to repair this per-skill inside a running container. The seed prunes
`~/.claude/skills` unconditionally on every start, so a skill installed over a dead link
is erased on the next start and the dead link returns — and installers that test only for
the directory entry then see it and skip, which makes the breakage look self-healing when
it is stable.

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

For host SSH and GitHub CLI credentials, explicit opt-in is necessary but not
sufficient: the renderer emits each read-only bind only when its source directory
exists and otherwise retains the empty named-volume shadow. Never ask Docker to
materialize a missing host credential path. Project-specific optional mounts are
outside the renderer's fixed allowlist and require separate user-approved design.

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

The generated files have one executable source of truth:

- [Compose skeleton](templates/compose-override.yml)
- [seed script](templates/local-seed.sh)
- [safe renderer](../../../../../../bin/claude-merge-compose-override)

Run the renderer through `SKILL.md` Step 6 with the discovered service,
remote user and passwd home, local/container seed paths, and base command JSON.
It emits only host seed sources that exist, keeps SSH and GitHub CLI credentials
container-local unless `--share-host-auth` was explicitly approved, replaces
managed volume targets while preserving unrelated Compose keys, and renders the
seed's remote user. Do not copy either template into this reference: changes to
the executable sources must take effect without synchronizing a prose block.

The helper stages and validates both outputs beside their destinations, shows
their diffs, allocates collision-safe backups through `bin/common.sh`, publishes
the seed before the override, and restores both previous files if the second
publication fails. Use `--dry-run` for a no-write preview.

Keep both files untracked. If the project does not already ignore them, add the actual override path plus the seed script path (`$OVERRIDE_COMPOSE` and `$SEED_SCRIPT` as resolved in Step 1) to `.git/info/exclude`. For the common `.devcontainer/` layout that is:

```text
.devcontainer/docker-compose.override.yml
.devcontainer/local-seed.sh
```

Why the two non-volume blocks:

- **`extra_hosts: host.docker.internal:host-gateway`** — on Docker Desktop (macOS/Windows) this DNS name exists automatically, but on Linux and WSL2 it does not. Adding `host-gateway` makes it resolve to the host on every platform, so anything in the container that talks to a host-side service (a dev server, a database tunnel, etc.) works the same everywhere. Include it in the override unless the base compose already declares it on the same service — grep the base for `host.docker.internal` first. Duplicating works (compose merges and dedupes by host name) but adds noise.

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
- Never edit a project Dockerfile or a base Compose file. The sole tracked-file exception is the user-approved `dockerComposeFile` entry in `devcontainer.json`. Keep every other devcontainer customization in the gitignored override and seed script.
- Don't assume adding `/host-seed` mounts removes legacy binds from the base compose file; verify the merged config and shadow inherited targets with named volumes.
- Don't restore parallel `${HOME}:${HOME}` mounts to make absolute references resolve.
- Don't copy host plugin runtime state; reinstall the personal marketplace container-local.
- Don't add comments explaining each mount line — the file header covers the why, and per-line comments age badly when the list changes. Match the style of the user's existing override files.
- Don't promote the override into the base `docker-compose.yml`. The whole point of the override is that it's host-specific and stays out of the committed compose file (or is committed but understood as the local-dev overlay).
- Don't change the service name to `app` if the base compose uses something else. The override must target the real service.
