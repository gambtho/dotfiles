# Explicit Herdr lane launch

Manual handoff is the default. Writing a prompt or saying "prepare W12" does not
launch anything. Follow this recipe only after an explicit request such as
"start W12", with a shell/tool interface inside the intended Herdr session.
A Claude app session without those tools returns the manual handoff instead.
Do not arrange SSH, guess a socket, or control a different session as a fallback.

## Before launch

- Confirm `HERDR_ENV=1` and that the inherited session is the intended destination.
  If access or destination is uncertain, provide the manual handoff. Inspect the
  installed `herdr --help`, `herdr workspace create --help`, `herdr agent start
  --help` and `herdr agent prompt --help` rather than assuming newer flags.
- Read STATE.md and the lane file. Check for an existing launch and inspect its
  recorded IDs with `herdr workspace get <workspace_id>` / `herdr agent get
  <pane_id>` before creating anything. If state has no launch record, list
  workspaces/agents and reconcile matching lane labels. A match that cannot be
  identified safely is a reason to ask, not create a duplicate.
- Confirm the lane file exists and the intended source repository directory.
  Each lane still creates/uses its own linked worktree before writing; opening
  a space does not fetch, switch branches or authorize primary-checkout writes.
- Choose a recognizable private display name, e.g. `project W12 — Login`, for
  both the space and Pi conversation. Use a separate unique agent alias matching
  `[a-z][a-z0-9_-]{0,31}`, e.g. `project-w12`. Check live aliases for collisions.
  Lane identifiers must not leak into public branches, commits or PR text.

## Create, record, start, submit

These are separate steps with checkpoints, not a fire-and-forget script. Stop on
any failed command or invalid response. Keep paths/titles as literal arguments;
quote shell data (including apostrophes) with a real shell-quoting routine when
constructing tool input. Never interpolate untrusted text into shell code or use
`eval`. Example Bash values below are literal, not executable label content:

```bash
repo='/home/example/my repo'
lane_file='/home/example/project-local/lanes/W12.md'
label='project W12 — Login'
alias='project-w12'
created=$(herdr workspace create --cwd "$repo" --label "$label" --no-focus)
```

Parse the returned `.result.workspace.workspace_id` and
`.result.root_pane.pane_id`; validate both are nonempty strings. They are opaque
IDs, not sidebar row numbers. Record them immediately in the lane's existing
STATE.md row, with Pi name, alias and launch state **Created**. If parsing or the
state write fails, stop and inspect the response/live list before retrying.

Use the returned root pane, not a new split or another client's focused pane:

```bash
herdr agent start "$alias" --kind pi --pane "$pane_id" -- --name "$label"
```

`agent start` requires an available shell pane and waits for recognized readiness
(default startup timeout 30 seconds). Successful return is not completed lane
work. Record **Ready** before submitting the instruction to the same pane:

```bash
herdr agent prompt "$pane_id" "Read $lane_file and follow it."
```

No `--wait`: launch hands control back to the coordinator while the lane works.
Record **Submitted** only on successful submission. Preserve user focus; do not
call focus commands or rely on implicit targets. Keep the existing lane report
and GitHub verification process as the source of completion evidence, not idle
status or a terminal excerpt.

## Partial launches and retries

Keep created IDs and the last confirmed launch state when startup is blocked,
times out, or prompt delivery is uncertain. Report the stage/error plainly;
never silently create another workspace or resend a possibly delivered prompt.
Inspect `agent get` and, when needed, `agent read` on the recorded pane. A timeout
does not prove no input was sent. Ask before retrying uncertain submission or
responding to a trust/permission/question dialog. Do not automatically approve,
press Enter, kill processes, or close surfaces to clear an error. Restarts can
make recorded IDs stale: reconcile the session, pane identity and lane prompt
before using them again.

## Manual Pi handoff

Return the normal `Read <absolute lane file> and follow it.` instruction and the
Pi UI command `/name <project W12 — title>` to run in the new lane before pasting
the instruction. Alternatively, start it with `pi --name <display-name>` using
correct shell quoting. `/name` is a human Pi UI command, not a Bash command or a
claim that this coordinator renamed a different session. Record **Manual** until
the user reports or you verify an actual launch. Other harnesses retain their
own naming mechanisms.
