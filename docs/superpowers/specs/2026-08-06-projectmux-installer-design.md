# ProjectMux installer (dotfiles side)

Date: 2026-08-06
Status: approved, ready for implementation planning

Implements step 5 of the extraction sequence in the `projectmux` repository's
`docs/design.md` §13: "Add a dotfiles installer and XDG configuration links
pinned to a reviewed release."

## 1. Intent

Install a reviewed ProjectMux release on this machine and expose personal
configuration to it. Nothing else.

§4 of the application design draws the boundary: the Go source, release
workflow, systemd unit template, migrations, and schemas belong to the
`projectmux` repository, which must not know this checkout exists. This
repository owns only installation policy — pin and install a reviewed release,
render configuration under the XDG config root, and keep machine-local values in
ignored files.

§11 states four requirements. All four are easy to half-do, so they are restated
as acceptance criteria:

1. Pin a version **and a digest**. A pinned version alone is not the
   requirement; verifying the digest is the point.
2. Install atomically. There must be no window in which the binary on `PATH` is
   partial.
3. `PROJECTMUX_LOCAL_BINARY` links a local build **without mutating the pin**,
   and a subsequent run without the override restores the pinned release.
4. Migrations are the application's job. The installer never runs them.

## 2. Out of scope

Explicitly untouched: `bin/dev`, `tools/dev/dev-event`, `tools/dev/dev.tmux.conf`,
the existing `dev-autostart` unit, and the managed tmux marker block in
`tools/tmux/tmux.conf.symlink`.

Removing the Bash platform is §13 step 8 — a staged migration whose ordering
matters (the old unit must be disabled before the new one is enabled, tmux hooks
unset only where they still match the managed commands, the old state directory
preserved as a dated backup). Switching the `dev` alias is §13 step 7 and must be
atomic, after side-by-side validation. Doing either early breaks a working setup.

## 3. Repository evidence

Findings from inspection that constrain the design.

### 3.1 The release exists and its digests are verified

`v0.1.0` is published as a prerelease with `projectmux-linux-amd64`,
`projectmux-linux-arm64`, and `SHA256SUMS`. The amd64 binary was downloaded and
checked directly rather than trusted from the checksum file:

- SHA-256 `7197eb19215af33f4e57fb26b8038cf701319d84fed4a6167ccb573035f43cda`,
  matching `SHA256SUMS`
- `file` reports a statically linked ELF, consistent with the `CGO_ENABLED=0`
  release gate
- `projectmux version` prints `v0.1.0`, confirming the build stamp

arm64 digest, from `SHA256SUMS`:
`7f9dbd1ee2cda2f673b8feeed346f0ea5cc592aa0a4d8c97b7ed5108c8c4599e`. This host is
amd64, so the arm64 artifact is pinned but unverified by download.

`/releases/latest/download/` is unusable: every `v0.x` release is a prerelease
and GitHub's "latest" excludes prereleases. An explicit tag is pinned, which the
design requires regardless.

### 3.2 `ai/vekil/install.sh` is the closer reference

The task framing named `tools/dev/install.sh` as the reference installer, and its
`systemd_user_available` guard (lines 30-41) is reused verbatim in shape. But
`ai/vekil/install.sh` already solves the whole artifact-installation problem:
pinned version plus per-architecture digest read from `config/versions.env`,
`download_verified_artifact`, a staged-then-renamed atomic install, an
installed-version marker driving idempotence, and the same systemd guard. This
design follows Vekil's structure and borrows the tmux installer's guard.

One Vekil behavior cannot carry over. `validate_regular_target`
(`ai/vekil/install.sh:93`) refuses a destination that is a symlink. ProjectMux
must install a symlink in local-binary mode, so it needs its own guard.

### 3.3 The configuration root is `projectmux`, not `dev`

§4 says configuration is exposed under `$XDG_CONFIG_HOME/dev/`. The application
does not read that path. `internal/config/load.go:17-30` resolves
`PROJECTMUX_CONFIG_ROOT`, else `$XDG_CONFIG_HOME/projectmux`, else
`~/.config/projectmux`.

This design follows the code. `dev/` is stale Bash-era prose in §4 — the `dev`
name survives only as a personal alias per §14. Configuration written to `dev/`
would be silently ignored by the binary. This conflict should be reported
upstream so §4 is corrected.

### 3.4 The existing defaults file is not portable

`tools/dev/default-workspace.yaml` cannot be reused. It expresses windows as a
`layout` plus a `panes` list, whereas the v1 schema (§6, confirmed against
`internal/config/layer.go:37-45`) gives each window exactly one of `agent`,
`command`, or `shell` and has no pane concept. It also sets
`start_timeout: 300`; `Duration.UnmarshalYAML` rejects a bare number with a
targeted error naming exactly this mistake. Unknown fields are rejected by
design, so the old file fails rather than degrading.

A defaults file is therefore authored fresh in the v1 schema.

### 3.5 There are no workspace overlays to migrate

`projects/` contains only `CLAUDE.md` overlays; no `workspace.yaml` or
`workspace.local.yaml` exists on this machine. The installer creates an empty
`workspaces/` directory and links nothing into it.

### 3.6 `bin/versions` cannot check a prerelease-only repository

`check_artifact_release` (`bin/versions:104`) queries
`https://api.github.com/repos/<repo>/releases/latest`, which 404s while every
release is a prerelease. Registering ProjectMux through it would break
`make pins-check`.

`tests/dependency_pins.bats:44` asserts non-mise pins have exactly one canonical
manifest — `config/versions.env` — and `bin/versions list` enumerates them, so
the pin does belong in both files.

### 3.7 The systemd unit is not a release artifact

Release assets are binaries and `SHA256SUMS` only. The unit template lives at
`contrib/systemd/projectmux-autostart.service` in the application repository. Its
own header states that whether it is enabled at all is the dotfiles' decision,
and its only version-coupled element is the `projectmux autostart` subcommand.

## 4. Decisions

### 4.1 Pin the digest in `versions.env`; do not fetch `SHA256SUMS`

`config/versions.env` gains `PROJECTMUX_VERSION`, `PROJECTMUX_RELEASE_BASE`,
`PROJECTMUX_LINUX_AMD64_SHA256`, and `PROJECTMUX_LINUX_ARM64_SHA256`, following
the `VEKIL_*` block exactly.

A `SHA256SUMS` file fetched at install time is only as trustworthy as the fetch
that retrieved it, so verifying against it proves nothing a reviewer approved. A
digest committed to the repository is a reviewed artifact. This satisfies §11's
"pins a reviewed version and digest".

Alternative rejected: verify with `sha256sum --check --ignore-missing` against
the downloaded `SHA256SUMS`. Simpler, but it is the pinned-version-only
half-measure §11 warns against.

### 4.2 Atomic install by staged rename

`download_verified_artifact` (`bin/common.sh:200`) downloads to a temporary file
and **fails before installing anything** when the digest does not match. The
verified file is then copied to a `mktemp` name *inside the destination
directory*, `chmod 0755`, and moved over the destination with `mv -f` — a
same-filesystem rename, which is atomic. No reader ever observes a partial or
non-executable binary on `PATH`.

The installed-version marker is written only after the rename succeeds, so an
interrupted install is retried rather than recorded as complete.

### 4.3 The marker makes the local-binary round trip work

State lives at `${XDG_STATE_HOME:-~/.local/state}/projectmux/installed-version`.

- **Override set:** validate that `PROJECTMUX_LOCAL_BINARY` is an absolute path
  to an existing, executable, non-directory file. Stage a symlink under a
  temporary name in the destination directory and rename it into place. Write
  the marker as `local:<path>`. `config/versions.env` is not touched, read-only
  or otherwise.
- **Override absent:** the marker reads `local:<path>`, which can never equal
  `PROJECTMUX_VERSION`. The idempotence short-circuit therefore cannot fire, the
  full verified download runs, and the rename replaces the symlink with the
  pinned regular file.

Encoding mode in the marker rather than inspecting the destination is what makes
restoring the pin fall out of normal control flow instead of needing a special
case.

Destination guard: the target must be absent, a regular file, or a symlink.
A directory is refused.

### 4.4 Render `defaults.yaml`; create if absent, warn on drift

Target root is `${XDG_CONFIG_HOME:-~/.config}/projectmux`, created `0700`
because `<slug>.local.yaml` is documented as holding secrets. An empty
`workspaces/` directory is created alongside it.

`defaults.yaml` is **rendered**, not symlinked. §11 permits "links or renders",
but `repository_roots` is accepted only in `defaults.yaml`
(`internal/config/layer.go:21-23`) and holds absolute machine-specific paths, so
a symlink to a tracked file could not carry it. Roots come from
`PROJECTMUX_REPOSITORY_ROOTS`, defaulting to `${DEV_REPO_ROOT:-$HOME/workspace}`
so the Go and Bash implementations resolve the same repositories during the §13
step 6 side-by-side window.

On re-run the file is rendered only when absent. If it exists and differs from
what would be rendered, the installer warns naming both paths and leaves it
alone. This follows the reasoning already recorded at `tools/dev/install.sh:74`
for the tmux marker block: report a divergence rather than silently write over a
hand edit. Accepted cost — template improvements need a manual merge on machines
whose file was edited.

### 4.5 Vendor the systemd unit as a rendered template

`tools/projectmux/projectmux-autostart.service` is tracked here with the binary
path as a placeholder, rendered at install time. This is the pattern
`ai/vekil/vekil.service` and `tools/dev/dev-autostart.service` already use, and
it keeps install-time correctness independent of the network.

Failure mode when the pin moves: the vendored copy drifts from upstream's. That
risk is low and bounded — the unit's only version-coupled element is the
subcommand name, and enablement is explicitly the dotfiles' decision.

Alternatives rejected:

- *Fetch from the tagged source.* Always matches the pinned version, but adds a
  second network dependency to an installer that otherwise needs only the
  release assets; the unit is absent from `SHA256SUMS`, so it would either need
  its own pinned digest or be fetched unverified; and a moved tag would silently
  change its content.
- *Generate from a heredoc.* No drift and no network, but it duplicates
  upstream's Docker-ordering caveats in shell and the unit stops being
  reviewable as a file.

### 4.6 The unit is written but deliberately not enabled

No `systemctl --user enable`, and no `daemon-reload`.

§13 step 8 requires the Phase 1 `dev-autostart` unit to be disabled *before* the
application-owned unit is enabled. Enabling now would leave two autostart units
active against separate state roots and separate tmux sockets, which is exactly
what the staged ordering exists to prevent. The installer logs that the unit is
staged and inert.

Because nothing is enabled, the unit is only a file, and no systemd user manager
is required to write it. The full `systemd_user_available` guard from
`tools/dev/install.sh:30-41` therefore does not apply here — that guard exists to
prevent `enable` and `daemon-reload` from mutating state outside a sandbox, and
neither is invoked. Reproducing it wholesale would be ceremony guarding nothing.
What survives is its OS test: the unit is written on Linux and skipped elsewhere,
since a systemd unit directory is meaningless on macOS. Writing into
`$XDG_CONFIG_HOME` is contained even when `HOME` is redirected, which is the
reasoning the guard's own comment records.

The unit is staged and renamed like every other managed file, and skipped when
byte-identical to what is already installed. The full guard returns in §13 step
8, which does need it.

### 4.7 Register the pin, with a prerelease-aware check

`list_pins` gains `artifact projectmux $PROJECTMUX_VERSION`, satisfying the
canonical-manifest convention.

For drift, a sibling of `check_artifact_release` reads `/releases` and takes the
newest entry instead of `/releases/latest`. This works while ProjectMux is
prerelease-only and keeps working after 1.0. It is the one piece of shared
tooling this change reaches into; the alternative — leaving the pin unlisted and
unchecked — was considered and rejected because pin drift would then never be
reported.

### 4.8 The installer runs no migrations

§11 assigns migrations to the application: upgrades run them before normal
command execution and retain a backup when a migration is destructive. The
installer replaces a binary and writes configuration. It does not touch SQLite.

## 5. Components

| Path | Role |
| --- | --- |
| `config/versions.env` | `PROJECTMUX_*` pin block — canonical manifest |
| `tools/projectmux/install.sh` | The installer |
| `tools/projectmux/defaults.yaml.template` | Rendered personal configuration |
| `tools/projectmux/projectmux-autostart.service` | Vendored unit template |
| `tests/projectmux_install.bats` | Behavioral tests |
| `bin/install` | `run_phase optional projectmux`, beside the existing `dev` phase |
| `bin/versions` | Pin listing and prerelease-aware drift check |

`install.sh` follows repository convention: `set -euo pipefail`, sources
`bin/common.sh` and `config/versions.env`, derives `DOTFILES_ROOT` from
`BASH_SOURCE`, cleans up staged files on `EXIT`, and supports `--check` for a
dry run as the AI installers do.

## 6. Control flow

```text
main
 ├─ --check ............ report intended actions, change nothing
 ├─ resolve mode ....... PROJECTMUX_LOCAL_BINARY set? local : pinned
 ├─ install_binary
 │   ├─ local ......... validate path → stage symlink → rename → marker "local:<path>"
 │   └─ pinned ........ marker == version && regular file? skip
 │                      detect arch → select asset + pinned digest
 │                      download_verified_artifact (fails closed on mismatch)
 │                      stage in destination dir → chmod 0755 → rename → marker
 ├─ install_config ..... mkdir 0700 root + workspaces/
 │                      defaults.yaml absent? render : (differs? warn : nothing)
 └─ install_unit ....... Linux only: render template → stage → rename
                         never enable, never daemon-reload
```

Architectures: `x86_64`/`amd64` and `aarch64`/`arm64` on Linux. Anything else is
refused with a clear message — §14 records Linux and WSL as the only initial
platforms.

## 7. Failure behavior

| Condition | Behavior |
| --- | --- |
| Digest mismatch | Download rejected before install; existing binary untouched; non-zero exit |
| Network failure | `curl` fails; nothing staged is promoted; existing binary untouched |
| `PROJECTMUX_LOCAL_BINARY` relative, missing, non-executable, or a directory | Refuse with a message naming the path; install nothing |
| Destination is a directory | Refuse; do not attempt a rename over it |
| Unsupported architecture or OS | Refuse before any download |
| `defaults.yaml` exists and differs | Warn naming both paths; leave it alone; exit zero |
| Non-Linux host | Skip the unit; log; exit zero. The binary and configuration still install |
| Interrupted mid-install | Marker not yet written, so the next run reinstalls |

The installer is an optional install phase, matching the existing `dev` phase, so
a failure does not abort the whole `bin/install` run.

## 8. Verification

Every item is executed, not read. An installer that has never been run is a
guess.

1. Local-binary mode installs a symlink to the local build; marker reads
   `local:<path>`; `config/versions.env` is byte-identical afterward.
2. Re-run with no override replaces the symlink with a regular file;
   `projectmux version` prints `v0.1.0`; marker reads the pin.
3. Third run short-circuits — no download.
4. A deliberately corrupted pinned digest fails the install and leaves the
   previously installed binary intact.
5. Configuration renders into a temporary root and
   `PROJECTMUX_CONFIG_ROOT=<tmp> projectmux config` accepts it, proving the
   generated `defaults.yaml` validates against the real schema rather than
   merely looking plausible.
6. A hand-edited `defaults.yaml` survives a re-run and produces a warning.
7. Relative, missing, and directory values of `PROJECTMUX_LOCAL_BINARY` are all
   refused.
8. `make check` — syntax, shellcheck, shfmt, bats, python, validate.

Known limits, to be stated rather than papered over:

- Nothing enables the unit at this step, so no enablement path is exercised —
  by design, not by sandbox limitation.
- This host is amd64; the arm64 digest is pinned from `SHA256SUMS` but not
  verified by download.

## 9. Assumptions

- `~/.local/bin` is on `PATH` and is the correct destination, consistent with
  `ai/vekil/install.sh` and the upstream unit's `%h/.local/bin/projectmux`.
- `$HOME/workspace` is the repository root on this machine, matching
  `bin/dev:18`'s `DEV_REPO_ROOT` default.
- `mv -f` within one directory is atomic. The destination directory and its
  staging file always share a filesystem because staging happens inside it.

## 10. Follow-up

- Report the §4 configuration-path conflict upstream (§3.3).
- §13 step 6 side-by-side validation, then step 7's atomic alias switch and step
  8's staged removal, each separately.
