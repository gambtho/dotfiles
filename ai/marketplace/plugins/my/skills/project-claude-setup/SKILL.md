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
4. **Global gitignore wired.** `git config --global core.excludesFile` resolves to a real file that includes `.claude/` and `CLAUDE.md`. Without this, symlinking the overlay into the project will leak it to `git status`. Stop and tell the user to add those patterns.
5. **`yq` (mikefarah/yq) available.** `command -v yq` resolves, and `yq --version` mentions `mikefarah`. If missing, point the user at `~/.dotfiles/bin/setup-agent-teams` which installs it. (The Python `kislyuk/yq` has incompatible merge semantics — refuse rather than risk a silent mismerge.)

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

Detect what the project tracks before calling the helper:

```bash
cd <project>
PROJ_HAS_CLAUDE_MD=0
PROJ_HAS_AGENTS_MD=0
PROJ_CLAUDE_DIR_TRACKED=0
git ls-files --error-unmatch CLAUDE.md   >/dev/null 2>&1 && PROJ_HAS_CLAUDE_MD=1
git ls-files --error-unmatch AGENTS.md   >/dev/null 2>&1 && PROJ_HAS_AGENTS_MD=1
# .claude is "tracked" if git knows about ANY file under it.
git ls-files --error-unmatch -- '.claude/**' >/dev/null 2>&1 && PROJ_CLAUDE_DIR_TRACKED=1
```

Pick the helper flags:

| Detected | Flags to pass |
|---|---|
| Project tracks CLAUDE.md | `--local-md` (writes CLAUDE.local.md import shim) |
| Project tracks AGENTS.md, user wants AGENTS.local.md too | `--local-md` (same flag triggers AGENTS.local.md if `~/.dotfiles/projects/<slug>/AGENTS.md` exists) |
| Project tracks anything under `.claude/` | `--claude-dir-per-file` |
| Project tracks none of the above | no extra flags — legacy symlink-the-whole-thing path |

Then invoke:

```bash
flags=()
(( PROJ_HAS_CLAUDE_MD )) && flags+=(--local-md)
(( PROJ_CLAUDE_DIR_TRACKED )) && flags+=(--claude-dir-per-file)
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

The project's tracked CLAUDE.md is Claude Code's primary instruction file — leave its content alone, it's the team's shared agreement. The overlay's `~/.dotfiles/projects/<slug>/CLAUDE.md` is your *personal* extension, loaded alongside the tracked file via the `CLAUDE.local.md` import shim. Use it for things like:

- Personal preferences ("use my custom test runner alias")
- Local sandbox URLs or credentials hints (no actual secrets)
- Reminders about decisions you keep making that the project doesn't document

Don't put team-relevant rules here — if other contributors would benefit, propose them as a change to the tracked CLAUDE.md.

**When the project does NOT track CLAUDE.md** (the legacy symlink path):

The overlay's CLAUDE.md is the project's primary CLAUDE.md, surfaced into the project tree via symlink. Run `/init` from inside the project (`cd <project> && claude`) to generate content — Claude reads the codebase and writes a starting CLAUDE.md. The output lands at the symlinked path, which routes back to your dotfiles overlay.

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

## Step 7 — Starter agents (optional, ask)

Ask: "Want me to scaffold 2–3 starter agents for this project?"

If no, create only `<overlay>/.claude/agents/README.md` pointing at `~/.dotfiles/ai/marketplace/plugins/my/agents/` for examples and exit this step.

If yes, **offer concrete candidates from the inspected stack** — not generic ones. Examples:

| Detected | Candidate agent |
|---|---|
| Go + tests | `test-runner.md` (mode: subagent, tools: Read+Bash(go test:*)+Bash(git diff:*); paragraph anchored on the project's actual test command from Step 2) |
| Go + golangci-lint | `lint-reviewer.md` (Read + Bash(golangci-lint:*); read-only, no Edit) |
| Go + httpx adapters pattern (look for `internal/adapters/clients/httpx`) | `api-client-author.md` (refs your `my:new-api-client` skill) |
| TypeScript + React | `ui-reviewer.md` (Read-only; ref `frontend-design` plugin) |
| TS + jest/vitest | `test-runner.md` adapted to npm test/vitest |
| Anything with `.github/workflows/` | `ci-checker.md` (Bash(gh run list:*), Bash(gh run view:*)) |
| Python + pytest | `test-runner.md` with `pytest -xvs <path>` pattern |

Show the user the candidate list with 1-line descriptions. Let them pick the ones they want. **Generate only what was picked.** Each agent gets:

- Frontmatter: `name`, `description` (one sentence, specific), `model: sonnet`, `tools: <restricted set>`
- One short paragraph: what it owns, anchored on actual project paths from Step 2
- A bulleted "priorities" list: 3–5 items, specific (not "be thorough")

For reviewer-type agents: `tools: Read, Grep, Glob, Bash(git diff:*), Bash(git log:*)`. **No Edit/Write.** Implementation agents can have wider tools.

Files land at `<overlay>/.claude/agents/<name>.md`. The symlink at `<project>/.claude/agents` makes them active.

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
- **Don't auto-generate agents.** Ask, offer grounded candidates from the inspected stack, generate only the picked ones. On collision with a tracked file, ask the user for a different name — don't auto-prefix.
- **Don't add wildcards to settings.local.json allowlist.** Per-tool, per-command, grounded in inspected facts.
- **Don't clobber existing files in the overlay.** Re-runs should merge or skip.
- **Don't run installers.** `~/.dotfiles/bin/setup-agent-teams` handles host-side setup (tmux, win32yank, yq, settings.json merge).
- **Don't commit changes.** Print commit commands; let the user run them.
