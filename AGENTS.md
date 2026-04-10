# OpenCode Configuration Dotfiles

This repository contains OpenCode (AI coding assistant) configuration, symlinked to `~/.config/opencode/` via `install.sh`.

## Structure

```
opencode/
  opencode.json          # Main config: model, permissions, plugins
  dcp.jsonc              # Dynamic context pruning config
  agents/                # 16 custom subagents (review + implementation)
  commands/              # Slash commands (brainstorm, fix-pr, review-code, etc.)
  skills/                # Custom skills (code-simplifier, ai-firstify, prereq-checker)
  .opencode/             # Plugin dependencies (package.json)
  install.sh             # Symlink setup script (--check for dry-run)
  docs/                  # Specs and implementation plans
```

## Conventions

- **All config lives in this dotfiles repo**, not directly in `~/.config/opencode/`. Changes go here, `install.sh` creates symlinks.
- **Agents** use `mode: subagent`. Review agents are `hidden: true` with `edit: deny` and restricted bash permissions. Implementation agents have broader permissions.
- **Commands that reference skills** should use the `skill` tool to load them, not inline the skill content.
- **Custom agents/commands override superpowers equivalents.** The custom `code-reviewer.md` agent and `brainstorm.md` command intentionally override the versions provided by the superpowers plugin. The custom versions have project-specific enhancements (confidence filtering for the reviewer, OpenCode-specific visual companion paths for brainstorm).

## Working in This Repo

When modifying config files:
1. Edit files in `~/.dotfiles/opencode/`
2. Run `./opencode/install.sh` to update symlinks (or `--check` for dry-run)
3. Restart OpenCode to pick up changes

When adding new skills, create a directory under `opencode/skills/<name>/` with a `SKILL.md` file. The install script will auto-discover and symlink it.

When adding new agents, add a `.md` file under `opencode/agents/`. Follow the existing frontmatter pattern for permissions.
