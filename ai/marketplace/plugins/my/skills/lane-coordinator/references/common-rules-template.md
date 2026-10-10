# <Effort>: shared lane rules

Every manually started lane reads this file and its prompt. If instructions conflict,
stop and ask the coordinator. One coordinator owns this file and COORDINATION.md.

## Ownership and isolation

Only edit owned paths. Route cross-lane needs through the coordinator before editing.
Each lane uses a distinct linked worktree and branch per repo, before any repository
write including plans/docs/tests. Do not change another lane's checkout or bypass guards.

| Lane | Repo | Owned paths/globs | Worktree / branch | Shared paths requiring approval |
|------|------|------------------|-------------------|---------------------------------|
| <Wn> | <owner/repo> | <paths> | <path/branch> | <lockfiles, CI, manifests, etc.> |

## Open PRs to stay off

- <owner/repo#N: owner and scope; do not push, rebase, comment, or duplicate work>

## Hard rules

- Never push to default/protected branches. Never merge; the user merges.
- No force pushes without explicit approval. Never mutate another lane's branch/PR.
- Audit/design approval first on non-trivial work unless that scope is already approved.
- Implementation approval, permission to push a specific remote/branch, and exact
  outward-draft/destination approval are separate gates. Stop at an unapproved gate.
- Before creating/editing PR titles/bodies, comments, reviews, or replies, show the
  exact draft and get approval. Changed text/destination requires fresh approval.
- One PR at a time per lane; report blocked/failing/pending instead of waiting indefinitely.
- Report actual repo/worktree/branch/SHAs, observation time, check evidence, and limits.
  Absent/inaccessible checks are not green; distinguish PR state from CI state.
- No secrets in logs/argv, or private names/lane identifiers in public text.
- Follow contribution policy. Keep generated workflow artifacts outside Git unless
  the user explicitly requests versioning those specific artifacts.
- Lanes write assigned local reports/handoffs, not the shared registry. No automatic
  cross-session monitoring or reminders are assumed.

## Sequencing

<Landing order, dependencies, and when ownership may transfer with coordinator approval>
