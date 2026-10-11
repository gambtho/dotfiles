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

Background reviewers are read-only helpers, not lanes: say so in their prompt (no edits,
commits, pushes or posts) and spot-check what they find.
