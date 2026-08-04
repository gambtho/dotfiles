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
      local p
      p="$(dev_state_path "$WS_ID")"
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
    local p
    p="$(dev_state_path "$WS_ID")"
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

@test "a config edited A to B, applied, to C and back to B emits three distinct events" {
  # Keyed on the wanted digest alone, this collapses to two events: the third
  # step's digest (B) repeats the first step's digest, and a discriminator
  # that ignores the applied side of the pair drops it as a duplicate. The
  # simpler "A -> B -> A" round trip (still exercised as steps 1-2 here)
  # cannot distinguish the two discriminators, because applied_digest never
  # moves off its starting value in that shorter sequence -- the wanted digest
  # alone already discriminates every event in it. Telling them apart needs an
  # actual apply in between, which is what the workspace.opened event below
  # provides: it folds config_digest into applied_digest, so step 3's
  # (wanted=B) collides with step 1's (wanted=B) only if applied_digest is
  # dropped from the key -- at step 1 applied was A, at step 3 it is B.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true

  # Step 1: aaa -> bbb. applied_digest is still aaa (mk_record's seed).
  dev_reconcile "$RESOLVED" "sha256:bbb" >/dev/null

  # An actual apply: workspace.opened folds config_digest into applied_digest.
  emit workspace.opened "2026-08-03T13:00:00.000Z" \
    "$(jq -nc --arg b "$BOOT_ID" \
      '{session_name_actual: "demo", boot_id: $b, config_digest: "sha256:bbb"}')"

  # Step 2: bbb -> ccc. applied_digest is now bbb.
  dev_reconcile "$RESOLVED" "sha256:ccc" >/dev/null

  # Step 3: back to bbb -- same WANTED digest as step 1, but a different
  # applied digest (bbb, not aaa).
  dev_reconcile "$RESOLVED" "sha256:bbb" >/dev/null

  [ "$(all_events | jq -r 'select(.event == "config.changed") | .id' | sort -u | wc -l)" -eq 3 ]
  [ "$(all_events | jq -r 'select(.event == "config.changed") | .data.config_digest' |
    tr '\n' ' ')" = "sha256:bbb sha256:ccc sha256:bbb " ]
}

@test "CAS: the has_id guard alone prevents a duplicate when the fold cannot see the event" {
  # The CAS tests above prove FOLD-suppression: on a retry, the event appended
  # by the failed attempt is already in the stream, so the SECOND attempt's
  # own fold already shows the record as stopped/lost/changed and the
  # discovery is never recomputed at all -- the dev_events_has_id guard is
  # never even reached. That is a different property from the one it exists
  # to guarantee (ADR-1: a CAS retry appends nothing). This test forces the
  # guard itself to be the deciding factor: the deterministic-id event is
  # pre-planted with a ts BEFORE opened_at, which the fold's own guard skips
  # (any non-workspace.opened event predating opened_at is dropped), so the
  # fold cannot suppress the re-derivation -- only dev_events_has_id can.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  planted_id=$(dev_event_id_deterministic "$WS_ID" workspace.vanished \
    "$BOOT_ID:2026-08-03T09:00:00.000Z")
  dev_event_append "$(dev_event_build "$planted_id" "2026-08-03T08:00:00.000Z" \
    workspace.vanished "$WS_ID" demo demo "$WT" \
    "$(jq -nc --arg d "$FAKE_NOW" --arg b "$BOOT_ID" \
      '{discovered_at: $d, reason: "vanished", last_boot_id: $b}')")"

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "an ADR-7-renamed session is queried under the record's name, not the resolver's guess" {
  # Invariant 9: the recorded session_name beats the resolver's proposal.
  # Every other test names the record and the resolved proposal identically
  # (both "demo"), so this branch has never actually been observed to fire.
  seed_record "$(mk_record | jq -c '.session_name = "demo--worktree--abcdef"')"
  BACKEND_EXISTS=true
  dev_backend_query() {
    printf '%s\n' "$1" >"$DEV_STATE_ROOT/queried-name"
    jq -nc --arg e "$BACKEND_EXISTS" --arg w "$WT" \
      '{exists: ($e == "true"), worktree: $w, clients: 0, windows: []}'
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(cat "$DEV_STATE_ROOT/queried-name")" = "demo--worktree--abcdef" ]
  [ "$(jq -r '.session_name' <<<"$output")" = "demo--worktree--abcdef" ]
}

@test "a rotated-away cursor with the backend absent is reported stopped by the overlay alone" {
  # Test 15 below only exercises the fold_gap re-anchor with the backend
  # PRESENT, so the overlay's "elif fold_gap == true then stopped" branch
  # never runs there (the "exists == true" arm wins first). This record's
  # status starts as "unknown" (dev_state_new's default, never "running"),
  # so the workspace.vanished discovery branch -- which only fires when the
  # folded status is already "running" -- cannot fire either. The only thing
  # that can turn this into "stopped" is the overlay's fold_gap branch.
  local rec
  rec=$(dev_state_new "$WS_ID" demo demo "$WT" | jq -c \
    --arg b "$BOOT_ID" \
    '.boot_id = $b
     | .config_digest = "sha256:aaa"
     | .applied_digest = "sha256:aaa"
     | .scanned_through = {id: "deadbeefdeadbeef", ts: "2026-08-03T10:00:00.000Z"}')
  seed_record "$rec"
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fold_gap' <<<"$output")" = true ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ -z "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id')" ]
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

@test "a corrupt event line makes the fold fail and reconcile leaves the record byte-identical" {
  # Regression: dev_fold_stream's `jq -s` on a non-JSON line writes nothing
  # (empty stdout), which used to flow uncaught all the way to
  # dev_state_commit and overwrite the record with a bare newline.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  local path before_sha
  path=$(dev_state_path "$WS_ID")
  before_sha=$(sha256sum "$path")

  printf 'not json{{{\n' >>"$DEV_STATE_ROOT/events/events.jsonl"

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 5 ]
  [ "$(sha256sum "$path")" = "$before_sha" ]
}

@test "a corrupt event line prints a diagnostic to stderr and never reaches commit" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  printf 'not json{{{\n' >>"$DEV_STATE_ROOT/events/events.jsonl"

  copy_fn dev_state_commit dev_state_commit_orig
  dev_state_commit() {
    printf 'dev_state_commit called\n' >"$TEST_ROOT/commit-called"
    dev_state_commit_orig "$@"
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 5 ]
  [[ "$output" == *"fold"* ]]
  [ ! -e "$TEST_ROOT/commit-called" ]
}
