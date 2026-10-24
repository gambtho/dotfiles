# <project> state

Volatile. Update when a lane opens, closes or changes what it waits on, and when a
decision lands. Re-check GitHub before trusting any PR state here.
Stable facts/rules: `COORDINATION.md` and `AGENTS.md`; people: `PEOPLE.md` or the
people section in COORDINATION.md.
Last updated: <date>. Last lane number used: **W<n>**.
Last end of day: <date time>.
Last weekly pass: <date>.
Single writer: <coordinator session; other sessions leave notes at the project report path>.

**Goal (required):** <the outcome everything is driving toward>.
**Next human decision:** <action and link, or none>.
**Tomorrow / next session first actions:** <critical-path action; needs-the-human list>.

Pick-up test: a fresh session can state the goal, the critical path and the human's next decision from STATE.
Aim for a scannable summary; line counts are guidance, not limits.

## Critical path (required)

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
Parked: <W<n> — stop: waiting on what; resume: first action and condition; report path>.

## Waiting on people

- **<person>:** <PRs/questions, in priority order>

## Decisions still in force

- <date>: <decision, one line, with PR/issue link>

## Session notes

In-flight judgment that isn't a decision yet, so the next session doesn't re-ask
(e.g. "waiting for <person>'s re-approval on #N after a push dismissed it").

## Upcoming

- <date or trigger>: <what>
