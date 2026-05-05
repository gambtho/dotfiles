---
name: polish
description: Analyze code changes, auto-fix high-confidence issues, and report remaining findings
argument-hint: "[commit ref — defaults to HEAD~1] [--fix] [--path <dir>]"
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git show:*), Bash(git status:*), Bash(git remote:*), Bash(git branch:*), Read, Edit, Glob, Grep, Agent
---

# Polish — Review & Fix

You are performing a thorough analysis of all changes since a specified commit, classifying findings by confidence and action type. By default, you report what would be fixed without making changes. With `--fix`, you apply high-confidence fixes and report the rest.

**Arguments**: $ARGUMENTS (default: `HEAD~1` if not specified)

Parse arguments:
- If `--fix` is present (in any position), set FIX_MODE=true and remove it from the commit reference.
- If `--path <prefix>` is present, set PATH_FILTER to the given prefix and remove both tokens from the arguments. This limits analysis to files under that directory.
- Remaining argument is the commit reference (default: `HEAD~1`).
- Examples: `/polish`, `/polish HEAD~5`, `/polish abc123 --fix`, `/polish --fix --path src/api HEAD~3`

---

## Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Resolve the target commit (use `HEAD~1` if not specified). If resolution fails, **STOP**.
3. Run `git log --oneline BASE_COMMIT..HEAD` and `git diff --stat BASE_COMMIT..HEAD`.
4. If there are no changes, print "No changes found since {BASE_COMMIT}" and **STOP**.
5. If the range includes merge commits (visible in the `git log` output), warn: "This range includes merge commits — the diff may include changes from merged branches. Consider a specific commit range that excludes merges."
6. Check for uncommitted changes with `git status --porcelain`. If present, warn: "You have uncommitted changes that are not included in this analysis. Commit or stash them first if you want them reviewed."
7. Print mode: "Mode: **report** (analyze only)" or "Mode: **fix** (analyze + apply fixes)" based on the `--fix` flag.

---

## Phase 1: Detect Stack & Conventions

Scan for language markers in the project root to determine the tech stack:

| Marker File | Language/Framework |
|---|---|
| `package.json`, `tsconfig.json` | JavaScript/TypeScript |
| `go.mod`, `go.sum` | Go |
| `Cargo.toml` | Rust |
| `Gemfile`, `*.gemspec` | Ruby |
| `pyproject.toml`, `setup.py`, `requirements.txt` | Python |
| `mix.exs` | Elixir |
| `pom.xml`, `build.gradle` | Java |
| `Makefile`, `CMakeLists.txt` | C/C++ (no language rules — general principles only) |

Convention sources (in priority order):
1. `CLAUDE.md` or `AGENTS.md` at project root (highest priority)
2. Linter/formatter configs (`.eslintrc*`, `golangci.yml`, `.rubocop.yml`, `ruff.toml`, etc.)
3. `CONTRIBUTING.md`, `STYLE.md`, or similar docs
4. Patterns sampled from surrounding (unchanged) files

**Load language rules** for the detected languages. Map file extensions from the diff to language rule files and read them from `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/`:

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` → `rules/typescript.md`
- `.py`, `.pyi` → `rules/python.md`
- `.rb`, `.erb`, `.rake` → `rules/ruby.md`
- `.go` → `rules/go.md`
- `.ex`, `.exs`, `.heex` → `rules/elixir.md`
- `.rs` → `rules/rust.md`
- `.java` → `rules/java.md`

Only load rules for languages actually present in the changed files.

Print detected stack summary:
```
Stack: Go, TypeScript
Conventions: CLAUDE.md, .eslintrc.json, golangci.yml, codebase patterns
Language rules loaded: go.md, typescript.md
```

---

## Phase 2: Gather the Diff

1. Run `git diff BASE_COMMIT..HEAD` to get the full diff.
2. Run `git diff --name-status BASE_COMMIT..HEAD` to get the file list with status (A/M/D/R).
3. If PATH_FILTER is set, filter the file list to only include files whose paths start with the given prefix.
4. Exclude binary files from analysis (identified by `git diff --stat` showing `Bin` or `git diff` showing `Binary files differ`).
5. If all remaining changes are deletions (all statuses are `D`), skip to Phase 5 with the message: "All changes are deletions — no new code to analyze. Verify that deleted code is not referenced elsewhere." Use Grep to check for remaining references to deleted exports/functions and include any findings in the report.
6. For each added or modified file, read the full current file contents (not just the diff hunks) — context is essential for dead code analysis and pattern detection.
7. Skip generated files: `*.lock`, `*.min.*`, `dist/`, `build/`, `vendor/`, `node_modules/`, `*.generated.*`, `*.pb.go`, `*_generated.ts`, `*.g.dart`, `migrations/`, `__snapshots__/`, `*.snap`.
8. Apply large diff tiers:
   - **Under 30 source files**: full analysis of all files.
   - **30-80 source files**: full diff for all, but only read full file contents for the top 20 files by lines changed. Note in the report which files had abbreviated analysis.
   - **Over 80 source files**: warn the user ("This diff spans N files. Analyzing the top 40 by change size. Run `/polish` with `--path` for targeted analysis of specific directories."). Analyze the top 40 files only.

---

## Phase 3: Analyze

This phase is **read-only with respect to file edits**. You MUST use Grep and Glob to search the codebase for references — all analysis should be grounded in actual search results, not guesses.

Each finding is classified with:
- **Confidence:** HIGH or MEDIUM
- **Action type:** `auto-fix` (will be applied in Phase 4 if `--fix` is set) or `report` (needs human review)

### 3a–3h: Find issues by category

Read `~/.dotfiles/ai/marketplace/plugins/my/commands/references/polish-categories.md` for the eight category definitions: bugs & security, idiomatic code, pattern adherence, duplication, over-engineering, comments, dead code & dead abstractions, structural simplification. Each category in the reference specifies what auto-fixes vs. what reports.

Core principles that hold across all categories:

- **Behavior preservation is paramount.** When in doubt between `auto-fix` and `report`, choose `report`. False positives in auto-fix erode trust.
- **Ground every finding in evidence.** Use Grep/Glob to verify before reporting — never flag something you can't point at a specific line for.
- **Bugs and security findings are always `report`.** Human verification required.
- **Naming changes are always `report`.** Subjective and the model lacks domain context.
- **Over-engineering findings are always `report`.** They require understanding intent.
- **Don't auto-fix nesting reductions in functions with cleanup logic** (`defer`, `finally`, `ensure`, `with`) — the transformation can change cleanup ordering.

Walk through each of 3a-3h from the reference and produce findings, classifying each as `auto-fix` (HIGH confidence + safe per the per-category rules) or `report` (everything else).

### 3i: Dispatch Subagents

Dispatch the following specialized subagents **in parallel** using the `Agent` tool (all calls in a single message):

1. **code-reviewer** (`subagent_type: "feature-dev:code-reviewer"`) — read-only, confidence-filtered general review. Scope to quality/fragility and suggestions — Phase 3a already covers bugs and security.
2. **silent-failure-hunter** (`subagent_type: "pr-review-toolkit:silent-failure-hunter"`) — finds swallowed errors and silent fallbacks
3. **comment-analyzer** (`subagent_type: "pr-review-toolkit:comment-analyzer"`) — focus exclusively on cross-referencing comment claims against actual code behavior. Skip tautological/noise/stale comment checks (Phase 3f handles those).
4. **type-design-analyzer** (`subagent_type: "pr-review-toolkit:type-design-analyzer"`) — reviews type/interface/struct design

Each subagent receives:
- The list of changed files and their paths
- The full diff from Phase 2
- The base commit and branch context
- The detected stack and conventions from Phase 1
- The change summary from Phase 2
- Instructions to format findings as: `[Severity|Confidence] file:line — description`

**Skip criteria:**
- Skip `type-design-analyzer` if the diff introduces no `interface`/`type`/`struct`/`class`/`enum`/`trait`/`protocol` definitions.
- Skip `comment-analyzer` if the diff contains fewer than 5 comment lines.
- Always dispatch `silent-failure-hunter` and `code-reviewer` (relevant to any code change).

**Deduplication:** After collecting subagent findings, merge them into the main findings list. Two findings are duplicates if they refer to the same file, overlapping line ranges (within 5 lines), and describe the same underlying issue regardless of categorization. When duplicates are found, keep the Phase 3 finding and drop the subagent duplicate. If a subagent finding adds new context to an existing Phase 3 finding, append the context rather than creating a duplicate. When in doubt, keep both findings.

**Timeout:** If a subagent has not completed after 90 seconds, proceed without its findings and note in the report: "Subagent {name} timed out — findings not included." If a subagent returns an error, log it and proceed.

Wait for all dispatched subagents to complete (or time out) before proceeding to Phase 4.

---

## Phase 4: Fix

**Skip this phase entirely if FIX_MODE is not set (the default).**

Apply all findings from Phase 3 that are classified as `auto-fix`. Use the Edit tool for each change. Process files one at a time, top-to-bottom within each file to avoid offset drift.

Auto-fix categories:
- Dead imports, unused variables, unreachable code → remove
- Dead parameters (only when unexported + single call site + not interface-bound) → remove from function signature and all call sites
- Dead branches (always-true/always-false conditions) → simplify to the live branch
- Early returns to reduce nesting → restructure with guard clauses (only when no `defer`/`finally`/`ensure`/`with` or cleanup logic)
- Language-specific idiom fixes → apply per loaded language rules
- Standard library replacements (semantically identical) → swap in standard library equivalent
- Tautological comments → remove
- Verified vestigial TODOs → remove
- **Import cleanup pass** — after all fixes above, scan each modified file for imports that became orphaned due to this phase's own changes. Before removing an import, Grep the entire file for all references to the imported name — only remove if zero references remain.

Log every change:

```
Fixing: src/handler.go:42 — Removing dead parameter `ctx`
Fixing: src/handler.go:58 — Early return to reduce nesting
Fixing: src/utils.go:12-18 — Removing unreachable code
Fixing: src/utils.go:1 — Removing orphaned import `fmt`
```

---

## Phase 5: Report

Generate the final report. Format depends on mode:

### Fix mode (after fixes applied):

```
POLISH REPORT — {BASE_COMMIT}..HEAD ({N} files, {N} languages)
═══════════════════════════════════════════════════════════════

FIXED ({N} items):
  ✓ file:line — Short description of what was fixed

NEEDS REVIEW ({N} items):
  Bugs & Security ({N}):
    1. ⚠ [Severity|Confidence] file:line — Description of the finding.
       Context: why this matters and what to verify.
       Suggested fix: concrete action to take (when the fix is clear).

  Over-Engineering ({N}):
    2. ⚠ [Severity|Confidence] file:line — Description.
       Context: ...

  Pattern Adherence ({N}):
    3. ⚠ [Severity|Confidence] file:line — Description.
       Context: ...

  ... (additional categories as needed)

SUMMARY:
  {N} items auto-fixed. {N} items need your review.
  Risk: {Low|Medium|High}. Most important unresolved: {description}.
```

### Report mode (default, no fixes applied):

Same format, but:
- "FIXED" becomes "WOULD FIX"
- "✓" becomes "→"
- Add note at top: "**Report mode** — no changes were made. Use `--fix` to apply auto-fixes."

### Report rules:

- Fixed/would-fix items: one line each (file:line + short description).
- Review items: include context — what was found, why it matters, what to verify. Where the fix is clear, include a concrete suggested action (e.g., "To fix: delete lines 30-45 and remove the corresponding test").
- **Group NEEDS REVIEW items by category** (Bugs & Security, Idiomatic Code, Codebase Patterns, Duplication, Over-Engineering, Comments, Dead Code, Structural). Within each category, sort by severity (Critical first, then Warning).
- **Number each NEEDS REVIEW item** sequentially across all categories for interactive follow-up.
- Subagent findings are merged into the appropriate category groups (not listed in separate blocks).
- Use severity/confidence tags: `[Critical|HIGH]`, `[Warning|MEDIUM]`, etc.
- Include subagent attribution in parentheses for findings that originated from a subagent: `(via code-reviewer)`, `(via silent-failure-hunter)`, etc.
- If there are zero fixed/would-fix items, omit the FIXED/WOULD FIX section.
- If there are zero review items, omit the NEEDS REVIEW section and congratulate briefly.

---

## Phase 6: Interactive Follow-Up

After presenting the report, offer to apply specific reported items:

"Apply any of these? (e.g., `apply 2,3` to fix items 2 and 3, or `skip` to leave as-is)"

If the user provides item numbers, apply those fixes using the Edit tool. If the user declines or does not respond, end.

---

## Important Notes

- **Behavior preservation is paramount.** Verify all auto-fixes are behavior-preserving. If unsure whether a change alters behavior, classify it as `report` rather than `auto-fix`.
- **Ground every finding in evidence.** Never report a finding unless you can point to a specific line and explain the concrete failure scenario. Do not hypothesize about what might go wrong in unrelated code paths. If you cannot construct a concrete example of the problem, do not report it.
- Focus on issues a senior engineer would flag during code review. Skip pedantic nitpicks that formatters and linters handle.
- Always ground your feedback in the actual codebase patterns — "the rest of the codebase does X, but this code does Y" is more useful than "best practice is X."
- When flagging over-engineering, be specific about the simpler alternative — don't just say "this is too complex."
- If the changes are trivially correct (e.g., fixing a typo, updating a version), say so briefly and don't force findings where there are none.
- When in doubt between `auto-fix` and `report`, choose `report`. False positives in auto-fix erode trust.
