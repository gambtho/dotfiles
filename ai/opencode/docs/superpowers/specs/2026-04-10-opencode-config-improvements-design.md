# OpenCode Config Improvements — Design Spec

**Date:** 2026-04-10
**Status:** Draft
**Scope:** Surgical fixes + selective structural reorganization of OpenCode config

## Overview

Comprehensive improvements to the OpenCode configuration at `~/.dotfiles/opencode/` (symlinked to `~/.config/opencode/`). The goal is to fix known issues, reduce friction, improve context management in long sessions, port substantial Claude Code commands, and add strategic new capabilities — while preserving full portability (`git clone dotfiles && ./install.sh`).

## 1. Immediate Config Fixes

### 1.1 Update Model

Change `github-copilot/claude-sonnet-4.5` to `github-copilot/claude-sonnet-4.6` in `opencode.json`.

### 1.2 Expand Bash Allow-List

Add these commands to the `permission.bash` allow-list in `opencode.json`:

**File inspection:** `cat *`, `wc *`, `find *`, `rg *`
**Language runtimes:** `python *`, `python3 *`, `ruby *`, `elixir *`, `mix *`, `bundle *`, `cargo *`
**Tooling:** `docker *`, `docker-compose *`, `jq *`, `curl *`, `wget *`

These should be set to `allow` to eliminate permission prompts for routine operations.

### 1.3 Unpin Plugin Version

Change `.opencode/package.json` from pinning `@opencode-ai/plugin` to `1.4.3` to using `"^1.4.3"` (semver range). This allows patch and minor updates automatically while protecting against breaking major version changes.

### 1.4 Move ai-firstify Skill Into Dotfiles

Move `~/.config/opencode/skills/ai-firstify/` into `~/.dotfiles/opencode/skills/ai-firstify/` for version control. The existing `install.sh` already iterates `skills/*/` and symlinks each into `~/.config/opencode/skills/`, so no install.sh changes are needed for this item.

## 2. Structural Cleanup

### 2.1 Resolve Agent Overlap

The custom `agents/code-reviewer.md` has the same filename as the agent provided by the superpowers plugin. OpenCode's load order is: global config → project config → global dir → project dir. Since our custom agents are symlinked into the global config dir (`~/.config/opencode/agents/`), and superpowers registers its agent via the plugin system (loaded from global config), we need to verify which takes precedence.

**Action:** Test priority by starting OpenCode and checking which agent description appears for `code-reviewer` (via `/agents` or by asking which agents are available). Per OpenCode docs, plugin-provided content loads from global config first, then local files override. If the custom one already takes priority (expected), document this in AGENTS.md. If not, rename the custom agent to `general-code-reviewer.md` and update any commands/specs that reference it by name.

### 2.2 Resolve Command Overlap

Same situation: custom `commands/brainstorm.md` vs superpowers' `brainstorm.md`. The custom one adds OpenCode-specific notes (visual companion paths, subagent execution guidance) that the superpowers version lacks.

**Action:** Same approach as 2.1 — verify the custom brainstorm.md takes priority. The custom version should win since it's in the global config directory. Document the override in AGENTS.md.

### 2.3 Port Claude Commands to OpenCode

Replace the 3 stub commands with full OpenCode ports of the original Claude Code commands:

#### fix-pr.md (from 489-line Claude original)

Port the 6-phase workflow:
- Phase 0: Setup & validation (gh auth, parse PR argument, validate PR exists)
- Phase 1: Gather PR context (diff, changed files, linked issues, commit history)
- Phase 2: Collect open review comments (inline, PR-level, formal reviews, thread reconstruction via GraphQL)
- Phase 3: Collect failing CI checks (check status, detailed run info, log excerpts, classify failures)
- Phase 4: Analyze and cross-reference (read source files, dispatch specialized review agents)
- Phase 5: Generate implementation plan (structured markdown output)
- Phase 6: Final output (summary + next steps)

**Adaptations required:**
- Replace Claude Code `Task` tool references with OpenCode `task` tool (subagent_type: "general")
- Replace `~/.claude/pr-fix-plans/` path with `~/.opencode/pr-fix-plans/` or `/tmp/pr-fix-plans/`
- Adjust any Claude-specific permission or tool syntax to OpenCode equivalents
- Keep the GraphQL queries for comment collection as-is (they call `gh api graphql`)

#### review-code.md (from 315-line Claude original)

Port the 4-phase workflow:
- Phase 0: Validate environment (git repo check, resolve commit)
- Phase 1: Detect project stack & conventions
- Phase 2: Gather the diff
- Phase 3: Perform review with specialized agent dispatch (silent-failure-hunter, comment-analyzer, type-design-analyzer, code-reviewer)
- Phase 4: Compile structured review report

**Adaptations:**
- Agent dispatch uses OpenCode's `task` tool with matching `subagent_type` values
- The specialized agents already exist in our `agents/` directory with matching names

#### review-prs.md (from 589-line Claude original)

Port the 7-phase batch pipeline:
- Phase 0: Detect repository & preflight (auth, repo detection, rate limit check)
- Phase 1: Load persistent learnings from review history
- Phase 2: Detect project stack (auto-generate review checklist)
- Phase 3: Learn review style from merged PRs with reviews
- Phase 4: Discover unreviewed PRs (filter drafts, already-reviewed, batch-check via GraphQL)
- Phase 5: Set up worktrees for parallel review
- Phase 6: Parallel review with model selection by PR size
- Phase 7: Compile report, update learnings, clean up worktrees

**Adaptations:**
- Replace `~/.claude/pr-reviews/` persistent learnings path with `~/.opencode/pr-reviews/` or a project-relative path
- Worktree setup uses the existing `using-git-worktrees` skill from superpowers
- Model selection per PR size: use OpenCode model config (haiku for small PRs, sonnet for medium/large)
- Agent dispatch via `task` tool

**Important:** These remain commands, not skills. The user wants direct control and visibility, especially for review-prs which does bulk operations.

### 2.4 New Skill: prereq-checker

Create `skills/prereq-checker/SKILL.md` — a skill that checks tool availability for the current session.

**Behavior:**
- Accept an optional list of required tools, or auto-detect from project context (package.json, Gemfile, go.mod, mix.exs, Cargo.toml, Dockerfile, etc.)
- Check each tool's availability via `command -v` or equivalent
- Group results: installed, missing-optional, missing-required
- Detect devcontainer environment (check for `/.dockerenv`, `REMOTE_CONTAINERS` env var, `/workspaces/` path)
- Suggest install commands appropriate to the environment (apt, brew, apk, etc.)

**New command:** `commands/prereqs.md` that invokes this skill.

## 3. Context & Memory

### 3.1 Configure DCP Plugin

Create a proper `dcp.jsonc` in the dotfiles (symlinked to `~/.config/opencode/dcp.jsonc`) with these settings:

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

**Rationale for non-default values:**
- `maxContextLimit: "60%"` and `minContextLimit: "30%"` — GitHub Copilot models have smaller effective context windows than direct API; percentage-based scales automatically
- `nudgeFrequency: 3` — more aggressive than default (5) to address context loss pain point
- `iterationNudgeThreshold: 10` — lower than default (15) for earlier compression during long agent chains
- `purgeErrors.turns: 3` — slightly more aggressive error pruning than default (4)
- `pruneNotification: "minimal"` — reduce noise while keeping awareness

The `dcp.jsonc` file should be added to the dotfiles and symlinked by `install.sh`.

### 3.2 Populate Memory Blocks

Memory blocks persist across sessions. There are two scopes:
- **global** (`~/.config/opencode/memory/`): `persona.md` and `human.md` — shared across all projects
- **project** (`.opencode/memory/`): `project.md` — specific to the current project/repo

**Persona block** (global — how the AI should behave):
```
Technical, direct communication. No filler or preamble.
Prioritize correctness over speed.
When reviewing code, check the full call chain — don't stop at the immediate change.
Use git worktrees for feature work that needs isolation.
Always run verification before claiming work is complete.
```

**Human block** (global — about the user):
```
Primary languages: Go, TypeScript, Ruby, Elixir.
Uses GitHub Copilot as provider. Works across multiple repos.
Often works in devcontainers and remote environments.
Prefers commands over skills for bulk/batch operations (wants direct control).
Dotfiles repo at ~/.dotfiles — all config should be version-controlled and portable.
```

**Project block** (project-scoped — about this specific dotfiles repo):
```
OpenCode configuration dotfiles. Symlinked to ~/.config/opencode/ via install.sh.
Structure: opencode.json, agents/, commands/, skills/, .opencode/
Plugins: superpowers (git), opencode-handoff, opencode-agent-memory, @tarquinen/opencode-dcp
Custom agents: 16 (3 implementation, 13 review). Custom commands: 7. Custom skills: code-simplifier, ai-firstify.
install.sh handles symlinking and merges existing files before replacing.
```

These are populated via the `memory_set` tool, not by editing files directly.

### 3.3 Add AGENTS.md

Create `AGENTS.md` at the dotfiles repo root (`~/.dotfiles/AGENTS.md`). This file is automatically read by OpenCode when working in this repo.

**Contents:**
- Brief repo overview (dotfiles for OpenCode, symlinked via install.sh)
- Config structure reference (what's where)
- Notes on overlaps (custom code-reviewer.md and brainstorm.md override superpowers versions intentionally)
- Convention: agents use `mode: subagent`, review agents are `hidden: true` with `edit: deny`
- Convention: commands that reference skills should use `skill` tool to load them
- Convention: all config must live in dotfiles, not directly in ~/.config/opencode/

## 4. Plugin Evaluation & New Capabilities

### 4.1 Add New Plugins

**opencode-usage** — Cost/token tracking across sessions. Add to `opencode.json` plugin array.

**opencode-codegraph** — CPG-powered code analysis for deeper structural understanding. Add to `opencode.json` plugin array.

**Rejected:**
- `oh-my-opencode` — too much overlap with superpowers
- `@kodrunhq/opencode-autopilot` — overlapping agents/skills
- Extra memory plugins — already have `opencode-agent-memory`
- `opencode-multiplexer`, `opencode-scheduler` — too niche for current workflow

### 4.2 Improve install.sh

Add to `install.sh`:
- Symlink `dcp.jsonc` to `~/.config/opencode/dcp.jsonc`
- Run `npm install` (or `bun install`) in `.opencode/` to ensure plugin dependencies are installed
- Add a `--check` flag for dry-run mode that reports what would be linked/installed without making changes

### 4.3 Add /prereqs Command

Create `commands/prereqs.md` that invokes the `prereq-checker` skill. Usage: `/prereqs` with optional arguments like `/prereqs docker gh cr` to check specific tools.

## Summary of Deliverables

| # | Item | Type | Files Changed |
|---|------|------|---------------|
| 1.1 | Update model | Config edit | `opencode.json` |
| 1.2 | Expand bash allow-list | Config edit | `opencode.json` |
| 1.3 | Unpin plugin version | Config edit | `.opencode/package.json` |
| 1.4 | Move ai-firstify to dotfiles | File move | `skills/ai-firstify/` |
| 2.1 | Resolve agent overlap | Investigation + doc | `AGENTS.md` |
| 2.2 | Resolve command overlap | Investigation + doc | `AGENTS.md` |
| 2.3 | Port fix-pr command | New command | `commands/fix-pr.md` |
| 2.3 | Port review-code command | New command | `commands/review-code.md` |
| 2.3 | Port review-prs command | New command | `commands/review-prs.md` |
| 2.4 | prereq-checker skill | New skill | `skills/prereq-checker/SKILL.md` |
| 2.4 | /prereqs command | New command | `commands/prereqs.md` |
| 3.1 | Configure DCP | New config | `dcp.jsonc` |
| 3.2 | Populate memory blocks | Memory tool | (via memory_set) |
| 3.3 | Add AGENTS.md | New file | `AGENTS.md` |
| 4.1 | Add plugins | Config edit | `opencode.json` |
| 4.2 | Improve install.sh | Script edit | `install.sh` |

## Out of Scope

- Auditing/rewriting individual agent prompt quality (separate task)
- Evaluating alternative memory plugins beyond opencode-agent-memory
- Creating new review agents for additional languages
- Modifying the superpowers plugin itself
