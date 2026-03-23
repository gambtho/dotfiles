---
name: review-prs
description: Review open PRs with no human comments — learns from past reviews and accumulates knowledge across runs
argument-hint: "[number of PRs to review, default 10]"
allowed-tools: Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr checkout:*), Bash(gh api:*), Bash(gh issue view:*), Bash(gh repo view:*), Bash(gh auth:*), Bash(git worktree:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git status:*), Bash(git fetch:*), Bash(rm -rf /tmp/pr-reviews-*), Bash(mkdir:*), Bash(ls:*), Bash(date:*), Bash(wc:*), Bash(cat:*), Bash(mv:*), Bash(for:*), Bash(echo:*), Bash(cd:*), Read, Glob, Grep, Write, Task, Agent, Skill
---

# PR Review Pipeline

You are reviewing open pull requests for the current repository that have not yet received human review comments. You will learn from existing review patterns, then produce detailed reviews saved to a local markdown file.

**Number of PRs to review**: $ARGUMENTS (default: 10 if not specified)

---

## Phase 0: Detect Repository & Preflight Checks

**Goal**: Identify the GitHub repository, verify auth, and check API quota.

### 0a: Verify GitHub Auth

Run: `gh auth status`
- If this fails, print this error and **STOP**:
  ```
  ERROR: GitHub CLI is not authenticated. Please run 'gh auth login' first.
  ```

### 0b: Detect Repository

1. Run: `gh repo view --json owner,name,url --jq '{owner: .owner.login, name: .name, url: .url}'`
2. If this fails, try: `git remote get-url origin` and parse `{OWNER}/{REPO}` from the URL (handles both SSH `git@github.com:owner/repo.git` and HTTPS `https://github.com/owner/repo.git` formats)
3. If both fail, print this error and **STOP** — do not proceed:
   ```
   ERROR: Could not detect a GitHub repository from the current directory.
   Please run this command from within a cloned GitHub repository.
   This command requires a GitHub-hosted repository (GitLab, Bitbucket, etc. are not supported).
   ```
4. Store these values for use in ALL subsequent phases:
   - `OWNER` — the repository owner (e.g., `kubernetes-sigs`)
   - `REPO` — the repository name (e.g., `headlamp`)
   - `REPO_URL` — the full GitHub URL (e.g., `https://github.com/kubernetes-sigs/headlamp`)
5. Set the output directory: `~/.claude/pr-reviews/{OWNER}/{REPO}/`
   - Create it with `mkdir -p` if it does not exist
6. Print: **"Reviewing PRs for: {OWNER}/{REPO}"**

### 0c: One-Time Migration

If `~/.claude/pr-reviews/learnings.md` exists at the old flat path AND `~/.claude/pr-reviews/{OWNER}/{REPO}/learnings.md` does NOT exist, move all files from `~/.claude/pr-reviews/` (excluding subdirectories) into `~/.claude/pr-reviews/{OWNER}/{REPO}/`. Print a note that migration was performed.

### 0d: Rate Limit Check

Run: `gh api rate_limit --jq '.rate.remaining'`
- If remaining < 100, warn the user and set `RATE_LIMITED=true` — reduce all parallel agent batches to 2 instead of 5 for the rest of the run.
- If remaining < 20, warn the user and **STOP** — not enough quota to proceed.

---

## Phase 1: Load Persistent Learnings

**Goal**: Bootstrap from accumulated knowledge of previous review runs.

1. Read `~/.claude/pr-reviews/{OWNER}/{REPO}/learnings.md` (if it exists)
2. If it exists and has substantial content:
   - Note the review style guidance, common issues, and false positive patterns
   - Extract the **Previously Reviewed PRs** list — store as a set of PR numbers to skip. Also store any HEAD SHAs recorded alongside them (for re-review detection in Phase 4).
   - Check the "Review Style Guide" section: if it has **8+ bullet points** AND the "Last updated" date is **within the last 7 days**, set `SKIP_STYLE_LEARNING=true` (Phase 3 will be skipped entirely)
   - Otherwise, reduce the number of merged PRs studied in Phase 3 to 5
3. If it does not exist, proceed with full style learning

### Load Project Config (Optional)

Read `~/.claude/pr-reviews/{OWNER}/{REPO}/config.md` if it exists. This file contains user-defined review conventions that supplement the auto-detected checklist:
- Commit message format requirements
- License header expectations
- Additional checklist items specific to this project
- Known false positives / accepted patterns

If this file does not exist, proceed without it. You will suggest creating one in the final report.

---

## Phase 2: Detect Project Stack

**Goal**: Automatically determine the project's technology stack to generate a relevant review checklist.

Examine the repository root to identify frameworks, languages, and conventions. Check for:

### Language Markers
| File | Language/Platform |
|------|------------------|
| `package.json` | Node.js / JavaScript / TypeScript |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pyproject.toml` or `requirements.txt` or `setup.py` | Python |
| `pom.xml` or `build.gradle` or `build.gradle.kts` | Java / Kotlin |
| `Gemfile` | Ruby |
| `mix.exs` | Elixir |
| `*.csproj` or `*.sln` | C# / .NET |

### Framework & Tooling Markers (check `package.json` dependencies if it exists)
| Marker | Stack |
|--------|-------|
| `"react"` in dependencies | React frontend |
| `"@mui/material"` in dependencies | MUI component library |
| `.storybook/` directory | Storybook stories expected |
| `"vitest"` in devDependencies | Vitest test framework |
| `"jest"` in devDependencies | Jest test framework |
| `"next"` in dependencies | Next.js |
| `"vue"` in dependencies | Vue.js |
| `angular.json` | Angular |
| `tailwind.config.*` | Tailwind CSS |
| `"i18next"` or `"react-i18next"` in dependencies | i18n expected |
| `"express"` or `"fastify"` or `"koa"` in dependencies | Node.js backend |

### Convention Markers
| File | Convention |
|------|-----------|
| `LICENSE` | Read it to determine expected license type |
| `CONTRIBUTING.md` | Read for contribution guidelines (commit format, PR requirements) |
| `CLAUDE.md` | Read for project-specific coding guidelines |
| `.eslintrc*` or `eslint.config.*` | ESLint style conventions in use |
| `.prettierrc*` | Prettier formatting in use |
| `Makefile` or `justfile` | Build/task conventions |

### Build the Review Checklist

Based on what you detect, compose the **Stack-Specific Checklist** by selecting relevant items from the menu below. Only include sections for technologies actually detected in this project.

**JavaScript/TypeScript (if detected):**
- TypeScript types are correct (no `any` unless justified)
- No `console.log` or debug statements left in production code
- Async/await error handling is correct (no unhandled promise rejections)
- Dependencies added to the correct section (dependencies vs devDependencies)

**React (if detected):**
- Components follow existing patterns in the codebase
- Props are properly typed
- Effects have correct dependency arrays
- No unnecessary re-renders from object/function references in render

**MUI (if detected):**
- Uses MUI components consistently (not raw HTML for styled UI elements)
- Theme-aware colors used (no hardcoded colors that break dark mode)

**Storybook (if detected):**
- New components have Storybook stories (`.stories.tsx` / `.stories.jsx`)
- Stories cover meaningful states (not just default rendering)

**i18n (if detected):**
- User-facing strings are internationalized (wrapped in `t()` / `useTranslation`)

**Vitest/Jest (if detected):**
- Tests use the project's test framework and assertion patterns
- Tests follow existing patterns (React Testing Library, etc.)

**Go (if detected):**
- All errors are checked and handled
- Exported functions have doc comments
- No goroutine leaks (goroutines have proper lifecycle management)
- Input validation for external data (no command injection, path traversal)
- Tests use the project's assertion library (testify, standard, etc.)

**Rust (if detected):**
- Proper use of `Result` and `Option` types
- No unnecessary `unwrap()` / `expect()` in library code
- Lifetime annotations are correct

**Python (if detected):**
- Type hints present on public functions
- Proper exception handling (no bare `except:`)
- No security issues (SQL injection, command injection, path traversal)

**Java/Kotlin (if detected):**
- Proper null handling
- Resources properly closed (try-with-resources)
- Thread safety considered for shared state

**License Header (if LICENSE file detected):**
- License header present on new source files matching the project's license

**Commit Message Format (if CONTRIBUTING.md specifies one, or config.md defines one):**
- Commit messages follow the project's required format

Print the composed checklist so the user can see what will be checked.

---

## Phase 3: Learn Review Style

**Goal**: Understand how this project's maintainers give code review feedback.

**Skip condition**: If `SKIP_STYLE_LEARNING=true` (set in Phase 1 because learnings already have a mature style guide updated within 7 days), skip this entire phase and print: "Using existing review style guide from learnings (last updated: {date})."

1. Fetch the 15 most recently merged PRs that have review comments:
   ```
   gh pr list --state merged --limit 30 --json number,title,reviews,reviewDecision
   ```
   Filter to those that actually have reviews with comments (not just approvals).

2. For the top 15 with comments (or top 5 if learnings already exist), use parallel Haiku agents (3-5 at a time, or 2 if RATE_LIMITED) to fetch and analyze review comments:
   ```
   gh api repos/{OWNER}/{REPO}/pulls/{number}/reviews
   gh api repos/{OWNER}/{REPO}/pulls/{number}/comments
   ```
   Each agent should analyze 3-5 PRs and return:
   - Common tone patterns (direct? gentle? question-based?)
   - Types of feedback given (bugs, style, architecture, testing, etc.)
   - Level of detail in comments
   - Whether reviewers suggest alternatives or just flag issues
   - Notable phrases or conventions used

3. Synthesize the findings into a brief **Review Style Guide** to inform your reviews. This should be 5-10 bullet points capturing the voice and priorities.

---

## Phase 4: Discover Unreviewed PRs

**Goal**: Find open PRs that need review attention.

### 4a: List and Filter Candidates

1. List all open PRs:
   ```
   gh pr list --state open --limit 50 --json number,title,author,createdAt,labels,body,headRefName,changedFiles,additions,deletions,isDraft,headRefOid
   ```
   Note: `headRefOid` is the HEAD SHA — needed for re-review detection.

2. **Immediately filter out** from the candidate list:
   - Draft PRs
   - PR numbers that appear in the "Previously Reviewed PRs" list from learnings (UNLESS the stored HEAD SHA differs from the current `headRefOid` — those go into a separate **"updated since last review"** list)

3. If 0 candidates remain after filtering (all PRs are drafts, already reviewed, or already have human comments), print a summary and **STOP** cleanly:
   ```
   No PRs to review. All {N} open PRs are either drafts, previously reviewed, or already have human comments.
   {M} PRs were updated since last review — consider re-reviewing: #X, #Y, #Z
   ```

### 4b: Batch-Check for Human Comments

For the remaining candidates, check for human review activity. Use a **single GraphQL query** to batch-check all PRs at once instead of sequential API calls:

```
gh api graphql -f query='
  query {
    repository(owner: "{OWNER}", name: "{REPO}") {
      pr1: pullRequest(number: {n1}) { number reviews(first: 1, states: [COMMENTED, CHANGES_REQUESTED, APPROVED]) { totalCount } comments(first: 1) { totalCount } }
      pr2: pullRequest(number: {n2}) { number reviews(first: 1, states: [COMMENTED, CHANGES_REQUESTED, APPROVED]) { totalCount } comments(first: 1) { totalCount } }
      ...
    }
  }
'
```

This checks BOTH formal reviews AND PR comments (inline/general) in a single request. A PR has human review activity if `reviews.totalCount > 0` OR `comments.totalCount > 0`.

**Important**: GraphQL queries have a node limit. If there are more than 30 candidate PRs, split into batches of 30.

**Fallback** if GraphQL fails: use the REST approach with parallel checks (batch with `&` and `wait`):
```
for pr in {numbers}; do
  echo "$pr $(gh api repos/{OWNER}/{REPO}/pulls/$pr/reviews --jq '[.[] | select(.user.type == "Bot" | not)] | length') $(gh api repos/{OWNER}/{REPO}/pulls/$pr/comments --jq 'length')" &
done
wait
```

Filter to PRs where BOTH review count AND comment count are 0.

### 4c: Select and Categorize

1. Select the N most recent unreviewed PRs (where N is the argument, default 10)

2. For each selected PR, collect:
   - PR number, title, author, branch name
   - PR body/description
   - Linked issue numbers (parse from PR body: "Fixes #NNN", "Closes #NNN", "Resolves #NNN")
   - Changed file count, additions, deletions
   - List of changed file paths: `gh pr view {number} --json files --jq '.files[].path'`

3. Categorize each PR by size and type:
   - **Lockfile-only**: All changed files match `*lock*`, `*.lock`, `go.sum`, `*.sum` — will review from diff only, no worktree, use `haiku` model
   - **Small** (< 100 lines changed): Review from diff only, no worktree, use `haiku` model
   - **Medium** (100–500 lines changed): Standard review with worktree, use `sonnet` model
   - **Large** (500–1500 lines changed): Extended review with worktree, agent focuses on highest-impact files, use `sonnet` model
   - **Very Large** (> 1500 lines changed): Summary and key concerns only, use `sonnet` model

4. If any PRs were detected as "updated since last review", include them at the end of the list (marked as re-reviews) if there is room within the N limit.

5. Print a summary table of the PRs that will be reviewed (including size category and model) and proceed.

---

## Phase 5: Set Up Worktrees

**Goal**: Create isolated checkouts so multiple agents can review different PRs simultaneously.

### 5a: Stale Cleanup

Check for leftover directories from previous failed runs for THIS repo only:
```
ls -d /tmp/pr-reviews-{OWNER}-{REPO}-* 2>/dev/null
```
If any exist, remove them with `git worktree remove` (for any registered worktrees) then `rm -rf`, and note the cleanup.

### 5b: Create Worktrees

1. Create a temporary directory:
   ```
   mkdir -p /tmp/pr-reviews-{OWNER}-{REPO}-$(date +%s)
   ```
   Store the full timestamp directory path for cleanup later.

2. For each **Medium** or **Large** PR, create a worktree. Wrap each in error handling:
   ```
   gh pr view {number} --json headRefName --jq '.headRefName'
   git worktree add /tmp/pr-reviews-{OWNER}-{REPO}-{ts}/pr-{number} --detach
   cd /tmp/pr-reviews-{OWNER}-{REPO}-{ts}/pr-{number} && gh pr checkout {number}
   ```
   **If checkout fails** for any PR (merge conflict, missing branch, etc.):
   - Clean up the partial worktree: `git worktree remove /tmp/pr-reviews-{OWNER}-{REPO}-{ts}/pr-{number} --force 2>/dev/null`
   - Add the PR to a **skipped list** with the failure reason
   - Continue with the remaining PRs — do NOT abort the run

3. **Small**, **Lockfile-only**, and **Very Large** PRs do NOT need worktrees — they will be reviewed from the diff alone.

4. Print which worktrees were created and which PRs were skipped (if any).

---

## Phase 6: Parallel Review

**Goal**: Deep code review of each PR using parallel agents.

Launch review agents in batches of up to 5 at a time (or 2 if RATE_LIMITED). Select the **model per PR based on size category**:

| Size Category | Model | Rationale |
|---------------|-------|-----------|
| Lockfile-only | `haiku` | Trivial changes, just check version sanity |
| Small | `haiku` | Fast and sufficient for small diffs |
| Medium | `sonnet` | Good balance of depth and speed |
| Large | `sonnet` | Needs careful analysis of impactful files |
| Very Large | `sonnet` | Summary-only mode, sonnet sufficient |

**Agent timeout guidance**: Give each agent a reasonable scope. If an agent has not returned after 5 minutes, do NOT block the pipeline — mark that PR as "review incomplete — agent timed out" in the report and continue with other results.

### Agent Prompt Template

For each PR, provide the agent with:

1. **PR metadata**: number, title, author, description, linked issue content
2. **The diff**: obtained via `gh pr diff {number}`
   - **Diff size limit**: If the diff exceeds 3000 lines, truncate it to the most impactful files. Exclude test files, generated files, lockfiles, and vendor directories. Tell the agent which files were omitted and their line counts.
3. **The worktree path**: so the agent can read full file context (Medium/Large PRs only)
4. **The review style guide** from Phase 3 (or learnings)
5. **The full review checklist**: Universal + Stack-Specific + Project Config items
6. **Any relevant learnings** about this author or common issues
7. **Size category and re-review flag**: so the agent knows whether to do a full review, summary, or focused delta review

### Universal Review Checklist (always include)

**Code Quality:**
- No obvious bugs or logic errors
- No security vulnerabilities (OWASP top 10)
- No unnecessary complexity or over-engineering
- Proper error handling and edge cases considered
- No duplicated code that should be abstracted
- No debug statements left in production code

**Alignment:**
- Changes match the PR description
- Changes address the linked issue (if any)
- No unrelated changes mixed in
- Scope is appropriate (not too broad, not incomplete)

**Testing:**
- New functionality has test coverage
- Tests are meaningful (not just testing implementation details)
- Edge cases covered in tests

### Specialized Agent Augmentation (Medium/Large PRs only)

For PRs in the **Medium**, **Large**, or **Very Large** size categories, each review agent should also dispatch specialized sub-agents in parallel to deepen the analysis. These run alongside the agent's own review and their findings are merged into the agent's output.

| Sub-agent | subagent_type | When to use |
|-----------|---------------|-------------|
| Silent failure hunter | `pr-review-toolkit:silent-failure-hunter` | PR touches error handling, catch blocks, or fallback logic |
| Comment analyzer | `pr-review-toolkit:comment-analyzer` | PR adds or modifies comments/docstrings |
| Type design analyzer | `pr-review-toolkit:type-design-analyzer` | PR introduces new types, interfaces, or structs |
| Code reviewer | `feature-dev:code-reviewer` | Always — catches bugs and security issues with confidence filtering |

**Instructions for review agents:**
- Only dispatch sub-agents relevant to the PR's changes — skip those that don't apply
- Launch all relevant sub-agents in a single parallel call to minimize wall-clock time
- Merge sub-agent findings into your own findings list, using the same `[Severity|Confidence]` format
- Deduplicate — if a sub-agent and your own analysis flag the same issue, keep the more detailed version
- If sub-agents are unavailable or fail, proceed with your own analysis alone
- Do NOT dispatch sub-agents for **Lockfile-only** or **Small** PRs — the overhead isn't worth it

### Agent Output Format

Each agent must return its findings in this EXACT format:

```
PR_NUMBER: {number}
PR_TITLE: {title}
AUTHOR: {author}
FILES_CHANGED: {count}
SIZE_CATEGORY: {Lockfile-only|Small|Medium|Large|Very Large}
RE_REVIEW: {yes|no}
VERDICT: APPROVE | REQUEST_CHANGES | NEEDS_DISCUSSION

FINDINGS:
- [Critical|HIGH] {file}:{line} — {description of issue}
- [Critical|MEDIUM] {file}:{line} — {description of issue}
- [Warning|HIGH] {file}:{line} — {description of issue}
- [Warning|MEDIUM] {file}:{line} — {description of issue}
- [Warning|LOW] {file}:{line} — {description of issue}
- [Suggestion|MEDIUM] {description}
- [Suggestion|LOW] {description}
- [Positive] {description of something done well}

SUMMARY:
{2-3 sentence overall assessment}

LEARNINGS:
{Any new observations about this author's patterns, recurring issues, or project conventions discovered}
```

**Finding format**: `[Severity|Confidence]` where:
- **Severity**: Critical, Warning, Suggestion, Positive
- **Confidence**: HIGH (certain issue), MEDIUM (likely issue, worth checking), LOW (possible concern, reviewer discretion)

---

## Phase 7: Compile Report, Update Learnings & Clean Up

**Goal**: Produce the final review report and persist knowledge for future runs.

### 7a: Compile Report

Create `~/.claude/pr-reviews/{OWNER}/{REPO}/review-{YYYY-MM-DD}.md` (if a file with today's date exists, append a counter: `review-{date}-2.md`).

Use this structure:

```markdown
# PR Review Report — {date}

**Repository**: {OWNER}/{REPO}
**Reviewed by**: AI PR Review Agent
**PRs Reviewed**: {count} ({skipped} skipped, {incomplete} incomplete)
**Review Style**: Based on analysis of {N} recent merged PR reviews (or "from accumulated learnings" if Phase 3 was skipped)

## Review Style Reference
{5-10 bullet points summarizing the learned review voice}

## Detected Stack
{List of detected technologies and frameworks that informed the checklist}

---

## PR #{number}: {title}
**Author**: @{author} | **Branch**: {branch} | **Files Changed**: {count} | **+{additions} / -{deletions}**
**Size Category**: {Lockfile-only|Small|Medium|Large|Very Large}
**Re-review**: {Yes — updated since last review on {date} | No}
**Description**: {first 2-3 sentences of PR body}
**Linked Issue**: #{issue_number} (if any)
**Link**: {REPO_URL}/pull/{number}

### Verdict: {APPROVE / REQUEST_CHANGES / NEEDS_DISCUSSION}

### Findings
- **[Critical|HIGH]** `{file}:{line}` — {description}
- **[Warning|MEDIUM]** `{file}:{line}` — {description}
- **[Suggestion|LOW]** {description}
- **[Positive]** {description}

### Summary
{2-3 sentence assessment}

---

(repeat for each PR)

## Skipped PRs
(if any PRs were skipped due to worktree failures or agent timeouts)
- PR #{number}: {reason}

## Statistics
- **Total PRs Reviewed**: {count}
- **Verdicts**: {N} APPROVE, {N} REQUEST_CHANGES, {N} NEEDS_DISCUSSION
- **Findings by Severity**: {N} Critical, {N} Warning, {N} Suggestion, {N} Positive
- **High-Confidence Issues**: {N}
- **Top Issue Categories**: {ranked list of most common issue types}
- **Size Distribution**: {N} Lockfile-only, {N} Small, {N} Medium, {N} Large, {N} Very Large
- **Models Used**: {N} haiku, {N} sonnet

## Trend Comparison
(if previous session data exists in learnings)
- {metric} changed from {old} to {new} (e.g., "Commit message violations: 50% → 30%")

## Aggregate Observations
{Cross-PR patterns noticed — e.g., "3 of 10 PRs missing test coverage for new features"}
```

If no project config file exists, append:

```markdown
## Suggestion: Create a Project Config

No project-specific review config was found. You can create one at:
`~/.claude/pr-reviews/{OWNER}/{REPO}/config.md`

This lets you define:
- Commit message format requirements
- License header expectations
- Additional project-specific checklist items
- Known false positives / accepted patterns

See the learnings file for auto-discovered conventions so far.
```

### 7b: Update Learnings

Read the existing `~/.claude/pr-reviews/{OWNER}/{REPO}/learnings.md` (if any), then update it. Do NOT just append — consolidate and deduplicate. The file structure should be:

```markdown
# PR Review Learnings — {OWNER}/{REPO}

*Last updated: {date}*

## Review Style Guide
{Synthesized guidance on tone, level of detail, and priorities — updated with any new observations}

## Detected Stack
{Technologies and frameworks detected in this project, for reference}

## Common Issues
{Patterns seen across multiple review sessions. Each entry should note how often it occurs.}
- {issue description} (seen in N/M PRs reviewed)

## False Positives / Project Conventions
{Things that look wrong but are accepted patterns in this project.}
- {pattern}: {why it's actually fine}

## Author Notes
{Per-author observations — only note patterns seen across 2+ PRs from the same author.}
- @{username}: {tendency}

## Previously Reviewed PRs
{Keep only the most recent 100 entries. If the list exceeds 100, remove the oldest entries.}
{Each entry includes the HEAD SHA for re-review detection.}
- #{number} — {date} — {headRefOid} — {title}

## Session Log
### {date}
- Reviewed {N} PRs: #{n1}, #{n2}, ...
- Models used: {N} haiku, {N} sonnet
- Skipped: {N} (reasons)
- New observations: {brief notes on anything new learned this session}
- Trend vs last session: {any notable changes in issue rates}
```

### 7c: Clean Up Worktrees

Remove all worktrees created during this run. For each worktree:
```
git worktree remove /tmp/pr-reviews-{OWNER}-{REPO}-{ts}/pr-{number} --force
```
Then remove the temporary directory:
```
rm -rf /tmp/pr-reviews-{OWNER}-{REPO}-{ts}
```

If any removal fails, retry once. If it still fails, warn the user with the path that needs manual cleanup.

Confirm cleanup succeeded.

---

## Important Notes

- Do NOT post comments to GitHub. All output is local only.
- Do NOT run builds, tests, or linters — assume CI handles that separately.
- Use `gh` for all GitHub interactions, never web fetch.
- **Shell escaping**: Never use `!=` in jq filters inside bash command substitutions. Always use `select(.field == "value" | not)` instead of `select(.field != "value")` to avoid zsh/bash history expansion issues with `!` inside `$()`.
- When reviewing, focus on issues a senior engineer would flag. Skip pedantic nitpicks that linters catch.
- Always include positive findings — balanced reviews are more useful.
- If a PR is categorized as Very Large (>1500 lines), provide a summary and key concerns only — do not attempt an exhaustive line-by-line review.
- If a linked issue exists, verify the PR actually addresses it — misalignment is a common problem.
- If CONTRIBUTING.md or CLAUDE.md exist in the repo, treat their guidelines as authoritative for checklist items they cover.
