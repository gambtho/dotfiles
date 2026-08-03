#!/usr/bin/env bats

load test_helper

WS_ID=9f2c4a7b1e05de3c8a41f07b2e6d95c3a8b17f42e0d6c95183ba7e4f2c0d68a9
OTHER_ID=1111111111111111111111111111111111111111111111111111111111111111

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  REC=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
}

# mkevent <id> <ts> <event> <data_json> [workspace_id]
mkevent() {
  dev_event_build "$1" "$2" "$3" "${5:-$WS_ID}" \
    slabledger slabledger /home/tng/workspace/slabledger "$4"
}

@test "fold: workspace.opened sets the incarnation and clears fold_gap" {
  local rec ev out
  rec=$(jq -c '.fold_gap = true | .stopped_reason = "user" | .status = "stopped"' <<<"$REC")
  ev=$(mkevent aaaa000000000001 2026-08-03T13:58:02.001Z workspace.opened \
    '{"boot_id":"6f2a1c9e","config_digest":"sha256:9a3f","session_name_actual":"slabledger--wt"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .opened_at <<<"$out")" = 2026-08-03T13:58:02.001Z ]
  [ "$(jq -r .boot_id <<<"$out")" = 6f2a1c9e ]
  [ "$(jq -r .applied_digest <<<"$out")" = sha256:9a3f ]
  [ "$(jq -r .session_name <<<"$out")" = slabledger--wt ]
  [ "$(jq -r .stopped_reason <<<"$out")" = null ]
  [ "$(jq -r .fold_gap <<<"$out")" = false ]
  # config_digest is written by config.changed and by reconcile, never by opened.
  [ "$(jq -r .config_digest <<<"$out")" = null ]
}

@test "fold: workspace.stopped and workspace.vanished set status and reason only" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.status = "ready" | .container.id = "a710"' <<<"$REC")
  ev=$(mkevent aaaa000000000002 2026-08-03T14:00:00.000Z workspace.stopped '{"reason":"user"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -r .stopped_reason <<<"$out")" = user ]
  # No workspace.* event may touch the container axis.
  [ "$(jq -c .container <<<"$out")" = "$(jq -c .container <<<"$rec")" ]

  ev=$(mkevent aaaa000000000003 2026-08-03T14:00:01.000Z workspace.vanished \
    '{"discovered_at":"2026-08-03T14:00:01.000Z","reason":"host_restart","last_boot_id":"old"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -r .stopped_reason <<<"$out")" = host_restart ]
  [ "$(jq -c .container <<<"$out")" = "$(jq -c .container <<<"$rec")" ]
}

@test "fold: attached and detached set last_seen and nothing else" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000004 2026-08-03T14:02:11.412Z workspace.attached '{"client":"/dev/pts/3"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .last_seen <<<"$out")" = 2026-08-03T14:02:11.412Z ]
  [ "$(jq -S -c 'del(.last_seen)' <<<"$out")" = "$(jq -S -c 'del(.last_seen)' <<<"$rec")" ]

  ev=$(mkevent aaaa000000000005 2026-08-03T14:03:00.000Z workspace.detached '{"client":"/dev/pts/3"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .last_seen <<<"$out")" = 2026-08-03T14:03:00.000Z ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -S -c 'del(.last_seen)' <<<"$out")" = "$(jq -S -c 'del(.last_seen)' <<<"$rec")" ]
}

@test "fold: container.ready replaces the whole container object" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container = {
    status: "ready", kind: "single", id: "3f9c", user: "root", workdir: "/src",
    verified: true, up_exit_status: 0, up_result: {containerId: "3f9c"},
    observed_at: "2026-08-03T10:00:00.000Z"
  }' <<<"$REC")
  ev=$(mkevent aaaa000000000006 2026-08-03T14:02:11.412Z container.ready \
    '{"id":"a710","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710","remoteUser":"vscode","remoteWorkspaceFolder":"/workspace"}}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = ready ]
  [ "$(jq -r .container.kind <<<"$out")" = compose ]
  [ "$(jq -r .container.id <<<"$out")" = a710 ]
  [ "$(jq -r .container.user <<<"$out")" = vscode ]
  [ "$(jq -r .container.workdir <<<"$out")" = /workspace ]
  [ "$(jq -r .container.up_exit_status <<<"$out")" = 0 ]
  [ "$(jq -r .container.up_result.remoteUser <<<"$out")" = vscode ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:02:11.412Z ]
  # verified is reset, never inherited (§5.3).
  [ "$(jq -r .container.verified <<<"$out")" = false ]
  # No container.* event writes the workspace status.
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r '.container | keys_unsorted | length' <<<"$out")" = 9 ]
}

@test "fold: container.starting and container.failed leave status alone" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000007 2026-08-03T14:00:00.000Z container.starting '{"config_path":".devcontainer/devcontainer.json"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = starting ]
  [ "$(jq -r .container.verified <<<"$out")" = false ]
  [ "$(jq -r .status <<<"$out")" = running ]

  ev=$(mkevent aaaa000000000008 2026-08-03T14:00:30.000Z container.failed \
    '{"reason":"compose up failed","up_exit_status":1,"stderr_tail":"no such service"}')
  out=$(dev_fold_apply "$out" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = failed ]
  [ "$(jq -r .container.up_exit_status <<<"$out")" = 1 ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:00:30.000Z ]
  # The one rule an earlier draft broke: container failure is not workspace death.
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .stopped_reason <<<"$out")" = null ]
}

@test "fold: container.lost nulls the id and leaves status alone" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.status = "ready" | .container.id = "a710" | .container.user = "vscode"' <<<"$REC")
  ev=$(mkevent aaaa000000000009 2026-08-03T14:05:00.000Z container.lost \
    '{"old_id":"a710","discovered_at":"2026-08-03T14:05:00.000Z"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.id <<<"$out")" = null ]
  [ "$(jq -r .container.status <<<"$out")" = lost ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:05:00.000Z ]
  [ "$(jq -r .container.user <<<"$out")" = vscode ]
  [ "$(jq -r .status <<<"$out")" = running ]
}

@test "fold: container.replaced and window.created fold to nothing" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.id = "a710"' <<<"$REC")
  ev=$(mkevent aaaa00000000000a 2026-08-03T14:06:00.000Z container.replaced \
    '{"old_id":"3f9c","new_id":"a710","reason":"rebuild"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]

  ev=$(mkevent aaaa00000000000b 2026-08-03T14:06:01.000Z window.created \
    '{"window":"scratch","location":"host","command":"zsh"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]
}

@test "fold: agent events upsert by window" {
  local rec out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa00000000000c 2026-08-03T14:07:00.000Z agent.started '{"window":"agent-1","command":"claude"}')")
  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000d 2026-08-03T14:07:01.000Z agent.started '{"window":"agent-2","command":"claude"}')")
  [ "$(jq -c .agents <<<"$out")" = '[{"window":"agent-1","command":"claude","state":"started"},{"window":"agent-2","command":"claude","state":"started"}]' ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000e 2026-08-03T14:08:00.000Z agent.exited '{"window":"agent-2","exit_status":0}')")
  [ "$(jq -r '.agents[] | select(.window == "agent-2") | .state' <<<"$out")" = exited ]
  [ "$(jq -r '.agents[] | select(.window == "agent-1") | .state' <<<"$out")" = started ]
  [ "$(jq -r '.agents[] | select(.window == "agent-2") | .command' <<<"$out")" = claude ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000f 2026-08-03T14:09:00.000Z agent.failed '{"window":"agent-1","reason":"crash","exit_status":137}')")
  [ "$(jq -r '.agents[] | select(.window == "agent-1") | .state' <<<"$out")" = failed ]
  [ "$(jq -c '.agents | length' <<<"$out")" = 2 ]
}

@test "fold: pane events change agent state only for windows carrying an agent" {
  local rec out
  rec=$(jq -c '.status = "running" | .agents = [{window: "agent-1", command: "claude", state: "started"}]' <<<"$REC")
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa000000000010 2026-08-03T14:10:00.000Z pane.died '{"window":"agent-1","exit_status":1}')")
  [ "$(jq -r '.agents[0].state' <<<"$out")" = exited ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000011 2026-08-03T14:11:00.000Z pane.respawned '{"window":"agent-1","container_id":"a710"}')")
  [ "$(jq -r '.agents[0].state' <<<"$out")" = started ]

  # scratch carries no agent: the pane event must not invent one.
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000012 2026-08-03T14:12:00.000Z pane.died '{"window":"scratch","exit_status":0}')")
  [ "$(jq -c '.agents | length' <<<"$out")" = 1 ]
  [ "$(jq -r '.agents[0].window' <<<"$out")" = agent-1 ]
  [ "$(jq -r '.agents[0].state' <<<"$out")" = started ]
}

@test "fold: config.changed writes config_digest and never applied_digest" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .config_digest = "sha256:old" | .applied_digest = "sha256:old"' <<<"$REC")
  ev=$(mkevent aaaa000000000013 2026-08-03T14:13:00.000Z config.changed \
    '{"config_digest":"sha256:new","applied_digest":"sha256:old"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .config_digest <<<"$out")" = sha256:new ]
  [ "$(jq -r .applied_digest <<<"$out")" = sha256:old ]
  [ "$(jq -S -c 'del(.config_digest)' <<<"$out")" = "$(jq -S -c 'del(.config_digest)' <<<"$rec")" ]
}

@test "fold: an event older than opened_at is skipped" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .opened_at = "2026-08-03T13:58:02.001Z"' <<<"$REC")
  ev=$(mkevent aaaa000000000014 2026-08-02T22:00:00.000Z workspace.stopped '{"reason":"user"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]

  # ...but workspace.opened itself moves the boundary.
  ev=$(mkevent aaaa000000000015 2026-08-03T09:00:00.000Z workspace.opened \
    '{"boot_id":"b0","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .opened_at <<<"$out")" = 2026-08-03T09:00:00.000Z ]
}

@test "fold: an unknown event type advances the cursor and changes nothing else" {
  local ev out
  ev=$(mkevent aaaa000000000016 2026-08-03T14:14:00.000Z notification.sent '{"target":"slack"}')
  out=$(printf '%s\n' "$ev" | dev_fold_stream "$REC")
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa000000000016 ]
  [ "$(jq -r .scanned_through.ts <<<"$out")" = 2026-08-03T14:14:00.000Z ]
  [ "$(jq -S -c 'del(.scanned_through)' <<<"$out")" = "$(jq -S -c 'del(.scanned_through)' <<<"$REC")" ]
}

@test "fold: the cursor advances across another workspace's event" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000017 2026-08-03T14:15:00.000Z workspace.stopped '{"reason":"user"}' "$OTHER_ID")
  out=$(printf '%s\n' "$ev" | dev_fold_stream "$rec")
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa000000000017 ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -S -c 'del(.scanned_through)' <<<"$out")" = "$(jq -S -c 'del(.scanned_through)' <<<"$rec")" ]
}

@test "fold: the stream resumes after the cursor and stops at the tail" {
  local seg rec out
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa000000000018 2026-08-03T13:58:02.001Z workspace.opened \
      '{"boot_id":"b1","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}'
    mkevent aaaa000000000019 2026-08-03T13:59:00.000Z agent.started '{"window":"agent-1","command":"claude"}'
    mkevent aaaa00000000001a 2026-08-03T14:00:00.000Z workspace.stopped '{"reason":"user"}'
  } >"$seg"
  rec=$(jq -c '
    .status = "running"
    | .opened_at = "2026-08-03T13:58:02.001Z"
    | .scanned_through = {id: "aaaa000000000019", ts: "2026-08-03T13:59:00.000Z"}
  ' <<<"$REC")
  out=$(dev_fold_stream "$rec" <"$seg")
  # Only the event after the cursor was applied.
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -c '.agents | length' <<<"$out")" = 0 ]
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa00000000001a ]
}

@test "fold: folding the same segment twice is byte-identical" {
  local seg once twice replay
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa00000000001b 2026-08-03T13:58:02.001Z workspace.opened \
      '{"boot_id":"b1","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}'
    mkevent aaaa00000000001c 2026-08-03T13:58:03.000Z container.starting '{}'
    mkevent aaaa00000000001d 2026-08-03T13:58:04.000Z container.ready \
      '{"id":"a710","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710"}}'
    mkevent aaaa00000000001e 2026-08-03T13:58:05.000Z agent.started '{"window":"agent-1","command":"claude"}'
    mkevent aaaa00000000001f 2026-08-03T13:58:06.000Z pane.died '{"window":"agent-1","exit_status":1}'
    mkevent aaaa000000000020 2026-08-03T13:58:07.000Z workspace.attached '{"client":"/dev/pts/3"}'
  } >"$seg"
  once=$(dev_fold_stream "$REC" <"$seg" | jq -S -c .)
  twice=$(dev_fold_stream "$REC" <"$seg" | jq -S -c .)
  [ "$once" = "$twice" ]
  # Replaying the whole segment onto the already-folded record, cursor reset,
  # must reproduce it exactly — this is the idempotence ADR-1 relies on.
  replay=$(dev_fold_stream "$(jq -c '.scanned_through = null' <<<"$once")" <"$seg" | jq -S -c .)
  diff <(printf '%s\n' "$once") <(printf '%s\n' "$replay")
}

@test "fold: an unreachable cursor sets fold_gap and folds nothing" {
  local seg rec out
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa000000000021 2026-08-03T14:20:00.000Z workspace.stopped '{"reason":"user"}'
    mkevent aaaa000000000022 2026-08-03T14:21:00.000Z container.lost '{"old_id":"a710"}'
  } >"$seg"
  rec=$(jq -c '
    .status = "running"
    | .opened_at = "2026-08-03T13:00:00.000Z"
    | .scanned_through = {id: "deadbeefdeadbeef", ts: "2026-08-02T00:00:00.000Z"}
  ' <<<"$REC")
  out=$(dev_fold_stream "$rec" <"$seg")
  [ "$(jq -r .fold_gap <<<"$out")" = true ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .container.status <<<"$out")" = none ]
  [ "$(jq -r .scanned_through.id <<<"$out")" = deadbeefdeadbeef ]
  [ "$(jq -S -c 'del(.fold_gap)' <<<"$out")" = "$(jq -S -c 'del(.fold_gap)' <<<"$rec")" ]
}

@test "fold: an empty stream leaves the record untouched" {
  local out
  out=$(dev_fold_stream "$REC" </dev/null)
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$REC")" ]
}
