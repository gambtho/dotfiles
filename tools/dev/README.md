# dev — tmux + devcontainer workspaces

One command per project: `dev <name>` reconciles state, starts the project's
devcontainer when it has one, builds a tmux session with agent and shell
windows, and attaches. Running it again repairs and re-attaches; it never
destroys. `dev stop` is the only destructive verb.

One tmux server runs on the WSL host; panes `exec` into containers. Nothing is
installed into images, and `dev` refuses to run inside a container (exit 10) —
the server that owns every session lives on the host.

## Setup

`bin/install` runs `tools/dev/install.sh` as its optional `dev` phase. It
creates the state directories, installs and enables the `dev-autostart`
systemd user unit, and verifies the tmux hook block. The hooks
(`dev.tmux.conf`) load into any new tmux server via `tmux.conf.symlink`; an
already-running server needs one `tmux source-file ~/.tmux.conf`.

## Commands

| Command | Behavior |
|---|---|
| `dev <name>` / `dev` | Open (the default verb): reconcile, container up, session + layout, attach. `<name>` is a directory under `~/workspace`; with no argument the workspace resolves from the current directory. `--no-attach` does everything but attach. |
| `dev list [--json]` | Live-reconciled listing of every known workspace. `--json` is the stable snapshot contract; the state files on disk are not. |
| `dev status [<name>]` | Detail for one workspace, including configuration drift and history gaps. |
| `dev attach [<name>]` | Attach only; fails if the session is absent. |
| `dev stop [<name>] [--container]` | End the session (records `stopped/user`). `--container` also stops the bound container by id. |
| `dev config [<name>] [--compact]` | Print the merged configuration JSON. Exits 5 on validation failure. |

Linked git worktrees get their own session, named `slug--dirname`; the
inherited project config applies to all of them.

## Configuration

Three YAML layers merge, later wins, windows merge **by name**:

1. `tools/dev/default-workspace.yaml` — shipped default (below).
2. `~/.dotfiles/projects/<slug>/workspace.yaml` — per-project overlay.
3. `projects/<slug>/workspace.local.yaml` — machine-local, git-ignored.

```yaml
version: 1
autostart: false          # true: warm this project's container at boot
devcontainer:
  enabled: auto           # auto | true | false; auto = presence of .devcontainer/
  start_timeout: 300      # seconds for devcontainer up
windows:
  - name: main
    focus: true            # at most one focused window
    layout: tiled          # tmux layout name applied across the window's panes
    panes:
      - name: agent-1
        agent: claude       # a pane sets agent: OR command:, never both
        focus: true         # at most one focused pane per window
      - name: agent-2
        agent: claude
      - name: shell
        command: null       # null command = interactive shell
      - name: scratch
        command: null
        location: host      # host | container; unset = container when one exists
```

This is the shipped default: one tiled window with four panes. A window sets
`agent:` OR `command:` OR `panes:` — never more than one. The single-pane form
(a window with `agent:`/`command:` directly, no `panes:` list) is still fully
supported and is what an overlay typically adds for an extra top-level window.

Panes accept the same fields as single-pane windows — `agent`, `command`,
`cwd`, `environment`, `location` — plus a required, window-unique `name` and
an optional `focus`. `layout:` takes any of tmux's five built-in layout names
(`even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`,
`tiled`); unset defaults to `main-vertical`.

An overlay that adds `panes:` to a window it inherits from a lower layer
(e.g. adding a second pane to the default's `main` window) must also null out
that window's single-pane fields — `agent: null` (or `command: null`) — since
`agent`/`command` and `panes` are mutually exclusive and the merge is by
field, not by form. This is the strict conversion idiom: without it, the
merged window carries both an `agent`/`command` and a `panes:` list and fails
validation.

**Migrating a running workspace:** the shipped default changed from four
top-level windows (`agent-1`, `agent-2`, `shell`, `scratch`) to one `main`
window with those as panes. A workspace opened under the old default keeps
running unchanged — `dev` never destroys — but the next `dev` on it creates
the new `main` window *beside* the old windows, and `dev status` reports the
old windows as drift (undeclared, since they're no longer in the merged
config). `dev stop <name>` followed by `dev <name>` converts cleanly to the
new layout. Overlays that patched the old default's window names directly
(`agent-1`, `agent-2`, `shell`, `scratch` as window-level entries) need
updating to target `main`'s panes instead.

Re-running `dev` also respawns dead panes on every open now — previously this
only happened after a container replacement; a pane that simply exited or was
killed is now caught by the very next `dev`, no container loss required.

Windows and panes both accept `cwd` (relative to the worktree) and
`environment` (a string map, injected into the process). Window-level
`environment` now actually applies to the window's process — it was
previously parsed but silently dropped. Environment values are never written
to the event log, so `workspace.local.yaml` is the place for tokens — it
stays on the machine and out of git.

`autostart: true` is honored by the `dev-autostart` unit at boot for the
project's **primary** worktree only, and only after the workspace has been
opened at least once (discovery is from existing records, never a directory
scan). Autostart runs `devcontainer up` and nothing else — sessions and
startup commands wait for a human `dev`.

## How state works

Everything under `~/.local/state/dev/` (`DEV_STATE_ROOT`):

- `events/*.jsonl` — append-only event log. Commands and the tmux hooks
  (attach/detach/pane-death/session-close via `dev-event`) only ever append.
- `workspaces/<id>.json` — one record per workspace, a fold (projection) of
  the event log. Only reconcile writes records; every `dev` command reconciles
  before answering, so `dev list`/`dev status` are always freshly observed and
  never repair or start anything.
- `locks/` — per-workspace operation locks (`open`/`stop`/autostart take them;
  a busy workspace answers exit 7 rather than racing) and the event-log lock.
- `sessions/<session>.json` — envelope for the session-closed hook; `dev stop`
  deletes it before killing, which is how a platform stop is distinguished
  from a close it did not perform (`stopped_reason: user` vs
  `session_closed`; `vanished` / `host_restart` are inferred later).

Delete the whole state directory and the platform rebuilds its view from the
next `dev` invocation — records are projections, not sources of truth.

## Environment overrides

| Variable | Default | |
|---|---|---|
| `DEV_REPO_ROOT` | `~/workspace` | where workspace names resolve |
| `DEV_OVERLAY_ROOT` | `~/.dotfiles/projects` | per-project config overlays |
| `DEV_STATE_ROOT` | `~/.local/state/dev` | events, records, locks |
| `DEV_DOTFILES_ROOT` | `~/.dotfiles` | platform code root |

## Exit codes

`2` usage · `5` validation/corrupt-log refusal · `7` operation lock held ·
`8` reconcile retries exhausted · `10` refused inside a container.
