# Repository Tooling Reliability Design

## Goal

Make repository validation describe the tracked product rather than incidental
checkout state, and consolidate symlink conflict handling without changing the
established behavior of each installer entry point.

## Hermetic checks

Syntax, ShellCheck, and shfmt inputs will come from one NUL-delimited helper,
`bin/list-check-files`. It combines `git ls-files` with `git ls-files --others
--exclude-standard`, so tracked and new untracked source files are checked while
ignored machine-local state is excluded. It classifies paths into Bash syntax,
Zsh syntax, ShellCheck, and shfmt sets; every Make target consumes this helper
instead of maintaining its own near-identical discovery expression. Tracked and
untracked extensionless Bash executables under `bin/` remain covered.

`make check` is explicitly a Git-checkout developer/CI command. If Git metadata
is unavailable, the helper exits nonzero with a clear message rather than using
a broader tarball fallback that cannot distinguish ignored state. Installed
dotfiles do not call this helper.

Tests will create representative ignored files and new untracked scripts inside
scanned directories, proving that ignored state is absent and untracked source
is present. They also cover the no-Git error. CI continues to call `make check`
with no new dependency.

## AI manifest and symlink validation

`bin/validate-ai` will validate both the Claude plugin manifest and the Pi
package metadata. Every declared skill path must exist and resolve to a skill
with valid frontmatter. Where the Pi skill list is the package's public,
exhaustive inventory, every actual skill directory must also be declared.

Tracked symlinks must be relative and resolve to existing repository content.
The obsolete `polish-core/references/rules` link will be removed rather than
retargeted because the canonical rules already live at `polish-core/rules` and
no active code references the compatibility link. Validation errors remain
fatal and warnings remain nonfatal.

## Shared symlink reconciliation

`bin/common.sh` will own one noninteractive symlink reconciliation primitive:
`reconcile_link SOURCE DESTINATION LABEL POLICY MODE`. `MODE` is `apply` or
`check`; check mode describes the resolved action and performs no mutation.
`POLICY` is one of:

- `skip`: preserve any conflicting real entry or different symlink;
- `replace`: remove the conflicting entry and create the managed link;
- `backup`: move the conflicting entry to a collision-safe timestamped backup.

The helper treats an already-correct link as success and creates parent
directories only where callers currently do so. It will not follow or remove a
destination through an unexpected symlink. Messages will share vocabulary but
retain enough labels to identify the managed tool.

Callers preserve their current effective policy:

- bootstrap prompts interactively and skips conflicts noninteractively;
- relink replaces different symlinks but skips real files/directories;
- Claude and Codex installers back up conflicts before linking.

Prompting is a separate `prompt_link_policy SOURCE DESTINATION LABEL` helper in
`common.sh`. It prints one of `skip`, `skip-all`, `replace`, `replace-all`,
`backup`, or `backup-all` and never mutates. Bootstrap interprets that result,
caches only the apply-to-all variants in its existing local orchestration state,
and passes the resolved noninteractive policy plus `apply` mode to
`reconcile_link`. This keeps shared prompt wording without circular ownership
of bootstrap state.

## Failure behavior

Invalid policy values fail before mutation. Backup collisions cannot overwrite
older backups. Failed moves, removals, or link creation return nonzero with the
destination intact wherever the underlying operation permits. Check modes must
remain immutable and describe the action they would take.

## Testing

Unit-style Bats tests will cover correct links, broken links, different links,
real files, real directories, each conflict policy, backup collision handling,
invalid policies and modes, and immutable check mode. Before any caller is
changed, characterization tests will lock down bootstrap, relink, Claude, and
Codex conflict behavior. Only after those tests pass will the four callers move
to the shared helper. Validator tests will cover missing declared skills,
unlisted skills, malformed paths, broken tracked symlinks, and ignored checkout
contamination.

## Delivery order

This repository-tooling wave is implemented first because its hermetic checks,
manifest validation, and entry-point characterization tests are the safety net
for the other work. Provisioning and reproducibility follows second, then Vekil
runtime reliability. Each wave receives focused verification and a reviewable
commit boundary before the next begins.

## Compatibility and exclusions

No public command is renamed and no default conflict policy changes. This wave
does not convert all repository filesystem discovery to Git manifests, redesign
project overlay linking, or add new installation modes.
