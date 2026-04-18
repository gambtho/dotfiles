---
name: polish-pr
description: Check out a PR into a worktree, run /polish --fix, commit the auto-fixes, prompt before pushing to the PR branch, and summarize fixed vs deferred findings
argument-hint: "<PR URL or number>"
allowed-tools: Bash(gh pr view:*), Bash(gh pr checkout:*), Bash(gh auth:*), Bash(gh repo view:*), Bash(gh api:*), Bash(git worktree:*), Bash(git fetch:*), Bash(git merge-base:*), Bash(git log:*), Bash(git diff:*), Bash(git status:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git branch:*), Bash(git show:*), Bash(cd:*), Bash(mkdir:*), Bash(rm -rf /tmp/polish-pr-*), Bash(ls:*), Bash(date:*), Read, Edit, Glob, Grep, Agent, Skill
---

# Polish PR — Auto-Fix a PR from the Outside

**Target PR**: $ARGUMENTS

Given a PR, this command:

1. Checks it out into a disposable worktree under `/tmp/polish-pr-*`
2. Runs `/polish --fix` against the full PR diff (merge-base..HEAD)
3. Commits whatever `/polish` auto-fixed
4. Prompts for confirmation, then pushes back to the PR branch
5. Prints a summary of what was fixed vs. what was deferred (the NEEDS REVIEW items `/polish` is not safe to auto-fix)
6. Removes the worktree

## What gets fixed vs deferred

`/polish --fix` is conservative on purpose. It auto-applies **only behavior-preserving cleanups**: dead code/imports, standard-library replacements that are semantically identical, tautological comments, verified-closed vestigial TODOs, and simple guard-clause flattening in functions without cleanup logic.

Bugs, security issues, over-engineering, naming, pattern-adherence, and anything at MEDIUM confidence are **reported, not fixed** — those require human judgment. Do not expect this command to fix logic bugs.

---

## Phase 0: Validate & parse the argument

**Narration rule for this command**: keep the running narration minimal. Do not announce each Phase. The two moments that warrant a one-line update are (a) right after Phase 0d when the PR is identified, and (b) right before Phase 4d when the push confirmation prompt is shown. Everything else speaks for itself via tool output.

### 0a: Require the argument

If `$ARGUMENTS` is empty, print and **STOP**:
```
ERROR: Please provide a PR URL or number.
Usage: /polish-pr <PR URL or number>
Examples:
  /polish-pr https://github.com/owner/repo/pull/123
  /polish-pr 123
```

### 0b: Verify `gh` auth

Run `gh auth status`. If it fails, print and **STOP**:
```
ERROR: GitHub CLI is not authenticated. Run `gh auth login` first.
```

### 0c: Parse OWNER / REPO / PR_NUMBER

- **Full URL** (`https://github.com/{OWNER}/{REPO}/pull/{NUMBER}`): extract the three parts.
- **Bare number**: use the current repo context.
  1. `gh repo view --json owner,name --jq '{owner: .owner.login, name: .name}'`
  2. Fallback: parse `git remote get-url origin` for `{OWNER}/{REPO}`.
  3. If both fail, print an error and **STOP** — ask for a full URL.

### 0d: Load PR metadata

```
gh pr view {PR_NUMBER} --repo {OWNER}/{REPO} \
  --json number,title,headRefName,baseRefName,headRefOid,state,isDraft,url,author,headRepositoryOwner
```

- If the PR is `MERGED` or `CLOSED`: warn and **STOP** — we do not push to merged/closed PRs.
- If `isDraft` is true: warn but continue.
- Store `headRefName`, `baseRefName`, `headRepositoryOwner.login`, `url`, `title`.
- Note whether the PR is from a fork: fork if `headRepositoryOwner.login` differs from `OWNER`.

Print: **"Polishing PR #{PR_NUMBER}: {title}"**.

---

## Phase 1: Set up an isolated worktree

### 1a: Clean leftovers from failed prior runs of THIS PR

Only clean worktrees for the **same PR**. Other PRs may be actively polished in another terminal — do not touch them.

```
ls -d /tmp/polish-pr-{OWNER}-{REPO}-{PR_NUMBER}-* 2>/dev/null
```

For each match, `git worktree remove --force <dir> 2>/dev/null` then `rm -rf <dir>`. If any were found, print: `"Removed {N} stale worktree(s) from prior runs of /polish-pr on PR #{PR_NUMBER}."` If none, say nothing — do not narrate a no-op.

### 1b: Fetch latest refs

```
git fetch origin
```

### 1c: Create the worktree & check out the PR

```
ts=$(date +%s)
WT=/tmp/polish-pr-{OWNER}-{REPO}-{PR_NUMBER}-${ts}
git worktree add ${WT} --detach
cd ${WT} && gh pr checkout {PR_NUMBER}
```

`gh pr checkout` sets up the correct branch and tracking — including for fork PRs, where it configures the fork's remote automatically.

If **any** step fails:
- `git worktree remove ${WT} --force 2>/dev/null`
- `rm -rf ${WT}`
- Print the failure reason and **STOP**.

Record `WT` so Phase 6 can always clean up.

---

## Phase 2: Resolve the polish base commit

```
BASE=$(git merge-base origin/{baseRefName} HEAD)
git log --oneline ${BASE}..HEAD
```

- If `BASE` is empty or the log is empty, **STOP** — the PR has no commits vs. its base (likely an up-to-date or empty PR).
- Print the commit list so the user can see what's in scope before `/polish` runs.

Why merge-base rather than the first PR commit: `/polish` treats its argument as the **exclusive** lower bound (`BASE..HEAD`). Using merge-base puts the first PR commit *inside* the analyzed range.

---

## Phase 3: Run `/polish` in fix mode

Invoke the polish command via the Skill tool:

- **Skill**: `my:polish`
- **Args**: `{BASE} --fix`

Capture polish's output — specifically the **FIXED** section (items it applied) and the **NEEDS REVIEW** section (items it deferred). Both are needed for the final summary.

If `/polish` exits with no FIXED items and a clean `git status`, jump to Phase 5 and skip the commit/push.

---

## Phase 4: Commit & push (with confirmation)

### 4a: Check what changed

```
git status --porcelain
```

- If clean, there is nothing to commit. Jump to Phase 5 with the message "No auto-fixable changes found. See DEFERRED below for items needing human review."

Show the user what polish touched:
```
git diff --stat
git diff
```

### 4b: Stage only what polish modified

Stage each modified file explicitly by name — **never** use `git add -A` or `git add .`. Use the file list from `git status --porcelain`.

### 4c: Commit

Use a HEREDOC for formatting:

```
git commit -m "$(cat <<'EOF'
polish: auto-fix {N} items via /polish-pr

Auto-fixed via /polish --fix against {BASE_SHORT}..HEAD:
- <short description of each FIXED item>
- ...

Deferred {M} items for human review (printed locally).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Replace `{N}`, `{M}`, `{BASE_SHORT}` (7-char), and fill the bullet list from polish's FIXED section (one line per item, `file:line — description`).

Do **not** use `--no-verify`. If a pre-commit hook fails, stop, surface the failure, and let the user decide — don't paper over it.

### 4d: Prompt before push

Print the commit SHA, diff stat, and the worktree path, then ask:
```
Commit {SHORT_SHA} is ready on {headRefName} in worktree {WT}.
Push now? [y/N]
(Declining keeps the worktree so you can review or push manually.)
```

**Only push after explicit affirmative confirmation.** On anything else (`n`, empty, unclear), mark the run as `PUSH_DECLINED` and go to Phase 5. **Do not remove the worktree** in that case — Phase 6 will skip cleanup so the user can inspect the changes, cherry-pick, or push manually with `git -C {WT} push`.

### 4e: Push

Prefer the upstream tracking that `gh pr checkout` configured:

```
# Verify upstream is set before pushing
git rev-parse --abbrev-ref @{upstream}
# Then push to that upstream
git push
```

If upstream is unset (rare — `gh pr checkout` normally handles this), fall back to the explicit form for same-repo PRs:
```
git push origin HEAD:{headRefName}
```

For fork PRs, rely on the upstream set by `gh pr checkout` — do **not** construct the remote URL manually.

Rules:
- **Never** `--force` / `--force-with-lease` / `+refs/...`.
- **Never** `--no-verify`.
- If the push is rejected (non-fast-forward, protected branch, etc.), surface the error, skip any local cleanup of the commit, and **STOP** — the user needs to decide how to resolve.

---

## Phase 5: Summary

Print the final report:

```
/polish-pr — PR #{PR_NUMBER}: {title}
Branch: {headRefName} @ {SHORT_SHA_AFTER_PUSH}

FIXED & PUSHED ({N}):
  ✓ file:line — description
  ...

DEFERRED FOR HUMAN REVIEW ({M}):
  Bugs & Security ({n}):
    1. ⚠ [Severity|Confidence] file:line — description
       Context: ...
       Suggested fix: ...
  Over-Engineering ({n}):
    2. ⚠ [Severity|Confidence] file:line — description
  Pattern Adherence ({n}):
  Comments / Dead Code / Structural ({n}):
  ...

PR: {url}
```

Reuse the exact grouping, numbering, and `[Severity|Confidence]` tags that `/polish` produced in its NEEDS REVIEW section — do not rewrite or re-classify. Just relabel the section as "DEFERRED FOR HUMAN REVIEW."

Special cases:
- **Nothing fixed, nothing deferred** → "PR is clean per `/polish`. No changes needed." Phase 6 removes the worktree (no work to lose).
- **Nothing fixed, items deferred** → omit `FIXED & PUSHED`, keep `DEFERRED`. Phase 6 removes the worktree (nothing was committed).
- **Items fixed, nothing deferred** → omit `DEFERRED`. Phase 6 handles per push outcome.
- **Push declined** (`PUSH_DECLINED`) → title: `/polish-pr — PR #{N} (NOT PUSHED — worktree kept)`. Include:
  - Committed SHA: `{SHORT_SHA}`
  - Worktree path: `{WT}`
  - Next steps block:
    ```
    Worktree kept for review. To push manually:
        git -C {WT} push
    To discard:
        git worktree remove {WT} --force
    ```
  Phase 6 **skips cleanup** in this case.
- **Push failed** → title: `/polish-pr — PR #{N} (PUSH FAILED — worktree kept)`. Include the error, the committed SHA, the worktree path, and the same "push manually / discard" block. Phase 6 **skips cleanup**.

---

## Phase 6: Cleanup

The worktree holds work the user may still care about. Only remove it when the work is either (a) durable on the remote or (b) non-existent. Decide based on the outcome state:

| Outcome | Action |
|---|---|
| Nothing committed (polish found nothing to fix) | Remove worktree |
| Committed + pushed successfully | Remove worktree |
| Committed but `PUSH_DECLINED` | **Keep worktree.** Print path + `git -C {WT} push` / `git worktree remove {WT} --force` hints. |
| Committed but push failed | **Keep worktree.** Print path + error + same hints. |
| Any unexpected error before commit | Remove worktree (nothing to lose) |

When removing:
```
cd - >/dev/null 2>&1 || true
git worktree remove ${WT} --force
```

When keeping, do not `cd` out silently — print the worktree path clearly and end the run. Print the PR URL one more time at the end regardless.

---

## Important notes

- **Worktree isolation is non-negotiable.** Never run `/polish --fix` inside the user's current working tree — it would write changes the user didn't ask for. All edits happen in `${WT}`.
- **Behavior preservation is paramount.** `/polish --fix` already enforces this; do not add post-polish edits or "small cleanups" — if `/polish` didn't auto-fix it, neither should this command.
- **No force-pushing, ever.** A non-fast-forward rejection means the PR has moved; stop and let the user resolve it.
- **No `--no-verify`.** If a pre-commit hook fails, surface the failure; don't bypass it.
- **Stage files by name.** Never `git add -A` — that would pick up stray artifacts.
- **Push requires explicit confirmation.** Even in auto-mode, always prompt. This is a visible action on a PR someone else may be watching.
- **Do not post PR comments.** The deferred list is printed locally only.
- **Do not run project tests/linters.** CI handles that; we just push and let CI report.
