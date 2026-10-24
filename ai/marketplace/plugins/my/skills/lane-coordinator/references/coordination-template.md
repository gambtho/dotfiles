# <project> coordination

Stable facts for the coordinator. Volatile state lives in `STATE.md` in the same folder.
Lane prompts: `lanes/W<n>-<slug>.md`. People: `PEOPLE.md` (or an existing people section
here). Project-wide lane rules live in `AGENTS.md`; refer to them rather than copying.
Last reviewed: <date>.

## Repositories

| Repo | Coordinator checkout | Merge owner / policy | Conflict method | WIP limit | Review profile |
|---|---|---|---|---|---|
| <owner/repo> | <path> | <who merges; strategy; required checks/reviews; contribution rules> | <merge the base in, or rebase; repo rule source> | <max open PRs; source> | <verified profile/alias path, or none> |

Keep executable plan/task IDs and current review evidence in lane prompts/reports,
not the stable repo table. Verify repository identity before assigning a profile.

## Authority table

Record confirmed authority, including the actor and source. Unfilled rows grant
nothing. PR-body authority is a project decision, not a blanket requirement that
lanes draft every public post.

| Action | Who may | Otherwise | Source |
|---|---|---|---|
| Open PRs / write PR bodies | <actor, repos, direct or draft, constraints> | <approval path> | <human's decision and date> |
| Reply to a person's review / other public posts | <actor, destinations and exact limits> | <draft exact text for the human> | <decision and date> |
| Handle bot review threads | <actor and limits> | <approval path> | <decision and date> |
| Write STATE / close a lane row | <single coordinator writer> | <other sessions' notes location> | <decision and date> |
| Git publication / merge | <actors and limits; reference AGENTS.md> | <human decision> | <decision and date> |
| Human away | <already-authorized work and maintenance> | <what waits for the human> | <decision and date> |

## Routines

Project-owned commands; replace placeholders with confirmed commands and limits.
An unfilled command uses the skill's manual fallback; entries do not expand authority.

| Routine | Command (including working directory) | Budget | Output |
|---|---|---|---|
| Drift check | <project drift-check command> | <time/query limit> | <local drift report path; observation time and unknowns> |
| Morning sweep | <project sweep command> | <time/query limit> | <current PR/lane observations and unknowns> |

Record failed checks or exhausted budgets as unknown, not clean results.

## Project facts

<Only stable facts not already owned by AGENTS.md or repo instructions. Name the
source for confirmed rules; don't promote a lane's own plan into human intent.>

## Writing

<Voice preferences and flagged phrases the user has corrected. Per-person tone goes
in PEOPLE.md, falling back to an existing people section here.>
