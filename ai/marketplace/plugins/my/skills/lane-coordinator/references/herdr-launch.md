# Explicit Herdr lane launch

Preparing a prompt does not launch it. After an explicit request such as **"start
W12"**, with an approved prompt already present, verify context/prompt/source then
run the helper below. Do not re-plan approved work or substitute manual instructions
when eligible access exists. Without tools or eligible inherited context, give the
short manual handoff. Never guess sockets, arrange SSH, switch sessions or steal focus.
Other harnesses retain their manual fallback; this is only a Pi fast path.

## Identity and preflight

- Read STATE.md and the approved lane file; confirm the intended source repository.
  The source cwd must exist. The lane must still isolate in a linked Git worktree
  before source writes: a Herdr workspace provides terminal layout, not Git isolation.
- Use the established project slug and numeric lane: `double-holo-12` for W12.
  This is the default for **all three** new workspace labels, Pi names and live
  aliases. Full task descriptions and W12 identity stay in STATE.md/lane files;
  lane filenames/numbering do not change. Never rename an existing workspace,
  conversation, alias, public branch, commit or PR.
- Honor an explicit naming override with `--name`; the shared name must satisfy
  Herdr's alias constraint `[a-z][a-z0-9_-]{0,31}`. Reject invalid names, overlength
  names and ambiguous collisions. No silent truncation or random suffixes. A user
  override that cannot serve as an alias needs a valid user-selected name, not a guess.
- Confirm `HERDR_ENV=1`, the inherited `HERDR_SESSION` matches the intended session,
  and inherited socket/caller pane/workspace exist. Supply that verified session to
  `--session`; it is an assertion, **not** a session selector. The helper never
  overrides the inherited destination. Missing/mismatched context means manual handoff.
  A default session may omit `HERDR_SESSION` (observed with v0.8.0); do not invent
  a value or switch sessions to bypass that precondition.
- STATE.md needs the five-column Open lanes table from the state template, including
  exactly one row for the lane, with Launch initially `Manual` or `—`. Existing launch
  state or a receipt must be reconciled, not erased. Keep receipts in the same local,
  unversioned lanes directory as the prompt. Do not copy receipts between sessions.

## Execute once

Run [launch.py](../scripts/launch.py) through Python 3 (standard library, POSIX
Linux/macOS/WSL). Resolve the script relative to this skill; quote literal paths:

```bash
python3 <skill-dir>/scripts/launch.py --requested \
  --project double-holo --lane W12 --session '<verified inherited session>' \
  --repo '/home/example/my repo' \
  --prompt '/home/example/double-holo-local/lanes/W12-approved-task.md' \
  --state '/home/example/double-holo-local/STATE.md'
```

`--requested` attests to the actual user launch request; it does not grant scope,
publication or provider/production authority. Do not add it for "prepare W12".
The helper uses argv subprocess calls, not executable shell text or `eval`.
It creates agent workspaces with `--env DOTFILES_KEYRING_PROMPT=0`, before the
root shell starts, so locked-keyring password input cannot consume the agent-start
command. Caller-created or existing panes need that opt-out at creation too;
setting it after a password prompt is already active is too late.

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
checked before use. Receipt version 1 and at-most-once delivery remain unchanged.
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

Deterministic fixtures exercise both accepted profiles. Isolated 0.9.5 server health
has passed, but actual Pi startup/readiness, prompt delivery, client-focus behavior,
bridge transitions and layout recovery are not certified for this upgrade. A
snapshot passing this policy is not proof of those end-to-end behaviors.

One `W12-launch.json` is authoritative. It stores prompt hash, source cwd, name,
inherited socket/session/caller fingerprint, returned opaque workspace/root-pane/
terminal IDs, Pi session identity and checkpoint timestamps. `.launch.lock` serializes
helpers sharing that lanes directory. STATE gets one concise projection on exit;
receipt checkpoints don't require extra model/tool rounds.

Flow: reconcile existing receipt and live labels/aliases → persist **Creating** →
create ONE workspace with explicit cwd/label and `--no-focus` → validate returned
workspace/root pane IDs → **Created** → persist **Starting** → start Pi with `--name`
on that **exact returned pane** → verify recognized Pi/session and readiness →
**Ready** → persist **Submitting before sending** → submit the lane instruction ONCE,
without `--wait` → **Submitted** → inspect working/blocked/unknown truthfully.
No focus, approval, key sending, kill, close, force or other-session operations exist.

The helper only waits up to 30 seconds for the known Powerline welcome overlay
(`Welcome back!` plus `Press any key to continue (Ns)` in the **visible** viewport).
It dismisses naturally; no Enter/approval is sent. Generic blocked status is not
splash evidence. Trust/permission/question text stops for user intervention. Shell-only
panes cannot be Ready. A successful submission/idle marker never proves lane completion.

## Interrupted launch / recovery

Re-run the **same invocation** only to reconcile; it does not mean "try again".
- Existing live labels/aliases without a matching receipt, or STATE recording an old
  launch, stop before creation. Inspect and identify them; do not rename/adopt implicitly.
- **Creating** without validated IDs is uncertain even if no match is visible. Inspect
  live workspaces; no automatic replacement workspace.
- **Created** can start once. **Starting** only inspects an already recognized Pi;
  a shell-only pane or startup failure is not permission to restart. A known welcome
  overlay may finish naturally. **Ready** is revalidated before submission.
- **Submitting** means possibly delivered, including a crash after delivery, failed
  parse, nonzero exit or timeout. Inspect/report only; **never automatically resend**,
  even if the agent appears idle or no delivery was observed. Ask before any deliberate
  recovery/resubmission. **Submitted** is inspect-only on subsequent invocations too.
- Receipt/live identity must match: inherited socket/caller fingerprint, workspace,
  root pane/terminal, alias and Pi session. Restarts, stale IDs, changed prompts and
  mismatches stop. Old receipt formats are not migrated or silently overwritten.
- On errors, preserve the receipt and last checkpoint. If STATE cannot be written,
  use the receipt and report that its summary needs updating. Never delete a receipt
  to get past uncertainty or automatically clear a dialog/terminate a pane.

## Manual Pi handoff

Name the new conversation in the Pi UI, then paste the instruction:

```text
/name double-holo-12
Read /absolute/project-local/lanes/W12-approved-task.md and follow it.
```

Alternatively launch `pi --name 'double-holo-12'`, then paste the instruction.
`/name` is a human UI command, not Bash and not a claim that the coordinator renamed
another session. Record **Manual** until an actual launch is reported or verified.
Manual sessions are not automatically monitored; the user can say "W12 ready" and
point to the consolidated shared report.
