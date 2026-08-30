# Pi runtime — `improve`

This reference defines the Pi-specific memory and subagent mechanics used by the `improve` skill.

## Quick reference

| Concept | Pi implementation |
|---|---|
| Project conventions | Root `AGENTS.md`, falling back to `CLAUDE.md` when a project has not migrated |
| Parallel reviewers | One `subagent` call with three self-contained tasks |
| Memory path | `.pi/memory/improve_findings.md` in the project root |
| Language idiom rules | The installed `polish-core/rules/` directory |

## Read previous findings

Read `.pi/memory/improve_findings.md` from the project root. If it does not exist, treat this as the first run and skip comparison with prior findings.

## Dispatch parallel reviewers

Use one `subagent` tool call with a `tasks` array of three prompts: semantic/architectural, correctness/quality, and surface/dependencies. Each task must be self-contained because subagents do not share the parent conversation. Repeat the required priming reads, Phase 1 data, finding format, and output contract in every task.

Use mode `deep` and a strong GitHub Copilot model. The correctness/quality task should read the applicable language file from the installed `polish-core/rules/` directory.

## Persist findings

Write `.pi/memory/improve_findings.md`, creating `.pi/memory/` when needed. Preserve the metrics history table, append the latest row, keep the last five rows, update resolved-item statuses, and add new findings.

If `.pi/memory/MEMORY.md` exists, ensure it points to the findings file:

```markdown
- [Improve Findings](improve_findings.md) — Latest codebase review findings and metrics
```

Create `MEMORY.md` with that line when absent.
