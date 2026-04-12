# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages configuration for three AI coding assistants under `ai/`:

```
ai/
  opencode/                # OpenCode (primary AI tool)
    opencode.json          # Main config: model, permissions, plugins
    dcp.jsonc              # Dynamic context pruning config
    agents/                # 16+ custom subagents (review + implementation)
    commands/              # Slash commands (brainstorm, fix-pr, polish, etc.)
    skills/                # Custom skills (code-simplifier, ai-firstify, prereq-checker)
    .opencode/             # Plugin dependencies (package.json)
    install.sh             # Symlink setup script (--check for dry-run)
  claude/                  # Claude Code
    commands/              # Slash commands (thin wrappers around OpenCode versions)
    install.sh
  copilot/                 # GitHub Copilot CLI
    agents/                # Agent definitions (MCP-based, independent implementations)
    skills/                # Skills
    install.sh
```

Configuration is symlinked to `~/.config/opencode/`, `~/.claude/`, and `~/.copilot/` by the respective install scripts. Run `make ai` or individual `ai/*/install.sh` scripts.

## Conventions

- **All config lives in this dotfiles repo**, not directly in target directories. Changes go here, install scripts create symlinks.
- **Agents** use `mode: subagent`. Review agents are `hidden: true` with `edit: deny` and restricted bash permissions. Implementation agents have broader permissions.
- **Commands that reference skills** should use the `skill` tool to load them, not inline the skill content.
- **Custom agents/commands override superpowers equivalents.** The custom `code-reviewer.md` agent and `brainstorm.md` command intentionally override the versions provided by the superpowers plugin. The custom versions have project-specific enhancements (confidence filtering for the reviewer, OpenCode-specific visual companion paths for brainstorm).
- **OpenCode commands are canonical.** Claude Code commands are thin wrappers that adapt the OpenCode versions for Claude's tool API. Copilot agents are independent implementations using MCP tools.

## Working in This Repo

When modifying AI config files:
1. Edit files in `~/.dotfiles/ai/opencode/` (or `ai/claude/`, `ai/copilot/`)
2. Run `make ai` to update all symlinks, or `ai/opencode/install.sh --check` for dry-run
3. Restart the AI tool to pick up changes

When adding new skills, create a directory under `ai/opencode/skills/<name>/` with a `SKILL.md` file. The install script will auto-discover and symlink it.

When adding new agents, add a `.md` file under `ai/opencode/agents/`. Follow the existing frontmatter pattern for permissions.
