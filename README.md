# dotfiles

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## Quick Start

```bash
git clone https://github.com/gambtho/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
bin/bootstrap
```

`bin/bootstrap` will:
1. Install OS prerequisites (Homebrew on macOS / apt + zsh + mise on Linux)
2. Set up `.gitconfig.local` from template (prompts for name and email)
3. Prompt for profile selection (`personal` or `work`)
4. Symlink all dotfiles and `config/` directories

On a pristine macOS machine without Homebrew, `bin/bootstrap` needs to run the
upstream Homebrew installer script. That remote installer execution is
disabled by default; review the Homebrew install script source, then opt in
explicitly:

```bash
ALLOW_REMOTE_INSTALLERS=1 bin/bootstrap
```

Without that consent, `bin/bootstrap` fails at the Homebrew install step with
`Remote installer execution is disabled. Re-run with ALLOW_REMOTE_INSTALLERS=1
after reviewing the installer source.`

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
  docs/guides/    # Long-form guides for the tooling in bin/
  archived/       # Dead code — never sourced, kept for reference
  projects/       # NOT tracked here — a separate private repo, cloned by
                  # bin/bootstrap. See docs/guides/project-overlays.md
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

Repositories are routed to a GitHub identity by **remote owner**, not by
per-repo configuration you have to remember to set. `core/git/identity-owners`
is a tracked, non-secret map of `owner slug`:

```
gambtho default
guarzo  guarzo
```

The `default` slug means "use the stock `~/.config/gh` and `~/.gitconfig.local`
— nothing extra to provision." Any other slug (`guarzo`) requires two
machine-local files that this map alone does not create:
`~/.gitconfig.<slug>` and a `~/.gh-<slug>` config directory. That split is
deliberate: the map says which owners this machine *knows about*, independent
of whether they are actually set up, so tooling can tell "unmapped and
unrelated" apart from "known identity but not provisioned."

**How routing works.** `core/git/gitconfig.symlink` carries an
`includeIf "hasconfig:remote.*.url:..."` block per non-default owner, pulling
in `~/.gitconfig.guarzo` only for repositories with a matching remote. That
include path is gitignored and machine-local — the tracked template lives at
`core/git/gitconfig.guarzo.symlink.example`. Copy it to
`core/git/gitconfig.guarzo.symlink` (relinked to `~/.gitconfig.guarzo`) and
fill in the real name, email, and signing key.

`bin/gh` is a PATH shim (installed ahead of the real `gh`, see the symlink
table below) that resolves the current repository's remote owner and exports
`GH_CONFIG_DIR` before exec'ing the real binary — so `gh` behaves correctly
from scripts, editors, and AI tool shells, not just interactive zsh. It
refuses to run rather than guess when a repository has remotes under two
different mapped owners.

`GH_CONFIG_DIR` also partitions **non-repo** `gh` state, not just
credentials: inside a secondary-identity repository, `gh extension list` and
similar commands see that identity's config dir. `gh` extensions installed
under the default identity are not visible there and must be installed again
per identity.

`bin/git-identity` is the diagnostic: run it inside a repository to see which
owner/identity applies and whether it's usable (provisioned, token valid,
transport supported). It's the fastest way to check "why is this behaving
oddly" and is what both `bin/gh` and the pre-push guard point you at on
failure.

A global `pre-push` hook (`core/git/git-hooks.symlink/pre-push`) double-checks
before every push: if the destination owner resolves to a provisioned
identity, it blocks the push when the effective `user.email` or
`user.signingKey` doesn't match what that identity expects. This is the last
line of defense against pushing under the wrong account even if `bin/gh` was
bypassed or the repo's local config drifted.

**Unsupported and detected, not silently mishandled:**
- **SSH remotes** for a routed identity. Git never invokes a credential
  helper over SSH, and `user.signingKey` doesn't select an SSH auth key, so
  SSH remotes bypass this whole mechanism. `bin/git-identity` reports
  `UNSUPPORTED` and tells you to re-point the remote at its `https://` URL.
- **Mixed-owner repositories** (remotes under two different mapped owners,
  e.g. a fork with `origin` under one owner and `upstream` under another).
  `hasconfig` matches any configured remote, not the push target, so this
  can't be routed unambiguously. `bin/gh` refuses to run in either direction.
  The pre-push guard is narrower: it only blocks pushing to the *default*
  owner from a repo whose effective identity resolves to the secondary (the
  fork case) -- pushing to the secondary owner is allowed, since routing
  correctly resolved to that identity. Use an explicit `GH_CONFIG_DIR` (and
  `GH_REPO` if needed) instead.
- **Owner casing.** GitHub owner names are case-insensitive, but git's own
  `includeIf hasconfig:` matching is not, so a differently-cased clone (e.g.
  `Guarzo/repo`) won't pick up the include -- the repo's effective identity
  stays the default. `bin/gh` and the pre-push guard still fold case when
  resolving the destination owner, so they recognise the mismatch and refuse
  rather than silently pushing under the wrong account.

**Manual provisioning steps** (also driven interactively by `bin/bootstrap`'s
secondary-identity prompt, which fills in the template but does not run
either of these for you):

1. Authenticate `gh` into the identity's own config directory, with the
   scopes this design's credential helper needs:
   ```bash
   GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth login --scopes repo,workflow
   ```
2. Generate an SSH key registered on the second GitHub account **as a signing
   key** (Settings → SSH and GPG keys → New SSH key → key type "Signing Key"),
   then add it to `~/.ssh/allowed_signers` so local `git log --show-signature`
   and `git verify-commit` can verify it:
   ```bash
   ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/id_ed25519_guarzo
   echo "you@example.com $(cat ~/.ssh/id_ed25519_guarzo.pub)" >> ~/.ssh/allowed_signers
   ```
   Point `signingKey` in `~/.gitconfig.guarzo` at the **absolute path** to the
   `.pub` file — git does not expand `~` for this setting on every platform.

## Routine Updates

```bash
bin/dot-update    # update packages and language runtimes; restore Neovim plugins to the tracked lockfile
make check        # run syntax, lint, tests, and AI config validation
```

`bin/dot-update` delegates to `bin/install`, which runs `nvim --headless "+Lazy!
restore" +qa` — this restores plugins to match `config/nvim/lazy-lock.json`
exactly. It never advances the lockfile itself.

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

Routine updates (`bin/install`, `bin/dot-update`) only restore plugins to the
versions recorded in `config/nvim/lazy-lock.json`; they never advance that
lockfile. To intentionally update Neovim plugins, open Neovim and run
`:Lazy update` (or `:Lazy sync`) manually, review the resulting diff to
`config/nvim/lazy-lock.json`, and commit it once you're satisfied with the
change.

## Runtime Manager

All language runtimes are managed by [mise](https://mise.jdx.dev/). Versions are defined
in `config/mise/config.toml` (linked to `~/.config/mise/config.toml`).

## Dependency Pins

Run `make pins` to list every managed version and Git ref. Run `make pins-check`
to query upstreams without changing files. Run `make pins-update` to select mise
upgrades interactively, refresh Git refs, run the full test suite, and display
the resulting version diff for review. The Kubernetes channel is
operator-selected: `pins-update` reports Kubernetes channel drift against
upstream but never rewrites `KUBERNETES_CHANNEL` itself — choose and edit a
compatible minor in `config/versions.env` by hand.

## Key Symlinks

| `$HOME` symlink | Source |
|---|---|
| `~/.zshrc` | `core/shell/zshrc.symlink` |
| `~/.gitconfig` | `core/git/gitconfig.symlink` |
| `~/.gitconfig.local` | `core/git/gitconfig.local.symlink` (machine-local, gitignored) |
| `~/.gitconfig.guarzo` | `core/git/gitconfig.guarzo.symlink` (machine-local, gitignored — see [Multiple GitHub Accounts](#multiple-github-accounts)) |
| `~/.bash_profile` | `core/shell/bash_profile.symlink` |
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
- `projects/` is never tracked here. Per-project Claude overlays describe
  non-public codebases and live in a separate private repository that
  `bin/bootstrap` clones to `~/.dotfiles/projects`; a test asserts the boundary.
  See [docs/guides/project-overlays.md](docs/guides/project-overlays.md).

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

Fresh zsh sessions automatically configure both clients when Vekil is ready:

```bash
claude          # through Vekil
codex           # through Vekil
claude-direct   # bypass Vekil for this invocation
codex-direct    # bypass Vekil for this invocation
```

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

### Devcontainer seed drift

`bin/seed-drift` reports, per project and per documented block, whether a
project's `.devcontainer/local-seed.sh` has fallen behind the
`project-claude-setup` template, run ahead of it, or diverged from it.

```bash
bin/seed-drift                       # every project under ~/workspace
bin/seed-drift ~/workspace/myproject # named candidates only
```

It is strictly read-only with respect to the seeds it inspects. Exit codes:
`0` clean, `1` drift found, `2` usage / template / doc / extraction error, or no
projects discovered.

`AHEAD` is a **promotion candidate**, not an error — the seed has something the
template does not, and the seed is the hand-owned file, so the fix direction is
to port it up rather than overwrite it.

The blocks it compares come from the Step 1 table in
`ai/marketplace/plugins/my/skills/project-claude-setup/catch-up-local-seed.md`;
that table is the tool's input, so adding a row there extends the detector.

### Global working agreement

`ai/claude/CLAUDE.md` and `ai/codex/AGENTS.md` hold always-loaded default guidance
(inspect before implementing, blind-spot analysis, evidence-based planning,
thorough verification). Both defer to repository-specific instructions.

### Validation

```bash
bash bin/validate-ai --verbose   # checks plugin command/skill frontmatter
```
