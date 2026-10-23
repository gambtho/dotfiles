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

Read the project's AGENTS.md (or the repo's own rules) for Git, PRs, privacy, tests
and reports. This file records effort-specific ownership and exceptions, not another
copy of those rules. If none exist, use small sequential PRs, never push to a default
branch or merge, never rewrite someone else's branch, and keep private details out
of public text.

- Audit first and stop for approval, unless the scope is already approved.
- Small PRs, one theme each, from a fresh base. Follow `pr-closeout` for scoped
  review/finalization, preserving publication approval and reusing valid review evidence.
- Profiles/aliases come from COORDINATION.md; executable plan/task ownership comes from the lane prompt.
  Return feedback candidates to the coordinator; only that coordinator writes profiles
  and commits/pushes them with plain Git in the private store.
- Approved LOCAL delivery covers authorized setup/verification, safe in-scope
  corrections and exact restoration of tool-generated temporary changes. Save the
  pre-run bytes/hash; confirm no unrelated edits, restore only generated changes and
  verify the original hash. No arbitrary resource/config changes or test bypasses.
- Return one consolidated shared readiness report or ONE batched real blocker. The
  user can signal "W<n> ready"; the coordinator reads it directly. Manual sessions
  are not automatically monitored. Escalate new material choices, shared/destructive
  operations and actions outside authority, not routine authorized LOCAL steps.
- PR publication and other public text follow the authority table in COORDINATION.md.
  Without permission there, draft exact text for the human. Production/provider
  approvals are unchanged.

## Sequencing

<Landing order and dependencies between lanes.>
