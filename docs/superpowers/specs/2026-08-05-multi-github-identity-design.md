# Multi-GitHub-identity routing

Route git and `gh` to the right GitHub account automatically, based on who owns
the remote, so that one machine can hold two identities without any global
switching.

## Problem

This machine has two GitHub identities. The default is the `gambtho` account,
logged in to the standard `~/.config/gh`. A second identity, `guarzo`, owns
three checkouts under `~/workspace` (`binderplan`, `slabledger`, `yetishopify`),
interleaved with a dozen `gambtho` and work repositories.

A partial solution already exists and was built by hand on 2026-02-23: a second
`gh` config directory at `~/.gh-guarzo`, plus repo-local `git config` applied
individually to each of the three repositories, documented in
`~/.gh-guarzo/SETUP.md`. None of it is in this repository, so it is neither
reproducible on a new machine nor protected against drift.

The manual approach has already drifted and already failed:

- `slabledger` sets a bare `credential.helper`; `binderplan` and `yetishopify`
  set the host-scoped `credential.https://github.com.helper`. Same intent, two
  mechanisms, applied by hand three times.
- All three override `user.name` and `user.email` but none overrides
  `user.signingKey`, so all three inherit the default identity's key while
  `commit.gpgSign` is globally true. The three most recent commits verify as
  `G` (good), `E` (error), and `N` (unsigned) respectively — one setting missed
  three times, with three different outcomes.
- The token in `~/.gh-guarzo/hosts.yml` is currently invalid, so `guarzo`
  authentication is broken as of this writing.
- Every new `guarzo` clone requires remembering to repeat the recipe, and
  forgetting it fails silently as the wrong identity.

## Goal

Inside any repository whose remote is owned by `guarzo`, git and `gh` act as
`guarzo` — credentials, commit author, and commit signature. Everywhere else the
default identity applies, unchanged. No global state, no `gh auth switch`, no
per-repository setup step, and nothing personal committed to this public
repository.

## Constraints and evidence

- **This repository is public.** `tests/repository_hygiene.bats` already enforces
  that nothing under `projects/` is tracked. Identity values (email addresses,
  key paths) must not be tracked here. The established pattern is a gitignored
  real file beside a tracked `.example` template: `core/git/gitconfig.local.symlink`
  is listed in `.gitignore` and documented in the README symlink table.
- **git is 2.54.0**, so `includeIf "hasconfig:remote.*.url:…"` (added in 2.36) is
  available.
- **Repo-local config outranks `~/.gitconfig` includes.** The three existing
  repositories therefore shadow any mechanism added here. Unwinding their local
  config is a correctness requirement, not cleanup.
- **Any `*.zsh` file under `core/`, `languages/`, or `tools/` is auto-sourced**
  by `core/shell/load-custom.zsh`, so a new `core/git/identity.zsh` loads with no
  registration step.
- **Claude Code sessions run bash**, not zsh, so a zsh function does not reach
  them. Per-project `.claude/settings.local.json` `env` blocks do; the global
  `ai/claude/settings.json` already uses an `env` block, and the private
  `~/.dotfiles/projects` overlay repository already carries overlays for several
  `guarzo` projects.

### Behaviour verified before adopting the design

Tested against git 2.54.0 with a temporary `HOME` and throwaway repositories:

| Case | Result |
| --- | --- |
| `https://github.com/guarzo/…` remote | routes to the guarzo include |
| `git@github.com:guarzo/…` remote | routes to the guarzo include |
| `https://github.com/gambtho/…` remote | stays on the default identity |
| Linked worktree of a guarzo repo | inherits guarzo |
| Linked worktree nested at `.claude/worktrees/` | inherits guarzo |
| Include file absent | silently ignored, default identity, exit 0 |
| `git credential fill` in a guarzo repo | runs the helper with `GH_CONFIG_DIR` set to the guarzo directory |
| `git credential fill` in a gambtho repo | never invokes the guarzo helper |

The credential-helper rows were exercised against a stub `gh` on `PATH`,
confirming that the `!`-prefixed helper runs through a shell, that `$HOME`
expands inside it, and that the variable reaches the `gh` process — not merely
that git stores the string.

The last row is what makes the tracked wiring safe to publish: on a machine with
no guarzo identity the conditional includes are inert rather than broken.

## Design

Three layers, each with a single responsibility, both enforcement points driven
by one rule — who owns the remote.

### 1. Routing (tracked, public)

`core/git/gitconfig.symlink` gains two conditional includes covering both remote
URL forms:

```
[includeIf "hasconfig:remote.*.url:https://github.com/guarzo/**"]
	path = ~/.gitconfig.guarzo
[includeIf "hasconfig:remote.*.url:git@github.com:guarzo/**"]
	path = ~/.gitconfig.guarzo
```

This is the only tracked change to identity behaviour. It names an account owner
but contains no personal data.

The same file's duplicate `[credential "https://github.com"]` block is collapsed
in the process. Today both `core/git/gitconfig.symlink` and `~/.gitconfig.local`
declare that section, each opening with an empty `helper =` reset; because the
later reset discards everything accumulated before it, the effective helper is
`/usr/bin/gh` (2.45.0, from apt) rather than the `/usr/local/bin/gh` (2.79.0)
that the shell uses. One block survives, referencing `gh` by name and resolving
through `PATH`.

### 2. Identity values (machine-local, gitignored)

`~/.gitconfig.guarzo` links to `core/git/gitconfig.guarzo.symlink`, which is
added to `.gitignore`. It holds:

```
[user]
	name = <account name>
	email = <account email>
	signingKey = /absolute/path/to/.ssh/id_ed25519_guarzo.pub
[credential "https://github.com"]
	helper =
	helper = !GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth git-credential
```

`user.signingKey` is written as an absolute path, matching the existing
`gitconfig.local.symlink` convention, because git does not expand `~` for this
key on every platform.

A tracked `core/git/gitconfig.guarzo.symlink.example` carries the same structure
with placeholders, mirroring the existing `gitconfig.local.symlink.example`.

### 3. `gh` routing

`core/git/identity.zsh` defines a `gh` wrapper function that resolves the current
repository's remote owner and prepends `GH_CONFIG_DIR` for `guarzo` repositories
only. Outside a git repository, or in any repository with another owner, it
delegates to the real `gh` untouched.

For Claude Code sessions, each `guarzo` project's
`.claude/settings.local.json` gains a static `env` block setting
`GH_CONFIG_DIR`, delivered through the private `~/.dotfiles/projects` overlay
repository. A static value is correct there because a given project has exactly
one identity.

### 4. Verification command

`bin/git-identity` reports, for the current repository: the matched owner, the
resolved `user.email` and `user.signingKey`, which `gh` config directory applies,
and whether that directory holds a valid token. It exits zero when the resolved
identity is usable, and non-zero in exactly two cases: the remote owner matches a
configured identity whose token is missing or invalid, or the remote owner
matches an identity whose include file is absent. An unmatched remote owner is
not an error — it is the default identity working as intended.

This exists because every failure mode in this design is silent — a missing
include, an unmatched remote, and an expired token all present as "you are
quietly the default identity." The command turns a silent state into a
one-line answer.

## Data flow

For git, configuration resolves system → `~/.gitconfig` → `~/.gitconfig.local`
(default identity) → `~/.gitconfig.guarzo` (when the remote matches) →
repository-local `.git/config`. After migration the three `guarzo` repositories
hold no identity configuration at all and derive everything from their remote.

For `gh`, the wrapper reads the remote owner and sets `GH_CONFIG_DIR` for that
single invocation. No global state is modified.

## Failure handling

**Clone-time gap.** During `git clone` no remote exists yet, so the default
identity authenticates. Public `guarzo` repositories clone fine; private ones
fail outright, which is a visible failure rather than a subtle one. Documented
workaround, already in use:
`GH_CONFIG_DIR=~/.gh-guarzo gh repo clone guarzo/<repo>`. Every operation after
the remote exists routes correctly, including the first commit, so authorship is
never wrong.

**Invalid or missing token.** Pushes fail with an authentication error rather
than falling back to the other identity. `bin/git-identity` reports it directly.

**`gh` outside a repository.** The wrapper keys off the current repository, so
`gh repo clone guarzo/new` from `~` uses the default identity. Documented, not
solved: solving it would require parsing `gh`'s arguments, which would break on
`gh` releases.

**Machine without a guarzo identity.** The conditional includes reference a
missing file, which git ignores silently; the wrapper finds no config directory
and delegates to real `gh`. A fresh bootstrap is unaffected.

## Manual provisioning

Two steps require the account holder and cannot be automated here. Final
verification is gated on both rather than declared against a dead token.

1. `GH_CONFIG_DIR=~/.gh-guarzo gh auth login`, with `repo` and `workflow`
   scopes. `BROWSER=false` selects the device flow if the browser handoff fails.
2. Generate `~/.ssh/id_ed25519_guarzo`, register the public half on the guarzo
   account **as a signing key** (GitHub keeps authentication and signing keys in
   separate lists), and add a matching line to `~/.ssh/allowed_signers`. That
   file currently holds one entry, bound to the default identity's address,
   which is why signature verification across the three repositories currently
   produces three different results.

## Adjacent fixes in scope

- Collapse the duplicate `[credential "https://github.com"]` blocks (above).
- Repoint `~/.gitconfig.local` at `core/git/gitconfig.local.symlink` and delete
  the stale `git/gitconfig.local.symlink`. The README symlink table and
  `.gitignore` both name the `core/git/` path as canonical; the stale copy is
  untracked only because of a local `.git/info/exclude` entry that no other
  machine shares.
- Replace the address in the tracked
  `core/git/gitconfig.local.symlink.example` with a placeholder. This changes
  `HEAD` only; the address remains in git history and is already public.
- Migrate the three `guarzo` repositories off their repo-local identity config.

## Migration

For each of `binderplan`, `slabledger`, and `yetishopify`: unset the local
`user.name`, `user.email`, and credential helper entries, then confirm that the
values resolved from the conditional include match what the local config
previously set. These repositories are outside this repository and the change is
reversible from the values recorded before removal.

## Testing

A new bats suite follows the existing `setup_dotfiles_test` pattern, using a
temporary `HOME` and throwaway repositories. Nothing in the suite touches a real
token or the network.

- Routing by remote owner over HTTPS and SSH resolves email, signing key, and
  credential helper; a non-`guarzo` remote stays on the default.
- Linked worktrees inherit the routed identity, including one nested at
  `.claude/worktrees/`.
- A missing include file yields the default identity and exit 0.
- `core/git/gitconfig.symlink` contains exactly one
  `[credential "https://github.com"]` block — a regression test for the
  duplicate-block bug.
- `.gitignore` covers `core/git/gitconfig.guarzo.symlink`.
- The `gh` wrapper selects the guarzo config directory for a guarzo remote,
  delegates unchanged for other remotes, and delegates outside a repository.
- `bin/git-identity` reports the routed identity and flags an invalid token,
  exercised against a stub.
- Added to `tests/repository_hygiene.bats`: tracked `core/git/*.example` files
  contain no email address outside the reserved `example.com` /
  `example.invalid` domains, so the scrub cannot regress while templates keep
  their illustrative placeholders.

### Baseline

At the time of writing, `make test` has 60 pre-existing failures across
`tests/dev_commands.bats`, `tests/dev_config_merge.bats`, `tests/dev_install.bats`,
`tests/dev_lifecycle.bats`, and `tests/claude_compose_override.bats`. They
reproduce on `main` and are unrelated to this work. Those five files are the
known-bad set; every other suite must stay green.

## Out of scope

- A registry or generator for arbitrary numbers of identities. The design ships
  exactly one non-default identity, structured so a second is a copy of one
  conditional-include pair plus one gitignored file.
- Rewriting git history to remove the address already published in
  `gitconfig.local.symlink.example`.
- A `PATH` shim intercepting every `gh` invocation machine-wide. Rejected as
  disproportionate: it would route work repositories through the same
  interception layer to solve a problem confined to three personal ones.
- Changing how the default identity authenticates.
- SSH host aliases. The README's current "Multiple GitHub Accounts" section
  documents that approach; it is replaced, because it covers only git transport
  and not `gh`, and requires rewriting each remote URL.
