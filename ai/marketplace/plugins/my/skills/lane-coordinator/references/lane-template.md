# W<n> — <repo>: <short title>

You are an implementation lane in `<owner/repo>` (checkout `<path>`; a new worktree per
PR from a freshly fetched `origin/<base>`). Read the repo's `AGENTS.md`/`CLAUDE.md` and
contribution guide first and follow them. Never push to the default branch, don't merge,
don't post on GitHub without the user's OK.

## Session identity (private)

Display name: `<project> W<n> — <short title>`. In Pi, launch with `--name` or have
its user run `/name <display name>` in the Pi UI before submitting this prompt.
Do not execute `/name` in Bash. Other harnesses use their own naming mechanism.
Keep this identity out of public branch names, commits, PRs and comments.

## Context

<Why this work exists, in a few lines. Link the issue/PR. Name who owns what and which
open PRs to stay off (or the shared rules file).>

## Scope

<Concrete outcome. What's in, what's explicitly out.>

## Steps

1. <Audit/design: what to read and answer.> Write it to `<local report path>` and
   **stop for approval**. Include a size estimate and a PR split if it's over ~800
   product lines. (Skip this gate if the scope is already approved; say so.)
2. <Implement the approved executable plan tasks: plan path, Task N IDs, owned files,
   dependencies, verified repo/profile/alias location. A decision brief must be converted
   to the canonical executable plan once before implementation.>
3. Run the repo's checks: <exact commands from the repo>. Race/focused tests on touched
   packages where the repo has them.
4. Use `pr-closeout` for the review/finalization phase, reusing valid review evidence
   rather than adding another automatic reviewer pass. Publication still needs the
   user's approval. For an approved PR, report CI/threads/readiness at the exact head;
   for local or deliberately draft work, report only that scoped status and blockers.

## Rules

- Only edit your scope's files; report anything outside it instead of changing it.
- Code comments describe current behavior only; history goes in commits/PR bodies.
- No secrets in logs, output or argv. No lane numbers, internal names, customers or
  events in anything public (branches, commits, PRs, comments).
- No force push on anyone else's branch. No timeout bumps as a fix.
- Tests cover distinct invariants, roughly proportional to product code; table-driven
  where cases share a shape; no duplicated fixtures. Put product/tests/docs line counts
  in the PR body.
- Conflicts with the base: merge it in, don't rebase, unless the repo asks otherwise.
- Handoffs and reports go under the project folder, never `/tmp`.
- Public text (PR bodies, comments) is a draft until the user approves it, unless this
  prompt says otherwise.

- Read the shared project-review contract bundled with `pr-closeout` and all applicable
  profiles at their verified COORDINATION.md paths, including aliases. Return feedback
  candidates (exact text plus evidence) to the coordinator; do not publish profiles
  yourself. The coordinator performs automatic private maintenance safely and summarizes it.

## Report

The PR number and head SHA, CI result for that head, what changed (and anything outside
scope), exact local checks run, and any decision needed. Before closing or pausing for
long, write `<lanes>/W<n>-HANDOFF.md` from the handoff template.
