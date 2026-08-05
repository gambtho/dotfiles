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

In any repository whose GitHub remotes are owned by `guarzo`, git and `gh` act as
`guarzo` — credentials, commit author, and commit signature. Everywhere else the
default identity applies, unchanged. No global state, no `gh auth switch`, and
nothing personal committed to this public repository.

Where the routing cannot be made automatic, the wrong identity must fail loudly
rather than silently. That principle drives the pre-push guard below, and it is
the reason several honest limitations are documented rather than papered over.

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
- **Global hooks must fail open.** `core/git/git-hooks.symlink/pre-push` carries
  an extended comment explaining that `core.hooksPath` is global, so a hook that
  errors breaks every repository on the machine, including ones unrelated to the
  feature. Any hook added here inherits that constraint.
- **`~/.dotfiles/bin` precedes `/usr/local/bin`** in both zsh and bash, so an
  executable placed there shadows the real `gh`.

### Behaviour verified before adopting the design

Tested against git 2.54.0 with a temporary `HOME` and throwaway repositories.

| Case | Result |
| --- | --- |
| `https://github.com/guarzo/…` remote | routes to the guarzo include |
| `https://github.com/gambtho/…` remote | stays on the default identity |
| Linked worktree of a guarzo repo | inherits guarzo |
| Linked worktree nested at `.claude/worktrees/` | inherits guarzo |
| Include file absent | silently ignored, default identity, exit 0 |
| `git credential fill` in a guarzo repo | runs the helper with `GH_CONFIG_DIR` set to the guarzo directory |
| `git credential fill` in a gambtho repo | never invokes the guarzo helper |
| `origin`=gambtho + `upstream`=guarzo, `remote.pushDefault=origin` | **routes to guarzo** — see below |
| `hasconfig:remote.origin.url:…` (narrowed matcher) | matches nothing, silently; not a supported keyword |
| `ssh://git@github.com/guarzo/…` remote | does **not** match the scp-style glob |
| `~/.dotfiles/bin` on `PATH` in `env -i bash -l` | **absent** — only inherited from a zsh parent |

The credential-helper rows were exercised against a stub `gh` on `PATH`,
confirming that the `!`-prefixed helper runs through a shell, that `$HOME`
expands inside it, and that the variable reaches the `gh` process — not merely
that git stores the string.

The "include file absent" row is what makes the tracked wiring safe to publish:
on a machine with no guarzo identity the conditional includes are inert rather
than broken.

The last four rows are load-bearing limitations discovered in review, and each
one shapes the design below.

## Design

Five components. Routing is declarative and covers the common case; a guard
converts the cases routing cannot cover from silent to loud.

### 1. Routing (tracked, public)

`core/git/gitconfig.symlink` gains one conditional include:

```
[includeIf "hasconfig:remote.*.url:https://github.com/guarzo/**"]
	path = ~/.gitconfig.guarzo
```

This is the only tracked change to identity behaviour. It names an account owner
but contains no personal data.

**`hasconfig` matches any configured remote, not the push target.** This was
verified: a repository with `origin` owned by `gambtho` and `upstream` owned by
`guarzo` resolves to the guarzo identity even with `remote.pushDefault=origin`.
The matcher cannot be narrowed — `hasconfig:remote.origin.url:` is not a
supported keyword and matches nothing at all, without warning. Mixed-owner
repositories are therefore **out of scope for routing** and are handled by the
guard in component 4.

The same file's duplicate `[credential "https://github.com"]` block is collapsed
in the process. Today both `core/git/gitconfig.symlink` and `~/.gitconfig.local`
declare that section, each opening with an empty `helper =` reset; because the
later reset discards everything accumulated before it, the effective helper is
`/usr/bin/gh` (2.45.0, from apt) rather than the `/usr/local/bin/gh` (2.79.0)
that the shell uses. One block survives, referencing `gh` by name and resolving
through `PATH`.

#### HTTPS only

Only the HTTPS remote form is routed. SSH transport is explicitly **not
supported**, because routing it correctly requires more than a credential
helper: for `git@github.com:guarzo/…` git never invokes a credential helper at
all, and key selection happens in ssh via the agent, default key files, or
`~/.ssh/config`. `user.signingKey` controls only commit signing and does not
select an authentication key, so a design that set only the signing key would
still authenticate SSH pushes as the default account.

All three guarzo repositories use HTTPS today, so this costs nothing now.
A guarzo SSH remote is reported as unsupported by `bin/git-identity` and is
caught by the pre-push guard before any push completes.

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

### 3. `gh` routing via a `PATH` shim

`bin/gh` is an executable that resolves the current repository's GitHub remote
owner, sets `GH_CONFIG_DIR` for a matching identity, and then execs the real
`gh`. It locates the real binary by scanning `PATH` for the first `gh` that is
not itself, so it cannot recurse, and it delegates unchanged when there is no
match, no repository, or no configured identity.

A shim rather than a shell function because a zsh function reaches only
interactive zsh: not bash, not scripts, not editor integrations, not Codex, and
not Claude Code's bash tool. Routing that disagrees between callers in the same
repository would reintroduce exactly the silent wrong-identity failure this
design exists to remove.

**Mixed-owner repositories.** The pre-push guard protects `git push` only.
Repository-contextual `gh` commands — `gh pr merge`, `gh issue close`,
`gh release delete` — carry the same wrong-account risk with no hook to catch
them. When the shim finds more than one mapped GitHub owner among the
repository's remotes it therefore **refuses to run** and exits non-zero with an
actionable message, rather than guessing.

The refusal covers every `gh` invocation in such a repository rather than only
the repository-contextual subset, because distinguishing them means parsing
`gh`'s arguments, which is the same fragility rejected elsewhere in this design.
The escape hatch is an explicit `GH_CONFIG_DIR` (optionally with `GH_REPO`) in
the caller's environment: when `GH_CONFIG_DIR` is already set, the shim passes
through untouched and the caller owns the choice.

**Coverage is bounded by `PATH`.** `~/.dotfiles/bin` precedes `/usr/local/bin` in
both zsh and bash, but a clean environment (`env -i bash -l`) does not have it at
all — it is present in bash only by inheritance from a zsh parent, because
neither `~/.profile` nor `~/.bashrc` adds it.

Bash login coverage is delivered by a new tracked `core/shell/bash_profile.symlink`
mapping to `~/.bash_profile`, which sources `~/.profile` if present and then
prepends `~/.dotfiles/bin` to `PATH`.

This specific shape is required by the existing installer. `link_file` in
`bin/relink` uses `policy=skip` for any destination that is not already a
symlink, and `bin/relink` then calls `log_error` — which exits — if any
destination was skipped. A `profile.symlink` would therefore collide with the
real `~/.profile` on this machine and abort `bin/relink` for *every* managed
dotfile, not merely fail to install itself. `~/.bash_profile` does not exist
here, so it links cleanly.

Chaining rather than replacing preserves the existing `~/.profile`, which
sources `~/.bashrc`, adds `~/bin` and `~/.local/bin`, and loads the Cargo
environment. Bash reads `~/.bash_profile` instead of `~/.profile` when the former
exists — as the stock `~/.profile` header itself notes — so sourcing it first
keeps current behaviour intact.

Non-bash POSIX login shells continue to read `~/.profile` only and do not get the
shim. Neither do cron and other environments that read no profile at all. Those
must set `GH_CONFIG_DIR` explicitly; this is documented, not solved.

Because the shim covers Claude Code's bash sessions, no per-project
`.claude/settings.local.json` `env` block is required, and none is added. That
removes the per-repository setup step that an earlier draft depended on.

### 4. Pre-push identity guard

A `pre-push` addition asserts that the identity about to be used matches the
owner of the URL being pushed to, and aborts the push when they disagree.

This is the component that makes the limitations above safe. It catches:

- mixed-owner repositories, where routing picked an identity from a remote that
  is not the push target;
- a guarzo repository whose include file is missing or unprovisioned;
- a guarzo SSH remote, which routing deliberately does not handle;
- a push to a guarzo URL from a repository that resolved to the default
  identity for any other reason.

#### Composition with the existing hook

The existing `pre-push` ends with `git lfs pre-push "$@"`, whose exit status
becomes the hook's exit status. Appending the guard after it would let a guard
that exits 0 overwrite a non-zero LFS result, pushing refs whose LFS objects
never uploaded. Order is therefore fixed and load-bearing:

1. Run the identity guard first — it needs only the destination arguments.
2. Abort immediately, non-zero, if the guard rejects the push.
3. Run `git lfs pre-push "$@"` last, so its exit status stays authoritative.

#### Fail-open boundary

Fail-open applies *before* the guard establishes that a push is within its remit,
not after. Blanket fail-open would contradict this design's stated principle that
an unroutable identity must fail loudly.

| Destination | Condition | Behaviour |
| --- | --- | --- |
| Non-`github.com`, or owner maps to no configured identity | any | exit 0, silent |
| Owner maps to a configured identity | resolved identity matches | allow |
| Owner maps to a configured identity | resolved identity disagrees | block, actionable message |
| Owner maps to a configured identity | cannot determine — missing `gh`/`jq`, unreadable config, indeterminate identity | **block**, actionable message |

The first row preserves the constraint that a global hook must not break
unrelated repositories: a machine with no guarzo identity, or any repository
pushing elsewhere, never reaches a blocking path. The existing hook's own comment
is the precedent and the cautionary tale — a global hook that errors breaks
unrelated repositories, including lazy.nvim's plugin clones. The last row is the
narrow, deliberate exception: once the destination is known to be a configured
identity's, "I cannot verify" is not a safe reason to proceed.

### 5. Verification command

`bin/git-identity` reports, for the current repository: the matched owner, the
resolved `user.email` and `user.signingKey`, which `gh` config directory applies,
and whether that directory holds a valid token. It exits zero when the resolved
identity is usable, and non-zero in exactly these cases: a matched identity whose
token is missing or invalid; a matched identity whose include file is absent; a
mixed-owner repository; and a guarzo SSH remote. An unmatched remote owner is not
an error — it is the default identity working as intended.

## Data flow

For git, configuration resolves system → `~/.gitconfig` → `~/.gitconfig.local`
(default identity) → `~/.gitconfig.guarzo` (when any remote matches) →
repository-local `.git/config`. After migration the three `guarzo` repositories
hold no identity configuration at all and derive everything from their remote.

For `gh`, the shim reads the remote owner and sets `GH_CONFIG_DIR` for that
single invocation. No global state is modified.

At push time the guard independently re-derives the expected identity from the
destination URL and compares it against what git actually resolved.

## Failure handling

**Mixed-owner repositories.** Routing selects an identity from any matching
remote, which may not be the push target. The guard blocks the push and names
the disagreement, and the `gh` shim refuses to run at all. Not silently
mitigated, because it cannot be.

**SSH remotes owned by guarzo.** Not routed. Author and signing identity fall
back to the default, and the guard blocks the push rather than letting it
authenticate as the wrong account.

**Clone-time gap.** During `git clone` no remote exists yet, so the default
identity authenticates. Public guarzo repositories clone fine; private ones fail
outright. Documented workaround, already in use:
`GH_CONFIG_DIR=~/.gh-guarzo gh repo clone guarzo/<repo>`. Every operation after
the remote exists routes correctly, including the first commit, so authorship is
never wrong.

**Invalid or missing token.** Pushes fail with an authentication error rather
than falling back to the other identity. `bin/git-identity` reports it directly.

**`gh` outside a repository.** The shim keys off the current repository, so
`gh repo clone guarzo/new` from `~` uses the default identity. Documented, not
solved: solving it would require parsing `gh`'s arguments, which would break on
`gh` releases.

**Environments without `~/.dotfiles/bin` on `PATH`.** cron, and non-bash POSIX
login shells, bypass the shim and use the default identity for `gh`. Git routing
is unaffected, since it depends on config rather than `PATH`, and the guard still
applies to any push.

**Machine without a guarzo identity.** The conditional include references a
missing file, which git ignores silently; the shim finds no config directory and
delegates; the guard maps no owner and exits 0. A fresh bootstrap is unaffected.

## Provisioning

The conditional include is inert until `core/git/gitconfig.guarzo.symlink`
exists, is populated, and is linked to `~/.gitconfig.guarzo`. Because the real
file is gitignored, **it does not exist after cloning this repository**, so a
new machine can complete every other step and still silently use the default
identity.

Provisioning therefore covers all four of:

1. `bootstrap` copies `gitconfig.guarzo.symlink.example` to
   `gitconfig.guarzo.symlink` and prompts for the identity values, following the
   pattern it already uses for `gitconfig.local`. It skips the whole step when
   the user declines a second identity, leaving the include inert.
2. `bin/relink` creates the `~/.gitconfig.guarzo` symlink.
3. `GH_CONFIG_DIR=~/.gh-guarzo gh auth login` with `repo` and `workflow` scopes.
   `BROWSER=false` selects the device flow if the browser handoff fails. **Manual
   — requires the account holder.**
4. Generate `~/.ssh/id_ed25519_guarzo`, register the public half on the guarzo
   account **as a signing key**, and add a matching line to
   `~/.ssh/allowed_signers`. That file currently holds one entry, bound to the
   default identity's address, which is why signature verification across the
   three repositories currently produces three different results. **Manual.**

Steps 3 and 4 cannot be automated here, and final verification is gated on both
rather than declared against the currently-invalid token. `bin/git-identity`
reports which of the four are incomplete.

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
- Replace the README's "Multiple GitHub Accounts" section, which documents the
  SSH host-alias approach this design supersedes.

## Migration

For each of `binderplan`, `slabledger`, and `yetishopify`: record the current
local values, unset the local `user.name`, `user.email`, and credential helper
entries, then confirm the values resolved from the conditional include match
what was recorded. Reversible from the recorded values.

## Testing

A new bats suite follows the existing `setup_dotfiles_test` pattern, using a
temporary `HOME` and throwaway repositories. Nothing in the suite touches a real
token or the network.

Routing:

- HTTPS guarzo remote resolves email, signing key, and credential helper; a
  non-guarzo remote stays on the default.
- Linked worktrees inherit the routed identity, including one nested at
  `.claude/worktrees/`.
- A missing include file yields the default identity and exit 0.
- `core/git/gitconfig.symlink` contains exactly one
  `[credential "https://github.com"]` block — a regression test for the
  duplicate-block bug.
- `.gitignore` covers `core/git/gitconfig.guarzo.symlink`.

Shim:

- Selects the guarzo config directory for a guarzo remote, delegates unchanged
  for other remotes and outside a repository, and does not recurse when it is
  the first `gh` on `PATH`.
- Refuses to run, non-zero, in a mixed-owner repository, and passes through
  untouched when the caller has already set `GH_CONFIG_DIR`.

Bash login coverage:

- `core/shell/bash_profile.symlink` puts `~/.dotfiles/bin` ahead of
  `/usr/local/bin` in `env -i bash -l`, and preserves the effects of a
  pre-existing real `~/.profile` — exercised against a temporary `HOME`
  containing one, not an empty home.
- `managed_link_pairs` maps it to `~/.bash_profile`, and `bin/relink` completes
  without skipping when that destination is absent.

Guard:

- Blocks a push to a guarzo URL from a repository resolved to the default
  identity, and a mixed-owner push whose destination disagrees with the routed
  identity.
- Allows a correctly-matched push.
- Fails **open** — exit 0, no output — for a non-`github.com` host and an
  unmapped owner. A regression here breaks every repository on the machine.
- Fails **closed** for a configured destination when `gh` or `jq` is missing or
  the identity is otherwise indeterminate. Paired with the row above, these two
  tests pin the boundary that a single blanket rule would blur.

Hook composition:

- With `git-lfs` stubbed to exit non-zero and the guard passing, the composed
  hook exits non-zero — LFS failures are not masked.
- With the guard rejecting, `git lfs pre-push` is never reached.

Doctor and hygiene:

- `bin/git-identity` reports the routed identity, and exits non-zero for an
  invalid token, an absent include file, a mixed-owner repository, and a guarzo
  SSH remote. Exercised against a stub.
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

- **SSH transport routing.** Reasoned above; detected and blocked, not
  supported.
- **Mixed-owner repositories.** Detected and blocked, not routed.
- A registry or generator for arbitrary numbers of identities. The design ships
  exactly one non-default identity, structured so a second is a copy of one
  conditional include plus one gitignored file.
- Rewriting git history to remove the address already published in
  `gitconfig.local.symlink.example`.
- `gh` routing in environments that read neither `~/.profile` nor a zsh startup
  file, such as cron.
- Changing how the default identity authenticates.
