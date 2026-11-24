# Herdr-only hosts (legacy, frozen)

**For hosts that are not lane workers; no new changes.** This file holds every
Herdr-only path the coordinator skill used before `lane` workers: terminal snapshots, inbox
note files and `send.py`, the local Herdr launch helper, `herdr-lane` remote launch, rsync
report fetch and workspace close by label. It is kept only until the last project starts
its tasks through `lane`, and is then deleted with its scripts. A host whose Hosts row says
`Worker: lane` uses the bundled developerlanes coordinator skill instead
(see [the skill](../SKILL.md#lane-mechanics-read-the-bundled-coordinator)).

The sections below are the earlier text, moved here unchanged apart from links and
sentences about lane workers, which were removed.

## Attention and notes on every turn

Before answering **every user message**, read this project's live lane status and your
addressed coordinator inbox, not only on `coordinate` or morning sweeps. Use the one-shot
[local messaging helper and contract](#local-messages-and-attention) for filtered Herdr metadata
and immutable `reports/inbox/` notes. Unknown/offline status is not a clean sweep. Live
working/blocked state beats stale ready metadata. Fetch reports and verify head/CI before
advising action; status discovery never grants pane-input or publication authority.

Notes have categories: `tom-decision` carries the human's verbatim words, timestamp and
inspectable source; `coordinator-instruction` stays within approved scope; `fyi` is no action.
Only a verified, correctly scoped `tom-decision` can satisfy a human gate. Cross-coordinator
notes are advisory `fyi` only, with receiving-project write authority. Preserve the single
STATE writer and record pickup/disposition in the recipient's report; never infer delivery
from publication. Existing addressed report notes remain inputs during inbox adoption.

For an owned local idle Claude Code or Pi session on a Herdr-only host, the messaging contract's once-only
`send.py` can deliver a note pointer or lane ready nudge after exact identity/no-dialog checks.
Use verified ownership evidence, never a label guess or edited inherited context. Coordinator
logs send intent/outcome in STATE as its single writer; lanes use their reports. Busy/unknown
means file pickup, not a human paste relay. Existing/uncertain claims are inspect-only; no
fallback transport or resend. Remote delivery and all human gates remain unchanged.

## Handoff line and session names

Use the single-line
handoff: local `herdr-lane <project>-<n> "Read <path> and follow it."` when installed,
otherwise plain Read (see [local handoff](#manual-local-handoff)).
Prefix local or bound-remote starts with `--agent claude` when the approved lane names Claude Code.
Remote: to remove manual transfer overhead, use `herdr-lane --host <binding> <project>-<n>
<prompt>` from the project-local folder for bound hosts, where installed and authorized;
this replaces that reference's remote Read-only rule. [Manual copy/start](#explicit-copy-and-manual-startup)
is for unbound hosts whose Hosts row explains why; see [bindings](#explicit-remote-command).
Don't add `/name` or `--name`.
Default new workspace labels, agent names and live Herdr aliases to
`<project-slug>-<lane-number>` (e.g. `double-holo-12`). Keep full W12/task identity in lane files and
STATE.md; preserve filenames/numbering and all existing names. Honor explicit
naming overrides that satisfy Herdr's alias constraints; use the approved label in
both handoff commands. Reject invalid names or collisions, never truncate or invent suffixes.

## Start a lane on a Herdr host

Preparing a prompt never launches it, including in a Claude app session: this keeps
handoff separate from launch permission. On explicit "start W<n>" for a remote lane, the coordinator
may run the row's one approved start path once: `herdr-lane --host <binding> <project>-<n> <prompt>`.
Record the request/launch in STATE; never retry a start. See [remote lanes](#remote-lanes-on-herdr-hosts)
for inputs, bindings, snapshots and endpoint checks. Local launches require shell/tool access
inside the intended Herdr session (`HERDR_ENV=1`); otherwise return the handoff
without claiming a launch.

For a local lane, when an approved prompt exists and the user says "start W12", use
the mechanical helper in [herdr-launch.md](#explicit-herdr-lane-launch) immediately after
context/prompt/source verification, not another planning round or a manual handoff
when eligible access exists. It reconciles live identity, groups with prepared project
setup (reports flat when wholly absent), starts the named selected agent on the verified source pane, and submits once without
waiting for task completion. Its receipt is authoritative; uncertain delivery is
inspect-only, never an automatic resend/replacement workspace. Never approve dialogs,
control another client's focused pane, or infer implementation approval from launch
permission. A Herdr workspace is not an isolated Git worktree.

## Close a closed lane's workspace

After closure, when the lane's report
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

## Harness and launch choice

For explicit Herdr launches and manual conversation naming, follow
[herdr-launch.md](#explicit-herdr-lane-launch), including its deterministic helper when an
approved prompt already exists. New names default to `project-slug-number` across
workspace/agent/alias (e.g. `double-holo-12`); existing names remain untouched.
This depends on actual tools and the inherited
Herdr session, not whether the coordinator is Pi or Claude Code. Claude app
sessions without terminal tools use the manual handoff.
A local lane can run Claude Code instead of Pi with
`herdr-lane --agent claude <project>-<n> "Read <path> and follow it."`. A bound
remote lane uses `herdr-lane --host <binding> --agent claude`; both require the
project-local Claude settings file. See [Claude Code lanes](#claude-code-lanes).

## Explicit Herdr lane launch

Preparing a prompt does not launch it. After an explicit request such as **"start
W12"**, with an approved prompt already present, verify context/prompt/source then
run the helper below. Do not re-plan approved work or substitute manual instructions
when eligible access exists. Without tools or eligible inherited context, give the
short manual handoff. Never guess sockets, arrange SSH, switch sessions or steal focus.
Other harnesses retain their manual fallback; this fast path supports Pi (default)
and Claude Code when `--agent claude` is explicit.

### Identity and preflight

- Read STATE.md and the approved lane file; confirm the intended source repository.
  The source cwd must exist. The lane must still isolate in a linked Git worktree
  before source writes: a Herdr workspace provides terminal layout, not Git isolation.
- Use the established project slug and numeric lane: `double-holo-12` for W12.
  This is the default for **all three** new workspace labels, agent names and live
  aliases. Full task descriptions and W12 identity stay in STATE.md/lane files;
  lane filenames/numbering do not change. Never rename an existing workspace,
  conversation, alias, public branch, commit or PR.
- Honor an explicit naming override with `--name`; the shared name must satisfy
  Herdr's alias constraint `[a-z][a-z0-9_-]{0,31}`. Reject invalid names, overlength
  names and ambiguous collisions. No silent truncation or random suffixes. A user
  override that cannot serve as an alias needs a valid user-selected name, not a guess.
- Confirm `HERDR_ENV=1` and inherited socket/caller pane/workspace exist. A present
  `HERDR_SESSION` must match the intended session. When it is absent, the helper
  accepts only a unique default from `herdr session list --json` whose `socket_path`
  exactly equals `HERDR_SOCKET_PATH`, which must be an absolute local socket.
  Supply that listed default's name to `--session`; it remains an assertion, **not**
  a session selector. An empty/mismatched session value or unverifiable default
  still means manual handoff. No session name or socket is guessed, injected or
  switched, and live caller identity is checked before any launch mutation.
- STATE.md needs the five-column Open lanes table from the state template, including
  exactly one row for the lane, with Launch initially `Manual` or `—`. Existing launch
  state or a receipt must be reconciled, not erased. Keep receipts in the same local,
  unversioned lanes directory as the prompt. Do not copy receipts between sessions.

### Execute once

Run [launch.py](../scripts/launch.py) through Python 3 (standard library, POSIX
Linux/macOS/WSL). Resolve the script relative to this skill; quote literal paths:

```bash
python3 <skill-dir>/scripts/launch.py --requested \
  --project double-holo --lane W12 --session '<verified session>' \
  --repo '/home/example/my repo' \
  --prompt '/home/example/double-holo-local/lanes/W12-approved-task.md' \
  --state '/home/example/double-holo-local/STATE.md'
# Add --agent claude for Claude Code.
```

Claude launches require a regular project-local
`lanes/claude-lane-settings.json` beside the prompt. The helper records the settings
path and digest, passes it through `--settings`, and stops before submission if the
file changes during startup. This adds to the user's Claude settings; it does not
replace them or approve a trust/theme dialog.

`--requested` attests to the actual user launch request; it does not grant scope,
publication or provider/production authority. Do not add it for "prepare W12".
The helper uses argv subprocess calls, not executable shell text or `eval`.
It creates agent workspaces with `--env DOTFILES_KEYRING_PROMPT=0`, before the
root shell starts, so locked-keyring password input cannot consume the agent-start
command. Caller-created or existing panes need that opt-out at creation too;
setting it after a password prompt is already active is too late.

With complete project heading/anchor setup, the helper creates an env-configured
lane-checkout workspace, attaches grouping without focus, splits at the source repo,
and closes only its owned temporary shell before starting the selected agent. No
typed cd is needed.
Wholly absent setup keeps today's flat launch and explicitly reports why; partial,
broken or ambiguous setup stops before launch. A failed grouped operation never
falls back to a second flat workspace. `--project` and lane number select grouping;
`--name` changes only the display/native alias, not the checkout or coordinator role.

Historical Herdr 0.8.0 capability inspection informed this helper's protocol 19
contract (`api snapshot`, `workspace create/get`, `agent start/get/read/prompt`).
The snapshot acceptance policy is explicit:

| JSON protocol | Snapshot version | Result |
|---|---|---|
| Integer `19` | Any or absent, preserving legacy behavior | Continue context/shape checks |
| Integer `22` | Exactly string `0.9.5` | Continue the same checks |
| Anything else | Any | Stop before receipt/create/start/prompt |

Floats such as `19.0`, booleans, strings and missing protocols are rejected, with
no coercion or semver normalization. Snapshot panes/workspaces/agents must be lists
of objects; consumed workspace/root-pane, agent/session and read boundaries are
checked before use. Flat receipts remain v1; grouped v2 receipts retain topology intents.
There is no per-launch help/status dump or global capability cache. On
incompatibility, inspect installed help/schema once and report manual fallback;
do not update Herdr/Pi or broaden permissions to make a launch work.

Use matched client/server installations: 0.8.0/0.8.0 for the previous path or
0.9.5/0.9.5 for the upgrade. Before launching after an approved cutover/rollback,
verify the client resolved by PATH **inside the coordinator pane** matches the
intended running server; an operator shell can resolve a different executable.
Legacy version-metadata acceptance does not certify mixed installations, and the
helper does not automatically detect every mixed pair. Stop before replacing a
shared binary; rollback must restore old compatible config/state, not open newer
state with an older binary.

Deterministic fixtures exercise both accepted profiles. A disposable flat 0.9.5
Claude launch has reached `Submitted`; Pi startup/readiness, client-focus behavior,
bridge transitions and grouped layout recovery are not certified end to end. A
snapshot passing this policy is not proof of those behaviors.

One `W12-launch.json` is authoritative. It stores prompt hash, source cwd, name,
selected agent (Pi when absent in legacy receipts), Claude settings path/hash when
used, inherited socket/session/caller fingerprint, returned opaque workspace/root-pane/
terminal IDs, agent session identity and checkpoint timestamps. `.launch.lock` serializes
helpers sharing that lanes directory. STATE gets one concise projection on exit;
receipt checkpoints don't require extra model/tool rounds.

Flow: reconcile existing receipt and live labels/aliases → persist **Creating** →
create ONE workspace (and complete grouped topology if applicable) without focus → validate
final source pane IDs and cwd → **Created** → persist **Starting** → start the selected
agent with `--name` on that **exact returned pane** → verify recognized agent/session and readiness →
**Ready** → persist **Submitting before sending** → submit the lane instruction ONCE,
without `--wait` → **Submitted** → inspect working/blocked/unknown truthfully.
No approval, key sending, force or other-session operations; only the new grouped temporary shell is closed.

Creation must return valid IDs, the requested label and the matching root-pane
workspace association. Herdr's pane cwd is optional and nullable. If creation-time
cwd does not exactly match the requested initial cwd, the helper takes **one** fresh,
protocol-checked snapshot. Exactly one workspace and root pane must confirm the same
label, workspace/pane/terminal IDs and exact cwd before **Created** or any agent start.
No polling or path normalization is added; malformed cwd values or an unconfirmed
snapshot leave **Creating** inspect-only. A matching create response needs no extra read.

Creation validation failures retain selected `creation_validation` comparisons with
expected and observed values, grouped by `create` or `snapshot`. Malformed objects,
strings containing characters below U+0020 and oversized strings are represented
by type, not raw content; no prompt or terminal text is copied. A successful snapshot fallback keeps the initial
cwd discrepancy and records `creation_cwd_confirmed: snapshot`. These observations do
not authorize recovery from an existing **Creating** receipt.

For Pi, the helper waits up to 30 seconds for the known Powerline welcome overlay
(`Welcome back!` plus `Press any key to continue (Ns)` in the **visible** viewport).
It dismisses naturally; no Enter/approval is sent. Claude startup reaches its recognized
idle editor shape or reports `blocked`; trust/theme/folder dialogs are never answered.
Trust/permission/question text stops for user intervention. Shell-only panes cannot be
Ready. A successful submission/idle marker never proves lane completion.

### Interrupted launch / recovery

Grouped topology intents are inspect-only on interruption; retain both returned pane IDs.
**Checkout** may fail before any pane exists: inspect the receipt and Git worktree registry;
even a failed Git command is not permission to retry automatically or discard the receipt.
With explicit operator approval and verified never-started state, inspect exact IDs/group/cwd,
create a missing source pane once, close only the verified shell-only temporary pane,
then start the receipt's named agent manually in the source pane and submit once.
Never edit/delete receipts.
An unfinished old flat receipt with grouping now present is inspect-only; lock contention stops.
Re-run the **same invocation** only to reconcile; it does not mean "try again".
- Existing live labels/aliases without a matching receipt, or STATE recording an old
  launch, stop before creation. Inspect and identify them; do not rename/adopt implicitly.
- **Creating** without validated IDs is uncertain even if no match is visible. Inspect
  live workspaces; no automatic replacement workspace.
- **Created** can start once. **Starting** only inspects the receipt's recognized agent;
  a shell-only pane or startup failure is not permission to restart. A known Pi
  welcome overlay may finish naturally. **Ready** is revalidated before submission.
- **Submitting** means possibly delivered, including a crash after delivery, failed
  parse, nonzero exit or timeout. Inspect/report only; **never automatically resend**,
  even if the agent appears idle or no delivery was observed. Ask before any deliberate
  recovery/resubmission. **Submitted** is inspect-only on subsequent invocations too.
- Receipt/live identity must match: inherited socket/caller fingerprint, workspace,
  root pane/terminal, alias and agent session. Restarts, stale IDs, changed prompts/settings and
  mismatches stop. Old receipt formats are not migrated or silently overwritten.
- On errors, preserve the receipt and last checkpoint. If STATE cannot be written,
  use the receipt and report that its summary needs updating. Never delete a receipt
  to get past uncertainty or automatically clear a dialog/terminate a pane.

### Manual local handoff

For a local lane, use `herdr-lane` only when its resolved target is the installed
dotfiles `herdr-lanes/lane.py`, not another same-named tool. Hand over:

```sh
herdr-lane double-holo-12 "Read /absolute/project-local/lanes/W12-approved-task.md and follow it."
herdr-lane --agent claude double-holo-12 "Read /absolute/project-local/lanes/W12-approved-task.md and follow it."
```

The Claude form requires `~/<project>-local/lanes/claude-lane-settings.json`. Both
forms type one startup command. The Claude start is observed read-only and reports a
blocked trust/dialog without answering it.

Shell-quote the prompt so its absolute path is passed literally, without expansion.
This opens under the project heading; an existing lane is only focused and never
receives the prompt. Failed or uncertain invocations are inspect-only: use the
pane named by the error and establish whether anything ran before taking action.
For a heading-shell failure, restore only its `needs.py` publisher using the error's
recovery command; no numbered lane exists yet. Never start an agent or paste the Read
instruction in the heading. For a numbered-lane shell failure with no submission,
finish startup, change to `~/<project>-local`, start the intended agent manually,
then paste the approved Read instruction into that idle agent. Never blindly resend or relaunch.

Without installed local `herdr-lane`, and for an unbound remote lane, use only:

```text
Read /absolute/project-local/lanes/W12-approved-task.md and follow it.
```

Do not add a `/name` or `--name` step, and never run `/name` in Bash. Record **Manual** until an actual launch is reported or verified.
Manual sessions are not automatically monitored; the user can say "W12 ready" and
point to the consolidated shared report.

## Local messages and attention

Use local notes to remove paste relays, not human approvals. `messages.py` never executes
instructions, sends terminal input, edits STATE or contacts remote hosts. Invoke through Python:

```sh
python3 <skill-dir>/scripts/messages.py status --root <project-root> --project sample
python3 <skill-dir>/scripts/messages.py publish --root <receiving-project-root> --project sample --note <complete-note.json>
python3 <skill-dir>/scripts/messages.py inbox --root <project-root> --project sample --role lane --name sample-7 --host local --prompt <lane-prompt.md>
python3 <skill-dir>/scripts/messages.py inbox --root <project-root> --project sample --role coordinator --name sample-coord --host local
```

`--root` and `--project` are explicit, trusted receiving-project bindings; a root need
not be named after its project. Verify both before publishing. Cross-coordinator notes
also require authority to write in that receiving project's folder. Never broadcast.
`--host` is the established host binding in coordination, not a guessed machine name.
Keep notes, acknowledgements and outputs private; no secrets or automatic Git staging.

### Attention on every user message

Before answering **every user message**, the coordinator reads its project's live lane
status and its own inbox, not only on `coordinate` or morning sweeps. Use `status` above:
it takes one Herdr snapshot, filters conventional numbered/coordinator labels by longest
matching sibling project slug, and includes custom labels pinned by this project's local
launch receipts (matching project, resolved STATE path and workspace). Pending receipts without
a workspace, or pinned workspaces absent from this snapshot, appear separately as
`unresolved_launches`; existing lane observations remain visible. Inspect that field too;
a recorded workspace ID is historical evidence, not a live observation.
No terminal content is read.
Remote/unbound or unobserved lanes remain unknown; a local snapshot is not remote coverage.
A host whose COORDINATION.md Hosts row marks `Worker: lane` does not use this file, except
to read notes already published. Human gates are unchanged: the human answers question cards;
the coordinator answers one only as a [covered answer](covered-answers.md).
On a Herdr host, if the wrapper needs approval, use the already-approved native `herdr api snapshot`
read and apply the same filter; do not broaden permissions or ask the human to carry status.

Live blocked/working/unknown wins over a stale ready token. A ready token on idle/done is
only a reason to fetch the report and verify head/CI, not readiness or merge permission.
The existing dashboard may rank ready before working; use live state for decisions.
Unsupported protocol/version, malformed ownership/data or CLI failure means unknown,
never an empty successful sweep. The helper accepts launch's protocol 19 or 22/Herdr 0.9.5.
A conventional label is discovery evidence only, not authority to send into that pane.

### Immutable addressed note

Publish one complete UTF-8 JSON object (maximum 64 KiB) per ID to
`<receiving-project-root>/reports/inbox/<id>.json`. `publish` preserves the input bytes,
flushes them, and atomically links the completed file without replacing an existing ID.
Directories and notes must not be symlinks. No writer edits an already published note.
IDs are filename-safe and unique in the receiving project's inbox, including across senders.

```json
{
  "version": 1,
  "id": "scope-20261115-001",
  "created_at": "2026-11-15T12:00:00Z",
  "sender": {"project": "sample", "role": "coordinator", "name": "sample-coord", "host": "local"},
  "recipient": {"project": "sample", "role": "lane", "name": "sample-7", "host": "local"},
  "category": "coordinator-instruction",
  "body": "Reread the amended prompt before publishing.",
  "prompt_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "supersedes": null,
  "decision": null
}
```

| Category | Meaning |
|---|---|
| `tom-decision` | Human's verbatim words in `decision.verbatim`, timezone-bearing `decision.timestamp`, inspectable `decision.source` locator. Only this category can carry a human-only approval. |
| `coordinator-instruction` | Same-project coordinator instruction within already approved scope only. Cannot satisfy a human gate. |
| `fyi` | Information only; no action or authority. The only cross-project category, coordinator-to-coordinator only; receiving coordinator decides applicability. |

For `tom-decision`, replace null with an object containing exactly `verbatim`, `timestamp`
and `source`. Prefer session path plus user entry ID/line; a report path plus line must
provide verifiable provenance, not an agent's assertion of consent. The recipient checks
the source and exact action/scope before relying on it. If unverifiable, stop at the human
gate. A schema-valid note is not authenticated consent and never rewrites the authority table.
Merges, public text, deletions, secrets, production and scope changes retain their human gates.
A coordinator recipient has `prompt_sha256: null`; a lane requires its current prompt SHA256.

### Pickup, acknowledgement and supersession

At **every existing prompt checkpoint before an irreversible/outward step**, and before
ready, the lane reads its addressed inbox as well as rereading a changed prompt. Reconcile
older addressed report notes too; do not silently drop pre-inbox instructions. Unreadable
notes/prompt or a rejected note must be resolved or explicitly acknowledged rejected before
claiming ready. Never read or edit global STATE as the lane's instruction channel.

The helper emits JSON `notes` (note, SHA256, superseded_by IDs) and `rejected` (ID/reason).
Exit 0 means the read/publish completed; exit 2 means invalid input, read failure or rejected
notes. Partial valid notes may accompany rejections; inspect the whole result. Errors go to
stderr; fatal failures leave stdout empty. No prompts, pager or background polling.

Recipient maintains this private report ledger **before acting**, not in STATE:
`message <id> sha256=<hash> disposition=<pending|applied|rejected|superseded|deferred> reason=<why>`.
Before executing, record pending; record applied only after observing completion. Compare ID
AND hash. Completed matching IDs are not reapplied; changed bytes under any acknowledged ID
are rejected, never treated as a new instruction. On interruption, inspect real effects: if
completed, record applied without repeating; verified absence of effects permits first execution
of the still-authorized action; partial or uncertain effects mean stop/reconcile, never automatic
retry. Acknowledgement alone is not proof of external completion. The helper
does not parse the report or perform actions; the consuming agent owns these checks.

New notes can name an existing same-recipient, same-sender, same-category ID in `supersedes`;
never overwrite it. Advisory notes cannot supersede human decisions or another sender's instructions.
Inspect predecessor links, not filesystem mtime; decide disposition before acting on a chain.
Reject missing/foreign predecessors. A stale prompt hash is rejected: ask the sender for a
new note targeting the current prompt. New instructions do not undo already applied actions.
Sender reads the recipient's named report for acknowledgement, never assumes file publication
means pickup. Only the coordinator writes its STATE using its normal stale-write protocol.

### Optional once-only local pointers

For owned local Claude Code and Pi lanes/coordinators, `send.py` can send one short
category/ID/path pointer to an already published note. It never sends the body as a command.
Coordinators may send within approved scope; a lane's ready nudge is `fyi` to its own
coordinator. This is not launch, cross-project messaging or remote delivery.

```sh
python3 <skill-dir>/scripts/send.py --root <project-root> --project sample --host local --session <verified-session> --ownership <current-ownership.json> --note <project-root>/reports/inbox/<id>.json
# Same arguments with --inspect inspect only; rerunning an existing claim also never sends.
```

Use the actual sender's inherited Herdr context, not selected/guessed `HERDR_*` variables.
The helper checks the server socket/session, both workspace labels and exact pane, terminal,
foreground cwd and agent session; the target must be idle/done with a recognized visible
idle editor and no dialog. A stale/unknown/busy/scrolled viewport means no send. A box-drawn
table or banner anywhere in view also counts as ambiguous; leave the note for checkpoint
pickup rather than automatically clearing the screen. Missing
`interactive_ready` on manually started agents is supported through equivalent identity,
idle and screen evidence; pending managed launches are refused. No focus, approval keys,
dialog answers or shell delivery. Ambiguous/custom screens require inspection, not guessing.
The native `agent prompt` endpoint also checks foreground-agent and blocked state; there is
no automatic fallback to `pane run` or another transport. This is a fresh check, not an atomic
idle/session lock: a state change after checking remains a race, not a delivery guarantee.

#### Ownership evidence

New launch receipts carry optional `caller_agent` **outside** their legacy compared `context`.
It pins the coordinator's kind/session, pane/workspace/terminal, foreground cwd and label.
The child remains pinned by the receipt's existing fields. The child foreground cwd is
`repo`, including grouped launches; `group.checkout` describes workspace worktree identity.
A conventional label alone never establishes ownership. The helper requires the matching
project, existing lane row in `<root>/STATE.md`, and current prompt under `<root>/lanes/`.
A lane recipient's note hash must match current prompt bytes, not its historical launch hash.
A reverse FYI has no recipient prompt hash; its source lane's prompt must still exist and its
STATE row must still exist. The helper does not interpret status-column text; the coordinator
checks that the lane is still an appropriate target. Row presence does not authorize an
instruction or weaken source review.

Old receipts without caller evidence cannot silently adopt whatever session is there now.
For a manual Claude lane or an explicitly reassigned/restarted coordinator, the coordinator
may write a **new private ownership copy**, leaving the launch receipt intact:

1. Verify current project/coordinator authority and the lane's original creation or approved
   handoff evidence. Retain the explicitly owned child pane/terminal/session and `repo`, lane,
   project, STATE and prompt paths; never pick a replacement by matching its label.
2. From the actual coordinator process, derive `context = launch.inherited_context(session)`,
   then `live = launch.snapshot(context)` and `caller_agent = launch.caller_pin(context, live)`
   using this skill's scripts. Require a non-null pin and check it is the authorized coordinator.
   Freshly compare the child pins against live metadata too. For a manually created lane,
   populate the same child fields from its verified create/start evidence, not guesses.
3. Save an exclusive new project-local JSON copy with those `context` and `caller_agent`
   fields and use it as `--ownership`. Recheck before sending; do not rewrite old delivery
   claims when a coordinator session changes.

This is coordinator attestation, not authenticated create/start proof: the helper checks
structure and current pins, not the history of the copy. Inherited context proves the pane,
not the calling process; a subagent inheriting it is not isolated by this helper. Existing
permission/worktree tripwires and the project's authority rules remain unchanged.

#### Claims and observation

Coordinator records intent and outcome in its lane row through the existing single STATE
writer/stale-write protocol. A lane records its ready nudge in its report; it never writes
STATE. Recipient ID/hash acknowledgement still lives in the named report, not this receipt.
The helper never edits STATE. Publication, successful submission and acknowledgement are
three different observations; none proves a human gate, external completion or merge readiness.

Read-only preflight runs before claiming. Busy/unknown at that point creates no delivery
receipt: leave the note for checkpoint pickup, no retry/polling loop. A later explicit
invocation can make its first send if no claim exists. After successful preflight, exclusive
`reports/inbox/delivery/<id>.json` claims serialize concurrent invocations. `prepared` is
flushed before another guard; `submitting` with attempts=1 is durable before native input;
`submitted` means a matching API response, not pickup. A failed post-claim guard is `not-sent`;
errors/timeouts/malformed responses after admission become `uncertain`. A crash can leave
`prepared`/`submitting` or an incomplete claim. Every existing claim is inspect-only: never resend,
change its ID to disguise a retry, delete it to retry, or try a different transport after
uncertainty. Reconcile real effects and current authority; unresolved effects mean stop.
Known structured error codes are retained, never arbitrary stderr or terminal content.
Inspection uses stored pins even if the launch receipt later adds an observation checkpoint.

### Lifecycle and hosts

No automatic expiry, deletion, archival or versioning. Retain notes and acknowledgement
history until the coordinator proposes an exact cleanup list and the human approves it.
The receiving project owns retention; sender owns publication; recipient owns acknowledgements.
These are trusted-local workflow files, not authenticated messaging or OS containment.
Remote note transport is not provided. An empty recipient-host inbox says nothing about
notes still on the coordinator host: record remote coverage as unknown, not no notes. The
coordinator confirms an already-approved delivery path and observable recipient copy before
claiming delivery; do not pretend a local edit reached a remote lane. Resolve this reference
to an installed/readable recipient-host path and verify it before prompt delivery; never use
an unverified coordinator-host-only absolute path. Later transport must transfer one immutable
addressed note with verified host binding, preserve bytes/hash and fetch the named acknowledgement. Never copy
STATE/session trees or personal-host content to another host to deliver a note.

## Remote lanes on Herdr hosts

To avoid local winning by omission, match the lane against each Hosts row's `Use for`;
local is the fallback when no row matches. Record the host and brief reason in its
`Host:` line and STATE row's `What / report` cell; the coordinator stays the single
STATE writer. No sync service is needed. On the user's explicit "start W<n>", the
coordinator may run the remote lane command once from the project-local folder,
where installed and project-authorized.
Record the launch in STATE; no retry, and inspect only on uncertain delivery/startup.

### Bind the host and prepare inputs

To avoid incomplete remote setup, each remote Hosts row in COORDINATION.md needs a
project-local `lane-hosts.json` binding or a reason it remains manual. The project's
coordinator prepares its own [binding](#explicit-remote-command), not other projects' files.
Verify SSH access, actual hostname/user, home, canonical checkout, host-local worktree
root, Pi/tool versions and provider/gh status
before delivery. Inspect status only, never auth files; the human does logins and
approves installs/resource updates with Pi stopped. A host alias can differ from its
OS hostname: the prompt's first-action guard checks the verified hostname/user.

Fill the lane's `Host:` with those bindings, concrete project paths, remote report
source and fetch command. Say plainly that its coordinator is on another machine
and fetches reports. Resolve filesystem paths before writing the prompt, not by
leaving shell variables in prose. Each lane uses its own fresh host-local worktree;
never copy another host's worktree `.git` pointer, regardless of which host coordinates.

Deliver only the task's project AGENTS/authority brief, host-resolved COMMON-RULES,
prompt and selected read-only repo profile. Replace references to absent coordinator
files with the scoped authority/profile locations in the host brief. Keep STATE,
other lanes' context, credentials and runtime/session trees on their owning hosts.
Inspect existing destinations/profile stores before copying; preserve unrelated work.
The prompt destination is create-only: before any delivery or workspace creation,
refuse an existing same-name file with different bytes; identical bytes are fine
and left unchanged. Choose another prompt filename for a different task.
Where approved, AGENTS.md, COMMON-RULES.md and the selected profile remain replaceable
coordinator-owned support files. Running lanes read the current shared rules/profile,
as local lanes do, not frozen per-lane copies. This does not reload already loaded
context. The profile is read-only for the lane, not a separately edited cumulative store.

### Explicit copy and manual startup

This fallback is only for an unbound host whose Hosts row explains why; bound hosts
use the [remote command](#explicit-remote-command) to avoid manual transfer overhead.
Inspect and byte-compare any existing prompt destination before delivering anything;
a different task must use another filename. Then create the approved project/lanes/
reports/profile directories over SSH. Bind this fictional example to the actual
verified paths/user. Use plain `rsync -a` for the three replaceable support files;
use create-only delivery for the prompt:

```sh
remote_shell='sh -c '\''exec tailscale ssh example@"$@"'\'' sh'
rsync -a --ignore-existing -e "$remote_shell" /home/example/project-local/lanes/task.md build-host:/home/example/project-local/lanes/task.md
```

The inline shell supplies `example@build-host`: rsync's usual `user@host:` spelling
passes `-l`, which the Tailscale SSH wrapper may not accept. Plain `-a` compares size
and time, so success alone does not prove current bytes. Read back the delivered
prompt, rules and profile before startup; unconfirmed currency is unknown. If equal
size/mtime hides different support-file bytes, inspect the intended source, deliberately make
only its mtime distinct, then rerun delivery and byte read-back. Unchanged rsync is
not a repair; no automatic force/checksum/delete flags, receipts or staging folders.
The human can still open a workspace on that host and start Pi manually after delivery.
For a bound host, hand over the resolved command from the project-local folder
instead of manual copy/start or a plain Read line:

```sh
herdr-lane --host build project-12 lanes/task.md
```

For lanes on the coordinator's own host, the handoff is
`herdr-lane <project>-<n> "Read <path> and follow it."` (add `--agent claude` for
Claude Code); without local command support, use plain Read.

### Explicit remote command

For a bound host, `herdr-lane --host <binding> <project-N> <local-prompt-file>` is the normal
start path, where installed and project-authorized: it removes manual transfer overhead,
delivers the four approved snapshots with byte read-back and creates a flat remote workspace.
The private project-local `lane-hosts.json` [format](https://github.com/gambtho/dotfiles/blob/main/tools/herdr/README.md#manual-remote-lanes)
supplies the saved-machine ID/target/session, independently verified SSH host/user, paths
and source files. A binding does not prove availability: missing command support,
authority or host access blocks that start. Report the blocker rather than substituting
local or manual startup; the manual fallback is only for documented unbound hosts.
Prepare host-resolved prose first; the command does not translate it.
No remote helper/anchor installation. An explicit "start W<n>" authorizes the
coordinator's single invocation above, not automatic launches or recovery.

Before mutation it compares the nonempty workspace/pane/terminal inventory through
transfer SSH, the saved API, and transfer SSH again. A mismatch or changing/empty
inventory stops; alias equality alone is insufficient. This is observational session
binding under trusted host authentication, not a cryptographic host-identity proof.
Each external call has a10-second outer limit. No mutation replay or timeout increase;
partial file delivery needs inspection, and a create/start timeout is uncertain.
Existing labels get remote-server focus only, no copy/input; the calling client's machine
selection is unchanged, whichever host coordinates. Record the command, observed result
and returned IDs in STATE; an existing label is not proof of startup. On uncertainty, record unknown and inspect only, never
retry. A repeated command cannot resume partial startup; it only focuses an existing label.
Keep the manual copy/start fallback above and the primary-first fetch below.

#### Claude Code lanes

Pi is the default. For a lane whose prompt names Claude Code as its harness, add
`--agent claude`: `herdr-lane --host <binding> --agent claude <project-N> <local-prompt-file>`.
The binding needs a `claude` executable path, and the project-local
`lanes/claude-lane-settings.json` is delivered create-only and passed with `--settings`;
without it the command refuses. That file adds to the host user's own Claude settings,
it does not replace them. The host must already trust the project-local folder; the
command never answers a trust or other dialog. After the single start it reads Herdr's
agent status up to ten times, one second apart: "blocked on Claude trust/dialog" or
"Claude did not start" (exit 1) is a stop to record and report, not something to answer
or resend. A printed status or "readiness unconfirmed" still needs the lane's report. See the
[README](https://github.com/gambtho/dotfiles/blob/main/tools/herdr/README.md#claude-code-lanes).

### Fetch before judging readiness

Name the required primary report explicitly (`W12-REPORT.md` here). Fetch it first,
then the prefixed evidence, including the handoff kept alongside the report, so
evidence alone cannot hide a missing primary behind an old local report. Record the
fetch observation time in the ordinary report:

```sh
remote_shell='sh -c '\''exec tailscale ssh example@"$@"'\'' sh'
rsync -a -e "$remote_shell" build-host:/home/example/project-local/reports/W12-REPORT.md /home/example/project-local/reports/ &&
rsync -a -e "$remote_shell" 'build-host:/home/example/project-local/reports/W12-*' /home/example/project-local/reports/
```

Read the host's named primary against the fetched copy before judging its currency.
A failed/offline fetch or unconfirmed currency is **unknown** even if older local
reports exist; a ready badge is not delivery. No delete flag, manifest, validator,
receipt or staging folder.

Use [normal report verification](../SKILL.md#handle-a-lane-report): refresh GitHub at
the exact PR head, match remote working/pushed/tested/CI revisions and read current
threads/review bodies. Reuse matching review evidence; a transfer timestamp alone
proves neither completion nor readiness.

### Close a closed remote lane workspace

Fetch first. Only after the lane is closed and its report and handoff are present in
the project's report location, use the recorded SSH binding to close the lane's own
workspace with `herdr workspace close <id>`. Match the launch receipt or exactly one
current workspace at the recorded label, and recheck Herdr status idle or done
immediately before close. The status check and close are not atomic, so work can resume
in that window; the pre-check does not guard against concurrent input. Working, blocked,
unknown, ambiguous identity or a changed status means leave it open and say so. Never
close the coordinator's own workspace or
one owned by another person/project. Record success in the archive line; this is not
file, worktree, branch, sandbox, or receipt deletion, and none of those cleanup rules
change. If the close itself is uncertain, inspect only, do not retry automatically,
and record closure unknown until reconciled.
