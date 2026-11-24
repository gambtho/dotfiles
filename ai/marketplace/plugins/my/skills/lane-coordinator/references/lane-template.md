# Goal
<one single line describing the approved user outcome or infrastructure-only delivery>.

# W<n> — <repo>: <short title>

You are an implementation lane in `<owner/repo>` (checkout `<path>`; a new worktree per
PR from a freshly fetched `origin/<base>`). Read the project's AGENTS.md, its shared
workflow at `<resolved project path>/lanes/COMMON-RULES.md`, the repo's own AGENTS.md
and contribution guide, and any effort rules named below; follow them. Use the shared
workflow's prompt-hash and addressed-note checkpoints before acting and reporting ready.
Coordinator: verify the shared workflow is readable on the recipient host.
Publication follows COORDINATION.md; otherwise draft exact text. Name publication holds.

Host: <chosen host>: <brief reason matched against Hosts `Use for`; local if no row matches>.
A host/project whose `Worker` is `lane` is started and steered through developerlanes with
the selected inputs ([hosts and lane workers](remote-lanes.md)); a host without `lane` keeps
the frozen Herdr/manual handoff, notes and bindings in the
[legacy reference](legacy-herdr.md#handoff-line-and-session-names). Coordinator: record
host/worker/reason in STATE's `What / report` cell. Remote lanes need verified
hostname/user, host alias, roots and how the report returns; put the guard first.

## Session identity (private)

On a lane worker, `lane` names the task. On a Herdr-only host, the new workspace label,
agent name and live Herdr alias are `<project-slug>-<lane-number>`
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

Review tools and `pr-text` ship together. Outside Pi, read `<resolved harness-notes path>`
and `<resolved skills dir>/<name>/SKILL.md`; coordinator resolves bundled paths before delivery.
Cross-family subscription review: `<resolved scripts dir>/codex-review.sh` (Claude Code)
or `claude-review.sh` (Codex); requirements unchanged.

1. <Audit/design inputs and report path.> New product: shared design-before-plan,
   independent design review, human approval, paired plan review. Audit-only: report
   and stop for approval. Estimate size/split: internal ~1k hand-written product lines;
   flag tests above ~1.5× product; external ~1k changed lines in total. Use COORDINATION.md's
   internal list; otherwise treat as external. The project's own rule wins.
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
   Open a short-body PR per COORDINATION.md unless held. Report exact-head CI/threads/
   readiness for approved PRs; LOCAL/draft work reports only its status/blockers.

## Rules

- You own source/test implementation and CI-fix loops for this assignment. The
  coordinator assigns, starts authorized lanes, verifies reports and maintains state;
  launch/publication permission does not authorize source takeover or a shadow worker.
- Standing authority: <in-scope repairs; exact publication/sandbox approval grant>.
  Stop for guarantee weakening, uncovered product decisions, publication beyond grant
  and stricter project stops; this avoids routine approval relays.
- Budget: <elapsed minutes>; on expiry stop new work and report pending work/resume
  conditions, not ready, to prevent endless closeout. Report out-of-scope work.
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

Return one consolidated report at `<local report path>` or ONE batched real blocker.
Top summary (at most ten lines): PR/head/CI, ready or blocked, next action/owner, unverified
risk. Below: delivery mode (LOCAL/PR), base/worktree/branch, changed paths, exact checks,
results/limits and decisions. Confirm the human's current workflow: what the change gives the human
and why existing mechanisms do not already cover it. Mark infrastructure-only/unverified
outcomes; no mandatory demo gate.
List bulky outputs: path, size, safe to delete when; say none or mark unknowns.
Ready requires local HEAD = remote PR head = tested revision = CI revision. Include
reusable review evidence (base, head provenance, scope, content/profile identities,
model, dispositions) and closeout's bot-opportunity evidence.
"W<n> ready" requests an action, not a completion verdict; coordinator replies action/owner first.
Mark each claim about another lane, host, person or project **observed** (command or
source) or **inferred**; re-observe an inferred claim before calling it a blocker.
A task started by `lane` with a PR also writes the evidence file the shared workflow
describes, next to this report, so `lane status` shows its readiness checks.
Herdr-only hosts: optional ready nudge by the [legacy pointers](legacy-herdr.md#optional-once-only-local-pointers);
record here, never STATE. Manual sessions are not monitored.
Escalate new material choices, shared/destructive operations or actions outside authority;
public/production/provider approval limits remain.
Before closing/long pause, write `W<n>-HANDOFF.md` in the same location as the lane's report
(e.g. `reports/W<n>-HANDOFF.md`), per project AGENTS.md; otherwise use the project folder.
Parked stop/resume line: all current resume conditions and who decides (a person, or none if automatic), first action, report.
