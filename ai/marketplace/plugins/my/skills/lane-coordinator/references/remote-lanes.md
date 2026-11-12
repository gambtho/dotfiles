# Remote lanes

Local remains the default. Use another host when a whole lane benefits from its
capacity or tools; the coordinator stays the single STATE writer. No sync service
or remote launcher is needed.

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

## Explicit copy and manual startup

Create the approved project/lanes/reports/profile directories over SSH first. Bind
this fictional example to the actual verified paths/user. Copy each selected file
to its named destination with the same plain rsync form:

```sh
remote_shell='sh -c '\''exec tailscale ssh example@"$@"'\'' sh'
rsync -a -e "$remote_shell" /home/example/project-local/lanes/task.md build-host:/home/example/project-local/lanes/task.md
```

The inline shell supplies `example@build-host`: rsync's usual `user@host:` spelling
passes `-l`, which the Tailscale SSH wrapper may not accept. Plain `-a` compares size
and time, so success alone does not prove current bytes. Read back the delivered
prompt, rules and profile before startup; unconfirmed currency is unknown. No helper
file or extra transfer machinery. The human opens a workspace on that host and starts Pi there;
the local Herdr launcher is not a remote launcher. Hand over only the resolved line:

```text
Read /home/example/project-local/lanes/task.md and follow it.
```

## Fetch before judging readiness

Name the required primary report explicitly (`task-report.md` here). Fetch it first,
then the prefixed evidence, including the handoff kept alongside the report, so
evidence alone cannot hide a missing primary behind an old local report. Record the
fetch observation time in the ordinary report:

```sh
remote_shell='sh -c '\''exec tailscale ssh example@"$@"'\'' sh'
rsync -a -e "$remote_shell" build-host:/home/example/project-local/reports/task-report.md /home/example/project-local/reports/ &&
rsync -a -e "$remote_shell" 'build-host:/home/example/project-local/reports/task-*' /home/example/project-local/reports/
```

Read the host's named primary against the fetched copy before judging its currency.
A failed/offline fetch or unconfirmed currency is **unknown** even if older local
reports exist; a ready badge is not delivery. No delete flag, manifest, validator,
receipt or staging folder.
Use [normal report verification](../SKILL.md#handle-a-lane-report): refresh GitHub at
the exact PR head, match remote working/pushed/tested/CI revisions and read current
threads/review bodies. Reuse matching review evidence; a transfer timestamp alone
proves neither completion nor readiness.
