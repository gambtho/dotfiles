# Pi runtime — `improve`

This reference defines the Pi-specific memory and subagent mechanics used by the `improve` skill.

## Quick reference

| Concept | Pi implementation |
|---|---|
| Project conventions | Root `AGENTS.md`, falling back to `CLAUDE.md` when a project has not migrated |
| Parallel reviewers | Three sibling background `subagent` calls, one self-contained prompt each |
| Memory path | `.pi/memory/improve_findings.md` in the project root |
| Language idiom rules | The installed `polish-core/rules/` directory |

## Read previous findings

Read `.pi/memory/improve_findings.md` from the project root. If it does not exist, treat this as the first run and skip comparison with prior findings.

## Dispatch parallel reviewers

Issue three sibling `subagent` calls: semantic/architectural, correctness/quality, and surface/dependencies. Give each call a self-contained `prompt`, a 3–5 word `description`, `subagent_type: deep`, and `run_in_background: true`, because subagents do not share the parent conversation. Repeat the required priming reads, Phase 1 data, finding format, and output contract in every prompt. The correctness/quality agent should read the applicable language file from the installed `polish-core/rules/` directory.

Record every returned agent ID, then poll each with `get_subagent_result({ agent_id, wait: false })`. Poll without blocking unrelated work; after the workflow's collection budget, mark unfinished reports late/incomplete and ignore later notifications rather than claiming those agents were stopped.

## Persist findings

Write `.pi/memory/improve_findings.md`, creating `.pi/memory/` when needed. Preserve the metrics history table, append the latest row, keep the last five rows, update resolved-item statuses, and add new findings.

If `.pi/memory/MEMORY.md` exists, ensure it points to the findings file:

```markdown
- [Improve Findings](improve_findings.md) — Latest codebase review findings and metrics
```

Create `MEMORY.md` with that line when absent.
