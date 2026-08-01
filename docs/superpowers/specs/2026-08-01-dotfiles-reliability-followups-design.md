# Dotfiles Reliability Follow-ups Design

## Goal

Resolve the eight findings from the 2026-08-01 repository review, plus the
approved Neovim documentation correction, without weakening the repository's
existing portability, safety, or verification guarantees.

## Scope

This change will:

1. replace the obsolete writable devcontainer mount helper with a safe,
   deterministic read-only seed-and-copy generator;
2. make project-overlay unlinking ownership-aware;
3. publish gallery derivatives and manifests atomically;
4. make pristine-macOS bootstrap instructions truthful about remote-installer
   consent;
5. make Windows Terminal settings replacement collision-safe and atomic;
6. remove duplicated devcontainer setup instructions and the contradiction
   inside its detailed reference;
7. treat the Kubernetes channel as an operator-owned compatibility pin;
8. centralize bootstrap/relink managed-link discovery; and
9. correct the claim that routine `dot-update` advances Neovim plugins.

Adjacent hygiene in the files already being changed will also remove the
tracked gallery bytecode, prevent future Python bytecode from being tracked,
and correct README's stale GitHub clone owner. The example SSH success comment
is valid content inside its verification shell block and remains unchanged.

It will not automatically rewrite existing project devcontainer overrides,
edit tracked `devcontainer.json` files, choose a Kubernetes minor for the user,
or update any dependency pins.

## Architecture

### Safe devcontainer generator

`bin/claude-merge-compose-override` remains the public entry point but changes
from the legacy writable-mount implementation into a deterministic renderer.
The project-setup skill remains responsible for discovering the real Compose
service, remote user, passwd-derived remote home, workspace, seed-script path,
and base command. It also remains responsible for obtaining approval before a
tracked `devcontainer.json` edit.

The helper accepts those resolved values as explicit arguments. Step 6 in the
skill calls the helper after discovery and consent; both temporary warnings
that prohibit using the legacy helper are removed. Its default
output contains:

- only allowlisted host Claude configuration mounted read-only beneath
  `/host-seed/.claude`;
- the dotfiles repository mounted read-only beneath `/host-seed/.dotfiles`;
- project-scoped named volumes at the remote user's `~/.claude` and
  `~/.dotfiles` targets;
- project-scoped empty volumes at the remote user's SSH, GitHub CLI, and
  OpenCode targets, ensuring inherited host binds are shadowed by default;
- no host SSH or GitHub CLI credentials;
- the seed command followed by the preserved base foreground command; and
- `host.docker.internal:host-gateway` for the host Vekil endpoint.

The explicit `--share-host-auth` flag replaces the empty SSH/GitHub volumes
with read-only `~/.ssh` and `~/.config/gh` mounts. OpenCode remains shadowed.
There is no flag for writable host configuration, whole-`~/.claude` mounting,
OpenCode bridging, or dual-home mounts.

The helper renders repository-owned Compose and seed templates, removes any
existing service-volume entries targeting the paths it owns, appends exactly
one safe entry per owned target, and preserves all unrelated keys and volume
targets. This target-aware replacement also repairs legacy unsafe entries in
the override being processed and ensures Compose target-key merging shadows
unsafe entries inherited from base files. It validates the result, shows the
diff, and supports `--dry-run`. Apply mode creates collision-free backups of
both managed output files before replacement. The helper sources
`bin/common.sh` and reuses `next_backup_path`; it does not introduce a third
backup allocator. Both outputs are staged before publication, and a failure
during the two-file publish restores the prior files from their backups. The
seed template becomes executable source rather than a large copy-paste block
embedded in prose.

Allowlisted seed-source mounts are emitted only when the corresponding entry
exists beneath the invoking host's `$HOME`. Tests override `HOME`; the helper
does not accept arbitrary host source roots.

The base command crosses the CLI boundary as validated JSON, not an interpolated
shell fragment. A non-empty JSON array of strings is passed to the seed wrapper
as argv and ultimately executed with `exec "$@"`. A JSON string is passed as one
argument and executed by the seed wrapper with `bash -lc -- "$command"` after
seeding. JSON numbers, objects, booleans, null, empty strings, empty arrays, or
arrays containing non-strings are rejected before rendering.

### Overlay unlink ownership

Unlink ownership is home-independent. The selected overlay produces an
ownership suffix rooted at `projects/<slug>/`, matching the migration logic
already used for host/container links. A symlink is removed only when its
resolved-or-textual target ends in the expected suffix for that exact managed
destination, regardless of whether the link was created under `/home/user`,
`/root`, or another host home.

A generated import shim is removed only when it contains exactly one import
line whose target ends in `projects/<slug>/CLAUDE.md` or
`projects/<slug>/AGENTS.md`, as appropriate. The home prefix may differ; the
slug and managed relative path may not. Foreign links, another overlay's links,
and edited files remain in place with an actionable warning. Whole-directory
and per-file unlinking share the same suffix-matching helper used by legacy
per-file migration instead of retaining the current absolute `$OVERLAY`
prefix check.

### Atomic gallery publishing

Every photo, video, thumbnail, and generated manifest is built in a temporary
file beside its final destination. Successful generation publishes with
`os.replace`, so readers observe either the old valid output or the new valid
output. Failures remove the temporary file and leave any prior destination
unchanged.

Freshness checks continue to use source/destination mtimes, but incomplete
work can no longer occupy the final destination. ffmpeg output is considered
successful only when the subprocess exits successfully and the staged file is
non-empty. Image writes use the same staged-publish path.

### Collision-safe Windows settings

The Windows Terminal reconciler sources `bin/common.sh` and uses its existing
`next_backup_path` function instead of maintaining another timestamp scheme.
It writes the validated merged JSON to a temporary file in the destination
directory and renames that file over `settings.json`. A failure before the
rename preserves the live settings and the backup.

The script moves executable work into `main` and supports a source-only guard,
so backup/publication functions can be tested outside WSL. Full-flow fixtures
may explicitly set the settings path, Windows username, and WSL distro; those
test overrides bypass host discovery only when all required values are
provided. Normal invocation retains the WSL guard and auto-detection.

### Compatibility-owned Kubernetes pin

`KUBERNETES_CHANNEL` remains the single declared channel consumed by repository
setup. `versions check` continues to compare it with upstream stable so age is
visible. `versions update` no longer rewrites it automatically; instead it
prints the current and upstream channels and explains that the operator must
select a cluster-compatible minor deliberately.

Runtime, Git-ref, and checksum-reviewed artifact update behavior is otherwise
unchanged.

### Shared managed-link inventory

`bin/common.sh` gains one NUL-delimited enumerator that emits paired source and
destination paths for both `*.symlink` files and `config/` directories. It owns
the archive, Git metadata, and worktree exclusions plus destination mapping.

`bin/bootstrap` and `bin/relink` consume that inventory while keeping their
current, intentionally different conflict policies. NUL delimiting preserves
paths containing spaces or other shell-significant characters.

### Documentation ownership

`project-claude-setup/SKILL.md` retains workflow, decisions, discovery, consent,
and verification, and Step 6 invokes the replacement helper. The obsolete
helper bans in both documents are removed. `devcontainer-host-mounts.md` owns
the detailed model and points to the executable templates/helper for exact
generated content. Repeated remediation bullets are removed. Its “Things to
avoid” rule is aligned with the earlier sanctioned exception: every
`devcontainer.json` edit remains forbidden except the user-approved
`dockerComposeFile` entry.

README Quick Start documents Homebrew's explicit remote-installer consent.
README routine-update text says Neovim restores the tracked lockfile and gives
an explicit manual workflow for intentionally advancing it.

## Public Interfaces

The replacement helper's interface is:

```text
claude-merge-compose-override \
  --service NAME \
  --remote-user USER \
  --remote-home PATH \
  --seed-file HOST_PATH \
  --seed-container-path CONTAINER_PATH \
  --base-command-json JSON \
  [--share-host-auth] \
  [--dry-run] \
  OVERRIDE_PATH
```

`--seed-file` names the local sibling `local-seed.sh` the helper writes;
`--seed-container-path` is the absolute path used by the generated Compose
command. `--base-command-json` accepts only a non-empty JSON string or a
non-empty array of strings and is converted into an exec-safe wrapper command;
it is never interpolated into shell source. All identity and path arguments are
mandatory: the helper must not infer a home as `/home/$USER`. Unknown flags,
missing values, unsafe empty values, a non-absolute remote home or seed
container path, invalid command JSON, an invalid existing Compose document, or
an unavailable supported `yq` fail before any write.

## Failure Handling and Compatibility

- Existing unsafe overrides are not rewritten implicitly. The helper operates
  only when explicitly invoked and always shows the proposed diff.
- Existing valid unrelated Compose keys survive merge.
- Credential sharing is deny-by-default and opt-in per invocation.
- Managed service-volume targets are replaced by target; unrelated targets are
  preserved.
- Unlink becomes more conservative; users can still remove foreign files
  manually.
- Atomic publishers never delete a previous valid destination on generation
  failure.
- Kubernetes updates become less automatic but retain visible drift reporting.
- Bootstrap and relink observable link policies remain unchanged.
- Bootstrap's interactive/backup `link_file` and relink's replace-symlinks-only
  `link_file` deliberately remain separate despite their shared name; only
  inventory discovery is consolidated in this change.

## Verification Strategy

Development follows red-green-refactor for every behavior change.

### Mount policy

Bats tests will render a fresh override, merge an existing override, and inspect
the resulting YAML. They will assert:

- default output has no host SSH/GH bind mounts;
- default output shadows inherited SSH/GH/OpenCode targets with named volumes;
- `--share-host-auth` adds both credentials read-only;
- authored Claude and dotfiles sources are read-only;
- no whole-Claude, writable host-config, OpenCode host bind, or dual-home mount
  exists;
- named-volume targets use the explicit remote home;
- unrelated keys survive merging;
- dry-run changes no files; and
- backup collisions preserve every prior backup.

Existing seed lifecycle tests will execute the rendered seed template instead
of extracting a copy from Markdown. The documented-block syntax test will stop
assuming the old block count (`total >= 10`) and will continue validating every
remaining Bash block plus the executable seed template directly.

### Unlink

Bats tests will cover owned same-home and cross-home symlinks, dangling
cross-home per-file links, foreign symlinks, another overlay's symlink/import
shim, an exact cross-home generated shim, and an edited shim.

### Gallery

Standard-library `unittest` coverage lives in
`tests/python/test_build_gallery.py`. `make check` gains a Python-test target
that runs `python3 -m unittest discover -s tests/python -p 'test_*.py'`; CI
explicitly installs `python3`. Because Pillow is an optional dependency of this
one skill rather than a repository-wide development dependency, tests inject a
minimal fake `PIL` module and exercise the shared atomic-output path without
making `make check` require Pillow. The tests will force image/ffmpeg generation
failures, verify that old outputs survive, verify staged files are cleaned,
then retry and prove the real destination is regenerated. Manifest replacement
receives equivalent coverage. Repository-hygiene coverage rejects tracked
`*.pyc`/`__pycache__` artifacts after removing the existing bytecode.

### Windows settings

Bats tests source the reconciler outside WSL and exercise its focused
backup/publication functions. Full-flow fixtures provide all three discovery
overrides. Coverage includes backup-name collisions, preservation on
validation/write failure, and successful atomic replacement.

### Pins and link inventory

Bats tests will prove `versions update` does not rewrite
`KUBERNETES_CHANNEL`, and will check its review message. Inventory tests will
compare bootstrap and relink discovery and include paths containing spaces.

### Final gates

Run focused suites throughout, followed by:

```bash
make check
make ai-check
git diff --check
```

Inspect the final diff for accidental dependency updates, unsafe mounts,
tracked generated files, and changes outside the approved scope.
