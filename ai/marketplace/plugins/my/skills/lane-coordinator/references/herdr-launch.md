# Explicit Herdr lane launch

Preparing a prompt does not launch it. After an explicit request such as **"start
W12"**, with an approved prompt already present, verify context/prompt/source then
run the helper below. Do not re-plan approved work or substitute manual instructions
when eligible access exists. Without tools or eligible inherited context, give the
short manual handoff. Never guess sockets, arrange SSH, switch sessions or steal focus.

## Identity and preflight

- A project is one workspace on the inherited local daemon, labelled with its full
  project slug (`double-holo`). Each lane is a tab; default tab label, Pi name and
  alias are `double-holo-12` for W12. Never move or rename existing sessions.
- Use the canonical existing project directory (`double-holo-local`) as
  `--project-root`; STATE must be directly in it. `--repo` is the separate existing
  code directory. Verify the intended source repository; the lane still isolates
  in a linked Git worktree before source writes. Terminal layout is not Git isolation.
- Honor explicit lane naming overrides with `--name`, matching Herdr's alias
  constraint `[a-z][a-z0-9_-]{0,31}`. Reject invalid names, overlength or collisions;
  never truncate or invent suffixes. Full task/W12 identity stays in STATE/lane files.
- Require `HERDR_ENV=1`, inherited session/socket/caller pane/workspace, and the
  intended session matching `HERDR_SESSION`. `--session` asserts this destination;
  it does not select another daemon. A missing default-session variable is not an
  invitation to invent it. A Claude app coordinator outside Herdr uses manual handoff;
  a terminal-capable coordinator with eligible context can use this helper.
- The five-column Open lanes STATE table needs exactly one lane row (last column
  Launch, initially `Manual` or `—`). Existing receipt/launch state is reconciled,
  not erased. Receipts remain beside the approved prompt, local and unversioned;
  do not copy receipts between sessions to establish authority.

## Execute once

Invoke [launch.py](../scripts/launch.py) through Python 3 (POSIX standard library),
with literal quoted paths. **New skill-generated launches always pass --project-root.**

```bash
python3 <skill-dir>/scripts/launch.py --requested \
  --project double-holo --lane W12 --session '<verified inherited session>' \
  --project-root '/home/example/double-holo-local' \
  --repo '/home/example/my repo' \
  --prompt '/home/example/double-holo-local/lanes/W12-approved-task.md' \
  --state '/home/example/double-holo-local/STATE.md'
```

`--requested` attests to a real launch request; it grants no implementation,
publication or provider authority. The helper uses literal argv, not shell text/eval.
Both workspace and lane-tab creation pass `--env DOTFILES_KEYRING_PROMPT=0` so the
new shell receives the keyring opt-out; setting it after an active password prompt
is too late. This is not a guarantee of live startup timing or client-focus behavior.

### Workspace selection

Use only the fresh inherited-daemon snapshot, not other hosts listed by a GUI.
For the unique workspace labelled the full project slug:
- Adopt it only if it is the verified caller's own workspace AND the caller pane's
  currently observed `cwd` equals the verified project root. Null/absent `cwd`,
  `foreground_cwd` alone or worker panes cannot authorize adoption.
- Any other matching workspace needs retained provenance from a v3 receipt that
  **created** it for this project/root on this daemon. An adoption-only receipt is
  not creation provenance. Same daemon means matching session and socket path,
  device and inode; an old/restarted-daemon receipt is not authority.
- Ambiguous/incompatible/unproven labels stop before workspace or tab creation.
  Missing retained workspace IDs or uncertain workspace creation also stop; a
  later empty snapshot never authorizes a replacement.
- If positively missing with no uncertain receipt, create the project workspace
  at project root. Its initial shell tab stays for the coordinator, even if empty.
  Then create the named lane tab at project root. Never reuse the shell as a lane.

The launcher never starts, moves or names a coordinator, nor claims coordinator-first
when none is present. The operator names new coordinators `project-coord` when starting
them and selects existing GUI Under workspaces/coordinator_suffix settings for ◆.
Existing bare coordinator names stay unmarked after merge plus `make ai`; existing
standalone lane workspaces stay navigable where they are. `WN` display in the future
GUI context view is separate from the underlying `project-N` identity.

### Versions and receipts

| Invocation | Receipt | Accepted snapshot |
|---|---|---|
| New launch with `--project-root` | v3 project workspace/lane tab | Integer 22, exact string 0.9.5 |
| Legacy invocation without it | v1 per-lane workspace at `--repo` | Integer 19, any/absent version; or integer 22 / exact 0.9.5 |

No float/bool/string protocol coercion or version normalization. New tab mode has
no protocol 19 fallback. Legacy same-invocation v1 reconciliation preserves its old
workspace/cwd; formats are never migrated, overwritten or silently reopened as v3.
Reference-only v2 receipts are not supported. An existing legacy live lane never moves.
Use matched client/server binaries; inspect help/schema on incompatibility, do not
update Herdr/Pi or broaden permissions. Snapshot acceptance is not end-to-end certification.

One `W12-launch.json` is authoritative. It records prompt hash, source/root, lane
name, inherited socket/session/caller fingerprint, workspace/tab/pane/terminal IDs,
Pi session reference and checkpoint times. `.launch.lock` serializes helpers sharing
that lanes directory. STATE gets one concise projection on exit, not a second journal.

Flow: reconcile receipt/live identity → **Creating** (distinct workspace/tab progress)
→ create missing project workspace once → save its returned IDs before requiring a
root pane → create one lane tab → save its independently valid IDs before requiring
its root pane → **Created** only after full validation → **Starting** before start
→ named Pi on the exact returned lane pane → recognized session/readiness → **Ready**
→ **Submitting before sending** approved lane instruction once → **Submitted**.
This fresh-work launcher submits a prompt; future GUI exact Resume sends none.
A v3 session reference must be an absolute `herdr:pi` path; it is not a display name.

Pre-mutation socket/caller rechecks are best effort. Herdr CLI connects separately,
so socket replacement can race between stat and connect. This is **not** Sheprd's
physically paired-socket proof or a global exactly-once guarantee across clients.
There are no focus, approval, key sending, kill, close, force or other-host actions.
The known Powerline welcome overlay may dismiss naturally within 30s; visible
trust/permission/question dialogs stop. Shell-only panes cannot be Ready, and
submission/idle never proves task completion.

## Interrupted launch / recovery

Re-run the same invocation only to reconcile, not to retry delivery. A read-only
refusal before any create attempt leaves no receipt or STATE change.
- Unrecorded lane label/alias collisions or existing STATE launch stop before creation.
  Project-workspace adoption is only the explicit policy above, never lane adoption.
- **Creating** at either workspace or tab step is uncertain, even with returned IDs.
  Root-pane-absent/malformed replies preserve every valid workspace/tab observation;
  they do not certify Created. Never create again, automatically clean up or move panes.
- **Created** certifies no attempted start and may start once. **Starting** only inspects
  recognized Pi; shell-only/startup failure never permits restart. **Ready** is revalidated.
- **Submitting** means possibly delivered after crash/timeout/bad reply/nonzero exit;
  inspect only, never resend even if idle or delivery was not observed. **Submitted**
  is also inspect-only. Deliberate recovery/resubmission needs separate approval.
- Receipt/live identity must match socket/session/caller, workspace/tab/pane/terminal,
  lane alias and Pi reference. Changed prompts, daemon restarts, stale IDs and mismatches
  stop. Missing legacy resources do not authorize a new launch under the old receipt.
- Preserve receipt/last checkpoint on error. If STATE cannot be updated, report that
  its projection needs updating from the receipt. Never delete a receipt to bypass uncertainty.

## Manual Pi handoff

The user names the conversation themselves; give this instruction alone:

```text
Read /absolute/project-local/lanes/W12-approved-task.md and follow it.
```

No `/name` or `--name` step, no `/name` in Bash. Record **Manual** until an actual
launch is reported/verified. Manual sessions are not automatically monitored.
