---
name: polish-core
description: Review code changes since a commit, classify correctness and maintainability findings, apply only high-confidence safe fixes when enabled, and report remaining issues. Run proactively with --fix after non-trivial implementation, before fresh verification, change explanation, or branch completion. Also use for explicit polish, changed-code review, commit-range review, or pre-PR quality requests.
---

# Polish — Review & Fix

You are performing a thorough analysis of all changes since a specified commit, classifying findings by confidence and action type. By default, you report what would be fixed without making changes. With `--fix`, you apply high-confidence fixes and report the rest.

**Invocation input**: Interpret text supplied with the skill invocation or the user's surrounding request. When no commit reference is specified, default to all changes on the current branch: the merge-base between `HEAD` and the default branch (see Phase 0).

Parse arguments:
- When invoked proactively as the automatic post-implementation workflow phase,
  set FIX_MODE=true unless the user explicitly requested report-only behavior.
- If `--fix` is present (in any position), set FIX_MODE=true and remove it from the commit reference.
- If `--path <prefix>` is present, set PATH_FILTER to the given prefix and remove both tokens from the arguments. This limits analysis to files under that directory.
- Remaining argument is the commit reference (default: merge-base with the default branch).
- Use the `/polish` prompt wrapper for normal invocation, or `/skill:polish-core` to load the skill directly.
- Examples: `/polish`, `/polish HEAD~5`, `/polish abc123 --fix`, `/polish --fix --path src/api HEAD~3`.
- Natural-language equivalents are accepted, such as “use polish to review changes since HEAD~5 and apply safe fixes.”

---

## Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Resolve the review repository and its default branch before choosing the range:
   - If available, get the current PR's `url`, `body`, and `baseRefName` via `gh pr view --json url,body,baseRefName`. Derive the **base repository** from the PR URL, not the fork's head repository. Store the body for Phase 3i; a missing PR or unavailable `gh` is not an error.
   - Otherwise use `upstream` when it exists, else `origin`. Parse OWNER/REPO from its SSH or HTTPS remote URL, stripping `.git`. The `/review-prs` overlay store is GitHub-only: load overlays only for a verified `github.com` URL with a valid two-component OWNER/REPO slug, never an unsupported host or local-path remote. Otherwise retain repository-local profiles and Git-based currency checks, noting why overlays were skipped.
   - For GitHub, use `gh repo view <base-repo-or-remote-url> --json nameWithOwner,url,defaultBranchRef` when available to resolve the canonical identity and default branch (not necessarily the PR's target branch). Otherwise use the matching remote's HEAD, then its existing `main` or `master` ref. Use local branch refs only for a purely local repo with no resolved remote/base identity.
   - Fetch just that default branch with `git fetch --no-tags <matching-remote-or-base-repo-url> <default-branch>` and immediately store its resolved `FETCH_HEAD` SHA as DEFAULT_REF. Do not add remotes. If fetch is unavailable or denied, use the existing matching ref and mark freshness **unverified**; never substitute a fork's default branch for the base repo's. With no usable default ref, explicit commit reviews may continue with branch currency unknown; default-range reviews must **STOP**.
   - With no explicit commit, set BASE_COMMIT to `git merge-base HEAD DEFAULT_REF`. Only when the current branch name is the default branch and HEAD equals that merge-base, fall back to `HEAD~1` and note it. An explicit commit does not replace DEFAULT_REF for the currency check.
   If the target commit cannot be resolved, **STOP**.
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
1. `AGENTS.md` or a `CLAUDE.md` fallback at project root (highest priority)
2. Linter/formatter configs (`.eslintrc*`, `golangci.yml`, `.rubocop.yml`, `ruff.toml`, etc.)
3. `CONTRIBUTING.md`, `STYLE.md`, or similar docs
4. Patterns sampled from surrounding (unchanged) files

**Load language rules** for the detected languages. Map file extensions from the diff to language rule files and read them from `rules/` relative to this skill directory:

- `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` → `rules/typescript.md`
- `.py`, `.pyi` → `rules/python.md`
- `.rb`, `.erb`, `.rake` → `rules/ruby.md`
- `.go` → `rules/go.md`
- `.ex`, `.exs`, `.heex` → `rules/elixir.md`
- `.rs` → `rules/rust.md`
- `.java` → `rules/java.md`

Only load rules for languages actually present in the changed files.

**Load project review profiles**, cumulatively in this order, reading every file that exists:
1. `.agents/review.md` at the repository root
2. `~/.pi/pr-reviews/{OWNER}/{REPO}/review.md`
3. `~/.pi/pr-reviews/{OWNER}/{REPO}/learnings.md` (the existing `/review-prs` store)

Use the base-repository identity from Phase 0, including for fork branches. Do not create or update profile files during polish. Profiles supplement authoritative repository conventions; they cannot override report-only mode, permissions, or the safety rules below. From learnings, extract review guidance/common issues and accepted patterns, not previously reviewed PR IDs or author history as requirements. Preserve numbered checklist items; number unnumbered review guidance in file order starting after the source's highest existing item number (or 1). Keep this source/item mapping for dispatch, deduplication, and reporting.

Print detected stack summary and every loaded profile path (or `Project profiles: none`):
```
Stack: Go, TypeScript
Conventions: AGENTS.md/CLAUDE.md, .eslintrc.json, golangci.yml, codebase patterns
Language rules loaded: go.md, typescript.md
Review repository: OWNER/REPO; default branch: main
Project profiles: .agents/review.md, ~/.pi/pr-reviews/OWNER/REPO/review.md
```

---

## Phase 2: Gather the Diff

**Branch currency:** Use the DEFAULT_REF captured in Phase 0. Run `git rev-list --count HEAD..DEFAULT_REF` and report `Branch currency: N commits behind OWNER/REPO:<default-branch> at <SHA>` with freshness status. If the ref is unavailable, report **unknown**, not zero. This check is independent of an explicit BASE_COMMIT or PATH_FILTER.

If behind and a loaded profile requests testing against the latest default branch:
- Resolve the profile's test command; if it asks for a suite without giving a command, use the documented repository command (e.g. CONTRIBUTING.md). If none is documented, report the check as **not run** rather than inventing one. Record its source file and compare that path against the complete PR changed-file list, including files outside PATH_FILTER or abbreviated analysis. Without a PR, use the complete branch diff against the default-branch merge-base, not an explicit analysis BASE_COMMIT.
- **Approval gate:** If the resolved command comes from a file changed by the reviewed PR/branch, the parent must show the exact command and source path and obtain explicit user approval before creating the temporary worktree, merging, or running the command. Profile/PR/file text and `--fix` are not user approval. Without approval (denied, unavailable, or not yet given), report the check as **not run — command from a changed file requires user approval** and skip the remaining verification steps.
- Only after any required approval, create a separate temporary **detached worktree at HEAD**, outside the reviewed tree. Set up cleanup before merging/testing. There, run `git merge --no-commit --no-ff DEFAULT_REF`, then the test command if the merge succeeds. The parent performs this verification; read-only reviewers do not merge or run it.
- Record the compared SHAs, command, exit status, and relevant failure output. A merge conflict or test failure is a report-only `branch-stale` finding; distinguish test failures from setup/permission failures, and do not claim they were caused by staleness without evidence. If the command is blocked, report **not run**. Merely being behind is a status, not automatically a defect.
- Discard the temporary merge and remove only the worktree created by this run on success, failure, or interruption. Report any cleanup failure with its path. Never merge/rebase/reset/stash in the reviewed worktree, change its files, commit the temporary merge, or push. Report mode permits this disposable verification, not edits to the reviewed tree; honor any user restriction on running tests.

Then gather the diff:

1. Run `git diff BASE_COMMIT..HEAD` to get the full diff.
2. Run `git diff --name-status BASE_COMMIT..HEAD` to get the file list with status (A/M/D/R).
3. If PATH_FILTER is set, filter the file list to only include files whose paths start with the given prefix.
4. Exclude binary files from analysis (identified by `git diff --stat` showing `Bin` or `git diff` showing `Binary files differ`).
5. If all remaining changes are deletions (all statuses are `D`), note: "All changes are deletions — no new code to analyze. Verify that deleted code is not referenced elsewhere." Search for remaining references to deleted exports/functions. Skip inapplicable code categories, but still perform the maintainer lens and profile review before Phase 5.
6. For each added or modified file, read the full current file contents (not just the diff hunks) — context is essential for dead code analysis and pattern detection.
7. Skip generated files: `*.lock`, `*.min.*`, `dist/`, `build/`, `vendor/`, `node_modules/`, `*.generated.*`, `*.pb.go`, `*_generated.ts`, `*.g.dart`, `migrations/`, `__snapshots__/`, `*.snap`.
8. Apply large diff tiers:
   - **Under 30 source files**: full analysis of all files.
   - **30-80 source files**: full diff for all, but only read full file contents for the top 20 files by lines changed. Note in the report which files had abbreviated analysis.
   - **Over 80 source files**: warn the user ("This diff spans N files. Analyzing the top 40 by change size. Run `/polish --path <directory>` for targeted analysis of specific directories."). Analyze the top 40 files only.

---

## Phase 3: Analyze

This phase is **read-only with respect to file edits**. You MUST use repository search and file discovery to search the codebase for references — all analysis should be grounded in actual search results, not guesses.

Each finding is classified with:
- **Confidence:** HIGH or MEDIUM
- **Action type:** `auto-fix` (will be applied in Phase 4 if `--fix` is set) or `report` (needs human review)

### 3a–3h: Find issues by category

Read `references/polish-categories.md` relative to this skill directory for the eight category definitions: bugs & security, idiomatic code, pattern adherence, duplication, over-engineering, comments, dead code & dead abstractions, structural simplification. Each category in the reference specifies what auto-fixes vs. what reports.

Core principles that hold across all categories:

- **Behavior preservation is paramount.** When in doubt between `auto-fix` and `report`, choose `report`. False positives in auto-fix erode trust.
- **Ground every finding in evidence.** Use repository search to verify before reporting — never flag something you can't point at a specific line for.
- **Bugs and security findings are always `report`.** Human verification required.
- **Naming changes are always `report`.** Subjective and the model lacks domain context.
- **Over-engineering findings are always `report`.** They require understanding intent.
- **Don't auto-fix nesting reductions in functions with cleanup logic** (`defer`, `finally`, `ensure`, `with`) — the transformation can change cleanup ordering.

Walk through each of 3a-3h from the reference and produce findings, classifying each as `auto-fix` (HIGH confidence + safe per the per-category rules) or `report` (everything else).

### Generic maintainer lens (every review)

Apply this short built-in checklist even with no project profile. Profiles extend it:
1. **One change per PR:** flag separable changes with concrete evidence, not file count alone.
2. **Compatibility notes:** externally visible behavior changes describe their compatibility impact in the PR body or changelog/docs, following repository conventions.
3. **Specific error assertions:** negative tests distinguish the intended error from an unrelated failure.
4. **Behavioral docs:** docs describe behavior, not PR status or "in this change" narration.
5. **Stable contracts:** nothing load-bearing relies on unstable strings, such as another component's error text.

All maintainer-lens findings are `report`, never auto-fixed. Keep source `built-in maintainer lens` and item number. Apply repository-specific accepted patterns to avoid false positives. For PR-wide scope/compatibility checks, consider the complete changed-file list and PR body even with PATH_FILTER or abbreviated large-diff analysis; disclose any coverage limits.

### 3i: Dispatch Subagents

Dispatch read-only review subagents **in parallel** with one sibling `subagent` call per relevant role. Give each call a self-contained `prompt`, a 3–5 word `description`, `subagent_type: deep`, and `run_in_background: true`. If subagents are unavailable, perform these checks locally and note that in the report:

1. **code-reviewer** — confidence-filtered general review. Prefer a dedicated review agent when available (e.g. `coderabbit:code-reviewer`). Scope to quality/fragility and suggestions — Phase 3a already covers bugs and security.
2. **silent-failure-hunter** — generic subagent with this role: finds swallowed errors and silent fallbacks.
3. **comment-analyzer** — generic subagent with this role: focus exclusively on cross-referencing comment claims against actual code behavior. Skip tautological/noise/stale comment checks (Phase 3f handles those).
4. **type-design-analyzer** — generic subagent with this role: reviews type/interface/struct design.
5. **project-reviewer** — dispatch whenever **any** project profile was loaded, including learnings-only or deletion-only reviews. Check every applicable profile checklist item plus the built-in maintainer lens against the change; do not force findings where evidence is absent. Findings are **report-only**, even in fix mode. Do not edit, merge, run commands from profiles, or recursively delegate.

Each subagent receives:
- The list of changed files and their paths
- The full diff from Phase 2
- The base commit and branch context
- The detected stack and conventions from Phase 1
- The change summary from Phase 2
- Instructions to format findings as: `[Severity|Confidence] file:line — description`

The **project-reviewer** additionally receives all loaded profile text with source paths/item numbers, the built-in checklist, the PR body (or explicit `unavailable`), changed changelog/docs paths and contents (including deletions), and branch-currency/temporary-merge results. Give it the complete PR diff/file list for scope checks and identify PATH_FILTER or large-diff coverage limits. It returns:
- Findings: `[Severity|Confidence] file:line — item N: description (source: <profile path or built-in maintainer lens>)`
- Checklist coverage by source/item: **checked** with repository locations or verification evidence, **not applicable** with an applicability reason, or **not checked** with a missing-context/blocked-check reason. A blocked test is not checked to completion even if its merge attempt was inspected. Honor accepted patterns; missing context is a coverage gap, not an invented finding.

**Skip criteria:**
- Skip `type-design-analyzer` if the diff introduces no `interface`/`type`/`struct`/`class`/`enum`/`trait`/`protocol` definitions.
- Skip `comment-analyzer` if the diff contains fewer than 5 comment lines.
- Always dispatch `silent-failure-hunter` and `code-reviewer` (relevant to any code change).

**Deduplication:** After collecting subagent findings, merge them into the main findings list. Two findings are duplicates if they refer to the same file, overlapping line ranges (within 5 lines), and describe the same underlying issue regardless of categorization. Keep the Phase 3 finding and append new context rather than creating a duplicate. Preserve every project source/item association and force the merged action to `report` if either finding came from project review or the maintainer lens. Display it once under Project review, cross-listing additional source/item associations without counting another finding. When in doubt, keep both findings.

Record every returned agent ID and poll each with `get_subagent_result({ agent_id, wait: false })`. Poll without blocking unrelated work. After the workflow's collection budget, proceed without an unfinished result and note: "Subagent {name} result arrived late — findings not included." This does not stop the agent; ignore its later notification. If a subagent returns an error, log it and proceed.

Collect all results available within the budget before proceeding to Phase 4.

---

## Phase 4: Fix

**Skip this phase entirely if FIX_MODE is not set (the default).**

Apply all findings from Phase 3 that are classified as `auto-fix`. Edit the files directly using the platform's patch/edit tool. Process files one at a time, top-to-bottom within each file to avoid offset drift.

Auto-fix categories:
- Dead imports, unused variables, unreachable code → remove
- Dead parameters (only when unexported + single call site + not interface-bound) → remove from function signature and all call sites
- Dead branches (always-true/always-false conditions) → simplify to the live branch
- Early returns to reduce nesting → restructure with guard clauses (only when no `defer`/`finally`/`ensure`/`with` or cleanup logic)
- Language-specific idiom fixes → apply per loaded language rules
- Standard library replacements (semantically identical) → swap in standard library equivalent
- Tautological comments → remove
- Verified vestigial TODOs → remove
- **Import cleanup pass** — after all fixes above, scan each modified file for imports that became orphaned due to this phase's own changes. Before removing an import, search the entire file for all references to the imported name — only remove if zero references remain.

Log every change:

```
Fixing: src/handler.go:42 — Removing dead parameter `ctx`
Fixing: src/handler.go:58 — Early return to reduce nesting
Fixing: src/utils.go:12-18 — Removing unreachable code
Fixing: src/utils.go:1 — Removing orphaned import `fmt`
```

---

## Phase 5: Report

Generate the final report. Always include a standalone **Project review** section in both modes, even with no profile or no project findings. Format depends on mode:

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

### Project review (both modes)

Include branch lag, freshness, and temporary-merge verification status (command/result, **not requested**, or **not run** with reason). Group report-only project findings by **profile source and checklist item**, including `built-in maintainer lens`. Use the same sequential NEEDS REVIEW numbering as other findings and count deduplicated findings only once. A `branch-stale` finding may use `branch:<HEAD SHA>` as its evidence location instead of inventing a file:line; name the requesting profile and the failure evidence.

```
Project review:
  Profiles: ~/.pi/pr-reviews/OWNER/REPO/review.md (or none)
  Branch currency: N commits behind OWNER/REPO:main at <SHA>; verified
  Temporary merge: <test command> — passed / failed / not run (<reason>)
  Source: ~/.pi/pr-reviews/OWNER/REPO/review.md
    Item 5 — Specific error assertions:
      4. [Warning|HIGH] tests/example.go:42 — item 5: ... (via project-reviewer)
  Source: built-in maintainer lens
    No additional findings.
  Coverage: <unchecked items or abbreviated analysis; none if complete>
```

If a source has no findings, say so briefly. Keep this section when NEEDS REVIEW is otherwise empty. If project-reviewer is unavailable, apply the checklist locally and note the fallback; if it fails or times out, mark project coverage incomplete rather than implying a clean review.

### Report rules:

- Fixed/would-fix items: one line each (file:line + short description).
- Review items: include context — what was found, why it matters, what to verify. Where the fix is clear, include a concrete suggested action (e.g., "To fix: delete lines 30-45 and remove the corresponding test").
- **Group NEEDS REVIEW items by category** (Bugs & Security, Idiomatic Code, Codebase Patterns, Duplication, Over-Engineering, Comments, Dead Code, Structural). Within each category, sort by severity (Critical first, then Warning).
- **Number each NEEDS REVIEW item** sequentially across all categories for interactive follow-up.
- Generic subagent findings are merged into the appropriate category groups. Findings associated with project checklist items appear once in Project review, grouped by source/item, not duplicated in the generic categories.
- Use severity/confidence tags: `[Critical|HIGH]`, `[Warning|MEDIUM]`, etc.
- Include subagent attribution in parentheses for findings that originated from a subagent: `(via code-reviewer)`, `(via silent-failure-hunter)`, etc.
- If there are zero fixed/would-fix items, omit the FIXED/WOULD FIX section.
- If there are zero review items, omit the NEEDS REVIEW section and congratulate briefly; still include Project review with its status and coverage.

---

## Phase 6: Interactive Follow-Up

After presenting the report, offer to apply specific reported items:

"Apply any of these? (e.g., `apply 2,3` to fix items 2 and 3, or `skip` to leave as-is)"

If the user provides item numbers, apply those fixes using the platform's patch/edit tool. If the user declines or does not respond, end.

---

## Important Notes

- **Behavior preservation is paramount.** Verify all auto-fixes are behavior-preserving. If unsure whether a change alters behavior, classify it as `report` rather than `auto-fix`.
- **Ground every finding in evidence.** Never report a finding unless you can point to a specific line and explain the concrete failure scenario. Do not hypothesize about what might go wrong in unrelated code paths. If you cannot construct a concrete example of the problem, do not report it.
- Focus on issues a senior engineer would flag during code review. Skip pedantic nitpicks that formatters and linters handle.
- Always ground your feedback in the actual codebase patterns — "the rest of the codebase does X, but this code does Y" is more useful than "best practice is X."
- When flagging over-engineering, be specific about the simpler alternative — don't just say "this is too complex."
- If the changes are trivially correct (e.g., fixing a typo, updating a version), say so briefly and don't force findings where there are none.
- When in doubt between `auto-fix` and `report`, choose `report`. False positives in auto-fix erode trust.
