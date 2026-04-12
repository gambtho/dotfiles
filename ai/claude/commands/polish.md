---
name: polish
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
argument-hint: "[commit ref — defaults to HEAD~1] [--dry-run]"
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git show:*), Bash(git status:*), Bash(git remote:*), Bash(git branch:*), Read, Write, Edit, Glob, Grep, Task, Agent, Skill
---

# Polish — Review & Fix

This command follows the same workflow as the OpenCode `/polish` command, adapted for Claude Code.

**Arguments**: $ARGUMENTS (default: `HEAD~1` if not specified)

## Adaptation Notes

This is the Claude Code version. Key differences from the OpenCode canonical version:
- Agent dispatch: Use the `Agent` tool (Claude's native subagent mechanism)
- Agent subagent_types use Claude Code namespaces: `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `pr-review-toolkit:type-design-analyzer`, `feature-dev:code-reviewer`
- Convention detection: Check for `CLAUDE.md` (in addition to `AGENTS.md`)
- Skill loading: Use `Skill` tool to load `code-simplifier` for language rules
- Editing: Use `Edit` tool for auto-fixes in Phase 4 (same as OpenCode)

## Full Workflow

Follow the complete polish workflow with these phases:

### Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Parse `--dry-run` flag from arguments if present.
3. Resolve the target commit (use `HEAD~1` if not specified). If resolution fails, **STOP**.
4. Run `git log --oneline BASE_COMMIT..HEAD` and `git diff --stat BASE_COMMIT..HEAD`.
5. If there are no changes, print "No changes found" and **STOP**.

### Phase 1: Detect Project Stack & Conventions

Scan for language markers (`package.json`, `go.mod`, `Cargo.toml`, etc.), convention sources (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, linter configs), and sample existing codebase patterns. Load matching language rules from the code-simplifier skill's `rules/` directory.

### Phase 2: Gather the Diff

Get the full diff and file list. Read full current versions of modified/added files for context.

### Phase 3: Analyze

Classify each finding with confidence (HIGH/MEDIUM) and action type (auto-fix/report/info).

- **3a: Bugs & Security** — logic errors, null safety, race conditions, injection, hardcoded secrets, auth issues
- **3b: Idiomatic Code** — language-specific idiom checks informed by loaded language rules
- **3c: Codebase Pattern Adherence** — naming, organization, error handling, imports, testing, API, logging patterns
- **3d: Duplication Detection** — existing utilities, standard library alternatives, near-duplicate logic
- **3e: Over-Engineering** — over-abstraction, premature generalization, unnecessary indirection, speculative generality, premature DRY, deep abstraction stacks, config-driven complexity, defensive copies
- **3f: Comment Quality** — tautological, stale, noise, journal comments vs. valuable why/warning/context comments
- **3g: Dead Code & Dead Abstractions** — dead exports, dead parameters, dead branches, orphaned abstractions, stale feature flags, dead error handling, vestigial TODOs

### Phase 3h: Dispatch Subagents

Dispatch relevant agents in parallel using the `Agent` tool:
- Silent failure hunter (`pr-review-toolkit:silent-failure-hunter`)
- Comment analyzer (`pr-review-toolkit:comment-analyzer`)
- Type design analyzer (`pr-review-toolkit:type-design-analyzer`)
- Code reviewer (`feature-dev:code-reviewer`)

Only dispatch agents relevant to the changes. Deduplicate: Phase 3 findings take precedence over subagent duplicates. Merge unique subagent findings by file location.

### Phase 4: Fix (skip if --dry-run)

Apply all `auto-fix` findings using the Edit tool. After all fixes, run an import cleanup pass to remove orphaned imports.

### Phase 5: Report

Generate the polish report with FIXED/WOULD FIX items, NEEDS REVIEW items, and summary.

---

## Important Notes

- In dry-run mode, do NOT make any changes. Report what WOULD be fixed.
- In normal mode, auto-fix high-confidence issues and report the rest.
- Focus on issues a senior engineer would flag. Skip pedantic nitpicks that formatters and linters handle.
- Ground feedback in actual codebase patterns.
- When flagging over-engineering, be specific about the simpler alternative.
