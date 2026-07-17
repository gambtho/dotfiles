# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages configuration for two AI coding assistants (Claude Code
and Codex CLI) plus a shared model proxy, under `ai/`:

```text
ai/
  marketplace/               # Claude Code plugin marketplace (canonical for commands/skills)
    install.sh               # Registers 'guarzo' marketplace, installs the 'my' plugin
    plugins/my/              # The 'my' personal plugin (see below)
  claude/                    # Claude Code
    settings.json            # Permissions, enabled plugins, effort, compact prompt
    CLAUDE.md                # Global always-loaded working agreement
    install.sh
  codex/                     # Codex CLI
    config.toml              # Default Vekil model
    AGENTS.md                # Global always-loaded working agreement (Codex)
    install.sh
  vekil/                     # Shared Copilot model proxy for Claude Code + Codex
    env.zsh                  # Auto-selects host/devcontainer endpoint
    install.sh               # Pinned install, managed auth, lifecycle startup
```

Configuration is symlinked into `~/.claude/` and `~/.codex/` by the respective
install scripts. Run `make ai` or individual `ai/*/install.sh` scripts.

Vekil is installed and started only through `ai/vekil/install.sh` and `bin/vekil-proxy`. Its credentials and runtime state are machine-local under `~/.config/vekil/` and `~/.local/state/vekil/`, but their lifecycle is repository-managed. The proxy binds to the Docker bridge when available so devcontainers can use `host.docker.internal` without exposing it on every interface.

## The `my` Plugin

`ai/marketplace/plugins/my/` is the personal plugin for Claude Code, installed via
the `guarzo` local marketplace. It is the single source of truth for personal
commands and skills.

### Commands
- `/fix-pr` — collects open PR review comments and failing CI, then writes a
  detailed implementation plan under `~/.claude/pr-fix-plans/`.
- `/polish` — analyzes changed code, auto-fixes high-confidence issues with
  `--fix`, reports the rest (thin wrapper over the `polish-core` skill).
- `/polish-pr` — checks a PR into a worktree, runs `/polish --fix`, commits, and
  prompts before pushing back.
- `/review-prs` — batch-reviews open PRs with no human comments; accumulates
  learnings under `~/.claude/pr-reviews/`.

### Skills
- `my:improve` — holistic codebase audit returning up to 10 ranked findings.
- `my:overnight-improve` — autonomous overnight loop around `my:improve`; requires
  `ralph-loop:ralph-loop`.
- `my:polish-core` — shared engine behind `/polish`; reads per-language idiom
  rules from its own `rules/` directory.
- `my:project-claude-setup` — scaffolds per-project CLAUDE.md / devcontainer config.
- `my:blindspot-pass` — pre-implementation risk surface (deliberate invocation).
- `my:implementation-plan` — evidence-based implementation plan (deliberate).
- `my:change-explainer` — reviewer-facing write-up of a completed change (deliberate).

## Conventions

- **The `my` plugin is canonical.** Commands and skills are fully self-contained;
  they do not delegate to versions in other tools.
- **Language rules live in `ai/marketplace/plugins/my/skills/polish-core/rules/`.**
  Both `/polish` (via `polish-core`) and `my:improve` read them from there.
- **All config lives in this dotfiles repo**, not directly in target directories.
  Changes go here; install scripts create symlinks.
- **Global working agreements** are `ai/claude/CLAUDE.md` and `ai/codex/AGENTS.md`.
  They are always-loaded default guidance and defer to repository-specific
  instructions. Keep the two substantially in sync.

## Working in This Repo

When modifying plugin commands or skills, edit files directly under
`ai/marketplace/plugins/my/`. Changes take effect on the next Claude session — no
reinstall needed.

When adding a new skill to the plugin:
1. Create `ai/marketplace/plugins/my/skills/<name>/SKILL.md` with `name` and
   `description` frontmatter.
2. Run `bash bin/validate-ai` to check structure.

When changing global guidance, edit `ai/claude/CLAUDE.md` and/or
`ai/codex/AGENTS.md`, then run `make ai` (or the relevant install script) to
refresh the symlinks.
