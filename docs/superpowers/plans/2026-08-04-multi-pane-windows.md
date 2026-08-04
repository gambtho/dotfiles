# Declarative Multi-Pane Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a `dev` workspace window declare multiple named panes (any of which may run an agent), built by `dev open`, repaired on every re-open, with pane-qualified agent state — per the approved spec `docs/superpowers/specs/2026-08-04-multi-pane-windows-design.md`.

**Architecture:** Config gains an exclusive `panes:` window form (normalized conditionally so panes-less digests never change). Pane identity is a pane-scoped tmux user option `@dev_pane`; events gain an optional `pane` field routed by the fold on `(window, pane // null)`. Only `backend-tmux.sh` touches tmux; every pane command still flows through `dev_container_exec_prefix` + `dev_window_inner_command`.

**Tech Stack:** bash + jq + yq, tmux 3.4, bats tests (real tmux via `DEV_TMUX_SOCKET`).

## Global Constraints

- Only `tools/dev/lib/backend-tmux.sh` may invoke tmux (spec §4; repo invariant).
- Every pane command goes through `dev_container_exec_prefix` + `dev_window_inner_command` — no second quoting/env path; events record the **declared** command, never the rendered one (secrets rule).
- `dev open` never destroys: no `kill-pane`, `kill-window`, `kill-session` outside `dev stop`.
- tmux targets: `-t "=session:"` (trailing colon) for pane-resolving commands, `=session:=window` for windows; concrete panes by `%id` handle only, never by index.
- A panes-less config must normalize to byte-identical JSON (same sha256 digest) as today — new keys (`panes`, `layout`, `environment`) appear in normalized output **only when present**.
- Shell style: `shfmt -i 2 -ci`; `shellcheck -x -S warning -e SC1091` must pass.
- Run make as `/usr/bin/make` (bare `make` is broken under this zsh). Full checks: `/usr/bin/make lint` and `bats tests/dev_*.bats`.
- bats tests use `setup_dev_test` from `tests/test_helper.bash`; tmux tests run a real server on socket `$DEV_TMUX_SOCKET` and must kill it in `teardown`.
- Commit after every green task; conventional-commit messages (`feat(dev): …`, `test(dev): …`).

---

### Task 1: Config — panes normalization, merge, validation

**Files:**
- Modify: `tools/dev/lib/config.sh`
- Test: `tests/dev_config_merge.bats`

**Interfaces:**
- Produces: normalized window objects that MAY carry `panes` (array of `{name, agent, command, cwd, location, focus[, environment]}`), `layout` (string), `environment` (object) — each key present only when declared. `dev_config_validate` gains the multi-pane rules. Later tasks read `.panes`, `.layout`, `.environment` with `// null` / `// {}` fallbacks.

- [ ] **Step 1: Write the failing tests** — append to `tests/dev_config_merge.bats` (it already loads config.sh; follow its existing test style):

```bash
@test "config: panes-less window normalizes without panes/layout/environment keys (digest stability)" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: solo
    command: null
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "solo")' <<<"$output")
  [ "$(jq 'has("panes")' <<<"$win")" = "false" ]
  [ "$(jq 'has("layout")' <<<"$win")" = "false" ]
  [ "$(jq 'has("environment")' <<<"$win")" = "false" ]
}

@test "config: panes normalize with per-pane defaults; window environment survives on single-pane windows" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    layout: tiled
    panes:
      - name: agent-1
        agent: claude
        focus: true
      - name: shell
        command: null
        environment: {PANE: "2"}
  - name: solo
    command: null
    environment: {WIN: "1"}
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.layout' <<<"$win")" = "tiled" ]
  [ "$(jq -c '.panes[0]' <<<"$win")" = '{"agent":"claude","command":null,"cwd":null,"focus":true,"location":null,"name":"agent-1"}' ]
  [ "$(jq -r '.panes[1].environment.PANE' <<<"$win")" = "2" ]
  # the spec §7.1 fix: window-level environment is kept for single-pane windows
  [ "$(jq -r '.windows[] | select(.name == "solo") | .environment.WIN' <<<"$output")" = "1" ]
}

@test "config: a layer defining an inherited pane twice fails loudly, never silently collapses" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    panes:
      - name: shell
        command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: main
    panes:
      - name: shell
        cwd: a
      - name: shell
        cwd: b
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]]   # bats `run` folds stderr into $output
}

@test "config: panes merge by name across layers, never by index" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    panes:
      - name: agent-1
        agent: claude
      - name: shell
        command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: main
    panes:
      - name: shell
        cwd: sub
      - name: extra
        command: htop
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 3 ]
  [ "$(jq -r '.panes[] | select(.name == "shell") | .cwd' <<<"$win")" = "sub" ]
  [ "$(jq -r '.panes[] | select(.name == "agent-1") | .agent' <<<"$win")" = "claude" ]
  [ "$(jq -r '.panes[] | select(.name == "extra") | .command' <<<"$win")" = "htop" ]
}

@test "config: converting an agent window to panes without nulling agent fails loudly" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: agent-1
    agent: claude
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: agent-1
    panes:
      - name: a
        agent: claude
EOF
  config=$(dev_config_merged "proj" "$TEST_ROOT/workspace/proj")
  run dev_config_validate "$config"
  [ "$status" -eq 5 ]
  [[ "$output" == *"agent-1"* && "$output" == *"panes"* ]]
}

@test "config: agent: null alongside panes converts cleanly; a shell window converts silently" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: agent-1
    agent: claude
  - name: shell
    command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: agent-1
    agent: null
    panes:
      - name: a
        agent: claude
  - name: shell
    panes:
      - name: s
        command: null
EOF
  config=$(dev_config_merged "proj" "$TEST_ROOT/workspace/proj")
  run dev_config_validate "$config"
  [ "$status" -eq 0 ]
}

@test "config: multi-pane validation failures are loud and name the offender" {
  bad() {
    jq -nc --argjson w "$1" '{version: 1, windows: [$w]}'
  }
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"layout":"tiled"}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"layout":"mosaic","panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":"x","command":"y","cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false},{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":true},{"name":"b","agent":null,"command":null,"cwd":null,"location":null,"focus":true}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"bad name","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  # exclusive schema: window-level environment is a single-pane key (spec §5)
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"environment":{"A":"1"},"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_config_merge.bats`
Expected: the new tests FAIL (panes dropped by normalization, validation exits 0).

- [ ] **Step 3: Implement in `tools/dev/lib/config.sh`**

Add a per-layer duplicate check and call it from `dev_config_merged`'s loop
right after `layer=$(dev_config_layer_json "$file")`. This must run on the
LAYER, not the merged result: by-name merging keeps only the last duplicate,
so post-merge validation can never see one (spec §5):

```bash
# By-name merging collapses duplicate names before post-merge validation can
# see them: a layer that defines an inherited pane twice would silently keep
# only the last patch. So duplicates are detected per layer, while the layer
# is still a layer. The post-merge duplicate checks in dev_config_validate
# stay as defense in depth for hand-fed JSON.
dev_config_layer_dup_check() {
  local file="$1" layer="$2" problem
  problem=$(jq -r '
    ([(.windows // []) | group_by(.name)[] | select(length > 1)
       | "window \(.[0].name) is defined more than once"]
     + [(.windows // [])[] | .name as $w
        | ((.panes // []) | group_by(.name)[] | select(length > 1))
        | "pane \($w)/\(.[0].name) is defined more than once"])
    | first // ""' <<<"$layer") || return 1
  [[ -z "$problem" ]] && return 0
  printf 'invalid workspace config in %s: %s\n' "$file" "$problem" >&2
  return 5
}
```

and in `dev_config_merged`:

```bash
    layer="$(dev_config_layer_json "$file")" || return 1
    dev_config_layer_dup_check "$file" "$layer" || return $?
```

Replace `DEV_CONFIG_MERGE_JQ`'s `merge_windows` with pane-aware merging (jq `*` replaces arrays wholesale, so `panes` needs the same by-name treatment windows get):

```bash
# windows merge by the name key, never by position (spec 4.1), and panes
# within a window merge the same way. IN(), not inside(): inside() is
# substring matching on strings and would swallow a new window whose name is
# a substring of an existing one.
DEV_CONFIG_MERGE_JQ='
def by_name($ws): reduce $ws[] as $w ({}; .[$w.name] = $w);
def merge_named($base; $over):
  (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(. * ($om[.name] // {})))
    + ($over | map(select((.name | IN($bn[])) | not)));
def merge_window($b; $o):
  ($b * $o)
  | if ($b.panes? != null) and ($o.panes? != null)
    then .panes = merge_named($b.panes; $o.panes)
    else . end;
def merge_windows($base; $over):
  (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(merge_window(.; ($om[.name] // {}))))
    + ($over | map(select((.name | IN($bn[])) | not)));
($a.windows // []) as $bw
| ($b.windows // []) as $ow
| ($a * $b)
| .windows = merge_windows($bw; $ow)
'
```

Extend the window map in `DEV_CONFIG_NORMALIZE_JQ`. The conditional additions are load-bearing: adding `panes`/`layout`/`environment` keys unconditionally would change the normalized JSON — and the sha256 digest — of every existing config, spuriously reporting drift (spec §1):

```bash
DEV_CONFIG_NORMALIZE_JQ='
def norm_pane:
  { name: .name,
    agent: (.agent // null),
    command: (.command // null),
    cwd: (.cwd // null),
    location: (.location // null),
    focus: (.focus // false) }
  + (if .environment != null then {environment: .environment} else {} end);
{ version: (.version // 1),
  autostart: (.autostart // false),
  devcontainer: ((.devcontainer // {}) | {
      enabled: (.enabled // "auto"),
      config: (.config // null),
      start_timeout: (.start_timeout // 300) }),
  environment: (.environment // {}),
  windows: ((.windows // []) | map(
    { name: .name,
      agent: (.agent // null),
      command: (.command // null),
      cwd: (.cwd // null),
      location: (.location // null),
      focus: (.focus // false) }
    + (if .environment != null then {environment: .environment} else {} end)
    + (if .layout != null then {layout: .layout} else {} end)
    + (if .panes != null then {panes: (.panes | map(norm_pane))} else {} end))) }
'
```

Append to the `problems` list in `dev_config_validate` (value-based mixed-shape check — normalization gives every window all single-pane keys, so key presence cannot distinguish an explicit null from an inherited one; spec §5):

```jq
+ ((.windows // []) | map(select(.panes != null
    and (.agent != null or .command != null or .cwd != null
         or .location != null or ((.environment // null) != null)))
    | "window \(.name) mixes panes with single-pane keys; null them explicitly in the overlay"))
+ ((.windows // []) | map(select(.panes != null and (.panes | length) == 0)
    | "window \(.name) declares an empty panes list"))
+ ((.windows // []) | map(select((.layout // null) != null and .panes == null)
    | "window \(.name) sets layout without panes"))
+ ((.windows // []) | map(select((.layout // null) != null
    and ((.layout | IN("even-horizontal","even-vertical","main-horizontal","main-vertical","tiled")) | not))
    | "window \(.name) has invalid layout \(.layout | tostring)"))
+ ((.windows // []) | map(. as $w | (.panes // [])[]
    | select(.agent != null and .command != null)
    | "pane \($w.name)/\(.name) sets both agent and command"))
+ ((.windows // []) | map(. as $w | (.panes // [])[]
    | select(.name == null or ((.name | tostring) | test("^[A-Za-z0-9._-]+$") | not))
    | "a pane in window \($w.name) has an invalid name; use [A-Za-z0-9._-]"))
+ ((.windows // []) | map(. as $w | (.panes // [])[]
    | select(.location != null and ((.location | IN("container","host")) | not))
    | "pane \($w.name)/\(.name) has invalid location \(.location | tostring)"))
+ ((.windows // []) | map(. as $w | ((.panes // []) | group_by(.name)[] | select(length > 1))
    | "pane \($w.name)/\(.[0].name) is defined more than once"))
+ ((.windows // []) | map(select(((.panes // []) | map(select(.focus == true)) | length) > 1)
    | "window \(.name) has more than one focused pane"))
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_config_merge.bats`
Expected: all PASS (old tests included — the merge rewrite must not break them).

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/lib/config.sh tests/dev_config_merge.bats
git commit -m "feat(dev): panes-aware config normalization, merge, and validation"
```

---

### Task 2: Fold — pane-qualified agent state

**Files:**
- Modify: `tools/dev/lib/fold.sh`
- Test: `tests/dev_fold.bats`

**Interfaces:**
- Consumes: event `data` may carry `pane` (string) on `pane.died`, `pane.respawned`, `agent.started`, `agent.exited`, `agent.failed`.
- Produces: `agents[]` entries `{window, pane, command, state}` with `pane: null` for single-pane windows. Matching key is `(window, data.pane // null)` for every pane/agent event.

- [ ] **Step 1: Write the failing tests** — append to `tests/dev_fold.bats` (it defines `mkevent` and a base record helper; reuse them):

```bash
@test "fold: pane-qualified events route to the matching agent only" {
  rec=$(base_record)
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa000000000020 2026-08-03T15:00:00.000Z agent.started '{"window":"main","pane":"agent-1","command":"claude"}')")
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000021 2026-08-03T15:01:00.000Z agent.started '{"window":"main","pane":"agent-2","command":"claude"}')")
  [ "$(jq -r '.agents | length' <<<"$out")" -eq 2 ]
  # the helper shell dying in the same window must not touch either agent
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000022 2026-08-03T15:02:00.000Z pane.died '{"window":"main","pane":"shell"}')")
  [ "$(jq -r '[.agents[].state] | unique | join(",")' <<<"$out")" = "started" ]
  # the right agent pane dying flips only that agent
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000023 2026-08-03T15:03:00.000Z pane.died '{"window":"main","pane":"agent-2"}')")
  [ "$(jq -r '.agents[] | select(.pane == "agent-2") | .state' <<<"$out")" = "exited" ]
  [ "$(jq -r '.agents[] | select(.pane == "agent-1") | .state' <<<"$out")" = "started" ]
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000024 2026-08-03T15:04:00.000Z pane.respawned '{"window":"main","pane":"agent-2"}')")
  [ "$(jq -r '.agents[] | select(.pane == "agent-2") | .state' <<<"$out")" = "started" ]
  # agent.exited and agent.failed route by pane too
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000025 2026-08-03T15:05:00.000Z agent.failed '{"window":"main","pane":"agent-1","reason":"crash"}')")
  [ "$(jq -r '.agents[] | select(.pane == "agent-1") | .state' <<<"$out")" = "failed" ]
}

@test "fold: legacy pane-less events still key by window with pane null" {
  rec=$(base_record)
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa000000000030 2026-08-03T15:10:00.000Z agent.started '{"window":"agent-1","command":"claude"}')")
  [ "$(jq -c '.agents[0] | {window, pane, state}' <<<"$out")" = '{"window":"agent-1","pane":null,"state":"started"}' ]
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000031 2026-08-03T15:11:00.000Z pane.died '{"window":"agent-1","exit_status":1}')")
  [ "$(jq -r '.agents[0].state' <<<"$out")" = "exited" ]
}
```

(If `tests/dev_fold.bats` names its record helper differently — check its top — use that name; do not invent a second fixture.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_fold.bats`
Expected: new tests FAIL (second `agent.started` for `main` overwrites the first; `pane` absent from entries).

- [ ] **Step 3: Implement in `tools/dev/lib/fold.sh`**

Replace `agent_has`/`agent_upsert` and their call sites; keep every transition an absolute assignment:

```jq
def agent_matches($d): .window == $d.window and ((.pane // null) == ($d.pane // null));
def agent_has($d): any(.agents[]; agent_matches($d));

def agent_upsert($d; $patch):
  if ($d.window // null) == null then .
  elif agent_has($d) then
    .agents = [.agents[] | if agent_matches($d) then . + $patch else . end]
  else
    .agents = (.agents
      + [{window: $d.window, pane: ($d.pane // null), command: null, state: null} + $patch])
  end;
```

Update the transitions to pass `$d` instead of `$d.window`:

```jq
elif $ev.event == "pane.died" then
  if agent_has($d) then agent_upsert($d; {state: "exited"}) else . end
elif $ev.event == "pane.respawned" then
  if agent_has($d) then agent_upsert($d; {state: "started"}) else . end
...
elif $ev.event == "agent.started" then
  agent_upsert($d; {command: $d.command, state: "started"})
elif $ev.event == "agent.exited" then
  agent_upsert($d; {state: "exited"})
elif $ev.event == "agent.failed" then
  agent_upsert($d; {state: "failed"})
```

Add to the invariant comment block at the top of the file: identity for agent state is `(window, data.pane // null)`; legacy pane-less events and records fold identically with `pane: null` (spec §3).

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_fold.bats`
Expected: all PASS, including the pre-existing legacy tests (they assert window-keyed behavior, which `pane: null` preserves — if one asserts an exact `agents[0]` object without `pane`, update that assertion to include `"pane":null` and note it in the commit message as the ADR-2-additive field).

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/lib/fold.sh tests/dev_fold.bats
git commit -m "feat(dev): pane-qualified agent identity in the event fold"
```

---

### Task 3: dev-event `pane=` skip + pane-died hook

**Files:**
- Modify: `tools/dev/dev-event`
- Modify: `tools/dev/dev.tmux.conf`
- Test: `tests/dev_state_events.bats` (unit), `tests/dev_install.bats` (hook integration)

**Interfaces:**
- Produces: `pane.died` events carry `"pane": "<logical name>"` when the dying pane has `@dev_pane` set, and are byte-identical to today's when it is not. Depends on Task 5 stamping `@dev_pane` (the integration test stamps manually, so this task is independently testable).

- [ ] **Step 1: Write the failing unit test** — append to `tests/dev_state_events.bats`:

```bash
@test "dev-event: an empty pane= pair is skipped; a non-empty one is recorded" {
  run "$REPO_ROOT/tools/dev/dev-event" ws1 proj sess "$TEST_ROOT/workspace/proj" \
    pane.died 'window=agent-1' 'pane='
  [ "$status" -eq 0 ]
  line=$(tail -n 1 "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r '.data | has("pane")' <<<"$line")" = "false" ]
  [ "$(jq -r '.data.window' <<<"$line")" = "agent-1" ]

  run "$REPO_ROOT/tools/dev/dev-event" ws1 proj sess "$TEST_ROOT/workspace/proj" \
    pane.died 'window=main' 'pane=shell'
  [ "$status" -eq 0 ]
  line=$(tail -n 1 "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r '.data.pane' <<<"$line")" = "shell" ]

  # other keys keep record-everything behavior, empty or not
  run "$REPO_ROOT/tools/dev/dev-event" ws1 proj sess "$TEST_ROOT/workspace/proj" \
    workspace.attached 'client='
  [ "$status" -eq 0 ]
  line=$(tail -n 1 "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r '.data.client' <<<"$line")" = "" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_state_events.bats`
Expected: FAIL — `has("pane")` is `true` with value `""`.

- [ ] **Step 3: Implement**

In `tools/dev/dev-event`, inside `dev_event_data_from_pairs`'s loop, after `value` is extracted:

```bash
    # `pane=` with an empty value is skipped — and ONLY pane. The pane-died
    # hook interpolates #{@dev_pane} unconditionally, and single-pane windows
    # are never stamped, so this is what keeps their pane.died bytes identical
    # to the pre-panes era (spec §3). Every other key keeps record-everything
    # behavior: an empty client or exit_status is an observation, not noise.
    if [[ "$key" == pane && -z "$value" ]]; then
      continue
    fi
```

In `tools/dev/dev.tmux.conf`, extend the pane-died hook line (keep it one line, same quoting pattern as the current one):

```
set-hook -gw pane-died "run-shell -b \"~/.dotfiles/tools/dev/dev-event '#{@dev_workspace_id}' '#{@dev_slug}' '#{session_name}' '#{@dev_worktree}' pane.died 'window=#{window_name}' 'pane=#{@dev_pane}'\""
```

- [ ] **Step 4: Write the failing hook integration test** — append to `tests/dev_install.bats`, following the existing hook tests there (they `dev_backend_create` a session, `source-file` the conf, and poll the event log). This is also the spec §2 verification item: does the window-scoped `pane-died` hook interpolate the dying pane's `@dev_pane`?

```bash
@test "pane-died hook reports the dying pane's @dev_pane and omits it when unstamped" {
  setup_hook_session   # or inline the same session/bootstrap the neighboring hook tests use
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"

  # window w1: one stamped pane, one unstamped
  dev_tmux new-window -d -t "=proj:" -n w1 "sleep 30" \
    ';' set-window-option -t "=proj:=w1" remain-on-exit on
  pid=$(dev_tmux split-window -d -P -F '#{pane_id}' -t "=proj:=w1" "sleep 30")
  dev_tmux set-option -p -t "$pid" @dev_pane helper

  dev_tmux respawn-pane -k -t "$pid" 'exit 1'
  for _ in $(seq 1 50); do
    grep -q '"pane":"helper"' "$DEV_STATE_ROOT/events/events.jsonl" 2>/dev/null && break
    sleep 0.1
  done
  line=$(grep '"pane":"helper"' "$DEV_STATE_ROOT/events/events.jsonl" | tail -n 1)
  [ "$(jq -r '.event' <<<"$line")" = "pane.died" ]
  [ "$(jq -r '.data.window' <<<"$line")" = "w1" ]

  # the unstamped pane dies -> event has window only, no pane key
  upid=$(dev_tmux list-panes -t "=proj:=w1" -F '#{pane_id} #{?#{@dev_pane},s,-}' | awk '$2 == "-" {print $1; exit}')
  dev_tmux respawn-pane -k -t "$upid" 'exit 1'
  for _ in $(seq 1 50); do
    n=$(grep -c '"event":"pane.died"' "$DEV_STATE_ROOT/events/events.jsonl" 2>/dev/null || echo 0)
    [ "$n" -ge 2 ] && break
    sleep 0.1
  done
  line=$(grep '"event":"pane.died"' "$DEV_STATE_ROOT/events/events.jsonl" | tail -n 1)
  [ "$(jq -r '.data | has("pane")' <<<"$line")" = "false" ]
}

@test "pane-died from a fast-exiting split still carries the pane name (atomic stamp)" {
  setup_hook_session
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"
  dev_tmux new-window -d -t "=proj:" -n w2 "sleep 30" \
    ';' set-window-option -t "=proj:=w2" remain-on-exit on
  # the command exits immediately: if the stamp were a second invocation, the
  # hook could fire first and emit an identity-less pane.died (spec §2)
  dev_tmux split-window -t "=proj:=w2" 'exit 1' \
    ';' set-option -p -t "=proj:=w2" @dev_pane fast
  for _ in $(seq 1 50); do
    grep -q '"pane":"fast"' "$DEV_STATE_ROOT/events/events.jsonl" 2>/dev/null && break
    sleep 0.1
  done
  line=$(grep '"pane":"fast"' "$DEV_STATE_ROOT/events/events.jsonl" | tail -n 1)
  [ "$(jq -r '.event' <<<"$line")" = "pane.died" ]
  [ "$(jq -r '.data.window' <<<"$line")" = "w2" ]
}
```

(Adapt the session bootstrap to whatever the neighboring hook tests in `dev_install.bats` actually do — reuse their helper if one exists, including the `~/.dotfiles` symlink they set up so `run-shell` finds `dev-event`. If `#{@dev_pane}` turns out NOT to interpolate in the hook context on tmux 3.4, STOP and flag it: the fallback design is interpolating `#{pane_id}` and resolving it in `dev-event`, which is a spec change requiring user sign-off.)

- [ ] **Step 5: Run both test files**

Run: `bats tests/dev_state_events.bats tests/dev_install.bats`
Expected: all PASS.

- [ ] **Step 6: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/dev-event tools/dev/dev.tmux.conf tests/dev_state_events.bats tests/dev_install.bats
git commit -m "feat(dev): pane discriminator on pane.died, omitted when unstamped"
```

---

### Task 4: Backend query — pane names and handles

**Files:**
- Modify: `tools/dev/lib/backend-tmux.sh` (`dev_backend_query`)
- Test: `tests/dev_backend_tmux.bats`

**Interfaces:**
- Produces: `dev_backend_query` window objects become `{name, panes: [{alive, pane, pane_id}]}` — `pane` is the `@dev_pane` logical name or null; `pane_id` is the opaque backend pane handle (tmux `%id`, the spec §4 name), valid only while the pane exists, never persisted. Existing consumers reading `.panes[].alive` are untouched.

- [ ] **Step 1: Write the failing test** — append to `tests/dev_backend_tmux.bats`:

```bash
@test "query reports pane logical names and handles; unstamped panes report pane:null" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_tmux new-window -d -t "=proj:" -n w1 "sleep 30" \
    ';' set-window-option -t "=proj:=w1" remain-on-exit on \
    ';' set-option -p -t "=proj:=w1" @dev_pane agent-1
  pid=$(dev_tmux split-window -d -P -F '#{pane_id}' -t "=proj:=w1" "sleep 30")
  dev_tmux set-option -p -t "$pid" @dev_pane shell
  dev_tmux split-window -d -t "=proj:=w1" "sleep 30"   # unstamped

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "w1")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 3 ]
  [ "$(jq -r '[.panes[].pane] | sort | join(",")' <<<"$win")" = ",agent-1,shell" ]
  [ "$(jq -r '[.panes[] | select(.pane == "shell") | .pane_id] | first' <<<"$win")" = "$pid" ]
  [ "$(jq -r '[.panes[] | select(.pane == null)] | length' <<<"$win")" -eq 1 ]
}
```

(`[.panes[].pane] | sort | join(",")` renders null as empty — hence the leading comma.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_backend_tmux.bats`
Expected: new test FAILS (`pane`/`pane_id` fields absent).

- [ ] **Step 3: Implement** — in `dev_backend_query`, change the format and the jq. `window_name` stays last to absorb spaces; `@dev_pane`'s validated charset (`[A-Za-z0-9._-]`) keeps the middle fields splittable, with `-` as the unset placeholder:

```bash
  if ! panes=$(dev_tmux list-panes -s -t "=$session_name:" \
    -F '#{pane_dead} #{window_index} #{pane_id} #{?#{@dev_pane},#{@dev_pane},-} #{window_name}' 2>/dev/null); then
```

```jq
    (split("\n")
     | map(select(length > 0))
     | map(capture("^(?<dead>[01]) (?<idx>[0-9]+) (?<pid>%[0-9]+) (?<pn>[^ ]+) (?<name>.*)$")))
    | group_by(.idx | tonumber)
    | map({name: .[0].name,
           panes: map({alive: (.dead == "0"),
                       pane: (if .pn == "-" then null else .pn end),
                       pane_id: .pid})})
```

Add to the function comment: `pane_id` is an opaque, ephemeral backend handle for targeting a live pane (respawn, select); it is never written to events or records — logical identity is `pane`.

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_backend_tmux.bats`
Expected: all PASS (existing query tests only read `alive`/`name`).

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/lib/backend-tmux.sh tests/dev_backend_tmux.bats
git commit -m "feat(dev): backend query exposes pane logical names and handles"
```

---

### Task 5: Backend — panes-form window creation, missing-pane repair, layout, focus

**Files:**
- Modify: `tools/dev/lib/backend-tmux.sh` (`dev_backend_apply_layout` + new helper `dev_backend_ensure_pane_window`)
- Test: `tests/dev_backend_tmux.bats`

**Interfaces:**
- Consumes: Task 1's normalized `panes`/`layout`/`environment`; Task 4's query shape; `dev_window_location` / `dev_container_exec_prefix` / `dev_window_workdir` / `dev_window_inner_command` from `container.sh` — a pane object has exactly the fields those functions read from a window object, so pane JSON is passed where window JSON goes today.
- Produces: panes-form windows built and repaired; events `window.created {window, panes: [names]}` (no `location`/`command` — spec's §4.4 amendment), `pane.created {window, pane, location, command}` (declared command), `agent.started {window, pane, command}`. Effective environment: panes-form panes get `global * pane.environment` (the exclusive schema forbids window-level `environment` beside `panes` — Task 1 validates that); single-pane windows get `global * window.environment` (the spec §7.1 fix).

- [ ] **Step 1: Write the failing tests** — append to `tests/dev_backend_tmux.bats`:

```bash
fixture_pane_config() {
  jq -nc '{
    version: 1, autostart: false,
    devcontainer: {enabled: "auto", start_timeout: 300},
    environment: {},
    windows: [
      {name: "main", agent: null, command: null, cwd: null, location: null,
       focus: true, layout: "tiled",
       panes: [
         {name: "agent-1", agent: "sleep 30", command: null, cwd: null, location: null, focus: true},
         {name: "agent-2", agent: "sleep 30", command: null, cwd: null, location: null, focus: false},
         {name: "shell",   agent: null, command: null, cwd: null, location: null, focus: false},
         {name: "scratch", agent: null, command: null, cwd: null, location: "host", focus: false}
       ]}
    ]}'
}

@test "apply_layout builds a panes-form window with stamped panes and applies the layout" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 4 ]
  [ "$(jq -r '[.panes[].pane] | sort | join(",")' <<<"$win")" = "agent-1,agent-2,scratch,shell" ]
  [ "$(jq -r '[.panes[].alive] | unique | join(",")' <<<"$win")" = "true" ]
  # remain-on-exit protects the whole window
  run dev_tmux show-window-options -t "=proj:=main" remain-on-exit
  [[ "$output" == *on* ]]
  # the focused pane is the window's active pane
  [ "$(dev_tmux display-message -p -t '=proj:=main' '#{@dev_pane}')" = "agent-1" ]
}

@test "apply_layout emits amended window.created, pane.created x4, agent.started with pane" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"
  local log="$DEV_STATE_ROOT/events/events.jsonl"

  wc_line=$(grep '"event":"window.created"' "$log")
  [ "$(jq -r '.data.window' <<<"$wc_line")" = "main" ]
  [ "$(jq -r '.data | has("location")' <<<"$wc_line")" = "false" ]
  [ "$(jq -r '.data | has("command")' <<<"$wc_line")" = "false" ]
  [ "$(jq -r '.data.panes | join(",")' <<<"$wc_line")" = "agent-1,agent-2,shell,scratch" ]

  [ "$(grep -c '"event":"pane.created"' "$log")" -eq 4 ]
  pc=$(grep '"event":"pane.created"' "$log" | head -n 1)
  [ "$(jq -r '.data.pane' <<<"$pc")" = "agent-1" ]
  [ "$(jq -r '.data.command' <<<"$pc")" = "sleep 30" ]

  [ "$(grep -c '"event":"agent.started"' "$log")" -eq 2 ]
  as_line=$(grep '"event":"agent.started"' "$log" | head -n 1)
  [ "$(jq -r '.data.pane' <<<"$as_line")" = "agent-1" ]
}

@test "apply_layout is idempotent for panes-form windows and repairs a missing declared pane" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"

  before=$(dev_tmux list-panes -t "=proj:=main" -F '#{pane_id}' | sort)
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"
  after=$(dev_tmux list-panes -t "=proj:=main" -F '#{pane_id}' | sort)
  [ "$before" = "$after" ]

  # kill one pane outright (as a user would); re-apply recreates exactly it
  victim=$(dev_tmux list-panes -t "=proj:=main" -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' |
    awk '$2 == "shell" {print $1; exit}')
  dev_tmux kill-pane -t "$victim"
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"
  run dev_backend_query "proj"
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 4 ]
  [ "$(jq -r '[.panes[] | select(.pane == "shell")] | length' <<<"$win")" -eq 1 ]
}

@test "apply_layout survives fast-exiting pane commands: dead, held, and stamped" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  cfg=$(jq -c '.windows[0].panes[2].command = "exit 5"' <<<"$(fixture_pane_config)")
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  # the window survives and all four panes exist; the fast-exiting one is dead
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 4 ]
  dead=$(jq -c '.panes[] | select(.alive | not)' <<<"$win")
  [ "$(jq -r '.pane' <<<"$dead")" = "shell" ]
}

@test "apply_layout leaves undeclared panes alone and single-pane window env includes window environment" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  cfg=$(jq -c '.windows[0].panes |= .[0:2]' <<<"$(fixture_pane_config)")
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  # a manual, unstamped split survives a re-apply untouched
  manual=$(dev_tmux split-window -d -P -F '#{pane_id}' -t "=proj:=main" "sleep 30")
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  run dev_tmux list-panes -t "=proj:=main" -F '#{pane_id}'
  [[ "$output" == *"$manual"* ]]

  # window-level environment reaches a single-pane window's process (spec §7.1 fix)
  envcfg=$(jq -nc '{
    version: 1, autostart: false,
    devcontainer: {enabled: "auto", start_timeout: 300},
    environment: {},
    windows: [{name: "envwin", agent: null,
               command: "printf %s \"$PROBE\" > probe.txt; sleep 30",
               cwd: null, location: "host", focus: false,
               environment: {PROBE: "from-window"}}]}')
  dev_backend_apply_layout "proj" "$envcfg" "$(fixture_record)"
  for _ in $(seq 1 50); do
    [ -s "$TEST_WT/probe.txt" ] && break
    sleep 0.1
  done
  [ "$(cat "$TEST_WT/probe.txt")" = "from-window" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_backend_tmux.bats`
Expected: new tests FAIL (panes-form windows created as one pane running nothing sensible / no stamps / no events).

- [ ] **Step 3: Implement in `tools/dev/lib/backend-tmux.sh`**

Add a helper above `dev_backend_apply_layout`:

```bash
# dev_backend_ensure_pane_window <session_name> <window_json> <record_json> \
#   <global_env_json> <exists 0|1>
#
# Creates a panes-form window (first pane rides new-window) and/or the declared
# panes it is missing, stamps each with the pane-scoped @dev_pane user option,
# and applies the window's named layout when anything was created. Undeclared
# panes — unstamped, or stamped with a name the config no longer declares —
# are invisible here: never matched, never split into, never killed (§1.2).
#
# EVERY stamp is chained into the same tmux invocation as the pane's creation.
# For the first pane the chain rides new-window (the window target resolves to
# its active — sole — pane) alongside remain-on-exit, exactly like the
# single-pane path. For splits the window cannot be destroyed (remain-on-exit
# is already on, so a fast-exiting command leaves a dead, held pane), but a
# SECOND race remains: the pane-died hook can fire before a separate second
# invocation stamps @dev_pane, and an unstamped death event has no pane
# identity for the fold to route. So split-window runs WITHOUT -d — the new
# pane becomes the window's active pane — and the chained set-option's window
# target resolves to it inside one atomic server request. The active-pane
# side effect is corrected by the focus pass at the end of apply_layout.
dev_backend_ensure_pane_window() {
  local session_name="$1" window_json="$2" record_json="$3" global_env="$4" exists="$5"
  local workspace_id slug worktree wname layout stamped
  local pane_json pname pane_env location workdir inner pane_cmd created=0
  local -a prefix
  local ev_id ev_ts data line

  workspace_id=$(jq -r '.workspace_id' <<<"$record_json")
  slug=$(jq -r '.slug' <<<"$record_json")
  worktree=$(jq -r '.worktree' <<<"$record_json")
  wname=$(jq -r '.name' <<<"$window_json")
  layout=$(jq -r '.layout // "main-vertical"' <<<"$window_json")

  if [[ "$exists" -eq 1 ]]; then
    stamped=$(dev_tmux list-panes -t "=$session_name:=$wname" \
      -F '#{?#{@dev_pane},#{@dev_pane},}' 2>/dev/null || true)
  else
    stamped=""
  fi

  while IFS= read -r pane_json; do
    [[ -n "$pane_json" ]] || continue
    pname=$(jq -r '.name' <<<"$pane_json")
    if [[ -n "$stamped" ]] && printf '%s\n' "$stamped" | grep -Fxq -- "$pname"; then
      continue
    fi
    # global * pane.environment only: the exclusive schema forbids window-level
    # environment beside panes (validated in config), so there is no window
    # layer to merge here.
    pane_env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$pane_json")
    location=$(dev_window_location "$record_json" "$pane_json") || return 1
    mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$pane_json") || return 1
    [[ ${#prefix[@]} -gt 0 ]] || return 1
    inner=$(dev_window_inner_command "$record_json" "$pane_json" "$pane_env") || return 1
    printf -v pane_cmd '%q ' "${prefix[@]}"
    printf -v pane_cmd '%s%q' "$pane_cmd" "$inner"
    if [[ "$location" == host ]]; then
      workdir=$(dev_window_workdir "$record_json" "$pane_json") || return 1
    else
      workdir="$worktree"
    fi

    if [[ "$exists" -eq 0 ]]; then
      dev_tmux new-window -d -t "=$session_name:" -n "$wname" -c "$workdir" "$pane_cmd" \
        ';' set-window-option -t "=$session_name:=$wname" remain-on-exit on \
        ';' set-option -p -t "=$session_name:=$wname" @dev_pane "$pname" || return 1
      exists=1
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      # §4.4 amendment: a panes-form window.created carries the pane roster and
      # neither location nor command — a mixed host/container window has no
      # window-level truth for either (absent means "not known").
      data=$(jq -c '{window: .name, panes: [.panes[].name]}' <<<"$window_json")
      line=$(dev_event_build "$ev_id" "$ev_ts" "window.created" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    else
      dev_tmux split-window -t "=$session_name:=$wname" -c "$workdir" "$pane_cmd" \
        ';' set-option -p -t "=$session_name:=$wname" @dev_pane "$pname" || return 1
    fi
    created=$((created + 1))

    ev_id=$(dev_event_id_random)
    ev_ts=$(dev_now)
    # The DECLARED command, never the rendered one (secrets rule).
    data=$(jq -c --arg w "$wname" --arg loc "$location" \
      '{window: $w, pane: .name, location: $loc, command: (.command // .agent // null)}' \
      <<<"$pane_json")
    line=$(dev_event_build "$ev_id" "$ev_ts" "pane.created" \
      "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
    dev_event_append "$line"

    if [[ "$(jq -r '.agent // ""' <<<"$pane_json")" != "" ]]; then
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      data=$(jq -c --arg w "$wname" '{window: $w, pane: .name, command: .agent}' <<<"$pane_json")
      line=$(dev_event_build "$ev_id" "$ev_ts" "agent.started" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    fi
  done < <(jq -c '.panes[]' <<<"$window_json")

  if [[ "$created" -gt 0 ]]; then
    # Applied only when a pane was created: re-applying on a no-op open would
    # stomp the user's manual resizes (spec §4).
    dev_tmux select-layout -t "=$session_name:=$wname" "$layout" || return 1
  fi
  printf '%s\n' "$created"
}
```

In `dev_backend_apply_layout`'s window loop, branch on shape and thread window-level environment into the single-pane path too:

```bash
    win_created=0
    if [[ "$(jq -r '.panes != null' <<<"$window_json")" == true ]]; then
      if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
        win_created=$(dev_backend_ensure_pane_window "$session_name" "$window_json" \
          "$record_json" "$env_json" 1) || return 1
      else
        win_created=$(dev_backend_ensure_pane_window "$session_name" "$window_json" \
          "$record_json" "$env_json" 0) || return 1
      fi
      created=$((created + win_created))
      continue
    fi
    if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      continue
    fi
```

and in the single-pane path replace the `inner=...` line's env argument:

```bash
    win_env=$(jq -c --argjson g "$env_json" '$g * (.environment // {})' <<<"$window_json")
    inner=$(dev_window_inner_command "$record_json" "$window_json" "$win_env") || return 1
```

(Note the existing `existing`/`grep -Fxq` idiom and the dev-holder cleanup + focus block below the loop stay; `created` now counts panes as well as windows, which only feeds the `> 0` holder check.)

After the existing `focus_window` block, add pane focus (re-applied every open, like window focus; validation guarantees at most one per window):

```bash
  while IFS=$'\t' read -r fw fp; do
    [[ -n "$fw" ]] || continue
    pid=$(dev_tmux list-panes -t "=$session_name:=$fw" \
      -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' 2>/dev/null |
      awk -v p="$fp" '$2 == p {print $1; exit}')
    [[ -n "$pid" ]] || continue
    dev_tmux select-pane -t "$pid" 2>/dev/null || true
  done < <(printf '%s' "$config_json" | jq -r '
    (.windows // [])[] | select(.panes != null) | .name as $w
    | .panes[] | select(.focus == true) | [$w, .name] | @tsv')
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_backend_tmux.bats`
Expected: all PASS, including every pre-existing apply_layout test (single-pane events must be byte-shaped exactly as before).

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/lib/backend-tmux.sh tests/dev_backend_tmux.bats
git commit -m "feat(dev): build and repair panes-form windows with stamped identity"
```

---

### Task 6: Backend — pane-targeted respawn

**Files:**
- Modify: `tools/dev/lib/backend-tmux.sh` (`dev_backend_respawn_pane`)
- Test: `tests/dev_backend_tmux.bats`

**Interfaces:**
- Consumes: Task 4's `pane_id` handle; the `fixture_pane_config` bats helper Task 5 added to `tests/dev_backend_tmux.bats`.
- Produces: `dev_backend_respawn_pane <session> <window> <command> [container_id] [pane_handle] [pane_name]` — with a handle it respawns exactly that pane; `pane_name` (when non-empty) is added to the `pane.respawned` event data. Still the SOLE emitter of `pane.respawned`.

- [ ] **Step 1: Write the failing test** — append to `tests/dev_backend_tmux.bats`:

```bash
@test "respawn_pane with a handle revives exactly that pane and stamps survive" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_pane_config)" "$(fixture_record)"

  target=$(dev_tmux list-panes -t "=proj:=main" -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' |
    awk '$2 == "agent-2" {print $1; exit}')
  dev_tmux respawn-pane -k -t "$target" 'exit 7'
  for _ in $(seq 1 50); do
    [ "$(dev_tmux display-message -p -t "$target" '#{pane_dead}')" = "1" ] && break
    sleep 0.1
  done
  # make a DIFFERENT pane the window's active pane, to prove targeting is by
  # handle and not by the old window-target (= active pane) bug
  other=$(dev_tmux list-panes -t "=proj:=main" -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' |
    awk '$2 == "shell" {print $1; exit}')
  dev_tmux select-pane -t "$other"

  dev_backend_respawn_pane "proj" "main" "sleep 30" "" "$target" "agent-2"
  [ "$(dev_tmux display-message -p -t "$target" '#{pane_dead}')" = "0" ]
  [ "$(dev_tmux display-message -p -t "$target" '#{@dev_pane}')" = "agent-2" ]

  line=$(grep '"event":"pane.respawned"' "$DEV_STATE_ROOT/events/events.jsonl" | tail -n 1)
  [ "$(jq -r '.data.window' <<<"$line")" = "main" ]
  [ "$(jq -r '.data.pane' <<<"$line")" = "agent-2" ]
}

@test "respawn_pane without a handle keeps the single-pane event bytes" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"
  dev_backend_respawn_pane "proj" "shell" "sleep 30" "cid-1"
  line=$(grep '"event":"pane.respawned"' "$DEV_STATE_ROOT/events/events.jsonl" | tail -n 1)
  [ "$(jq -r '.data | has("pane")' <<<"$line")" = "false" ]
  [ "$(jq -r '.data.container_id' <<<"$line")" = "cid-1" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_backend_tmux.bats`
Expected: first new test FAILS (extra args ignored; wrong pane respawned / no `pane` in event).

- [ ] **Step 3: Implement** — change `dev_backend_respawn_pane`'s head and event data:

```bash
# dev_backend_respawn_pane <session_name> <window> <command> [container_id] \
#   [pane_handle] [pane_name]
#
# With a pane_handle (an id from dev_backend_query) the respawn targets exactly
# that pane; without one it falls back to the window target, which tmux
# resolves to the window's ACTIVE pane — correct only for single-pane windows,
# which is the only caller that omits it. pane_name, when non-empty, is the
# logical @dev_pane identity and is recorded on the event; the stamp itself
# survives respawn because the pane object does.
dev_backend_respawn_pane() {
  local session_name="$1" window="$2" pane_command="$3" container_id="${4:-}"
  local pane_handle="${5:-}" pane_name="${6:-}"
  local target workspace_id slug worktree ev_id ev_ts data line
  if [[ -n "$pane_handle" ]]; then
    target="$pane_handle"
  else
    target="=$session_name:=$window"
  fi
  dev_tmux respawn-pane -k -t "$target" "$pane_command" || return 1
```

and:

```bash
  data=$(jq -nc --arg w "$window" --arg p "$pane_name" --arg c "$container_id" \
    '{window: $w}
     + (if $p == "" then {} else {pane: $p} end)
     + (if $c == "" then {} else {container_id: $c} end)')
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_backend_tmux.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/lib/backend-tmux.sh tests/dev_backend_tmux.bats
git commit -m "feat(dev): pane-handle targeting for respawn, pane on the event"
```

---

### Task 7: Open — repair on every open, per-pane

**Files:**
- Modify: `tools/dev/commands/open.sh` (`dev_open_respawn_dead`, `dev_open_ensure_locked`)
- Test: `tests/dev_commands.bats`

**Interfaces:**
- Consumes: Task 4 query (`pane`, `pane_id`), Task 6 respawn signature, Task 1 config shape.
- Produces: dead declared panes respawn on EVERY `dev open` (gate removed); env parity `global * window.environment * pane.environment` with creation.

- [ ] **Step 1: Write the failing test** — append to `tests/dev_commands.bats`, reusing its scenario scaffolding (fake `DEV_DOTFILES_ROOT` root, stubbed agent commands, real tmux). The exact bootstrap must copy what the existing "open after a container loss … respawns dead panes" test does, minus the container parts:

```bash
@test "plain re-open respawns a dead pane in a host-only workspace (no container loss required)" {
  scenario_setup_demo_workspace   # reuse/extract the same bootstrap the container-loss respawn test uses
  run dev open demo --no-attach
  [ "$status" -eq 0 ]

  dev_tmux respawn-pane -k -t '=demo:=shell' 'exit 3'
  for _ in $(seq 1 50); do
    [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "1" ] && break
    sleep 0.1
  done

  run dev open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "0" ]
  grep -q '"event":"pane.respawned"' "$DEV_STATE_ROOT/events/events.jsonl"
}

@test "re-open respawns one dead agent pane of two and leaves the other agent untouched" {
  scenario_setup_demo_workspace
  mkdir -p "$DEV_OVERLAY_ROOT/demo"
  cat >"$DEV_OVERLAY_ROOT/demo/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: dash
    layout: tiled
    panes:
      - name: agent-1
        agent: sleep 30
      - name: agent-2
        agent: sleep 30
EOF
  run dev open demo --no-attach
  [ "$status" -eq 0 ]

  victim=$(dev_tmux list-panes -t '=demo:=dash' -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' |
    awk '$2 == "agent-2" {print $1; exit}')
  dev_tmux respawn-pane -k -t "$victim" 'exit 1'
  for _ in $(seq 1 50); do
    [ "$(dev_tmux display-message -p -t "$victim" '#{pane_dead}')" = "1" ] && break
    sleep 0.1
  done

  run dev open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$(dev_tmux display-message -p -t "$victim" '#{pane_dead}')" = "0" ]

  record=$(cat "$DEV_STATE_ROOT"/workspaces/*.json)
  [ "$(jq -r '.agents[] | select(.pane == "agent-2") | .state' <<<"$record")" = "started" ]
  # agent-1 never died: exactly one lifecycle event for it, the start
  [ "$(jq -r '.agents[] | select(.pane == "agent-1") | .state' <<<"$record")" = "started" ]
  [ "$(grep -c '"pane":"agent-1"' "$DEV_STATE_ROOT/events/events.jsonl")" -eq 2 ]  # pane.created + agent.started only
}
```

(The last assertion counts `pane.created` + `agent.started` for agent-1 — if the pane-died hook is active in this scenario's tmux server and fires for agent-2's kill, that adds agent-2 events, not agent-1's. Adjust the exact count only if `scenario_setup_demo_workspace` sources the hook conf; the invariant under test is that agent-1 gained no death/respawn events.)

(If no shared bootstrap function exists, extract one from the container-loss test rather than duplicating the ~15 setup lines; name it `scenario_setup_demo_workspace` and have both tests call it.)

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_commands.bats`
Expected: new test FAILS — the pane stays dead (`repair` gate never fires without container loss).

- [ ] **Step 3: Implement in `tools/dev/commands/open.sh`**

In `dev_open_ensure_locked`, replace the gated call:

```bash
  if [[ "$repair" -eq 1 && "$created" -eq 0 ]]; then
    dev_open_respawn_dead "$config" "$record"
  fi
```

with an unconditional one (idempotent — only dead declared panes are touched; spec §4 removed the gate deliberately, and a dead agent now respawns on plain `dev <name>`):

```bash
  dev_open_respawn_dead "$config" "$record"
```

Rewrite `dev_open_respawn_dead` per-pane:

```bash
# Only panes the backend reports dead are touched; a live pane is never
# respawned, so running this on every open is idempotent (spec §4 removed the
# old container-loss gate). Undeclared panes — unstamped, or stamped with a
# name the config no longer declares — are skipped: they are drift for
# `dev status` to report, not ours to touch. A single-pane window with extra
# manual panes is skipped for the same reason: the window target cannot say
# which pane is the declared one.
dev_open_respawn_dead() {
  local config="$1" record="$2"
  local query cid global_env win pname handle total wjson pjson env cmd
  query=$(dev_backend_query "$DEV_OPEN_SESSION")
  cid=$(jq -r '.container.id // ""' <<<"$record")
  global_env=$(jq -c '.environment // {}' <<<"$config")
  while IFS=$'\t' read -r win pname handle total; do
    [[ -n "$win" ]] || continue
    wjson=$(jq -c --arg w "$win" 'first(.windows[] | select(.name == $w)) // empty' <<<"$config")
    [[ -n "$wjson" ]] || continue
    if [[ "$(jq -r '.panes != null' <<<"$wjson")" == true ]]; then
      [[ "$pname" != "-" ]] || continue
      pjson=$(jq -c --arg p "$pname" 'first(.panes[] | select(.name == $p)) // empty' <<<"$wjson")
      [[ -n "$pjson" ]] || continue
      env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$wjson")
      env=$(jq -c --argjson w "$env" '$w * (.environment // {})' <<<"$pjson")
      cmd=$(dev_open_window_command "$record" "$pjson" "$env") || continue
      dev_backend_respawn_pane "$DEV_OPEN_SESSION" "$win" "$cmd" "$cid" "$handle" "$pname" || continue
    else
      [[ "$total" -eq 1 ]] || continue
      env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$wjson")
      cmd=$(dev_open_window_command "$record" "$wjson" "$env") || continue
      dev_backend_respawn_pane "$DEV_OPEN_SESSION" "$win" "$cmd" "$cid" "$handle" || continue
    fi
  done < <(jq -r '.windows[] | .name as $w | (.panes | length) as $n
    | .panes[] | select(.alive | not)
    | [$w, (.pane // "-"), .pane_id, ($n | tostring)] | @tsv' <<<"$query")
}
```

(`dev_open_window_command` already accepts any window-shaped JSON, so passing the pane object works unchanged — the comment above it in open.sh explains why it must.)

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_commands.bats`
Expected: all PASS — including the container-loss scenario, which now shares the repair path.

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/commands/open.sh tests/dev_commands.bats
git commit -m "feat(dev): repair dead declared panes on every open"
```

---

### Task 8: Status — pane display and drift reporting

**Files:**
- Modify: `tools/dev/commands/status.sh`
- Test: `tests/dev_commands.bats`

**Interfaces:**
- Consumes: Task 4 query shape; `agents[].pane` from Task 2.
- Produces: human-readable pane names in window lines, `window/pane` agent labels, and `drift:` lines for undeclared windows and undeclared panes. Nothing machine-readable changes (`dev status` is not a JSON contract).

- [ ] **Step 1: Write the failing test** — append to `tests/dev_commands.bats`:

```bash
@test "status reports undeclared windows and undeclared panes as drift" {
  scenario_setup_demo_workspace
  run dev open demo --no-attach
  [ "$status" -eq 0 ]

  dev_tmux new-window -d -t '=demo:' -n rogue "sleep 30"
  dev_tmux split-window -d -t '=demo:=shell' "sleep 30"

  run dev status demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift:"*"rogue"* ]]
  [[ "$output" == *"drift:"*"shell"*"undeclared pane"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats tests/dev_commands.bats`
Expected: FAILS — status prints no drift lines for windows/panes.

- [ ] **Step 3: Implement in `tools/dev/commands/status.sh`**

Replace the window/agent print block (after the `container:` line) with:

```bash
  printf '%s' "$query" | jq -r '.windows[]? |
    "  window \(.name): " + ([.panes[]
      | (if .pane == null then "" else "\(.pane) " end)
        + (if .alive then "alive" else "dead" end)] | join(", "))'
  printf '%s' "$record" | jq -r '.agents[]? |
    "  agent \(.window)\(if (.pane // null) != null then "/" + .pane else "" end): \(.state) (\(.command // "?"))"'

  # Drift: running windows/panes the merged configuration does not declare.
  # Reported, never repaired — open never destroys, and status never repairs.
  printf '%s' "$query" | jq -r --argjson cfg "$(printf '%s' "$config" | jq -c '.windows // []')" '
    ([$cfg[].name]) as $wnames
    | .windows[]?
    | . as $w
    | if ($w.name | IN($wnames[])) | not then
        "  drift:      window \($w.name) is running but not declared"
      else
        (first($cfg[] | select(.name == $w.name))) as $decl
        | (if ($decl.panes // null) != null then
             [$w.panes[] | select(.pane == null or ((.pane | IN($decl.panes[].name)) | not))]
           elif ($w.panes | length) > 1 then $w.panes[1:]
           else [] end) as $extra
        | if ($extra | length) > 0 then
            "  drift:      window \($w.name) has \($extra | length) undeclared pane(s) (\([$extra[] | .pane // "unnamed"] | join(", ")))"
          else empty end
      end'
```

- [ ] **Step 4: Run the tests**

Run: `bats tests/dev_commands.bats`
Expected: all PASS.

- [ ] **Step 5: Lint and commit**

```bash
/usr/bin/make lint
git add tools/dev/commands/status.sh tests/dev_commands.bats
git commit -m "feat(dev): pane-aware status with window and pane drift reporting"
```

---

### Task 9: Default dashboard, README, test-fixture migration

**Files:**
- Modify: `tools/dev/default-workspace.yaml`
- Modify: `tools/dev/README.md`
- Modify: `tests/dev_commands.bats` (fixture migration + dashboard scenario)

**Interfaces:**
- Consumes: everything above.
- Produces: the shipped default is the one-window dashboard; docs describe panes, layouts, focus, the `agent: null` conversion idiom, and migration.

- [ ] **Step 1: Migrate the scenario fixture** — `tests/dev_commands.bats` (line ~25) copies the shipped `default-workspace.yaml` into its fake root. The existing scenarios exercise the single-pane paths and must keep doing so after the default changes: replace the `cp` with a heredoc writing the LEGACY four-window layout into `"$TEST_ROOT/root/tools/dev/default-workspace.yaml"`:

```bash
  cat >"$TEST_ROOT/root/tools/dev/default-workspace.yaml" <<'EOF'
version: 1
autostart: false
devcontainer:
  enabled: auto
  start_timeout: 300
windows:
  - name: agent-1
    agent: claude
    focus: true
  - name: agent-2
    agent: claude
  - name: shell
    command: null
  - name: scratch
    command: null
    location: host
EOF
```

Run `bats tests/dev_commands.bats` — everything must still pass BEFORE the default changes (this proves the fixture is equivalent). Commit separately:

```bash
git add tests/dev_commands.bats
git commit -m "test(dev): pin the legacy default layout in command scenarios"
```

- [ ] **Step 2: Write the failing dashboard scenario** — append to `tests/dev_commands.bats`; this one copies the REAL shipped default:

```bash
@test "shipped default opens as a one-window tiled dashboard with four stamped panes" {
  scenario_setup_demo_workspace
  cp "$REPO_ROOT/tools/dev/default-workspace.yaml" "$TEST_ROOT/root/tools/dev/default-workspace.yaml"
  # agent commands must not exit instantly; the scenarios stub `claude`
  stub_command claude 'exec sleep 30'

  run dev open demo --no-attach
  [ "$status" -eq 0 ]
  run dev_tmux list-windows -t '=demo' -F '#{window_name}'
  [ "$output" = "main" ]
  run dev_tmux list-panes -t '=demo:=main' -F '#{?#{@dev_pane},#{@dev_pane},-}'
  [ "$(printf '%s\n' "$output" | sort | tr '\n' ',')" = "agent-1,agent-2,scratch,shell," ]

  record=$(cat "$DEV_STATE_ROOT"/workspaces/*.json)
  [ "$(jq -r '[.agents[] | select(.window == "main")] | length' <<<"$record")" -eq 2 ]
  [ "$(jq -r '[.agents[].pane] | sort | join(",")' <<<"$record")" = "agent-1,agent-2" ]
}
```

(Adapt the stub/bootstrap details to `scenario_setup_demo_workspace`; if the scenarios already stub `claude`, drop the duplicate stub line.)

- [ ] **Step 3: Run to verify failure**

Run: `bats tests/dev_commands.bats`
Expected: dashboard test FAILS (default still four windows).

- [ ] **Step 4: Ship the dashboard default** — replace `tools/dev/default-workspace.yaml`:

```yaml
version: 1
autostart: false
devcontainer:
  enabled: auto
  start_timeout: 300
windows:
  - name: main
    focus: true
    layout: tiled
    panes:
      - name: agent-1
        agent: claude
        focus: true
      - name: agent-2
        agent: claude
      - name: shell
        command: null
      - name: scratch
        command: null
        location: host
```

- [ ] **Step 5: Update `tools/dev/README.md`** — in the Configuration section: replace the example YAML with the dashboard default above; keep the single-pane form documented ("a window sets `agent:` OR `command:` OR `panes:`"); document per-pane fields (same as single-pane windows, plus required unique `name`, optional `focus`), `layout:` (the five tmux names, default `main-vertical`), the strict conversion idiom (an overlay adding `panes:` to an inherited agent/command window must also null those keys: `agent: null`), migration (a running workspace's next open creates `main` beside the old windows; they are reported as drift; `dev stop <ws>` + `dev <ws>` converts cleanly), the repair change ("re-running `dev` also respawns dead panes — no longer only after container loss"), and one line noting overlays that patched the old default window names (`agent-1` …) by name must be updated. Also update the "Windows also accept cwd and environment" sentence: window-level `environment` now actually applies (it previously was dropped), and panes accept `cwd`/`environment`/`location` per pane.

- [ ] **Step 6: Run the full dev suite and lint**

Run: `bats tests/dev_config_merge.bats tests/dev_fold.bats tests/dev_state_events.bats tests/dev_backend_tmux.bats tests/dev_commands.bats tests/dev_install.bats tests/dev_lifecycle.bats tests/dev_reconcile.bats tests/dev_resolve.bats tests/dev_runtime_container.bats`
Expected: all PASS.
Run: `/usr/bin/make lint`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/default-workspace.yaml tools/dev/README.md tests/dev_commands.bats
git commit -m "feat(dev): ship the one-window tiled dashboard as the default workspace"
```

---

### Task 10: Full verification sweep

**Files:** none new.

- [ ] **Step 1: Full test run** — `bats tests` (the whole suite; unrelated suites must be untouched).
- [ ] **Step 2: Lint** — `/usr/bin/make lint`.
- [ ] **Step 3: Manual smoke (optional, if a real workspace is at hand)** — `dev <some-workspace> --no-attach` on a plain repo; `dev status` it; kill an agent pane's process and re-open; confirm the pane respawns and `dev list --json | jq '.[] | .agents'` shows `pane` fields.
- [ ] **Step 4: Spec cross-check** — re-read `docs/superpowers/specs/2026-08-04-multi-pane-windows-design.md` §§1–8 and confirm each has an implementing task; the §2 hook-interpolation verification item is Task 3 Step 4.
- [ ] **Step 5: Commit any stragglers** and report completion honestly (what ran, what passed, anything skipped).
