# my — personal Claude Code plugin

Custom commands, skills, and agents promoted from `~/.dotfiles/ai/` and `~/workspace/slabledger`.

## Contents

### Commands (Claude Code only)
- `/fix-pr` — analyzes PR comments + failing CI; produces a prioritized implementation plan
- `/polish` — auto-fixes high-confidence issues across changed code, dispatches sub-agents for the rest
- `/review-prs` — batch PR review with cross-run learning

### Skills
- `my:improve` — holistic codebase audit; up to 10 ranked findings (architecture drift, duplicate logic, smells, tests, UX). Reads project conventions from CLAUDE.md.
- `my:new-api-client` — scaffolds a new external API client in a Go hexagonal-architecture project. Reads `go.mod` for the module path.
- `my:overnight-improve` — autonomous overnight loop wrapped around `my:improve` + `ralph-loop:ralph-loop`. Reads per-project `.claude/overnight-config.yaml`.

### Agents
- `ux-react` — usability + React idiom expert (Nielsen heuristics, WCAG 2.1 AA, modern hooks). Distinct from `frontend-design` (visual aesthetics) and `vercel:react-best-practices` (Next.js performance).

## Cross-tool compatibility

The plugin's `skills/` and `agents/` are bridged to OpenCode (`~/.config/opencode/{skills,agents}/`) and Copilot (`~/.copilot/{skills,agents}/`) via symlinks added by `../../install.sh`. Compatibility is best-effort — Claude-specific tools (parallel `Agent` dispatch, marketplace plugin invocations like `ralph-loop:ralph-loop`) will degrade or no-op outside Claude Code.

| Skill / agent | Claude Code | OpenCode | Copilot |
|---|---|---|---|
| `my:new-api-client` | yes | yes | yes |
| `ux-react` (agent) | yes | yes | yes |
| `my:improve` | yes | degraded (parallel `Agent` dispatch is CC-specific) | degraded |
| `my:overnight-improve` | yes | no — requires `ralph-loop:ralph-loop` plugin | no |

Commands (`/fix-pr`, `/polish`, `/review-prs`) are NOT bridged — OpenCode and Copilot use platform-specific syntax that's not symlink-compatible. The legacy `~/.dotfiles/ai/opencode/commands/` and `~/.dotfiles/ai/copilot/agents/*.agent.md` versions remain in place for those tools.

## Install

From the dotfiles root:

```bash
make ai
# or just this plugin:
bash ~/.dotfiles/ai/marketplace/install.sh
```

The install adds the `guarzo` marketplace and installs the `my` plugin. Local edits to files under `~/.dotfiles/ai/marketplace/plugins/my/` take effect on the next Claude session — no reinstall needed.

## Source

`~/.dotfiles/ai/marketplace/plugins/my/`
