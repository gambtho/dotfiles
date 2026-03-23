---
name: review-prs
description: Review open PRs with no human comments — learns from past reviews and accumulates knowledge across runs
tools:
  - read
  - glob
  - grep
  - edit
  - create
  - bash
  - task
  - github-mcp-server-pull_request_read
  - github-mcp-server-list_pull_requests
  - github-mcp-server-issue_read
  - github-mcp-server-get_job_logs
  - github-mcp-server-actions_list
  - github-mcp-server-get_file_contents
  - github-mcp-server-get_commit
  - github-mcp-server-list_commits
  - github-mcp-server-search_code
---

# PR Review Pipeline

You are reviewing open pull requests for the current repository that have not yet received human review comments. You will learn from existing review patterns, then produce detailed reviews saved to a local markdown file.

**Number of PRs to review**: The user may specify a count in their prompt (default: 10 if not specified).

---

## Phase 0: Detect Repository & Preflight Checks

**Goal**: Identify the GitHub repository, verify access, and check API quota.

### 0a: Detect Repository

1. Run: `git remote get-url origin` and parse `{OWNER}/{REPO}` from the URL (handles both SSH `git@github.com:owner/repo.git` and HTTPS `https://github.com/owner/repo.git` formats)
2. If this fails, ask the user which repository to review

Store: `OWNER`, `REPO`

### 0b: Set Up Output Directory

```
mkdir -p ~/.copilot/pr-reviews/{OWNER}/{REPO}
```

Print: **"Reviewing PRs for: {OWNER}/{REPO}"**

### 0c: One-Time Migration

If `~/.copilot/pr-reviews/learnings.md` exists at the old flat path AND `~/.copilot/pr-reviews/{OWNER}/{REPO}/learnings.md` does NOT exist, move all files from the flat path into the repo-specific directory. Also check `~/.claude/pr-reviews/` for legacy data and migrate if found.

---

## Phase 1: Load Persistent Learnings

**Goal**: Bootstrap from accumulated knowledge of previous review runs.

1. Read `~/.copilot/pr-reviews/{OWNER}/{REPO}/learnings.md` (if it exists)
2. If it exists and has substantial content:
   - Note the review style guidance, common issues, and false positive patterns
   - Extract the **Previously Reviewed PRs** list — store as a set of PR numbers to skip. Also store any HEAD SHAs recorded alongside them (for re-review detection in Phase 4).
   - Check the "Review Style Guide" section: if it has **8+ bullet points** AND the "Last updated" date is **within the last 7 days**, set `SKIP_STYLE_LEARNING=true` (Phase 3 will be skipped entirely)
   - Otherwise, reduce the number of merged PRs studied in Phase 3 to 5
3. If it does not exist, proceed with full style learning

### Load Project Config (Optional)

Read `~/.copilot/pr-reviews/{OWNER}/{REPO}/config.md` if it exists. This file contains user-defined review conventions that supplement the auto-detected checklist:
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
| `tsconfig.json` | TypeScript |
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
| `"i18next"` or `"react-i18next"` | i18n expected |

### Convention Markers
| File | Convention |
|------|-----------|
| `LICENSE` | Read it to determine expected license type |
| `CONTRIBUTING.md` | Read for contribution guidelines |
| `AGENTS.md` / `CLAUDE.md` / `.github/copilot-instructions.md` | Read for project-specific coding guidelines |
| `.eslintrc*` or `eslint.config.*` | ESLint style conventions in use |
| `.prettierrc*` | Prettier formatting in use |
| `Makefile` or `justfile` | Build/task conventions |

### Build the Review Checklist

Based on what you detect, compose the **Stack-Specific Checklist** by selecting relevant items. Only include sections for technologies actually detected.

**JavaScript/TypeScript:**
- TypeScript types are correct (no `any` unless justified)
- No `console.log` or debug statements left in production code
- Async/await error handling is correct
- Dependencies added to the correct section

**React:**
- Components follow existing patterns in the codebase
- Props are properly typed
- Effects have correct dependency arrays
- No unnecessary re-renders

**Go:**
- All errors are checked and handled
- Exported functions have doc comments
- No goroutine leaks
- Input validation for external data

**Rust:**
- Proper use of `Result` and `Option` types
- No unnecessary `unwrap()` / `expect()` in library code
- Lifetime annotations are correct

**Python:**
- Type hints present on public functions
- Proper exception handling (no bare `except:`)
- No security issues

**Java/Kotlin:**
- Proper null handling
- Resources properly closed
- Thread safety considered for shared state

Print the composed checklist so the user can see what will be checked.

---

## Phase 3: Learn Review Style

**Goal**: Understand how this project's maintainers give code review feedback.

**Skip condition**: If `SKIP_STYLE_LEARNING=true` (learnings already have a mature style guide updated within 7 days), skip this entire phase and print: "Using existing review style guide from learnings (last updated: {date})."

1. Use `github-mcp-server-list_pull_requests` with `state: "closed"` and `sort: "updated"` to find recently merged PRs.

2. For the top 15 with review comments (or top 5 if learnings already exist), use parallel sub-agents (via the `task` tool with `agent_type: "explore"`) to fetch and analyze review comments:
   - Use `github-mcp-server-pull_request_read` with method `get_review_comments` and `get_reviews`
   - Each agent should analyze 3-5 PRs and return:
     - Common tone patterns (direct? gentle? question-based?)
     - Types of feedback given (bugs, style, architecture, testing, etc.)
     - Level of detail in comments
     - Whether reviewers suggest alternatives or just flag issues
     - Notable phrases or conventions used

3. Synthesize the findings into a brief **Review Style Guide** (5-10 bullet points capturing the voice and priorities).

---

## Phase 4: Discover Unreviewed PRs

**Goal**: Find open PRs that need review attention.

### 4a: List and Filter Candidates

1. Use `github-mcp-server-list_pull_requests` with `state: "open"` to list all open PRs.

2. **Immediately filter out**:
   - Draft PRs
   - PR numbers in the "Previously Reviewed PRs" list from learnings (UNLESS the stored HEAD SHA differs from the current head SHA — those go into a separate **"updated since last review"** list)

3. If 0 candidates remain, print a summary and **STOP** cleanly.

### 4b: Check for Human Comments

For each remaining candidate, use `github-mcp-server-pull_request_read` with methods `get_reviews` and `get_comments` to check for human review activity. Use parallel sub-agents to batch these checks.

Filter to PRs where both review count and comment count are 0 (excluding bot comments).

### 4c: Select and Categorize

1. Select the N most recent unreviewed PRs (where N is the user's requested count, default 10)

2. For each selected PR, use `github-mcp-server-pull_request_read` with method `get_files` to get changed file paths.

3. Categorize each PR by size and type:
   - **Lockfile-only**: All changed files match `*lock*`, `*.lock`, `go.sum`, `*.sum`
   - **Small** (< 100 lines changed): Review from diff only
   - **Medium** (100–500 lines changed): Standard review with full file context
   - **Large** (500–1500 lines changed): Extended review focusing on highest-impact files
   - **Very Large** (> 1500 lines changed): Summary and key concerns only

4. If any PRs were detected as "updated since last review", include them at the end (marked as re-reviews) if there is room within the N limit.

5. Print a summary table of the PRs that will be reviewed.

---

## Phase 5: Set Up Working Context

**Goal**: Prepare context so multiple agents can review different PRs simultaneously.

For **Medium** and **Large** PRs, ensure the repository is available locally. If working from a cloned repo, fetch the PR branches:

```bash
git fetch origin pull/{number}/head:pr-{number}
```

For **Small**, **Lockfile-only**, and **Very Large** PRs, the diff alone is sufficient — no local checkout needed.

---

## Phase 6: Parallel Review

**Goal**: Deep code review of each PR using parallel sub-agents.

Launch review agents in batches of up to 5 at a time using the `task` tool with `agent_type: "general-purpose"` for Medium/Large PRs and `agent_type: "explore"` for Small/Lockfile-only PRs.

### Agent Prompt Template

For each PR, provide the agent with:

1. **PR metadata**: number, title, author, description, linked issue content
2. **The diff**: obtained via `github-mcp-server-pull_request_read` with method `get_diff`
   - If the diff exceeds 3000 lines, truncate to the most impactful files. Exclude test files, generated files, lockfiles, and vendor directories. Tell the agent which files were omitted.
3. **Full file context** for Medium/Large PRs: read changed files from the local checkout or via `github-mcp-server-get_file_contents`
4. **The review style guide** from Phase 3 (or learnings)
5. **The full review checklist**: Universal + Stack-Specific + Project Config items
6. **Any relevant learnings** about this author or common issues
7. **Size category and re-review flag**

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
- Scope is appropriate

**Testing:**
- New functionality has test coverage
- Tests are meaningful
- Edge cases covered in tests

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
- **Confidence**: HIGH (certain issue), MEDIUM (likely issue), LOW (possible concern)

---

## Phase 7: Compile Report, Update Learnings & Clean Up

**Goal**: Produce the final review report and persist knowledge for future runs.

### 7a: Compile Report

Create `~/.copilot/pr-reviews/{OWNER}/{REPO}/review-{YYYY-MM-DD}.md` (if a file with today's date exists, append a counter: `review-{date}-2.md`).

```markdown
# PR Review Report — {date}

**Repository**: {OWNER}/{REPO}
**Reviewed by**: AI PR Review Agent
**PRs Reviewed**: {count} ({skipped} skipped, {incomplete} incomplete)
**Review Style**: Based on analysis of {N} recent merged PR reviews (or "from accumulated learnings")

## Review Style Reference
{5-10 bullet points summarizing the learned review voice}

## Detected Stack
{List of detected technologies and frameworks}

---

## PR #{number}: {title}
**Author**: @{author} | **Branch**: {branch} | **Files Changed**: {count} | **+{additions} / -{deletions}**
**Size Category**: {category}
**Re-review**: {Yes — updated since last review | No}
**Description**: {first 2-3 sentences of PR body}
**Linked Issue**: #{issue_number} (if any)
**Link**: https://github.com/{OWNER}/{REPO}/pull/{number}

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
- PR #{number}: {reason}

## Statistics
- **Total PRs Reviewed**: {count}
- **Verdicts**: {N} APPROVE, {N} REQUEST_CHANGES, {N} NEEDS_DISCUSSION
- **Findings by Severity**: {N} Critical, {N} Warning, {N} Suggestion, {N} Positive
- **High-Confidence Issues**: {N}
- **Top Issue Categories**: {ranked list}

## Trend Comparison
(if previous session data exists in learnings)
- {metric} changed from {old} to {new}

## Aggregate Observations
{Cross-PR patterns noticed}
```

If no project config file exists, append a suggestion to create one at `~/.copilot/pr-reviews/{OWNER}/{REPO}/config.md`.

### 7b: Update Learnings

Read the existing learnings file (if any), then **update** it. Do NOT just append — consolidate and deduplicate.

```markdown
# PR Review Learnings — {OWNER}/{REPO}

*Last updated: {date}*

## Review Style Guide
{Synthesized guidance on tone, level of detail, and priorities}

## Detected Stack
{Technologies and frameworks detected}

## Common Issues
{Patterns seen across multiple review sessions, with frequency}
- {issue description} (seen in N/M PRs reviewed)

## False Positives / Project Conventions
{Things that look wrong but are accepted patterns}
- {pattern}: {why it's actually fine}

## Author Notes
{Per-author observations — only note patterns seen across 2+ PRs}
- @{username}: {tendency}

## Previously Reviewed PRs
{Keep only the most recent 100 entries}
- #{number} — {date} — {headRefOid} — {title}

## Session Log
### {date}
- Reviewed {N} PRs: #{n1}, #{n2}, ...
- Skipped: {N} (reasons)
- New observations: {brief notes}
- Trend vs last session: {any notable changes}
```

### 7c: Clean Up

If any temporary branches were fetched, clean them up:
```bash
git branch -D pr-{number}
```

Confirm cleanup succeeded.

---

## Important Rules

- Do NOT post comments to GitHub. All output is local only.
- Do NOT run builds, tests, or linters — assume CI handles that separately.
- Prefer GitHub MCP server tools over raw `gh` CLI calls for GitHub API interactions.
- When reviewing, focus on issues a senior engineer would flag. Skip pedantic nitpicks that linters catch.
- Always include positive findings — balanced reviews are more useful.
- If a PR is Very Large (>1500 lines), provide a summary and key concerns only.
- If a linked issue exists, verify the PR actually addresses it.
- If CONTRIBUTING.md or project coding guidelines exist, treat their guidelines as authoritative.
