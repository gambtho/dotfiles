# <project> state

Volatile. Re-check GitHub before trusting any PR state here. Stable facts: `COORDINATION.md`
and `AGENTS.md`; people: `PEOPLE.md`.
Last updated: <date>. Last lane number used: **W<n>**.
Last end of day: <date time>.
Last weekly pass: <date>.
Single writer: <coordinator session; other sessions leave notes at the project report path>.

<!-- Writing it: re-read before replacing and refuse to overwrite a file changed since you
read it; write a same-directory temp file, check it is nonempty with unique lane rows,
recheck the original, then rename. Re-read after a `lane` command updates a row. One
commit per coherent update where the project versions STATE. After a rule or ownership
change, reconcile affected prompts and STATE in the same update and mark old instructions
superseded. Replace, don't add: one home per fact. Closing a lane (merged and tried, retired
or cleaned up; checked at each cleanup and at end of day; never while `awaiting try`) moves its row or paragraph to the
archive (`CLOSED-<month>.md`, same folder) in the same update, as one line:
`- W<n> (<date>, merged #42): <one-line outcome>; report reports/W<n>-REPORT.md`.
Keep STATE at most 200 lines: open lanes, outcomes, decisions in force, needs and next steps.
A decision still in force never moves to the archive. Propose an exact deletion list with sizes for bulky outputs from the lane
report/handoff; it stays under **Needs the human** until decided, and deletion happens
only after the human approves that exact list. Unknown safety or size is not
deletion-ready. Once the report and handoff are saved in the project's report location,
finish a lane worker's task in the bundled skill's order; applying a cleanup plan removes
a worktree, so it is a deletion under the project's authority table. A Herdr-only host's
workspace closes by the legacy reference's "Close a closed lane's workspace". Pick-up
test: a fresh session can state the goal, each outcome's status and the human's next
decision from this file. -->

**Goal (required):** <one line in the human's words> (<date>).

## Outcomes (required, 3–7 rows)

The coordinator proposes rows and status changes; the human confirms. A merge never sets
`works`; only a try does. Stale: a merge touched the area after the last try, or the last
try is over 7 days old.

| ID | Who can do what, where | Status | Evidence (how tried, by whom; observed or the human's word) | Last tried |
|---|---|---|---|---|
| O1 | <who> can <do what> on <which setup> | works / partly / doesn't / untried | <evidence> | <date time> |

## Critical path (required)

Links only, each with the outcome it moves, an owner and a one-word state. Mark rehearsal
and dogfood steps `rehearsal`. Recheck when a lane reports or something merges, respecting
each decision's scope; do not make route-specific dependencies global.

1. <step link> — O<n> — <owner lane or person> — <state>
2. <step link> — O<n> — **unowned** — <state> ← raise this first
3. <step link> — O<n> — rehearsal — <owner> — <state>

## Open lanes

Status, PR numbers without heads or CI, next actor and action, and report path. A merged
lane whose outcome is untried or stale stays here as `awaiting try` with its agreed owner; write
its PR as `#42 merged` so the drift check doesn't read it as still waiting. A parked
lane's row holds all current resume conditions and who decides (a person, or none if automatic).

| Lane | What / report | State | Next actor and action | Launch |
|---|---|---|---|---|
| W<n> | <outcome; host, worker, reason; PR numbers; report path> | Active / Waiting / Paused / Ready / Awaiting try | <actor: next action> | <receipt path and task ID, or Manual> |

Closed recently: <W<n>, …>
Parked: <links to paused lane rows, without repeating their facts>.

## Needs the human

Priority-ordered one-liners; link to a lane row rather than repeating its facts.

1. <decision or action and link, or none>

## Waiting on others

Only waits not already a lane row's next actor.

- **<person>:** <question or action and link>

## Decisions in force

Keep at most about 10, only those not already in the project's rule files; name each
decision's scope in about 25 words with a pointer to its full record. Done or superseded
ones move to the archive; past 10, ask the human which to retire or fold into a rule file.

- D1 (<date>): Keep deployment manual until rollback checks pass; the release owner confirms readiness before each rollout. Full record: `reports/decision.md`.

## Session notes

In-flight judgment that isn't a decision yet, and logged rehearsal overrides with dates.

## Upcoming

Only dated or triggered items not already in a lane row.

- <date or trigger>: <what>
