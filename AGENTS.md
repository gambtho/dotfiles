# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages configuration for three AI coding assistants under `ai/`:

```
ai/
  marketplace/               # Claude Code plugin marketplace (canonical for commands/skills/agents)
    install.sh               # Registers 'guarzo' marketplace, installs 'my' plugin, bridges to other tools
    plugins/my/              # The 'my' personal plugin (see below)
  opencode/                  # OpenCode
    opencode.json            # Main config: model, permissions, plugins
    dcp.jsonc                # Dynamic context pruning config
    agents/                  # Subagents (review + implementation)
    commands/                # Slash commands (brainstorm, fix-pr, polish, etc.)
    skills/                  # Custom skills (code-simplifier, ai-firstify, prereq-checker)
    .opencode/               # Plugin dependencies (package.json)
    install.sh               # Symlink setup script (--check for dry-run)
  claude/                    # Claude Code (non-plugin config)
    install.sh
  copilot/                   # GitHub Copilot CLI
    agents/                  # Agent definitions (independent implementations)
    skills/                  # Skills
    install.sh
```

Configuration is symlinked to `~/.config/opencode/`, `~/.claude/`, and `~/.copilot/` by the respective install scripts. Run `make ai` or individual `ai/*/install.sh` scripts.

## The `my` Plugin

`ai/marketplace/plugins/my/` is the primary personal plugin for Claude Code. It is installed via the `guarzo` local marketplace and contains:

### Commands (Claude Code only)
- `/fix-pr` — collects all open PR review comments and failing CI checks, then writes a detailed implementation plan to `~/.claude/pr-fix-plans/{OWNER}/{REPO}/pr-{N}-plan.md`
- `/polish` — analyzes changed code, auto-fixes high-confidence issues with `--fix`, reports the rest
- `/polish-pr` — checks out a PR into a worktree, runs `/polish --fix` against it, commits, and prompts before pushing back to the PR branch
- `/review-prs` — batch-reviews open PRs with no human comments; learns review style from merged PRs and accumulates findings across runs in `~/.claude/pr-reviews/{OWNER}/{REPO}/`

### Skills
- `my:improve` — holistic codebase audit returning up to 10 ranked findings (architecture drift, duplicate logic, code smells, tests, UX). Platform-aware: works in both Claude Code and OpenCode.
- `my:new-api-client` — scaffolds a new external API client in a Go hexagonal-architecture project (domain interface + adapter package + httpx client + tests)
- `my:overnight-improve` — autonomous overnight loop: runs `my:improve`, picks the top finding, fixes it, runs verification gates, commits or rolls back. Requires `ralph-loop:ralph-loop` and `--permission-mode bypassPermissions`.

### Agents
- `ux-react` — senior UI engineer focused on Nielsen usability heuristics, WCAG 2.1 AA accessibility, and modern React patterns. Distinct from `frontend-design` (visual aesthetics) and `vercel:react-best-practices` (Next.js performance).

### Cross-tool bridging
The install script symlinks `skills/` and `agents/` into `~/.config/opencode/` and `~/.copilot/` so those tools can use them too. Commands are NOT bridged — each tool has its own command format. The OpenCode versions of `/fix-pr`, `/polish`, and `/review-prs` live in `ai/opencode/commands/` as independent implementations.

## Conventions

- **Plugin is canonical for Claude Code.** Commands in `ai/marketplace/plugins/my/commands/` are fully self-contained — they do not delegate to OpenCode versions. Each command embeds its complete workflow.
- **Language rules live in `ai/opencode/skills/code-simplifier/rules/`.** Both the plugin's `/polish` command and `my:improve` skill read language rules from this path (e.g. `go.md`, `typescript.md`). Do not move them.
- **All config lives in this dotfiles repo**, not directly in target directories. Changes go here; install scripts create symlinks.
- **Agents** use `mode: subagent`. Review agents are `hidden: true` with `edit: deny` and restricted bash permissions. Implementation agents have broader permissions.
- **Commands that reference skills** should use the `skill` tool to load them, not inline the skill content.
- **Custom agents/commands override superpowers equivalents.** The custom `code-reviewer.md` agent and `brainstorm.md` command intentionally override the versions provided by the superpowers plugin.

## Working in This Repo

When modifying plugin commands or skills, edit files directly under `ai/marketplace/plugins/my/`. Changes take effect on the next Claude session — no reinstall needed.

When modifying OpenCode-only config, edit files under `ai/opencode/` and run `ai/opencode/install.sh` (or `make ai`) to refresh symlinks.

When adding new skills to the plugin:
1. Create `ai/marketplace/plugins/my/skills/<name>/SKILL.md`
2. Re-run `ai/marketplace/install.sh` to bridge the new skill to OpenCode/Copilot

When adding new agents to the plugin:
1. Add `ai/marketplace/plugins/my/agents/<name>.md` with appropriate frontmatter
2. Re-run `ai/marketplace/install.sh` to bridge it
