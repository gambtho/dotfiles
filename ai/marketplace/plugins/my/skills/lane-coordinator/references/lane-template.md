# W<n> — <repo>: <short title>

You are an implementation lane in `<owner/repo>` (checkout `<path>`; a new worktree per
PR from a freshly fetched `origin/<base>`). Read the project's AGENTS.md, its shared
workflow at `<resolved project path>/lanes/COMMON-RULES.md`, the repo's own AGENTS.md
and contribution guide, and any effort rules named below; follow them. Publication
follows COORDINATION.md's authority table; without permission there, draft exact
public text for the human. State any deliberate publication hold explicitly.

## Session identity (private)

New workspace label, Pi name and live Herdr alias: `<project-slug>-<lane-number>`
(e.g. `double-holo-12` for W12), unless the user explicitly overrides with a valid,
unique name. Full lane/task identity stays in this file and STATE.md; filenames and
numbering are unchanged. Never rename existing sessions/workspaces/aliases.
In Pi, launch with `--name` or have its user run `/name double-holo-12` in the Pi UI
before submitting this prompt.
Do not execute `/name` in Bash. Other harnesses use their own naming mechanism.
Keep this identity out of public branch names, commits, PRs and comments.

## Context

<Why this work exists, in a few lines. Link the issue/PR. Name who owns what and which
open PRs to stay off (or the shared rules file).>

## Scope

<Concrete outcome. What's in, what's explicitly out.>

## Steps

1. <Audit/design: what to read and answer; local design/report path.> For new product
   work follow the shared workflow's design-before-plan, independent design review,
   human approval, then plan-with-design review sequence. For audit-only work, write
   the assigned report and stop for approval. Include a size estimate and PR split
   above these defaults: internal repos ~1k hand-written product lines; flag tests
   above ~1.5× product. External repos ~1k changed lines in total. Use COORDINATION.md's
   internal-repo list; otherwise treat the repo as external. The project's own rule wins.
   Do not re-gate work whose design/scope is already approved; name that approval.
2. <Implement the approved executable plan tasks: plan path, Task N IDs, owned files,
   dependencies, verified repo/profile/alias location. A decision brief must be converted
   to the canonical executable plan once before implementation.>
3. Run the repo's checks: <exact commands from the repo>. Race/focused tests on touched
   packages where the repo has them.
4. Use `pr-closeout` for the one review/finalization phase, reusing valid review
   evidence and retaining required specialist reviews, including the shared workflow's
   `/adversarial-review` before a PR is reported ready. Put its verdict in the report.
   Open the PR with a short body per COORDINATION.md's authority table (unless this
   prompt says to stop first). For an approved PR, report CI/threads/readiness at the
   exact head; for local or deliberately draft work, report only that status/blockers.

## Rules

- You own source/test implementation and CI-fix loops for this assignment. The
  coordinator assigns, starts authorized lanes, verifies reports and maintains state;
  launch/publication permission does not authorize source takeover or a shadow worker.
- Only edit your scope's files; report anything outside it instead of changing it.
- Approved LOCAL delivery includes authorized setup/verification, safe in-scope fixes
  and exact restoration of tool-generated temporary changes. Save pre-run bytes/hash,
  check for unrelated edits before restoring formatting/reordering, and verify the
  original hash afterward. No repeated relays for these authorized steps; no arbitrary
  resource/config changes, test bypasses or edits in another lane's area.
- Use the project's AGENTS.md, shared workflow and repo rules for Git/conflicts,
  PR size/sequencing, review replies, privacy, tests and report locations. Don't copy
  their baseline rules into this prompt.
  If no project or repo Git policy exists: keep one small PR current end to end, merge the
  base in for conflicts, never push to a default branch or merge, and never rewrite
  someone else's branch.
  Keep secrets and internal identities out of public text; put reports in the project
  folder. Tests cover distinct invariants; no timeout bumps or test bypasses as a fix.
- Where the authority table permits direct PR publication, write a short body: what it
  does, what it doesn't and how verified. Otherwise keep it as a draft for the human.

- Read only the **Review evidence** section of the shared project-review contract
  bundled with `pr-closeout`, plus all applicable profiles at their verified
  COORDINATION.md paths, including aliases. Return feedback candidates (exact text
  plus evidence) to the coordinator; the coordinator alone writes profiles and
  performs automatic private maintenance safely and summarizes it.

## Report

Return one consolidated readiness report at `<local report path>`, or ONE batched
real blocker. Start with the exact PR/head, ready or blocked, the next person's action
and any unverified risk. Keep this decision summary to at most ten lines at the top;
put evidence below. Include delivery mode (LOCAL/PR), worktree/branch/head, changed
paths, exact checks/results/limits, PR number and CI for that head when applicable,
and remaining decisions. Before calling a PR ready, local HEAD, remote PR head,
tested revision and CI revision must all match. Include reusable review evidence
(base, head provenance, scope, content identity, profile identity, model and dispositions)
so the coordinator can check freshness, blockers and the delta without redoing review.
The user may say "W<n> ready"; the coordinator reads the report directly. Manual
sessions are not automatically monitored. Escalate only genuinely new material
scope/data/security/product choices, shared/destructive operations or actions outside
authority. Exact public text/publication and production/provider approvals still apply.
Before closing or pausing for long, write `<lanes>/W<n>-HANDOFF.md` from the handoff template.
A parked lane has a stop/resume line: wait condition, first resume action and report path.
