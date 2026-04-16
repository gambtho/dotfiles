---
name: overnight-improve
description: Run an autonomous overnight improvement loop on a codebase. Each iteration runs the project's review skill (default `my:improve`), picks the top eligible finding, fixes it, runs project-defined verification gates, and commits or rolls back. After max iterations or no eligible findings, pushes the branch, opens a PR, and runs CodeRabbit autofix rounds. Reads per-project config from `.claude/overnight-config.yaml` (gates, do-nots, iteration cap). Use when the user wants to run an unattended improvement session and wake up to a PR.
---

# Overnight Improvement Loop

Orchestrates an unattended overnight improvement session. Each iteration runs a configurable review skill (default `my:improve`), picks the highest-ranked finding not already attempted, applies the fix, runs verification gates, and commits or rolls back. On the final iteration (or when no eligible findings remain), pushes the branch and opens a PR with up to N rounds of CodeRabbit autofix follow-up.

## Prerequisites

This skill MUST be invoked in a Claude Code session launched with `--permission-mode bypassPermissions`. Plan mode (the default) blocks every write/Bash call, so an unattended loop stalls at the first tool call. If the current session is not in bypass mode, tell the user and stop — do NOT continue.

The repo MUST have a `.claude/overnight-config.yaml` file. If missing, see `references/config-schema.md` for the schema and stop.

## Step 0: Preflight (read references/preflight-checklist.md and run it)

Run all checks in `references/preflight-checklist.md`. If any check fails, log the failure and stop. Do not start the loop on a broken baseline.

The preflight covers:
- Verifies session is in bypass-permissions mode
- Verifies main is clean and up to date
- Creates the overnight branch
- Seeds `.claude/overnight-run-state.md`
- Runs each gate from `.claude/overnight-config.yaml` against baseline; any failure aborts

## Step 1: Read project config

Read `.claude/overnight-config.yaml`. Schema (see `references/config-schema.md` for full doc):

```yaml
improve_skill: my:improve          # which review skill to dispatch each iteration
max_iterations: 15                 # PHASE 2 fires when iteration counter hits this
max_wrap_iterations: 3             # max CodeRabbit autofix rounds in PHASE 2
branch_prefix: overnight-improvements
gates:                             # ordered list; all must exit 0 to commit
  - name: <human label>
    command: <bash command, run from repo root>
do_nots:                           # appended to per-iteration prompt
  - <one-line constraint>
```

If any required field is missing, stop and ask the user to populate the config.

## Step 2: Generate the per-iteration prompt

Build the loop prompt by substituting config values into the template below (under "Loop prompt template").

Substitute:
- `{{improve_skill}}` → value of `improve_skill` from config
- `{{max_iterations}}` → value of `max_iterations` from config
- `{{max_wrap_iterations}}` → value of `max_wrap_iterations` from config
- `{{branch_prefix}}` → value of `branch_prefix` from config
- `{{gates_block}}` → for each gate, render `<name>: <command>` lines; the loop runs them sequentially and fails on the first non-zero exit
- `{{do_nots_block}}` → render each do-not as a `- <text>` bullet

## Step 3: Invoke ralph-loop with the rendered prompt

Use the `Skill` tool to invoke `ralph-loop:ralph-loop` with these arguments:

- `--max-iterations {{max_iterations}}`
- `--completion-promise 'NO_FINDINGS_WORTH_FIXING'`
- prompt: the rendered loop prompt from Step 2

Ralph-loop will fire the prompt up to `{{max_iterations}}` times. Each fire is a fresh session that picks up from `.claude/overnight-run-state.md`.

## Step 4: Stop conditions

The loop stops when any of:
- The fired prompt outputs `<promise>NO_FINDINGS_WORTH_FIXING</promise>` (which only happens after PHASE 2 wrap-up completes, or on a wrong-branch safety trip)
- ralph-loop's own max-iterations is reached without the promise being emitted

When the loop ends, tell the user where to find:
- `.claude/overnight-run-state.md` — the per-iteration log
- `git log --oneline main..HEAD` — what got committed
- `gh pr view` — the PR if one was opened

---

## Loop prompt template

The text below is what gets sent to ralph-loop, with `{{...}}` placeholders substituted from config.

```
You are running one iteration of an autonomous overnight improvement loop. The same prompt will fire again after you finish this iteration, until max-iterations is hit or you output the completion promise.

== OPERATING RULES (pre-authorized for this loop only) ==

- You are working on branch `{{branch_prefix}}-<today>`. Verify with `git branch --show-current` first. If you are on any other branch, output `<promise>NO_FINDINGS_WORTH_FIXING</promise>` immediately — DO NOT switch branches autonomously.
- You MAY `git reset --hard HEAD` to discard uncommitted changes on this branch to roll back a failed attempt. This overrides the "never reset without asking" rule for THIS branch only.
- You may NOT: force-push, switch/merge/delete branches, run `git clean -fd`, run any `--no-verify` variant, touch any other branch.
- During PHASE 2 (wrap-up) ONLY, you MAY `git push -u origin HEAD`, run `gh pr create`, run additional `git push` commands for follow-up commits, and invoke the `coderabbit:autofix` skill. These permissions do NOT apply during normal iteration work — only inside the wrap-up phase below.
- You may run any read-only command (tests, lint, typecheck, build).
- Commits must include the `Co-Authored-By: Claude` trailer and a clear subject `improve: <finding title>`.

== STATE TRACKING ==

Read `.claude/overnight-run-state.md`. If it does not exist, create it with:

---
started: <ISO timestamp>
branch: {{branch_prefix}}-<today>
max_iterations: {{max_iterations}}
iteration: 0
max_wrap_iterations: {{max_wrap_iterations}}
---

== Attempted findings ==
(none yet)

== Wrap-up ==
(pending)

Each entry under "Attempted findings" has the form:
`- <file:line> [<category>] <title> — status: <succeeded|failed-once|failed-twice|skipped-design>` with commit SHA when succeeded.

Use `file:line + category` as the identity key (titles shift between review runs; file + category is stable).

The frontmatter `iteration` counter tracks how many times this prompt has fired. Bump it at step 0 of every iteration. When `iteration == max_iterations`, this is the LAST fire and PHASE 2 wrap-up MUST run before the iteration ends.

== WORK FOR THIS ITERATION ==

0. Bump the iteration counter. Read `iteration` from the frontmatter, add 1, write it back. Note the new value — call it `N`. If the frontmatter is missing the field (older state file), add `iteration: 1`, `max_iterations: {{max_iterations}}`, and `max_wrap_iterations: {{max_wrap_iterations}}`.

1. Run the review skill: invoke `{{improve_skill}}` with no arguments (full codebase scope). Capture the top 10 findings.

2. Pick the finding to attempt. From the returned list, pick the highest-ranked finding where the state file does NOT show the same file:line + category already marked `succeeded`, `failed-twice`, or `skipped-design`. If the finding is marked `failed-once`, you may retry it. If no eligible finding remains, jump to PHASE 2 (wrap-up) below — do NOT emit the completion promise yet.

3. Log as in-progress in the state file: `- <file:line> [<category>] <title> — status: in-progress (iteration <N>)`.

4. Implement the fix. Respect the project's CLAUDE.md and the do-nots listed at the bottom of this prompt. Stay inside the scope of the finding — do not rename, restructure, or add features beyond what the finding names. If during implementation you realize the finding genuinely requires a design decision you cannot make alone, mark it `skipped-design` in the state file, `git reset --hard HEAD`, and return to step 2 to pick the next finding.

5. Run verification gates. All must exit 0. Capture the exit code of each:

{{gates_block}}

6. Commit or roll back.
   - All gates pass: `git add` the files you modified (do NOT use `git add -A` — avoid staging unrelated artifacts) → `git commit` with subject `improve: <finding title>` and body containing: the category, severity, and effort of the finding, and a 2-3 line description of what was changed and why. Update state file entry to `succeeded: <short SHA>`.
   - Any gate fails: `git reset --hard HEAD`. If this was the first attempt at this finding, update state entry to `failed-once: <gate that failed>, <brief error>`. If this was the second attempt, update to `failed-twice`. Do NOT output the completion promise just because a fix failed — let the loop try the next finding.

7. Sanity check before ending the iteration. Run `git status` — working tree must be clean. If it is not clean, you have a bug; `git reset --hard HEAD` and log the anomaly in the state file.

8. Wrap-up trigger. If `N == max_iterations` (this was the last fire), jump to PHASE 2 below before ending the iteration. Otherwise end the iteration normally and let ralph-loop fire the next one.

== PHASE 2: WRAP-UP (PR + CodeRabbit) ==

Trigger conditions (either fires the wrap-up):
- Step 2 found no eligible findings (all top-ranked are already `succeeded`, `failed-twice`, or `skipped-design`).
- Step 8 detected `N == max_iterations`.

Skip wrap-up entirely (and emit the completion promise immediately) if the wrong-branch safety check from the rules above tripped — never push or open PRs from an unexpected branch.

Permissions for this phase only: `git push -u origin HEAD`, `gh pr create`, follow-up `git push`, and the `coderabbit:autofix` skill are allowed. Force-push, branch switching, merging, and `--no-verify` remain forbidden.

W1. Verify there is something to push. Run `git log --oneline main..HEAD` — if zero commits, log `no commits, nothing to PR` under `== Wrap-up ==` in the state file, output the completion promise, and stop.

W2. Push the branch:

git push -u origin HEAD

If push fails, log the error under `== Wrap-up ==`, output the completion promise, and stop.

W3. Open or find the PR (target `main`, ready for review — not draft):

gh pr create --base main --head "$(git branch --show-current)" \
  --title "improve: overnight loop $(date +%Y-%m-%d)" \
  --body "Autonomous overnight improvement loop on $(date +%Y-%m-%d). Per-finding log: \`.claude/overnight-run-state.md\`. Commits: $(git log --oneline main..HEAD). All commits passed the configured gates."

If `gh pr create` fails because a PR already exists, fall back to `gh pr view --json number -q .number` to get the existing PR number. Capture the PR number — call it `PR`. Log `pr: #<PR>` under `== Wrap-up ==`.

W4. Address CodeRabbit in rounds. CodeRabbit (`coderabbitai[bot]`) auto-reviews on PR open AND re-reviews each new commit. One autofix pass usually does not clear every comment, so loop up to `max_wrap_iterations` (read from state file frontmatter) times. Each round: wait for the review of the *current HEAD*, apply autofix, gate, push.

Use the `coderabbit:autofix` skill in batch mode against the PR for each round. After each round:
- Re-run all gates (the same ones from step 5)
- If gates pass and there are file changes, commit with subject `improve: address coderabbit review (round <N>)` (with Co-Authored-By trailer) and push
- If gates fail after autofix, `git reset --hard HEAD` and log `autofix broke <gate>, rolled back` — break the loop, do NOT push a broken commit

Stop conditions for the wrap loop (any breaks):
- CodeRabbit's latest review reports `Actionable comments posted: 0`
- `coderabbit:autofix` produces no file changes
- Gates fail after autofix (rolled back, do not push)
- Poll for the current HEAD's review times out (15 min)
- `round` reaches `max_wrap_iterations`

For each round, append one line to `== Wrap-up ==` in the state file: `round <N>: <outcome>`.

W5. Verify the PR reflects the latest state. Run `gh pr view "$PR" --json headRefOid -q .headRefOid` and confirm it matches `git rev-parse HEAD`. Log a mismatch under `== Wrap-up ==`.

W6. Output `<promise>NO_FINDINGS_WORTH_FIXING</promise>` and stop.

== COMPLETION PROMISE RULES ==

Output `<promise>NO_FINDINGS_WORTH_FIXING</promise>` ONLY when at least one of:
- PHASE 2 wrap-up has finished (cleanly or with a logged failure).
- You are on the wrong branch (safety check) — skip wrap-up in this case.

Do NOT output the promise to escape the loop because "this is hard" or "I am stuck". The loop is designed to continue through failed attempts — that is what `failed-once`/`failed-twice` tracking is for.

== PROJECT-SPECIFIC DO NOTs ==

{{do_nots_block}}
```
