#!/usr/bin/env bash
# Event stream: one append-only JSONL file per host, rotated by size.
#
# Locking (spec §4.4, ADR-1): appends take `flock -s` on locks/events.lock, the
# fold's reader takes `flock -s` across BOTH listing and reading the segments,
# rotation takes `flock -x`. flock is per open-file-description, so taking the
# exclusive lock while this process still holds the shared one deadlocks: call
# dev_events_rotate_if_needed only after the fold has released.
#
# This file is sourced. It defines functions and does no work at source time.

DEV_EVENT_MAX_BYTES=4096
DEV_EVENTS_ROTATE_BYTES=8388608
DEV_EVENTS_KEEP_SEGMENTS=5

dev_now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

dev_event_id_random() {
  openssl rand -hex 8
}

# Discovery events (workspace.vanished, container.lost, config.changed) derive
# their id from what was discovered, so a CAS retry recomputes the same id and
# the append is skipped instead of duplicated (ADR-1).
dev_event_id_deterministic() {
  printf '%s' "${1}${2}${3}" | sha256sum | cut -c1-16
}

dev_event_build() {
  local id=$1 ts=$2 event=$3 workspace_id=$4 slug=$5 session_name=$6 worktree=$7
  local data=${8:-}
  [[ -n "$data" ]] || data='{}'
  jq -c -n \
    --arg id "$id" \
    --arg ts "$ts" \
    --arg event "$event" \
    --arg workspace_id "$workspace_id" \
    --arg slug "$slug" \
    --arg session_name "$session_name" \
    --arg worktree "$worktree" \
    --argjson data "$data" \
    '{
      v: 1,
      id: $id,
      ts: $ts,
      event: $event,
      workspace_id: $workspace_id,
      slug: $slug,
      session_name: $session_name,
      worktree: $worktree,
      data: $data
    }'
}

# Appends one composed line. The whole line is emitted by a single printf whose
# redirection is outside it, so the kernel sees exactly one write(2) against an
# O_APPEND descriptor; two syscalls could interleave with another appender's.
dev_event_append() {
  local line=$1
  local file="$DEV_STATE_ROOT/events/events.jsonl"
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  local size
  mkdir -p "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks"
  size=$(printf '%s' "$line" | wc -c)
  if ((size > DEV_EVENT_MAX_BYTES)); then
    # Replace free-form data with a truncated rendering and mark it. The budget
    # is an estimate (character vs byte width, JSON escaping), so the loop
    # re-measures and halves until the composed line fits.
    local raw budget candidate
    raw=$(printf '%s' "$line" | jq -c '.data')
    budget=$((DEV_EVENT_MAX_BYTES - (size - ${#raw}) - 64))
    ((budget > 0)) || budget=0
    while :; do
      candidate=$(printf '%s' "$line" |
        jq -c --arg raw "${raw:0:budget}" '.data = {truncated: true, raw: $raw}')
      size=$(printf '%s' "$candidate" | wc -c)
      if ((size <= DEV_EVENT_MAX_BYTES)) || ((budget == 0)); then
        line=$candidate
        break
      fi
      budget=$((budget / 2))
    done
  fi
  { flock -s 9 && printf '%s\n' "$line" >>"$file"; } 9>"$lock"
}

# Rotated segments carry an RFC 3339 basic stamp, so glob order (lexicographic)
# is chronological. The live file sorts last because it is printed last.
dev_events_segments() {
  local dir="$DEV_STATE_ROOT/events"
  local seg
  for seg in "$dir"/events-*.jsonl; do
    if [[ -f "$seg" ]]; then
      printf '%s\n' "$seg"
    fi
  done
  if [[ -f "$dir/events.jsonl" ]]; then
    printf '%s\n' "$dir/events.jsonl"
  fi
  return 0
}

# Holds the shared lock across both listing the segments and reading them.
# Releasing between the two lets rotation delete an enumerated segment, and the
# resulting short read is indistinguishable from an unreachable cursor — a
# fold_gap manufactured by the reader itself (ADR-1).
dev_events_read_all() {
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  mkdir -p "$DEV_STATE_ROOT/locks"
  {
    flock -s 9
    local -a segs=()
    mapfile -t segs < <(dev_events_segments)
    if ((${#segs[@]} > 0)); then
      cat "${segs[@]}"
    fi
  } 9>"$lock"
  return 0
}

dev_events_has_id() {
  local id=$1
  dev_events_read_all | jq -e -s --arg id "$id" 'any(.[]; .id == $id)' >/dev/null
}

dev_events_rotate_if_needed() {
  local dir="$DEV_STATE_ROOT/events"
  local live="$dir/events.jsonl"
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  mkdir -p "$dir" "$DEV_STATE_ROOT/locks"
  {
    flock -x 9
    [[ -f "$live" ]] || return 0
    local size
    size=$(wc -c <"$live")
    ((size > DEV_EVENTS_ROTATE_BYTES)) || return 0

    # Sub-second precision plus a collision counter. A bare second-resolution
    # stamp and a bare `mv` silently destroyed a segment when two rotations
    # landed in the same second -- possible here because the threshold is a size,
    # so a burst of appends can cross it twice in quick succession.
    #
    # The counter is present in EVERY name, not only on collision, and both parts
    # are fixed-width. Segment order is lexical (the glob below and
    # `dev_events_segments` both rely on it), and `-00` sorting against a bare
    # `.jsonl` would put the newer file first: `-` is 0x2D, `.` is 0x2E. Uniform
    # names remove that trap. Zero-padded %N sorts correctly for the same reason.
    local stamp target n=0
    stamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
    printf -v target '%s/events-%s-%02d.jsonl' "$dir" "$stamp" "$n"
    while [[ -e "$target" ]]; do
      n=$((n + 1))
      # Bounded: something is badly wrong if this many segments share a
      # nanosecond, and rotating is never worth spinning forever over.
      ((n < 100)) || return 0
      printf -v target '%s/events-%s-%02d.jsonl' "$dir" "$stamp" "$n"
    done
    mv "$live" "$target"
    : >"$live"
    local -a rotated=()
    local seg
    for seg in "$dir"/events-*.jsonl; do
      if [[ -f "$seg" ]]; then
        rotated+=("$seg")
      fi
    done
    local excess=$((${#rotated[@]} - DEV_EVENTS_KEEP_SEGMENTS))
    if ((excess > 0)); then
      rm -f "${rotated[@]:0:excess}"
    fi
  } 9>"$lock"
  return 0
}
