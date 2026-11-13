# Remote lanes

Local remains the default. Use another host when a whole lane benefits from its
capacity or tools; the coordinator stays the single STATE writer. No sync service
is needed. An approved human-invoked remote lane command can replace manual delivery
and startup; it does not extend coordinator launch authority.

## Bind the host and prepare inputs

Use COORDINATION.md's Hosts table. Verify SSH access, actual hostname/user, home,
canonical checkout, host-local worktree root, Pi/tool versions and provider/gh status
before delivery. Inspect status only, never auth files; the human does logins and
approves installs/resource updates with Pi stopped. A host alias can differ from its
OS hostname: the prompt's first-action guard checks the verified hostname/user.

Fill the lane's `Host:` with those bindings, concrete project paths, remote report
source and fetch command. Say plainly that its coordinator is on another machine
and fetches reports. Resolve filesystem paths before writing the prompt, not by
leaving shell variables in prose. Each lane uses its own fresh host-local worktree;
never copy a laptop worktree's `.git` pointer.

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
The human can open a workspace on that host and start Pi manually. Hand over only
the resolved line:

```text
Read /home/example/project-local/lanes/task.md and follow it.
```

## Optional human-invoked command

Where installed and authorized by the project, `lane --host <binding> <project-N>
<local-prompt-file>` delivers the four approved snapshots with byte read-back and
creates a flat remote workspace. The private project-local binding supplies the
saved-machine ID/target/session, independently verified SSH host/user, paths and
source files. Prepare host-resolved prose first; the command does not translate it.
No remote helper/anchor installation or automatic remote coordinator launch.

Before mutation it compares the nonempty workspace/pane/terminal inventory through
transfer SSH, the saved API, and transfer SSH again. A mismatch or changing/empty
inventory stops; alias equality alone is insufficient. This is observational session
binding under trusted host authentication, not a cryptographic host-identity proof.
Each external call has a10-second outer limit. No mutation replay or timeout increase;
partial file delivery needs inspection, and a create/start timeout is uncertain.
Existing labels get remote-server focus only, no copy/input; laptop machine selection
is unchanged. Read returned IDs and inspect before any explicit recovery. A repeated
command cannot resume partial startup; it only focuses an existing label.
Keep the manual copy/start fallback above and the primary-first fetch below.

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
