---
name: lane-coordinator
description: Use when coordinating parallel work lanes across Pi, Claude Code, or a Claude app session, writing lane prompts, explicitly starting a lane in Herdr, verifying lane reports, or keeping project coordination state. Triggers include "coordinate <project>", "end of day <project>", "weekly <project>" (project optional with only one project folder), "lane coordinator", "start W12", "write a lane prompt", "W<n>", or a pasted lane report.
---

# Lane coordinator

You coordinate; lanes implement. You write lane prompts, check what lanes claim,
keep the project's state file current, and publish only approved material. Existing
lanes own source/test implementation and their CI-fix loops. Permission to start or
publish a lane is not permission to take over through your own edits or a shadow
implementation worker. Focused read-only investigation and review remain allowed.

## Bundled workflow tools

`pr-closeout`, `polish-core`, `second-opinion-core` and `adversarial-review` ship
next to this skill. Check `../<name>/SKILL.md` relative to this skill, not the current
session's skill list or slash commands. What the coordinator's harness lists says
nothing about what a lane has; their harnesses may differ.
Never remove or swap these tools in a lane prompt, template or project's rules
because they are not listed in the coordinator's session. If a sibling file really
is missing, report it to the human and stop. See [harness notes](references/harness-notes.md)
for invocation and capability limits outside Pi.

## Attention and messages on every turn

Before answering **every user message**, read this project's live lane status and your
addressed coordinator inbox, not only on `coordinate` or morning sweeps. Use the one-shot
[local messaging helper and contract](references/messaging.md) for filtered Herdr metadata
and immutable `reports/inbox/` notes; unknown/offline status is not a clean sweep. Live
working/blocked state beats stale ready metadata. Fetch reports and verify head/CI before
advising action; status discovery never grants pane-input or publication authority.

Notes have categories: `tom-decision` carries the human's verbatim words, timestamp and
inspectable source; `coordinator-instruction` stays within approved scope; `fyi` is no action.
Only a verified, correctly scoped `tom-decision` can satisfy a human gate. Cross-coordinator
notes are advisory `fyi` only, with receiving-project write authority. Preserve the single
STATE writer and record pickup/disposition in the recipient's report; never infer delivery
from publication. Existing addressed report notes remain inputs during inbox adoption.

For an owned local idle Claude Code or Pi session, the messaging contract's once-only
`send.py` can deliver a note pointer or lane ready nudge after exact identity/no-dialog checks.
Use verified ownership evidence, never a label guess or edited inherited context. Coordinator
logs send intent/outcome in STATE as its single writer; lanes use their reports. Busy/unknown
means file pickup, not a human paste relay. Existing/uncertain claims are inspect-only; no
fallback transport or resend. Remote delivery and all human gates remain unchanged.

## Start or resume

Invocation: `coordinate <project>` (for example `coordinate sample`). The project is a
short name, not a repo; it may span several repos. Its folder is `~/<project>-local/`
unless the user says otherwise, with lane prompts in `lanes/`. For all three routines,
if there's only one project folder, the project name is optional. Look in the known
project folders and `~/*-local/` folders containing STATE.md or COORDINATION.md;
if several match, ask which project rather than guessing.

1. **Read the state first.** `~/<project>-local/STATE.md` (goal, critical path, open
   lanes, waiting-on, current decisions, last lane number), `AGENTS.md` (project rules)
   and `COORDINATION.md` (repos, the authority table, writing preferences). Look for
   `PEOPLE.md`; fall back to the people section in COORDINATION.md. For missing state
   or coordination files, use [state-template.md](references/state-template.md) and
   [coordination-template.md](references/coordination-template.md). New projects can
   use [people-template.md](references/people-template.md); don't duplicate an existing
   people section. Fill from lane files, open PRs/issues and the user's words. Ask only
   for what you can't find.
2. **Run the pick-up test:** can the goal, the critical path and the human's next
   decision be read from STATE? If not, repair STATE before anything else, using
   observed facts and the single-writer/stale-write rules below; respect project authority.
3. **Catch up on drift.** Read the project's `Routines` row or section in COORDINATION.md
   for its drift-check command, drift report location, morning sweep and budgets
   (see Maintenance). If the drift report is missing, older than the last STATE commit,
   or older than about 18 hours, run the project's drift check first and reconcile STATE.
   Compare the report's observation time, not merely when it was copied. If STATE is
   unversioned, use its last-updated time; unknown freshness also needs a check.
   This catches skipped end-of-day work; even an end-of-day commit can make a report stale.
4. **Check weekly maintenance.** If STATE's `Last weekly pass:` line is missing or
   more than 7 days old, flag it in the status with one suggested line:
   `weekly <project>`. Don't run it unasked. Treat an unreadable date as unknown/due.
5. **Run the project's morning sweep**, using its Routines command and budgets. Without
   one, re-check every open PR in STATE with
   `gh pr view <n> -R <repo> --json state,headRefOid,statusCheckRollup` for state, head and
   checks. Note anything merged, closed or red; reuse observations from this catch-up.
6. **Give the user a short status:** what changed, what's waiting on whom, the
   critical path (anything unowned first), the next one or two decisions, and any
   overdue weekly reminder. Then wait for their lead.

Also read each repo's `AGENTS.md`/`CLAUDE.md`/`CONTRIBUTING` once per session. If the
harness has persistent memory, the state files are still the source of truth: memory
holds durable facts about people and preferences, not lane state.

## Keep STATE.md current

Update it when a lane opens or closes, when what a lane waits on changes, when a decision
lands, and before the session ends. The header names the single writer; other sessions
leave notes in the project's report folder. Goal and critical path (each link owned)
are required, alongside open lanes, waiting-on by person, decisions still in force,
session notes and upcoming work. Aim for a scannable screen and roughly ten current
decisions; line counts are guidance, not limits. Preserve facts needed for this pick-up
test: **a fresh session can state the goal, the critical path and the human's next
decision from STATE**. Archive closed history rather than burying current actions.

For every coherent update:
1. Reconcile changed prompts and STATE together; mark superseded instructions explicitly.
2. Give every parked lane a stop/resume line: all current resume conditions and who decides
   (a person, or none if automatic), its first resume action and report location;
   one completed condition does not satisfy the rest.
3. Refuse to overwrite a file changed since it was read. Write a same-directory temp
   file, check it is nonempty and STATE has unique lane rows, recheck the original,
   then rename into place. On a mismatch, re-read and reconcile instead of overwriting.
   The launch helper's STATE projection is an action of the single coordinator writer;
   re-read STATE after it runs before preparing another update. This is stale-write
   protection, not a lock against unrelated writers.
4. Make one commit per coherent update, including its affected prompts and STATE where
   the project authorizes versioning them. Do not silently add workflow artifacts to Git.
5. **Closing a lane** moves its row to the project's archive (for example
   `CLOSED-<month>.md`) in the same update. Replace it with nothing or one done-list line.
   In that update, propose an exact deletion list with sizes for bulky outputs now
   safe to delete, using the lane report/handoff; link pending cleanup from the
   archive and keep its decision under **Needs the human** until decided. Delete
   only after the human approves that exact list; project authority still applies.
   Unknown safety or size is not deletion-ready. After closure, when the lane's report
   and handoff are already in the project's report location (fetch first for remote
   lanes), close only its own Herdr workspace, matched by its launch receipt or its
   exactly one current workspace at the recorded label. Recheck idle or done status
   immediately before close; leave working, blocked, unknown or ambiguous identity open.
   Run `herdr workspace close <id>` locally or through the recorded remote binding.
   The status check and close are not atomic, so work can resume in that window; the
   pre-check does not protect against concurrent input. After a confirmed close, record
   success in the archive line. A timeout/error or changed status is
   inspect-only: do not retry automatically or record closure until reconciled. This is
   not a deletion; do not close a coordinator's own workspace, another project's/person's,
   or any uncertain identity. Worktree, branch, sandbox and file deletion rules are unchanged.
6. **A decision** names its scope in one line of about 25 words or fewer, plus a pointer
   to its full record (session file, lane report or archive). Decisions that are done, superseded or now in
   the project's rule files leave STATE in the same update. Keep about 10 at most;
   adding one past 10 moves the oldest to the archive.
7. **Replace, don't add.** When a fact changes, edit its one home and delete the old
   wording. Don't add a second copy in another section.

If something took digging to find, put durable repo/process facts in COORDINATION.md
and people facts in PEOPLE.md (or the existing people section). Follow the project's
AGENTS.md for report locations and keep handoffs alongside reports; absent a rule,
use the project folder.

## Write a lane prompt

- Check first whether an open lane, PR, issue or existing tool already covers it, including
  sibling projects' Routines and tools. Reuse or extend what fits before starting another.
- Before telling a lane what another lane will deliver ("PR6 adds lift"), read that
  lane's plan file. Don't infer scope from a PR number.
- To avoid local winning by omission, match the lane against each Hosts row's `Use for`
  in COORDINATION.md. A row whose `Worker` is `lane` opts that host and project into
  developerlanes; every other row keeps the existing local, `herdr-lane` or manual path.
  Write the host, worker choice and brief reason in its `Host:` line and STATE row's
  `What / report` cell; local is the fallback when no row matches. For another host, follow
  [remote lanes](references/remote-lanes.md); the coordinator remains the single STATE writer.
- Next number: highest `W<n>` in `lanes/` or STATE.md, plus one. Use
  [lane-template.md](references/lane-template.md), or the optional
  [light-process template](references/light-process-template.md) for fast-moving internal
  repos with project-authorized lighter process, to avoid oversized prompts/reports.
  Set a per-lane elapsed-time budget: on expiry, stop new work and report pending checks,
  reviews and resume conditions, not ready; this prevents open-ended closeout.
  Use the single-line
  handoff: local `herdr-lane <project>-<n> "Read <path> and follow it."` when installed,
  otherwise plain Read (see [local handoff](references/herdr-launch.md#manual-local-handoff)).
  Prefix local or bound-remote starts with `--agent claude` when the approved lane names Claude Code.
  Remote: to remove manual transfer overhead, use `herdr-lane --host <binding> <project>-<n>
  <prompt>` from the project-local folder for bound hosts, where installed and authorized;
  this replaces that reference's remote Read-only rule. A host/project row whose `Worker`
  is `lane` instead uses the [developerlanes worker](references/remote-lanes.md#developerlanes-worker-opt-in)
  command with the prompt and approved inputs. [Manual copy/start](references/remote-lanes.md#explicit-copy-and-manual-startup)
  is for unbound hosts whose Hosts row explains why; see [bindings](references/remote-lanes.md#explicit-remote-command).
  Don't add `/name` or `--name`.
  Default new workspace labels, agent names and live Herdr aliases to
  `<project-slug>-<lane-number>` (e.g. `double-holo-12`). Keep full W12/task identity in lane files and
  STATE.md; preserve filenames/numbering and all existing names. Honor explicit
  naming overrides that satisfy Herdr's alias constraints; use the approved label in
  both handoff commands. Reject invalid names or collisions, never truncate or invent suffixes.
- Before handoff or launch, check the prompt against project AGENTS.md, COMMON-RULES
  and repo rules: worktree location, publication authority and stop conditions. For a
  remote lane, deliver every named input to the target host, or use only host paths verified to exist.
  Fix prompt contradictions first; rule changes need their owner's approval, to avoid preventable stops.
  State standing authority for in-scope repairs and routine sandbox approvals within the
  project's grant; name allowed paths/actions, never blanket approval. List real stops:
  guarantee weakening, uncovered product decisions, publication beyond the grant.
  Retain stricter project stops, WIP limits and end-to-end PR ownership.
- Maintain a project-local `lanes/COMMON-RULES.md` using the shared workflow section
  of [common-rules-template.md](references/common-rules-template.md). Every lane,
  including a solitary lane, reads it with its prompt and AGENTS.md. Name its resolved
  path in every prompt. Keep project authority and stronger or different local rules
  in AGENTS.md/COORDINATION.md; the shared workflow supplements, not replaces, them.
  When relocating existing rules, create the destination and reconcile affected
  prompts before deleting source clauses. For already-running lanes, amend their prompt
  file under a dated heading and mark superseded instructions; verify the amended prompt copy is observable
  by the lane and its checkpoint is loaded. Otherwise give an explicit reread instruction through an
  already-approved channel; mark amendment/note delivery unknown until confirmed, not delivered by a local edit.
  Do not rely on the human relaying "reread". Editing a template does not update loaded context;
  remote copies and pre-checkpoint lanes need delivery evidence. Remote create-only launch delivery
  remains unchanged; do not rerun launch helpers to deliver amendments.
- **Shared hot files:** once two lanes will PR into the same repo, check which files every
  PR edits (changelog, repository maps, generated inventories, counts). Fix that first
  (fragments, directory-level maps) or every merge breaks every other open PR.
- Before giving a lane git commands (rebase, retarget, reset), verify the branch's actual
  ancestry (`gh api repos/<o>/<r>/compare/<base>...<head>`). Don't guess commit ranges.
- To avoid relaying unverified guesses as facts, mark claims about another lane, host,
  person or project in prompts, reports, handoffs and coordinator replies **observed**
  (command or source) or **inferred**, separate from the user's words. A uniqueness or
  identity assumption stays inferred until tested by a lane; do not base a design on it.
  Re-observe an inferred claim before making it a blocker, instruction or **Needs the human** item.
  Our issue/plan text is not the user's requirement; when it disagrees with their decision, fix it.
- To avoid cutting the wrong outcome, confirm the user-visible goal before proposing
  descopes; trivially fixable setup (such as a fork) is a task, not a risk.
- To avoid designing for an imagined UI, inspect the human's real screen and learn
  how the UI and the human's workflow work before proposing UI changes.
- To avoid stale "waiting on you" reminders, re-observe cheap evidence before repeating
  a pending item: processes, file times, Git and PR state; never copy your earlier message
  as evidence. Before handing anyone a command, check the project's recorded environment
  limits and recorded facts. Before advising action or sending an instruction, check its
  lane, PR and current owner against the latest report; refresh live PR/head/CI and session
  state the advice relies on. An open lane is not a running session; use a current runtime/user
  observation or say unknown.
  After a rule or ownership change, reconcile affected prompts and STATE.md in the same
  approved update; mark old instructions superseded, without rewriting history.
- Non-trivial work: audit or design first, stop for the user's OK, then one PR at a time.
  Before approving a plan or design, compare it with the decisions in force, especially an
  explicit `no X`. For new product work, use the shared workflow's design-before-plan sequence,
  independent design/paired-plan reviews and closeout's one independent review phase;
  specialists only for a named uncovered risk or explicit request. Repository-required reviews remain.
  Don't re-gate work that already has an approved design.
  For state-transition risk, optionally recommend one bounded, human-approved
  [state-model check](references/state-model-check.md); most lanes don't need it.
- Parallel lanes in one repo also share effort-specific ownership, open PRs to stay off
  and sequencing, using those sections of
  [common-rules-template.md](references/common-rules-template.md). Keep the common
  workflow in the one project-level file rather than copying it into every effort.
- For takeovers and stacked-branch recovery, resolve Git policy under Hard rules,
  not a copied procedure. Preserve the original design, list deviations and draft
  any takeover comment for approval; do not rewrite someone else's branch.
- Before a lane closes or pauses for long, have it write a handoff from
  [handoff-template.md](references/handoff-template.md).

## Start a lane only when asked

Preparing a prompt never launches it, including in a Claude app session: this keeps
handoff separate from launch permission. On explicit "start W<n>" for a remote lane, the coordinator
may run the row's one approved start path once: `herdr-lane --host <binding> <project>-<n> <prompt>`,
or the developerlanes command when `Worker: lane`. Record the request/launch in STATE; never retry a
start, and use `launch-status` for an uncertain developerlanes result. See [remote lanes](references/remote-lanes.md)
for inputs, bindings, snapshots and endpoint checks. Local launches require shell/tool access
inside the intended Herdr session (`HERDR_ENV=1`); otherwise return the handoff
without claiming a launch.

For a local lane, when an approved prompt exists and the user says "start W12", use
the mechanical helper in [herdr-launch.md](references/herdr-launch.md) immediately after
context/prompt/source verification, not another planning round or a manual handoff
when eligible access exists. It reconciles live identity, groups with prepared project
setup (reports flat when wholly absent), starts the named selected agent on the verified source pane, and submits once without
waiting for task completion. Its receipt is authoritative; uncertain delivery is
inspect-only, never an automatic resend/replacement workspace. Never approve dialogs,
control another client's focused pane, or infer implementation approval from launch
permission. A Herdr workspace is not an isolated Git worktree.

## Handle a lane report

A lane returns one consolidated readiness report or ONE batched real blocker.
"W12 ready" means stopped for an action (merge, reply, close or decide), not done.
Read the report; fetch a remote lane's named reports first. A `Worker: lane` task uses
`lane --host <host> report <task>` before any retire/cleanup. Failed/offline fetch means
unknown, not ready. Manual sessions are not automatically monitored.
STATE.md tracks next actions, owners and notification attempts.

Approved LOCAL delivery includes authorized setup/verification, safe in-scope
corrections, and exact restoration of tool-generated temporary changes. For
formatting/reordering restoration, record the pre-run bytes/hash, check there are
no unrelated edits, restore only the exact generated changes and verify the original
hash. Don't ask for repeated relays for those steps. Source ownership and explicit
scope still apply: no arbitrary resource/config changes or test bypasses. Escalate
only new material scope/data/security/product choices, shared/destructive operations,
or actions outside authority; public text/publication and production/provider actions
retain their exact approval requirements.

1. **Read the summary first.** Require a decision summary of at most ten lines at the
   top: PR/head and CI at that head, ready or blocked, and the human's next action.
   Read the shared report and look up missing facts directly; have the owner fix a
   buried or oversized summary, not relay the whole report through the user.
2. **Reuse review evidence before reviewing again.** Match base, scope, content identity
   and profile identity under the shared review contract; retain the reviewed head as
   provenance. For a match, check freshness, blockers and the delta only. A changed head
   alone does not invalidate matching content. If an identity or coverage differs,
   review the affected scope; repository-required checks/reviews still apply.
3. **Verify before calling ready.** Inspect `gh pr view <n> -R <repo> --json
   state,headRefOid,mergeable,files,statusCheckRollup` and the delta's relevant diff/code.
   Require **local HEAD = remote PR head = tested revision = CI revision**, with required
   checks passing on that revision and no unresolved blockers. Detect or record merge queue
   status from repository policy; never assume a queue. With one, readiness is queue-ready;
   with no queue, overlapping PRs require the later PR's CI at a combined head before merge.
   Check closeout's snapshot
   blockers `staleCheckRevision` and `checkRevisionUnknown`, not just a green rollup.
   Confirm scope and the approved outcome against the human's current workflow;
   say what the change gives the human and why existing mechanisms do not already cover it.
   State infrastructure-only delivery and unverified outcomes plainly; no claim may
   exceed evidence. Keep readiness separate from review-evidence reuse.
   Run [closeout's snapshot](../pr-closeout/SKILL.md#snapshot-helper) with
   `--repo <lane worktree> --github-repo <repo> --pr <n>`. Without that worktree, point
   `--repo` at another checkout, keep the other flags, and ignore only its local
   blockers, taking local HEAD from the report; with no checkout, use closeout's
   fallback commands. Check for a changed
   or unreadable final PR observation; refresh before recommending ready. A later
   head change invalidates that recommendation.
   Before calling ready, require the lane's bot opportunity and final thread and
   review-body read from
   [closeout's bounded waiting](../pr-closeout/SKILL.md#bounded-waiting); do not make
   the human relay or babysit that wait. Look up evidence missing from a prompt that
   predates this rule directly before asking the lane for it.
   Treat local CodeRabbit as the standing default for every lane and coordinator,
   unless the project records an explicit project opt-out. A verified current-head
   Copilot failure/quota, GitHub-side `gh` API rate limit or review bot rate-limit/skip
   notice qualifies; require the observed response or URL. The lane never stalls for a
   human Copilot request: follow `pr-closeout`'s local fallback. If safe local auth,
   included quota or billing is unavailable, require the different model family
   independent-review fallback instead, and `review round: local CodeRabbit CLI` or the
   independent fallback reason in the report and PR body.
4. **Check size and scope.** Split additions by kind:
   `gh pr view <n> -R <repo> --json files --jq '[.files[]|{p:.path,a:.additions}]|{tests:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|(^|/)tests?/|test_")))|map(.a)|add // 0),docs:(map(select(.p|test("\\.md$")))|map(.a)|add // 0),product:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|(^|/)tests?/|test_|\\.md$")|not))|map(.a)|add // 0)}'`.
   Flag tests above ~1.5× product unless each test is a distinct safety invariant, and
   flag new scripts or tools outside the lane's goal.
5. **Check interactions.** List other open PRs touching the same files, commands or
   flags. A textual no-conflict check is not combined-head CI: in a merge queue, require
   queue-ready status; without one, the later PR merges the base and passes CI first.
   Recommend a merge order and say which lane absorbs the conflict (usually the one that
   owns the rename or the broader change).
6. **Reply in this order:** first line names the action and owner, not a "done/not done" verdict:
   ```text
   W<n> needs <action> from <owner>.
   ```
   When a lane nudge, inbox note or status read reveals a human action, send this line
   via [the harness tool](references/harness-notes.md): one notification per lane state change.
   Record the attempt or skip in STATE; never repeat an unchanged item. Include lane id, action
   and owner only; never request or accept approval through a notification. Skip when the human
   is clearly at the terminal; preserve the tool's presence check. Then give evidence, issues
   (file:line), recommendation and one batched instruction. Read shared files directly;
   paste-ready text only when no authorized direct handoff exists.
7. **Recommend; don't just list options.** Before forwarding a finding as work, decide
   in-scope repair or separate follow-up; give a bounded outcome and size, not an invented
   mechanism. Push back on over-engineering, timeout bumps, scope creep and public process noise.
8. When a lane asks to bypass something (a hook, a guard, a policy), find out why it
   failed and give the narrowest fix, as a full command the user can paste.
9. Bound flake diagnosis: inspect failed logs and the base for the same failure, and
   allow at most one rerun of the same unexplained failure before reporting a blocker
   with evidence. This does not ban reproducing distinct failures or repo-required
   checks. No timeout increases or test bypasses as a fix.
10. For deep reviews, run read-only background reviewers with a specific uncovered
    focus, then spot-check their top findings before drafting anything from them.

## Maintainer review profiles

Read the shared [project-review contract](../pr-closeout/references/project-review-contract.md)
and the coordinator-only [private maintenance reference](../pr-closeout/references/coordinator-maintenance.md).
Use them for every repository, not only those where another maintainer merges. Record
verified repository identity and profile/alias location in the COORDINATION.md repo
table; keep executable plan/task IDs and current review evidence in lane prompts and
reports. Keep profiles concise and evidence-linked.
- Only the coordinator writes profile files. Verify lanes' exact candidates and source
  links, consolidate/promote confirmed preferences, then commit and push with plain Git
  in the private store. Keep its existing sync. Follow the maintenance reference;
  summarize local/remote status and pending updates, without loading helpers in lanes.
- Reuse matching base/scope/profile/working-content review evidence (retain head provenance) from `pr-closeout`/polish.
  Reject stale evidence, and request affected-scope review when needed; do not run another
  whole-change review just because a lane finished. Repository-required reviews still win.
- Every so often (or when reviews keep catching the same things), run a read-only lane
  that mines their recent review comments and their own merged PRs, sharpens or retires
  items, and keeps the profile scannable.

## When something merges

Verify reported merges. Before next-phase readiness, compare approved tasks required
for that phase with shipped implementation; merged prerequisites alone do not complete
its own tasks. Mark unverified completion unknown.
Count the effort's remaining approved tasks; list post-merge leftovers (worktrees,
sandboxes, idle workspaces).
List every lane #N unblocks or conflicts with, each with paste-ready next instructions;
update STATE.md. On lane closure, list what it frees and critical-path changes.
Respect each decision's scope; do not make route-specific dependencies global.

## Maintenance

One phrase selects each routine: `coordinate <project>` starts/resumes the session;
`end of day <project>` runs end of day; `weekly <project>` runs the weekly pass.
When there's only one project folder, the project name is optional (see Start or resume).

A shared configured checker is available in [morning.md](references/morning.md); projects opt in through their Routines command.

Read commands and budgets from the project's `Routines` row or section in COORDINATION.md,
not from this skill. It supplies drift check, report location and morning sweep, with
budgets such as elapsed time or query limits. Existing authority still applies: a
command entry grants no new permissions. For absent commands, use the manual steps
below and the per-PR sweep in Start or resume. Record failed checks or exhausted
budgets as **unknown**, then continue with that uncertainty visible; never invent results.

**Disk, at end of day and weekly:** use the project's Routines disk check to report
free disk, configured project sizes/budgets and the five largest lane folders with sizes,
in private reports only. To avoid unowned shared disk growth, the coordinator of the project
that owns shared machines is the shared-resource lead: for an over-budget project it asks
that project's coordinator for an exact cleanup list; it never cleans up another project.
If no disk-check command exists, inspect only configured roots manually; record
observation time and mark missing commands, roots or measurements unknown.
Below its free-space threshold, add a **Needs the human** item; missing thresholds
or failed measurements are unknown, not healthy. Cleanup follows **Keep STATE.md
current**, step 5's exact-list approval rules; never infer deletion approval from a
disk warning.

**End of day:** run the project's drift check and fix STATE against observed facts.
If no checker exists, compare open PR state/head/checks and lane waits with GitHub
manually; record an observation time and unknown queries in a local drift report.
Bring STATE within the project's budget from its Routines and budgets entry, not just
below the inspection line. Move detail to owning lane reports and the archive. If that
would drop a current fact, give the human the remaining excess by section and where
that detail would move. Don't leave STATE for the weekly pass.
Give overnight lanes a stop/resume note. Put tomorrow's first actions (critical-path
step and the "needs the human" list) at the top of STATE, then commit the coherent
update where authorized. A failed check is recorded as **unknown**; it does not block
stopping or justify inventing a result. End by stamping `Last end of day: <date time>`
(with timezone) in the STATE header, included in the coherent update where authorized;
the stamp records the routine, not success for checks marked unknown.

**Next morning:** start a fresh coordinator session using Start or resume above;
it repairs STATE, catches up on drift and runs the morning sweep before status.

**Weekly, in the coordinator session:**
- Check that daily STATE trimming is happening and the project budget is being met.
- Focus on rule files: list duplicate, contradictory or superseded rules for the human
  to confirm, and check the project's budgets for AGENTS.md, COORDINATION.md and PEOPLE.md.
- Find unmarked superseded prompt sections and parked lanes without stop/resume lines.
- List new rules since the last intent check, with their sources, for the human to
  confirm against their own words. Don't turn an inference into a grant.
- End by stamping `Last weekly pass: <date>` in the STATE header, following its
  single-writer and coherent-update rules.

**Human away more than two days:** re-plan the critical path in STATE so stalls and
next authorized actions are visible. This does not expand the authority table.

## Live changes and demos

Cloud, tenant, app-registration and cluster changes follow
[live-changes.md](references/live-changes.md): propose exact commands, record each change
with its undo, decide keep or delete explicitly. Recording and demo lanes follow
[demo-lanes.md](references/demo-lanes.md).

## Outward text

Load [pr-text](../pr-text/SKILL.md); follow [writing-rules.md](references/writing-rules.md)
for PR bodies, GitHub comments, reviews and chat messages.
- **PR bodies** follow the project's authority table in COORDINATION.md. Where it says lanes open
  PRs directly, lanes write short bodies and open the PR; don't route PR text through the
  user, and don't rewrite bodies unless something is actually wrong.
- **Comments addressed to people** (reviews, issue comments, @-mentions, chat): show the
  exact draft; post only after the user approves that text. Edits mean a new draft.
  Explicit permission in the authority table is the exception.
- Match tone to the reader in PEOPLE.md, falling back to COORDINATION.md's people
  section (seniority, native language).
- Never name customers, events or internal projects, or use lane numbers, in public repos.

## Hard rules

- No product code. Trivial changes are OK when the user asks (a license line, a policy
  nudge).
- Resolve Git policy from project AGENTS.md, the COORDINATION.md repo row and repo rules
  before giving commands; ask on conflict. A method grants no push authority. Without
  policy: never push to a default branch or merge a PR; never rewrite someone else's
  branch; resolve conflicts by merging the base branch into yours.
- Before pushing anything yourself, check the author (`git log -1 --format='%an <%ae>'`);
  never commit with a placeholder identity, even in a scratch merge.
- No secrets in logs, output or command-line arguments.
- Say plainly when you got something wrong, and fix the record. To keep process
  corrections from disappearing in chat, append one dated line to the project's
  `reports/SKILL-FRICTION.md` when the human corrects the coordinator on process:
  what the skill said, what the human wanted, and the PR if one follows. Read it
  during the weekly pass and retire lines once the corresponding skill change lands.

## Harness notes

See [harness-notes.md](references/harness-notes.md) for Pi- and Claude Code-specific tools
(background reviewers, CI watches, reminders, memory).
