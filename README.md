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
  ai/             # Pi configuration and personal prompt/skill package
  profiles/       # Machine profiles: personal.zsh, work.zsh
  config/         # XDG config files, symlinked to ~/.config/<name>
  docs/guides/    # Long-form guides for the tooling in bin/
```

## Profile System

Create `~/.dotfiles-profile` (not git-tracked) to select which profile is active:

```bash
echo "personal" > ~/.dotfiles-profile   # or "work"
```

`bin/bootstrap` prompts for this on first run. The `work` profile sources every
`work/*.zsh` on disk. Tracked files there hold only generic tooling (paths, krew,
apt repositories); employer-specific aliases, identities, and endpoints belong in
a machine-local `work/*.local.zsh` (gitignored — copy
`work/aliases.local.zsh.example` to get started). All `work/*.zsh` files
self-guard with `[[ -z "$WORK_PROFILE" ]] && return` to prevent accidental loading.

## Multiple GitHub Accounts

Repositories are routed to a GitHub identity by **remote owner**, not by
per-repo configuration you have to remember to set. `core/git/identity-owners`
is a tracked, non-secret map of `owner slug`. The tracked map ships with only
the primary account; a machine with a second account adds it there — or, to
keep the pairing off the public record, in the gitignored
`identity-owners.local` (see [Per-machine identity roles](#per-machine-identity-roles)):

```
gambtho default
alt     alt
```

The `default` slug means "use the stock `~/.config/gh` and `~/.gitconfig.local`
— nothing extra to provision." Any other slug (`alt`) requires two
machine-local files that this map alone does not create:
`~/.gitconfig.<slug>` and a `~/.gh-<slug>` config directory. That split is
deliberate: the map says which owners this machine *knows about*, independent
of whether they are actually set up, so tooling can tell "unmapped and
unrelated" apart from "known identity but not provisioned."

**How routing works.** `bin/relink` generates one
`includeIf "hasconfig:remote.*.url:..."` block per non-default owner in the
**active** map into the gitignored `~/.gitconfig.identity-routes`, which
`core/git/gitconfig.symlink` includes. Generated rather than tracked because the
map is per-machine: a hardcoded owner would name the wrong account on a machine
that flips the roles, leaving the other identity silently unrouted. Re-run
`bin/relink` after changing the map. Each block pulls in `~/.gitconfig.<slug>`
only for repositories with a matching remote. That
include path is gitignored and machine-local — the tracked template lives at
`core/git/gitconfig.secondary.symlink.example`, which is slug-agnostic.
`bin/bootstrap` renders it per non-`default` slug into
`core/git/gitconfig.<slug>.symlink` (relinked to `~/.gitconfig.<slug>`); to do
it by hand, copy the template, replace `IDENTITY_SLUG` with the slug, and fill
in the real name, email, and absolute signing-key path.

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
oddly". When an identity is mapped but not provisioned, it — like `bin/gh` and
the pre-push guard — prints the commands that finish provisioning rather than
just naming the gap: `bin/relink` when the identity file is authored but not
yet linked into `$HOME`, `bin/bootstrap` when it hasn't been authored at all,
and `GH_CONFIG_DIR=$HOME/.gh-<slug> gh auth login --scopes repo,workflow` for a
missing `gh` config dir.

`NOT ROUTED` — the identity is provisioned but git resolves a different
`user.email` or `user.signingKey` — has two causes with opposite repairs, and
the diagnostic names whichever applies: a missing conditional include (fixed by
`bin/relink`), or a `local`/`worktree`-scope value set in the repository itself,
which outranks every include and is fixed by `git config --local --unset
user.email`. The pre-push guard names the same cause when it blocks.

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
  `Alt/repo`) won't pick up the include -- the repo's effective identity
  stays the default. `bin/gh` and the pre-push guard still fold case when
  resolving the destination owner, so they recognise the mismatch and refuse
  rather than silently pushing under the wrong account.

**Manual provisioning steps** (also driven interactively by `bin/bootstrap`'s
secondary-identity prompt, which fills in the template but does not run
either of these for you):

1. Authenticate `gh` into the identity's own config directory, with the
   scopes this design's credential helper needs:
   ```bash
   GH_CONFIG_DIR=$HOME/.gh-alt gh auth login --scopes repo,workflow
   ```
2. Generate an SSH key registered on the second GitHub account **as a signing
   key** (Settings → SSH and GPG keys → New SSH key → key type "Signing Key"),
   then add it to `~/.ssh/allowed_signers` so local `git log --show-signature`
   and `git verify-commit` can verify it:
   ```bash
   ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/id_ed25519_alt
   echo "you@example.com $(cat ~/.ssh/id_ed25519_alt.pub)" >> ~/.ssh/allowed_signers
   ```
   Point `signingKey` in `~/.gitconfig.alt` at the **absolute path** to the
   `.pub` file — git does not expand `~` for this setting on every platform.

### Per-machine identity roles

`core/git/identity-owners` records *roles* — which account is this machine's
ambient default, and which need their own routed identity. Roles differ between
machines: an account that is secondary on one may be the ambient default on
another. Four sources are consulted, highest precedence first, and the first one
that exists **replaces** the others outright (they are never merged):

| Source | Scope |
| --- | --- |
| `$IDENTITY_MAP_FILE` | explicit override, for tests and one-offs |
| `core/git/identity-owners.local` | this machine only (gitignored) |
| `core/git/identity-owners.<profile>` | machines sharing that `~/.dotfiles-profile` |
| `core/git/identity-owners` | the shared default |

Replace rather than merge is deliberate: merging would let a machine silently
inherit another machine's roles, which is the failure this design exists to
prevent. List every owner the machine should know — one you leave out becomes
unmapped, so nothing routes it and nothing blocks it.

`bin/bootstrap` offers to write the local map, or copy
`identity-owners.local.example` by hand. It then offers to provision each
non-`default` slug the map names, rendering
`gitconfig.secondary.symlink.example` into `core/git/gitconfig.<slug>.symlink`
(gitignored) and pointing you at `GH_CONFIG_DIR=$HOME/.gh-<slug> gh auth login`.
Which account is secondary differs per machine, so the prompts follow the map
rather than a fixed account name. `bin/git-identity` prints the map
actually in effect, which is the first thing to check when routing surprises you
on a particular machine.

Provisioning is two independent halves, and an identity is only usable with
both: the git include (`core/git/gitconfig.<slug>.symlink`, authored by
`bin/bootstrap` and linked into `$HOME` by its symlink step — `bin/relink`
re-links it on its own) and the `gh` config dir (`$HOME/.gh-<slug>`, created
only by that `gh auth login`). Bootstrap authoring the file does not link it,
so a run interrupted between those two steps leaves an identity that exists in
the repo but not in `$HOME`.

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

## Terminal Theme (WSL)

On WSL, `bin/install` applies the Tokyo Night color scheme to Windows Terminal
(`platforms/windows/wt-color-scheme.sh`), so the terminal matches Herdr's UI
theme and Neovim's `tokyonight-night`. Windows Terminal ships no Tokyo Night
built-in and otherwise falls back to Campbell.

The scheme becomes the default for every profile. Profiles that set their own
`colorScheme` keep it, and the script names them when it finishes. It is
idempotent — re-runs exit early once applied — and it backs up `settings.json`
before rewriting it. A `settings.json` containing comments is refused rather
than mangled, since `jq` cannot round-trip JSONC.

Run it by hand with `--dry-run` to preview the diff, or `--check` to test
whether it has been applied:

```bash
platforms/windows/wt-color-scheme.sh --check
```

If several directories exist under `/mnt/c/Users` (Entra-joined machines
usually carry service-account directories alongside the real one), discovery is
ambiguous. Pick one with `--win-user NAME`, or set `WT_WINDOWS_USER` in
`~/.localrc` (sourced by `core/shell/load-custom.zsh`) so the install phase
resolves it unattended:

```bash
echo 'export WT_WINDOWS_USER=yourname' >> ~/.localrc
```

Without it, the install phase warns and is skipped rather than prompting.

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
| `~/.gitconfig.<slug>` | `core/git/gitconfig.<slug>.symlink` (machine-local, gitignored — see [Multiple GitHub Accounts](#multiple-github-accounts)) |
| `~/.bash_profile` | `core/shell/bash_profile.symlink` |
| `~/.config/mise/config.toml` | `config/mise/config.toml` |
| `~/.config/nvim` | `config/nvim/` |

## Reaping Merged Worktrees

`bin/git-worktree-gc` removes linked worktrees whose branch has already landed.
Because `bin` is on `PATH`, Git resolves it as a subcommand:

```bash
git worktree-gc                          # dry run: print the plan, change nothing
git worktree-gc --yes                    # remove the worktrees it listed
git worktree-gc --yes --delete-branches  # and delete their branches
```

Merge detection reads `git branch --merged` *and* `gh pr list --state merged`.
The second source is what makes it useful in a squash-merge repository, where
a shipped branch is never an ancestor of `main` and ancestry alone reports
almost everything as unmerged. Without `gh`, the script says so and falls back
to ancestry rather than reporting a clean sweep.

The main worktree, the one you are standing in, detached-HEAD worktrees, and
anything with uncommitted changes are never removed. Locked worktrees are
skipped unless `--include-locked`, which unlocks each before removing it.

## Repository Hygiene

- Active configuration must not discover files under `archived/`.
- Machine-local files use a `.local` suffix and remain ignored.
- Generated backups and binaries larger than 5 MiB are not tracked.
- Historical artifacts belong in release storage or a dedicated archive repository.

## AI Coding Agent

Pi is the only repository-managed coding-agent harness:

```text
ai/
  pi/                     # settings, global guidance, keybindings, extensions, installer
  marketplace/plugins/my/ # local Pi package containing prompts and skills
```

### Setup

```bash
make ai          # install pinned Pi, link config, and reconcile packages
make ai-check    # dry-run without changing the machine
```

The full installer also runs Pi setup during Phase 9. Authentication remains machine-local: start `pi`, run `/login`, and choose **GitHub Copilot**. Use `/model` to select any Copilot model enabled for the subscription and Ctrl+S to save the highlighted model as the default.

The installer links the authored extension directory, and `ai/pi/settings.json` loads the local `my` package. The guard blocks Pi's direct file-write tools in primary checkouts; use a linked worktree, or place an intentional exception in `~/.pi/worktree-guard-allow`.

The personal package provides `/fix-pr`, `/polish`, `/polish-pr`, `/review-prs`, and `/second-opinion`, plus the `improve`, `overnight-improve`, `polish-core`, `blindspot-pass`, `implementation-plan`, and `change-explainer` skills. See `AGENTS.md` and `ai/marketplace/plugins/my/README.md` for details.

Pi's always-loaded global working agreement is `ai/pi/AGENTS.md`; project instructions override it through repository `AGENTS.md` files. Remote browser access is an opt-in [Pi Web UI](ai/pi/webui/README.md).

### Validation

```bash
bash bin/validate-ai --verbose   # checks Pi prompt/skill frontmatter and manifest coverage
```

## Origins

This repository began as a fork of [holman/dotfiles](https://github.com/holman/dotfiles)
and has since been rebuilt around its own installer, test suite, and AI tooling.
The topic-directory layout and the `*.symlink` convention survive from Zach
Holman's original design, and his copyright notice is retained in
[LICENSE.md](LICENSE.md) alongside this repository's own.
