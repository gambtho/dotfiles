# `/fix-pr` — plan document template

Write the implementation plan to:

```
~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{PR_NUMBER}-plan.md
```

If a plan for this PR already exists, archive the old one by renaming to `pr-{PR_NUMBER}-plan-{YYYY-MM-DD-HHMMSS}.md` before writing the new file.

Use this exact structure:

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

## Section rules

- **PR Summary**: keep to 2-4 sentences; this is the orientation block, not a recap of the diff.
- **Overview table**: the table is the contract — every issue listed in Detailed Plan must appear in the table, and vice versa. Use `—` for "no dependencies."
- **Detailed Plan**: quote comments verbatim in blockquotes — never paraphrase reviewer feedback. If the comment is part of a thread, include the full thread.
- **CI Failures**: each gets its own subsection with the exact error output. Root cause analysis must reference specific lines, not vague descriptions.
- **Conflicting Feedback**: omit the section entirely if no conflicts exist. Don't write "No conflicts" — silence is the signal.
- **Additional Recommendations**: keep brief; clearly label as optional. These are agent-discovered findings (Phase 4c), not reviewer requests.
- **Checklist**: one entry per issue + one per CI failure + the standard "all threads resolved / CI passing / ready for re-review" trailers.
