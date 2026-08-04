#!/usr/bin/env bash
# The event fold: spec §4.4's transition table as a jq program.
#
# Invariants the table encodes, restated because they are easy to break:
#   * no container.* event writes .status; no workspace.* event writes .container.status
#   * container.ready replaces the entire container object, never patches it
#   * only workspace.attached/detached write .last_seen in the fold
#   * every transition is an absolute assignment, which is what makes replay idempotent
#   * unknown event types fall through unchanged — ignored, never rejected
#   * agent identity is (window, data.pane // null); legacy pane-less events
#     and records fold identically with pane: null (spec §3)
#
# This file is sourced. It defines functions and does no work at source time.

# The shared jq source. Internal to this file; no other task calls it.
dev_fold_jq_program() {
  cat <<'JQ'
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

def fold_event($ev):
  . as $r
  | ($ev.data // {}) as $d
  | $ev.ts as $ts
  | if $ev.workspace_id != $r.workspace_id then .
    elif ($r.opened_at != null
          and $ts < $r.opened_at
          and $ev.event != "workspace.opened") then .
    elif $ev.event == "workspace.opened" then
      .status = "running"
      | .opened_at = $ts
      | .boot_id = $d.boot_id
      | .applied_digest = $d.config_digest
      | .session_name = ($d.session_name_actual // .session_name)
      | .stopped_reason = null
      | .fold_gap = false
    elif $ev.event == "workspace.attached" then .last_seen = $ts
    elif $ev.event == "workspace.detached" then .last_seen = $ts
    elif $ev.event == "workspace.stopped" then
      .status = "stopped" | .stopped_reason = $d.reason
    elif $ev.event == "workspace.vanished" then
      .status = "stopped" | .stopped_reason = $d.reason
    elif $ev.event == "window.created" then .
    elif $ev.event == "pane.died" then
      if agent_has($d) then agent_upsert($d; {state: "exited"}) else . end
    elif $ev.event == "pane.respawned" then
      if agent_has($d) then agent_upsert($d; {state: "started"}) else . end
    elif $ev.event == "container.starting" then
      .container.status = "starting" | .container.verified = false
    elif $ev.event == "container.ready" then
      .container = {
        status: "ready",
        kind: $d.kind,
        id: $d.id,
        user: $d.user,
        workdir: $d.workdir,
        verified: false,
        up_exit_status: $d.up_exit_status,
        up_result: $d.up_result,
        observed_at: $ts
      }
    elif $ev.event == "container.failed" then
      .container.status = "failed"
      | .container.observed_at = $ts
      | .container.up_exit_status = $d.up_exit_status
    elif $ev.event == "container.lost" then
      .container.id = null
      | .container.status = "lost"
      | .container.observed_at = $ts
    elif $ev.event == "container.replaced" then .
    elif $ev.event == "agent.started" then
      agent_upsert($d; {command: $d.command, state: "started"})
    elif $ev.event == "agent.exited" then
      agent_upsert($d; {state: "exited"})
    elif $ev.event == "agent.failed" then
      agent_upsert($d; {state: "failed"})
    elif $ev.event == "config.changed" then
      .config_digest = $d.config_digest
    else .
    end;

def fold_stream($events):
  . as $r
  | $r.scanned_through.id as $cursor
  | (if $cursor == null then -1
     else (first($events | to_entries[] | select(.value.id == $cursor) | .key) // -2)
     end) as $at
  | if $at == -2 then
      .fold_gap = true
    else
      $events[($at + 1):] as $pending
      | reduce $pending[] as $ev (.; fold_event($ev))
      | ($pending | last) as $tail
      | if $tail == null then .
        else .scanned_through = {id: $tail.id, ts: $tail.ts}
        end
    end;
JQ
}

dev_fold_apply() {
  local record=$1 event=$2
  local program
  program=$(dev_fold_jq_program)
  printf '%s' "$record" | jq -c --argjson ev "$event" "$program"' fold_event($ev)'
}

# Events arrive on stdin, one JSON object per line, oldest first. Slurped so the
# cursor can be located by index; the cursor is the last event *scanned*, whether
# or not it belonged to this workspace (ADR-1).
dev_fold_stream() {
  local record=$1
  local program
  program=$(dev_fold_jq_program)
  jq -s -c --argjson rec "$record" \
    "$program"' . as $events | $rec | fold_stream($events)'
}
