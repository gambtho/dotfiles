# W<n> handoff

Local handoff for a manually resumed Pi lane, not a Pi `handoff` tool invocation.
Keep it outside Git unless the user explicitly authorizes versioning this artifact.

## Provenance and state

- Repository: <owner/repo>
- Pi session identifier/path: <known, or unresolved>
- Worktree / branch: <actual path/name>
- Base ref / SHA / freshness: <verified evidence, or unknown>
- Local HEAD: <actual SHA>
- Observed at: <actual time>
- Current scope / lane state: <approved scope; active/blocked/paused/closed>
- Prompt / shared rules / assigned report: <absolute local paths>

## PRs and verification

| PR URL | Head SHA | PR state | CI state | Required checks known? | Evidence / observed at | Waiting on |
|--------|----------|----------|----------|------------------------|------------------------|------------|
| <URL/not opened> | <SHA/unknown/not applicable> | <open/draft/closed/merged/not opened/unknown> | <passing/failing/pending/not configured/unknown/not applicable before PR> | <yes/no/not applicable> | <checks/links/time> | <decision> |

Local verification: <exact commands, outcomes, tested SHA, limitations; not run if not run>
Coverage and ownership exceptions: <paths/review omissions/conflicts, or none>

## Unpushed or uncommitted work

- Branches and HEADs: <actual names/SHAs; remote/branch if push authorized>
- Dirty files, patches/stashes: <actual paths/refs, or none; never stash others' work>
- Generated artifacts remain local: <paths; exclude from staging>

## Decisions and authorization

<Scope approval, push permission, and exact outward-draft/destination approval separately;
reference the coordinator record and actual approval evidence. Missing/ambiguous means unapproved.>

## Next steps and gotchas

1. <next actionable step or decision needed>
2. <recheck Git state, current PR head and checks before relying on this handoff>

<Dependencies, unresolved risks, blocked commands, contribution/privacy policy>

On resume, read local records and applicable repository instructions, then verify
actual workspace and external state. Old CI applies only to its recorded SHA.
