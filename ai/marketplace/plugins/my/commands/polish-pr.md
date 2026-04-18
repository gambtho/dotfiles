---
name: polish-pr
description: Check out a PR into a worktree, run /polish --fix, commit the auto-fixes, prompt before pushing to the PR branch, and summarize fixed vs deferred findings
argument-hint: "<PR URL or number>"
allowed-tools: Bash(gh pr view:*), Bash(gh pr checkout:*), Bash(gh auth:*), Bash(gh repo view:*), Bash(gh api:*), Bash(git worktree:*), Bash(git fetch:*), Bash(git pull:*), Bash(git merge-base:*), Bash(git log:*), Bash(git diff:*), Bash(git status:*), Bash(git rev-parse:*), Bash(git remote:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git branch:*), Bash(git show:*), Bash(cd:*), Bash(mkdir:*), Bash(rm -rf /tmp/polish-pr-*), Bash(ls:*), Bash(date:*), Read, Edit, Glob, Grep, Agent, Skill
---

# Polish PR — Auto-Fix a PR from the Outside

**Target PR**: $ARGUMENTS

Given a PR, this command:

1. Reuses an existing worktree for this PR if one is available under `/tmp/polish-pr-*`; otherwise checks the PR out into a fresh worktree
2. Runs `/polish --fix` against the full PR diff (merge-base..HEAD)
3. Commits whatever `/polish` auto-fixed
4. Prompts for confirmation, then pushes back to the PR branch
5. Prints a summary of what was fixed vs. what was deferred (the NEEDS REVIEW items `/polish` is not safe to auto-fix)
6. Offers to apply any deferred items interactively (preserves the worktree until the user says otherwise)
7. Removes the worktree only when the work is safe on the remote or the user opts in

## What gets fixed vs deferred

`/polish --fix` is conservative on purpose. It auto-applies **only behavior-preserving cleanups**: dead code/imports, standard-library replacements that are semantically identical, tautological comments, verified-closed vestigial TODOs, and simple guard-clause flattening in functions without cleanup logic.

Bugs, security issues, over-engineering, naming, pattern-adherence, and anything at MEDIUM confidence are **reported, not fixed** — those require human judgment. Do not expect this command to fix logic bugs.

---

## Phase 0: Validate & parse the argument

**Narration rule for this command**: keep the running narration minimal. Do not announce each Phase. The moments that warrant a one-line update are (a) right after Phase 0d when the PR is identified, (b) in Phase 1a if an existing worktree is found (so the user knows we're not re-checking-out), and (c) right before Phase 4d when the push confirmation prompt is shown. Everything else speaks for itself via tool output.

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

### 1a: Look for an existing worktree for this PR and reuse it if possible

Only consider worktrees for the **same PR**. Other PRs may be actively polished in another terminal — do not touch them.

```
ls -td /tmp/polish-pr-{OWNER}-{REPO}-{PR_NUMBER}-* 2>/dev/null
```

For each match (newest first):
- If `git -C <dir> rev-parse HEAD 2>/dev/null` fails, it's not a valid worktree anymore — `rm -rf <dir>` (and `git worktree prune` at the end of the sweep). Continue to the next match.
- If the path doesn't show up in `git worktree list --porcelain`, it's orphaned — `rm -rf <dir>` and continue.

After the sweep, if at least one valid worktree remains, pick the newest and inspect its state:

```
WT_CANDIDATE=<newest valid match>
HEAD_SHA=$(git -C ${WT_CANDIDATE} rev-parse --short HEAD)
BRANCH=$(git -C ${WT_CANDIDATE} rev-parse --abbrev-ref HEAD)
DIRTY=$(git -C ${WT_CANDIDATE} status --porcelain)
UNPUSHED=$(git -C ${WT_CANDIDATE} log --oneline @{upstream}..HEAD 2>/dev/null)
```

Print the candidate's state:

```
Found existing worktree for PR #{PR_NUMBER}:
  Path:       {WT_CANDIDATE}
  Branch:     {BRANCH} @ {HEAD_SHA}
  Dirty:      {yes/no — list files if yes, up to 5}
  Unpushed:   {commit list if any, else "none"}
```

Decision:

- **Clean AND HEAD matches the PR's current `headRefOid`**: print `"Reusing existing worktree."` and set `WT=${WT_CANDIDATE}`. Skip to Phase 1b.
- **Dirty OR has unpushed commits OR HEAD differs from `headRefOid`**: the prior session left real state. Prompt:
  ```
  Reuse this worktree? [Y/n/fresh]
    - "y" (default): continue in the existing worktree, preserving changes
    - "n": abort (leave everything as-is)
    - "fresh": remove this worktree and start a new one (destroys uncommitted work!)
  ```
  - On `y` or empty → set `WT=${WT_CANDIDATE}`; skip to Phase 1b.
  - On `n` → print the worktree path and **STOP** (user handles it manually).
  - On `fresh` → `git worktree remove ${WT_CANDIDATE} --force`, `rm -rf ${WT_CANDIDATE}`, then fall through to 1c to create a new one.

If any additional (older) valid worktrees remain after the candidate is selected, offer to clean them up in a single confirm: `"Also remove {N} older worktree(s) for this PR? [y/N]"`. Default no.

If **no** valid worktrees were found at all, fall through to 1c.

### 1b: Fetch latest refs

```
git fetch origin
```

Skip this if we're reusing a dirty worktree and fetching would overwrite a ref the user is mid-edit on — actually `git fetch origin` only touches remote-tracking refs, never the working tree, so it's always safe. Run it.

### 1c: Create a new worktree (only if no reusable one exists)

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

### 1d: If reusing, refresh the branch

If we entered Phase 1 via reuse (not 1c) AND the candidate was clean AND its HEAD is an ancestor of the PR's current `headRefOid`, run:
```
cd ${WT} && git pull --ff-only
```
This picks up any commits pushed to the PR after the prior `/polish-pr` run. **Skip `git pull` if the worktree is dirty or has unpushed commits** — the user's work comes first.

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

**Do not print a worktree status line here.** Phase 6 owns the final worktree decision, after Phase 5.5 has a chance to act on deferred items.

Special cases (summary-only; worktree lifecycle is decided in Phase 6):
- **Nothing fixed, nothing deferred** → "PR is clean per `/polish`. No changes needed." Phase 5.5 is skipped; Phase 6 removes the worktree.
- **Nothing fixed, items deferred** → omit `FIXED & PUSHED`, keep `DEFERRED`. Phase 5.5 then prompts the user — **do not remove the worktree before that prompt**.
- **Items fixed, nothing deferred** → omit `DEFERRED`. Phase 5.5 is skipped; Phase 6 handles per push outcome.
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
- **Push failed** → title: `/polish-pr — PR #{N} (PUSH FAILED — worktree kept)`. Include the error, the committed SHA, the worktree path, and the same "push manually / discard" block.

---

## Phase 5.5: Interactive follow-up on deferred items

**Skip this phase entirely if there are zero deferred items (`M == 0`).**

The worktree is already on the PR branch — it is the obvious place to apply any deferred finding the user wants. Do not destroy it without asking.

After printing the Phase 5 summary, prompt:

```
{M} deferred item(s) are listed above. Apply any of them now in the worktree?
  - Numbers (e.g. "1,3,4") — apply those findings
  - "all"  — apply every finding that has a concrete Suggested fix
  - "none" — skip; remove the worktree
  - "keep" — skip but keep the worktree at {WT} for manual follow-up

Your choice: 
```

Behavior by response:

### Numbers / "all" → fix loop

1. For each selected deferred item:
   - If it has a concrete `Suggested fix:` in its NEEDS REVIEW entry, apply that fix via the `Edit` tool inside `${WT}`.
   - If the fix requires a larger refactor or isn't concretely specified, **skip it** and note why (e.g. "#4 skipped — suggested fix is vague, apply manually"). Do not invent a fix.
2. After all selected edits: show `git diff` so the user can see what changed.
3. Prompt: `"Commit these {K} manual fixes? [y/N]"`.
   - **Decline** → leave changes unstaged in the worktree, set `FOLLOW_UP=keep`, and fall through to Phase 6 (which will preserve the worktree).
   - **Accept** → continue.
4. Stage each modified file by name (same rule as Phase 4b — never `-A`). Commit via HEREDOC:
   ```
   git commit -m "$(cat <<'EOF'
   polish: apply {K} deferred fixes via /polish-pr

   Applied via interactive follow-up against {BASE_SHORT}..HEAD:
   - <short list of applied items, one per line>

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
   EOF
   )"
   ```
   Never `--no-verify`. If the hook fails, surface it and stop — do not bypass.
5. Re-enter the Phase 4d push prompt for this new commit. The push outcome (pushed / declined / failed) feeds Phase 6 exactly like an auto-fix commit.
6. After the follow-up commit settles, if any unactioned deferred items remain, offer the prompt one more time. Loop until the user answers "none" or "keep".

### "none" (or empty) → skip

Set `FOLLOW_UP=declined` and proceed to Phase 6. The user has explicitly waived all deferred items; the worktree is safe to remove (subject to push state).

### "keep" → skip but preserve

Set `FOLLOW_UP=keep` and proceed to Phase 6. The worktree is preserved with push/discard hints.

### Unparseable input

Re-prompt once with a clarification ("Enter numbers like `1,3`, or one of: all, none, keep."). On a second unparseable answer, default to `FOLLOW_UP=keep` — preserving work is always the safer default.

---

## Phase 6: Cleanup

The worktree holds work the user may still care about. Only remove it when (a) the work is durable on the remote, (b) there's nothing to do, or (c) the user explicitly opted into cleanup. Decide based on the combined state of commits, push outcome, and `FOLLOW_UP`:

| Prior state                                                            | Action |
|---|---|
| Nothing committed AND no deferred items                                | Remove worktree |
| Nothing committed AND `FOLLOW_UP=declined`                             | Remove worktree |
| Nothing committed AND `FOLLOW_UP=keep`                                 | **Keep worktree** (+ hints) |
| Committed + pushed successfully AND `FOLLOW_UP != keep`                | Remove worktree |
| Committed + pushed successfully AND `FOLLOW_UP=keep`                   | **Keep worktree** (+ hints) |
| Commit exists but `PUSH_DECLINED` (auto-fix or manual follow-up)       | **Keep worktree** (+ hints) |
| Commit exists but push failed                                          | **Keep worktree** (+ hints + error) |
| Unexpected error before commit                                         | Remove worktree |

Underlying rule: the worktree is kept whenever (a) uncommitted deferred work may still be applied, (b) a local commit has not reached the remote, or (c) the user said "keep".

When **keeping**, print:
```
Worktree kept: {WT}
  Push a pending commit:  git -C {WT} push
  Discard everything:     git worktree remove {WT} --force
```

When **removing**:
```
cd - >/dev/null 2>&1 || true
git worktree remove ${WT} --force
```

Print the PR URL once more at the end regardless.

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
