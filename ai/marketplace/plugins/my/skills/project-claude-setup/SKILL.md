---
name: project-claude-setup
description: Set up a project for Claude Code without leaking personal config into the project's git history. Creates a per-project overlay in ~/.dotfiles/projects/<name>/ (CLAUDE.md, agents/, settings.json), symlinks it into the project worktree, and — for compose-based devcontainers — writes a docker-compose.override.yml that mounts host SSH/gh/Claude/dotfiles. Use when starting work on a new project, when an open-source project shouldn't carry your CLAUDE.md, when adding agent-teams support to an existing project, or when the user mentions "set up this project for Claude" / "bootstrap project Claude config" / "share host SSH/gh/dotfiles with the devcontainer".
---

# Project Claude setup

The user keeps personal per-project Claude config (CLAUDE.md, settings.json, agents/) in their dotfiles repo at `~/.dotfiles/projects/<project-name>/`, not in the project repo. This skill scaffolds that overlay, symlinks it into the project worktree (the global gitignore catches the symlinks), and — when the project has a compose-based devcontainer — wires the host mounts that let the container see the user's Claude/dotfiles/SSH/gh.

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
5. **Project doesn't already track CLAUDE.md or AGENTS.md.** Check `git ls-files CLAUDE.md AGENTS.md` and also a plain `ls`. If either file exists as a real (non-symlink) file:
   - The project already has its own AI instructions checked in.
   - Symlinking the overlay's CLAUDE.md/AGENTS.md on top would either fail (if the file exists) or shadow the project's version (bad).
   - **Stop and ask** the user which they want:
     - **(a) Skip the overlay's CLAUDE.md** — keep the project's version, only set up `.claude/agents/` + `.claude/settings.json` overlay. (Most common answer.)
     - **(b) Move the project file out of the way** — `git mv CLAUDE.md CLAUDE-project.md` so it stays tracked but doesn't conflict, then symlink the overlay's CLAUDE.md on top.
     - **(c) Abort** — do nothing.
   - Don't auto-pick. The user must decide.
   - If the file exists but is already a symlink into our overlay (re-run case), treat it as already-configured and continue.

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

Slug derivation: `basename "$PROJECT_DIR"`. Preserve case. Don't transform — the user's existing layout (`~/workspace/eveDMV`, `~/workspace/wanderer-kills`) uses verbatim directory names.

Use the existing `~/.dotfiles/bin/claude-link-project --create <project-dir>` helper rather than inlining the logic. It:
- Creates `~/.dotfiles/projects/<slug>/{CLAUDE.md,.claude/settings.json}` placeholders
- Symlinks `<project>/CLAUDE.md` → overlay's CLAUDE.md
- Symlinks `<project>/.claude` → overlay's `.claude` dir

**If prereq 5 resolved as option (a)** — the project tracks its own CLAUDE.md/AGENTS.md and the user wants to keep it — pass `--no-claude-md`:

```bash
claude-link-project --create --no-claude-md <project-dir>
```

This skips the CLAUDE.md symlink (the project's own file stays untouched) but still scaffolds and links `.claude/agents/` + `.claude/settings.json`. The overlay's CLAUDE.md placeholder is still created in the dotfiles repo so the user has a private notes file *if* they want one later — it just doesn't get symlinked into the project tree.

If the overlay already exists (re-run), the helper detects this and skips the placeholder writes. That's fine — we'll merge into the existing files in later steps.

After running it, verify symlinks resolve:

```bash
ls -L <project>/CLAUDE.md     # should resolve, may be empty
ls -L <project>/.claude/settings.json
```

## Step 4 — CLAUDE.md: defer to /init

**If prereq 5 resolved as option (a)** — the project already has a CLAUDE.md or AGENTS.md it owns — **skip this step entirely**. Don't run `/init`. The project's existing file is what Claude will read.

Otherwise, the placeholder CLAUDE.md created by `claude-link-project --create` is empty by design. Tell the user:

> The overlay's CLAUDE.md is a placeholder. Run `/init` from inside the project (`cd <project> && claude`) to generate the actual content — it reads the codebase the way you'd want. The output lands at the symlinked path, which routes back to your dotfiles overlay.

Don't write CLAUDE.md content from this skill. `/init` is purpose-built; reimplementing it here means two diverging code paths.

## Step 5 — settings.json: grounded allowlist

Edit `~/.dotfiles/projects/<slug>/.claude/settings.json` (the overlay file — the symlink in the project tree points here).

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

Show the diff before writing. The settings.json schema lives at the overlay path; the symlink makes it active in the project.

## Step 6 — Compose host mounts (case a only)

This is the section from the old `devcontainer-host-mounts` skill. The mounts give the container the user's host-side Claude/SSH/gh/dotfiles so the symlinked overlay actually resolves inside the container, and so `claude` inside the container reuses the host's auth/plugins/skills.

Refer to `devcontainer-host-mounts.md` in this skill's directory for the full content. The short version:

1. Resolve service name and container user (see table at end).
2. Find where the base compose file lives (read `dockerComposeFile` in devcontainer.json — sometimes `.devcontainer/docker-compose.yml`, sometimes project root).
3. Write `docker-compose.override.yml` next to the base compose file (Compose only auto-merges siblings).
4. Use the standard template with `~/.ssh`, `~/.config/gh`, `~/.claude`, `~/.config/opencode`, `~/.dotfiles` mounts — plus the **parallel `${HOME}:${HOME}` mounts** for `~/.claude`, `~/.config/opencode`, `~/.dotfiles` so absolute symlinks and absolute paths baked into JSON (e.g. `installed_plugins.json`'s `installPath`) resolve inside the container.

**One addition over the old skill:** include the agent-teams env var on the service:

```yaml
services:
  {SERVICE}:
    environment:
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"
```

If an override file already exists, parse it and merge. Don't clobber existing entries. Surface a one-line summary of what's already there before showing the proposed diff.

See `devcontainer-host-mounts.md` for the full template, the absolute-path gotcha explanation, and the verification commands.

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
  ```
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

- **Don't write CLAUDE.md content.** `/init` does it better.
- **Don't auto-generate agents.** Ask, offer grounded candidates, generate the picked ones.
- **Don't add wildcards to settings.json allowlist.** Per-tool, per-command, grounded in inspected facts.
- **Don't clobber existing files in the overlay.** Re-runs should merge or skip.
- **Don't run installers.** `~/.dotfiles/bin/setup-agent-teams` handles host-side setup.
- **Don't commit changes.** Print commit commands; let the user run them.
