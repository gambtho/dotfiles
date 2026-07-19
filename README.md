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
  ai/             # AI tools: claude/, codex/, marketplace/, vekil/
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
make check        # run syntax, lint, tests, and AI config validation
```

Run `make check` before pushing changes. Installer tests use temporary home
directories and stubbed commands, so they verify behavior without changing the
developer machine.

## Migrating an Existing Installation

After pulling this modernization, verify the repository, refresh symlinks, and
run the installer:

```bash
git pull
make check
bin/relink
bin/install
exec zsh
```

`bin/relink` removes dead symlinks and recreates links from the current layout.
Remote installer scripts remain disabled by default. After reviewing their
sources, explicitly opt in when a missing tool requires one:

```bash
ALLOW_REMOTE_INSTALLERS=1 bin/install
```

## Neovim

Neovim config lives in `config/nvim/init.lua` (based on [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim)),
symlinked to `~/.config/nvim`. Plugins are bootstrapped via lazy.nvim on first launch.

## Runtime Manager

All language runtimes are managed by [mise](https://mise.jdx.dev/). Versions are defined
in `config/mise/config.toml` (linked to `~/.config/mise/config.toml`).

## Dependency Pins

Run `make pins` to list every managed version and Git ref. Run `make pins-check`
to query upstreams without changing files. Run `make pins-update` to select mise
upgrades interactively, refresh Git refs and the Kubernetes channel, run the full
test suite, and display the resulting version diff for review.

## Key Symlinks

| `$HOME` symlink | Source |
|---|---|
| `~/.zshrc` | `core/shell/zshrc.symlink` |
| `~/.gitconfig` | `core/git/gitconfig.symlink` |
| `~/.gitconfig.local` | `core/git/gitconfig.local.symlink` (machine-local, gitignored) |
| `~/.config/mise/config.toml` | `config/mise/config.toml` |
| `~/.config/nvim` | `config/nvim/` |

## Archived

`archived/` contains old configs no longer in active use:

- `zshrc-saw`, `zpreztorc-saw`, `p10k.zsh-saw` — SAW (Secure Admin Workstation) configs
- `vim-install.sh` — amix/vimrc setup (replaced by kickstart.nvim)
- `aks-mknetrc`, `aks-install-cron.sh` — goms.io PAT token refresh cron (that team is gone)
- `aks-localrc.symlink`, `aks-env.zsh` — goms.io GOPRIVATE/GOPROXY settings
- `localrc` — ssh-agent + goms.io environment
- `script-bootstrap`, `script-install` — old install scripts (replaced by `bin/bootstrap` and `bin/install`)

## Repository Hygiene

- Active configuration must not discover files under `archived/`.
- Machine-local files use a `.local` suffix and remain ignored.
- Generated backups and binaries larger than 5 MiB are not tracked.
- Historical artifacts belong in release storage or a dedicated archive repository.

## AI Coding Assistants

Two AI tools are configured under `ai/` — Claude Code (primary) and Codex CLI —
plus a shared Vekil proxy:

```text
ai/
  marketplace/  # Claude Code plugin marketplace — the 'my' plugin (commands + skills)
  claude/       # Claude Code — settings.json + global CLAUDE.md
  codex/        # Codex CLI — generated config.toml + global AGENTS.md
  vekil/        # Shared GitHub Copilot model proxy for Claude Code + Codex
```

### Setup

```bash
make ai          # install/update all AI tool configs
make ai-check    # dry-run: show what would be linked
```

Or run individually: `ai/claude/install.sh`, `ai/codex/install.sh`,
`ai/marketplace/install.sh`, `ai/vekil/install.sh`. The Vekil installer
authenticates and starts the proxy through `bin/vekil-proxy`, binding to the
Docker bridge when available and falling back to loopback on macOS or when the
bridge cannot be detected.

AI tools are also installed during `bin/install` (Phase 9).

Codex project trust paths are machine-local. Copy entries from
`ai/config-paths.example.toml` to the ignored
`ai/codex/projects.local.toml`; `ai/codex/install.sh` merges them into the
generated user config.

### The `my` plugin (Claude Code)

The personal plugin is the single source of truth for commands and skills. See
`AGENTS.md` for the full inventory. In brief:

- **Commands:** `/fix-pr`, `/polish`, `/polish-pr`, `/review-prs`.
- **Skills:** `improve`, `overnight-improve`, `polish-core`, `project-claude-setup`,
  and the deliberately-invoked `blindspot-pass`, `implementation-plan`,
  `change-explainer`.

### Global working agreement

`ai/claude/CLAUDE.md` and `ai/codex/AGENTS.md` hold always-loaded default guidance
(inspect before implementing, blind-spot analysis, evidence-based planning,
thorough verification). Both defer to repository-specific instructions.

### Validation

```bash
bash bin/validate-ai --verbose   # checks plugin command/skill frontmatter
```
