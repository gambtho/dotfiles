#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  export DEV_CONTAINER_MARKER="$TEST_ROOT/no-such-marker"
  stage_dev_root
  make_fixture_repo "proj"
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

# The dispatcher must be exercised against a tree that contains a commands/
# directory we control, because commands/open.sh does not exist until Task 14
# and this test must not depend on it. Staging a copy of the repo and writing a
# stub open.sh into it keeps the test stable both before and after Task 14.
stage_dev_root() {
  mkdir -p "$TEST_ROOT/root/tools/dev"
  cp -r "$REPO_ROOT/bin" "$TEST_ROOT/root/bin"
  cp -r "$REPO_ROOT/tools/dev/lib" "$TEST_ROOT/root/tools/dev/lib"
  cp -r "$REPO_ROOT/tools/dev/commands" "$TEST_ROOT/root/tools/dev/commands"
  # Pinned to the LEGACY four-window layout (not a cp of the shipped default):
  # these dispatcher-pattern scenarios exercise the single-pane window paths
  # and must keep doing so regardless of what the shipped default becomes.
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
  export DEV_DOTFILES_ROOT="$TEST_ROOT/root"
}

stub_open_command() {
  cat >"$TEST_ROOT/root/tools/dev/commands/open.sh" <<'EOF'
dev_cmd_open() { printf 'OPEN:%s\n' "$*"; }
EOF
}

make_fixture_repo() {
  local name="$1"
  mkdir -p "$DEV_REPO_ROOT/$name"
  git -C "$DEV_REPO_ROOT/$name" init -q
}

@test "dev --help exits 0 and lists the six verbs" {
  run "$TEST_ROOT/root/bin/dev" --help
  [ "$status" -eq 0 ]
  local verb
  for verb in open attach list status stop config; do
    [[ "$output" == *"$verb"* ]]
  done
}

@test "dev rejects an unknown flag with exit 2" {
  run "$TEST_ROOT/root/bin/dev" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "dev refuses to run inside a container with exit 10" {
  touch "$TEST_ROOT/in-a-container"
  DEV_CONTAINER_MARKER="$TEST_ROOT/in-a-container" run "$TEST_ROOT/root/bin/dev" list
  [ "$status" -eq 10 ]
  [[ "$output" == *"tmux server"* ]]
  [[ "$output" == *"host"* ]]
}

@test "dev config prints valid JSON with the four default windows" {
  run "$TEST_ROOT/root/bin/dev" config proj
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | sort | join(",")')" = "agent-1,agent-2,scratch,shell" ]
  [ "$(printf '%s' "$output" | jq -r '.version')" -eq 1 ]
}

@test "dev config --compact prints one line" {
  run "$TEST_ROOT/root/bin/dev" config --compact proj
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "dev config exits 5 on a config that fails validation" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: shell
    agent: claude
    command: make test
EOF
  run "$TEST_ROOT/root/bin/dev" config proj
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]]
}

@test "a word matching a command file dispatches to that command" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev" config --compact proj
  [ "$status" -eq 0 ]
  [[ "$output" != OPEN:* ]]
  printf '%s' "$output" | jq -e . >/dev/null
}

@test "a word matching no command file dispatches to open with the word intact" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev" slabledger
  [ "$status" -eq 0 ]
  [ "$output" = "OPEN:slabledger" ]
}

@test "no arguments at all dispatches to open with no arguments" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev"
  [ "$status" -eq 0 ]
  [ "$output" = "OPEN:" ]
}

@test "a verb containing a path separator is a usage error" {
  run "$TEST_ROOT/root/bin/dev" ../../etc/passwd
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Task 13: dev list / dev status
# ---------------------------------------------------------------------------

# Any invocation of docker or the devcontainer CLI leaves a marker file behind,
# so a test can assert that a read-only command started nothing.
stub_no_start_runtime() {
  stub_command docker "touch '$TEST_ROOT/docker-called'; exit 0"
  stub_command devcontainer "touch '$TEST_ROOT/devcontainer-called'; exit 0"
}

write_record() {
  local id="$1" session="$2" slug="$3" worktree="$4"
  local status="$5" cstatus="$6" applied="$7" foldgap="$8"
  jq -nc \
    --arg id "$id" --arg sn "$session" --arg slug "$slug" --arg wt "$worktree" \
    --arg st "$status" --arg cs "$cstatus" --arg ap "$applied" --argjson fg "$foldgap" '{
      v: 1, workspace_id: $id, session_name: $sn, slug: $slug, worktree: $wt,
      status: $st, boot_id: null,
      config_digest: $ap, applied_digest: $ap,
      container: {status: $cs, kind: null, id: null, user: null, workdir: null,
                  verified: false, up_exit_status: null, up_result: null, observed_at: null},
      agents: [], opened_at: null, last_seen: "2026-08-03T10:00:00.000Z",
      scanned_through: {id: null, ts: null}, fold_gap: $fg, stopped_reason: null
    }' >"$DEV_STATE_ROOT/workspaces/${id}.json"
}

@test "dev list --json emits v:1 and every workspace, and parses as JSON" {
  make_fixture_repo "alpha"
  make_fixture_repo "beta"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:x" false
  write_record "$(printf 'b%.0s' {1..64})" beta beta "$DEV_REPO_ROOT/beta" stopped none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.v')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '[.workspaces[].session_name] | sort | join(",")')" = "alpha,beta" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("container")')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("fold_gap")')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("stopped_reason")')" = "true" ]
}

@test "a record whose session is absent lists as stopped and starts nothing" {
  stub_no_start_runtime
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].status')" = "stopped" ]
  [ ! -e "$TEST_ROOT/docker-called" ]
  [ ! -e "$TEST_ROOT/devcontainer-called" ]
}

@test "dev list groups two worktrees of one slug together" {
  make_fixture_repo "proj"
  mkdir -p "$DEV_REPO_ROOT/proj-pr5"
  git -C "$DEV_REPO_ROOT/proj-pr5" init -q
  write_record "$(printf 'c%.0s' {1..64})" proj proj "$DEV_REPO_ROOT/proj" stopped none "sha256:x" false
  write_record "$(printf 'd%.0s' {1..64})" "proj--proj-pr5" proj "$DEV_REPO_ROOT/proj-pr5" stopped none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^proj$')" -eq 1 ]
  [[ "$output" == *"  proj"* ]]
  [[ "$output" == *"proj--proj-pr5"* ]]
}

@test "a workspace whose reconcile fails is listed, but marked stale" {
  # The listing must neither drop the workspace nor present a remembered record
  # as if it had just been observed. `dev list --json` promises observed state
  # (ADR-2); `stale` is how it stays honest when it could not deliver that.
  stub_no_start_runtime
  make_fixture_repo "alpha"
  local id
  id=$(printf 'a%.0s' {1..64})
  write_record "$id" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  # The session is gone, so reconcile must write (status running -> stopped);
  # a read-only records directory makes every commit attempt fail, and reconcile
  # gives up with 8 after its bounded retries.
  chmod 500 "$DEV_STATE_ROOT/workspaces"

  run "$TEST_ROOT/root/bin/dev" list --json
  local rc="$status" out="$output"
  chmod 700 "$DEV_STATE_ROOT/workspaces"
  [ "$rc" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r '.workspaces | length')" -eq 1 ]
  [ "$(printf '%s' "$out" | jq -r '.workspaces[0].stale')" = "true" ]
  # Reported as the record last said, not as reconcile would have corrected it.
  [ "$(printf '%s' "$out" | jq -r '.workspaces[0].status')" = "running" ]
}

@test "a successfully reconciled entry is marked not stale" {
  stub_no_start_runtime
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].stale')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].status')" = "stopped" ]
}

# dev status resolves a workspace via dev_resolve, which derives workspace_id
# as sha256(realpath(worktree)) -- not the literal fixture ids write_record's
# other callers use. A record written under a mismatched id is invisible to
# dev status (dev_reconcile falls into "not found" and synthesizes a fresh
# record), so the status tests below must key their fixture the same way
# dev_resolve_workspace_id does.
workspace_id_for() {
  printf '%s' "$(realpath "$1")" | sha256sum | cut -d' ' -f1
}

@test "dev status reports a container-failed workspace as running with container failed" {
  make_fixture_repo "alpha"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  local id
  id=$(workspace_id_for "$DEV_REPO_ROOT/alpha")
  write_record "$id" alpha alpha "$DEV_REPO_ROOT/alpha" running failed "sha256:x" false
  dev_backend_create "alpha" "$id" "alpha" "$DEV_REPO_ROOT/alpha"

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
  [[ "$output" == *"container"*"failed"* ]]
}

@test "dev status on a drifted configuration names dev stop as the remedy" {
  make_fixture_repo "alpha"
  write_record "$(workspace_id_for "$DEV_REPO_ROOT/alpha")" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:stale" false

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev stop"* ]]
  [[ "$output" == *"drift"* ]]
}

@test "dev status surfaces fold_gap in words rather than as a flag" {
  make_fixture_repo "alpha"
  write_record "$(workspace_id_for "$DEV_REPO_ROOT/alpha")" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:x" true

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"were not recorded"* ]]
}

dev_open_load_libs() {
  source "$REPO_ROOT/bin/common.sh"
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/config.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  source "$REPO_ROOT/tools/dev/lib/reconcile.sh"
  source "$REPO_ROOT/tools/dev/lib/runtime.sh"
  source "$REPO_ROOT/tools/dev/lib/vekil.sh"
  source "$REPO_ROOT/tools/dev/lib/container.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  source "$REPO_ROOT/tools/dev/commands/open.sh"
  source "$REPO_ROOT/tools/dev/commands/attach.sh"
  source "$REPO_ROOT/tools/dev/commands/stop.sh"
  source "$REPO_ROOT/tools/dev/commands/list.sh"
  source "$REPO_ROOT/tools/dev/commands/status.sh"
}

# dev_open_load_libs sources the real repo directly and setup_dev_test points
# DEV_DOTFILES_ROOT at $REPO_ROOT, so these sourced-function scenarios read
# the actual shipped default-workspace.yaml -- not a copy under stage_dev_root
# (that fixture only feeds the dispatcher-pattern tests above). Scenarios that
# assert the legacy single-pane *window* shape (agent-1/agent-2/shell/scratch
# as windows, not panes of one dashboard window) call dev_pin_legacy_default_root
# (test_helper.bash) to pin that shape regardless of what the shipped default
# becomes.

dev_open_fixture() {
  local dir="$DEV_REPO_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf '%s\n' "$dir"
}

dev_open_stub_attach() {
  dev_open_attach() {
    printf 'ATTACH %s\n' "$1" >>"$TEST_ROOT/attached"
  }
}

dev_open_events() {
  jq -r "$1" "$DEV_STATE_ROOT/events/events.jsonl"
}

@test "open creates the session with the four default windows and emits workspace.opened" {
  setup_dev_test
  dev_open_load_libs
  dev_pin_legacy_default_root
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_tmux list-windows -t '=demo' -F '#{window_name}'
  [ "$status" -eq 0 ]
  [[ "$output" == *agent-1* ]]
  [[ "$output" == *agent-2* ]]
  [[ "$output" == *shell* ]]
  [[ "$output" == *scratch* ]]
  [[ "$output" != *dev-holder* ]]

  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]
  local opened
  opened=$(dev_open_events 'select(.event == "workspace.opened") | .data | [.boot_id, .config_digest, .session_name_actual] | @tsv')
  [[ "$opened" == *"sha256:"* ]]
  [[ "$opened" == *demo* ]]
  [ -n "${opened%%	*}" ]

  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH demo" ]
  dev_tmux kill-server || true
}

@test "a second open creates nothing, re-runs nothing, and leaves scratch untouched" {
  setup_dev_test
  dev_open_load_libs
  dev_pin_legacy_default_root
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  dev_tmux send-keys -t '=demo:=scratch' 'MARKER-SCENARIO-2' Enter
  local i
  for i in $(seq 1 50); do
    dev_tmux capture-pane -p -t '=demo:=scratch' | grep -q MARKER-SCENARIO-2 && break
    sleep 0.1
  done

  local before
  before=$(dev_tmux list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  local after
  after=$(dev_tmux list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')
  [ "$before" = "$after" ]

  run dev_tmux capture-pane -p -t '=demo:=scratch'
  [ "$status" -eq 0 ]
  [[ "$output" == *MARKER-SCENARIO-2* ]]

  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]
  dev_tmux kill-server || true
}

@test "open --no-attach does the work, prints the session name, and never attaches" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$output" = "demo" ]
  [ ! -e "$TEST_ROOT/attached" ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -eq 0 ]
  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]

  run dev_cmd_open --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-attach"* ]]
  dev_tmux kill-server || true
}

@test "open exits 7 when the operation lock is already held" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  flock -x "$DEV_STATE_ROOT/locks/$ws_id.op" sleep 5 &
  local holder=$!
  # Wait until the background flock genuinely owns the lock.
  local i
  for i in $(seq 1 50); do
    flock -n "$DEV_STATE_ROOT/locks/$ws_id.op" true || break
    sleep 0.1
  done

  run dev_cmd_open demo
  [ "$status" -eq 7 ]
  [[ "$output" == *"another dev is working on this workspace"* ]]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  dev_tmux kill-server || true
}

# The common bootstrap for "plain re-open respawns a dead pane" scenarios:
# stage a demo fixture with sourced libs, a stubbed attach, and a long-lived
# stand-in for the "claude" binary the default config's agent-1/agent-2
# windows run (not on PATH here). As tests/dev_backend_tmux.bats:29-37
# documents, a command that exits races dev_backend_apply_layout setting
# remain-on-exit -- the window can vanish before the very next tmux call
# touches it, so the stub must stay alive rather than just exit 0.
scenario_setup_demo_workspace() {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null
  stub_command claude 'exec sleep 30'
}

@test "open after a container loss emits container.replaced then container.ready and respawns dead panes" {
  scenario_setup_demo_workspace
  dev_pin_legacy_default_root
  local dir ws_id
  dir="$DEV_REPO_ROOT/demo"
  mkdir -p "$dir/.devcontainer"
  printf '{"image":"alpine:3"}\n' >"$dir/.devcontainer/devcontainer.json"

  # remoteWorkspaceFolder is host-real (the fixture worktree), not the usual
  # "/workspace" container-only path: the `exec` branch below genuinely execs
  # its trailing command on this host (there is no real container), and that
  # command `cd`s into container.workdir before running the agent. A
  # container-only path can't exist here, so the exec-forwarding fix needs a
  # directory that actually does.
  stub_command devcontainer '
case "$1" in
  --version) echo 0.86.1; exit 0 ;;
  exec) shift; while [ "${1#-}" != "$1" ]; do shift 2; done; exec "$@" ;;
  *) echo "{\"outcome\":\"success\",\"containerId\":\"newcid\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"'"$dir"'\"}" ;;
esac
'
  stub_command mise 'shift 2; shift; exec "$@"'
  stub_command docker '
case "$1" in
  info) exit 0 ;;
  inspect)
    for a in "$@"; do
      if [ "$a" = "oldcid" ]; then exit 1; fi
    done
    echo true; exit 0 ;;
  exec) shift; while [ "${1#-}" != "$1" ]; do shift 2; done; shift; exec "$@" ;;
  *) exit 0 ;;
esac
'

  # Seed a record bound to a container that no longer exists.
  local session record
  session=demo
  record=$(dev_state_new "$(dev_resolve_workspace_id "$dir")" demo demo "$dir")
  record=$(jq --arg wd "$dir" '.status = "running"
    | .container.status = "ready"
    | .container.id = "oldcid"
    | .container.kind = "single"
    | .container.user = "vscode"
    | .container.workdir = $wd' <<<"$record")
  ws_id=$(dev_resolve_workspace_id "$dir")
  printf '%s\n' "$record" >"$(dev_state_path "$ws_id")"

  # A live session with one dead pane.
  dev_backend_create "$session" "$ws_id" demo "$dir"
  dev_backend_apply_layout "$session" "$(dev_config_merged demo "$dir")" "$record"
  dev_tmux set-window-option -t '=demo:=shell' remain-on-exit on
  dev_tmux respawn-pane -k -t '=demo:=shell' 'exit 3'
  local i
  for i in $(seq 1 50); do
    [[ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" == "1" ]] && break
    sleep 0.1
  done
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "1" ]

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  local order
  order=$(dev_open_events 'select(.event == "container.replaced" or .event == "container.ready") | .event' | tr '\n' ' ')
  [ "$order" = "container.replaced container.ready " ]

  [ "$(dev_open_events 'select(.event == "container.replaced") | .data.old_id')" = "oldcid" ]
  [ "$(dev_open_events 'select(.event == "container.replaced") | .data.new_id')" = "newcid" ]
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .data.window')" = "shell" ]
  # Exactly one event for one respawn: `dev_backend_respawn_pane` is the sole
  # emitter and `dev_open_respawn_dead` must not emit a second. A double event
  # folds twice and reports every recovery as two restarts.
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .id' | wc -l)" = "1" ]
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .data.container_id')" = "newcid" ]
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "0" ]
  dev_tmux kill-server || true
}

@test "plain re-open respawns a dead pane in a host-only workspace (no container loss required)" {
  scenario_setup_demo_workspace
  dev_pin_legacy_default_root

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]

  dev_tmux respawn-pane -k -t '=demo:=shell' 'exit 3'
  local i
  for i in $(seq 1 50); do
    [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "1" ] && break
    sleep 0.1
  done

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "0" ]
  grep -q '"event":"pane.respawned"' "$DEV_STATE_ROOT/events/events.jsonl"
  dev_tmux kill-server || true
}

@test "re-open respawns one dead agent pane of two and leaves the other agent untouched" {
  scenario_setup_demo_workspace
  dev_pin_legacy_default_root
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
  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]

  local victim
  victim=$(dev_tmux list-panes -t '=demo:=dash' -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' |
    awk '$2 == "agent-2" {print $1; exit}')
  dev_tmux respawn-pane -k -t "$victim" 'exit 1'
  local i
  for i in $(seq 1 50); do
    [ "$(dev_tmux display-message -p -t "$victim" '#{pane_dead}')" = "1" ] && break
    sleep 0.1
  done

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$(dev_tmux display-message -p -t "$victim" '#{pane_dead}')" = "0" ]

  local record
  record=$(cat "$DEV_STATE_ROOT"/workspaces/*.json)
  [ "$(jq -r '.agents[] | select(.pane == "agent-2") | .state' <<<"$record")" = "started" ]
  # agent-1 never died: exactly one lifecycle event for it, the start
  [ "$(jq -r '.agents[] | select(.pane == "agent-1") | .state' <<<"$record")" = "started" ]
  [ "$(grep -c '"pane":"agent-1"' "$DEV_STATE_ROOT/events/events.jsonl")" -eq 2 ] # pane.created + agent.started only
  dev_tmux kill-server || true
}

@test "a respawned window comes back as the window it was, not as a bare shell" {
  # The respawn path used to re-derive `.command` itself, which meant an agent
  # window came back running $SHELL in the worktree with no environment -- the
  # pane was alive and silently not what the config declared. It now goes through
  # dev_window_inner_command, the same function creation uses. Asserted by
  # running the produced string rather than by matching its text: the string is
  # `sh -c <quoted inner>`, so a substring match would be testing the quoting
  # rather than the behaviour.
  setup_dev_test
  dev_open_load_libs
  local dir ws_id record wjson env_json cmd
  dir=$(dev_open_fixture demo)
  mkdir -p "$dir/sub dir"
  ws_id=$(dev_resolve_workspace_id "$dir")
  record=$(dev_state_new "$ws_id" demo demo "$dir")

  stub_command my-agent "printf '%s|%s|%s\n' \"\$PWD\" \"\$FOO\" \"\$1\" >'$TEST_ROOT/agent-ran'"

  wjson='{"name":"agent-1","agent":"my-agent --flag","cwd":"sub dir","location":"host"}'
  env_json='{"FOO":"a b"}'
  cmd=$(dev_open_window_command "$record" "$wjson" "$env_json")

  bash -c "$cmd"
  [ "$(cat "$TEST_ROOT/agent-ran")" = "$dir/sub dir|a b|--flag" ]
}

@test "attach on an absent session exits 4 and creates nothing" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_attach demo
  [ "$status" -eq 4 ]
  [[ "$output" == *"no live session"* ]]
  [ ! -e "$TEST_ROOT/attached" ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]
  dev_tmux kill-server || true
}

@test "the attach guard picks the hashed name when an existing session holds a different worktree" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir other ws_id
  dir=$(dev_open_fixture demo)
  other=$(dev_open_fixture impostor)

  # A squatter session already owns the name "demo" but points elsewhere.
  dev_backend_create demo "$(dev_resolve_workspace_id "$other")" demo "$other"

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  ws_id=$(dev_resolve_workspace_id "$dir")
  local expected="demo--$(basename "$dir")--${ws_id:0:6}"
  run dev_tmux has-session -t "=$expected"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH $expected" ]
  [ "$(dev_open_events 'select(.event == "workspace.opened") | .data.session_name_actual')" = "$expected" ]
  [ "$(dev_tmux show-options -t "=$expected:" -qv @dev_worktree)" = "$dir" ]
  dev_tmux kill-server || true
}

@test "a collision-hashed name survives the conflicting session going away" {
  # The durability half of ADR-7's guard, and the regression this pins: every
  # later command used to re-derive the resolver's PROPOSAL rather than read the
  # record. Once the squatter left, `dev attach demo` looked up the plain name,
  # found nothing, and reported no live session -- while the hashed session was
  # still running with the user's work in it. `dev demo` would then have built a
  # second session for the same working tree.
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir other ws_id expected
  dir=$(dev_open_fixture demo)
  other=$(dev_open_fixture impostor)

  dev_backend_create demo "$(dev_resolve_workspace_id "$other")" demo "$other"
  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]

  ws_id=$(dev_resolve_workspace_id "$dir")
  expected="demo--$(basename "$dir")--${ws_id:0:6}"
  [ "$(jq -r '.session_name' "$(dev_state_path "$ws_id")")" = "$expected" ]

  # The squatter leaves. The plain name is now free.
  dev_tmux kill-session -t '=demo'
  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]

  # attach must still find the hashed session.
  rm -f "$TEST_ROOT/attached"
  run dev_cmd_attach demo
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH $expected" ]

  # open must reuse it rather than create a second session on the free name.
  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]
  [ "$(dev_tmux list-sessions -F '#{session_name}' | wc -l)" = "1" ]

  # And reconcile never called it vanished: it queried the recorded name.
  [ "$(jq -r '.status' "$(dev_state_path "$ws_id")")" = "running" ]
  [ -z "$(dev_open_events 'select(.event == "workspace.vanished") | .id')" ]
  dev_tmux kill-server || true
}

@test "the real dispatcher resolves dev_open_attach when attaching to a live session" {
  # bin/dev sources exactly one command file per verb (dev_commands.bats:66-79),
  # so a real `dev attach` never gets open.sh's functions for free the way
  # dev_open_load_libs does. Only invoking the staged dispatcher end to end --
  # not dev_cmd_attach in-process -- can catch attach.sh calling a function
  # open.sh defines.
  setup_dev_test
  stage_dev_root
  make_fixture_repo "proj"
  dev_open_load_libs
  local dir ws_id session record
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")
  session=demo
  record=$(dev_state_new "$ws_id" demo demo "$dir")
  printf '%s\n' "$record" >"$(dev_state_path "$ws_id")"
  dev_backend_create "$session" "$ws_id" demo "$dir"
  dev_open_session_index_write "$ws_id" demo "$session" "$dir"

  run "$TEST_ROOT/root/bin/dev" attach demo
  # A missing source of dev_open_attach dies at "dev_open_attach: command not
  # found" (exit 127) even though the session above is alive and attachable.
  # Getting past that into tmux's own "not a terminal" attach failure (there is
  # no tty under `run`) proves dev_open_attach was resolved and its exec ran.
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"not a terminal"* ]]

  dev_tmux kill-server || true
}

@test "stop ends the session and the next dev list reports stopped/user" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]

  [ "$(dev_open_events 'select(.event == "workspace.stopped") | .data.reason')" = "user" ]

  # stop reconciles after the kill, so the record itself reads stopped without
  # waiting for the next command to project it.
  [ "$(jq -r '.status' "$(dev_state_path "$ws_id")")" = "stopped" ]

  run dev_cmd_list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .status' <<<"$output")" = "stopped" ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .stopped_reason' <<<"$output")" = "user" ]
  dev_tmux kill-server || true
}

@test "a kill that fails does not record the workspace as stopped" {
  # The ordering regression: emitting workspace.stopped before the kill left a
  # live session recorded as stopped, and reconcile treats stopped as terminal,
  # so nothing ever corrected it.
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  dev_backend_kill() { return 1; }

  run dev_cmd_stop demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"still running"* ]]

  # No event, so nothing to fold into a false stopped.
  [ -z "$(dev_open_events 'select(.event == "workspace.stopped") | .id')" ]

  # The session index is back, so the hook is still armed for the eventual close.
  [ -s "$(dev_open_session_index_path demo)" ]

  unset -f dev_backend_kill
  run dev_cmd_list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .status' <<<"$output")" = "running" ]
  dev_tmux kill-server || true
}

@test "stop without --container leaves the container alone; --container stops it" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id record
  dir=$(dev_open_fixture demo)
  mkdir -p "$dir/.devcontainer"
  printf '{"image":"alpine:3"}\n' >"$dir/.devcontainer/devcontainer.json"

  stub_command devcontainer '
case "$1" in
  --version) echo 0.86.1; exit 0 ;;
  exec) shift; while [ "${1#-}" != "$1" ]; do shift 2; done; exec "$@" ;;
  *) echo "{\"outcome\":\"success\",\"containerId\":\"cid1\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"'"$dir"'\"}" ;;
esac
'
  stub_command mise 'shift 2; shift; exec "$@"'
  stub_command claude 'exec sleep 30'
  stub_command docker '
if [ "$1" = "stop" ]; then echo "$2" >>"$TEST_ROOT/docker-stop"; exit 0; fi
if [ "$1" = "info" ]; then exit 0; fi
if [ "$1" = "inspect" ]; then echo true; exit 0; fi
if [ "$1" = "exec" ]; then shift; while [ "${1#-}" != "$1" ]; do shift 2; done; shift; exec "$@"; fi
exit 0
'

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/docker-stop" ]

  run dev_cmd_open demo
  [ "$status" -eq 0 ]
  run dev_cmd_stop demo --container
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/docker-stop")" = "cid1" ]
  dev_tmux kill-server || true
}

@test "stop exits 7 while the operation lock is held" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  flock -x "$DEV_STATE_ROOT/locks/$ws_id.op" sleep 5 &
  local holder=$!
  # Wait until the background flock genuinely owns the lock.
  local i
  for i in $(seq 1 50); do
    flock -n "$DEV_STATE_ROOT/locks/$ws_id.op" true || break
    sleep 0.1
  done

  run dev_cmd_stop demo
  [ "$status" -eq 7 ]
  [[ "$output" == *"another dev is working on this workspace"* ]]
  run dev_tmux has-session -t '=demo'
  [ "$status" -eq 0 ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  dev_tmux kill-server || true
}

@test "stop on an already-stopped workspace is a no-op exiting 0" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]
  run dev_cmd_stop demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already stopped"* ]]
  [ "$(dev_open_events 'select(.event == "workspace.stopped") | .id' | wc -l)" -eq 1 ]
  dev_tmux kill-server || true
}

@test "the real dispatcher resolves dev_open_session_index_path when stopping a live session" {
  # bin/dev sources exactly one command file per verb (bin/dev:74-79), so a
  # real `dev stop` never gets open.sh's functions for free the way
  # dev_open_load_libs does. Only invoking the staged dispatcher end to end --
  # not dev_cmd_stop in-process -- can catch stop.sh calling a function
  # open.sh defines.
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run "$TEST_ROOT/root/bin/dev" stop demo
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
  [ ! -e "$(dev_open_session_index_path demo)" ]

  dev_tmux kill-server || true
}

@test "status reports undeclared windows and undeclared panes as drift" {
  scenario_setup_demo_workspace
  dev_pin_legacy_default_root

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]

  dev_tmux new-window -d -t '=demo:' -n rogue "sleep 30"
  dev_tmux split-window -d -t '=demo:=shell' "sleep 30"

  run dev_cmd_status demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift:"*"rogue"* ]]
  [[ "$output" == *"drift:"*"shell"*"undeclared pane"* ]]

  dev_tmux kill-server || true
}

@test "shipped default opens as a one-window tiled dashboard with four stamped panes" {
  # Unlike the scenarios above, this one deliberately does NOT pin the legacy
  # layout: it exercises the real shipped tools/dev/default-workspace.yaml
  # (scenario_setup_demo_workspace already stubs claude to stay alive).
  scenario_setup_demo_workspace

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  run dev_tmux list-windows -t '=demo' -F '#{window_name}'
  [ "$output" = "main" ]
  run dev_tmux list-panes -t '=demo:=main' -F '#{?#{@dev_pane},#{@dev_pane},-}'
  [ "$(printf '%s\n' "$output" | sort | tr '\n' ',')" = "agent-1,agent-2,scratch,shell," ]

  record=$(cat "$DEV_STATE_ROOT"/workspaces/*.json)
  [ "$(jq -r '[.agents[] | select(.window == "main")] | length' <<<"$record")" -eq 2 ]
  [ "$(jq -r '[.agents[].pane] | sort | join(",")' <<<"$record")" = "agent-1,agent-2" ]
  dev_tmux kill-server || true
}
