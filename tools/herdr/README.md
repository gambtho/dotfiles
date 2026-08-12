# Herdr

[Herdr](https://herdr.dev) is a terminal workspace runtime for coding agents: a
background server that owns panes and process state, with a terminal client
attached to it. Panes survive detaching the client, dropping the network, and
closing the terminal; only stopping the server ends them.

It replaced ProjectMux in this bootstrap. ProjectMux is still developed at
[gambtho/projectmux](https://github.com/gambtho/projectmux) — it is just no
longer installed from here, and this change removes nothing from a machine that
already has it.

## What the installer does

`install.sh` runs as the `herdr` phase of `bin/install`:

1. Refuses anything but Linux. Upstream ships macOS assets too, but the
   machines this repo bootstraps are WSL2 and an untested darwin path is worse
   than an honest refusal. macOS would come through `platforms/macos/brewfile`.
2. Downloads the release pinned in `config/versions.env`, verifies it against
   the committed digest, and publishes it to `~/.local/bin/herdr` through a
   stage-then-rename so no partial binary ever appears on `PATH`.
3. Records the installed version in `~/.local/state/herdr/installed-version`,
   only after the binary is in place, so an interrupted run reinstalls instead
   of believing it succeeded.
4. Copies `config.toml.template` to `~/.config/herdr/config.toml` if that file
   does not exist. An existing config is never overwritten — drift is reported
   and the file is left alone.

`bash tools/herdr/install.sh --check` prints the plan and writes nothing.

## Why the config is copied, not symlinked

Every other `config/<name>/` directory in this repo is symlinked into
`~/.config/` by `bin/relink`. Herdr cannot use that: it keeps runtime state in
its config directory alongside `config.toml` — `herdr.sock`, `herdr-client.sock`,
`herdr-server.log`, and `session.json`. A directory symlink would point all of
that into the git checkout and leave live sockets and logs in a working tree.

The cost is that local edits to `config.toml` are not tracked. Changes worth
keeping belong in `config.toml.template`.

## Why the pin fights the built-in updater

Herdr self-updates: `herdr update`, `herdr channel set stable|preview`, and a
background `version_check` that polls herdr.dev. Any of those would move the
binary away from the digest recorded in `config/versions.env`, so the shipped
config sets `version_check = false` and new releases are noticed by
`make pins-check` instead.

To move the pin: `make pins-update`, or edit `HERDR_VERSION` and both
`HERDR_LINUX_*_SHA256` values by hand. Upstream publishes no checksum file, so
the digests are computed from the downloaded artifacts and are
trust-on-first-use.

## Related

- `platforms/windows/wt-color-scheme.sh` installs the matching Tokyo Night
  scheme into Windows Terminal, so Herdr's UI theme, Neovim's
  `tokyonight-night`, and the surrounding terminal agree.
- Apply config changes to a running server without dropping panes:
  `herdr server reload-config`.
