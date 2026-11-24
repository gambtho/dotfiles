# Coordinator check of a lane's PR

Only a coordinator loads this reference, when a lane reports a PR ready. The lane ran
closeout; this checks its claims against current evidence. It adds no merge or posting
authority. Profiles follow the [private maintenance reference](coordinator-maintenance.md).

## Summary and evidence

- Require a decision summary of at most ten lines at the top of the report: PR/head and
  CI at that head, ready or blocked, and the human's next action. Have the owner fix a
  buried or oversized summary; don't relay the whole report through the human.
- Reuse review evidence before reviewing again. Match base, scope, content identity and
  profile identity under the [shared review contract](project-review-contract.md#review-evidence);
  keep the reviewed head as provenance. For a match, check freshness, blockers and the
  delta only. A changed head alone does not invalidate matching content. If an identity or
  coverage differs, review the affected scope; repository-required reviews still apply.
- For deep reviews, run read-only background reviewers with a specific uncovered focus,
  then spot-check their top findings before drafting anything from them.

## Verify before calling ready

Inspect `gh pr view <n> -R <repo> --json state,headRefOid,mergeable,files,statusCheckRollup`
and the delta's relevant diff. Require **local HEAD = remote PR head = tested revision = CI
revision**, required checks passing on that revision and no unresolved blockers.

Run the [snapshot helper](../SKILL.md#snapshot-helper) with
`--repo <lane worktree> --github-repo <repo> --pr <n>`. Without that worktree, point
`--repo` at another checkout, keep the other flags, ignore only its local blockers and take
local HEAD from the report; with no checkout, use the snapshot's fallback commands. Check
`staleCheckRevision` and `checkRevisionUnknown`, not just a green rollup. On a changed or
unreadable final PR observation, refresh before recommending ready; a later head change
invalidates the recommendation.

Require the lane's bot opportunity and final thread and review-body read from
[bounded waiting](../SKILL.md#bounded-waiting); do not make the human relay or babysit
that wait. Local CodeRabbit is the standing default for every lane and coordinator unless
the project records an explicit project opt-out. It qualifies only as the
[local fallback](../SKILL.md#local-coderabbit-fallback) says: a current-head rate limit or
quota from a Copilot request, the `gh` API or a review bot, with the observed response or
URL; a size-only skip does not. The lane never stalls for a human Copilot request; without safe
local auth, included quota or billing, require one independent review by a different
model family instead, and `review round: local CodeRabbit CLI` or the fallback reason in
the report and PR body.

Confirm scope and the approved outcome against the human's current workflow: say what the
change gives the human and why existing mechanisms do not already cover it. State
infrastructure-only delivery and unverified outcomes plainly; a merge is not a try.

## Size

Split additions by kind:

```sh
gh pr view <n> -R <repo> --json files --jq '[.files[]|{p:.path,a:.additions}]|{tests:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|(^|/)tests?/|test_")))|map(.a)|add // 0),docs:(map(select(.p|test("\\.md$")))|map(.a)|add // 0),product:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|(^|/)tests?/|test_|\\.md$")|not))|map(.a)|add // 0)}'
```

Flag tests above ~1.5× product unless each test is a distinct safety invariant, and flag
new scripts or tools outside the lane's goal.

## Overlaps and merge order

Detect or record merge queue status from repository policy; never assume a queue. With
one, readiness is queue-ready. Without one, overlapping PRs need the later PR's CI at a
combined head before merge; a textual no-conflict check is not that. List other open PRs
touching the same files, commands or flags, recommend a merge order and say which lane
absorbs the conflict (usually the one that owns the rename or the broader change). List
every lane the PR unblocks or conflicts with. Once two lanes PR into one repo, check for
files every PR edits (changelog, generated inventories, counts) and fix that first.

Before giving a lane git commands (rebase, retarget, reset), verify the branch's actual
ancestry (`gh api repos/<o>/<r>/compare/<base>...<head>`). For takeovers and stacked-branch
recovery, keep the original design, list deviations and draft any takeover comment for
approval; never rewrite someone else's branch.

## Pushback

- Decide in-scope repair or separate follow-up before forwarding a finding; give a bounded
  outcome and size, not an invented mechanism. Push back on over-engineering, timeout
  bumps, scope creep and public process noise.
- When a lane asks to bypass a hook, guard or policy, find out why it failed and give the
  narrowest fix as a full command the human can paste.
- Bound flake diagnosis: inspect failed logs and the base for the same failure, and allow
  at most one rerun of the same unexplained failure before reporting a blocker with
  evidence. No timeout increases or test bypasses as a fix.
