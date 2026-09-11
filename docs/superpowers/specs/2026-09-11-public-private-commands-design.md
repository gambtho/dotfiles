# Public and private dotfiles commands

## Goal and approval

Make the exported `bin/` directory an explicit public command surface, rather
than exposing repository maintenance tools and shared implementation files.
The user approved the layout and migration scope below in chat on 2026-09-11.
This document records that design for review before implementation planning.

Base: `2b5256b7faf8544fb244d20c3f68e2f1c1632397`, after PR #29 renamed the
full installer to `dot-install` and added command-shadowing guardrails.

## Chosen boundary

Keep exactly these six executable files in `bin/`:

- `dot-install`
- `dot-update`
- `gh`
- `git-identity`
- `git-worktree-gc`
- `tmux-copy-url`

Move every other current `bin/` file to the same relative location beneath a
new root-level `libexec/` directory:

```text
libexec/
  bootstrap
  relink
  versions
  list-check-files
  validate-ai
  validate-pi-permission-config
  validate-pi-security-runtime
  validate-pi-webui
  validate-pi-security-runtime.ts
  pi-permission-pipeline-checks.ts
  common.sh
  log-helper
  lib/
    artifacts.sh
    links.sh
    phases.sh
    system.sh
```

`libexec/` is private in the command-discovery sense, not an access-control
boundary: scripts and operators can invoke its files through explicit paths.
It must not be added to PATH. Private executables retain their executable bits;
sourced libraries retain their existing source-only behavior.

### Why this layout

A sibling directory preserves the depth of existing repository-root calculations
and keeps the two TypeScript modules' relative import intact. Keeping filenames
and the internal `lib/` layout avoids unrelated renaming and restructuring.

Alternatives considered:

- A `scripts/` tree with language-suffixed filenames is workable but adds filename
  and import churn without improving the public boundary.
- A generated directory of public symlinks would allow implementation files to
  stay together, but introduces installation and stale-link reconciliation that
  this repository does not need for the split.

## Public interfaces and invocation

The six public commands keep their names, argument contracts, and exit-status
behavior. In particular, `gh` must still win over the underlying GitHub CLI in
parent and child shells; system `install` must remain unshadowed. No shell PATH
ordering changes are part of this work.

Existing Make targets become the documented operator interface for repository
maintenance:

| Operation | Documented invocation |
|---|---|
| First-time bootstrap | `make bootstrap` |
| Link reconciliation | `make relink` |
| List dependency pins | `make pins` |
| Check dependency pins | `make pins-check` |
| Update dependency pins | `make pins-update` |
| AI-resource validation | `make validate` |
| Repository verification | `make check` |

Make recipes call the corresponding private scripts at their new paths. Other
scripts and CI may call `libexec/` tools directly; do not replace internal calls
with recursive Make invocations or introduce a new dispatch layer.

### Bootstrap fallback

Make is not guaranteed before bootstrap: Linux installs `build-essential` only
after bootstrap starts, and the macOS bootstrap path does not establish initial
Make availability. Document `bash libexec/bootstrap` as the explicit fallback
from the repository root when Make is unavailable.

Preserve direct support for `--profile personal|work|server`, `--non-interactive`,
and `--allow-remote-installers`. Advanced flag-bearing examples may use the
explicit Bash invocation. Do not introduce `BOOTSTRAP_ARGS` or another Make
argument-forwarding interface. `ALLOW_REMOTE_INSTALLERS=1 make bootstrap` remains
the normal environment-based consent form. Remote-installer consent and all
other bootstrap policies remain unchanged.

## Caller and documentation migration

Update tracked active references in these categories:

1. Make recipes and `.github/workflows/check.yml`.
2. Public commands and topic installers sourcing `common.sh` or `lib/` slices.
3. Validators calling other validators, Python loader paths, and TypeScript
   runner/module paths.
4. Tests, including fixture copies that currently recreate a `bin/` tree,
   source-only script loading, strict-mode exemptions, and portability scans.
5. README examples, active AI/tool READMEs, root guidance, help text, comments,
   and code that generates future diagnostics or provenance text.
6. Permission-pipeline fixture command strings that exercise the moved validator.
   Preserve their explicit `bash .../validate-ai` command shape: switching those
   fixtures to Make would test a different permission-parser behavior.

Git identity diagnostics run from arbitrary repositories. Their repair commands
must name the resolved dotfiles checkout using a shell-safe
`make -C <dotfiles-root> relink` or `make -C <dotfiles-root> bootstrap` invocation.
They must work when the dotfiles path contains spaces and must not accidentally
run the unrelated current repository's Makefile.

Do not leave compatibility wrappers, symlinks, or inert copies of moved files in
`bin/`. Document that external callers of the removed paths need updating and
that existing shells may need `rehash` (zsh), `hash -r` (Bash), or a restart.

### Files deliberately left alone

- Historical plans, specs, and `implementation-notes.md`.
- Ignored generated identity files and machine-local configuration; update their
  tracked producers, not existing local outputs.
- Third-party package `bin/` paths and historical cleanup signatures used to
  recognize retired installations.
- Personal prompts/skills unless implementation-time search finds an actual
  active caller; discovery found no moved-command references there.

## Discovery and prevention

The current file-discovery classifier explicitly recognizes `bin/` and
`bin/lib/*.sh`. Moving files without updating it would silently remove private
shell code from syntax and lint checks.

Extend the existing shebang-aware classification to the analogous `libexec/`
layout. Preserve these properties:

- Public shell entrypoints and private shell entrypoints are checked.
- Private sourced shell libraries are checked even without executable bits.
- Explicit Python/Node entrypoints and `.ts` files are not fed to shell parsers.
- Ambiguous extensionless command files cannot silently escape shell checking.
- Tracked and untracked source files are included; ignored local state is not.
- Discovery still propagates errors through the Make pipelines.

The public-directory inventory test must assert the exact six approved files,
not merely a permissive prefix list. It must also catch unexpected helper
subdirectories and dangling symlinks. Retain the reserved system-command checks
and the existing `install`/`gh` lookup regressions. Public additions require an
explicit inventory change and justification; routine maintenance belongs in
`libexec/`.

## Behavior and failure preservation

This is a path and visibility migration, not a provisioning refactor. Preserve
source-only controls, the phase-state include guard, direct executable calls,
validator arguments, working-directory behavior, and failure propagation.

The `dot-install` argument guard from PR #29 remains intact: help and invalid
arguments do not load the selected profile or start provisioning. No new runtime
state, dependencies, compatibility wrappers, or production rollout steps are
introduced. Keep existing Linux, macOS, and WSL portability constraints; do not
add Bash-version requirements or GNU-only command options.

## Acceptance and verification

Use test-first regressions for the new public inventory and private discovery,
then migrate the coupled callers and fixtures together.

Acceptance criteria:

1. `bin/` contains exactly the six public commands and no compatibility remnants.
2. `libexec/` contains the moved files with preserved permissions and internal
   module relationships, and is absent from authored PATH configuration.
3. All current Make targets resolve to existing intended entrypoints; direct
   private calls and source-only loading retain behavior.
4. Private shell discovery, strict-mode policy, and interpreter exclusions are
   covered by executable tests, including untracked and ignored fixtures.
5. Identity repair hints execute correctly from an unrelated CWD with a dotfiles
   root containing spaces.
6. Existing parent/child `install` and `gh` lookup tests continue to pass.
7. Active tracked callers and documentation contain no stale paths, except
   deliberate migration explanations and explicitly preserved historical data.

Run focused discovery, hygiene, shell-loading, orchestration, identity/link,
validator, Python-loader, and Web UI fixture tests. Then run `make check` and
`libexec/validate-pi-security-runtime` against the available installed pinned
packages. If the installed-package check cannot run, report that prerequisite
and the unverified surface; do not fetch or install dependencies merely for this
migration without making that action explicit.

Run `polish-core --fix`, inspect its changes, and repeat affected verification
before completion. Inspect the final diff for path-only scope, accidental
machine-local changes, lost executable bits, stale callers, and debug artifacts.
Do not run live provisioning to validate this migration. Report which host was
used and distinguish portability checks from actual macOS/WSL execution.

## Design review checklist

- Public and private inventories are explicit and mutually exclusive.
- Make is the normal operator interface without becoming a bootstrap prerequisite.
- Internal callers use explicit paths; diagnostic commands identify the checkout.
- Source-discovery coverage moves with the code, rather than merely moving files.
- Tests cover behavior and failure propagation, not only reference replacement.
- No unresolved architecture or public-interface decisions remain in this design.
