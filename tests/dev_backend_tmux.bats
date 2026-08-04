#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/container.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  export TEST_WT="$TEST_ROOT/workspace/proj"
  mkdir -p "$TEST_WT"
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

fixture_record() {
  jq -nc --arg wt "${1:-$TEST_WT}" --arg sn "${2:-proj}" '{
    v: 1, workspace_id: "aa11", session_name: $sn, slug: "proj", worktree: $wt,
    status: "running", boot_id: null, config_digest: null, applied_digest: null,
    container: {status: "none", kind: null, id: null, user: null, workdir: null,
                verified: false, up_exit_status: null, up_result: null, observed_at: null},
    agents: [], opened_at: null, last_seen: null,
    scanned_through: {id: null, ts: null}, fold_gap: false, stopped_reason: null
  }'
}

# The agent windows carry a long-lived placeholder command rather than "claude":
# these assertions are about window creation and event emission, not about which
# binary an agent window runs, and a command that exits would race remain-on-exit.
#
# Locations are null (unset) rather than "container", matching what Task 4's
# normalization actually produces for the default layer. fixture_record carries
# no container binding, so dev_window_location resolves them to host and the
# panes really run — which is the plain-repository path, and the only one these
# tests can exercise without docker. An earlier draft pinned "container" here
# and would have aborted apply_layout on the first window.
fixture_config() {
  jq -nc '{
    version: 1, autostart: false,
    devcontainer: {enabled: "auto", start_timeout: 300},
    environment: {},
    windows: [
      {name: "agent-1", agent: "sleep 30", command: null, cwd: null, location: null, focus: true},
      {name: "agent-2", agent: "sleep 30", command: null, cwd: null, location: null, focus: false},
      {name: "shell",   agent: null, command: null, cwd: null, location: null, focus: false},
      {name: "scratch", agent: null, command: null, cwd: null, location: "host", focus: false}
    ]}'
}

@test "create sets the three dev user options per session" {
  mkdir -p "$TEST_ROOT/workspace/wt-a" "$TEST_ROOT/workspace/wt-b"
  dev_backend_create "proj-a" "id-a" "proj" "$TEST_ROOT/workspace/wt-a"
  dev_backend_create "proj-b" "id-b" "proj" "$TEST_ROOT/workspace/wt-b"

  run dev_tmux show-options -qv -t "=proj-a:" @dev_workspace_id
  [ "$output" = "id-a" ]
  run dev_tmux show-options -qv -t "=proj-b:" @dev_workspace_id
  [ "$output" = "id-b" ]
  run dev_tmux show-options -qv -t "=proj-a:" @dev_worktree
  [ "$output" = "$TEST_ROOT/workspace/wt-a" ]
  run dev_tmux show-options -qv -t "=proj-b:" @dev_worktree
  [ "$output" = "$TEST_ROOT/workspace/wt-b" ]
  run dev_tmux show-options -qv -t "=proj-a:" @dev_slug
  [ "$output" = "proj" ]
}

@test "query with no tmux server at all reports exists:false and exits 0" {
  run dev_backend_query "nothing-here"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.exists')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.worktree')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.windows | length')" -eq 0 ]
}

@test "query on a nonexistent session of a running server reports exists:false and exits 0" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  run dev_backend_query "not-this-one"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.exists')" = "false" ]
}

@test "apply_layout creates the four default windows and is idempotent" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | sort | join(",")')" = "agent-1,agent-2,scratch,shell" ]
  [ "$(printf '%s' "$output" | jq -r '.worktree')" = "$TEST_WT" ]

  # A pane id captured before the second pass must survive it untouched.
  local before
  before=$(dev_tmux list-panes -t "=proj:=shell" -F '#{pane_id}')

  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$(printf '%s' "$output" | jq -r '.windows | length')" -eq 4 ]
  [ "$(dev_tmux list-panes -t '=proj:=shell' -F '#{pane_id}')" = "$before" ]
}

@test "apply_layout emits window.created per window and agent.started per agent window" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  local log="$DEV_STATE_ROOT/events/events.jsonl"
  [ "$(grep -c '"event":"window.created"' "$log")" -eq 4 ]
  [ "$(grep -c '"event":"agent.started"' "$log")" -eq 2 ]
  run jq -r 'select(.event == "agent.started") | .data.window' "$log"
  [[ "$output" == *"agent-1"* ]]
  [[ "$output" == *"agent-2"* ]]
  run jq -r 'select(.event == "window.created" and .data.window == "scratch") | .data.location' "$log"
  [ "$output" = "host" ]
  # An unset location on a container-less record resolves to host, not to a
  # container that does not exist.
  run jq -r 'select(.event == "window.created" and .data.window == "agent-1") | .data.location' "$log"
  [ "$output" = "host" ]
}

@test "the focused window is selected after the layout is applied" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"
  run dev_tmux display-message -p -t "=proj:" '#{window_name}'
  [ "$output" = "agent-1" ]
}

@test "per-window cwd and environment reach the running pane" {
  # The regression this pins: `environment` and `cwd` were normalized and
  # validated, then never applied — every window ran in the worktree with no
  # environment injected.
  mkdir -p "$TEST_WT/sub"
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local probe_cmd cfg
  probe_cmd="sh -c 'printf \"%s|%s\\n\" \"\$PWD\" \"\$DEV_PROBE\" >probe.out; sleep 5'"
  cfg=$(jq -nc --arg cmd "$probe_cmd" '{version: 1, autostart: false,
    environment: {DEV_PROBE: "hello world"},
    windows: [{name: "probe", agent: null, command: $cmd,
               cwd: "sub", location: "host", focus: false}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  local i
  for i in $(seq 1 50); do
    [[ -f "$TEST_WT/sub/probe.out" ]] && break
    sleep 0.1
  done
  [ -f "$TEST_WT/sub/probe.out" ]
  run cat "$TEST_WT/sub/probe.out"
  [ "$output" = "$TEST_WT/sub|hello world" ]
}

@test "remain-on-exit is set per window and never globally" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_tmux show-window-options -t "=proj:=shell" remain-on-exit
  [[ "$output" == *"on"* ]]

  run dev_tmux show-options -g remain-on-exit
  [[ "$output" != *" on"* ]]
}

@test "a window whose process exits stays visible as a dead pane" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local cfg
  # sleep first so remain-on-exit is set before the process can exit; an
  # immediate `exit 3` races the option and tmux destroys the window.
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {}, windows: [
    {name: "shell", agent: null, command: "sleep 0.2; exit 3", cwd: null, location: "host", focus: true}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  sleep 1

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | join(",")')" = "shell" ]
  [ "$(printf '%s' "$output" | jq -r '.windows[0].panes[0].alive')" = "false" ]
}

@test "respawn_pane brings a dead pane back to alive and emits pane.respawned" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local cfg
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {}, windows: [
    {name: "shell", agent: null, command: "sleep 0.2; exit 3", cwd: null, location: "host", focus: true}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  sleep 1
  [ "$(dev_backend_query proj | jq -r '.windows[0].panes[0].alive')" = "false" ]

  dev_backend_respawn_pane "proj" "shell" "sleep 30"

  run dev_backend_query "proj"
  [ "$(printf '%s' "$output" | jq -r '.windows[0].panes[0].alive')" = "true" ]
  run jq -r 'select(.event == "pane.respawned") | .data.window + " " + .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$output" = "shell aa11" ]
}

@test "kill removes the session and is a no-op when it is already gone" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  run dev_backend_kill "proj"
  [ "$status" -eq 0 ]
  [ "$(dev_backend_query proj | jq -r '.exists')" = "false" ]
  run dev_backend_kill "proj"
  [ "$status" -eq 0 ]
}
