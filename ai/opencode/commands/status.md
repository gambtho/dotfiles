---
description: Check dotfiles health — symlink integrity, AI tool installation, authentication status, and plugin state
---

# Dotfiles Status Check

Run a comprehensive health check of the dotfiles installation.

## Instructions

Check the following categories and report results grouped by status.

### 1. Symlink Integrity

Verify that key symlinks exist and point to valid targets:

```bash
# Shell
ls -la ~/.zshrc 2>/dev/null
ls -la ~/.zpreztorc 2>/dev/null
ls -la ~/.p10k.zsh 2>/dev/null

# Git
ls -la ~/.gitconfig 2>/dev/null
ls -la ~/.gitconfig.local 2>/dev/null

# Mise
ls -la ~/.mise.local.toml 2>/dev/null

# Neovim
ls -la ~/.config/nvim 2>/dev/null

# OpenCode
ls -la ~/.config/opencode/opencode.json 2>/dev/null
ls -la ~/.config/opencode/agents 2>/dev/null
ls -la ~/.config/opencode/commands 2>/dev/null
ls -la ~/.config/opencode/skills 2>/dev/null
ls -la ~/.config/opencode/dcp.jsonc 2>/dev/null

# Claude
ls -la ~/.claude/commands 2>/dev/null

# Copilot
ls -la ~/.copilot/agents 2>/dev/null
ls -la ~/.copilot/skills 2>/dev/null
```

For each symlink, check:
- Does it exist?
- Is it a symlink (not a regular file/directory)?
- Does the target exist (not a broken symlink)?
- Does the target point into `~/.dotfiles/`?

### 2. AI Tool Installation

Check if AI tools are installed and their versions:

```bash
opencode --version 2>/dev/null || echo "NOT INSTALLED"
claude --version 2>/dev/null || echo "NOT INSTALLED"
```

### 3. Authentication Status

Check auth for tools that require it:

```bash
gh auth status 2>&1 | head -5
cr auth status 2>&1 | head -3 || echo "CodeRabbit CLI not installed"
```

### 4. Plugin Dependencies

Check if OpenCode plugin dependencies are installed:

```bash
ls ~/.config/opencode/.opencode/node_modules/ 2>/dev/null | head -5 || echo "No plugin dependencies installed"
```

### 5. Dotfiles Repo State

```bash
cd ~/.dotfiles && git status --short
cd ~/.dotfiles && git log --oneline -3
```

### 6. Profile

```bash
cat ~/.dotfiles-profile 2>/dev/null || echo "No profile set (defaults to personal)"
```

### 7. Runtime Manager

```bash
mise --version 2>/dev/null || echo "mise NOT INSTALLED"
mise ls 2>/dev/null | head -10
```

## Output Format

```
## Dotfiles Status

### Symlinks
- [OK] ~/.zshrc -> ~/.dotfiles/core/shell/zshrc.symlink
- [OK] ~/.config/opencode/opencode.json -> ~/.dotfiles/ai/opencode/opencode.json
- [BROKEN] ~/.config/nvim -> ~/.dotfiles/config/nvim (target missing)
- [MISSING] ~/.copilot/agents

### AI Tools
- [OK] OpenCode v1.2.3
- [OK] Claude Code v4.5.6
- [MISSING] CodeRabbit CLI

### Auth
- [OK] GitHub CLI authenticated as @username
- [MISSING] CodeRabbit CLI not authenticated

### Plugins
- [OK] 4 plugin dependencies installed

### Repo
- [CLEAN] dotfiles repo is clean
- Latest: abc1234 last commit message

### Profile: personal

### Runtimes
- [OK] mise v2024.x.x
- go 1.22.x
- node 20.x.x
- python 3.12.x
```

Adjust format based on actual findings. Use [OK], [MISSING], [BROKEN], [WARN] prefixes for scanability.
