# projectmux — pinned release installer

Installs the pinned [ProjectMux](https://github.com/gambtho/projectmux) release,
its default configuration, and its systemd user unit.

This directory owns **installation policy only**: which release is pinned, that
it verifies against a committed digest, and that it lands atomically. It holds
no workspace logic. Migrating existing state is the application's job, not the
installer's.

ProjectMux is the intended replacement for the Bash tmux platform in
`tools/dev/`. Installing it changes nothing about `bin/dev` — the two coexist
until you perform the cutover below.

## Setup

`bin/install` runs `tools/projectmux/install.sh` as its optional `projectmux`
phase, so a machine that cannot reach the release does not abort the rest of the
install.

```bash
bash tools/projectmux/install.sh --check   # print the plan, change nothing
bash tools/projectmux/install.sh           # install
```

`--check` reports the pinned version, every destination path, and the currently
installed marker.

## The pin

`config/versions.env` holds the version, the release base URL, and a SHA-256
digest per architecture. **The digests are committed, never fetched at install
time** — a release re-tagged upstream fails verification here instead of
installing silently.

Linux only, amd64 and arm64. Any other host is refused before anything is
written.

Bumping the release means editing `config/versions.env`: the version, the base
URL, and both digests.

## Atomic install

Every managed file — binary, version marker, config, unit — is staged into a
temporary file **inside its own destination directory** and published with
`mv -Tf`. Two consequences:

- No window exists in which a partial file is visible on `PATH`.
- A symlink squatting a destination is replaced, not written through. `-T` is
  what stops `mv` following a symlinked destination into a directory.

An interrupted run leaves no litter: staged files are dot-prefixed and removed
by an `EXIT` trap.

## Local builds

```bash
PROJECTMUX_LOCAL_BINARY=/path/to/build bash tools/projectmux/install.sh
```

Symlinks that build into place — so a rebuild takes effect without re-running
the installer — and records `local:<path>` in the version marker. **It never
rewrites the pin.**

Running the installer again *without* the variable restores the pinned release
over the symlink. This needs no special-case code: a Git tag cannot contain
`:`, so a local marker can never compare equal to a pinned version.

## Configuration

`defaults.yaml` is created under `$XDG_CONFIG_HOME/projectmux/` only if absent.
An existing config is **never overwritten**; drift from the shipped template is
reported as a warning and left alone.

`repository_roots` is rendered from `PROJECTMUX_REPOSITORY_ROOTS` (a `:`
separated list). Unset, it falls back to `DEV_REPO_ROOT` — the same variable
`tools/dev/` resolves workspace names under — and then to `~/workspace`.

## The autostart unit

`projectmux-autostart.service` is written to `$XDG_CONFIG_HOME/systemd/user/`
but is **deliberately not enabled**, and the installer never runs
`systemctl --user daemon-reload`. `dev-autostart.service` is still enabled on
these machines, and two units attaching a workspace at login would race for the
same tmux server.

Cutover is a manual, deliberate step:

```bash
systemctl --user disable --now dev-autostart.service
systemctl --user daemon-reload
systemctl --user enable --now projectmux-autostart.service
```

## Environment overrides

| Variable | Default | Effect |
|---|---|---|
| `PROJECTMUX_LOCAL_BINARY` | unset | Symlink this build instead of installing the pin |
| `PROJECTMUX_INSTALL_DIR` | `~/.local/bin` | Where the binary is published |
| `PROJECTMUX_STATE_ROOT` | `$XDG_STATE_HOME/projectmux` | Holds `installed-version` |
| `PROJECTMUX_CONFIG_ROOT` | `$XDG_CONFIG_HOME/projectmux` | Holds `defaults.yaml` and `workspaces/` |
| `PROJECTMUX_REPOSITORY_ROOTS` | `$DEV_REPO_ROOT`, else `~/workspace` | `:`-separated roots written into `defaults.yaml` |

## Tests

`tests/projectmux_install.bats` covers the installer, `tests/projectmux_phase.bats`
its registration in `bin/install`. Both run under `make check`.
