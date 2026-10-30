# Harness notes

The skill is harness-neutral. Use whatever the current harness offers for these jobs;
skip optional jobs if there's no tool for them. Required reviews remain required;
report a capability blocker rather than silently skipping or replacing them.

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

## Bundled review tools

The package includes `pr-closeout`, `polish-core`, `second-opinion-core` and `adversarial-review`.

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

## Shell pitfalls (zsh)

- `path` is tied to `$PATH`: never use it as a variable name (`read id path` breaks every
  command after it).
- `rm` may be aliased to `rm -i`; use `command rm -f` for non-interactive deletes.
- Unquoted `$var` doesn't word-split in zsh, and unmatched globs (or `?` in an unquoted
  URL) are errors. Quote URLs; loop over `gh` output in Python rather than `for x in $list`.
- `diff` and other tools may be shell functions; prefer `git diff --no-index` or Python.
- Long greps over transcripts can exceed the command timeout; narrow the path first.
