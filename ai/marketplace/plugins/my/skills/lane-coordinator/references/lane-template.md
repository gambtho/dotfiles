# Goal
<O<n>: the outcome this moves, in one line> | <Maintenance: what changes, in one line>.

# Scope
W<n> — `<owner/repo>`: <short title>. Own worktree from a freshly fetched `origin/<base>`.
Read the project's AGENTS.md, `<resolved project path>/lanes/COMMON-RULES.md`, the repo's
AGENTS.md and contribution guide, and any effort rules; use the shared workflow's
prompt-hash and addressed-note checkpoints. Publication follows COORDINATION.md; otherwise
draft exact text.
Host: <chosen host>: <reason matched against Hosts `Use for`; local if no row matches>.
A host whose `Worker` is `lane` is started and steered through developerlanes; a host without `lane` keeps
the frozen handoff, notes and session names in the [legacy reference](legacy-herdr.md#handoff-line-and-session-names).
Context: <why, in a few lines; issue/PR links; what other lanes own and which PRs to stay off>.
In: <what the human will see or do in the human's current workflow, or infrastructure-only>.
Out: <explicit exclusions>.
Standing authority: <in-scope repairs; exact publication and sandbox grant>. Stop for
guarantee weakening, uncovered product decisions, publication beyond the grant and
<stricter project stops>. Budget: <elapsed minutes>; on expiry stop new work and report
pending work and resume conditions, not ready.
Review tools and `pr-text` ship together; outside Pi read `<resolved harness-notes path>` and
`<resolved skills dir>/<name>/SKILL.md`. Cross-family review: `<resolved scripts dir>/codex-review.sh`
(Claude Code) or `claude-review.sh` (Codex).
Steps: <audit/design inputs or approved plan and Task IDs>; the repo's checks <exact commands>;
`pr-closeout` for the one review phase (specialists only for a named uncovered risk or
explicit request). Complete closeout's bounded bot opportunity before reporting a PR ready.
Resolve Git policy from project AGENTS.md, the COORDINATION.md repo row and repo rules; ask
on conflict. A method grants no push authority; the shared workflow carries the no-policy Git fallback.

# Done when
Product (pick one variant, delete the other):
- Outcome: <who> can <do what> on <which setup>.
- Tried by: <this lane, how> | <coordinator or the human after merge, how, on which machine>.
- The PR is a means, not the done line: one green PR at `pr-closeout`'s readiness.
Maintenance (no user outcome): one green PR. The report claims no outcome.
LOCAL or publication-held work: local checks pass; report status and blockers, not a PR gate.

# Report
One report at `<local report path>`, or ONE batched real blocker. A summary of at most ten
lines opens it: first the try result (`works` / `doesn't` / `not tried (why)`, or
`maintenance`), then PR, head, CI at that head, ready or blocked, next action and owner,
unverified risk. Below: base,
worktree, changed paths, exact checks, what the change gives the human and why existing
mechanisms do not already cover it (or infrastructure-only), unverified outcomes, and
closeout's bot-opportunity evidence. Mark each claim about another lane, host, person or
project **observed** (command or source) or **inferred**. A task started by `lane` with a PR
writes the evidence file the shared workflow describes, so `lane status` shows its readiness checks;
a Herdr-only host may send a ready nudge by the [legacy pointers](legacy-herdr.md#optional-once-only-local-pointers).
End with **Notes for later**, one line each, marking any that block the current try
(product, docs or our skill); the coordinator files them by the skill's Notes for later rule.
List bulky outputs: path, size, safe to delete when; say none or mark unknowns.
Before closing or a long pause, write `W<n>-HANDOFF.md` from the handoff template
in the same location as the lane's report (e.g. `reports/W<n>-HANDOFF.md`).
Parked stop/resume line: all current resume conditions and who decides (a person, or none
if automatic), first action, report.

<!-- Coordinator checklist before handoff; delete from the delivered prompt.
- Goal cites an outcome or says Maintenance; off-goal work was stopped and asked about.
- Prompt agrees with project AGENTS.md, COMMON-RULES and repo rules on worktree,
  publication authority and stop conditions; contradictions fixed first.
- Standing authority names allowed paths and actions, never blanket approval; stricter
  project stops, WIP limits and end-to-end PR ownership kept.
- Every bundled path resolved and readable on the recipient host; remote inputs delivered.
- A decision brief was converted once into the canonical executable plan (Task IDs, owned
  files) before implementation.
- A lighter process only where the project approved it; checks, reviews, checkpoints
  and publication limits still apply.
- Host, worker and reason recorded in STATE's `What / report` cell. -->
