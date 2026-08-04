# Declarative multi-pane windows — design

Date: 2026-08-04
Status: approved design, pre-implementation

## Goal

Let one tmux window show several panes declaratively — up to a full dashboard
(two agents and two shells tiled in a single window), removing the friction of
switching windows to see each agent. `dev open` builds the panes; re-running it
repairs them; everything else about the platform keeps working.

## Decisions (all confirmed with the user)

1. **Pane-qualified agent identity** — any pane may set `agent:`; multiple
   agents per window are supported. Identity is the pair `(window, pane)`.
2. **Exclusive schema** — a window sets either the existing single-pane keys
   or `panes:`, never both.
3. **Named layouts only** — tmux's five named layouts; no per-split DSL.
4. **Repair = create missing + respawn dead + report undeclared** — never kill.
5. **Strict merge** — converting an inherited single-pane window to panes-form
   requires an explicit `agent: null` (or `command: null` removal); the mixed
   shape fails validation loudly.
6. **Pane focus** — at most one `focus: true` pane per window, re-applied on
   every open like window focus.
7. **The shipped default becomes a one-window dashboard** — this deliberately
   revises the original "default never changes" constraint; the *machinery*
   still keeps every no-panes config byte-identical.

## 1. Schema

A window declares **either** the single-pane form (today's `agent`/`command`/
`cwd`/`location`, completely unchanged) **or** `panes:`. A panes-form window
accepts only `name`, `focus`, `layout`, `panes`:

```yaml
windows:
  - name: main
    focus: true
    layout: tiled            # even-horizontal | even-vertical | main-horizontal
                             # | main-vertical | tiled; default main-vertical
    panes:
      - name: agent-1
        agent: claude
        focus: true          # at most one focused pane per window
      - name: agent-2
        agent: claude
      - name: shell
        command: null        # null command = interactive shell
      - name: scratch
        command: null
        location: host
```

Per-pane fields are exactly the single-pane window fields: `name` (required,
`[A-Za-z0-9._-]+`), `agent` xor `command`, `cwd`, `location`, `environment`,
plus `focus`. Pane names must be unique **within their window** only; identity
everywhere is `(window, pane)`, so every dashboard can have a pane named
`shell`.

**Normalization** adds the `panes` and `layout` keys **only when present** in
the merged config. Unconditionally normalizing them (like the other window
keys) would change the normalized JSON — and therefore the sha256 config
digest — of every existing workspace, spuriously reporting config drift on the
next open. This conditional normalization is what keeps constraint 8's
"byte-identical" promise for existing configs.

## 2. Pane identity in tmux

The durable answer to "which pane is the agent" is a **pane-scoped user
option** `@dev_pane`, stamped with the logical pane name at pane creation.
tmux keeps pane options through `respawn-pane` (the pane object survives; only
its process is replaced), so identity survives respawns. Only kill+recreate
restamps. tmux pane ids (`%N`) and indexes are never used as identity — only
as concrete targets resolved fresh from a query.

Stamping does not need the remain-on-exit atomic chain: `remain-on-exit` is
window-scoped and set atomically with window creation (the existing chained
invocation), so by the time any `split-window` runs it is already on, and a
fast-exiting split command leaves a *dead, held, still-targetable* pane — the
window-destruction race that motivated the original chain cannot occur for
splits. Mechanics:

- `split-window -P -F '#{pane_id}'` captures the concrete new pane id.
- `set-option -p -t "%id" @dev_pane <name>` stamps it (a dead pane still
  accepts options).

Single-pane windows are never stamped, keeping their event stream
byte-identical to today's.

**Verification item for implementation:** confirm on tmux 3.4 that the
window-scoped `pane-died` hook's format context interpolates the *dying
pane's* `#{@dev_pane}`. Fallback if not: interpolate `#{pane_id}` and resolve
it to the logical name via a query in `dev-event`.

Pane-resolving tmux commands keep the exact-match discipline: `%pane_id`
targets are unambiguous by construction; window-level targets stay
`=session:=window`, session-level stay `=session:`.

## 3. Events and fold (§4.4 changes — all additive)

- `pane.died` and `pane.respawned` gain an optional `pane` field. The
  `pane-died` hook line adds `pane=#{@dev_pane}`; `dev-event` omits the field
  when the value is empty, so single-pane windows emit today's exact bytes.
- New event `pane.created` `{window, pane, location, command}` — the
  **declared** command only, same secrets rule as `window.created` (a rendered
  command embeds `environment` values from `workspace.local.yaml`). The fold
  ignores unknown event types, so old and new events coexist in one log.
- `agent.started` gains `pane` when emitted for a panes-form window.
- Record schema: `agents[]` entries become `{window, pane, command, state}`
  with `pane: null` for single-pane windows. The fold matches events to
  entries on `(window, event.data.pane // null)`. Replaying an existing event
  log (which has no pane fields anywhere) folds to today's records plus the
  constant `pane: null` — an added field, allowed by ADR-2.
- `dev list --json`: existing fields untouched; `agents[].pane` added.
  `dev status` gains pane-level drift reporting (see §5).

## 4. Build and repair (`dev_backend_apply_layout` + `dev_open_respawn_dead`)

Every pane's command is built by the existing pair
`dev_container_exec_prefix` + `dev_window_inner_command`, with the pane object
passed where the window object is passed today (the shapes are identical).
The vekil agent-env overlay and the secrets rule ride along untouched — there
is no second quoting/env path.

Per declared window, the single-pane path is completely unchanged. For a
panes-form window:

- **Window missing** → `new-window` chained with
  `set-window-option remain-on-exit on` exactly as today (one atomic tmux
  invocation), stamp the first pane, split+stamp the remaining panes, then one
  `select-layout <layout>`. Emit `window.created`, `pane.created` × N, and
  `agent.started` for each agent pane.
- **Declared pane missing** in a live window → split + stamp + re-apply
  `select-layout`. Layout is re-applied **only when a pane was created**, so a
  no-op `dev open` never stomps manual resizes.
- **Declared pane dead** (remain-on-exit holds it) → `respawn-pane -t "%id"`,
  the id resolved from the query by `@dev_pane`, command rebuilt through the
  same path, emitting `pane.respawned {window, pane}`.
  This fixes a latent bug: today's respawn targets `=session:=window`, which
  resolves to the window's **active** pane — wrong the moment a window has two.
- **Undeclared pane** (unstamped, or stamped with a name no longer in config)
  → invisible to repair: never matched, never split into, never killed;
  reported by `dev status` as pane drift. This one rule covers manual splits,
  config-removed panes, and shape conversions of a running window.
- **Focus**: after the focused window is selected, `select-pane` the focused
  pane's current `%id`. Re-applied on every open, like window focus.

`dev_backend_query` pane objects gain `pane` (the `@dev_pane` value or null)
and `pane_id` (for targeting; not part of any durable record). In the
`list-panes` format string the new fields precede `window_name`, which stays
last to absorb spaces; `@dev_pane`'s restricted charset keeps the line
splittable, with a `#{?…}` placeholder for the unset case.

## 5. Merge and validation

Panes merge across layers **by name within their window**, using the window
algorithm verbatim (patch same names, append new ones, `IN()` not
`inside()`). New validation, all loud (exit 5):

- a merged window sets `panes` together with any single-pane key
  (`agent`, `command`, `cwd`, `location`) — names the window; the fix is an
  explicit `agent: null` / `command: null` in the overlay;
- duplicate pane names within one window;
- a pane sets both `agent` and `command`;
- invalid pane `name` charset or `location` value;
- more than one `focus: true` pane in a window;
- `layout` not one of the five tmux names, or present without `panes`;
- `panes: []` (empty list).

## 6. Default workspace and migration

`default-workspace.yaml` becomes the dashboard shown in §1: one window `main`,
`layout: tiled`, panes `agent-1`, `agent-2`, `shell`, `scratch` (scratch keeps
`location: host`). Consequences:

- **Constraint revision (explicit user choice):** the original constraint was
  "every existing workspace.yaml behaves byte-identically". The machinery
  honors that — any config without `panes` produces identical commands,
  events, and digests — but the shipped default itself changes.
- A **running** workspace's next `dev open` creates `main` beside the old four
  windows (open never destroys). The old windows become window-level drift in
  `dev status` until the user runs `dev stop` + `dev <name>`, which is the
  clean conversion. Their `agents[]` entries persist in the record (keyed by
  the old window names, `pane: null`) until then — accurate, since those
  agents really are still running.
- No project under `~/.dotfiles/projects/` currently has a `workspace.yaml`
  overlay, so nothing patches `agent-1`-by-name today and the
  overlay-stops-matching hazard is theoretical. The README should still note
  that overlays patching the old default window names must be updated when
  this ships.
- README configuration section gains the panes-form example and the
  `agent: null` conversion idiom.

## 7. Pre-existing issues discovered during design

1. **Per-window `environment` is silently dropped.** The README documents it,
   but `DEV_CONFIG_NORMALIZE_JQ` omits `environment` from the window map, so a
   window-level `environment` never reaches `dev_window_inner_command` (only
   the top-level `environment` does). Panes must support `environment`
   correctly; the window-level fix should ride along in the same change (it is
   the same jq map) — flagged so it is a decision, not an accident.
2. **Active-pane respawn targeting** (§4): `dev_backend_respawn_pane` targets
   the window, i.e. its active pane. Harmless while windows have one pane;
   must become pane-id targeting as part of this work.

## 8. Explicit exclusions (YAGNI)

- No per-split direction/size DSL; no custom layout strings.
- No nested panes, no pane-level `autostart`, no per-worktree pane config.
- No `dev` verb to prune drifted windows/panes; `dev stop` + reopen remains
  the conversion/cleanup path.
- No global pane-name uniqueness; identity is always `(window, pane)`.

## Verification strategy (for the implementation plan)

- bats: config normalization byte-identity for panes-less configs (digest
  unchanged); merge/validation matrix incl. the strict-conversion error;
  fold replay of a legacy log producing `pane: null` entries; fold routing of
  pane-qualified `pane.died`/`pane.respawned` to the right agent.
- tmux-integration: dashboard creation with fast-exiting commands (dead held
  panes, window survives); pane repair after killing one agent pane of two;
  undeclared-pane drift; layout not re-applied on no-op open; `@dev_pane`
  survival across respawn; the `pane-died` hook interpolation check from §2.
- `dev list --json` contract: existing fields byte-identical for a
  panes-less workspace.
