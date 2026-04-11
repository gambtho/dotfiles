---
name: fix-pr
description: Analyze a PR's open comments and failing CI checks, then produce a detailed implementation plan to resolve all issues
argument-hint: "<PR URL or number>"
allowed-tools: Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr checks:*), Bash(gh pr checkout:*), Bash(gh api:*), Bash(gh issue view:*), Bash(gh repo view:*), Bash(gh auth:*), Bash(gh run view:*), Bash(gh run list:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git status:*), Bash(git fetch:*), Bash(git diff:*), Bash(git show:*), Bash(ls:*), Bash(date:*), Bash(wc:*), Bash(cat:*), Bash(mkdir:*), Bash(echo:*), Read, Glob, Grep, Write, Task, Agent, Skill
---

# Fix PR — Implementation Plan Generator

This command follows the same workflow as the OpenCode `/fix-pr` command, adapted for Claude Code.

**Target PR**: $ARGUMENTS

## Adaptation Notes

This is the Claude Code version. Key differences from the OpenCode canonical version:
- Output directory: `~/.claude/pr-fix-plans/{OWNER}/{REPO}/` (not `~/.opencode/`)
- Agent dispatch: Use the `Agent` tool (Claude's native subagent mechanism)
- Agent subagent_types use Claude Code namespaces: `pr-review-toolkit:silent-failure-hunter`, `feature-dev:code-reviewer`, `feature-dev:code-explorer`
- Convention detection: Check for `CLAUDE.md` (in addition to `AGENTS.md`)
- Next steps reference: "feed this plan back to Claude Code"

## Full Workflow

Follow the complete fix-pr workflow below. The phases are identical to the OpenCode version.

If no argument is provided, print this error and **STOP**:
```
ERROR: Please provide a PR URL or number.
Usage: /fix-pr <PR URL or number>
Examples:
  /fix-pr https://github.com/owner/repo/pull/123
  /fix-pr 123
```

---

## Phase 0: Setup & Validation

### 0a: Verify GitHub Auth

Run: `gh auth status`
- If this fails, print this error and **STOP**:
  ```
  ERROR: GitHub CLI is not authenticated. Please run 'gh auth login' first.
  ```

### 0b: Parse the PR Argument

The argument can be:
1. **A full URL**: `https://github.com/{OWNER}/{REPO}/pull/{NUMBER}` — extract OWNER, REPO, and NUMBER
2. **A bare number**: `123` — use the current repo context

For a bare number:
1. Run: `gh repo view --json owner,name,url --jq '{owner: .owner.login, name: .name, url: .url}'`
2. If this fails, try: `git remote get-url origin` and parse `{OWNER}/{REPO}` from the URL
3. If both fail, print this error and **STOP**:
   ```
   ERROR: Could not detect a GitHub repository from the current directory.
   Please provide a full PR URL or run this command from within a cloned GitHub repository.
   ```

Store: `OWNER`, `REPO`, `PR_NUMBER`, `REPO_URL`

### 0c: Validate the PR Exists

Run: `gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json number,title,author,state,headRefName,baseRefName,body,url,additions,deletions,changedFiles,headRefOid`

- If this fails, print an error and **STOP**
- If the PR is merged or closed, warn the user but continue
- Store all PR metadata for later use

Print: **"Analyzing PR #{PR_NUMBER}: {title}"**

### 0d: Set Up Output Directory

```
mkdir -p ~/.claude/pr-fix-plans/{OWNER}/{REPO}
```

---

## Phases 1-6: Core Workflow

Follow the same phases as documented in the OpenCode `/fix-pr` command:

1. **Phase 1: Gather PR Context** — diff, file list, linked issues, commit history
2. **Phase 2: Collect All Open Review Comments** — inline, PR-level, formal reviews, thread reconstruction via GraphQL
3. **Phase 3: Collect Failing CI Checks** — status, detailed check runs, log excerpts, classification
4. **Phase 4: Analyze and Cross-Reference** — read source files, cross-reference issues, dispatch specialized agents (using `Agent` tool with `pr-review-toolkit:*` and `feature-dev:*` namespaces), assess scope
5. **Phase 5: Generate the Implementation Plan** — write to `~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{PR_NUMBER}-plan.md`
6. **Phase 6: Final Output** — print summary and next steps

---

## Important Notes

- Do NOT post any comments to GitHub. All output is local only.
- Do NOT modify any code. This command only produces a plan.
- Do NOT run builds, tests, or linters — just analyze existing CI results.
- Use `gh` for all GitHub interactions, never web fetch.
- **Shell escaping**: Never use `!=` in jq filters inside bash command substitutions. Always use `select(.field == "value" | not)` instead of `select(.field != "value")` to avoid zsh/bash history expansion issues with `!` inside `$()`.
- If the PR has no open comments AND all CI checks pass, say so clearly and skip plan generation.
- When quoting comments, preserve them exactly — do not paraphrase reviewer feedback.
- If a comment thread shows the issue was already addressed (author replied with a fix commit), note it in the plan as "Likely resolved — verify" rather than omitting it.
- Be specific about file paths and line numbers. Vague instructions like "fix the tests" are not acceptable — say exactly which test, which assertion, and what the expected behavior should be.
