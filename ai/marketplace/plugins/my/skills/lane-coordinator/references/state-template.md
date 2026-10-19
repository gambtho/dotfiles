# <project> state

Volatile. Update when a lane opens, closes or changes what it waits on, and when a
decision lands. Re-check GitHub before trusting any PR state here.
Stable facts: `COORDINATION.md` in the same folder.
Last updated: <date>. Last lane number used: **W<n>**.

## Critical path

Goal: <the outcome everything is driving toward, e.g. "demo recording", "release v1">
1. <step> — <owner lane or person> — <PR / status>
2. <step> — **unowned** ← raise this first

Recheck this chain whenever a lane reports or something merges. A link without an owner
is the most important thing to surface.

## Open lanes

| Lane | What | State | Waiting on | Launch |
|---|---|---|---|---|
| W<n> | <one line: goal and current PR numbers> | Active / Waiting / Paused / Ready | <person, PR, or —> | Manual, or <W<n>-launch.json; project-slug-number; stage; workspace / root-pane ID> |

Launch is terminal setup, not proof of completed work. Preserve the last confirmed
stage and IDs on failure. The launch receipt is authoritative; this row is its concise
projection. Creating / Created / Starting / Ready / Submitting / Submitted are setup
checkpoints. Submitting is possibly delivered: inspect only, never automatically resend.
Keep the full W<n>/task identity here, separate from short new session names.

Closed recently: <W<n>, …>
To reopen later: <W<n> (when)>

## Waiting on people

- **<person>:** <PRs/questions, in priority order>

## Recent decisions

- <date>: <decision, one line, with PR/issue link>

## Session notes

In-flight judgment that isn't a decision yet, so the next session doesn't re-ask
(e.g. "waiting for <person>'s re-approval on #N after a push dismissed it").

## Upcoming

- <date or trigger>: <what>
