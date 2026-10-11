# W<n> — <repo>: <short title>

You are an implementation lane in `<owner/repo>` (checkout `<path>`; a new worktree per
PR from a freshly fetched `origin/<base>`). Read the repo's `AGENTS.md`/`CLAUDE.md` and
contribution guide first and follow them. Never push to the default branch, don't merge,
don't post on GitHub without the user's OK.

## Context

<Why this work exists, in a few lines. Link the issue/PR. Name who owns what and which
open PRs to stay off (or the shared rules file).>

## Scope

<Concrete outcome. What's in, what's explicitly out.>

## Steps

1. <Audit/design: what to read and answer.> Write it to `<local report path>` and
   **stop for approval**. (Skip this gate if the scope is already approved; say so.)
2. <Implement the approved scope.>
3. Run the repo's checks: <exact commands from the repo>. Race/focused tests on touched
   packages where the repo has them.
4. Open the PR (draft or not, say which) with a short plain body. Stop when it's open
   and CI is green. If it's blocked, failing or pending past a reasonable wait, stop and
   report that.

## Rules

- Only edit your scope's files; report anything outside it instead of changing it.
- Code comments describe current behavior only; history goes in commits/PR bodies.
- No secrets in logs, output or argv. No lane numbers, internal names, customers or
  events in anything public (branches, commits, PRs, comments).
- No force push on anyone else's branch. No timeout bumps as a fix.
- Public text (PR bodies, comments) is a draft until the user approves it, unless this
  prompt says otherwise.

## Report

The PR number and head SHA, CI result for that head, what changed (and anything outside
scope), exact local checks run, and any decision needed. Before closing or pausing for
long, write `<lanes>/W<n>-HANDOFF.md` from the handoff template.
