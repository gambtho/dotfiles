---
name: project-claude-setup
description: Set up a project for Claude Code without leaking personal config into the project's git history. Creates a per-project overlay in ~/.dotfiles/projects/<name>/ (CLAUDE.md, agents/, settings.local.json), symlinks it into the project worktree, and — for compose-based devcontainers — writes a docker-compose.override.yml that mounts host SSH/gh/Claude/dotfiles, or merges into an existing one. Use when starting work on a new project, when an open-source project shouldn't carry your CLAUDE.md, when adding agent-teams support to an existing project, or when the user mentions "set up this project for Claude" / "bootstrap project Claude config" / "share host SSH/gh/dotfiles with the devcontainer".
---

# Project Claude setup

The user keeps personal per-project Claude config (CLAUDE.md, settings.local.json, agents/) in their dotfiles repo at `~/.dotfiles/projects/<project-name>/`, not in the project repo. This skill scaffolds that overlay, symlinks it into the project worktree (the global gitignore catches the symlinks), and — when the project has a compose-based devcontainer — wires the host mounts that let the container see the user's Claude/dotfiles/SSH/gh.

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

1. **WSL host, not a devcontainer.** `uname -a` contains `microsoft` and `/.dockerenv` does NOT exist and `$REMOTE_CONTAINERS` is unset. If we're already in a container, the symlinks won't work — abort with: "Run this on the WSL host, not inside the container."
2. **Project root.** `.git/` exists in the current dir. If not, ask the user to `cd` first.
3. **Dotfiles repo present.** `~/.dotfiles/` exists with `core/git/gitignore.symlink` and `projects/` subdir. If not, point at `~/.dotfiles/projects/README.md` for the setup story.
4. **Global gitignore wired.** `git config --global core.excludesFile` resolves to a real file that includes `.claude/`, `CLAUDE.md`, `CLAUDE.local.md`, and `AGENTS.local.md`. Without these, the symlinks and import shims this skill creates will leak to `git status` inside the project. Stop and tell the user to add the missing patterns.
5. **`yq` (mikefarah/yq) and `jq` available.** Probe in order: `command -v yq` and, if that misses (PATH/cache lag in fresh shells), also `[ -x /usr/local/bin/yq ]` directly. Confirm flavor via `yq --version 2>&1 | grep -q mikefarah` — if it doesn't match, refuse. **Never suggest `apt install yq`** — Ubuntu/Debian ship the Python `kislyuk/yq`, which has incompatible merge semantics. Correct install:
   ```bash
   sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
     && sudo chmod +x /usr/local/bin/yq
   ```
   Or run `~/.dotfiles/bin/setup-agent-teams` which installs yq plus the rest of the host-side toolchain. `jq` should already be present; `sudo apt install jq` is fine (only one flavor).

Don't continue past failed prereqs — they're not auto-recoverable from inside this skill.

## Step 1 — Classify the devcontainer setup

Read `.devcontainer/devcontainer.json` if present. Categorize:

- **(a) Compose-based**: `dockerComposeFile` key is set. The override file logic in Section 6 applies.
- **(b) Dockerfile / image-only**: `build` or `image` set, no `dockerComposeFile`. The host-mount override doesn't apply directly — Compose features won't merge into a non-Compose devcontainer.
- **(c) No devcontainer**: file doesn't exist. Skip Section 6 entirely.

For case (b), stop and ask: "This project uses a Dockerfile-based devcontainer, not Compose. Options: (1) add a thin `docker-compose.yml` wrapper so we can apply host mounts, (2) skip the container side and just do the overlay symlinks. Which?" Don't auto-convert.

## Step 2 — Inspect the project

Read concrete files. **Don't infer**; cite the file you read.

| Signal | Source |
|---|---|
| Primary language | `go.mod` / `package.json` / `pyproject.toml` / `Gemfile` / `Cargo.toml` / `mix.exs` |
| Build/test/lint commands | `Makefile` (parse target names), `package.json` scripts, `justfile`, `Taskfile.yml`, `.github/workflows/*.yml` |
| Container user | `remoteUser` in `devcontainer.json` → Dockerfile `USER` → base image default (see table at the bottom of this skill) |
| Container service name | `service` in `devcontainer.json` if set, else the first key under `services:` in the base compose file |

Summarize in 4–6 lines:

```text
Project: <name> (slug: <basename>)
Language: <lang> (from <file>)
Build: <cmd> | Test: <cmd> | Lint: <cmd>  (from <Makefile/scripts/CI>)
Devcontainer: <flavor> | service=<name> | user=<user>
```

Wait for the user to confirm before generating anything.

## Step 3 — Create the dotfiles overlay

The overlay directory under `~/.dotfiles/projects/<slug>/` is the master copy. The project worktree only ever has symlinks pointing into it.

Slug derivation: the basename of the project directory (e.g., for a project at `~/workspace/eveDMV`, `basename ~/workspace/eveDMV` yields `eveDMV` — that's the slug). Preserve case. Don't transform — the user's existing layout (`~/workspace/eveDMV`, `~/workspace/wanderer-kills`) uses verbatim directory names.

Detect what the project tracks (or has on disk) before calling the helper:

```bash
cd <project>
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
claude-link-project --create "${flags[@]}" <project-dir>
```

`claude-link-project --create` scaffolds `~/.dotfiles/projects/<slug>/{CLAUDE.md,.claude/settings.local.json}` placeholders in the overlay if not already present, then links them into the project per the chosen flags:

- Default: symlinks `<project>/CLAUDE.md` → overlay's CLAUDE.md, and `<project>/.claude` → overlay's `.claude` dir.
- `--local-md`: writes a 1-line `<project>/CLAUDE.local.md` (gitignored globally) containing `@~/.dotfiles/projects/<slug>/CLAUDE.md`; the project's tracked CLAUDE.md is left untouched.
- `--claude-dir-per-file`: walks the overlay's `.claude/` tree and symlinks each leaf into the project's `.claude/` at the same relative path. `settings.local.json` is merged via jq (with diff + confirmation) instead of symlinked. If a tracked file in the project would be shadowed, the helper refuses with a clear message — rename your overlay item and re-run.

If the overlay already exists (re-run), the helper detects this and skips the placeholder writes. Per-file mode and merges are idempotent.

After running it, verify the expected on-disk shapes:

```bash
ls -L <project>/CLAUDE.md       # symlink (default) OR untouched real file (--local-md)
ls -L <project>/CLAUDE.local.md # exists only in --local-md mode
ls -L <project>/.claude/settings.local.json
```

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

The host mounts give the container the user's `~/.ssh`, `~/.config/gh`, `~/.claude`, `~/.config/opencode`, `~/.dotfiles` so the symlinked overlay actually resolves inside the container, and so `claude` inside the container reuses the host's auth/plugins/skills.

Use `~/.dotfiles/bin/claude-merge-compose-override` for both the create-new and merge-into-existing cases:

```bash
# Resolve service name and container user from devcontainer.json + base
# compose file (see Step 2 inspection results).
service=<from devcontainer.json or first key under services:>
user=<remoteUser or USER from Dockerfile or base-image default>

override="$(dirname "$(jq -r '.dockerComposeFile | if type=="array" then .[0] else . end' .devcontainer/devcontainer.json | sed 's|^./||')")/docker-compose.override.yml"

claude-merge-compose-override --service "$service" --user "$user" "$override"
```

The helper:
1. Creates the file with our standard mounts if it doesn't exist.
2. Merges our mounts and env var into an existing file, deduping volume mounts, showing a unified diff.
3. Warns if the target is tracked in git ("this change will appear in `git diff`; decide whether to commit, stash, or revert").
4. Refuses if `yq` is missing or is the wrong yq (Python kislyuk vs Go mikefarah).
5. Backs up the original to `<file>.backup-<timestamp>`.

See `devcontainer-host-mounts.md` for the mount table reference (what each mount is for, the parallel `${HOME}:${HOME}` mount explanation, verification commands inside the container).

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

Files land at `<overlay>/.claude/agents/<name>.md`. Re-running `claude-link-project --claude-dir-per-file` walks the overlay tree and symlinks each new agent into the project's `.claude/agents/`.

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

`claude-link-project --claude-dir-per-file` walks the overlay tree, so `.claude/commands/*.md` get symlinked into the project the same way agents do. Re-run after creating the command file. **Verify the symlink lands**: `ls -L <project>/.claude/commands/new-feature.md` should resolve.

Skip this step if the user only wants standalone subagents — the catalog still works for one-shot delegation without the team ritual.

## Step 8 — Final verification

```bash
cd <project>
git status
```

Should show **no new files**. If `.claude/` or `CLAUDE.md` shows up, the global gitignore isn't catching them — diagnose before declaring done.

Report to the user:
- Files created/updated in `~/.dotfiles/projects/<slug>/`
- Symlinks created in the project worktree
- Commands to commit dotfiles changes:
  ```bash
  cd ~/.dotfiles && git add projects/<slug> && git commit -m "add project overlay for <slug>"
  ```
- For case (a): rebuild the devcontainer to pick up new mounts —
  `devcontainer up --remove-existing-container --workspace-folder .` or VS Code "Dev Containers: Rebuild Container"
- For case (c): `claude` in the project root picks up the symlinked config on next launch
- Reminder to run `/init` for CLAUDE.md content

## Container user lookup table

(carried over from the old skill)

| Base image | Default user |
|---|---|
| `mcr.microsoft.com/devcontainers/javascript-node` | `node` |
| `mcr.microsoft.com/devcontainers/typescript-node` | `node` |
| `mcr.microsoft.com/devcontainers/base:ubuntu` (and most lang variants) | `vscode` |
| `mcr.microsoft.com/devcontainers/universal` | `codespace` |
| Custom Dockerfile with no `USER` | `root` (warn — bind mounts will be owned by root) |

If `remoteUser` in devcontainer.json is set, that wins. If you can't determine it from any signal, ask. Don't guess between `vscode` / `node` / `developer` — getting it wrong silently mounts into a path the shell never visits.

## Things to avoid

- **Don't write CLAUDE.md content.** `/init` does it better for projects that don't track CLAUDE.md. For projects that DO track CLAUDE.md, the overlay is just your personal notes — let the project's tracked CLAUDE.md drive the shared rules.
- **Don't shadow tracked project files.** If the project tracks CLAUDE.md, AGENTS.md, or anything under `.claude/`, never propose renaming or symlinking on top. Use the `.local.md` import-shim and per-file symlink modes instead. This skill enforces this; `claude-link-project --claude-dir-per-file` will refuse on collision.
- **Don't auto-generate agents.** Ask, offer the two-tier choice (standing catalog vs README-only), then offer the grounded role candidates from the inspected stack. Generate only what was picked. On collision with a tracked file, ask the user for a different name — don't auto-prefix.
- **Don't scaffold the team-flow command without the catalog.** `/new-feature` references the agent catalog by `subagent_type` — without agents, the command is dead code.
- **Don't add wildcards to settings.local.json allowlist.** Per-tool, per-command, grounded in inspected facts.
- **Don't clobber existing files in the overlay.** Re-runs should merge or skip.
- **Don't run installers.** `~/.dotfiles/bin/setup-agent-teams` handles host-side setup (tmux, win32yank, yq, settings.json merge).
- **Don't commit changes.** Print commit commands; let the user run them.
