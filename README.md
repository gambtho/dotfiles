# dotfiles

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## Quick Start

```bash
git clone https://github.com/tng/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
bin/bootstrap
```

`bin/bootstrap` will:
1. Install OS prerequisites (Homebrew on macOS / apt + zsh + mise on Linux)
2. Set up `.gitconfig.local` from template (prompts for name and email)
3. Prompt for profile selection (`personal` or `work`)
4. Symlink all dotfiles and `config/` directories

After bootstrap, run `bin/install` (or `bin/dot-update`) to install packages and language runtimes.

## Structure

```
~/.dotfiles/
  bin/            # Scripts: bootstrap, install, dot-update, relink, helpers
  core/           # Always loaded: shell (zsh/prezto/p10k), git, path, env
  languages/      # Runtime tooling: go, ruby, python, rust, mise
  tools/          # Tool configs: docker, kubernetes
  platforms/      # OS-specific: linux/, macos/, windows/
  work/           # Work context: only sourced when work profile is active
  ai/             # AI tools: opencode/, claude/, copilot/
  profiles/       # Machine profiles: personal.zsh, work.zsh
  config/         # XDG config files, symlinked to ~/.config/<name>
  archived/       # Dead code — never sourced, kept for reference
```

## Profile System

Create `~/.dotfiles-profile` (not git-tracked) to select which profile is active:

```bash
echo "personal" > ~/.dotfiles-profile   # or "work"
```

`bin/bootstrap` prompts for this on first run. The `work` profile sources `work/*.zsh`,
which contains Microsoft/AKS-specific aliases and tooling. All `work/*.zsh` files also
self-guard with `[[ -z "$WORK_PROFILE" ]] && return` to prevent accidental loading.

## Multiple GitHub Accounts

If this repo needs to use a different GitHub account than your default, use an SSH host alias.

**1. Generate a key for the second account**
```bash
ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/id_ed25519_work
```
Add `~/.ssh/id_ed25519_work.pub` to that GitHub account under Settings → SSH keys.

**2. Add a host alias to `~/.ssh/config`**
```
Host github-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
```

**3. Update the repo remote to use the alias**
```bash
git remote set-url origin git@github-work:gambtho/dotfiles.git
```

**Verify:**
```bash
ssh -T git@github-work
# Hi gambtho! You've successfully authenticated...
```

## Routine Updates

```bash
bin/dot-update    # update packages, language runtimes, neovim plugins
```

## After Pulling a Restructure

If you pull changes that moved `.symlink` files to new directories, run:

```bash
bin/relink
```

This removes dead symlinks (pointing to paths that no longer exist) and re-creates all
symlinks from the current repo layout.

## Neovim

Neovim config lives in `config/nvim/init.lua` (based on [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim)),
symlinked to `~/.config/nvim`. Plugins are bootstrapped via lazy.nvim on first launch.

## Runtime Manager

All language runtimes are managed by [mise](https://mise.jdx.dev/). Versions are defined
in `languages/mise/mise.local.toml.symlink` (symlinked to `~/.mise.local.toml`).

## Key Symlinks

| `$HOME` symlink | Source |
|---|---|
| `~/.zshrc` | `core/shell/zshrc.symlink` |
| `~/.gitconfig` | `core/git/gitconfig.symlink` |
| `~/.gitconfig.local` | `core/git/gitconfig.local.symlink` (machine-local, gitignored) |
| `~/.mise.local.toml` | `languages/mise/mise.local.toml.symlink` |
| `~/.config/nvim` | `config/nvim/` |

## Archived

`archived/` contains old configs no longer in active use:

- `zshrc-saw`, `zpreztorc-saw`, `p10k.zsh-saw` — SAW (Secure Admin Workstation) configs
- `vim-install.sh` — amix/vimrc setup (replaced by kickstart.nvim)
- `aks-mknetrc`, `aks-install-cron.sh` — goms.io PAT token refresh cron (that team is gone)
- `aks-localrc.symlink`, `aks-env.zsh` — goms.io GOPRIVATE/GOPROXY settings
- `localrc` — ssh-agent + goms.io environment
- `script-bootstrap`, `script-install` — old install scripts (replaced by `bin/bootstrap` and `bin/install`)

## AI Coding Assistants

Three AI tools are configured under `ai/`, with OpenCode as the primary tool:

```
ai/
  opencode/     # Primary — 18 agents, 9 commands, 3 skills, DCP, plugins
  claude/       # Claude Code — thin wrapper commands over OpenCode versions
  copilot/      # GitHub Copilot CLI — independent MCP-based implementations
```

### Setup

```bash
make ai          # install/update all AI tool configs
make ai-check    # dry-run: show what would be linked
```

Or run individually: `ai/opencode/install.sh`, `ai/claude/install.sh`, `ai/copilot/install.sh`.

AI tools are also installed during `bin/install` (Phase 9).

### OpenCode Agents

**Review agents** (read-only, hidden from agent list):
`code-reviewer`, `reviewer`, `comment-analyzer`, `silent-failure-hunter`,
`code-explorer`, `type-design-analyzer`, `cr-reviewer`,
`react-reviewer`, `frontend-reviewer`, `ts-patterns`, `go-idioms`,
`ruby-conventions`, `elixir-otp`, `python-reviewer`, `rust-reviewer`

**Implementation agents** (can edit files):
`implementer` (fast, Haiku-based), `react-developer`, `frontend-developer`

### OpenCode Commands

| Command | Description |
|---------|-------------|
| `/brainstorm` | Structured brainstorm -> spec -> plan -> implement workflow |
| `/review-code` | Review changes since a commit (dispatches specialized agents) |
| `/review-prs` | Batch-review open PRs with learning and persistent knowledge |
| `/fix-pr` | Analyze PR comments/CI failures, produce implementation plan |
| `/cr-review` | Run CodeRabbit CLI review with fix-and-verify loop |
| `/simplify` | Simplify recently modified code (loads language-specific rules) |
| `/ai-firstify` | Audit/re-engineer a project for AI-first design |
| `/prereqs` | Check tool availability for current project |
| `/status` | Health check: symlinks, auth, plugins, runtimes |

### OpenCode Skills

- **code-simplifier** — Language-specific simplification rules (7 languages)
- **ai-firstify** — AI-first design principles with audit/bootstrap/re-engineer modes
- **prereq-checker** — Tool availability checking with install suggestions

### Per-Project Config

OpenCode automatically merges project-level `opencode.json` with the global config.
Drop an `opencode.json` in any project root to override model, permissions, or plugins
for that project. See [OpenCode config docs](https://opencode.ai/docs/config/) for details.
