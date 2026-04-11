---
name: review-prs
description: Review open PRs with no human comments — learns from past reviews and accumulates knowledge across runs
argument-hint: "[number of PRs to review, default 10]"
allowed-tools: Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr checkout:*), Bash(gh api:*), Bash(gh issue view:*), Bash(gh repo view:*), Bash(gh auth:*), Bash(git worktree:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git status:*), Bash(git fetch:*), Bash(rm -rf /tmp/pr-reviews-*), Bash(mkdir:*), Bash(ls:*), Bash(date:*), Bash(wc:*), Bash(cat:*), Bash(mv:*), Bash(for:*), Bash(echo:*), Bash(cd:*), Read, Glob, Grep, Write, Task, Agent, Skill
---

# PR Review Pipeline

This command follows the same workflow as the OpenCode `/review-prs` command, adapted for Claude Code.

**Number of PRs to review**: $ARGUMENTS (default: 10 if not specified)

## Adaptation Notes

This is the Claude Code version. Key differences from the OpenCode canonical version:
- Output directory: `~/.claude/pr-reviews/{OWNER}/{REPO}/` (not `~/.opencode/`)
- Agent dispatch: Use the `Agent` tool (Claude's native subagent mechanism)
- Agent subagent_types use Claude Code namespaces: `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `pr-review-toolkit:type-design-analyzer`, `feature-dev:code-reviewer`
- Model references: Use `haiku` and `sonnet` (generic names, Claude resolves them)
- Convention detection: Check for `CLAUDE.md` (in addition to `AGENTS.md`)
- Migration: Checks `~/.claude/pr-reviews/` for legacy flat-path data

## Full Workflow

Follow the complete PR review pipeline with these phases:

### Phase 0: Detect Repository & Preflight Checks
- Verify GitHub auth (`gh auth status`)
- Detect repository (OWNER/REPO) from `gh repo view` or `git remote`
- Set output directory: `~/.claude/pr-reviews/{OWNER}/{REPO}/`
- One-time migration from flat path if needed
- Rate limit check (`gh api rate_limit`)

### Phase 1: Load Persistent Learnings
- Read `~/.claude/pr-reviews/{OWNER}/{REPO}/learnings.md` if it exists
- Extract previously reviewed PR numbers and HEAD SHAs for skip/re-review detection
- Check if style guide is mature enough to skip Phase 3
- Load optional `config.md` for project-specific review conventions

### Phase 2: Detect Project Stack
- Scan for language markers, framework markers, convention markers
- Build a stack-specific review checklist from detected technologies

### Phase 3: Learn Review Style (skippable if learnings are mature)
- Fetch 15 most recently merged PRs with review comments
- Use parallel Haiku agents to analyze review tone, priorities, detail level
- Synthesize into a Review Style Guide

### Phase 4: Discover Unreviewed PRs
- List open PRs, filter out drafts and previously-reviewed
- Batch-check for human comments via GraphQL
- Select and categorize by size (Lockfile-only, Small, Medium, Large, Very Large)
- Assign model tier: `haiku` for small, `sonnet` for medium+

### Phase 5: Set Up Worktrees
- Clean stale worktrees from previous runs
- Create isolated checkouts for Medium/Large PRs
- Small and Very Large PRs reviewed from diff only

### Phase 6: Parallel Review
- Launch review agents in batches of up to 5 (2 if rate-limited)
- For Medium+ PRs, agents dispatch sub-agents: silent-failure-hunter, comment-analyzer, type-design-analyzer, code-reviewer
- Each agent returns structured findings with `[Severity|Confidence]` format

### Phase 7: Compile Report, Update Learnings & Clean Up
- Write `~/.claude/pr-reviews/{OWNER}/{REPO}/review-{date}.md`
- Update `learnings.md` with new observations, reviewed PR list, session log
- Remove worktrees and temp directories

---

## Important Notes

- Do NOT post comments to GitHub. All output is local only.
- Do NOT run builds, tests, or linters — assume CI handles that separately.
- Use `gh` for all GitHub interactions, never web fetch.
- **Shell escaping**: Never use `!=` in jq filters inside bash command substitutions. Always use `select(.field == "value" | not)` instead of `select(.field != "value")`.
- When reviewing, focus on issues a senior engineer would flag. Skip pedantic nitpicks.
- Always include positive findings — balanced reviews are more useful.
- If a PR is Very Large (>1500 lines), provide summary and key concerns only.
- If CONTRIBUTING.md or CLAUDE.md exist, treat their guidelines as authoritative.
