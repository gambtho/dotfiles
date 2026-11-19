# Local messages and attention

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

## Attention on every user message

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
A project/host whose COORDINATION.md Hosts row marks `Worker: lane` instead uses
`lane --host <host> status <project>` and the lane inbox; do not substitute a Herdr
snapshot. Send owner context to a running task with `lane --host <host> instruct <task>
"<text>"` and record Sent/Held/Refused or uncertain; this replaces inbox-file plus paste
pointers, not human gates. The human answers question cards; the coordinator never
answers one. If the wrapper needs approval, use the already-approved native `herdr api snapshot`
read and apply the same filter; do not broaden permissions or ask the human to carry status.

Live blocked/working/unknown wins over a stale ready token. A ready token on idle/done is
only a reason to fetch the report and verify head/CI, not readiness or merge permission.
The existing dashboard may rank ready before working; use live state for decisions.
Unsupported protocol/version, malformed ownership/data or CLI failure means unknown,
never an empty successful sweep. The helper accepts launch's protocol 19 or 22/Herdr 0.9.5.
A conventional label is discovery evidence only, not authority to send into that pane.

## Immutable addressed note

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

## Pickup, acknowledgement and supersession

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

## Optional once-only local pointers

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

### Ownership evidence

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

### Claims and observation

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

## Lifecycle and hosts

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
