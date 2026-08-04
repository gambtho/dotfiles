#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  source "$REPO_ROOT/tools/dev/lib/reconcile.sh"

  # Deterministic clock: two runs of the same pass must be byte-comparable.
  FAKE_NOW="2026-08-03T15:00:00.000Z"
  dev_now() { printf '%s\n' "$FAKE_NOW"; }

  BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
  WT="$DEV_REPO_ROOT/demo"
  mkdir -p "$WT"
  WS_ID=$(printf '%s' "$WT" | sha256sum | cut -d' ' -f1)
  RESOLVED=$(jq -nc --arg s demo --arg w "$WT" --arg i "$WS_ID" --arg n demo \
    '{slug: $s, worktree: $w, workspace_id: $i, session_name: $n, is_primary: true}')

  # Fake backend. Both knobs are plain globals the test body flips.
  BACKEND_EXISTS=false
  CONTAINER_ALIVE=false
  dev_backend_query() {
    jq -nc --arg e "$BACKEND_EXISTS" --arg w "$WT" \
      '{exists: ($e == "true"), worktree: $w, clients: 0, windows: []}'
  }
  dev_container_alive() { [[ "$CONTAINER_ALIVE" == "true" ]]; }
}

# A running record, opened long ago, last seen at a time distinct from FAKE_NOW.
mk_record() {
  dev_state_new "$WS_ID" demo demo "$WT" | jq -c \
    --arg b "$BOOT_ID" \
    '.status = "running"
     | .opened_at = "2026-08-03T09:00:00.000Z"
     | .last_seen = "2026-08-03T12:30:00.000Z"
     | .boot_id = $b
     | .config_digest = "sha256:aaa"
     | .applied_digest = "sha256:aaa"
     | .scanned_through = {id: null, ts: null}'
}

seed_record() { printf '%s\n' "$1" >"$(dev_state_path "$WS_ID")"; }

# Appends one event with a random id and the shared envelope.
emit() {
  local event="$1" ts="$2" data="$3" id
  id=$(dev_event_id_random)
  dev_event_append \
    "$(dev_event_build "$id" "$ts" "$event" "$WS_ID" demo demo "$WT" "$data")"
}

all_events() { cat "$DEV_STATE_ROOT"/events/*.jsonl 2>/dev/null; }

@test "case A: a workspace.stopped event with the backend absent folds to stopped/user" {
  seed_record "$(mk_record)"
  emit workspace.stopped "2026-08-03T12:45:00.000Z" '{"reason":"user"}'
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = user ]
  # The hook already explained it; reconcile must not also claim a discovery.
  [ -z "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id')" ]
}

@test "case A: a missed hook produces workspace.vanished with discovered_at distinct from ts" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = vanished ]

  ev=$(all_events | jq -c 'select(.event == "workspace.vanished")')
  [ "$(jq -r '.ts' <<<"$ev")" = "2026-08-03T12:30:00.000Z" ]
  [ "$(jq -r '.data.discovered_at' <<<"$ev")" = "$FAKE_NOW" ]
  [ "$(jq -r '.ts' <<<"$ev")" != "$(jq -r '.data.discovered_at' <<<"$ev")" ]
  [ "$(jq -r '.data.reason' <<<"$ev")" = vanished ]
  [ "$(jq -r '.data.last_boot_id' <<<"$ev")" = "$BOOT_ID" ]
}

@test "case B: a differing boot id yields host_restart rather than vanished" {
  seed_record "$(mk_record | jq -c '.boot_id = "11111111-2222-3333-4444-555555555555"')"
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = host_restart ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .data.reason')" = host_restart ]
}

@test "case C: a dead container emits container.lost and leaves workspace status alone" {
  seed_record "$(mk_record | jq -c '
    .container = {status: "ready", kind: "compose", id: "a710dead", user: "vscode",
                  workdir: "/workspace", verified: false, up_exit_status: 0,
                  up_result: {containerId: "a710dead"},
                  observed_at: "2026-08-03T11:00:00.000Z"}')"
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = lost ]
  [ "$(jq -r '.container.id' <<<"$output")" = null ]
  # ADR-2's axis separation: a lost container does not stop the workspace.
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = null ]

  ev=$(all_events | jq -c 'select(.event == "container.lost")')
  [ "$(jq -r '.data.old_id' <<<"$ev")" = a710dead ]
  [ "$(jq -r '.data.discovered_at' <<<"$ev")" = "$FAKE_NOW" ]
  [ "$(jq -r '.ts' <<<"$ev")" = "2026-08-03T11:00:00.000Z" ]
}

@test "case D: a changed config digest emits config.changed and touches no tmux" {
  stub_command tmux 'echo tmux >"$TEST_ROOT/tmux-was-called"; exit 1'
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:bbb"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.config_digest' <<<"$output")" = "sha256:bbb" ]
  [ "$(jq -r '.applied_digest' <<<"$output")" = "sha256:aaa" ]
  assert_file_absent "$TEST_ROOT/tmux-was-called"

  ev=$(all_events | jq -c 'select(.event == "config.changed")')
  [ "$(jq -r '.data.config_digest' <<<"$ev")" = "sha256:bbb" ]
  [ "$(jq -r '.data.applied_digest' <<<"$ev")" = "sha256:aaa" ]
}

@test "case E: VS Code stopping the compose stack is handled identically to case C" {
  # Different setup from case C: the binding arrives by folding the container.ready
  # event that open wrote, rather than being present in the seeded record.
  seed_record "$(mk_record)"
  emit container.ready "2026-08-03T11:00:00.000Z" \
    '{"id":"a710dead","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710dead"}}'
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = lost ]
  [ "$(jq -r '.container.id' <<<"$output")" = null ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .data.old_id')" = a710dead ]
}

@test "no drift means no discovery events and a record that only advances last_seen" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(jq -r '.last_seen' <<<"$output")" = "$FAKE_NOW" ]
  [ -z "$(all_events)" ]
}

@test "an absent record is created from the resolved identity" {
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspace_id' <<<"$output")" = "$WS_ID" ]
  [ "$(jq -r '.slug' <<<"$output")" = demo ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ -f "$(dev_state_path "$WS_ID")" ]
}

# Copies a function definition under a second name, so a test can wrap it.
copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }

@test "CAS: a discovery event is appended exactly once across a forced retry" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  copy_fn dev_state_commit dev_state_commit_orig
  CAS_TRIPPED=0
  # Mutate the on-disk record on the first commit attempt only, so attempt 1
  # exits 9 and attempt 2 re-observes and succeeds.
  dev_state_commit() {
    if [[ "$CAS_TRIPPED" == 0 ]]; then
      CAS_TRIPPED=1
      local p; p="$(dev_state_path "$WS_ID")"
      jq -c '.last_seen = "2026-08-03T12:31:00.000Z"' "$p" >"$p.mut"
      mv "$p.mut" "$p"
    fi
    dev_state_commit_orig "$@"
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "CAS: three consecutive CAS failures exit 8 without overwriting the record" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  copy_fn dev_state_commit dev_state_commit_orig
  # Mutate the record before every commit attempt, so all three exit 9.
  dev_state_commit() {
    local p; p="$(dev_state_path "$WS_ID")"
    jq -c --arg n "$RANDOM" '.last_seen = ("2026-08-03T12:31:00." + $n + "Z")' "$p" >"$p.mut"
    mv "$p.mut" "$p"
    dev_state_commit_orig "$@"
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 8 ]
  [[ "$output" == *"changing underneath"* ]]
  [ "$(jq -r '.status' "$(dev_state_path "$WS_ID")")" = running ]
  # Idempotent id: three attempts, still one event.
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "CAS: a crash between emit and commit converges to the uninterrupted record" {
  # Branch A — an uninterrupted pass, reconciled twice so its fold cursor has
  # advanced across the event it appended.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  uninterrupted=$(jq -S -c . "$(dev_state_path "$WS_ID")")

  # Branch B — the crash: the discovery event reached the log, the record never
  # changed. Rebuild the state root from scratch and replay that situation.
  rm -rf "$DEV_STATE_ROOT"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks"
  seed_record "$(mk_record)"
  # The discriminator is boot_id + the record's opened_at (mk_record's value),
  # so this reproduces exactly the id reconcile will recompute on the next pass.
  crash_id=$(dev_event_id_deterministic "$WS_ID" workspace.vanished \
    "$BOOT_ID:2026-08-03T09:00:00.000Z")
  dev_event_append "$(dev_event_build "$crash_id" "2026-08-03T12:30:00.000Z" \
    workspace.vanished "$WS_ID" demo demo "$WT" \
    "$(jq -nc --arg d "$FAKE_NOW" --arg b "$BOOT_ID" \
      '{discovered_at: $d, reason: "vanished", last_boot_id: $b}')")"

  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  converged=$(jq -S -c . "$(dev_state_path "$WS_ID")")

  [ "$converged" = "$uninterrupted" ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "a second vanish in a new incarnation is a second event, not a dropped duplicate" {
  # Deduplication by deterministic id must suppress only re-derivations of the
  # SAME occasion. Keyed on boot_id alone, the boot id is identical until the
  # host reboots, so every later loss of the same workspace collapsed into the
  # first one's id and was silently discarded by the has-id check.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]

  # Reopened: a new incarnation, same boot id.
  emit workspace.opened "2026-08-03T13:00:00.000Z" \
    "$(jq -nc --arg b "$BOOT_ID" \
      '{session_name_actual: "demo", boot_id: $b, config_digest: "sha256:aaa"}')"
  BACKEND_EXISTS=true
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(jq -r '.status' "$(dev_state_path "$WS_ID")")" = running ]

  # And killed again.
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 2 ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | sort -u | wc -l)" -eq 2 ]
}

@test "losing the same container id twice across two bindings emits two events" {
  # `docker start` preserves the id, so the id alone does not identify the
  # binding; the container.ready that bound it does.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false
  emit container.ready "2026-08-03T12:00:00.000Z" \
    '{"kind":"devcontainer","id":"cid1","user":"vscode","workdir":"/w","up_exit_status":0,"up_result":"success"}'
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .id' | wc -l)" -eq 1 ]

  # The same container comes back, then goes away again.
  emit container.ready "2026-08-03T12:40:00.000Z" \
    '{"kind":"devcontainer","id":"cid1","user":"vscode","workdir":"/w","up_exit_status":0,"up_result":"success"}'
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .id' | sort -u | wc -l)" -eq 2 ]
}

@test "a config edited A to B and back to A emits an event each way" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true
  dev_reconcile "$RESOLVED" "sha256:bbb" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "config.changed") | .id' | sort -u | wc -l)" -eq 2 ]
  [ "$(all_events | jq -r 'select(.event == "config.changed") | .data.config_digest' |
    tr '\n' ' ')" = "sha256:bbb sha256:aaa " ]
}

@test "a rotated-away cursor re-anchors: fold_gap stays set but the rescan stops" {
  seed_record "$(jq -c '.scanned_through = {id: "deadbeefdeadbeef", ts: "2026-08-03T10:00:00.000Z"}' <<<"$(mk_record)")"
  BACKEND_EXISTS=true

  # An event the cursor can anchor to, none of which is the missing cursor.
  dev_event_append "$(dev_event_build "$(dev_event_id_random)" "2026-08-03T12:00:00.000Z" \
    workspace.attached "$WS_ID" demo demo "$WT" '{"client":"/dev/pts/1"}')"

  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  after=$(jq -c . "$(dev_state_path "$WS_ID")")

  # The gap is still reported — only workspace.opened clears it.
  [ "$(jq -r '.fold_gap' <<<"$after")" = true ]
  # But the cursor has moved off the unreachable id to the newest scanned event,
  # so the next pass folds forward instead of re-deriving the same gap.
  [ "$(jq -r '.scanned_through.id' <<<"$after")" != "deadbeefdeadbeef" ]
  [ "$(jq -r '.scanned_through.ts' <<<"$after")" = "2026-08-03T12:00:00.000Z" ]

  # A second pass changes nothing but last_seen: the rescan really did stop.
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  second=$(jq -c . "$(dev_state_path "$WS_ID")")
  [ "$(jq -S -c 'del(.last_seen)' <<<"$second")" = "$(jq -S -c 'del(.last_seen)' <<<"$after")" ]
}
