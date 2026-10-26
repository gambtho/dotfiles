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

`install.sh` runs as the `herdr` phase of `bin/dot-install`:

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

The installer neither installs nor removes plugins. Existing registrations and
plugin-owned configuration remain machine-local.

`bash tools/herdr/install.sh --check` prints the plan and writes nothing.

## Optional native iPhone access

[Heeler access](heeler/README.md) adds explicit, opt-in boot persistence for the
normal **default** Herdr session and a private key-only SSH listener over
Tailscale. Run `DOTFILES_HEELER_ENABLED=1 make ai-heeler` from the canonical
checkout to prepare it without restarting live agents; root publication and
controlled cutover remain separate operator steps. Ordinary bootstrap and
updates do not enable this access. No browser backend or reverse proxy is required.

## Why the config is copied, not symlinked

Every other `config/<name>/` directory in this repo is symlinked into
`~/.config/` by `make relink`. Herdr cannot use that: it keeps runtime state in
its config directory alongside `config.toml` — `herdr.sock`, `herdr-client.sock`,
`herdr-server.log`, and `session.json`. A directory symlink would point all of
that into the git checkout and leave live sockets and logs in a working tree.

The cost is that local edits to `config.toml` are not tracked. Changes worth
keeping belong in `config.toml.template`.

## Why the pin fights the built-in updater

Herdr self-updates: `herdr update`, `herdr channel set stable|preview`, and a
background `version_check` that polls herdr.dev. Any of those would move the
binary away from the digest recorded in `config/versions.env`, so the shipped
config sets `version_check = false`.

Normal Linux install/update runs a separate optional Herdr-only release check:
`bash libexec/versions check-herdr`. It compares the repository pin with GitHub's
latest stable release, using a 3-second connection timeout, 10-second total
request timeout and no retries. A differing tag prints a reminder, not an
upgrade or downgrade recommendation. Missing tools, offline/rate-limited requests
and invalid responses warn without failing otherwise successful provisioning.
The advisory never contacts the running Herdr server or changes pins/binaries.
`make pins-check` remains the comprehensive check for all dependencies.

To advance Herdr, review the release and edit `HERDR_VERSION`, its release URL,
and both `HERDR_LINUX_*_SHA256` values together, then verify before deploying.
`make pins-update` does not advance checksum-reviewed artifacts. Upstream
publishes no checksum file, so these digests are computed from downloaded
artifacts and are trust-on-first-use. Replacing a binary does not itself upgrade
an already-running server; arrange a controlled cutover after saving agent work.

## Lane workflow and existing-host rollout

The defaults name spaces at creation, sort Agents by attention priority, hide a
single tab's bar, and show in-app background notifications. Keep Spaces as the
stable lane list; Agents is an attention queue, not a requirement to group lanes
by repository or run several agents per space. Pi's coordinator skill can launch
lanes only on explicit request; manual handoffs remain available in other apps.

These are first-install defaults, not a migration of existing mutable config.
After integrating the reviewed source into the canonical checkout:

1. Stop Pi sessions before reconciling linked resources; run `make ai` from the
   canonical checkout, never the implementation worktree. This removes the
   tab-status selection while retaining Herdr's state/prompt bridges. Start a
   fresh Pi session after the remaining configuration steps.
2. Explicitly refresh an existing config by backing it up first:

   ```bash
   config="$HOME/.config/herdr/config.toml"
   backup=$(mktemp "$config.backup.XXXXXX")
   cp -p "$config" "$backup"
   printf 'Backup: %s\n' "$backup"
   ```

   Manually merge the following defaults into the existing tables, preserving
   intentional overrides. Add missing tables only once; do not append duplicate
   TOML tables or replace unrelated preferences, keybindings, or onboarding state.
   Normal install/update only reports drift and never performs this refresh:

   ```toml
   [ui]
   prompt_new_workspace_name = true
   agent_panel_sort = "priority"
   hide_tab_bar_when_single_tab = true

   [ui.toast]
   delivery = "herdr"

   [ui.sidebar.spaces]
   rows = [["state_icon", "workspace"]]
   ```

3. Remove only existing `[[keys.command]]` blocks whose `command` is exactly
   `devcontainer.open-shell` or `devcontainer.open-stop`. Preserve all other
   shortcuts. Inspect `herdr plugin list --json`; if devcontainer is registered
   and none of its plugin panes is in use, run `herdr plugin uninstall devcontainer`
   in the intended session. No installer automatically uninstalls it. Do not
   stop containers or delete their data or `~/.config/herdr-devcontainer`.
4. Run `herdr config check` before `herdr server reload-config`; reload only if
   validation succeeds. If validation fails, correct the merge or restore the
   backup with `cp -p "$backup" "$config"` before reloading. No server restart is
   needed. Check that the retired bindings are absent and the new preferences
   work, then start fresh Pi and try one disposable lane
   with an explicit launch request. Check its space name, Pi `/session` and
   `/resume` identity, unchanged focus, and the coordinator's recorded IDs.

No server stop or Herdr upgrade is needed for these preferences. In-app toasts
are separate from iPhone pushes; see [Heeler notifications](heeler/README.md#notification-only-follow-up).

## Deferred extension watchlist

Not installed or live-tested here; recheck requirements and source before trying:

| Candidate | Possible value | Gate/caveat at investigation |
|---|---|---|
| [Herdr Annotate](https://github.com/plannotator/herdr-annotate) | Comment on plans and agent replies | Supports Herdr 0.8.0; test one review flow first |
| [Herdr Reviewr](https://github.com/persiyanov/herdr-reviewr) | Interactive diffs and feedback | Requires Herdr >=0.9.3 |
| [pi-herdr](https://github.com/AndrewJacop/pi-herdr) | Visible, steerable delegated agents | Requires Herdr >=0.9.0; README does not verify Linux |
| [pi-herdr-agents](https://github.com/giuseppecrj/pi-herdr-agents) | Herdr-backed subagents/worktrees | Alternative to current managers, not an automatic additional layer |
| [Herdr Projects](https://github.com/eliasstravik/herdr-projects) | Integrated coordinator/task board | Would replace substantial existing coordination and Git workflow |

## Related

- `platforms/windows/wt-color-scheme.sh` installs the matching Tokyo Night
  scheme into Windows Terminal, so Herdr's UI theme, Neovim's
  `tokyonight-night`, and the surrounding terminal agree.
- Apply config changes to a running server without dropping panes:
  `herdr server reload-config`.
