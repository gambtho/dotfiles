# Local messages and attention

Use local notes to remove paste relays, not human approvals. These helpers never execute
instructions, send terminal input, edit STATE or contact remote hosts. Invoke through Python:

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
If the wrapper needs approval, use the already-approved native `herdr api snapshot` read
and apply the same filter; do not broaden permissions or ask the human to carry status.

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
