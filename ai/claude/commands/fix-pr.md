---
name: fix-pr
description: Analyze a PR's open comments and failing CI checks, then produce a detailed implementation plan to resolve all issues
argument-hint: "<PR URL or number>"
allowed-tools: Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr checks:*), Bash(gh pr checkout:*), Bash(gh api:*), Bash(gh issue view:*), Bash(gh repo view:*), Bash(gh auth:*), Bash(gh run view:*), Bash(gh run list:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git status:*), Bash(git fetch:*), Bash(git diff:*), Bash(git show:*), Bash(ls:*), Bash(date:*), Bash(wc:*), Bash(cat:*), Bash(mkdir:*), Bash(echo:*), Read, Glob, Grep, Write, Task, Agent, Skill
---

# Fix PR — Implementation Plan Generator

You are analyzing a pull request to collect all open review comments and failing CI checks, then producing a comprehensive, actionable implementation plan to resolve every issue.

**Target PR**: $ARGUMENTS

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
- If the PR is merged or closed, warn the user but continue (they may still want the plan)
- Store all PR metadata for later use

Print: **"Analyzing PR #{PR_NUMBER}: {title}"**

### 0d: Set Up Output Directory

```
mkdir -p ~/.claude/pr-fix-plans/{OWNER}/{REPO}
```

---

## Phase 1: Gather PR Context

**Goal**: Build a complete picture of the PR — its purpose, the diff, linked issues, and the current state of the branch.

### 1a: Get the Full Diff

Run: `gh pr diff {PR_NUMBER} --repo {OWNER}/{REPO}`

Store the diff. If it exceeds 5000 lines, note which files were truncated and their line counts. Prioritize source files over generated files, lockfiles, and vendor directories.

### 1b: Get the Changed File List

Run: `gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json files --jq '.files[] | "\(.path) (+\(.additions) -\(.deletions))"'`

### 1c: Fetch Linked Issues

Parse the PR body for linked issues: `Fixes #N`, `Closes #N`, `Resolves #N`, `Related to #N`.

For each linked issue, run:
```
gh issue view {N} --repo {OWNER}/{REPO} --json title,body,labels,state
```

Store the issue context — it informs whether the PR is achieving its stated goal.

### 1d: Get the PR Description and Commit History

Run:
```
gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} --json commits --jq '.commits[] | "\(.oid[:8]) \(.messageHeadline)"'
```

This gives the full commit log for the PR branch.

---

## Phase 2: Collect All Open Review Comments

**Goal**: Retrieve every unresolved comment thread on the PR.

### 2a: Fetch Review Comments (Inline / File-Level)

Run:
```
gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/comments --paginate
```

For each comment, extract:
- `id`, `user.login`, `body`, `path`, `line` (or `original_line`), `diff_hunk`, `created_at`, `updated_at`
- `in_reply_to_id` — to group threads together
- `subject_type` — to distinguish line-level vs file-level comments

### 2b: Fetch PR-Level (Conversation) Comments

Run:
```
gh api repos/{OWNER}/{REPO}/issues/{PR_NUMBER}/comments --paginate
```

These are top-level conversation comments (not attached to specific lines). Extract:
- `id`, `user.login`, `body`, `created_at`

Filter out bot comments (where `user.type == "Bot"`) unless they contain actionable feedback.

### 2c: Fetch Formal Reviews

Run:
```
gh api repos/{OWNER}/{REPO}/pulls/{PR_NUMBER}/reviews --paginate
```

Extract:
- `id`, `user.login`, `state` (APPROVED, CHANGES_REQUESTED, COMMENTED), `body`

Focus on reviews with state `CHANGES_REQUESTED` or `COMMENTED` that have a non-empty body.

### 2d: Reconstruct Comment Threads

Group inline comments into threads using `in_reply_to_id`. For each thread:
1. Identify the **root comment** (no `in_reply_to_id`)
2. Chain all replies in chronological order
3. Determine if the thread is **resolved or open**:
   - Use GraphQL to check thread resolution status:
     ```
     gh api graphql -f query='
       query {
         repository(owner: "{OWNER}", name: "{REPO}") {
           pullRequest(number: {PR_NUMBER}) {
             reviewThreads(first: 100) {
               nodes {
                 isResolved
                 comments(first: 10) {
                   nodes {
                     id
                     databaseId
                     body
                     author { login }
                     path
                     line
                   }
                 }
               }
             }
           }
         }
       }
     '
     ```
   - Only include **unresolved threads** in the plan

### 2e: Summarize Collected Comments

Print a summary:
```
Found:
  - {N} unresolved inline comment threads across {M} files
  - {N} PR-level conversation comments with actionable feedback
  - {N} formal reviews requesting changes
```

---

## Phase 3: Collect Failing CI Checks

**Goal**: Identify all failing or errored CI checks and extract their failure details.

### 3a: Get Check Status

Run:
```
gh pr checks {PR_NUMBER} --repo {OWNER}/{REPO}
```

Parse the output to identify checks with status `fail` or `error`. Also note checks that are `pending` (they may become failures).

### 3b: Get Detailed Check Run Information

For each failing check, get the details. First list the check runs:
```
gh api repos/{OWNER}/{REPO}/commits/{HEAD_SHA}/check-runs --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required" or .conclusion == "timed_out") | {name: .name, conclusion: .conclusion, output_title: .output.title, output_summary: .output.summary, details_url: .details_url, html_url: .html_url}'
```

### 3c: Get CI Log Excerpts

For each failing check run, attempt to get the failure logs:

1. First try the check run annotations (these often contain the exact error):
   ```
   gh api repos/{OWNER}/{REPO}/check-runs/{CHECK_RUN_ID}/annotations
   ```
   Extract: `path`, `start_line`, `end_line`, `annotation_level`, `message`

2. If using GitHub Actions, try to get the workflow run logs:
   ```
   gh run view {RUN_ID} --repo {OWNER}/{REPO} --log-failed
   ```
   If the full log is too large, focus on the last 100 lines of each failed step.

3. Also check for commit status contexts (older CI systems):
   ```
   gh api repos/{OWNER}/{REPO}/commits/{HEAD_SHA}/status --jq '.statuses[] | select(.state == "failure" or .state == "error") | {context: .context, description: .description, target_url: .target_url}'
   ```

### 3d: Classify CI Failures

For each failure, classify it:
- **Build error**: Compilation / type checking failed
- **Test failure**: One or more tests failed
- **Lint / format**: Style or formatting violations
- **Security scan**: Vulnerability or policy violation
- **Deploy / integration**: Environment or integration issue
- **Timeout**: Job ran out of time
- **Flaky / infra**: Known flaky test or infrastructure issue (note if re-run might fix it)

### 3e: Summarize CI Status

Print:
```
CI Status:
  - {N} checks passing
  - {N} checks failing:
    - {check_name}: {classification} — {brief description}
  - {N} checks pending
```

---

## Phase 4: Analyze and Cross-Reference

**Goal**: Understand the relationships between comments, CI failures, and the code changes.

### 4a: Read Relevant Source Files

For each file mentioned in comments or CI failures, read the current version from the PR branch to understand the full context (not just the diff hunk):

Use the `gh api` to get file contents from the PR's head ref, or if the repo is locally available, read the files directly after fetching the branch.

### 4b: Cross-Reference Issues

Identify connections:
- Do any CI failures relate to the same files mentioned in review comments?
- Are there comments that conflict with each other? (Flag these for the user)
- Do any comments request changes that would affect other parts of the diff?
- Are there comments that are already addressed by subsequent commits but not yet resolved?

### 4c: Leverage Specialized Agents

While performing your own analysis, dispatch specialized agents in parallel to surface issues that reviewers and CI may have missed. These findings enrich the plan with preemptive fixes.

**Launch these agents in parallel on the PR's changed files:**

| Agent | subagent_type | Purpose |
|-------|---------------|---------|
| Silent failure hunter | `pr-review-toolkit:silent-failure-hunter` | Finds swallowed errors, empty catch blocks, fallbacks that hide failures |
| Code reviewer | `feature-dev:code-reviewer` | Catches bugs, logic errors, and security issues with confidence filtering |
| Code explorer | `feature-dev:code-explorer` | Traces execution paths and maps dependencies to understand impact of changes |

For each agent, provide:
- The list of changed files and their paths
- The PR diff and description
- Context about what the PR is trying to accomplish

**Important:**
- Only dispatch agents relevant to the changes (e.g. skip silent-failure-hunter if there's no error handling code)
- Launch all relevant agents in a single parallel call
- Incorporate agent findings into the plan as additional issues (clearly marked as "Proactive — not flagged by reviewers") in the Detailed Plan section
- If agents are unavailable or fail, proceed without them — agent findings are supplementary

### 4d: Assess Scope and Dependencies

For each issue, determine:
1. **Which files need to be modified** — be specific about file paths
2. **Whether changes are independent or interdependent** — if fixing issue A affects the approach for issue B, note the dependency
3. **Estimated complexity**: trivial (< 5 lines), small (5-20 lines), medium (20-50 lines), large (50+ lines)

---

## Phase 5: Generate the Implementation Plan

**Goal**: Produce a detailed, actionable markdown file that a developer (or AI agent) can follow step-by-step to resolve every issue.

Create the file at: `~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{PR_NUMBER}-plan.md`

If a plan for this PR already exists, archive it by renaming to `pr-{PR_NUMBER}-plan-{YYYY-MM-DD-HHMMSS}.md`.

### Plan Structure

```markdown
# Implementation Plan — PR #{PR_NUMBER}: {title}

**Repository**: {OWNER}/{REPO}
**PR URL**: {REPO_URL}/pull/{PR_NUMBER}
**Branch**: {headRefName} → {baseRefName}
**Author**: @{author}
**Generated**: {YYYY-MM-DD HH:MM}
**Status**: {open|closed|merged}

## PR Summary

{2-4 sentence summary of what the PR does, based on the description, linked issues, and the diff}

## Issues to Resolve

### Overview

| # | Source | File | Description | Complexity | Depends On |
|---|--------|------|-------------|------------|------------|
| 1 | Review comment by @user | `path/to/file.ts:42` | Brief description | Small | — |
| 2 | CI: test-suite | `path/to/file.test.ts` | Test assertion failure | Medium | #1 |
| 3 | Review comment by @user | General | Architecture concern | Large | — |
| ... | ... | ... | ... | ... | ... |

### Suggested Resolution Order

{Ordered list considering dependencies — which issues should be tackled first}

---

## Detailed Plan

### Issue 1: {Short title}

**Source**: {Review comment by @username | CI check: {name} | Formal review by @username}
**File(s)**: `{path/to/file}:{line}`
**Complexity**: {Trivial | Small | Medium | Large}

#### Context

{Quote the original comment or CI error verbatim in a blockquote}

> {exact comment text or error message}

{If part of a thread, include the full thread to show the discussion}

#### Current Code

```{language}
{The relevant code snippet from the PR diff, with enough context to understand the issue}
```

#### What Needs to Change

{Clear explanation of what's wrong and what the expected behavior/code should be}

#### Suggested Implementation

```{language}
{Concrete code showing the fix, or a detailed description of the approach if the fix is more complex}
```

#### Verification

- {How to verify this fix works — specific test to run, behavior to check, etc.}

---

### Issue 2: {Short title}
{... repeat the same structure for each issue ...}

---

## CI Failures

### {Check Name}: {Classification}

**Status**: {failure | error | timed_out}
**Details URL**: {url}

#### Error Output

```
{Exact error message or log excerpt}
```

#### Root Cause Analysis

{What is causing this failure — be specific. Reference the exact lines of code if possible.}

#### Fix

{Step-by-step instructions to fix this CI failure}

#### Files to Modify

- `{path/to/file}:{line}` — {what to change}

---

{... repeat for each CI failure ...}

## Conflicting Feedback

{If any comments conflict with each other, list them here}

- **Conflict**: @{user1} says "{X}" but @{user2} says "{Y}" on `{file}`
  - **Recommendation**: {Your suggested resolution, or flag for the developer to decide}

{If no conflicts, omit this section}

## Additional Recommendations

{Any improvements you noticed while analyzing the PR that aren't explicitly requested in comments but would strengthen the PR. Keep this brief and clearly label these as optional.}

## Checklist

- [ ] Issue 1: {short title}
- [ ] Issue 2: {short title}
- [ ] ...
- [ ] CI: {check name}
- [ ] ...
- [ ] All review threads resolved
- [ ] All CI checks passing
- [ ] Ready for re-review
```

---

## Phase 6: Final Output

### 6a: Print Summary to Console

After writing the plan file, print a concise summary:

```
Plan generated: ~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{PR_NUMBER}-plan.md

PR #{PR_NUMBER}: {title}
  - {N} review comment issues to resolve
  - {N} CI failures to fix
  - {N} conflicting comments flagged
  - Estimated total complexity: {sum of all issue complexities}

Resolution order:
  1. {Issue title} ({complexity})
  2. {Issue title} ({complexity})
  ...
```

### 6b: Offer Next Steps

Print:
```
Next steps:
  - Review the plan: Read ~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{PR_NUMBER}-plan.md
  - To start implementing, you can feed this plan back to Claude Code
```

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
