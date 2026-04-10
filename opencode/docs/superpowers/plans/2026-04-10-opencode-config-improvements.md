# OpenCode Config Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix known config issues, reduce permission friction, port 3 Claude Code commands, configure context management, populate memory, and add strategic new capabilities — while preserving full dotfiles portability.

**Architecture:** All changes target `~/.dotfiles/opencode/` (symlinked to `~/.config/opencode/`). Config edits are direct file modifications. Command ports adapt Claude Code syntax to OpenCode equivalents. New skills/commands follow existing patterns in the repo.

**Tech Stack:** Bash (install.sh), Markdown (commands/agents/skills), JSON (opencode.json, package.json), JSONC (dcp.jsonc)

**Spec:** `docs/superpowers/specs/2026-04-10-opencode-config-improvements-design.md`

---

## File Structure

**Files to modify:**
- `opencode.json` — model update, bash allow-list expansion, plugin additions
- `.opencode/package.json` — unpin plugin version
- `commands/fix-pr.md` — replace stub with full port
- `commands/review-code.md` — replace stub with full port
- `commands/review-prs.md` — replace stub with full port
- `install.sh` — add dcp.jsonc linking, npm install, --check flag

**Files to create:**
- `dcp.jsonc` — DCP plugin configuration
- `skills/prereq-checker/SKILL.md` — new prerequisite checking skill
- `commands/prereqs.md` — command invoking prereq-checker skill
- `~/.dotfiles/AGENTS.md` — repo-level agent instructions

**Files to move:**
- `~/.config/opencode/skills/ai-firstify/` → `skills/ai-firstify/` (into dotfiles for version control)

**Non-file actions:**
- Populate memory blocks via `memory_set` tool (persona, human, project)

---

### Task 1: Config Fixes — opencode.json and package.json

**Files:**
- Modify: `opencode.json`
- Modify: `.opencode/package.json`

- [ ] **Step 1: Update model to claude-sonnet-4.6**

In `opencode.json`, change line 3:

```json
// OLD:
"model": "github-copilot/claude-sonnet-4.5",

// NEW:
"model": "github-copilot/claude-sonnet-4.6",
```

- [ ] **Step 2: Expand bash allow-list**

In `opencode.json`, add these entries to the `permission.bash` object (after the existing `"node *": "allow"` line):

```json
"cat *": "allow",
"wc *": "allow",
"find *": "allow",
"rg *": "allow",
"python *": "allow",
"python3 *": "allow",
"ruby *": "allow",
"elixir *": "allow",
"mix *": "allow",
"bundle *": "allow",
"cargo *": "allow",
"docker *": "allow",
"docker-compose *": "allow",
"jq *": "allow",
"curl *": "allow",
"wget *": "allow"
```

- [ ] **Step 3: Add new plugins**

In `opencode.json`, add to the `plugin` array:

```json
"plugin": [
    "superpowers@git+https://github.com/obra/superpowers.git",
    "opencode-handoff",
    "opencode-agent-memory",
    "@tarquinen/opencode-dcp@latest",
    "opencode-usage",
    "opencode-codegraph"
]
```

- [ ] **Step 4: Unpin plugin version**

Replace `.opencode/package.json` contents with:

```json
{
  "dependencies": {
    "@opencode-ai/plugin": "^1.4.3"
  }
}
```

- [ ] **Step 5: Verify the final opencode.json**

The complete `opencode.json` should now be:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "github-copilot/claude-sonnet-4.6",
  "permission": {
    "edit": "ask",
    "bash": {
      "*": "ask",
      "gh *": "allow",
      "git diff *": "allow",
      "git log *": "allow",
      "git show *": "allow",
      "git status *": "allow",
      "git rev-parse *": "allow",
      "git remote *": "allow",
      "git worktree *": "allow",
      "git fetch *": "allow",
      "git branch *": "allow",
      "git checkout *": "allow",
      "git switch *": "allow",
      "git add *": "allow",
      "git commit *": "allow",
      "git cherry-pick *": "allow",
      "git rebase *": "allow",
      "grep *": "allow",
      "mkdir *": "allow",
      "ls *": "allow",
      "rm -rf /tmp/pr-reviews-*": "allow",
      "go test *": "allow",
      "go build *": "allow",
      "go vet *": "allow",
      "go mod *": "allow",
      "make *": "allow",
      "npm *": "allow",
      "npx *": "allow",
      "node *": "allow",
      "cat *": "allow",
      "wc *": "allow",
      "find *": "allow",
      "rg *": "allow",
      "python *": "allow",
      "python3 *": "allow",
      "ruby *": "allow",
      "elixir *": "allow",
      "mix *": "allow",
      "bundle *": "allow",
      "cargo *": "allow",
      "docker *": "allow",
      "docker-compose *": "allow",
      "jq *": "allow",
      "curl *": "allow",
      "wget *": "allow"
    },
    "external_directory": {
      "~/.config/opencode/*": "allow",
      "/tmp/pr-reviews-*": "allow"
    }
  },
  "plugin": [
    "superpowers@git+https://github.com/obra/superpowers.git",
    "opencode-handoff",
    "opencode-agent-memory",
    "@tarquinen/opencode-dcp@latest",
    "opencode-usage",
    "opencode-codegraph"
  ]
}
```

- [ ] **Step 6: Commit**

```bash
git add opencode.json .opencode/package.json
git commit -m "fix: update model to sonnet 4.6, expand bash allow-list, add plugins, unpin plugin version"
```

---

### Task 2: Move ai-firstify Skill Into Dotfiles

**Files:**
- Move: `~/.config/opencode/skills/ai-firstify/` → `skills/ai-firstify/`

- [ ] **Step 1: Copy ai-firstify from config to dotfiles**

```bash
cp -r ~/.config/opencode/skills/ai-firstify/ skills/ai-firstify/
```

- [ ] **Step 2: Verify the copy**

```bash
ls -la skills/ai-firstify/
ls -la skills/ai-firstify/references/
ls -la skills/ai-firstify/scripts/
```

Expected: `SKILL.md`, `references/` directory with 9 files (principles.md, patterns.md, anti-patterns.md, assessment-rubric.md, mode-audit.md, mode-reengineer.md, mode-bootstrap.md, project-structure.md, skill-architecture.md), `scripts/` directory with validate-report.sh.

- [ ] **Step 3: Remove the old unversioned copy**

Since `install.sh` already symlinks `skills/*/` from dotfiles to `~/.config/opencode/skills/`, the old copy will be replaced by the symlink on next install run. Remove it now:

```bash
rm -rf ~/.config/opencode/skills/ai-firstify
ln -s "$(pwd)/skills/ai-firstify" ~/.config/opencode/skills/ai-firstify
```

- [ ] **Step 4: Verify the symlink works**

```bash
ls -la ~/.config/opencode/skills/ai-firstify
readlink ~/.config/opencode/skills/ai-firstify
```

Expected: symlink pointing to the dotfiles copy.

- [ ] **Step 5: Commit**

```bash
git add skills/ai-firstify/
git commit -m "feat: move ai-firstify skill into dotfiles for version control"
```

---

### Task 3: Create DCP Configuration

**Files:**
- Create: `dcp.jsonc`

- [ ] **Step 1: Create dcp.jsonc**

Create `dcp.jsonc` in the opencode dotfiles root with this content:

```jsonc
{
    "$schema": "https://raw.githubusercontent.com/Opencode-DCP/opencode-dynamic-context-pruning/master/dcp.schema.json",
    "enabled": true,
    "pruneNotification": "minimal",
    "pruneNotificationType": "chat",
    "compress": {
        "mode": "range",
        "permission": "allow",
        "summaryBuffer": true,
        "maxContextLimit": "60%",
        "minContextLimit": "30%",
        "nudgeFrequency": 3,
        "iterationNudgeThreshold": 10,
        "nudgeForce": "soft",
        "protectUserMessages": false
    },
    "strategies": {
        "deduplication": {
            "enabled": true
        },
        "purgeErrors": {
            "enabled": true,
            "turns": 3
        }
    }
}
```

- [ ] **Step 2: Symlink dcp.jsonc to config directory**

```bash
ln -sf "$(pwd)/dcp.jsonc" ~/.config/opencode/dcp.jsonc
```

- [ ] **Step 3: Verify the symlink**

```bash
ls -la ~/.config/opencode/dcp.jsonc
readlink ~/.config/opencode/dcp.jsonc
```

- [ ] **Step 4: Commit**

```bash
git add dcp.jsonc
git commit -m "feat: add DCP config for context management with GitHub Copilot-tuned limits"
```

---

### Task 4: Port fix-pr Command

**Files:**
- Modify: `commands/fix-pr.md` (replace stub with full port)

- [ ] **Step 1: Write the ported command**

Replace the entire contents of `commands/fix-pr.md` with the adapted command. The source is `~/.dotfiles/claude/commands/fix-pr.md` (489 lines) with these adaptations:

**Frontmatter changes** — replace the Claude Code frontmatter:
```yaml
# REMOVE these Claude-specific fields:
# name, argument-hint, allowed-tools

# KEEP only:
---
description: Analyze a PR's open comments and failing CI checks, then produce a detailed implementation plan to resolve all issues
---
```

**Body changes — search and replace these patterns throughout the file:**

| Find | Replace | Reason |
|------|---------|--------|
| `~/.claude/pr-fix-plans/` | `~/.opencode/pr-fix-plans/` | OpenCode path convention |
| `pr-review-toolkit:silent-failure-hunter` | `silent-failure-hunter` | OpenCode agent names don't use prefixes |
| `feature-dev:code-reviewer` | `code-reviewer` | Same |
| `feature-dev:code-explorer` | `code-explorer` | Same |
| `Claude Code` | `OpenCode` | Branding |
| `Claude` (in "feed this plan back to Claude Code") | `OpenCode` | Branding |
| `the Agent tool` / `Use the Agent tool` | `the task tool` / `Use the task tool` | OpenCode uses `task` tool for subagent dispatch |

**Add this note** at the end of Phase 4c (after the agent table):

```markdown
**OpenCode note:** Use the `task` tool with `subagent_type` matching the agent names above (e.g., `subagent_type: "silent-failure-hunter"`). Launch all relevant agents in parallel by making multiple `task` tool calls in a single message.
```

**Add `$ARGUMENTS` reference** — the body already uses `$ARGUMENTS` on line 12, which is the OpenCode convention. Keep it as-is.

- [ ] **Step 2: Verify the ported file**

Read the file and check:
- Frontmatter has only `description` field
- No references to `~/.claude/` paths remain
- No references to `allowed-tools` remain
- No references to Claude-specific tool names remain
- `$ARGUMENTS` is used for the PR reference

- [ ] **Step 3: Commit**

```bash
git add commands/fix-pr.md
git commit -m "feat: port fix-pr command from Claude Code with full 6-phase workflow"
```

---

### Task 5: Port review-code Command

**Files:**
- Modify: `commands/review-code.md` (replace stub with full port)

- [ ] **Step 1: Write the ported command**

Replace the entire contents of `commands/review-code.md` with the adapted command. Source: `~/.dotfiles/claude/commands/review-code.md` (315 lines).

**Frontmatter changes:**
```yaml
---
description: Review code changes since a specified commit for quality, idiomacy, patterns, and unnecessary complexity
---
```

**Body changes — search and replace:**

| Find | Replace | Reason |
|------|---------|--------|
| `pr-review-toolkit:silent-failure-hunter` | `silent-failure-hunter` | OpenCode agent names |
| `pr-review-toolkit:comment-analyzer` | `comment-analyzer` | Same |
| `pr-review-toolkit:type-design-analyzer` | `type-design-analyzer` | Same |
| `feature-dev:code-reviewer` | `code-reviewer` | Same |
| `the Agent tool` / `Use the Agent tool` | `the task tool` / `Use the task tool` | OpenCode tool name |
| `CLAUDE.md` | `AGENTS.md` | OpenCode convention file (keep existing `CLAUDE.md` mentions too — check for both) |

**Phase 3.5 adaptation** — replace the agent dispatch instructions:

```markdown
## Phase 3.5: Leverage Available Agents

After completing your own analysis in Phase 3, dispatch specialized agents in parallel to deepen the review. Use the `task` tool with the appropriate `subagent_type` to launch these — they run concurrently and return findings you should incorporate into the final report.

**Launch these agents in parallel on the changed files:**

| Agent | subagent_type | Purpose |
|-------|---------------|---------|
| Silent failure hunter | `silent-failure-hunter` | Finds swallowed errors, empty catch blocks, fallbacks that hide failures |
| Comment analyzer | `comment-analyzer` | Validates comment accuracy and identifies comment rot |
| Type design analyzer | `type-design-analyzer` | Reviews new types/interfaces for encapsulation and invariant quality |
| Code reviewer | `code-reviewer` | Catches bugs, logic errors, and security issues with confidence filtering |
```

**Add AGENTS.md to convention detection** — in Phase 1b, add `AGENTS.md` alongside `CLAUDE.md`:
```markdown
- `AGENTS.md` or `CLAUDE.md` — project-specific coding guidelines (authoritative)
```

- [ ] **Step 2: Verify the ported file**

Same checks as Task 4 Step 2.

- [ ] **Step 3: Commit**

```bash
git add commands/review-code.md
git commit -m "feat: port review-code command from Claude Code with 4-phase review workflow"
```

---

### Task 6: Port review-prs Command

**Files:**
- Modify: `commands/review-prs.md` (replace stub with full port)

- [ ] **Step 1: Write the ported command**

Replace the entire contents of `commands/review-prs.md` with the adapted command. Source: `~/.dotfiles/claude/commands/review-prs.md` (589 lines).

**Frontmatter changes:**
```yaml
---
description: Review open PRs with no human comments — learns from past reviews and accumulates knowledge across runs
---
```

**Body changes — search and replace:**

| Find | Replace | Reason |
|------|---------|--------|
| `~/.claude/pr-reviews/` | `~/.opencode/pr-reviews/` | OpenCode path convention |
| `pr-review-toolkit:silent-failure-hunter` | `silent-failure-hunter` | OpenCode agent names |
| `pr-review-toolkit:comment-analyzer` | `comment-analyzer` | Same |
| `pr-review-toolkit:type-design-analyzer` | `type-design-analyzer` | Same |
| `feature-dev:code-reviewer` | `code-reviewer` | Same |
| `the Agent tool` / `Use the Agent tool` | `the task tool` / `Use the task tool` | OpenCode tool name |
| `Claude Code` | `OpenCode` | Branding |
| `CLAUDE.md` (in convention markers) | `AGENTS.md` or `CLAUDE.md` | OpenCode convention |

**Phase 3 adaptation** — model references use `haiku` and `sonnet` without provider prefix. Add a note:

```markdown
**OpenCode note:** When dispatching agents with model selection, use `github-copilot/claude-haiku-4.5` for haiku and `github-copilot/claude-sonnet-4.6` for sonnet. Set the model in agent prompts or use the default model for sonnet-tier reviews.
```

**Phase 6 adaptation** — replace the agent dispatch mechanism:

```markdown
Launch review agents using the `task` tool with `subagent_type: "general"`. Select the model per PR based on size category. For each PR, create a `task` tool call with the full review prompt including all context from the template below.
```

**External directory** — ensure `/tmp/pr-reviews-*` is already in the `external_directory` allow-list in opencode.json (it is — confirmed in Task 1).

**One-time migration note** — Phase 0c references `~/.claude/pr-reviews/`. Update the migration to check BOTH old paths:

```markdown
### 0c: One-Time Migration

If `~/.claude/pr-reviews/learnings.md` exists OR `~/.opencode/pr-reviews/learnings.md` exists at the old flat path AND `~/.opencode/pr-reviews/{OWNER}/{REPO}/learnings.md` does NOT exist, move all files from the old path into `~/.opencode/pr-reviews/{OWNER}/{REPO}/`. Print a note that migration was performed.
```

- [ ] **Step 2: Verify the ported file**

Same checks as Task 4 Step 2. Additionally verify:
- All `~/.claude/` paths are replaced with `~/.opencode/`
- Model references include GitHub Copilot provider prefix
- The migration section handles both old path formats

- [ ] **Step 3: Commit**

```bash
git add commands/review-prs.md
git commit -m "feat: port review-prs command from Claude Code with 7-phase batch review pipeline"
```

---

### Task 7: Create prereq-checker Skill and /prereqs Command

**Files:**
- Create: `skills/prereq-checker/SKILL.md`
- Create: `commands/prereqs.md`

- [ ] **Step 1: Create the prereq-checker skill**

Create `skills/prereq-checker/SKILL.md`:

```markdown
---
name: prereq-checker
description: >-
  Check tool availability for the current session. Auto-detects required tools
  from project context or accepts an explicit list. Groups results by status
  and suggests install commands for missing tools.
---

# Prerequisite Checker

Check whether required CLI tools are available in the current environment.

## Step 1: Determine Required Tools

If the user provided specific tool names as arguments, check those.

Otherwise, auto-detect from project context by checking for these files:

| File | Tools to check |
|------|---------------|
| `package.json` | `node`, `npm` (or `yarn`, `pnpm`, `bun` if referenced in packageManager field) |
| `go.mod` | `go` |
| `Cargo.toml` | `cargo`, `rustc` |
| `pyproject.toml` / `requirements.txt` | `python3`, `pip` (or `uv`, `poetry` if referenced) |
| `Gemfile` | `ruby`, `bundle` |
| `mix.exs` | `elixir`, `mix` |
| `Dockerfile` / `docker-compose.yml` | `docker`, `docker-compose` |
| `.github/` directory | `gh` |
| `Makefile` / `justfile` | `make` / `just` |
| `Taskfile.yml` | `task` |

Always check these baseline tools regardless: `git`, `gh`.

## Step 2: Check Availability

For each tool, run:

```bash
command -v <tool> 2>/dev/null && <tool> --version 2>/dev/null | head -1
```

If `--version` fails, try `-v`, `-V`, or `version` subcommand. Record:
- Tool name
- Whether it exists (`command -v` exit code)
- Version string (if available)

## Step 3: Detect Environment

Check for devcontainer / remote environment:

```bash
# Devcontainer indicators
[ -f /.dockerenv ] && echo "Docker container detected"
[ -n "$REMOTE_CONTAINERS" ] && echo "VS Code devcontainer detected"
[ -d "/workspaces" ] && echo "Codespaces/devcontainer workspace detected"
[ -n "$CODESPACES" ] && echo "GitHub Codespaces detected"
```

Store the environment type — it affects install command suggestions.

## Step 4: Report Results

Group tools into three categories and present:

### Installed
List each tool with its version.

### Missing (Optional)
Tools that would be useful but aren't strictly required. No action needed.

### Missing (Required)
Tools that the project needs to build/run/test. Suggest install commands based on the detected environment:

| Environment | Package manager |
|-------------|----------------|
| Debian/Ubuntu container | `apt-get install -y <package>` |
| Alpine container | `apk add <package>` |
| macOS | `brew install <package>` |
| Generic Linux | `curl`/`wget` install commands or distro-agnostic methods |

## Step 5: Summary

Print a one-line summary:
```
Prerequisites: N/M installed (K required tools missing)
```

If all required tools are present: "All prerequisites satisfied."
```

- [ ] **Step 2: Create the /prereqs command**

Create `commands/prereqs.md`:

```markdown
---
description: Check tool availability for the current project environment
---

# Prerequisite Checker

Check that required tools are available in the current environment. $ARGUMENTS

## Context

- Current directory: !`pwd`
- OS: !`uname -s`

## Instructions

Load the `prereq-checker` skill using the skill tool and follow it exactly.

If $ARGUMENTS contains specific tool names (e.g., `/prereqs docker gh cr`), check only those tools.
If no arguments are provided, auto-detect required tools from the project context.
```

- [ ] **Step 3: Verify skill structure matches existing patterns**

```bash
ls skills/prereq-checker/SKILL.md
ls skills/code-simplifier/SKILL.md
```

Both should exist and follow the same frontmatter pattern (`name`, `description` fields).

- [ ] **Step 4: Commit**

```bash
git add skills/prereq-checker/ commands/prereqs.md
git commit -m "feat: add prereq-checker skill and /prereqs command"
```

---

### Task 8: Improve install.sh

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Add --check flag support**

Add argument parsing at the top of `main()`, before any operations. Insert after the `main() {` line:

```bash
main() {
    local check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
        log_info "Dry-run mode: showing what would be linked/installed"
    fi
```

- [ ] **Step 2: Add dry-run support to link_dir and link_file**

Add a global variable check in `link_dir` and `link_file`. At the end of each function, before the `ln -s` line, add:

```bash
    if [[ "$check_only" == true ]]; then
        log_info "[dry-run] Would link $src -> $dst"
        return
    fi
```

Note: `check_only` needs to be accessible. Change the `local` declaration in `main()` to a global by removing `local`:

```bash
main() {
    check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
        log_info "Dry-run mode: showing what would be linked/installed"
    fi
```

- [ ] **Step 3: Add dcp.jsonc symlink**

After the skill-linking loop (line 104), add:

```bash
    # Link DCP config if it exists
    if [ -f "$DOTFILES_ROOT/opencode/dcp.jsonc" ]; then
        link_file "$DOTFILES_ROOT/opencode/dcp.jsonc" "$HOME/.config/opencode/dcp.jsonc" "DCP config"
    fi
```

- [ ] **Step 4: Add npm install for .opencode dependencies**

After the dcp.jsonc linking, add:

```bash
    # Install plugin dependencies
    if [ -f "$DOTFILES_ROOT/opencode/.opencode/package.json" ]; then
        if [[ "$check_only" == true ]]; then
            log_info "[dry-run] Would run npm install in .opencode/"
        else
            log_info "Installing plugin dependencies..."
            (cd "$DOTFILES_ROOT/opencode/.opencode" && npm install --silent)
            log_success "Plugin dependencies installed."
        fi
    fi
```

- [ ] **Step 5: Add dry-run guard to install/update**

Wrap the install/update block in a dry-run check:

```bash
    if [[ "$check_only" == true ]]; then
        if command_exists opencode; then
            log_info "[dry-run] OpenCode is installed, would update"
        else
            log_info "[dry-run] OpenCode not installed, would install via npm"
        fi
    else
        if command_exists opencode; then
            log_info "OpenCode is already installed."
            update_opencode
        else
            if command_exists npm; then
                install_opencode
            else
                log_warning "npm not found. Install Node.js/npm first, then re-run."
                return 1
            fi
        fi
    fi
```

- [ ] **Step 6: Verify the complete install.sh**

Read the file and verify:
- `--check` flag is parsed
- `link_dir` and `link_file` respect dry-run mode
- `dcp.jsonc` is symlinked
- `.opencode/` npm install runs
- All operations have dry-run guards

Run: `bash install.sh --check` and verify it outputs dry-run messages without making changes.

- [ ] **Step 7: Commit**

```bash
git add install.sh
git commit -m "feat: improve install.sh with dcp.jsonc linking, npm install, and --check dry-run"
```

---

### Task 9: Populate Memory Blocks

**Non-file action:** Uses `memory_set` tool calls, not file edits.

- [ ] **Step 1: Set persona memory block (global)**

Use the `memory_set` tool:
- **scope:** `global`
- **label:** `persona`
- **value:**
```
Technical, direct communication. No filler or preamble.
Prioritize correctness over speed.
When reviewing code, check the full call chain — don't stop at the immediate change.
Use git worktrees for feature work that needs isolation.
Always run verification before claiming work is complete.
```

- [ ] **Step 2: Set human memory block (global)**

Use the `memory_set` tool:
- **scope:** `global`
- **label:** `human`
- **value:**
```
Primary languages: Go, TypeScript, Ruby, Elixir.
Uses GitHub Copilot as provider. Works across multiple repos.
Often works in devcontainers and remote environments.
Prefers commands over skills for bulk/batch operations (wants direct control).
Dotfiles repo at ~/.dotfiles — all config should be version-controlled and portable.
```

- [ ] **Step 3: Set project memory block (project)**

Use the `memory_set` tool:
- **scope:** `project`
- **label:** `project`
- **value:**
```
OpenCode configuration dotfiles. Symlinked to ~/.config/opencode/ via install.sh.
Structure: opencode.json, agents/, commands/, skills/, .opencode/
Plugins: superpowers (git), opencode-handoff, opencode-agent-memory, @tarquinen/opencode-dcp, opencode-usage, opencode-codegraph
Custom agents: 16 (3 implementation, 13 review). Custom commands: 7+. Custom skills: code-simplifier, ai-firstify, prereq-checker.
install.sh handles symlinking and merges existing files before replacing. Run with --check for dry-run.
```

- [ ] **Step 4: Verify memory blocks**

Use `memory_list` to confirm all three blocks are populated with the expected content.

---

### Task 10: Create AGENTS.md

**Files:**
- Create: `~/.dotfiles/AGENTS.md` (repo root, NOT inside opencode/)

- [ ] **Step 1: Write AGENTS.md**

Create `~/.dotfiles/AGENTS.md`:

```markdown
# OpenCode Configuration Dotfiles

This repository contains OpenCode (AI coding assistant) configuration, symlinked to `~/.config/opencode/` via `install.sh`.

## Structure

```
opencode/
  opencode.json          # Main config: model, permissions, plugins
  dcp.jsonc              # Dynamic context pruning config
  agents/                # 16 custom subagents (review + implementation)
  commands/              # Slash commands (brainstorm, fix-pr, review-code, etc.)
  skills/                # Custom skills (code-simplifier, ai-firstify, prereq-checker)
  .opencode/             # Plugin dependencies (package.json)
  install.sh             # Symlink setup script (--check for dry-run)
  docs/                  # Specs and implementation plans
```

## Conventions

- **All config lives in this dotfiles repo**, not directly in `~/.config/opencode/`. Changes go here, `install.sh` creates symlinks.
- **Agents** use `mode: subagent`. Review agents are `hidden: true` with `edit: deny` and restricted bash permissions. Implementation agents have broader permissions.
- **Commands that reference skills** should use the `skill` tool to load them, not inline the skill content.
- **Custom agents/commands override superpowers equivalents.** The custom `code-reviewer.md` agent and `brainstorm.md` command intentionally override the versions provided by the superpowers plugin. The custom versions have project-specific enhancements (confidence filtering for the reviewer, OpenCode-specific visual companion paths for brainstorm).

## Working in This Repo

When modifying config files:
1. Edit files in `~/.dotfiles/opencode/`
2. Run `./opencode/install.sh` to update symlinks (or `--check` for dry-run)
3. Restart OpenCode to pick up changes

When adding new skills, create a directory under `opencode/skills/<name>/` with a `SKILL.md` file. The install script will auto-discover and symlink it.

When adding new agents, add a `.md` file under `opencode/agents/`. Follow the existing frontmatter pattern for permissions.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: add AGENTS.md with repo structure and conventions"
```

Note: This file is at the dotfiles repo root (`~/.dotfiles/AGENTS.md`), so it will be read by OpenCode when working in any part of the dotfiles repo.

---

### Task 11: Verify Overlap Resolution

**Non-file action:** Manual testing in OpenCode.

- [ ] **Step 1: Test agent overlap**

Start a new OpenCode session in any project directory. Ask: "What agents are available? Show me the description for code-reviewer."

Verify: The custom `code-reviewer.md` description appears ("General code reviewer that catches bugs, logic errors, security issues, and quality problems with confidence filtering"), NOT the superpowers default.

If the custom one does NOT take priority, rename `agents/code-reviewer.md` to `agents/general-code-reviewer.md` and update references in the ported commands (fix-pr.md, review-code.md, review-prs.md).

- [ ] **Step 2: Test command overlap**

In the same session, check: "What commands are available? Show me /brainstorm."

Verify: The custom `brainstorm.md` with OpenCode-specific notes (visual companion paths, subagent execution guidance) is what appears.

- [ ] **Step 3: Document results**

If both custom versions take priority (expected): No changes needed — AGENTS.md already documents this.

If renaming was required: Update AGENTS.md to reflect the actual names used.

---

## Summary

| Task | Description | Depends On | Parallelizable |
|------|-------------|------------|----------------|
| 1 | Config fixes (opencode.json, package.json) | — | Yes |
| 2 | Move ai-firstify to dotfiles | — | Yes |
| 3 | Create DCP config | — | Yes |
| 4 | Port fix-pr command | — | Yes |
| 5 | Port review-code command | — | Yes |
| 6 | Port review-prs command | — | Yes |
| 7 | prereq-checker skill + command | — | Yes |
| 8 | Improve install.sh | Task 3 (needs dcp.jsonc to exist) | After Task 3 |
| 9 | Populate memory blocks | — | Yes |
| 10 | Create AGENTS.md | — | Yes |
| 11 | Verify overlap resolution | Tasks 1-10 | Last |

Tasks 1-7, 9, 10 are fully independent and can run in parallel.
Task 8 depends on Task 3 (dcp.jsonc must exist to be linked).
Task 11 should run last after all other changes are committed.
