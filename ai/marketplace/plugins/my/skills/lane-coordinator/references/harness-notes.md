# Harness notes

The skill is harness-neutral. Use whatever the current harness offers for these jobs;
skip optional jobs if there's no tool for them. Required reviews remain required;
report a capability blocker rather than silently skipping or replacing them.

| Job | Claude Code | Pi |
|---|---|---|
| Read-only background reviewer | Agent tool with a self-contained prompt and `run_in_background: true` | `subagent_type: deep` or `review`, `run_in_background: true`; poll with `get_subagent_result({ agent_id, wait: false })` |
| Wait for CI | `gh pr checks <n> -R <repo> --watch`; foreground-poll background jobs (below) | Background shell if available; otherwise check on return |
| Wait for the bot-review budget | Foreground bounded wait for the remaining budget; overlap CI | Background shell if available; otherwise park with head, start time and remaining budget as the stop/resume line, not ready |
| Reminders | Session-only cron (say they end with the session); STATE.md "Upcoming" for anything longer | STATE.md "Upcoming" |
| Human attention on a lane state change | `PushNotification` when available; keep its presence check (it skips an active terminal). Informational only, never an approval channel. | No equivalent callable push tool is available in this Pi setup; keep the reply and STATE record, without a substitute transport. |
| Durable facts about people and preferences | Auto-memory, one fact per file; STATE.md stays the source of truth for lanes | `session_query` for missing context from a known session file; record durable facts in COORDINATION.md |
| Worktree writes | Normal git worktrees | The worktree guard blocks writes in primary checkouts; use linked worktrees |

A Hosts row marked `Worker: lane` starts its tasks through developerlanes; the worker
enrollment pins the harness, so add no client-side agent flag. Herdr launches, `herdr-lane`
and manual conversation naming are frozen in [the legacy reference](legacy-herdr.md#harness-and-launch-choice).

Background reviewers are read-only helpers, not lanes: say so in their prompt (no edits,
commits, pushes or posts) and spot-check what they find.
Codex CLI reviewers wait on "Reading additional input from stdin" unless stdin is closed (`</dev/null`).
From Claude Code, a background cross-family Pi reviewer (`pi -p …`) also needs
stdin closed (`< /dev/null`); otherwise it can wait silently until timeout.

## Bundled review and writing tools

The package includes `pr-closeout`, `polish-core`, `second-opinion-core`, `adversarial-review`
and `pr-text` (PR bodies, review comments/replies and issues).

- **Pi:** the package loads these skills and the `/second-opinion` and
  `/adversarial-review` prompt wrappers.
- **Claude Code:** read and follow the sibling `SKILL.md` directly, or optionally
  link each skill directory for discovery (replace `<name>` with a name above):
  `mkdir -p "$HOME/.claude/skills" && ln -s "$HOME/.dotfiles/ai/marketplace/plugins/my/skills/<name>" "$HOME/.claude/skills/<name>"`.
  This is manual setup, not an installer step; the Pi prompt wrappers are not
  Claude Code commands. Resolve sibling paths from the source directory, not the link.
- `pr-closeout` and `polish-core` can use Claude Code's Agent tool for an isolated,
  read-only reviewer; Pi's `inspector`/`deep`/`review` routes and
  `get_subagent_result` are not built-in Claude Code equivalents. Use its native
  background/result handling. Without an independent agent, disclose self-review
  and incomplete independence as `polish-core` requires.
- `second-opinion-core` requires a different-family model; `adversarial-review`
  requires two isolated reviewers with the specified family separation and verified
  resolved models. Claude Code's native Claude model selection alone cannot meet
  these requirements. Linking files does not supply Pi's dispatch/model routing.
  Use a verified capable lane/tool; otherwise report blocked (`INCOMPLETE` for
  adversarial review), not an equivalent pass. See [Claude Code subagents](https://code.claude.com/docs/en/sub-agents).

## Subscription lanes (Claude Code, Codex)

A lane can run on a Claude Code or Codex subscription instead of Pi. Its
cross-family review then comes from the other CLI, through the bundled scripts.

**Claude Code lane setup**, once per project and host:

1. Copy [claude-lane-settings.json](claude-lane-settings.json) to the project-local
   `lanes/claude-lane-settings.json`. Replace `<worktree-root>`, `<canonical-checkout>`
   and `<project-local>` with the host's resolved paths. In `Edit(...)`/`Read(...)` rules write
   `~/x` or `//abs/x`: a single leading `/` is relative to the settings file. Add the project's
   own test commands to `allow` (`Bash(<tool>:*)`). Keep the credential `Read` denies. Don't
   add `Write(...)` denies: Claude Code ignores them, and the `Edit` rules already cover writes.
   The denies bind Claude's file tools and simple command prefixes, not what an allowed
   `bash`/`python3` command or a reordered `git` command can do. Keep branch protection on
   the server, and narrow those allows if the host holds secrets the lane must not read.
   The template starts Claude in `auto` mode: allow rules run unchecked, deny rules block, and
   anything else goes to Claude's auto-mode check instead of a prompt. An auto-mode refusal means
   the lane stops or works around it, never that it asks for a bypass.
2. On a Herdr-only host, start with `herdr-lane --agent claude …`; see the frozen
   [legacy reference](legacy-herdr.md#claude-code-lanes). A lane worker's enrollment
   already names the harness.
3. A person starts `claude` once in the host's project-local folder and accepts the trust
   dialog. The launch never answers it.

**Codex lane** (hand-started; `herdr-lane` has no Codex option). From the host's
project-local folder:

```sh
codex -s workspace-write -a on-request --add-dir <worktree-root> \
  --add-dir <canonical-checkout>/.git -c sandbox_workspace_write.network_access=true \
  "Read <prompt> and follow it."
```

Network is on for git and gh; `on-request` asks the person only for steps outside the sandbox.

**Cross-family review.** Resolve the script paths to this skill's `scripts/` before delivery.
Each script writes `<out-prefix>.md`, `.stderr` and `.exit`, and exits with the reviewer's status:

- Claude Code lanes: `bash <skill>/scripts/codex-review.sh <prompt-file> <out-prefix>`
  (read-only sandbox, prompt on stdin from the file so it never waits; `codex` from PATH or mise;
  optional `CODEX_REVIEW_MODEL`).
- Codex lanes: `bash <skill>/scripts/claude-review.sh <prompt-file> <out-prefix>`
  (no edit or shell tools; prompt on stdin; optional `CLAUDE_REVIEW_MODEL`).

A nonzero exit is a blocker to report, not a reason to switch reviewers.

**Lessons from pilot lanes:**

- Write the report before saying ready.
- Run long checks with output and exit-code files. Claude lanes foreground-poll background
  checks/CI/reviews to prevent false Herdr idle/ready status. At lane-budget expiry,
  report pending work and park, not ready; retain stricter project wait rules. Otherwise
  never end with work running. Bound polls to ~9 minutes, not larger timeouts.
- A lane that needs one more path (for example SSH config) gets it for that lane only.
  Private keys stay denied.

## Shell pitfalls (zsh)

- `path` is tied to `$PATH`: never use it as a variable name (`read id path` breaks every
  command after it).
- `rm` may be aliased to `rm -i`; use `command rm -f` for non-interactive deletes.
- Unquoted `$var` doesn't word-split in zsh, and unmatched globs (or `?` in an unquoted
  URL) are errors. Quote URLs; loop over `gh` output in Python rather than `for x in $list`.
- `diff` and other tools may be shell functions; prefer `git diff --no-index` or Python.
- Long greps over transcripts can exceed the command timeout; narrow the path first.
