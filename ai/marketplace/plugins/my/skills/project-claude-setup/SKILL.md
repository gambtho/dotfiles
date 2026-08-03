---
name: project-claude-setup
description: Set up a project for Claude Code without leaking personal config into the project's git history. Creates a per-project overlay under ~/.dotfiles/projects/ (CLAUDE.md, agents/, settings.local.json), symlinks it into the project worktree, and — for compose-based devcontainers — writes a local seed-and-copy override for host Claude/dotfiles (with SSH/gh identity sharing as an explicit opt-in). Also detects and repairs legacy writable or dual-home Claude mounts. Use when starting work on a new project, when an open-source project shouldn't carry your CLAUDE.md, when adding agent-teams support to an existing project, or when the user mentions "set up this project for Claude" / "bootstrap project Claude config" / "share host SSH/gh/dotfiles with the devcontainer".
---

# Project Claude setup

The user keeps personal per-project Claude config (CLAUDE.md, settings.local.json, agents/) in their dotfiles repo at `~/.dotfiles/projects/<project-name>/`, not in the project repo. This skill scaffolds that overlay, symlinks it into the project worktree (the global gitignore catches the symlinks), and — when the project has a compose-based devcontainer — wires the host mounts that let the container see the user's Claude and dotfiles (with SSH/gh identity sharing available as an explicit opt-in).

It replaces the old narrower `devcontainer-host-mounts` skill. The host-mounts logic is still in here, just as one section of a longer flow.

## Triggers

- "Set up Claude for this project"
- "Bootstrap project Claude config"
- "Share my host SSH/gh/Claude with the devcontainer"
- Starting work on a fresh project (especially public/OSS where personal CLAUDE.md shouldn't ship)
- User mentions agent teams and project-level settings

## What this skill does NOT do

- **Generate CLAUDE.md content.** Run `/init` from inside the project for that — it's purpose-built. This skill creates an empty `CLAUDE.md` placeholder in the overlay so the symlink target exists, and reminds the user to run `/init`.
- **Run installers.** The `setup-agent-teams` script in `~/.dotfiles/bin/` handles tmux/win32yank/agent-teams settings on the host. That's a one-time per-machine step, separate from per-project setup.

## Prerequisites — verify first, bail clearly if any fail

All of these are blocking except item 4, which downgrades the deliverable
instead of stopping it. That single exception is stated inline below and again
at the end of this section; nothing else here is advisory.

1. **WSL host, not a devcontainer.** `uname -a` contains `microsoft` and `/.dockerenv` does NOT exist and `$REMOTE_CONTAINERS` is unset. If we're already in a container, the symlinks won't work — abort with: "Run this on the WSL host, not inside the container."
2. **Project root.** `.git/` exists in the current dir. If not, ask the user to `cd` first.
3. **Dotfiles repo present.** `~/.dotfiles/` exists with `core/git/gitignore.symlink` and `projects/` subdir. If not, point at `~/.dotfiles/projects/README.md` for the setup story.
4. **Stable link root published.** `[ -d /opt/dotfiles ] && [ "$(cd -P /opt/dotfiles && pwd -P)" = "$(cd -P ~/.dotfiles && pwd -P)" ]`. Compare canonical paths rather than trusting `readlink` output: `readlink` prints the recorded target whether or not it exists, so a root left over from another machine or an earlier `$HOME` reads as published while every overlay link through it dangles. Overlay symlinks target this root so they resolve under both the host's `$HOME` and the container's. If it's missing or points elsewhere, run `~/.dotfiles/bin/relink` — it creates the root and needs `sudo` once per machine, since `/opt` is root-owned. Don't block on it, but the two outcomes are different products, so say which one you delivered: **root validated** → the overlay works on this host *and* in the devcontainer; **root absent** → host-only, the linker falls back to `$HOME`-absolute targets with a warning and the links dangle inside any container. Never describe the fallback as container-ready.
5. **Global gitignore wired.** `git config --global core.excludesFile` resolves to a real file that includes `.claude/`, `CLAUDE.md`, `CLAUDE.local.md`, and `AGENTS.local.md`. Without these, the symlinks and import shims this skill creates will leak to `git status` inside the project. Stop and tell the user to add the missing patterns.
6. **`yq` (mikefarah/yq) and `jq` available.** Probe in order: `command -v yq` and, if that misses (PATH/cache lag in fresh shells), also `[ -x /usr/local/bin/yq ]` directly. Confirm flavor via `yq --version 2>&1 | grep -q mikefarah` — if it doesn't match, refuse. **Never suggest `apt install yq`** — Ubuntu/Debian ship the Python `kislyuk/yq`, which has incompatible merge semantics. If `yq` is missing or has the wrong flavor, stop and ask the user to run `~/.dotfiles/bin/setup-agent-teams` separately. After it completes, rerun this skill and repeat every prerequisite check before continuing. `jq` should already be present; `sudo apt install jq` is fine (only one flavor).

Don't continue past failed prereqs — they're not auto-recoverable from inside
this skill. The one exception is item 4: an absent stable root is recoverable
later (`~/.dotfiles/bin/relink`, one `sudo` per machine) and blocks nothing on
this host, so continue — but deliver it as **host-only**, never as done.

## Step 1 — Classify the devcontainer setup

Read `.devcontainer/devcontainer.json` if present. Categorize:

- **(a) Compose-based**: `dockerComposeFile` key is set. The override file logic in Section 6 applies.
- **(b) Dockerfile / image-only**: `build` or `image` set, no `dockerComposeFile`. The host-mount override doesn't apply directly — Compose features won't merge into a non-Compose devcontainer.
- **(c) No devcontainer**: file doesn't exist. Skip Section 6 entirely.

For case (b), stop and ask: "This project uses a Dockerfile-based devcontainer, not Compose. Options: (1) add a thin `docker-compose.yml` wrapper so we can apply host mounts, (2) skip the container side and just do the overlay symlinks. Which?" Don't auto-convert.

For case (a), also record the `dockerComposeFile` **contents**. The key is either a single string (`"dockerComposeFile": "docker-compose.yml"`) or an array; treat a string as a one-item list when checking whether the override is present, and normalize it to an array only if the user approves the tracked edit in Section 6c. The override only loads if `docker-compose.override.yml` is one of its entries — the Dev Containers CLI / VS Code pass explicit `-f` flags for exactly the listed files and ignore any unlisted sibling override (plain `docker compose` auto-merge does NOT happen under the real launch path). If the override is absent from the array, Section 6 must resolve that (ask the user to add it to the tracked `devcontainer.json`, or hand them the manual edit) — otherwise the seed silently never runs and `claude` never lands in the container.

## Step 2 — Inspect the project

Read concrete files. **Don't infer**; cite the file you read.

| Signal | Source |
|---|---|
| Primary language | `go.mod` / `package.json` / `pyproject.toml` / `Gemfile` / `Cargo.toml` / `mix.exs` |
| Build/test/lint commands | `Makefile` (parse target names), `package.json` scripts, `justfile`, `Taskfile.yml`, `.github/workflows/*.yml` |
| Container **remoteUser** (terminal/extension user — what mounts + seed target) | **Best: ask the user to run `id; echo $HOME` in their VS Code terminal.** Else `remoteUser` in `devcontainer.json`, or read the *VS Code-launched* container (`docker ps -q --filter "label=devcontainer.local_folder=$PWD"` — scoped to *this* workspace, never the first devcontainer running. **On Windows+WSL that label holds a UNC path** (`\\wsl.localhost\Ubuntu\home\you\proj`), so a POSIX `$PWD` match returns nothing even when the container is healthy; fall back to `devcontainer.config_file=$PWD/.devcontainer/devcontainer.json` or `com.docker.compose.project.working_dir=$PWD/.devcontainer`, which are always POSIX. See `devcontainer_cid()` in Step 8. **Require exactly one non-empty ID before any `docker exec`**: zero means rebuild first, more than one must be disambiguated by hand. Then `docker exec <it> sh -c 'id -un'` and `sh -c 'getent passwd "$1" \| cut -d: -f6' _ <user>` for the home, treating empty passwd output as "no such user" rather than falling through to a guess). NOT uid 1000, NOT `docker inspect .Config.User`, and NOT a container you `docker compose up` yourself — each can resolve to a different user than the one VS Code opens terminals as. Record the resulting user/home pair once and reuse it for every mount target, the seed, and verification. |
| Container service name | `service` in `devcontainer.json` if set, else the first key under `services:` in the base compose file |
| Seed privilege (Compose, non-root user) | Passwordless `sudo` already supplied by the image or existing Dockerfile; inspect only, and verify a running container with `sudo -n true` when available |

Summarize in 4–6 lines:

```text
Project: <name> (slug: <basename>)
Language: <lang> (from <file>)
Build: <cmd> | Test: <cmd> | Lint: <cmd>  (from <Makefile/scripts/CI>)
Devcontainer: <flavor> | service=<name> | user=<user>
```

**Tracked devcontainer boundary.** Dockerfile, devcontainer.json, and base Compose files are inspection-only, with ONE sanctioned exception (below).

Never edit a project Dockerfile or a base Compose file. Never edit `.devcontainer/devcontainer.json` **except** for the single user-approved change of adding `docker-compose.override.yml` to the `dockerComposeFile` array (Section 6c) — and even then, touch no other key. That edit only happens after the user explicitly approves it, knowing it is a tracked change.

The only permitted devcontainer writes are the gitignored `docker-compose.override.yml`, `local-seed.sh`, the user-approved `dockerComposeFile` entry in `devcontainer.json`, and `.git/info/exclude` entries needed for the two local files.

Capture the initial `git status --short` output before any write, **and a copy of the tracked `devcontainer.json` content** (e.g. `git show :.devcontainer/devcontainer.json` plus the working-tree file). Status alone is insufficient: if that file is already modified for unrelated reasons, a further unauthorized edit does not change its status line and would go undetected.

At final verification, run `git status --short` and compare its output byte-for-byte with the initial snapshot, **and diff `devcontainer.json` against the captured copy**. The only permitted content difference is the user-approved `dockerComposeFile` entry; any other tracked modification is reported without staging, reverting, or repairing it.

The only expected difference is the user-approved `devcontainer.json` edit from Section 6c (if it happened) — flag that in the report with the fork/upstream caveat. Otherwise the snapshots must match, because all other skill-created files are ignored. If any *other* tracked devcontainer modification appears, stop and report it without staging, reverting, or attempting to repair it.

For a Compose devcontainer with a non-root user, do not generate the seed model unless passwordless `sudo` is already provided by the image or existing Dockerfile, or verified in a running container. The Dockerfile is evidence only; never add users, packages, directories, ownership changes, or sudo configuration to it. Docker named volumes can be mounted as `root:root`, and the seed must repair both destination trees before checking its sentinel. If passwordless `sudo` is unavailable, stop and offer only a solution implemented entirely in the gitignored local Compose override; otherwise report the container setup as unsupported. Root container users do not need this check.

Wait for the user to confirm before generating anything.

## Step 3 — Create the dotfiles overlay

The overlay directory under `~/.dotfiles/projects/<slug>/` is the master copy. The project worktree only ever has symlinks pointing into it.

Slug derivation: the basename of the project directory (e.g., for a project at `~/workspace/eveDMV`, `basename ~/workspace/eveDMV` yields `eveDMV` — that's the slug). Preserve case. Don't transform — the user's existing layout (`~/workspace/eveDMV`, `~/workspace/wanderer-kills`) uses verbatim directory names.

Detect what the project tracks (or has on disk) before calling the helper:

```bash
PROJECT_DIR="<project>"        # the project worktree
SLUG="$(basename "$PROJECT_DIR")"   # verbatim basename; see the slug rule above
cd "$PROJECT_DIR"
PROJ_HAS_CLAUDE_MD=0
PROJ_HAS_AGENTS_MD=0
PROJ_CLAUDE_DIR_NEEDS_PER_FILE=0
git ls-files --error-unmatch CLAUDE.md   >/dev/null 2>&1 && PROJ_HAS_CLAUDE_MD=1
git ls-files --error-unmatch AGENTS.md   >/dev/null 2>&1 && PROJ_HAS_AGENTS_MD=1
# Per-file mode is required whenever a real .claude/ directory exists in
# the project (tracked OR untracked). The legacy directory-symlink path
# would fail with "exists as a real file/dir" — coexist via per-file
# symlinks instead.
if [[ -d .claude && ! -L .claude ]]; then PROJ_CLAUDE_DIR_NEEDS_PER_FILE=1; fi
```

Pick the helper flags:

| Detected | Flags to pass |
|---|---|
| Project tracks CLAUDE.md | `--local-md` (writes CLAUDE.local.md import shim) |
| Project tracks AGENTS.md, user wants AGENTS.local.md too | `--local-md --agents-md` (AGENTS.local.md is opt-in via `--agents-md`; only fires if `~/.dotfiles/projects/<slug>/AGENTS.md` also exists) |
| A real `.claude/` directory exists in the project (tracked or not) | `--claude-dir-per-file` |
| None of the above | no extra flags — legacy symlink-the-whole-thing path |

Then invoke:

```bash
flags=()
(( PROJ_HAS_CLAUDE_MD )) && flags+=(--local-md)
(( PROJ_HAS_AGENTS_MD )) && flags+=(--local-md --agents-md)   # --agents-md is opt-in; pair with --local-md
(( PROJ_CLAUDE_DIR_NEEDS_PER_FILE )) && flags+=(--claude-dir-per-file)
# Dedupe in case both CLAUDE.md and AGENTS.md triggered --local-md above.
mapfile -t flags < <(printf '%s\n' "${flags[@]}" | awk '!seen[$0]++')
claude-link-project --create "${flags[@]}" "$PROJECT_DIR"
```

`claude-link-project --create` scaffolds `~/.dotfiles/projects/<slug>/{CLAUDE.md,.claude/settings.local.json}` placeholders in the overlay if not already present, then links them into the project per the chosen flags:

- Default: symlinks `<project>/CLAUDE.md` → overlay's CLAUDE.md, and `<project>/.claude` → overlay's `.claude` dir.
- `--local-md`: writes a 1-line `<project>/CLAUDE.local.md` (gitignored globally) containing `@~/.dotfiles/projects/<slug>/CLAUDE.md`; the project's tracked CLAUDE.md is left untouched.
- `--claude-dir-per-file`: links the overlay's `.claude/` into the project's `.claude/`. `skills/` and `agents/` are linked as **whole directories**; every other file is linked individually at the same relative path. `settings.local.json` is merged via jq (with diff + confirmation) instead of symlinked. If a tracked file in the project would be shadowed, the helper refuses with a clear message — rename your overlay item and re-run. A legacy per-file `skills/`/`agents/` tree from an older run is migrated to a directory link automatically, provided every entry under it is a symlink into the overlay.

If the overlay already exists (re-run), the helper detects this and skips the placeholder writes. Per-file mode and merges are idempotent.

After running it, verify the expected on-disk shapes:

```bash
ls -L <project>/CLAUDE.md       # symlink (default) OR untouched real file (--local-md)
ls -L <project>/CLAUDE.local.md # exists only in --local-md mode
ls -L <project>/.claude/settings.local.json

# skills/ and agents/ are DIRECTORY symlinks into the overlay, not trees of
# per-file links: Claude Code documents a <skill-name> entry that is a symlink
# to a directory elsewhere, but says nothing about a symlinked SKILL.md inside
# a real directory. A directory link also carries scripts/ and other payloads,
# and picks up newly added skills with no re-run.
ls -ld <project>/.claude/skills <project>/.claude/agents

# Must print nothing. Any output is a dangling link. Overlay links target the
# stable root /opt/dotfiles rather than an absolute $HOME path, so the same link
# resolves on the host and inside a container that publishes its own root.
# Re-running the helper migrates any link still written against a bare $HOME —
# directory links, per-file links, and CLAUDE.md alike — and repoints it.
find <project>/.claude -xtype l

# The root itself. `readlink` alone is not a check — it prints the recorded
# target whether or not it exists — so compare canonical paths. Anything but a
# match means bootstrap/relink has not run on this machine, or could not get
# sudo; the linker then falls back to $HOME-absolute targets, which resolve
# here and dangle in the container. Report that as host-only, not as done.
# See ~/.dotfiles/projects/README.md.
[ -d /opt/dotfiles ] && [ "$(cd -P /opt/dotfiles && pwd -P)" = "$(cd -P ~/.dotfiles && pwd -P)" ] \
  && echo "stable root OK (host + container)" || echo "NO stable root — host-only"
```

Skills and agents are discovered when a session starts, so anything linked
after launch only appears once the session is restarted.

### Git worktrees

`git worktree add` produces a fresh working tree, and the `.claude/` overlay is
untracked — so a new worktree starts with none of the project's personal skills
or agents. The `SessionStart` hook at `ai/claude/hooks/overlay-sync.sh` repairs
this automatically: it resolves the overlay slug from the **primary** working
tree (a worktree directory is named after its branch, not the project), re-runs
the linker, and reports what it created. It also repoints links left dangling by
a different `$HOME`. It writes only inside the working tree it was invoked for,
and fails open — a broken hook never blocks a session from starting.

To link a worktree by hand, or whenever the directory name doesn't match the
overlay, pass the slug explicitly:

```bash
project_name="<project-name>"
worktree_dir="<worktree-dir>"
claude-link-project --claude-dir-per-file --slug "$project_name" "$worktree_dir"
```

Set `CLAUDE_OVERLAY_SYNC=off` to disable the hook.

## Step 4 — CLAUDE.md content

**When the project tracks its own CLAUDE.md** (the `--local-md` path):

The project's tracked CLAUDE.md is Claude Code's primary instruction file — leave its content alone, it's the team's shared agreement. The overlay's `~/.dotfiles/projects/<slug>/CLAUDE.md` is your *personal* extension, loaded alongside the tracked file via the `CLAUDE.local.md` import shim.

The real use case for the overlay CLAUDE.md isn't "alias hints and credentials reminders" — it's **personal workflow opinions about how features get built** that you don't want to impose on contributors. Concretely, write things like:

- **Agent dispatch preferences** — "For non-trivial work, dispatch the `go-dev` / `frontend-dev` agents instead of executing in the main thread." Without this, Claude defaults to main-thread execution and the standing agents you scaffold in Step 7 sit unused.
- **When to use the team flow** — "For features touching backend + frontend, run `/new-feature`. For one-line fixes, just do it." Codifies the threshold so Claude isn't second-guessing it per task.
- **Personal scope/verification discipline** — "Cite test output before claiming done. Don't rename or restructure outside the asked scope. When unsure, stop and ask." These are global preferences but they bear repeating per-project because they shape every turn.
- **Local sandbox/credentials hints** — e.g. "Use `SUPABASE_DB_URL` from `.env`, production API at `<host>`." Pointers, not actual secrets.

What stays OUT of the overlay CLAUDE.md:
- Anything other contributors would benefit from — propose a change to the tracked CLAUDE.md instead.
- Detailed architecture rules — they belong with the team.

A useful overlay CLAUDE.md after Step 7 is typically 30–80 lines: a workflow section, the standing-agent catalog with trigger conditions, and a "personal preferences" tail.

**When the project does NOT track CLAUDE.md** (the legacy symlink path):

The overlay's CLAUDE.md is the project's primary CLAUDE.md, surfaced into the project tree via symlink. Run `/init` from inside the project (`cd <project> && claude`) to generate content — Claude reads the codebase and writes a starting CLAUDE.md. The output lands at the symlinked path, which routes back to your dotfiles overlay. After `/init` finishes, append the same workflow/agent-dispatch section described above so the standing agents get used.

## Step 5 — settings.local.json: grounded allowlist

Personal allowlist entries always land in `settings.local.json`, never in `settings.json`. Claude Code's documented settings layering puts `.local.json` on top of `.json`, and `.local.json` is gitignored by convention — keeping personal allows out of the project repo.

Edit `~/.dotfiles/projects/<slug>/.claude/settings.local.json` (the overlay master; the file in the project tree is either a symlink to this, or a merged copy — see Step 3).

Read the existing file (the placeholder is `{ "permissions": { "allow": [] } }`). Append + dedupe — never replace.

Build the allowlist **from inspected facts only**. For each entry, point at the file that justified it:

| Allow entry | Add when… |
|---|---|
| `Bash(go test:*)`, `Bash(go build:*)`, `Bash(go vet:*)`, `Bash(gofmt:*)` | `go.mod` present |
| `Bash(golangci-lint:*)` | `.golangci.yml`/`.golangci.yaml` or `golangci-lint` referenced in Makefile/CI |
| `Bash(npm test:*)`, `Bash(npm run build:*)`, `Bash(npm run lint:*)` | `package.json` has matching `scripts` entry |
| `Bash(npx tsc:*)` | `tsconfig.json` present |
| `Bash(pytest:*)` | `pytest.ini`/`pyproject.toml [tool.pytest]` or `tests/` with conftest |
| `Bash(ruff:*)`, `Bash(mypy:*)` | mentioned in CI or pyproject |
| `Bash(make:*)` | top-level `Makefile` |
| `Bash(just <target>:*)` per real justfile target | `justfile` |
| `Bash(kubectl:*)`, `Bash(helm:*)` | `k8s/` or `charts/` or `helm/` dirs |
| `Bash(docker compose:*)` | `docker-compose.yml` at root |

Don't add wildcards (`Bash(*)`, `Read(**)`). Don't add commands speculatively because "they might be useful."

Show the diff before writing.

For projects that already track their own `.claude/settings.local.json` (rare; usually it's gitignored), `claude-link-project --claude-dir-per-file` merges your overlay's allows into the tracked file via jq, shows a diff, and warns that the change will appear in `git diff`. Decide whether to commit, stash, or revert.

Never write to the project-shared `.claude/settings.json` from this skill — that file (when it exists) is the team's shared baseline. Personal additions go to `settings.local.json`.

## Step 6 — Compose host mounts (case a only)

Mount an allowlisted subset of `~/.claude` — plus `~/.dotfiles` — read-only under `/host-seed`, then copy the authored Claude subset and dotfiles into container-local named volumes at the user's home with a gitignored `.devcontainer/local-seed.sh`. Mounting the whole `~/.claude` would expose host credentials and session transcripts to the container even read-only, so only the authored-config paths the seed script actually copies are mounted. The named-volume targets also replace any inherited host binds with the same container targets during Compose merge. This lets Claude Code write runtime state without any write path back to the host. Host SSH keys and `gh` auth are **not** shared by default — they are single global credentials that force the container onto the host's GitHub identity across projects; mount `~/.ssh` and `~/.config/gh` read-only only when the user explicitly opts in (see item 2). OpenCode is not seeded; the seed script links Codex through `ai/codex/install.sh`.

Write or merge the gitignored `docker-compose.override.yml` directly. The override must:

1. Target the actual devcontainer service and home directory found in Step 2.
2. Leave host SSH keys and `gh` auth unmounted by default. Ask the user once: "Share host SSH keys and gh auth with this container? (default: no)" — mounting them forces every container onto the same host GitHub identity and key set and can switch accounts unexpectedly. Only if the user opts in, mount `~/.ssh` and `~/.config/gh` read-only at the container home. Otherwise the container authenticates itself (`gh auth login` inside the container, a project-scoped `GH_TOKEN`, or its own key). If the merged base compose already binds host `~/.ssh` or `~/.config/gh` and the user declined, shadow each inherited target with an empty project-scoped named volume — declining must not leave an inherited host bind in place.
3. Mount the authored-config allowlist from `~/.claude` under `/host-seed/.claude` path-by-path (`settings.json`, `CLAUDE.md`, `config`, `commands`, `skills`, each `:ro,cached`), and `~/.dotfiles` at `/host-seed/.dotfiles:ro,cached`. Never mount all of `~/.claude`: read-only still means readable, so a whole-directory mount would expose `.credentials.json`, `history.jsonl`, and `projects/` session transcripts to the container. Skip any allowlist entry the host lacks — Docker would otherwise create an empty directory in its place.
4. Mount project-scoped named volumes at the container user's `~/.claude` and `~/.dotfiles`. Because Compose volume entries merge by container target, these replace legacy host binds inherited from the base compose file.
5. If the merged base still exposes host OpenCode config, shadow that target with an empty project-scoped named volume; do not seed or install OpenCode.
6. Override `command` to run `.devcontainer/local-seed.sh`, then `exec` the base service's original foreground command.
7. Preserve unrelated existing override keys and show the diff before writing.
8. Back up an existing override to `<file>.backup-<timestamp>` before replacing legacy mounts.
9. In the seed script, repair both named-volume trees' ownership before checking the sentinel; the sentinel may skip copies and installers, never ownership recovery.
10. Before checking the sentinel, idempotently add a container-local `~/.zshrc` hook that sources `~/.dotfiles/ai/vekil/env.zsh`; this supplies both proxy endpoint variables and the managed `codex` function without modifying the host or running the full dotfiles installer.
11. Make the sentinel version-aware: store a `SEED_VERSION` number in `~/.claude/.seeded` and re-run the gated copy/install steps unless the sentinel records exactly that version. A persisted named volume survives `--remove-existing-container`, so without a version bump an evolving template could not refresh those steps. A legacy bare (empty) sentinel is **not** current — it predates versioning, so it takes a one-time migration through the gated steps and is then stamped with the current version; subsequent starts match on version and skip. The always-run block (ownership + Vekil hook) stays before the gate so those land on every start regardless of version. Verify by asserting the sentinel's *content* equals the current `SEED_VERSION`, not merely that the file exists.
12. Install the Claude Code CLI **binary** in the seed, not just its config. Most base images ship without `claude`, so seeding `~/.claude` alone leaves no runnable CLI — the exact "claude isn't installed in the devcontainer" failure. Run `~/.dotfiles/ai/claude/install.sh` with `ALLOW_REMOTE_INSTALLERS=1` (the dotfiles guard blocks remote installers by default). Note the tradeoff: that installer fetches `https://claude.ai/install.sh` unpinned, so a rebuild executes whatever upstream currently serves. This is accepted as the default because the seed only ever runs against the user's own devcontainer and the alternative (vendoring a pinned release) would go stale silently. **If the project needs supply-chain pinning, set `CLAUDE_CLI_INSTALL_CMD` in the override's `environment:`** to a command that installs a pinned, checksum-verified artifact into the remoteUser's `~/.local/bin`; the seed takes that branch instead and never invokes the remote installer. (`ai/claude/install.sh` has no version/checksum support of its own, so the pinned artifact must be supplied by the project.) Either way the step lives in the **always-run block, NOT the versioned gate** (see #15), guarded by a `command -v claude` skip so an image that already provides it is left alone. The installer drops the binary in `~/.local/bin`, so the always-run block must also add `~/.local/bin` to PATH in `~/.zshrc` (and export it for the seed's own install steps) or `claude` won't resolve.
13. Ensure the override is actually loaded (see Step 1 / Section 6c). Writing the override is pointless if `docker-compose.override.yml` is not in `dockerComposeFile` (string or array) — the CLI ignores unlisted files. This is checked and resolved separately because it may require a user-approved edit to the tracked `devcontainer.json`.
14. Make **zsh the container's default (login) shell** in the always-run block. Vekil's `env.zsh` is zsh-only and is what points claude/codex at the proxy (`ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL`). If the default shell is bash, an interactive terminal never sources it, so `claude` launched from that terminal silently bypasses the proxy — the "claude isn't picking up the vekil proxy" symptom, even though the Vekil `~/.zshrc` hook, the proxy, and `claude` are all fine. Set the login shell with `chsh -s "$(command -v zsh)"` (fall back to editing `/etc/passwd` if writable), guarded so it's a no-op when already zsh. Keep it in the always-run block, not the version gate: `/etc/passwd` is in the container's writable layer and resets on every rebuild, so it must re-apply each launch. If zsh is missing, or neither `chsh` nor a writable `/etc/passwd` can set it, fail the seed loudly with the reason rather than skipping quietly — a silent skip produces exactly the bypassed-proxy symptom this rule exists to prevent, and the fix (a supported base image, or an override that installs zsh) is the user's to make.
15. **Split seed steps by BOTH clauses below — this is the rule that keeps a rebuild working.** A step may sit under the version gate only if it satisfies *both*; failing either puts it in the **always-run block** with its own presence check.

    **Clause 1 — the target must persist.** The sentinel (`~/.claude/.seeded`) lives in the persisted `claude-local-home` named volume, which survives `--remove-existing-container`. Anything targeting the container's **ephemeral writable layer** would be skipped as "already seeded" yet be gone after a rebuild. Ephemeral targets here: the `claude` binary (`~/.local/bin`), codex config (`~/.codex`), the default shell (`/etc/passwd`), the `~/.zshrc` hooks, and the `~/.dotfiles` refresh (always-run so the installers exist before the claude/codex steps that need them). Symptom of getting this wrong: everything works on the first build, then after a rebuild `claude` is missing / the proxy isn't wired, though the log says "already seeded."

    **Clause 2 — the source must be this template.** `SEED_VERSION` lives in `local-seed.sh`, so the gate can only observe changes to that file. A step whose source is the **host** (`/host-seed/...`) is invisible to it: editing `~/.claude/settings.json` on the host bumps no version, so the gate skips the copy and the container serves stale config through any number of rebuilds — with the correct value sitting unread in the read-only mount. **The authored `~/.claude` config copy fails this clause and belongs in the always-run block**, even though its target persists. Gating it costs nothing to give up: the subset is ~12K with no regular files at the top level (`skills/` is symlinks), measured at ~9ms for a full `cp -a`. Symptom: a host config change (model, commands, skills) never reaches the container, and rebuilding doesn't help because the named volume survives.

    For the small `~/.claude` subset, `rm -rf` + `cp -a` is sufficient — `rsync` buys nothing at ~12K and is absent from some base images.

    **`~/.dotfiles` is NOT an exception to clause 2 — it is the worst case of it.** An empty-volume guard here looks like a reasonable cost optimization and is not, because this tree is the *source* of the config the other steps copy: `~/.claude/settings.json` is a symlink into it, and `ai/vekil/env.zsh` exports `ANTHROPIC_MODEL`, which **outranks `settings.json`**. Freezing the volume therefore pins the model to whatever the host had at first seed, and no amount of fixing the `~/.claude` copy can dislodge it — the correct value is copied, then overridden by the stale env var. Rebuilding does not help; the named volume survives `--remove-existing-container`. A missing `hooks/overlay-sync.sh` presents at the same time as a `SessionStart` hook error.

    So mirror it on every launch, host-authoritative:
    ```bash
    if [ -d "$SEED_DOTFILES" ]; then
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$SEED_DOTFILES/" "$HOME/.dotfiles/"
      else
        # No non-pruning fallback: the always-run installers EXECUTE files from
        # this persisted tree, so one deleted upstream would keep running.
        find "$HOME/.dotfiles" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        cp -a "$SEED_DOTFILES/." "$HOME/.dotfiles/"
      fi
    fi
    ```
    State the cost plainly to the user: container-local edits under `~/.dotfiles` are reverted every start, including the runtime toggles Claude Code writes into `ai/claude/settings.json` (theme, `agentPushNotifEnabled`). Those must be made on the host to persist. That is the right trade — a 40M rsync of an unchanged tree is near-instant, and the alternative is a class of bug that costs hours.

    Net: **only the marketplace/plugins install stays gated** — it alone is both expensive and template-sourced.

Do **not** use `claude-merge-compose-override` for this step until that helper emits the seed model; its current output contains writable and dual-home mounts.

Keep the override and seed script local. Verify they are ignored with `git check-ignore`; if the project does not already ignore them, add them to `.git/info/exclude` rather than changing tracked project files.

### Section 6c — Ensure the override is loaded (may edit tracked `devcontainer.json`, ask first)

Before rebuilding, confirm `docker-compose.override.yml` appears in `dockerComposeFile` in `.devcontainer/devcontainer.json`. That key may be a single string or an array — read a string as a one-item list before deciding whether the override is missing. If it does not, the Dev Containers CLI / VS Code will never load it — the seed won't run and `claude` won't appear, which looks exactly like "the setup didn't work."

`devcontainer.json` is otherwise off-limits, so this is a **sanctioned, ask-first exception** — never edit it silently:

> "The override won't load unless it's listed in `dockerComposeFile` in the tracked `.devcontainer/devcontainer.json`. I can add it there (one line), but that file is tracked — the change will show in `git status`, and if this repo is a fork/OSS project you'll want to keep it as a local-only commit and not push it upstream. Or I can leave the file untouched and give you the exact line to add yourself. Which do you prefer?"

- **User approves the edit:** add `"docker-compose.override.yml"` (or the correct relative path) to the list, matching existing style. If the current value is a plain string, convert it to an array containing the original string followed by the override; if it is already an array, append. Touch no other key. Flag it in the final report as a tracked change with the fork/upstream caveat.
- **User declines:** write the override + seed as normal, but state plainly it will NOT take effect until the entry exists, and hand them the exact edit. Do not claim the container side is done.

Verify the merge after listing — over the **complete** `dockerComposeFile` list, in order, with each entry resolved relative to `devcontainer.json`'s directory (so `../docker-compose.yml` lands at the project root). Verifying only the base plus the override misses a third file that overrides the service `command` or re-adds a host bind:

```bash
mapfile -t COMPOSE_FILES < <(jq -r '
  (.dockerComposeFile | if type == "array" then . else [.] end)[]' \
  .devcontainer/devcontainer.json)
COMPOSE_ARGS=(); for f in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$(realpath -m ".devcontainer/$f")")
done
docker compose "${COMPOSE_ARGS[@]}" config    # the override appears only if it is listed
```

The merged output should show the seed `command` and the `/host-seed` mounts.

See `devcontainer-host-mounts.md` for the copy-pasteable override and seed script, service/user/path substitutions, and verification commands.

For a project that **already has** a `.devcontainer/local-seed.sh` predating a template change, see `catch-up-local-seed.md`. Don't regenerate the file from the template to close the gap — the drift runs both ways, and a wholesale regeneration silently deletes whatever that project fixed locally first. `SEED_VERSION` is not a reliable indicator either: always-run blocks correctly don't bump it, so two seeds can both report the same version and differ.

## Step 6b — Repair an existing corrupted rw-mount setup

Detect the old pattern before converting. Signals (any one → offer repair):

1. rw `~/.claude` mount in a compose file:
   `grep -rnE '~/\.claude:/home/[^:]+:cached' .devcontainer/`
2. parallel dual-mount lines:
   `grep -rn '${HOME}:${HOME}' .devcontainer/ 2>/dev/null || grep -rnE '\$\{HOME\}/\.claude:\$\{HOME\}/\.claude' .devcontainer/`
3. container-user paths written back into HOST config — match any foreign home
   and subtract this one, rather than listing `/home/vscode|/home/node`: the
   `remoteUser` varies per project (wanderer's is `developer`), and a fixed list
   silently reports "clean" for every user not on it. Anchor on the
   `/.claude|/.dotfiles` suffix, not a bare `/root`, or the catalog's
   `//rootly.com` URLs match and every host trips this signal; require a path
   boundary after it too, so a neighbour like `/home/vscode/.claude-backup`
   does not. Strip URLs before matching rather than after: a source URL that
   happens to contain `/home/<x>/.claude/` is not a filesystem path, and no
   amount of anchoring distinguishes it once the scheme has scrolled past.
   Subtract this home with a fixed-string prefix test, not `grep -v "^$HOME/"`:
   interpolating the path into a regex turns every `.` in it into a wildcard, so
   a `/home/user.name` host silently drops a foreign `/home/userXname/.claude/`.
   `grep -F` cannot express the anchor, hence awk's `index() != 1`:
   `cat ~/.claude/plugins/*.json 2>/dev/null | sed 's#[a-z][a-z0-9+.-]*://[^"[:space:]]*##g' | grep -hoE '(/root|/home/[^/"]+)/\.(claude|dotfiles)(/|"|$)' | awk -v h="$HOME/" 'index($0, h) != 1' | sort -u`
4. foreign home symlinks the shim created:
   `ls -l /home/*/ 2>/dev/null | grep -- '-> /home/'` (inside a container only)
5. **stale gated config copy** (the clause-2 bug in item 15) — an existing
   `local-seed.sh` that copies the authored `~/.claude` subset *inside* the
   version gate. Cheap to detect: the copy loop appears after the sentinel
   check rather than before it.
   ```bash
   # non-zero line number => the settings.json copy sits AFTER the gate: stale
   awk '/VERSION GATE/{g=NR} /cp -a "\$SEED_CLAUDE\/\$item"/{if(g)print NR}' \
     .devcontainer/local-seed.sh
   ```
   Confirm against the running container — the definitive test, since it
   compares content rather than reading the script. Compare all five seed-owned paths, in both directions — a subset check passes
   while `commands/` or `skills/` are stale, and a source-exists guard hides the
   path deleted on the host but still present in the persisted volume:
   ```bash
   docker exec -u "$REMOTE_USER" "$CID" sh -s "$REMOTE_HOME" <<'EOF'
   # Same reason as the plugin scan below: -u switches the uid, not HOME.
   HOME="$1"
   for i in settings.json CLAUDE.md config commands skills; do
     s=/host-seed/.claude/$i; d=$HOME/.claude/$i
     if   [ -e "$s" ] && [ ! -e "$d" ]; then echo "STALE $i (missing)"
     elif [ ! -e "$s" ] && [ -e "$d" ]; then echo "STALE $i (orphaned)"
     elif [ -d "$s" ] || [ -d "$d" ]; then
       # --no-dereference: skills/ is symlinks into the unmounted ~/.agents
       diff --no-dereference -rq "$s" "$d" >/dev/null 2>&1 || echo "STALE $i"
     elif [ -e "$s" ]; then cmp -s "$s" "$d" || echo "STALE $i"
     fi
   done
   EOF
   ```
   Any `STALE` line means the item-15 fix has not been applied.
   Repair: move the authored-config copy from the gated section into the
   always-run block (leave the marketplace install gated), then restart. No
   `SEED_VERSION` bump is needed — that is the point of the fix. Seeds written
   before this change also lack the `a0` self-check below, so add it too; it is
   what surfaces this class of drift on every start instead of on the day
   someone notices the wrong model.

6. **frozen `~/.dotfiles` volume** — a `local-seed.sh` that only populates
   `~/.dotfiles` when the volume is empty. Higher-impact than signal 5 and it
   masks the fix for it, since `~/.claude/settings.json` symlinks into this tree
   and `ai/vekil/env.zsh` exports `ANTHROPIC_MODEL`, which outranks
   `settings.json`.
   ```bash
   # any output => populate-once guard still present: host edits never land
   grep -n 'mindepth 1 -maxdepth 1 -print -quit' .devcontainer/local-seed.sh
   ```
   Confirm against the container — this is the check that names the real symptom:
   ```bash
   docker exec -u "$REMOTE_USER" "$CID" \
     cmp /host-seed/.dotfiles/ai/vekil/env.zsh "$REMOTE_HOME/.dotfiles/ai/vekil/env.zsh" \
     || echo "dotfiles FROZEN — model/hooks stale regardless of settings.json"
   ```
   Repair: replace the guard with the unconditional `rsync -a --delete` mirror
   from item 15 and restart. Tell the user their container-local `~/.dotfiles`
   edits will be reverted from now on.

7. **stale home paths in the CONTAINER plugin registry** — presents to the user
   as every plugin failing at once with `Failed to load marketplace "<name>":
   cache-miss`, which reads like the marketplace was never downloaded. It was:
   the payloads are present and correctly owned, but the registry records
   ABSOLUTE paths, and they still name the home of a *previous* container user.
   This is signal 3 in the opposite direction — 3 is container paths leaking
   into host config, 7 is a dead container home stranded in container config —
   so check both; neither grep finds the other.
   Trigger: the container user changed (commonly root → `vscode`/`node`/
   `developer`) while `~/.claude` lived in a **persisted named volume**. No
   rebuild clears it, because the volume is precisely what rebuilds preserve.
   The removed home-symlink shim used to mask this by making the old path
   resolve, so it typically surfaces right after that shim is cleaned up.
   ```bash
   # inside the container: any output => registry points at a dead home.
   # Test each file's CONTENT: `grep -l` prints filenames, and every one of them
   # is under $HOME by construction, so filtering the filename list by $HOME
   # discards every hit and the check silently never fires.
   # URLs are stripped first: a marketplace source containing /home/<x>/.claude/
   # is not a filesystem path and would otherwise trip this on every container.
   # HOME comes from the resolved REMOTE_HOME, not from the exec environment:
   # `docker exec -u <user>` switches the uid but leaves HOME at the image's
   # ENV value (usually /root), so the glob would scan a directory that does not
   # exist, match nothing, and read as clean — and the exclusion would subtract
   # the wrong home even if it did.
   docker exec -u "$REMOTE_USER" "$CID" sh -c '
     HOME="$1"
     for f in "$HOME"/.claude/plugins/*.json; do
       [ -f "$f" ] || continue
       sed "s#[a-z][a-z0-9+.-]*://[^\"[:space:]]*##g" "$f" 2>/dev/null \
         | grep -oE "(/root|/home/[^/\"]*)/\.(claude|dotfiles)(/|\"|$)" \
         | awk -v h="$HOME/" "index(\$0, h) != 1" | sed "s#^#$f: #"
     done' _ "$REMOTE_HOME"
   ```
   Distinguish from a genuinely absent marketplace before repairing — same error
   string, unrelated cause: a marketplace referenced by `settings.json`'s
   `enabledPlugins` but missing from `known_marketplaces.json` was never
   registered in this container at all. The authored `~/.claude` allowlist
   deliberately excludes `plugins/` (hundreds of MB), so it cannot arrive by
   copy; it has to be re-registered with `claude plugin marketplace add <repo>`.
   The registry key comes from the marketplace manifest, not the repo path
   (`techwolf-ai/ai-first-toolkit` → `techwolf-ai-first`), so an
   already-registered guard must list the key explicitly or it re-adds forever.
   Repair, in the seed and **above** the version gate — the source is container
   runtime state, so `SEED_VERSION` cannot observe the poisoning and gating it
   latches the break. Use the `plugin_home_repair()` function in
   `devcontainer-host-mounts.md` rather than writing the rewrite inline: it
   validates the rewritten JSON before replacing anything (a truncated registry
   is worse than a stale one — Claude fails to start rather than reporting
   cache-miss), carries owner and mode onto the temp file so the rename does not
   hand the registry to the wrong user, skips files the rewrite left unchanged,
   and replaces via atomic `mv` so an interrupt cannot leave a half-written
   registry. A bare `sed >"$f.tmp" && mv` has none of that.

   Two details in it are load-bearing and easy to lose in a re-implementation:
   the rewrite must write back to the file (a plain `sed` transforms stdin and
   leaves the registry untouched, which reads as "the repair ran and did
   nothing"), and the pattern must anchor on the `/.claude|/.dotfiles` suffix
   rather than a bare `/root` — the official catalog contains `//rootly.com` and
   `/Rootly-AI-Labs` URLs that a loose pattern silently corrupts. Also delete
   `~/.claude` symlinks left dangling at
   the old home. Rewriting is non-destructive and preserves the cache; wiping
   the volume also works but costs re-auth (`.credentials.json` lives there),
   re-download, and container-local history.

Anything scaffolded before the two-clause rule existed will trip signals 5 and 6,
so run both during **any** repair pass, not just rw-mount conversions. Signal 6
first: while the dotfiles tree is frozen, fixing signal 5 changes nothing
observable, which makes the fix look ineffective.

Remediation (confirm with user before each write):

- **Re-resolve the remoteUser empirically first — do NOT trust the home path in the legacy override, and do NOT trust a container you started yourself.** A legacy override often hardcodes a home (e.g. `/home/node`) that may or may not still be the remoteUser after features run. The authoritative source is the user's actual VS Code terminal: ask them to run `id; echo $HOME`. If you inspect via docker, inspect the **VS Code-launched** container (`docker ps | grep devcontainer`), never one you `docker compose up` yourself — a hand-started container can resolve uid 1000 to a *different* user than VS Code's, so every `docker exec` then confirms the wrong home while the user's terminal stays broken. Use the remoteUser's home for every mount target and as the seed's `SEED_HOME`. Remember the seed `command:` may run as root or a different user — it must write to the remoteUser's home explicitly (via `runuser`/`sudo -u`), never its own `$HOME`. See Step 2 and the reference file's Step 2.
- Rewrite the override to read-only seed mounts, container-local named-volume targets, the `command` override, and `local-seed.sh` from Step 6, **all targeting the empirically-resolved home**. Back up the old override to `<file>.backup-<timestamp>`.
- Remove the `${HOME}:${HOME}` dual-mount lines.
- Inspect the fully merged Compose config, not only the override. Shadow any legacy base-file binds targeting the container user's `~/.claude`, `~/.dotfiles`, or OpenCode directory with project-scoped named volumes. Unless credential sharing was opted into, do the same for any inherited `~/.ssh` or `~/.config/gh` bind.
- Optional host cleanup: rewrite `/home/<container-user>` to the host home in `~/.claude/plugins/{known_marketplaces,installed_plugins}.json`, and delete broken `~/.claude` symlinks whose target starts with `/home/<container-user>`. Show a diff or list first; never bulk-delete without confirmation.
- Tell the user to rebuild the container to apply the repair.
- Inspect the fully merged Compose config, not only the override. Shadow any legacy base-file binds targeting the container user's `~/.claude`, `~/.dotfiles`, or OpenCode directory with project-scoped named volumes. Unless credential sharing was opted into, do the same for any inherited `~/.ssh` or `~/.config/gh` bind.
- Optional host cleanup: rewrite `/home/<container-user>` to the host home in `~/.claude/plugins/{known_marketplaces,installed_plugins}.json`, and delete broken `~/.claude` symlinks whose target starts with `/home/<container-user>`. Show a diff or list first; never bulk-delete without confirmation.
- Tell the user to rebuild the container to apply the repair.

## Step 7 — Agent scaffolding (ask, two tiers)

Agents in `.claude/agents/*.md` serve two roles:

1. **Standalone subagents** — dispatched directly via the `Agent` tool for one-shot delegation.
2. **Team member templates** — when you call `TeamCreate` and spawn members, the `subagent_type` you pass references the same `.md` files. The agent definition becomes the "role template" for that teammate.

Both roles use the same files. So the question isn't "subagent or team member?" — it's "what roles does this project need standing on call?"

Ask the user:

> "Want me to scaffold standing agents for this project? Two options:
> **(a) Standing catalog** — 3–6 role-based agents (backend-dev, frontend-dev, code-reviewer, etc.) that double as team members. Recommended if you'll use the team-spawning flow.
> **(b) Just a README** — pointer to examples, scaffold later.
> **(c) Skip.**"

If **(b)** or **(c)**, create only `<overlay>/.claude/agents/README.md` pointing at `~/.dotfiles/ai/marketplace/plugins/my/agents/` and exit this step.

If **(a)**, offer **role-based candidates grounded in the inspected stack**:

| Detected | Candidate role | Tools | Notes |
|---|---|---|---|
| Go backend | `<lang>-dev` (e.g. `go-dev`) | full (Read/Edit/Write/Bash/Grep/Glob) | Anchored on project's architecture rules (hexagonal, file-size budget, mock pattern from CLAUDE.md) |
| React/TS frontend | `frontend-dev` | full | Knows the dev proxy, type sync, API client; references `frontend-design`/`impeccable`/`slabledger-design` skills if present |
| Database with migrations | merge into `<lang>-dev` (don't make a separate `db-migrator` unless migrations need their own review lens) | — | Narrow agents that overlap with the language dev waste a slot |
| Data analysis surface (portfolio, billing, analytics dashboards) | `<domain>-analyst` (e.g. `profit-analyst`) | Read + Bash (psql/curl only) — **no Edit** | Read-only by design; cite data source |
| Any project with reviewable PRs | `code-reviewer` | Read + Grep + Glob + Bash(git diff/log/make check) — **no Edit** | Anchored on the convention table from the tracked CLAUDE.md |
| Frontend project with screenshots | `ux-polisher` | full, scoped to web/ | Drives `ui-screenshot-improve` and `impeccable` |

A good baseline is **5 roles**: language-dev, frontend-dev (if applicable), code-reviewer, data-analyst (if applicable), ux-polisher (if frontend). Don't propose narrow one-offs (test-runner, lint-reviewer, single-skill wrappers) — they overlap with the language-dev role and waste slots in the catalog.

**Agent file structure** (lands at `<overlay>/.claude/agents/<name>.md`):

```yaml
---
name: <role>
description: <one-sentence trigger description, mentions when to auto-dispatch; also acts as the template summary when spawned as a team member>
model: sonnet
tools: <restricted set — see table above>
---

<one short paragraph: what they own, anchored on project paths from Step 2>

## Priorities

- <3–6 specific, file-or-rule-anchored items from the tracked CLAUDE.md>
```

For **reviewer-type** agents: `tools: Read, Grep, Glob, Bash` with the Bash entries scoped to non-mutating commands. **No Edit/Write.** For **analyst-type** agents: same Read-only stance, Bash limited to `psql`, `curl`, etc.

Files land at `<overlay>/.claude/agents/<name>.md`. Because `agents/` is a directory symlink, a new agent file appears in the project immediately — no re-run needed.

## Step 7b — Team-flow scaffolding (offer when standing catalog created)

If the user accepted Step 7 (a), also offer:

> "Want a `/new-feature` slash command that encodes the team-spawn ritual (brainstorm → plan → TeamCreate → seed TaskList → spawn role-typed members in parallel)?"

If yes, create two files:

**File 1: `<overlay>/.claude/commands/new-feature.md`** — a slash command that walks the user through:
1. `superpowers:brainstorming` to clarify intent
2. `superpowers:writing-plans` to write the plan
3. `TeamCreate({ team_name, description })`
4. `TaskCreate` per unit of work (with `addBlockedBy` dependencies)
5. `Agent({ team_name, name, subagent_type })` for each role, in parallel (single message, multiple tool calls)
6. Orchestrate via `TaskList` + `SendMessage`; run `code-reviewer` before declaring done
7. `superpowers:verification-before-completion` before any "done" claim
8. `TeamDelete` on completion

The frontmatter is just `description:` and `argument-hint:`. Body uses `$ARGUMENTS` for the feature slug. See `references/new-feature-command-template.md` if it exists; otherwise model on the agent catalog you just created — each role in the catalog maps to one `subagent_type` in the spawn step.

**File 2: workflow section appended to `<overlay>/CLAUDE.md`** — codifies when to use the team flow vs the main thread (see Step 4 for content guidance). Without this, Claude doesn't know it should reach for the agents on each new task and defaults to single-thread execution.

`commands/` is still linked per-file (unlike `skills/` and `agents/`), because a project is more likely to track its own `.claude/commands/` content and the per-file mode is what catches those collisions. Re-run after creating the command file. **Verify the symlink lands**: `ls -L <project>/.claude/commands/new-feature.md` should resolve.

Skip this step if the user only wants standalone subagents — the catalog still works for one-shot delegation without the team ritual.

## Step 8 — Final verification

```bash
cd "$PROJECT_DIR"    # from Step 7
git status --short
```

Compare the output byte-for-byte with the initial `git status --short` snapshot. If `.claude/` or `CLAUDE.md` appears, the global gitignore is not catching it. The one permitted difference is the user-approved `devcontainer.json` edit from Section 6c — report it as a tracked change with the fork/upstream caveat. If any *other* tracked devcontainer file appears as newly modified, stop and report the boundary violation; never stage or revert it on the user's behalf.

Report to the user:
- Files created/updated in `~/.dotfiles/projects/<slug>/`
- Symlinks created in the project worktree
- Commands to commit dotfiles changes:
  ```bash
  cd ~/.dotfiles && git add "projects/$SLUG" && git commit -m "add project overlay for $SLUG"
  ```
- For case (a): rebuild the devcontainer to pick up new mounts —
  `devcontainer up --remove-existing-container --workspace-folder .` or VS Code "Dev Containers: Rebuild Container"
- For case (a): after rebuild, run the checks below against the **VS Code-launched container and the remoteUser resolved in Step 2** — not `docker compose exec <service>`, which can hit a container you started by hand and defaults to the image user (often root), passing checks that the real terminal user would fail. Resolve the handles once:
  ```bash
  # `devcontainer.local_folder` holds the path as the CLIENT saw it. On
  # Windows+WSL, VS Code writes a UNC path (\\wsl.localhost\Ubuntu\home\you\proj)
  # so matching it against a POSIX $PWD silently returns nothing and every check
  # below reports "no devcontainer running" on a perfectly healthy container.
  # Fall back to labels that are always POSIX and always exact.
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
  CID="$(devcontainer_cid)"   # THIS workspace only
  [ -n "$CID" ] && [ "$(printf '%s\n' "$CID" | wc -l)" -eq 1 ] \
    || { echo "no single VS Code devcontainer for $PWD — rebuild first"; exit 1; }
  REMOTE_USER="<from Step 2>"    # never .Config.User, never uid 1000
  # pass the user as a positional arg, never interpolated into the sh -c text:
  REMOTE_HOME="$(docker exec "$CID" sh -c 'getent passwd "$1" | cut -d: -f6' _ "$REMOTE_USER")"
  ```
  If all three filters miss, list what is actually running and match by eye —
  do NOT fall back to "the first devcontainer", which can be another project:
  ```bash
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Label "devcontainer.local_folder"}}'
  ```
- For case (a): **check this one first — it decides whether any later check means anything.** Confirm the running container actually has the seed mounts, rather than assuming the config on disk is what it was built from:
  ```bash
  docker exec "$CID" sh -c 'test -d /host-seed && echo "/host-seed mounted"'
  docker inspect "$CID" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
  ```
  A missing `/host-seed`, or a `config_files` list without `docker-compose.override.yml`, means the container predates the `dockerComposeFile` edit. **Editing `devcontainer.json` does not touch an existing container, and neither does restarting it** — Compose keeps the file list, mounts, and `command:` recorded at creation, so the seed has simply never run and every check below will fail with a misleading symptom (no `nvim`, no `claude`, no dotfiles). The fix is a **rebuild**, not a restart: *Dev Containers: Rebuild Container* in VS Code. Do not `docker compose up` it by hand — the devcontainer CLI injects generated compose files for features and the build, and recreating without them silently drops those layers.
- For case (a): verify the `claude` CLI binary is installed AND on PATH — this is the check that catches the "claude isn't installed in the devcontainer" failure:
  ```bash
  docker exec -u "$REMOTE_USER" "$CID" zsh -lic 'whence -v claude; claude --version'
  ```
  If `claude` doesn't resolve, either the seed's CLI-install step didn't run (override not loaded — re-check `dockerComposeFile`, Section 6c) or `~/.local/bin` isn't on PATH (the always-run PATH hook didn't fire — check the seed log for `added ~/.local/bin to PATH`).
- For case (a): verify the `tree-sitter` CLI resolves — without it every nvim-treesitter parser fails to build at first launch, since `config/nvim` pins the `main` branch and its installer shells out to `tree-sitter build` with no bare-`cc` fallback:
  ```bash
  docker exec -u "$REMOTE_USER" "$CID" zsh -lic 'whence -v tree-sitter; tree-sitter --version'
  ```
  If it doesn't resolve, the seed's tree-sitter step didn't run (check the seed log for `tree-sitter ready`); on a container predating that step, catch the seed up per `catch-up-local-seed.md`. The symptom is a wall of `Error during "tree-sitter build": ... ENOENT ... (cmd): 'tree-sitter'` on opening any file.
- For case (a): confirm zsh is the **default** shell and the proxy env reaches it — this catches "claude isn't picking up the vekil proxy" when everything else looks fine but the terminal opens bash:
  ```bash
  docker exec -u "$REMOTE_USER" "$CID" sh -c 'test "$(getent passwd $(id -un) | cut -d: -f7)" = "$(command -v zsh)" && echo "default shell = zsh"'
  # `echo` always exits 0, so it cannot fail the check — test the value, then print it.
  docker exec -u "$REMOTE_USER" "$CID" zsh -lic '[[ -n "$ANTHROPIC_BASE_URL" ]] && print "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"'   # nonzero exit = proxy NOT wired into the login shell
  ```
  If the default shell is still bash, the always-run `chsh` step didn't apply (check the seed log for `set default shell to zsh`). Vekil's `env.zsh` is zsh-only, so a bash default shell means claude launched from the terminal bypasses the proxy even though the `~/.zshrc` hook and proxy are healthy.
- For case (a): verify Vekil in a fresh interactive login shell:
  ```bash
  # Run grep INSIDE the container — a bare ~/.zshrc would expand on the host.
  docker exec -u "$REMOTE_USER" "$CID" grep -Fq ai/vekil/env.zsh "$REMOTE_HOME/.zshrc"          # hook present
  docker exec -u "$REMOTE_USER" "$CID" zsh -n "$REMOTE_HOME/.dotfiles/ai/vekil/env.zsh"          # target exists + parses; no /readyz probe
  # Each variable is asserted non-empty, not merely printed, so an unset proxy
  # endpoint exits nonzero instead of scrolling past as an empty-looking line.
  docker exec -u "$REMOTE_USER" "$CID" zsh -lic '[[ -n "$OPENAI_BASE_URL" && -n "$ANTHROPIC_BASE_URL" ]] && { print "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -v codex; }'
  ```
  If the hook grep fails, the seed's always-run block never wrote it — the
  running container is likely executing a stale pre-hook `local-seed.sh`. A
  persisted named volume can keep an old versioned sentinel; confirm the on-disk
  seed matches the current template, then restart so the always-run block fires.
  The `zsh -n` line validates the hook *target* alone — nonzero if
  `~/.dotfiles/ai/vekil/env.zsh` is missing (127) or malformed (1), without
  executing it, so it does not touch the proxy. That keeps "is the hook
  well-formed" separate from readiness; the `zsh -lic` line is the combined
  hook-plus-readiness check, where an empty endpoint variable means the target
  loaded but Vekil's `/readyz` probe failed. Empty endpoint variables or Codex
  resolving to the raw binary otherwise mean the container-local zsh hook did
  not load.
  Diagnose the local seed hook and proxy readiness. Never edit a Dockerfile or
  baked rc, source all dotfiles by glob, or add a shell-startup retry loop
  without reproducing a readiness race.
- For case (c): `claude` in the project root picks up the symlinked config on next launch
- Reminder to run `/init` for CLAUDE.md content

## Container user lookup table

**This table is a last-resort guess, not an answer.** A devcontainer feature (ruby, github-cli, common-utils, etc.) can rebase uid 1000 from the base image's user to `vscode` at build time, so the base `FROM` does not determine the container user. **Whenever the image is built or a container is running, resolve the user empirically instead** — it is the only authoritative source:

```bash
# Preferred — the VS Code-launched container, as the remoteUser VS Code uses.
# NOT `docker compose exec <svc>` (may hit a container you started by hand) and
# NOT `docker inspect .Config.User` (the image/seed user, frequently root).
# Uses the devcontainer_cid() helper from Step 8: `devcontainer.local_folder`
# is a Windows UNC path under Windows+WSL, so a bare $PWD match finds nothing
# on a healthy container. The helper falls back to POSIX-valued labels.
CID="$(devcontainer_cid)"   # THIS workspace only
# Check non-empty BEFORE counting: `printf '%s\n' ""` still prints one line, so
# a bare `wc -l` test passes when no container matched at all.
[ -n "$CID" ] || { echo "no devcontainer running for $PWD — rebuild first"; exit 1; }
[ "$(printf '%s\n' "$CID" | wc -l)" -eq 1 ] || { echo "multiple containers for $PWD; disambiguate manually"; exit 1; }
# Prefer the user already resolved in Step 2. Only re-derive if you don't have
# it, and note devcontainer.json is JSONC — jq fails on comments/trailing
# commas, so a null result means "unparsed", not "unset":
REMOTE_USER="<from Step 2, if already resolved>"
[ -n "$REMOTE_USER" ] || REMOTE_USER="$(jq -r '.remoteUser // empty' .devcontainer/devcontainer.json 2>/dev/null)"
# A jq-derived name is a claim, not a fact: validate it against passwd before
# using it. Empty output means no such user (a stale remoteUser, or JSONC that
# jq mis-parsed) — do NOT silently fall back to `id -un`, which reports the
# image default (often root) and would send mounts to the wrong home while
# every check appears to pass. Ask the user to run `id; echo $HOME` in their
# VS Code terminal and use that instead.
if [ -n "$REMOTE_USER" ]; then
  docker exec "$CID" sh -c 'getent passwd "$1"' _ "$REMOTE_USER" \
    || { echo "remoteUser '$REMOTE_USER' is not in this container's passwd — confirm with the user, do not guess"; exit 1; }
else
  echo "no remoteUser configured — ask the user to run 'id; echo \$HOME' in their VS Code terminal"; exit 1
fi
```

Use the login user's passwd home (`getent passwd <user> | cut -d: -f6`) verbatim as the mount target. A directory merely *existing* at a guessed home (e.g. `/home/node`) proves nothing: Docker creates any missing mount target as a root-owned dir, so a wrong prior mount manufactures the very path that seems to confirm it. If passwd has only `vscode` and no `node`, the target is `/home/vscode` no matter what the base image or this table says — and config seeded into the wrong home is silently invisible, since Claude Code reads `$HOME/.claude`.

| Base image | Default user (unverified guess — confirm empirically) |
|---|---|
| `mcr.microsoft.com/devcontainers/javascript-node` | `node` (features often rebase to `vscode`) |
| `mcr.microsoft.com/devcontainers/typescript-node` | `node` (features often rebase to `vscode`) |
| `mcr.microsoft.com/devcontainers/base:ubuntu` (and most lang variants) | `vscode` |
| `mcr.microsoft.com/devcontainers/universal` | `codespace` |
| Custom Dockerfile with no `USER` | `root` (warn — bind mounts will be owned by root) |

If `remoteUser` in devcontainer.json is set, it wins *only if that user exists in the built image's passwd* — a stale `remoteUser` pointing at a user a feature removed is a bug, not a target. If you can't determine it from any signal, ask. Don't guess between `vscode` / `node` / `developer` — getting it wrong silently mounts into a path the shell never visits.

## Things to avoid

- **Don't write CLAUDE.md content.** `/init` does it better for projects that don't track CLAUDE.md. For projects that DO track CLAUDE.md, the overlay is just your personal notes — let the project's tracked CLAUDE.md drive the shared rules.
- **Don't shadow tracked project files.** If the project tracks CLAUDE.md, AGENTS.md, or anything under `.claude/`, never propose renaming or symlinking on top. Use the `.local.md` import-shim and per-file symlink modes instead. This skill enforces this; `claude-link-project --claude-dir-per-file` will refuse on collision.
- **Don't auto-generate agents.** Ask, offer the two-tier choice (standing catalog vs README-only), then offer the grounded role candidates from the inspected stack. Generate only what was picked. On collision with a tracked file, ask the user for a different name — don't auto-prefix.
- **Don't scaffold the team-flow command without the catalog.** `/new-feature` references the agent catalog by `subagent_type` — without agents, the command is dead code.
- **Never edit a project Dockerfile or base Compose file.** Read them only to discover existing behavior. The sole tracked-file exception is adding the override to `dockerComposeFile` in `devcontainer.json`, and only with explicit user approval (Section 6c). Every other container customization belongs in the gitignored override and seed script.
- **Don't add wildcards to settings.local.json allowlist.** Per-tool, per-command, grounded in inspected facts.
- **Don't clobber existing files in the overlay.** Re-runs should merge or skip.
- **Don't run installers.** `~/.dotfiles/bin/setup-agent-teams` handles host-side setup (tmux, win32yank, yq, settings.json merge).
- **Don't commit changes.** Print commit commands; let the user run them.
