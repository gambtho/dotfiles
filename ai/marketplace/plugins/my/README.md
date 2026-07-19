# my — personal Claude Code plugin

Custom commands and skills promoted from `~/.dotfiles/ai/` and `~/workspace/slabledger`.

## Contents

### Commands
- `/fix-pr` — analyzes PR comments + failing CI; produces a prioritized implementation plan
- `/polish` — auto-fixes high-confidence issues across changed code, dispatches sub-agents for the rest (thin wrapper over the `polish-core` skill)
- `/polish-pr` — worktree/PR-lifecycle orchestration around polish
- `/review-prs` — batch PR review with cross-run learning

### Skills
- `my:improve` — holistic codebase audit; up to 10 ranked findings (architecture drift, duplicate logic, smells, tests, UX). Reads project conventions from CLAUDE.md or AGENTS.md.
- `my:overnight-improve` — autonomous overnight loop wrapped around `my:improve` + `ralph-loop:ralph-loop`. Reads per-project `.claude/overnight-config.yaml`.
- `my:polish-core` — shared engine behind `/polish`: change-detection, per-language idiom rules (`rules/*.md`), and confidence-classified fixes.
- `my:project-claude-setup` — scaffolds per-project CLAUDE.md / devcontainer AI config.

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
