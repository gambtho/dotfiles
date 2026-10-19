# <effort>: shared lane rules

Every lane in this effort reads this file with its own prompt. If they conflict, stop and
ask the coordinator.

## Ownership

| Lane | Repo | Owns | Doesn't touch |
|---|---|---|---|
| W<n> | <owner/repo> | <paths/globs> | <paths other lanes own> |

If you need a change in another lane's area, write it in your report instead of making it.
Lanes own their source/test work and CI-fix loops. The coordinator prepares assignments,
starts authorized lanes, verifies reports, maintains state and publishes approved
material; start/publish authority does not authorize source takeover or a shadow worker.

## Open PRs to stay off

- <owner/repo#N (owner): files it touches. Re-check `gh pr list` before each PR.>

## Rules for every lane

- Audit first and stop for approval, unless the scope is already approved.
- Small PRs, one theme each, from a fresh base. Follow `pr-closeout` for scoped
  review/finalization, preserving publication approval and reusing valid review evidence.
- Profiles/aliases and executable plan task ownership come from COORDINATION.md;
  return feedback candidates to the coordinator, who uses the shared publication helper.
- Never push to the default branch, never merge, no force push on others' branches.
- Approved LOCAL delivery covers authorized setup/verification, safe in-scope
  corrections and exact restoration of tool-generated temporary changes. Save the
  pre-run bytes/hash; confirm no unrelated edits, restore only generated changes and
  verify the original hash. No arbitrary resource/config changes or test bypasses.
- Return one consolidated shared readiness report or ONE batched real blocker. The
  user can signal "W<n> ready"; the coordinator reads it directly. Manual sessions
  are not automatically monitored. Escalate new material choices, shared/destructive
  operations and actions outside authority, not routine authorized LOCAL steps.
- Public text is a draft until the user approves it. Exact publication and
  production/provider approvals are unchanged.
- No secrets, lane numbers, internal names, customers or events in anything public.
- Teammates' work: propose, don't delete; mark it "ask owner" with their login.

## Sequencing

<Landing order and dependencies between lanes.>
