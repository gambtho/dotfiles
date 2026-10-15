---
name: pr-closeout
description: Drive a GitHub pull request to merge-ready after implementation or review, in any repository. Use after creating or updating an agent-authored PR unless the user opts out or the PR is intentionally draft/WIP; also use when asked to fix merge conflicts, make CI green, handle unresolved review comments, reply to or resolve review threads, push PR branch updates, or repeat until a PR is green and review-clean.
---

# PR Closeout

Drive the PR from "has feedback or failing checks" to "currently merge-ready": no merge conflicts, required checks green, no unresolved actionable review threads, non-blocking review decision. Repository rules (`AGENTS.md`, `CONTRIBUTING.md`, project review profiles) win over anything generic here.

## Contract

- CI failures and review comments are signals, not truth. Verify each against the real code path, logs and current diff before changing code.
- Push back on stale, duplicate, speculative or regression-causing feedback with concise evidence instead of churning code.
- Small fixes at the right ownership boundary; no unrelated cleanup or refactors.
- After any fix: rerun relevant local checks, push, and take a fresh snapshot. Stop when no current blockers remain; don't poll for nicer wording.

## Guardrails

- Never push to `main`/the default branch. Push only the PR branch. Never merge, enable auto-merge, retarget, force-push, amend, rebase or run destructive git operations unless explicitly asked or the repository's workflow clearly requires it.
- Update a stale branch by merging the base into it, not rebasing, unless the repository says otherwise.
- Commit message and sign-off follow the repository's convention (DCO `-s` only where required). Add no AI attribution where the repository's policy forbids it.
- Redact secrets in logs and summaries: tokens, auth URLs, JWTs, cookies, credentials.
- **Who you may answer:**
  - **Bot threads** (CodeRabbit, Copilot, other review bots): reply with fix or pushback evidence, then resolve.
  - **Human threads:** draft replies in the final report; post or resolve only when the user explicitly authorized posting for this PR. Never resolve a human's thread without a reply they can see.
- Say "currently no unresolved actionable review threads remain", never "reviewers will have no more comments".

## Before the loop (new or substantially changed PRs)

1. **Project review profile.** Read every existing profile, in this order, and check the diff against it:
   1. `.agents/review.md` in the repository
   2. `~/.pi/pr-reviews/{OWNER}/{REPO}/review.md`
   3. `~/.pi/pr-reviews/{OWNER}/{REPO}/learnings.md`

   `OWNER/REPO` is the PR's **base** repository (for a fork PR, the upstream). Fix clear violations before pushing. Profiles are maintained by the user/coordinator: if a reviewer's comment reveals a recurring preference the profile lacks, **propose** the addition in the final report; don't edit the profile.
2. **Polish / review.** For non-trivial code changes, run the repository's review step (`$autoreview` where its AGENTS.md asks for it, otherwise `/polish` or `polish-core` if installed) once before the first push, not on every loop.
3. **Size.** Report product vs test vs docs/generated lines. Flag (don't silently ship) a PR over ~1.5k hand-written product lines or with tests above ~1.5× product; suggest a split along ownership boundaries.
4. **Body.** Concise: what changed, compatibility/breaking notes, verification actually run (including any live run and its limits). Stacked PRs say "stacked on #N — review after it lands" and stay draft until the parent merges.

## Snapshot helper

Read-only; use it first and after every push or GitHub write batch:

```bash
<skill-dir>/scripts/pr_snapshot.sh --summary              # current branch's PR
<skill-dir>/scripts/pr_snapshot.sh --pr 123 --summary
<skill-dir>/scripts/pr_snapshot.sh --github-repo OWNER/REPO --pr 123 --summary
```

It reports local branch/head, PR metadata, unresolved review threads (bodies omitted), all-check and required-check buckets, and blocker booleans. Empty check lists on a just-pushed PR count as pending, not green. If it fails (auth, missing `gh`/`jq`), report that and fall back to `gh pr view`, `gh pr checks` and GraphQL `reviewThreads`.

## Workflow

1. **Target.** Use the given PR, else the current branch's. Fetch the PR's actual base. Confirm the checkout is on `headRefName` at `headRefOid`; if not, check it out or stop and say why. Dirty unrelated changes: stop and ask. A branch you can't push (someone else's fork): report before editing.
2. **Merge conflicts first.** Merge the base, resolve narrowly preserving both sides' intent, run focused verification for the conflicted areas.
3. **Review threads.** Use thread-aware data (`reviewThreads`, `isResolved`, `isOutdated`, path/line). Cluster related threads into one fix. If the answer is an explanation, not code, reply (bots) or draft (humans) with evidence. Outdated-because-already-fixed: point at the commit. Conflicting or product/design-level comments: surface the tradeoff, don't guess.
4. **CI failures.** Read the failing job's logs before editing; never infer from the check name. Smallest fix tied to the observed failure and this PR's diff.
   - **Possibly flaky or unrelated:** check whether the same test fails on the base branch's recent runs. If it isn't this PR's fault, say so with evidence; at most one rerun of that job, and only if authorized. Never raise timeouts or retries to make a check pass. If the suite is broadly flaky, report the failure rate rather than chasing it.
   - **Bot review skipped** (rate limit, size): at most one re-trigger per head (e.g. `@coderabbitai review`), only where that bot is already installed.
5. **Verify locally** with the repository's own commands from `AGENTS.md`/`CONTRIBUTING.md` for the files changed (lint, tests, generators, workflow linters). State exactly what ran.
6. **Commit and push** (when authorized): review `git diff`/`git status`, follow the repo's commit convention, push the PR branch, take a fresh snapshot; don't assume checks attached to the new head.
7. **Reply and resolve** per the guardrails: bots replied and resolved; human replies drafted unless posting was authorized. Re-query thread state after writes.
8. **Repeat** until no current blockers remain. New comments during the loop get the same treatment.

## Bounded waiting

Queued or running checks with moving timestamps are progress. Poll at sensible intervals while a run set is active; stop after a stable pass/fail state, after only external/human blockers remain, or when checks sit queued with no logs (report as an external blocker). No empty commits or reassurance reruns.

## Final report

- PR URL, branch, head SHA, commits pushed.
- Size (product / test / docs), and any split recommendation.
- Conflicts resolved; CI checks inspected and final status (including external/pending blockers and flake evidence).
- Threads: bots replied/resolved; human threads with **drafted replies** (verbatim, one line each where possible) or posted ones if authorized; anything left open and why.
- Local verification commands run; review step (`$autoreview`/polish) run or why not.
- Proposed project-profile additions, if any.
- Merge readiness and remaining human/external blockers.
