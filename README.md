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
