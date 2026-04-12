---
name: polish
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
argument-hint: "[commit ref — defaults to HEAD~1] [--fix] [--path <dir>]"
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git show:*), Bash(git status:*), Bash(git remote:*), Bash(git branch:*), Read, Edit, Glob, Grep, Agent
---

# Polish — Review & Fix

This command follows the same workflow as the OpenCode `/polish` command, adapted for Claude Code.

**Arguments**: $ARGUMENTS (default: `HEAD~1` if not specified)

## Adaptation Notes

This is the Claude Code version. Key differences from the OpenCode canonical version:
- Agent dispatch: Use the `Agent` tool (Claude's native subagent mechanism)
- Agent subagent_types use Claude Code namespaces: `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `pr-review-toolkit:type-design-analyzer`, `feature-dev:code-reviewer`
- Convention detection: Check for `CLAUDE.md` (in addition to `AGENTS.md`)
- Language rules: Read rule files directly from `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/` using the Read tool (map file extensions from the diff to the appropriate rule file)
- Editing: Use `Edit` tool for auto-fixes in Phase 4 (same as OpenCode)

## Full Workflow

Follow the complete polish workflow from the canonical version with these phases:

### Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Parse `--fix` flag and `--path <prefix>` from arguments if present.
3. Resolve the target commit (use `HEAD~1` if not specified). If resolution fails, **STOP**.
4. Run `git log --oneline BASE_COMMIT..HEAD` and `git diff --stat BASE_COMMIT..HEAD`.
5. If there are no changes, print "No changes found since {BASE_COMMIT}" and **STOP**.
6. Warn about merge commits if present in the range.
7. Warn about uncommitted changes if `git status --porcelain` shows any.
8. Print mode: "Mode: **report** (analyze only)" or "Mode: **fix** (analyze + apply fixes)" based on the `--fix` flag.

### Phase 1: Detect Project Stack & Conventions

Scan for language markers (`package.json`, `go.mod`, `Cargo.toml`, etc.), convention sources (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, linter configs), and sample existing codebase patterns. Read matching language rule files from `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/` for detected languages.

### Phase 2: Gather the Diff

Get the full diff and file list. Apply `--path` filter if set. Exclude binary and generated files. Read full current versions of modified/added files for context. Apply large diff tiers (30/80 file thresholds from canonical version).

### Phase 3: Analyze

At the start of Phase 3, **read the canonical polish command** at `~/.dotfiles/ai/opencode/commands/polish.md` for the full analysis criteria and Phase 5 report format. Classify each finding with confidence (HIGH/MEDIUM) and action type (auto-fix/report).

Key rules (see canonical for full details):
- **Dead imports, unused variables, unreachable code**: `auto-fix` at HIGH confidence
- **Naming improvements**: always `report`, never auto-fix
- **Dead parameters**: `report` by default; only auto-fix when unexported + single call site + not interface-bound
- **Standard library replacements**: `auto-fix` when semantically identical, `report` when behavioral differences exist
- **All bugs/security**: always `report`
- **All over-engineering**: always `report`

### Phase 3h: Structural Simplification

Reduce nesting via early returns and guard clauses. Auto-fix at HIGH confidence when the transformation is unambiguous. Do NOT auto-fix in functions containing `defer`, `finally`, `ensure`, `with` (Python context manager), or any cleanup/teardown logic — classify as `report` instead.

### Phase 3i: Dispatch Subagents

Dispatch relevant agents in parallel using the `Agent` tool:
- Silent failure hunter (`pr-review-toolkit:silent-failure-hunter`) — always dispatch
- Code reviewer (`feature-dev:code-reviewer`) — always dispatch, scope to quality/fragility
- Comment analyzer (`pr-review-toolkit:comment-analyzer`) — skip if <5 comment lines; focus on comment-vs-code accuracy only
- Type design analyzer (`pr-review-toolkit:type-design-analyzer`) — skip if no new `interface`/`type`/`struct`/`class`/`enum`/`trait`/`protocol` definitions

Deduplicate: same file + overlapping lines (within 5) + same issue = duplicate. Phase 3 findings take precedence. Timeout: proceed after 90 seconds without a subagent's findings. If an agent returns an error, note it and proceed. Wait for all dispatched agents to complete or time out before proceeding to Phase 4.

### Phase 4: Fix (skip unless --fix)

Apply all `auto-fix` findings using the Edit tool. Process files one at a time, top-to-bottom within each file to avoid offset drift. After all fixes, run an import cleanup pass — Grep each file for references before removing imports.

### Phase 5: Report

Generate the polish report (see canonical for full format):
- **Report mode** (default): WOULD FIX items + NEEDS REVIEW items grouped by category + numbered for interactive follow-up
- **Fix mode**: FIXED items + NEEDS REVIEW items grouped by category + numbered
- Include subagent attribution in parentheses: `(via code-reviewer)`, `(via silent-failure-hunter)`, etc.
- End with SUMMARY block: risk level (Low/Medium/High), most important unresolved finding, count of items
- If zero fixed/would-fix items, omit that section. If zero review items, omit NEEDS REVIEW and congratulate briefly.

### Phase 6: Interactive Follow-Up

Offer to apply specific reported items by number.

---

## Important Notes

- **Behavior preservation is paramount.** Verify all auto-fixes are behavior-preserving. If unsure whether a change alters behavior, classify it as `report` rather than `auto-fix`.
- In report mode (default), do NOT make any changes. Report what WOULD be fixed.
- In fix mode (`--fix`), auto-fix high-confidence issues and report the rest.
- Ground every finding in evidence — never report without a specific line and concrete failure scenario.
- Focus on issues a senior engineer would flag. Skip pedantic nitpicks that formatters and linters handle.
- Ground feedback in actual codebase patterns.
- When flagging over-engineering, be specific about the simpler alternative.
- When in doubt between auto-fix and report, choose report.
