# <project> coordination

Stable facts for the coordinator. Volatile state lives in `STATE.md` in the same folder.
Lane prompts: `~/<project>-local/lanes/W<n>-<slug>.md`. Last reviewed: <date>.

## Repositories

| Repo | Coordinator checkout | Merge policy |
|---|---|---|
| <owner/repo> | <path> | <who merges, required checks/reviews, strategy, contribution rules (DCO, AI disclosure, who replies to reviews); verified review profile/alias path, executable plan/task IDs and review evidence location> |

## People

| Who | GitHub | Area | Tone |
|---|---|---|---|
| <name> | <login> | <what they own> | <e.g. senior: offer and ask; non-native English: short and simple> |

## Standing rules

- Coordinator prepares assignments, starts authorized lanes, verifies reports,
  maintains state and publishes approved material. Lanes own implementation/tests
  and CI-fix loops; no coordinator takeover or shadow implementation worker.
- New workspace/Pi/Herdr names default to `<project-slug>-<lane-number>`; preserve
  existing names and full W<n>/task identity in lane files/STATE.md.
- Lanes draft every public post; the user approves the exact text.
- Never push to main, never merge, no force push on someone else's branch.
- <project-specific rules: context pinning, comment style, privacy, etc.>

## Standing grants (no per-item approval needed)

- <e.g. close a lane when its PRs merge; post verified review replies on repo X>

## Writing

<voice preferences and flagged phrases the user has corrected>
