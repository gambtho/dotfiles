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
Next decision and first actions: see Critical path and Needs the human below.

Pick-up test: a fresh session can state the goal, the critical path and the human's next decision from STATE.
One home per fact: keep each fact in its section below; link rather than repeat it.
Aim for a scannable summary; line counts are guidance, not limits.

## Critical path (required)

Links only, each with an owner and a one-word state.

1. <step link> — <owner lane or person> — <state>
2. <step link> — **unowned** — <state> ← raise this first

Recheck this chain whenever a lane reports or something merges. A link without an owner
is the most important thing to surface.

## Open lanes

Status, PR numbers without heads or CI, next actor and action, and report path live here.
For a parked lane, include its stop/resume condition in its row.

| Lane | What / report | State | Next actor and action | Launch |
|---|---|---|---|---|
| W<n> | <goal; PR numbers; report path> | Active / Waiting / Paused / Ready | <actor: next action> | Manual, or <W<n>-launch.json; project-slug-number; stage; workspace / root-pane ID> |

Launch is terminal setup, not proof of completed work. Preserve the last confirmed
stage and IDs on failure. The launch receipt is authoritative; this row is its concise
projection. Creating / Created / Starting / Ready / Submitting / Submitted are setup
checkpoints. Submitting is possibly delivered: inspect only, never automatically resend.
Keep the full W<n>/task identity here, separate from short new session names.

Closed recently: <W<n>, …>
Parked: <links to paused lane rows, without repeating their facts>.

## Needs the human

Priority-ordered one-liners; link to a lane row rather than repeating its facts.

1. <decision or action and link, or none>

## Waiting on others

Only waits not already a lane row's next actor.

- **<person>:** <question or action and link>

## Decisions still in force

Keep at most about 10, only those not already in the project's rule files.

- <date>: <decision, one line, with PR/issue link>

## Session notes

In-flight judgment that isn't a decision yet, so the next session doesn't re-ask.
Link to its home action above; keep only distinct context here.

## Upcoming

Only dated or triggered items not already in a lane row.

- <date or trigger>: <what>
