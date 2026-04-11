---
name: review-code
description: Review code changes since a specified commit for quality, idiomacy, patterns, and unnecessary complexity
argument-hint: "[commit ref — defaults to HEAD~1]"
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git show:*), Bash(git status:*), Bash(git remote:*), Bash(git branch:*), Read, Glob, Grep, Task, Agent, Skill
---

# Code Review Since Commit

This command follows the same workflow as the OpenCode `/review-code` command, adapted for Claude Code.

**Commit reference**: $ARGUMENTS (default: `HEAD~1` if not specified — i.e. review the most recent commit)

## Adaptation Notes

This is the Claude Code version. Key differences from the OpenCode canonical version:
- Agent dispatch: Use the `Agent` tool (Claude's native subagent mechanism)
- Agent subagent_types use Claude Code namespaces: `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `pr-review-toolkit:type-design-analyzer`, `feature-dev:code-reviewer`
- Convention detection: Check for `CLAUDE.md` (in addition to `AGENTS.md`)
- Conventions applied label uses `"CLAUDE.md, .eslintrc, codebase patterns"` format

## Full Workflow

Follow the complete review-code workflow with these phases:

### Phase 0: Validate Environment

1. Run `git rev-parse --is-inside-work-tree` to confirm we're in a git repo. If not, print an error and **STOP**.
2. Resolve the target commit (use `HEAD~1` if not specified). If resolution fails, **STOP**.
3. Run `git log --oneline BASE_COMMIT..HEAD` and `git diff --stat BASE_COMMIT..HEAD`.
4. If there are no changes, print "No changes found" and **STOP**.

### Phase 1: Detect Project Stack & Conventions

Scan for language markers (`package.json`, `go.mod`, `Cargo.toml`, etc.), convention sources (`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, linter configs), and sample existing codebase patterns from modified files.

### Phase 2: Gather the Diff

Get the full diff and file list. Read full current versions of modified/added files for context.

### Phase 3: Perform the Review

Review all changed files for:
- **3a: Code Quality** — bugs, error handling, security, debug statements, resource cleanup
- **3b: Idiomatic Code** — language-specific idiom checks (JS/TS, Python, Go, Rust, Ruby, Java, C/C++)
- **3c: Codebase Pattern Adherence** — naming, organization, error handling, imports, testing, API, logging patterns
- **3d: Duplication Detection** — search for existing overlapping utilities, standard library alternatives, near-duplicate logic
- **3e: Unnecessary Complexity** — over-abstraction, premature generalization, over-engineering, unnecessary indirection
- **3f: Comment Quality** — tautological, stale, noise, journal comments vs. valuable why/warning/context comments

### Phase 3.5: Leverage Specialized Agents

Dispatch relevant agents in parallel using the `Agent` tool:
- Silent failure hunter (`pr-review-toolkit:silent-failure-hunter`)
- Comment analyzer (`pr-review-toolkit:comment-analyzer`)
- Type design analyzer (`pr-review-toolkit:type-design-analyzer`)
- Code reviewer (`feature-dev:code-reviewer`)

Only dispatch agents relevant to the changes. Merge findings into the report.

### Phase 4: Compile the Review

Present findings grouped by: Critical, Improvements, Duplication, Simplifications, Noisy Comments, Nits, Positive. Include file-by-file notes with `file_path:line_number` references.

---

## Important Notes

- Do NOT make any changes to the code. This is a read-only review.
- Focus on issues a senior engineer would flag during code review. Skip pedantic nitpicks that formatters and linters handle.
- Always ground your feedback in the actual codebase patterns.
- Be balanced — include positive findings where warranted.
- When flagging complexity, be specific about the simpler alternative.
