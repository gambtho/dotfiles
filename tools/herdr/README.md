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
   does not exist. Normal installation never overwrites an existing config —
   drift is reported and the file is left alone.

The installer neither installs nor removes plugins. Existing registrations and
plugin-owned configuration remain machine-local.

`bash tools/herdr/install.sh --check` prints the plan and writes nothing.

## Explicit preference refresh

`make herdr-config-refresh` deliberately **replaces** the config with the template;
review local differences first. It writes an exact, private
`config.toml.backup.XXXXXX` beside the old file before atomic publication. It does
not install a binary, register plugins, reload or restart a server. An identical
config is a no-op; a failed backup leaves the original untouched. For a reviewed
machine-local full config that preserves additional bindings, use
`HERDR_CONFIG_TEMPLATE=/absolute/path/to/reviewed.toml make herdr-config-refresh`.
Then apply with `herdr server reload-config`, not a server restart.

Defaults keep priority Agent rows icon-only and show optional `$needs` workspace
metadata (hidden at zero). Machine identity stays visible in the dashboard. This does not
produce counts by itself: the optional heading reporter below sets them.

## Optional project headings and lanes

Run `make herdr-lanes` to install copied Python tools under
`${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/herdr-lanes` and link
`~/.local/bin/lane` to the installed copy. Like the dashboard, installs are
content-addressed and published atomically; older copies remain for running
publishers. No repository checkout is used at runtime, `bin/` stays unchanged,
and `libexec/` never goes on PATH. An existing regular file at `lane` is not replaced.
`HERDR_INSTALL_DIR` can override the command directory; the default popup assumes
`~/.local/bin/lane`.

```sh
lane orchard-12 "Read /absolute/orchard-local/lanes/task.md and follow it."
lane orchard-coord
# From ~/orchard-local, shorthand also works:
lane 13
```

Projects are existing `~/<project>-local` folders. The longest matching folder
name wins, including dashed names. A lane suffix is a number or `coord`; a bare
project name prepares only its heading without changing focus. Avoid folders
whose names collide with lane labels (for example `orchard-12-local`).

First use creates an empty Git anchor at `~/.lane-anchors/<project>`, detached
lane checkouts beside it under `<project>-lanes/`, and a `◆ <project>` workspace.
The helper first creates its own workspace at the checkout with
`DOTFILES_KEYRING_PROMPT=0` before shell startup, then attaches stock grouping to
that exact workspace without relabelling an adopted checkout. Its shell then
changes to the project folder. Existing matching labels or open checkouts are only focused: no rename,
regrouping or input, even if a prompt was supplied. Duplicate labels are refused.
New panes receive commands only after their shell is confirmed alone in the
foreground. Labels and prompts with terminal control characters are rejected
(multiline prompt text is supported). If startup still owns the pane (including a keyring prompt), the
workspace remains open and nothing is typed there; finish startup and run Pi
manually. This process check is not a general shell-prompt detector.

The template binds **prefix+shift+l** to the lane popup. Apply to an existing
config only through the reviewed refresh/backup path above. The heading pane runs
`needs.py`, which shows the project's numbered/coord lanes and publishes `$needs`:
grouped linked lanes blocked or reporting `phase=needs-decision`. Ungrouped lanes
are marked in the pane summary but excluded from the badge. Zero is not total
lane count. Reporters stop with Ctrl-C and do not auto-respawn; after a server
restart rerun `python3 -B "${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles/herdr-lanes/needs.py"`
in each heading pane. Never restart a server just to apply these preferences.

The coordinator's unattended `launch.py` stays flat: Herdr 0.9.5 worktree-open has
no pre-shell `--env`, and its `--cwd` selects the anchor repository rather than the
lane's working directory. Keeping the keyring opt-out, real repo cwd, no-focus and
at-most-once startup takes precedence over automatic grouping. Manual `lane`
provides grouping with the foreground-shell check described above.

## Optional project dashboard

Run `make herdr-dashboard` explicitly. It copies the stdlib Python pane into a
content-addressed directory under `${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles`,
atomically switches `herdr-dashboard` to that copy, and registers it with stock
`herdr plugin link`. Re-running reconciles the registration; it never links a
source checkout or opens a pane. Normal installation still does not touch plugins.
Python 3.11+ with curses and the pinned Herdr must be on the pane's PATH.

After both `make herdr-lanes` and `make herdr-dashboard`, **prefix+shift+o** focuses
an existing `Projects` workspace and types nothing. If none is open, it creates `Projects` at the
installed dashboard directory and runs `./dashboard.py` in its **primary pane**,
not a plugin tab or split. The new shell has `DOTFILES_KEYRING_PROMPT=0` before
startup; the opener also checks foreground-shell ownership before sending input.
Duplicate `Projects` labels are refused; missing installs give an error/notification.

Alternatively, the plugin remains available in a chosen workspace without stealing focus:

```sh
herdr plugin pane open --plugin project-dashboard --entrypoint projects \
  --workspace <workspace-id> --no-focus
```

The pane discovers **all enabled saved machines** from `herdr machine list --json`
and the local calling session, then reads snapshots. `<project>-<number>` workspaces
are lanes. `<project>-coord` is a coordinator; so are `<project>` and
`<project>-local` when that project already has lanes or a `◆ <project>` heading.
`◆ <project>` workspaces are never rows. Other workspaces are excluded.

Each lane shows one state: `!` needs you (blocked or phase `needs-decision`),
`✓` ready for review (done or phase `ready`), `●` working, `○` idle, `·` no agent.
Live working/blocked wins over a stale phase; unknown is never called complete.

The top strip lists lanes that need you or are ready for review, then any lane
reporting a task, numbered 1–9. Below it, a grid has one row per project (most
urgent first) and one column per machine; `◆` marks the coordinator and `+N` folds
lanes that don't fit (selecting it goes to the most urgent of them). Machines that
don't fit are counted as `+N` after the last column.

Arrows or hjkl move, 1–9 jump to a strip row, Enter or a mouse click goes, r
refreshes, q exits. Local lanes are focused by their returned workspace ID. For a
remote lane the footer shows the path: **Ctrl-B w**, select the machine and
workspace, then Enter. The dashboard does not send input to lanes.

Failed or slow hosts are visibly offline/checking; their last successful rows stay
**cached**, excluded from known-live attention totals. Cache lives only in memory.
One host never blocks the others. Quitting cancels only dashboard-owned CLI reader
process groups, not shared detached SSH masters or Herdr servers. Snapshot reads
use saved profile IDs, not user-provided SSH commands. `dashboard.py --once` prints
one bounded diagnostic view and exits nonzero for discovery/read failures.

Saved machines and strict SSH trust/authentication remain machine-local; this
installer neither configures SSH nor installs/starts/updates remote Herdr. Enroll
machines separately with stock `herdr machine add` after checking their existing
servers. A pane inherits its server's HOME/PATH/SSH agent environment: verify a
real read from the plugin pane, not only an interactive shell. Hosts enrolled in
[Heeler](heeler/README.md) may use a separate listener/port; use their actual
approved SSH configuration rather than assuming a port or changing services.

Undo: close only the created pane with `herdr plugin pane close <pane-id>`, then
`herdr plugin unlink project-dashboard`. Copies remain under the data directory
until explicitly removed; retain older versions while a pane may still use them.
No server needs to stop.

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

### Web links on headless WSL

With mouse capture enabled (the default), Herdr v0.9.5 handles Ctrl-clicks itself
instead of passing labeled hyperlinks to Windows Terminal. File links can be
claimed by plugins; unmatched HTTP(S) links use the client's Linux `xdg-open`.
Without a Linux browser, web clicks can therefore silently do nothing even when
file links work.

`core/env.zsh` supplies a `BROWSER` fallback to the Windows default browser through
`rundll32.exe` when either the `WSLInterop` or `WSLInterop-late` registration is
enabled and the executable exists at the standard
`/mnt/c/Windows/System32/rundll32.exe` path. An existing nonempty `BROWSER` is
preserved. The command includes a `%s` URL placeholder for compatibility with
Python's `webbrowser` module as well as `xdg-open`. This also works without a
display, where `xdg-open` ignores desktop
MIME registrations. Hosts with a different Windows mount can set their own
`BROWSER` in `~/.localrc`.

After integrating the change into the canonical checkout, start a fresh shell
before attaching Herdr so the client inherits the fallback. For a live session,
detach with Ctrl+B then Q, open a fresh outer shell, and run `herdr` again. Do not
stop the server: its Pi sessions can keep running. Check with
`xdg-open https://example.com`, then Ctrl-click a web link inside Herdr. A running
client does not pick up environment changes through `herdr server reload-config`.

### Reviewed release pin

The repository pins [Herdr v0.9.5](https://github.com/herdrdev/herdr/releases/tag/v0.9.5)
for Linux. Both assets were downloaded from that release and hashed with
`sha256sum`; the measured values also match the release API's asset digests:

| Asset | SHA-256 |
|---|---|
| `herdr-linux-x86_64` | `14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d` |
| `herdr-linux-aarch64` | `17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c` |

API digests corroborate the downloaded bytes, not independent provenance or a
signature. Matching hashes and installer tests do not certify a running-server
upgrade. An isolated v0.9.5 server reports snapshot protocol **22**. The
lane-coordinator launcher accepts integer protocol **19** with legacy version
metadata unchanged, or integer **22** only with snapshot version exactly `0.9.5`.
Other protocols, floats and malformed consumed response objects are rejected;
this is an explicit compatibility allowlist, not a minimum-version rule.

The isolated v0.9.5 Heeler version/ping checks pass. Actual Pi startup/readiness,
prompt delivery, client-focus preservation, bridge transitions and layout recovery
are not certified for this upgrade. A legacy v0.8.0 default-session fixture omitted
`HERDR_SESSION` and correctly failed the launcher's inherited-context precondition;
no session value is guessed or injected. Deterministic launcher fixtures cover both
accepted protocol/version profiles, not those unperformed live paths. This is not
certification of live Heeler or phone access.

The intervening release notes include operational changes: v0.9.0 removes
`--no-session` and changes client/server compatibility; v0.9.2 removes the
`pane.graphics.*` API; v0.9.4 leaves Unix servers running after `SIGHUP`. Do not
assume closing the launching shell stops a newer server. Preserve version-matched
binary, configuration and session backups, and use a separately approved
stop-before-install cutover. Use matching client/server versions: v0.8.0/v0.8.0
for rollback or v0.9.5/v0.9.5 for the upgrade. Verify the client resolved by PATH in
the coordinator's own pane, not only an operator shell; mixed pairs are not
certified or automatically detected by the launcher. Restore the original quiescent
old state/config before opening it with an older binary, never candidate-written
state. The preference-only reload procedure below is not a binary-upgrade procedure.
No plugin or integration adoption follows from this pin.

## Behaviors the tooling radar watches

The weekly radar compares upstream changes with these dependencies, not with a
list of every Herdr feature:

- Workspace labels and `workspace report-metadata` tokens, including `$task`,
  `$phase` and `$needs` sidebar rows, retain their meaning and update correctly.
- Git worktrees stay grouped with their repository in the sidebar.
- Saved machines remain available, and `Ctrl-B w` navigation works across them.
- Sidebar row configuration and agent sorting keep their configured behavior.
- Plugin panes remain usable across configuration reloads and client reconnects.
- `herdr api` snapshot and agent-list responses remain compatible with the
  integrations that consume them; protocol/version changes need explicit review.

The radar also tracks [workspace folders](https://github.com/herdrdev/herdr/discussions/1953)
and the [saved-machine selection API](https://github.com/herdrdev/herdr/discussions/4396).
These are upstream proposals, not features this repository claims are available.
See [the automation evidence limits](../automations/README.md#herdr-upstream-evidence).

## Lane workflow and existing-host rollout

The defaults skip the workspace-name prompt, sort Agents by attention priority, hide a
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
   if ! backup=$(mktemp "$config.backup.XXXXXX"); then
     printf 'Could not create the Herdr configuration backup.\n' >&2
     exit 1
   fi
   if ! cp -p "$config" "$backup"; then
     printf 'Could not copy the Herdr configuration to %s.\n' "$backup" >&2
     exit 1
   fi
   printf 'Backup: %s\n' "$backup"
   ```

   Manually merge the following defaults into the existing tables, preserving
   intentional overrides. Add missing tables only once; do not append duplicate
   TOML tables or replace unrelated preferences, keybindings, or onboarding state.
   Normal install/update only reports drift and never performs this refresh:

   ```toml
   [ui]
   prompt_new_workspace_name = false
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
