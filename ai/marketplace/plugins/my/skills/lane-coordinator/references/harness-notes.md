# Harness notes

The skill is harness-neutral. Use whatever the current harness offers for these jobs;
skip a job if there's no tool for it.

| Job | Claude Code | Pi |
|---|---|---|
| Read-only background reviewer | Agent tool with a self-contained prompt and `run_in_background: true` | `subagent_type: deep` or `review`, `run_in_background: true`; poll with `get_subagent_result({ agent_id, wait: false })` |
| Wait for CI without polling by hand | Background shell: `gh pr checks <n> -R <repo> --watch` | Same command in a background shell if available; otherwise check on return |
| Reminders | Session-only cron (say they end with the session); STATE.md "Upcoming" for anything longer | STATE.md "Upcoming" |
| Durable facts about people and preferences | Auto-memory, one fact per file; STATE.md stays the source of truth for lanes | `session_query` for missing context from a known session file; record durable facts in COORDINATION.md |
| Worktree writes | Normal git worktrees | The worktree guard blocks writes in primary checkouts; use linked worktrees |

For explicit Herdr launches and manual Pi conversation naming, follow
[herdr-launch.md](herdr-launch.md), including its deterministic helper when an
approved prompt already exists. New names default to `project-slug-number` across
workspace/Pi/alias (e.g. `double-holo-12`); existing names remain untouched.
This depends on actual tools and the inherited
Herdr session, not whether the coordinator is Pi or Claude Code. Claude app
sessions without terminal tools use the manual handoff.

Background reviewers are read-only helpers, not lanes: say so in their prompt (no edits,
commits, pushes or posts) and spot-check what they find.

## Shell pitfalls (zsh)

- `path` is tied to `$PATH`: never use it as a variable name (`read id path` breaks every
  command after it).
- `rm` may be aliased to `rm -i`; use `command rm -f` for non-interactive deletes.
- Unquoted `$var` doesn't word-split in zsh, and unmatched globs (or `?` in an unquoted
  URL) are errors. Quote URLs; loop over `gh` output in Python rather than `for x in $list`.
- `diff` and other tools may be shell functions; prefer `git diff --no-index` or Python.
- Long greps over transcripts can exceed the command timeout; narrow the path first.
