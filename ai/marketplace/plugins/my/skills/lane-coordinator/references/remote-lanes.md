# Remote lanes

To avoid local winning by omission, match the lane against each Hosts row's `Use for`;
local is the fallback when no row matches. Record the host and brief reason in its
`Host:` line and STATE row's `What / report` cell; the coordinator stays the single
STATE writer. No sync service is needed. On the user's explicit "start W<n>", the
coordinator may run the remote lane command once from the project-local folder,
where installed and project-authorized.
Record the launch in STATE; no retry, and inspect only on uncertain delivery/startup.

## Developerlanes worker (opt-in)

A Hosts row whose `Worker` is `lane` opts **that host for that project** into
developerlanes. Everything else keeps today's Herdr/manual path. The coordinator verifies
the saved host/worker enrollment and the project allowlist before using any command below;
this row grants no new publication, answer or launch authority.

On explicit start authority, include the approved context as inert `--input` files:

```sh
lane --host <host> start <lane-project> --prompt <lane-file> --label "<project> W<n>" --by <project>-coord --input <AGENTS.md> --input <COMMON-RULES.md> [--input <review-profile>]
```

Pass `--label "<project> W<n>"` and `--by <project>-coord` on every `lane start`, local
or `--host`. Both are display-only: they show in status, Herdr, the inbox and Teams, and
grant nothing. `lane status --by <project>-coord` lists one coordinator's tasks.

Run it once and record the request/creation ID in STATE. If the result is interrupted,
unreachable or uncertain, run only `lane --host <host> launch-status <lane-project>
--request-id <request-id>` (or the original creation ID); never submit a second start.
`Submitted` proves delivery to the native launcher, not task completion or readiness.
A fresh start after a set-aside reuses the prompt file with a new ID:
`lane --host <host> start … --label "<project> W<n>" --by <project>-coord --creation-id <new UUID>`;
do not rename the prompt file to force a new start, which leaves two copies of one prompt.

For live state and attention, use `lane --host <host> status <lane-project>` and the
lane inbox instead of Herdr snapshots. A fresh `done` is still only a reason to inspect the
report. For a running task, send approved owner steering with
`lane --host <host> instruct <task> "<text>"` instead of publishing an inbox note and
asking for a paste. Record the instruction UUID and outcome: `Sent` is delivered once,
`Held` means wait; do not send a replacement. After the task becomes idle, rerun
the exact original `instruct` command to reconcile and advance that same saved ID;
this is not a second instruction. `instruction-status` is lookup-only and may not
advance delivery. `Refused` stops for identity/dialog inspection. Uncertain or
`Recording`/`Sending` results are inspect-only; never send a replacement instruction
or answer a trust/permission dialog through the API.
The human answers question cards; the coordinator calls `lane answer` only for a
[covered answer](covered-answers.md), with `--by <coordinator-id>` and `--expected-hash`.
A remote answer binds to the card cached by the
last status read, so run `lane --host <host> status <lane-project>` immediately before
`lane --host <host> answer`, and pass that row's `card.sha256`. Confirm the refreshed card
and choice still match the cited rule; if the card changed, stop and read it again before
answering. A remote answer is recorded as the enrolled owner's, relayed by the `--by` name.

Fetch the lane's primary report and optional handoff before retirement or cleanup with
`lane --host <host> report <task>`. Capture that formatted stdout as private fetched evidence
under the project's report folder; do not treat a displayed remote path as a local copy.
Read the returned content/revision before judging it; a failed, stale or unsafe report
remains unknown. Then apply
the existing report verification, approval, retire/close and cleanup rules unchanged.
Readiness still requires the exact PR head/CI/thread checks in the skill; developerlanes'
checked-ready holds are useful evidence where present, not a replacement for those rules.

## Bind the host and prepare inputs

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

## Explicit copy and manual startup

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

## Explicit remote command

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

### Claude Code lanes

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

## Fetch before judging readiness

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

## Close a closed remote lane workspace

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
