# Platform compatibility — `my:improve`

This skill runs on Claude Code, OpenCode, and Pi. Read this file when the skill body says "see references/platforms.md" — it covers the per-platform substitutions for memory I/O, agent dispatch, and supporting-skill paths.

## Platform detection

- If your system prompt mentions **OpenCode**, use OpenCode conventions.
- If it mentions **pi** / **Pi coding agent**, or you have a `subagent` tool but no `Agent`/`task` tool, use Pi conventions.
- Otherwise use **Claude Code** conventions.

## Quick reference

| Concept | Claude Code | OpenCode | Pi |
|---------|-------------|----------|----|
| Project conventions file | `CLAUDE.md` | `CLAUDE.md` or `AGENTS.md` | `AGENTS.md` (fall back to `CLAUDE.md`) |
| Parallel agents | `Agent` tool with `explore` | `task` tool with `subagent_type: "explore"` | `subagent` tool with one task per agent (each task prompt fully self-contained) |
| Memory path | `~/.claude/projects/<project>/memory/improve_findings.md` | `memory_set` / `memory_list` (scope: `project`, label: `improve-findings`) | `.pi/memory/improve_findings.md` in project root |
| Code-simplifier rules | `~/.claude/plugins/cache/.../code-simplifier/*/rules/` | `~/.config/opencode/skills/code-simplifier/rules/` or `~/.dotfiles/ai/opencode/skills/code-simplifier/rules/` | Same as OpenCode paths if present; otherwise skip |

---

## Step 1: read previous findings

**Claude Code**: read `~/.claude/projects/<current-project>/memory/improve_findings.md` if it exists. Determine `<current-project>` from the current working directory.

**OpenCode**: use `memory_list` to check whether a `project`-scoped block named `improve-findings` exists; if so, read its contents.

**Pi**: read `.pi/memory/improve_findings.md` from the project root.

If no previous findings exist, this is the first run — skip the comparison step.

## Step 3: dispatching parallel agents

The skill spawns 3 explore agents — semantic/architectural, correctness/quality, surface/dependencies. Per platform:

- **Claude Code**: 3 `Agent` tool calls with `subagent_type: "Explore"` in a single message.
- **OpenCode**: 3 `task` tool calls with `subagent_type: "explore"` in a single message.
- **Pi**: one `subagent` tool call with a `tasks` array of 3 prompts. Each task prompt MUST be self-contained — repeat the full priming reads, Phase 1 data, finding format, and strict output contract, since pi subagents have no shared conversation history.

Agent 2 ("Correctness & quality") wants the language idiom rules from `code-simplifier` — see the table above for paths. If unavailable on the platform, the agent proceeds without them; the skill's value is what linters miss regardless.

## Step 5: write findings to memory

**Claude Code**: write to `~/.claude/projects/<current-project>/memory/improve_findings.md`. When updating, preserve the metrics history table — append a new row, keep the last 5 rows. Update the status of resolved items (add the PR number if known) and add new items.

**OpenCode**: use `memory_set` with `scope: "project"` and `label: "improve-findings"`. OpenCode's memory blocks have size limits (~5000 chars), so keep the format concise — current metrics row plus the last 2 rows of history; findings as title + status only. Include the description: `"Latest codebase review findings from /improve skill"`.

**Pi**: write to `.pi/memory/improve_findings.md` (create the directory if missing). Same append-and-keep-last-5 rule as Claude Code. No size limit applies.

If `MEMORY.md` exists in the memory directory, ensure it has a pointer to this file:

```markdown
- [Improve Findings](improve_findings.md) — Latest /improve skill review results and metrics
```

If `MEMORY.md` does not exist, create it with that line.
