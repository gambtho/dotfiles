#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/vekil.sh"
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

# --- Fix round 1: closing review findings 1, 2 and 4 (finding 3 is out of scope) ---
#
# Every test below creates ONLY a longer-named session ("proj-longer") and then
# targets the shorter name ("proj"), which exists nowhere. This is deliberate:
# tmux resolves an unqualified target by prefix match, so a bare (non-"=")
# target for "proj" silently resolves to "proj-longer" and returns success —
# exactly the cross-workspace misattachment ADR-7's "=" prefix exists to
# prevent. Creating both names would not expose this: when a session exists
# under the exact requested name, tmux prefers the exact match regardless of
# whether "=" is present, so the ambiguity only shows up when the exact name
# is entirely absent.

@test "query, kill and apply_layout never misattach to a longer-named session" {
  mkdir -p "$TEST_ROOT/workspace/proj-longer"
  dev_backend_create "proj-longer" "id-longer" "proj" "$TEST_ROOT/workspace/proj-longer"

  # M1: list-panes losing "=" would resolve "proj" to "proj-longer" and report
  # its panes as if they belonged to the (nonexistent) "proj" session.
  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.exists')" = "false" ]

  # M2: has-session/kill-session losing "=" would find and destroy
  # "proj-longer" when asked to kill the (nonexistent) "proj".
  run dev_backend_kill "proj"
  [ "$status" -eq 0 ]
  run dev_tmux has-session -t "=proj-longer"
  [ "$status" -eq 0 ]

  # M3: new-window losing "=" would create the new window inside
  # "proj-longer" instead of failing to find the (nonexistent) "proj".
  run dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record "$TEST_ROOT/workspace/proj-longer" "proj")"
  [ "$status" -ne 0 ]
  run dev_tmux list-windows -t "=proj-longer:" -F '#{window_name}'
  [ "$output" = "dev-holder" ]
}

# M4 (set-window-option losing "=" on "=$session:=$name") cannot be exercised
# independently of M3 under single-mutation testing: set-window-option only
# ever runs immediately after new-window has just created that exact window
# name in that exact session, and new-window's own "=" (unmutated when M4
# alone is applied) already guarantees the target is unambiguous by the time
# set-window-option runs. Every scenario that reaches this line therefore has
# only one possible session and only one possible window of that name, so the
# bare and "=" forms resolve identically. No test can distinguish them; see
# task-11-report.md for the full argument. Kill table below reports this
# honestly as SURVIVED (structurally unreachable), not as a gap in test design.

@test "apply_layout creates a same-name window even when only a longer name pre-exists" {
  # M27: the existing-window diff (grep -Fxq) must treat "my-shell" and
  # "shell" as distinct names. A substring-based diff would wrongly treat the
  # pre-existing "my-shell" as satisfying the config's request for "shell" and
  # skip creating it.
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_tmux new-window -d -t "=proj:" -n "my-shell" "sleep 30"

  local cfg
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {}, windows: [
    {name: "shell", agent: null, command: "sleep 30", cwd: null, location: "host", focus: false}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | sort | join(",")')" = "my-shell,shell" ]
}

@test "query reports clients as a present, numeric field" {
  # M8: `clients` must actually be read from tmux and typed as a number, not
  # merely present with a fixed placeholder. Its true value needs a real
  # attached client (a pty) to observe, which is out of reach for these tests
  # and is deferred to Task 14 (M9); this only pins presence and type.
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.clients | type == "number"' >/dev/null
  [ "$(printf '%s' "$output" | jq -r 'has("clients")')" = "true" ]
}

# Task 14 / M9: closes the gap the test above documents. `script -qc` allocates a
# real pty and runs `tmux attach-session` inside it, so this is a genuine attached
# client -- not a stub -- and `clients` must reflect it exactly, then drop back to
# 0 once the client detaches. A hardcoded `clients:0` would have passed the M8
# test above; it cannot pass this one.
@test "query reports a nonzero clients count for a real attached client, and 0 again after detach" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.clients')" = "0" ]

  # SHELL=/bin/bash: `script -qc` runs its command via `$SHELL -c`, and under
  # the invoking user's zsh, a bare `=proj` word is zsh's named-directory/
  # command-path expansion syntax, not a literal string -- it fails with
  # "proj not found" before tmux ever sees it. Forcing bash for this one
  # subprocess keeps the exact-match `=name` target intact.
  # TERM=xterm-256color: CI runners export TERM=dumb (or nothing), and tmux
  # then refuses the client with "open terminal failed: terminal does not
  # support clear" -- the pty is real but the attach never happens and
  # clients stays 0. Reproduced both ways; the forced TERM applies only
  # inside this pty.
  SHELL=/bin/bash script -qc "TERM=xterm-256color tmux -L $DEV_TMUX_SOCKET attach-session -t =proj" /dev/null >/dev/null 2>&1 &
  local client_pid=$!

  local tries=0 clients=0
  while [ "$tries" -lt 50 ]; do
    clients=$(dev_backend_query "proj" | jq -r '.clients')
    [ "$clients" != "0" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$clients" = "1" ]

  dev_tmux detach-client -a -s proj 2>/dev/null || true
  kill "$client_pid" 2>/dev/null || true
  wait "$client_pid" 2>/dev/null || true

  tries=0
  while [ "$tries" -lt 50 ]; do
    clients=$(dev_backend_query "proj" | jq -r '.clients')
    [ "$clients" = "0" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$clients" = "0" ]
}

@test "query reports pane logical names and handles; unstamped panes report pane:null" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_tmux new-window -d -t "=proj:" -n w1 "sleep 30" \
    ';' set-window-option -t "=proj:=w1" remain-on-exit on \
    ';' set-option -p -t "=proj:=w1" @dev_pane agent-1
  pid=$(dev_tmux split-window -d -P -F '#{pane_id}' -t "=proj:=w1" "sleep 30")
  dev_tmux set-option -p -t "$pid" @dev_pane shell
  dev_tmux split-window -d -t "=proj:=w1" "sleep 30" # unstamped

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "w1")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 3 ]
  [ "$(jq -r '[.panes[].pane] | sort | join(",")' <<<"$win")" = ",agent-1,shell" ]
  [ "$(jq -r '[.panes[] | select(.pane == "shell") | .pane_id] | first' <<<"$win")" = "$pid" ]
  [ "$(jq -r '[.panes[] | select(.pane == null)] | length' <<<"$win")" -eq 1 ]
}
