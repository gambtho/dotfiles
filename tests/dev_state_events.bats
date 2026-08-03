#!/usr/bin/env bats

load test_helper

WS_ID=9f2c4a7b1e05de3c8a41f07b2e6d95c3a8b17f42e0d6c95183ba7e4f2c0d68a9

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
}

# Writes `$1` filler event lines into the live segment. The line is ~190 bytes, so
# 50000 lines is ~9.5 MiB, comfortably past the 8 MiB rotation threshold.
fill_events() {
  head -n "$1" < <(yes '{"v":1,"id":"filler","ts":"2026-08-03T00:00:00.000Z","event":"window.created","workspace_id":"filler","slug":"f","session_name":"f","worktree":"/f","data":{"window":"w","location":"host"}}') \
    >"$DEV_STATE_ROOT/events/events.jsonl"
}

@test "events: dev_now is RFC 3339 UTC with milliseconds" {
  local now
  now=$(dev_now)
  [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}

@test "events: the envelope round-trips with all eight fields plus v" {
  local line
  line=$(dev_event_build 4b1e05a7c39f2d18 2026-08-03T14:02:11.412Z container.replaced \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
    '{"old_id":"3f9c","new_id":"a710","reason":"rebuild"}')
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ]
  [ "$(jq -r .v <<<"$line")" = 1 ]
  [ "$(jq -r .id <<<"$line")" = 4b1e05a7c39f2d18 ]
  [ "$(jq -r .ts <<<"$line")" = 2026-08-03T14:02:11.412Z ]
  [ "$(jq -r .event <<<"$line")" = container.replaced ]
  [ "$(jq -r .workspace_id <<<"$line")" = "$WS_ID" ]
  [ "$(jq -r .slug <<<"$line")" = slabledger ]
  [ "$(jq -r .session_name <<<"$line")" = slabledger ]
  [ "$(jq -r .worktree <<<"$line")" = /home/tng/workspace/slabledger ]
  [ "$(jq -r .data.reason <<<"$line")" = rebuild ]
  [ "$(jq -r 'keys_unsorted | join(",")' <<<"$line")" = "v,id,ts,event,workspace_id,slug,session_name,worktree,data" ]
}

@test "events: an oversized payload is truncated and marked" {
  local big data line written
  big=$(head -c 6000 </dev/zero | tr '\0' 'x')
  data=$(jq -c -n --arg s "$big" '{stderr_tail: $s}')
  line=$(dev_event_build 0123456789abcdef 2026-08-03T14:02:11.412Z container.failed \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger "$data")
  [ "$(printf '%s' "$line" | wc -c)" -gt 4096 ]
  dev_event_append "$line"
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -le 4097 ]
  written=$(cat "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r .event <<<"$written")" = container.failed ]
  [ "$(jq -r .id <<<"$written")" = 0123456789abcdef ]
  [ "$(jq -r .data.truncated <<<"$written")" = true ]
  [ -n "$(jq -r .data.raw <<<"$written")" ]
}

@test "events: an oversized non-ASCII payload preserves some raw content" {
  # 2000 repetitions of a 3-byte UTF-8 character (~6000 bytes). Regression:
  # the truncation budget mixed byte and character counts, so a multi-byte
  # payload made the estimate undershoot, the halving loop overshot to zero,
  # and every byte of `data.raw` was silently discarded for non-ASCII data.
  local big data line written
  big=$(printf '\xe4\xb8\xad%.0s' $(seq 1 2000))
  data=$(jq -c -n --arg s "$big" '{stderr_tail: $s}')
  line=$(dev_event_build fedcba9876543210 2026-08-03T14:02:11.412Z container.failed \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger "$data")
  [ "$(printf '%s' "$line" | wc -c)" -gt 4096 ]
  dev_event_append "$line"
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
  written=$(cat "$DEV_STATE_ROOT/events/events.jsonl")
  # Still exactly one valid JSON value on the line.
  [ "$(jq -c . <<<"$written" | wc -l)" -eq 1 ]
  [ "$(jq -r .data.truncated <<<"$written")" = true ]
  [ -n "$(jq -r .data.raw <<<"$written")" ]
}

@test "events: a payload under the cap is written verbatim" {
  local line
  line=$(dev_event_build 0123456789abcdef 2026-08-03T14:02:11.412Z agent.started \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
    '{"window":"agent-1","command":"claude"}')
  dev_event_append "$line"
  [ "$(cat "$DEV_STATE_ROOT/events/events.jsonl")" = "$line" ]
}

@test "events: random ids are 16 hex and differ between calls" {
  local a b
  a=$(dev_event_id_random)
  b=$(dev_event_id_random)
  [[ "$a" =~ ^[0-9a-f]{16}$ ]]
  [[ "$b" =~ ^[0-9a-f]{16}$ ]]
  [ "$a" != "$b" ]
}

@test "events: deterministic ids are stable and discriminator-sensitive" {
  local a b c d
  a=$(dev_event_id_deterministic "$WS_ID" container.lost a710deadbeef)
  b=$(dev_event_id_deterministic "$WS_ID" container.lost a710deadbeef)
  c=$(dev_event_id_deterministic "$WS_ID" container.lost 3f9cfeedface)
  d=$(dev_event_id_deterministic "$WS_ID" config.changed a710deadbeef)
  [[ "$a" =~ ^[0-9a-f]{16}$ ]]
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
  [ "$a" != "$d" ]
}

@test "events: segments list rotated files oldest-first with the live file last" {
  : >"$DEV_STATE_ROOT/events/events.jsonl"
  : >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  : >"$DEV_STATE_ROOT/events/events-20260802T000000Z.jsonl"
  run dev_events_segments
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl" ]
  [ "${lines[1]}" = "$DEV_STATE_ROOT/events/events-20260802T000000Z.jsonl" ]
  [ "${lines[2]}" = "$DEV_STATE_ROOT/events/events.jsonl" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "events: read_all returns rotated events before live ones" {
  dev_event_build aaaa000000000001 2026-08-03T13:00:00.000Z window.created \
    "$WS_ID" s s /w '{"window":"shell","location":"host"}' \
    >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  dev_event_build aaaa000000000002 2026-08-03T14:00:00.000Z window.created \
    "$WS_ID" s s /w '{"window":"scratch","location":"host"}' \
    >"$DEV_STATE_ROOT/events/events.jsonl"
  run dev_events_read_all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(jq -r .id <<<"${lines[0]}")" = aaaa000000000001 ]
  [ "$(jq -r .id <<<"${lines[1]}")" = aaaa000000000002 ]
}

@test "events: has_id finds ids in rotated segments and in the live file" {
  dev_event_build aaaa000000000001 2026-08-03T13:00:00.000Z workspace.stopped \
    "$WS_ID" s s /w '{"reason":"user"}' \
    >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  dev_event_build aaaa000000000002 2026-08-03T14:00:00.000Z workspace.attached \
    "$WS_ID" s s /w '{"client":"/dev/pts/3"}' \
    >"$DEV_STATE_ROOT/events/events.jsonl"
  run dev_events_has_id aaaa000000000001
  [ "$status" -eq 0 ]
  run dev_events_has_id aaaa000000000002
  [ "$status" -eq 0 ]
  run dev_events_has_id aaaa00000000ffff
  [ "$status" -ne 0 ]
}

@test "events: rotation is a no-op below the threshold" {
  fill_events 100
  dev_events_rotate_if_needed
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 100 ]
  [ "$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)" -eq 0 ]
}

@test "events: rotation past the threshold empties the live file into a segment" {
  fill_events 50000
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -gt 8388608 ]
  dev_events_rotate_if_needed
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 0 ]
  local segs
  segs=$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)
  [ "$segs" -eq 1 ]
  [ "$(cat "$DEV_STATE_ROOT"/events/events-*.jsonl | wc -l)" -eq 50000 ]
}

@test "events: two rotations in the same second keep both segments" {
  # The regression: a second-resolution stamp plus a bare `mv` overwrote the
  # first segment, losing 50k events with no error. Nothing here sleeps, so the
  # two rotations land in the same second on any machine.
  fill_events 50000
  dev_events_rotate_if_needed
  fill_events 50000
  dev_events_rotate_if_needed

  local d="$DEV_STATE_ROOT/events"
  [ "$(find "$d" -name 'events-*.jsonl' | wc -l)" -eq 2 ]
  [ "$(cat "$d"/events-*.jsonl | wc -l)" -eq 100000 ]

  # And they are ordered oldest-first, which is what read_all depends on.
  run dev_events_segments
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = "$d/events.jsonl" ]
  [[ "${lines[0]}" < "${lines[1]}" ]]
}

@test "events: retention keeps exactly five rotated segments" {
  local d="$DEV_STATE_ROOT/events" n
  for n in 01 02 03 04 05 06; do
    printf 'old-%s\n' "$n" >"$d/events-202001${n}T000000Z.jsonl"
  done
  fill_events 50000
  dev_events_rotate_if_needed
  [ "$(find "$d" -name 'events-*.jsonl' | wc -l)" -eq 5 ]
  [ ! -e "$d/events-2020010" ]
  [ ! -e "$d/events-20200101T000000Z.jsonl" ]
  [ ! -e "$d/events-20200102T000000Z.jsonl" ]
  [ -e "$d/events-20200103T000000Z.jsonl" ]
  [ -e "$d/events-20200106T000000Z.jsonl" ]
}

@test "events: concurrent appends survive a rotation and a concurrent read" {
  local i j pad_len probe probe_len pad
  # Build every event's line to land at exactly DEV_EVENT_MAX_BYTES. That is
  # the boundary where the trailing newline dev_event_append adds pushes the
  # real write one byte past bash's stdio buffer, turning a single printf
  # into two write(2) calls -- the exact regression this test exists to
  # catch (DEV_EVENT_MAX_BYTES was one byte too generous). Ordinary ~200 B
  # events never approach that boundary and could not have caught it.
  probe=$(dev_event_build ev000000 2026-08-03T14:00:00.000Z agent.started \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
    '{"window":"agent-1","command":"claude","pad":""}')
  probe_len=$(printf '%s' "$probe" | wc -c)
  pad_len=$((DEV_EVENT_MAX_BYTES - probe_len))
  pad=$(printf 'x%.0s' $(seq 1 "$pad_len"))

  # Pre-fill past the threshold so the concurrent rotation actually fires while
  # the appenders are running.
  fill_events 50000

  for i in $(seq 1 20); do
    (
      local j line data
      for j in $(seq 1 25); do
        data=$(jq -c -n --arg pad "$pad" \
          '{window:"agent-1",command:"claude",pad:$pad}')
        line=$(dev_event_build "$(printf 'ev%03d%03d' "$i" "$j")" \
          2026-08-03T14:00:00.000Z agent.started \
          "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger "$data")
        dev_event_append "$line"
      done
    ) &
  done
  dev_events_rotate_if_needed &
  dev_events_read_all >"$TEST_ROOT/read-all.jsonl" &
  wait

  dev_events_segments >"$TEST_ROOT/segments.txt"
  xargs -a "$TEST_ROOT/segments.txt" cat >"$TEST_ROOT/all.jsonl"

  # jq reads a stream of values and is indifferent to newlines -- concatenated
  # objects on one physical line parse fine, and blank lines are skipped -- so
  # this proves the file is well-formed JSONL overall but NOT that no tearing
  # occurred. It still catches values that are not valid JSON at all.
  jq -c . "$TEST_ROOT/all.jsonl" >/dev/null
  jq -c . "$TEST_ROOT/read-all.jsonl" >/dev/null

  # Line-oriented tearing check: no blank lines and no two objects glued onto
  # one physical line. This is what an interleaved multi-write append leaves
  # behind, and jq alone cannot see it.
  [ "$(grep -c '^$' "$TEST_ROOT/all.jsonl")" -eq 0 ]
  [ "$(grep -c '}{' "$TEST_ROOT/all.jsonl")" -eq 0 ]
  [ "$(grep -c '^$' "$TEST_ROOT/read-all.jsonl")" -eq 0 ]
  [ "$(grep -c '}{' "$TEST_ROOT/read-all.jsonl")" -eq 0 ]

  # Every emitted id appears exactly once across the live file and all segments.
  jq -r 'select(.id | startswith("ev")) | .id' "$TEST_ROOT/all.jsonl" \
    | sort >"$TEST_ROOT/got.txt"
  for i in $(seq 1 20); do
    for j in $(seq 1 25); do
      printf 'ev%03d%03d\n' "$i" "$j"
    done
  done | sort >"$TEST_ROOT/want.txt"
  [ "$(wc -l <"$TEST_ROOT/got.txt")" -eq 500 ]
  diff "$TEST_ROOT/want.txt" "$TEST_ROOT/got.txt"

  # Rotation ran: the filler lines are in a segment, not the live file.
  [ "$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)" -eq 1 ]
  [ "$(grep -c '"id":"filler"' "$TEST_ROOT/all.jsonl")" -eq 50000 ]
}

@test "state: the record path uses the full 64-hex workspace id" {
  local path
  path=$(dev_state_path "$WS_ID")
  [ "$path" = "$DEV_STATE_ROOT/workspaces/$WS_ID.json" ]
  [ "${#WS_ID}" -eq 64 ]
  dev_state_commit "$WS_ID" "" "$(dev_state_new "$WS_ID" slabledger slabledger /w)"
  [ -f "$path" ]
  [ "$(basename "$path")" = "$WS_ID.json" ]
}

@test "state: a fresh record has the v1 shape" {
  local rec
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
  [ "$(jq -r .v <<<"$rec")" = 1 ]
  [ "$(jq -r .workspace_id <<<"$rec")" = "$WS_ID" ]
  [ "$(jq -r .slug <<<"$rec")" = slabledger ]
  [ "$(jq -r .session_name <<<"$rec")" = slabledger ]
  [ "$(jq -r .worktree <<<"$rec")" = /home/tng/workspace/slabledger ]
  [ "$(jq -r .status <<<"$rec")" = unknown ]
  [ "$(jq -r .boot_id <<<"$rec")" = null ]
  [ "$(jq -r .config_digest <<<"$rec")" = null ]
  [ "$(jq -r .applied_digest <<<"$rec")" = null ]
  [ "$(jq -c .container <<<"$rec")" = '{"status":"none","kind":null,"id":null,"user":null,"workdir":null,"verified":false,"up_exit_status":null,"up_result":null,"observed_at":null}' ]
  [ "$(jq -c .agents <<<"$rec")" = '[]' ]
  [ "$(jq -r .opened_at <<<"$rec")" = null ]
  [ "$(jq -r .last_seen <<<"$rec")" = null ]
  [ "$(jq -r .scanned_through <<<"$rec")" = null ]
  [ "$(jq -r .fold_gap <<<"$rec")" = false ]
  [ "$(jq -r .stopped_reason <<<"$rec")" = null ]
}

@test "state: a fresh record round-trips through commit and read unchanged" {
  local rec out
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
  run dev_state_commit "$WS_ID" "" "$rec"
  [ "$status" -eq 0 ]
  out=$(dev_state_read "$WS_ID")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]
}

@test "state: reading an absent record exits 1 with no output" {
  run dev_state_read "$WS_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "state: committing over an absent record requires an empty expectation" {
  local rec
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  run dev_state_commit "$WS_ID" "$rec" "$rec"
  [ "$status" -eq 9 ]
  [ ! -e "$(dev_state_path "$WS_ID")" ]
}

@test "state: a stale expectation exits 9 and leaves the file untouched" {
  local rec stale new before after path
  path=$(dev_state_path "$WS_ID")
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  before=$(cat "$path")
  stale=$(jq -c '.status = "running"' <<<"$rec")
  new=$(jq -c '.status = "stopped"' <<<"$rec")
  run dev_state_commit "$WS_ID" "$stale" "$new"
  [ "$status" -eq 9 ]
  after=$(cat "$path")
  [ "$before" = "$after" ]
}

@test "state: a reordered expectation still matches" {
  local rec reordered new
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  reordered=$(jq -c 'to_entries | reverse | from_entries' <<<"$rec")
  [ "$reordered" != "$rec" ]
  new=$(jq -c '.status = "running"' <<<"$rec")
  run dev_state_commit "$WS_ID" "$reordered" "$new"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <"$(dev_state_path "$WS_ID")")" = running ]
}

@test "state: two concurrent committers give one winner and one exit-9 loser" {
  local rec a b rca rcb final
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  a=$(jq -c '.status = "running"' <<<"$rec")
  b=$(jq -c '.status = "stopped"' <<<"$rec")
  (
    rc=0
    dev_state_commit "$WS_ID" "$rec" "$a" || rc=$?
    printf '%s\n' "$rc" >"$TEST_ROOT/rc-a"
  ) &
  (
    rc=0
    dev_state_commit "$WS_ID" "$rec" "$b" || rc=$?
    printf '%s\n' "$rc" >"$TEST_ROOT/rc-b"
  ) &
  wait
  rca=$(cat "$TEST_ROOT/rc-a")
  rcb=$(cat "$TEST_ROOT/rc-b")
  # Exactly one winner (0) and one CAS loser (9).
  [ "$((rca + rcb))" -eq 9 ]
  [ "$rca" -ne "$rcb" ]
  final=$(jq -r .status <"$(dev_state_path "$WS_ID")")
  [[ "$final" = running || "$final" = stopped ]]
  # The loser wrote nothing: the file is exactly one of the two candidates.
  [ "$(jq -S -c . <"$(dev_state_path "$WS_ID")")" = "$(jq -S -c . <<<"$a")" ] ||
    [ "$(jq -S -c . <"$(dev_state_path "$WS_ID")")" = "$(jq -S -c . <<<"$b")" ]
}

@test "state: list returns every record path" {
  local other=1111111111111111111111111111111111111111111111111111111111111111
  dev_state_commit "$WS_ID" "" "$(dev_state_new "$WS_ID" a a /a)"
  dev_state_commit "$other" "" "$(dev_state_new "$other" b b /b)"
  run dev_state_list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$DEV_STATE_ROOT/workspaces/$other.json" ]
  [ "${lines[1]}" = "$DEV_STATE_ROOT/workspaces/$WS_ID.json" ]
}

@test "state: list is empty when no records exist" {
  run dev_state_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state: the recorded session name beats the resolver's proposal" {
  # ADR-7's collision guard may have renamed this workspace to
  # `<slug>--<basename>--<hash6>`. That rename is durable, so every command
  # after the first `open` must read it back rather than re-derive the plain
  # name -- re-deriving is what left a collided workspace unreachable.
  local rec
  rec=$(dev_state_new "$WS_ID" demo demo /w)
  rec=$(jq -c '.session_name = "demo--feat--a1b2c3"' <<<"$rec")
  dev_state_commit "$WS_ID" "" "$rec"

  run dev_state_session_name "$WS_ID" demo
  [ "$status" -eq 0 ]
  [ "$output" = "demo--feat--a1b2c3" ]
}

@test "state: the fallback is used only when no record exists yet" {
  # The first `dev open`, which is exactly when the resolver's proposal is right.
  run dev_state_session_name "$(printf 'f%.0s' {1..64})" demo
  [ "$status" -eq 0 ]
  [ "$output" = "demo" ]
}

@test "state: a concurrent commit never exposes a torn read" {
  # dev_state_commit's write is mktemp-in-directory + `mv -f`, an atomic
  # same-filesystem rename -- a reader must only ever see the old record or
  # the new one, never a partial write. dev_state_read takes no lock (by
  # design: reads are cheap and frequent), so this is the exposed path. A
  # record has to be large enough that a non-atomic write (e.g. an in-place
  # `printf >"$path"`) is actually interruptible by a concurrent reader; a
  # few-hundred-byte record writes faster than a reader can catch it mid-write.
  local rec bad=0 reads=0 writer_pid
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"

  (
    local cur a b i
    cur=$rec
    # Build the ~2 MB payloads inside jq (string repeat) rather than passing
    # them as a shell/jq argv string -- a multi-megabyte --arg blows past
    # ARG_MAX on exec.
    a=$(jq -c --argjson n 2000000 '.stopped_reason = ("a" * $n)' <<<"$rec")
    b=$(jq -c --argjson n 2000000 '.stopped_reason = ("b" * $n)' <<<"$rec")
    for i in $(seq 1 30); do
      if ((i % 2 == 1)); then
        dev_state_commit "$WS_ID" "$cur" "$a" && cur=$a
      else
        dev_state_commit "$WS_ID" "$cur" "$b" && cur=$b
      fi
    done
  ) &
  writer_pid=$!

  while kill -0 "$writer_pid" 2>/dev/null; do
    reads=$((reads + 1))
    if ! dev_state_read "$WS_ID" | jq empty >/dev/null 2>&1; then
      bad=$((bad + 1))
    fi
  done
  wait "$writer_pid"

  # Sanity: the loop actually raced the writer, and no read ever saw a
  # truncated / non-JSON record.
  [ "$reads" -gt 0 ]
  [ "$bad" -eq 0 ]
}
