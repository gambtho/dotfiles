# <effort>: shared lane rules

Every lane in this effort reads this file with its own prompt. If they conflict, stop and
ask the coordinator.

## Ownership

| Lane | Repo | Owns | Doesn't touch |
|---|---|---|---|
| W<n> | <owner/repo> | <paths/globs> | <paths other lanes own> |

If you need a change in another lane's area, write it in your report instead of making it.

## Open PRs to stay off

- <owner/repo#N (owner): files it touches. Re-check `gh pr list` before each PR.>

## Rules for every lane

- Audit first and stop for approval, unless the scope is already approved.
- Small PRs, one theme each, from a fresh base. Stop when each is open and green.
- Never push to the default branch, never merge, no force push on others' branches.
- Public text is a draft until the user approves it.
- No secrets, lane numbers, internal names, customers or events in anything public.
- Teammates' work: propose, don't delete; mark it "ask owner" with their login.

## Sequencing

<Landing order and dependencies between lanes.>
