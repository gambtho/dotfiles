# W<n> — <repo>: <short title>

You are an implementation lane in `<owner/repo>` (checkout `<path>`; a new worktree per
PR from a freshly fetched `origin/<base>`). Read the project's AGENTS.md, its shared
workflow at `<resolved project path>/lanes/COMMON-RULES.md`, the repo's own AGENTS.md
and contribution guide, and any effort rules named below; follow them. Use the shared
workflow's prompt-hash and addressed-note checkpoints before acting and reporting ready.
Coordinator: verify that workflow and its [messaging reference](messaging.md) are readable on
the recipient host before delivery. Publication follows COORDINATION.md's authority table;
without permission there, draft exact public text. State any publication hold explicitly.

Host: <chosen host>: <brief reason matched against Hosts `Use for`; local if no row matches>.
For remote lanes, inbox coverage and note delivery follow messaging.md's host rules.
Coordinator: to avoid an implicit local choice, record the same host/reason in STATE's
`What / report` cell. For remote lanes, include the host alias, verified OS hostname/user,
project/checkout/worktree roots and report source/return command. Use [remote lanes](remote-lanes.md)
to put the host/user guard first and resolve paths and authority/profile references before delivery.
Coordinator: use the [local handoff](herdr-launch.md#manual-pi-handoff): installed
`lane <project>-<n> "Read <path> and follow it."`, otherwise plain Read. For remote lanes,
use `lane --host <binding> <project>-<n> <prompt>` for bound hosts to avoid manual transfer,
instead of that reference's remote Read-only fallback. Follow [bindings](remote-lanes.md#explicit-remote-command)
for setup/authority; manual copy/start is for an unbound host whose Hosts row explains why.

## Session identity (private)

New workspace label, Pi name and live Herdr alias: `<project-slug>-<lane-number>`
(e.g. `double-holo-12` for W12), unless the user explicitly overrides with a valid,
unique name. Full lane/task identity stays in this file and STATE.md; filenames and
numbering are unchanged. Never rename existing sessions/workspaces/aliases.
The user names the session; never run `/name` in Bash. Keep this identity out of public branch names, commits, PRs and comments.

## Context

<Why this work exists, in a few lines. Link the issue/PR. Name who owns what and which
open PRs to stay off (or the shared rules file).>

## Scope

<What the human will see or be able to do in the human's current workflow, or plainly
infrastructure-only. What's in, what's explicitly out.>

## Steps

These review tools and `pr-text` ship with the package. Outside Pi, read `<resolved harness-notes path>`
and each skill's `<resolved skills dir>/<name>/SKILL.md` instead of its slash command.
Coordinator: resolve those to the skill's bundled `references/harness-notes.md` and the package's
`skills/` directory before delivery.
Subscription-harness lanes: cross-family review via `<resolved scripts dir>/codex-review.sh` (Claude Code) or `claude-review.sh` (Codex).
The requirements below are unchanged.

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
   evidence and retaining repository-required reviews. Add specialists only for a
   named uncovered risk or explicit request; record their focus and verdict. Complete
   closeout's bounded bot opportunity and final thread and review-body read
   before reporting a PR ready.
   Open the PR with a short body per COORDINATION.md's authority table (unless this
   prompt says to stop first). For an approved PR, report CI/threads/readiness at the
   exact head; for local or deliberately draft work, report only that status/blockers.

## Rules

- You own source/test implementation and CI-fix loops for this assignment. The
  coordinator assigns, starts authorized lanes, verifies reports and maintains state;
  launch/publication permission does not authorize source takeover or a shadow worker.
- Only edit your scope's files; report anything outside it instead of changing it.
- Resolve Git policy from project AGENTS.md, the COORDINATION.md repo row and repo rules;
  ask on conflict. A method grants no push authority. The shared workflow carries the
  no-policy Git fallback, LOCAL delivery, PR size/sequencing/body, replies, privacy and
  timeout rules; don't copy them here. Tests cover distinct invariants.

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
and remaining decisions. Confirm the approved outcome in the human's current workflow:
what the change gives the human and why existing mechanisms do not already cover it.
State infrastructure-only delivery and unverified outcomes plainly; no mandatory demo gate.
List bulky outputs: path, size, safe to delete when; say none or mark unknowns.
Before calling a PR ready, local HEAD, remote PR head, tested revision and CI revision
must all match. Include reusable review evidence
(base, head provenance, scope, content identity, profile identity, model and dispositions)
so the coordinator can check freshness, blockers and the delta without redoing review.
For a PR, include closeout's bot-opportunity evidence from its final report.
The user's "W<n> ready" means stopped and needing an action, not a completion verdict.
The coordinator reads the report and opens its reply with the next action and its owner.
For an owned local coordinator, an optional ready nudge follows the
[once-only pointer rules](messaging.md#optional-once-only-local-pointers); record its outcome
here, never in STATE.
Manual sessions are not automatically monitored. Escalate only genuinely new material
scope/data/security/product choices, shared/destructive operations or actions outside
authority. Exact public text/publication and production/provider approvals still apply.
Before closing or pausing for long, write `W<n>-HANDOFF.md` from the handoff template
in the same location as the lane's report, following the project's AGENTS.md
(e.g. `reports/W<n>-HANDOFF.md`); absent a rule, use the project folder.
A parked lane has a stop/resume line: all current resume conditions and who decides (a person, or none if automatic), first resume action and report path.
