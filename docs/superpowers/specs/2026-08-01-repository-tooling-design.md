# Repository Tooling Reliability Design

## Goal

Make repository validation describe the tracked product rather than incidental
checkout state, and consolidate symlink conflict handling without changing the
established behavior of each installer entry point.

## Hermetic checks

Syntax, ShellCheck, and shfmt inputs will be derived from tracked paths rather
than unrestricted `find` traversal. Machine-local files that are intentionally
ignored—such as `.opencode` state and the local Git identity symlink—must not
change verification results. Tracked extensionless Bash executables under
`bin/` remain covered.

Tests will create representative ignored files inside scanned directories and
prove that the resolved input set is unchanged. CI continues to call `make
check` with no new dependency.

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

`bin/common.sh` will own one symlink reconciliation primitive. Its inputs are a
source, destination, human-readable label, and an explicit conflict policy:

- `skip`: preserve any conflicting real entry or different symlink;
- `replace`: remove the conflicting entry and create the managed link;
- `backup`: move the conflicting entry to a collision-safe timestamped backup;
- `prompt`: ask once and translate the choice into one of the noninteractive
  policies, including the existing apply-to-all behavior needed by bootstrap.

The helper treats an already-correct link as success and creates parent
directories only where callers currently do so. It will not follow or remove a
destination through an unexpected symlink. Messages will share vocabulary but
retain enough labels to identify the managed tool.

Callers preserve their current effective policy:

- bootstrap prompts interactively and skips conflicts noninteractively;
- relink replaces different symlinks but skips real files/directories;
- Claude and Codex installers back up conflicts before linking.

Bootstrap's apply-to-all state remains orchestration state owned by bootstrap,
not hidden global state in `common.sh`.

## Failure behavior

Invalid policy values fail before mutation. Backup collisions cannot overwrite
older backups. Failed moves, removals, or link creation return nonzero with the
destination intact wherever the underlying operation permits. Check modes must
remain immutable and describe the action they would take.

## Testing

Unit-style Bats tests will cover correct links, broken links, different links,
real files, real directories, each conflict policy, backup collision handling,
and invalid policies. Entry-point tests will lock down bootstrap, relink,
Claude, and Codex compatibility. Validator tests will cover missing declared
skills, unlisted skills, malformed paths, broken tracked symlinks, and ignored
checkout contamination.

## Compatibility and exclusions

No public command is renamed and no default conflict policy changes. This wave
does not convert all repository filesystem discovery to Git manifests, redesign
project overlay linking, or add new installation modes.
