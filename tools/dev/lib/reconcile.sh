#!/usr/bin/env bash
# reconcile.sh — observe the backend, fold the event log, commit a record.
#
# Read-only with respect to the workspace (ADR-1): this file never starts a
# container, respawns a pane, or creates a window. Repair is `open`'s ensure
# phase alone, which is why `dev list` and `dev status` may run reconcile while
# holding no operation lock.
#
# The pass is observe -> compute -> commit. No state lock is held while
# observing or folding; `dev_state_commit` takes it for one read-modify-write.
# Discovery events are emitted BEFORE the commit and carry deterministic ids,
# so a CAS retry appends nothing and a crash in the gap leaves an event the
# next pass folds.

DEV_RECONCILE_MAX_ATTEMPTS="${DEV_RECONCILE_MAX_ATTEMPTS:-3}"

dev_reconcile_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf '\n'
}

dev_reconcile() {
  local resolved_json="$1" config_digest="$2"
  local workspace_id slug worktree proposed_name session_name
  workspace_id=$(jq -r '.workspace_id' <<<"$resolved_json")
  slug=$(jq -r '.slug' <<<"$resolved_json")
  worktree=$(jq -r '.worktree' <<<"$resolved_json")
  proposed_name=$(jq -r '.session_name' <<<"$resolved_json")

  local attempt=1
  while ((attempt <= DEV_RECONCILE_MAX_ATTEMPTS)); do
    # --- observe (no state lock held) ---------------------------------------
    local base expected
    if base=$(dev_state_read "$workspace_id"); then
      expected="$base"
      # The record's own name, never the resolver's proposal. On a workspace the
      # ADR-7 collision guard renamed, the proposal names a DIFFERENT working
      # tree's session (or nothing at all), so querying it would report this
      # workspace as vanished while it is running, and emit a false
      # workspace.vanished on every pass. Re-read inside the retry loop so a
      # concurrent open's rename is picked up on the second attempt.
      session_name=$(jq -r '.session_name // ""' <<<"$base")
      [[ -n "$session_name" && "$session_name" != null ]] || session_name="$proposed_name"
    else
      session_name="$proposed_name"
      base=$(dev_state_new "$workspace_id" "$slug" "$session_name" "$worktree")
      expected=""
    fi

    local backend_json exists
    backend_json=$(dev_backend_query "$session_name")
    exists=$(jq -r '.exists' <<<"$backend_json")

    # Capture the stream once. The tail is needed twice — by the fold, and (on a
    # gap) by the re-anchor below — and reading twice would race a rotation
    # between the two reads and produce inconsistent cursors.
    local all_events folded
    all_events=$(dev_events_read_all)
    folded=$(printf '%s\n' "$all_events" | dev_fold_stream "$base")

    local container_id container_alive=unknown
    container_id=$(jq -r '.container.id // empty' <<<"$folded")
    if [[ -n "$container_id" && "$container_id" != null ]]; then
      if dev_container_alive "$container_id"; then
        container_alive=yes
      else
        container_alive=no
      fi
    fi

    # --- compute the discovery events ---------------------------------------
    local now
    now=$(dev_now)
    local -a discoveries=()
    local folded_status rec_boot_id cur_boot_id data id ts
    local rec_opened_at bound_at
    folded_status=$(jq -r '.status' <<<"$folded")
    rec_boot_id=$(jq -r '.boot_id // empty' <<<"$folded")
    cur_boot_id=$(dev_reconcile_boot_id)
    # The incarnation this record is in. `workspace.opened` sets it on every open,
    # so it is what distinguishes "this workspace vanished" from "this workspace
    # vanished, was reopened, and vanished again" -- two real events that a
    # discriminator of boot_id alone collapses into one, because the boot id is
    # identical until the host reboots. The second loss would then be silently
    # dropped by the has-id check and no consumer would ever hear about it.
    rec_opened_at=$(jq -r '.opened_at // empty' <<<"$folded")

    if [[ "$folded_status" == running && "$exists" != true ]]; then
      local reason=vanished
      if [[ -n "$rec_boot_id" && "$rec_boot_id" != "$cur_boot_id" ]]; then
        reason=host_restart
      fi
      # ts estimates when it happened; discovered_at records when we noticed.
      ts=$(jq -r '.last_seen // empty' <<<"$folded")
      [[ -n "$ts" ]] || ts="$now"
      data=$(jq -nc --arg d "$now" --arg r "$reason" --arg b "$rec_boot_id" \
        '{discovered_at: $d, reason: $r}
         + (if $b == "" then {} else {last_boot_id: $b} end)')
      id=$(dev_event_id_deterministic "$workspace_id" workspace.vanished \
        "${rec_boot_id}:${rec_opened_at}")
      discoveries+=("$(dev_event_build "$id" "$ts" workspace.vanished \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    if [[ "$container_alive" == no ]]; then
      ts=$(jq -r '.container.observed_at // .last_seen // empty' <<<"$folded")
      [[ -n "$ts" ]] || ts="$now"
      data=$(jq -nc --arg o "$container_id" --arg d "$now" \
        '{old_id: $o, discovered_at: $d}')
      # `container.observed_at` is written by the fold from the `container.ready`
      # that bound this id, so it names the binding rather than the moment of
      # this observation. Without it, a container stopped, started again under
      # the same id (which `docker start` preserves), and lost a second time
      # would produce a duplicate id and the second loss would never be emitted.
      bound_at=$(jq -r '.container.observed_at // empty' <<<"$folded")
      id=$(dev_event_id_deterministic "$workspace_id" container.lost \
        "${container_id}:${bound_at}")
      discoveries+=("$(dev_event_build "$id" "$ts" container.lost \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    local folded_digest folded_applied
    folded_digest=$(jq -r '.config_digest // empty' <<<"$folded")
    folded_applied=$(jq -r '.applied_digest // empty' <<<"$folded")
    if [[ -n "$config_digest" && "$config_digest" != "$folded_digest" ]]; then
      data=$(jq -nc --arg c "$config_digest" --arg a "$folded_applied" \
        '{config_digest: $c}
         + (if $a == "" then {} else {applied_digest: $a} end)')
      # Both digests, because the event is a statement about the pair. Editing a
      # config from A to B and back to A used to produce one event and then
      # silence: the return to A carried the same discriminator as the state
      # before B, so it was dropped, and `dev status` reported drift no event
      # explained. With the applied digest folded in, each distinct (wanted,
      # applied) pair is its own event. One case survives by design: A -> B -> A
      # -> B with no intervening `dev open` re-emits the first B event's id, and
      # the repeat is dropped -- correctly, since nothing was applied in between
      # and the second B is the same undelivered fact as the first.
      id=$(dev_event_id_deterministic "$workspace_id" config.changed \
        "${config_digest}:${folded_applied}")
      discoveries+=("$(dev_event_build "$id" "$now" config.changed \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    # --- emit, then commit (ADR-1) ------------------------------------------
    local computed="$folded" ev
    if ((${#discoveries[@]} > 0)); then
      for ev in "${discoveries[@]}"; do
        id=$(jq -r '.id' <<<"$ev")
        if ! dev_events_has_id "$id"; then
          dev_event_append "$ev"
        fi
        computed=$(dev_fold_apply "$computed" "$ev")
      done
    fi

    # Overlay what observation alone establishes. When the fold cursor rotated
    # away (fold_gap) the backend is the only honest source of status.
    #
    # Re-anchor the cursor when the fold reported a gap. lib/fold.sh deliberately
    # leaves `scanned_through` untouched on an unreachable cursor — a fold that
    # silently advanced past a gap would be papering over the exact thing it was
    # asked to report. But leaving it unmoved makes the gap sticky: every later
    # reconcile re-derives it and re-flags forever. Reconcile, which is the layer
    # that has already reported the gap, anchors the cursor to the newest event it
    # scanned so folding resumes from the tail. `fold_gap` STAYS true — only
    # `workspace.opened` clears it — so the honest signal survives; what stops is
    # the pointless rescan.
    local newest
    newest=$(printf '%s\n' "$all_events" | jq -s -c 'if length == 0 then null else (.[-1] | {id, ts}) end')
    if [[ "$(jq -r '.fold_gap' <<<"$computed")" == "true" && "$newest" != "null" ]]; then
      computed=$(jq -c --argjson st "$newest" '.scanned_through = $st' <<<"$computed")
    fi

    local final
    final=$(jq -c --arg now "$now" --arg dg "$config_digest" --arg ex "$exists" '
      .last_seen = $now
      | .config_digest = (if $dg == "" then .config_digest else $dg end)
      | .status = (if $ex == "true" then "running"
                   elif (.fold_gap == true) then "stopped"
                   else .status end)
      | .stopped_reason = (if .status == "running" then null else .stopped_reason end)
    ' <<<"$computed")

    if dev_state_commit "$workspace_id" "$expected" "$final"; then
      # Rotation is checked outside the fold's shared lock, never inside it.
      dev_events_rotate_if_needed
      printf '%s\n' "$final"
      return 0
    fi

    attempt=$((attempt + 1))
  done

  printf 'dev: workspace %s is changing underneath this command; giving up after %s attempts\n' \
    "$slug" "$DEV_RECONCILE_MAX_ATTEMPTS" >&2
  return 8
}
