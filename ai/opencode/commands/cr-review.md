---
description: Run CodeRabbit AI code review on your changes
---

# CodeRabbit Code Review

Run an AI-powered code review using the CodeRabbit CLI.

## Context

- Current directory: !`pwd`
- Git repo: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "Yes" || echo "No"`
- Branch: !`git branch --show-current 2>/dev/null || echo "detached HEAD"`
- Has changes: !`git status --porcelain 2>/dev/null | head -1 | grep -q . && echo "Yes" || echo "No"`

## Instructions

Review code based on: **$ARGUMENTS**

### Step 1: Prerequisites Check

**Skip these checks if you already verified them earlier in this session.**

Run:

```bash
cr --version 2>/dev/null && cr auth status 2>&1 | head -3
```

**If CLI not found**, tell user:
> CodeRabbit CLI is not installed. Run in your terminal:
>
> ```bash
> curl -fsSL https://cli.coderabbit.ai/install.sh | sh
> ```
>
> Then restart your shell and try again.

**If "Not logged in"**, tell user:
> You need to authenticate. Run in your terminal:
>
> ```bash
> cr auth login
> ```
>
> Then try again.

### Step 2: Determine Review Parameters

Parse `$ARGUMENTS` for:

- **Review type**: `committed`, `uncommitted`, or `all` (default)
- **Base branch**: value after `--base`
- **Config files**: value after `-c`

**Auto-detect base branch** (only if `--base` not specified):

```bash
git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}'
```

If detection fails, omit `--base` and let `cr` use its default.

### Step 3: Run Review in Background

CodeRabbit reviews can take 7-30+ minutes depending on scope. Run it in the background:

```bash
cr --prompt-only -t <type> [--base <branch>] [-c <config>] > /tmp/cr-review-$$.out 2>&1 &
CR_PID=$!
echo "CodeRabbit review started (PID: $CR_PID)"
```

Inform the user: "CodeRabbit review is running in the background. I'll check on it periodically."

Then poll every 30 seconds:

```bash
if kill -0 $CR_PID 2>/dev/null; then echo "Still running..."; else echo "Done"; cat /tmp/cr-review-$$.out; fi
```

Keep polling until the process completes. When done, read the output file.

### Step 4: Parse and Present Results

Once the review completes:

1. Read the output from the temp file
2. Create an OpenCode todo for each finding, prefixed with severity:
   - `[CRITICAL]` for security vulnerabilities and bugs
   - `[HIGH]` for important issues that need attention
   - `[MEDIUM]` for suggestions and improvements
   - `[LOW]` for minor nits and style issues
3. Present a summary grouped by severity:
   - **Critical** — Security, bugs (must fix)
   - **High** — Important issues (should fix)
   - **Medium** — Improvements (consider fixing)
   - **Low** — Minor suggestions (optional)
   - **Positive** — What's done well
4. Clean up the temp file

### Step 5: Offer to Fix Issues

If there are Critical or High findings:

1. Offer to fix them: "I found N critical/high issues. Want me to fix them?"
2. If yes, work through each finding systematically
3. Mark each todo as completed after fixing
4. After all fixes are applied, proceed to Step 6

If there are no Critical or High findings, skip to the summary.

### Step 6: Re-Review Loop (Max 2 Iterations)

After applying fixes, offer to verify:

> "Fixes applied. Want me to re-run CodeRabbit to verify the fixes didn't introduce new issues? (This will take another few minutes)"

If yes:
1. Run `cr --prompt-only` again in background using the same parameters
2. Present new findings (if any)
3. If critical/high issues remain, offer to fix them (second and final iteration)
4. After the second pass, summarize regardless of remaining issues

### Step 7: Final Summary

Present a final summary:

```
## CodeRabbit Review Complete

- **Review passes**: N
- **Issues found**: N (X critical, Y high, Z medium, W low)
- **Issues fixed**: N
- **Issues remaining**: N
```
