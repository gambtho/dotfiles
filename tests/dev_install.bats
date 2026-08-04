#!/usr/bin/env bats

load test_helper

teardown() {
  if [[ -n "${DEV_TMUX_SOCKET:-}" ]]; then
    tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
}

@test "dev-event with an empty workspace_id writes nothing and exits 0" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" "" slug sess /tmp/tree workspace.stopped reason=user
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}

@test "dev-event appends exactly one line carrying the whole envelope" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid1 myslug mysess /home/t/tree \
    workspace.attached client=/dev/pts/3
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]

  local line
  line=$(cat "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r '.v' <<<"$line")" = "1" ]
  [ "$(jq -r '.id' <<<"$line" | wc -c)" -eq 17 ]
  [ "$(jq -r '.ts' <<<"$line")" != "null" ]
  [ "$(jq -r '.event' <<<"$line")" = "workspace.attached" ]
  [ "$(jq -r '.workspace_id' <<<"$line")" = "wsid1" ]
  [ "$(jq -r '.slug' <<<"$line")" = "myslug" ]
  [ "$(jq -r '.session_name' <<<"$line")" = "mysess" ]
  [ "$(jq -r '.worktree' <<<"$line")" = "/home/t/tree" ]
  [ "$(jq -r '.data.client' <<<"$line")" = "/dev/pts/3" ]
}

@test "dev-event emits {} when no key=value pairs are given" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid1 slug sess /tmp/tree workspace.detached
  [ "$status" -eq 0 ]
  [ "$(jq -c '.data' "$DEV_STATE_ROOT/events/events.jsonl")" = "{}" ]
}

@test "dev-event keeps a worktree path containing a space as one field" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid2 slug sess "/home/t/my tree" pane.died window=shell
  [ "$status" -eq 0 ]
  [ "$(jq -r '.worktree' "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/my tree" ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = "shell" ]
}

@test "dev-event escapes quotes and backslashes in a value instead of corrupting the line" {
  # The regression this pins: the hooks used to interpolate tmux formats into a
  # JSON literal, so a value containing " or \ produced a line that would not
  # parse -- and dev_events_read_all silently skips unparseable lines, so the
  # event vanished with no error anywhere. jq --arg escapes by construction.
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid4 slug sess /tmp/tree pane.died \
    'window=od"d\name'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
  run jq -e . "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = 'od"d\name' ]
}

@test "dev-event keeps the whole remainder of a pair, equals signs and all" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid5 slug sess /tmp/tree pane.died \
    'window=a=b=c'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = "a=b=c" ]
}

@test "dev-event rejects an argument that is not a key=value pair" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid6 slug sess /tmp/tree pane.died notapair
  [ "$status" -eq 2 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}

@test "dev-event --session resolves the envelope from the session index" {
  setup_dev_test
  mkdir -p "$DEV_STATE_ROOT/sessions"
  jq -n '{workspace_id:"wsid3", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspace_id' "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid3" ]
  [ "$(jq -r '.slug' "$DEV_STATE_ROOT/events/events.jsonl")" = "demo" ]
  [ "$(jq -r '.worktree' "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/demo" ]
  [ "$(jq -r '.data.reason' "$DEV_STATE_ROOT/events/events.jsonl")" = "session_closed" ]
}

@test "dev-event --session removes the index it just consumed" {
  # The session is gone, so the index is stale from this moment on -- and names
  # are reused, so a leftover index would answer for the NEXT incarnation of
  # `demo`. Deleting after the append keeps a crash in between on the safe side:
  # a stale index rather than a lost event.
  setup_dev_test
  mkdir -p "$DEV_STATE_ROOT/sessions"
  jq -n '{workspace_id:"wsid7", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ ! -e "$DEV_STATE_ROOT/sessions/demo.json" ]

  # A second close on the same name is now a no-op rather than a duplicate event.
  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
}

@test "dev-event --session on an unknown session writes nothing and exits 0" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" --session adhoc workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}

dev_hook_env() {
  # dev.tmux.conf reaches dev-event through ~/.dotfiles, and the tmux server
  # inherits DEV_STATE_ROOT from the shell that starts it.
  ln -sfn "$REPO_ROOT" "$HOME/.dotfiles"
  mkdir -p "$DEV_STATE_ROOT/sessions"
}

# Hooks run via `run-shell -b`, so the event lands asynchronously. Poll for it
# (bounded, ~5s) instead of a fixed sleep: the fixed-sleep form flaked under
# full-suite load and once wedged `make check` via a leaked server.
dev_wait_for_event() {
  local event="$1" i
  for i in $(seq 1 50); do
    if jq -e -s --arg e "$event" 'any(.[]; .event == $e)' \
      "$DEV_STATE_ROOT/events/events.jsonl" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

@test "session-closed emits workspace.stopped through the session index" {
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  jq -n '{workspace_id:"wsid9", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  # A holder session keeps the server alive after `demo` is killed: killing the
  # last session on a server tears the server down before the session-closed
  # hook's backgrounded run-shell can complete, so no event is ever written.
  # Verified on this machine's tmux 3.4 (task-16-report.md).
  dev_tmux new-session -d -s holder
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"
  dev_tmux new-session -d -s demo
  dev_tmux kill-session -t '=demo'
  dev_wait_for_event workspace.stopped

  [ "$(jq -r 'select(.event == "workspace.stopped") | .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid9" ]
  [ "$(jq -r 'select(.event == "workspace.stopped") | .session_name' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "demo" ]
  # Not "user": `dev stop` removes the index before killing, so a close this hook
  # observes is by construction one the platform did not perform.
  [ "$(jq -r 'select(.event == "workspace.stopped") | .data.reason' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "session_closed" ]
  [ ! -e "$DEV_STATE_ROOT/sessions/demo.json" ]
  dev_tmux kill-server || true
}

@test "a window name with a double quote still produces a parseable pane.died" {
  # End-to-end for the escaping fix: tmux interpolates the raw name into the
  # argument, and dev-event -- not the tmux config -- turns it into JSON.
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  dev_tmux new-session -d -s holder
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"

  dev_tmux new-session -d -s quoted
  dev_tmux set-option -t '=quoted:' @dev_workspace_id wsidq
  dev_tmux set-option -t '=quoted:' @dev_slug quoted
  dev_tmux set-option -t '=quoted:' @dev_worktree /home/t/quoted

  # Task 4 constrains names the platform CREATES; tmux itself does not, and a
  # hand-renamed window must not be able to corrupt the log.
  dev_tmux new-window -t '=quoted' -n 'we"ird' 'sleep 0.4; exit 3'
  dev_tmux set-window-option -t '=quoted:' remain-on-exit on
  dev_wait_for_event pane.died

  run jq -e . "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event == "pane.died") | .data.window' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = 'we"ird' ]
  dev_tmux kill-server || true
}

@test "pane-died emits pane.died with the envelope from the session user options" {
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  dev_tmux new-session -d -s holder
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"

  # pane-died is window-scoped: absent from -g, present under -gw.
  run dev_tmux show-hooks -g
  [[ "$output" != *pane-died* ]]
  run dev_tmux show-hooks -gw
  [[ "$output" == *pane-died* ]]

  dev_tmux new-session -d -s demo
  dev_tmux set-option -t '=demo:' @dev_workspace_id wsid8
  dev_tmux set-option -t '=demo:' @dev_slug demo
  dev_tmux set-option -t '=demo:' @dev_worktree '/home/t/my demo'

  # The spec warns that an immediate `exit 3` races remain-on-exit being set.
  dev_tmux new-window -t '=demo' -n shell 'sleep 0.4; exit 3'
  dev_tmux set-window-option -t '=demo:=shell' remain-on-exit on
  dev_wait_for_event pane.died

  [ "$(jq -r 'select(.event == "pane.died") | .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid8" ]
  [ "$(jq -r 'select(.event == "pane.died") | .worktree' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/my demo" ]
  [ "$(jq -r 'select(.event == "pane.died") | .data.window' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "shell" ]
  dev_tmux kill-server || true
}

@test "tmux.conf.symlink sources dev.tmux.conf between idempotency markers" {
  setup_dotfiles_test
  run grep -c '# dev-workspace-config-start' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
  run grep -c '# dev-workspace-config-end' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
  run grep -c 'tools/dev/dev.tmux.conf' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
}

@test "install.sh writes the autostart unit with DOTFILES_ROOT substituted" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]

  local unit="$XDG_CONFIG_HOME/systemd/user/dev-autostart.service"
  [ -f "$unit" ]
  run grep -c "@DOTFILES_ROOT@" "$unit"
  [ "$status" -ne 0 ]
  grep -qF "ExecStart=$REPO_ROOT/tools/dev/dev-autostart" "$unit"
  grep -q "^Type=oneshot$" "$unit"
  grep -q "^WantedBy=default.target$" "$unit"
  grep -q "^Environment=PATH=" "$unit"
  grep -q "^ExecStartPre=" "$unit"
}

@test "install.sh creates the state directories" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1
  export DEV_STATE_ROOT="$TEST_ROOT/fresh-state"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  [ -d "$DEV_STATE_ROOT/workspaces" ]
  [ -d "$DEV_STATE_ROOT/events" ]
  [ -d "$DEV_STATE_ROOT/locks" ]
  [ -d "$DEV_STATE_ROOT/sessions" ]
}

@test "install.sh is idempotent" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  local unit="$XDG_CONFIG_HOME/systemd/user/dev-autostart.service"
  cp "$unit" "$TEST_ROOT/unit.first"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/unit.first" "$unit"
  # No stray staging files left behind.
  run bash -c "ls -A '$XDG_CONFIG_HOME/systemd/user' | grep -c '^\\.'"
  [ "$output" = "0" ]
}

@test "install.sh verifies the committed tmux marker block" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  grep -qF "# dev-workspace-config-start" "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  grep -qF "# dev-workspace-config-end" "$REPO_ROOT/tools/tmux/tmux.conf.symlink"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tmux marker block"* ]]
}

@test "workspace.local.yaml is gitignored" {
  run git -C "$REPO_ROOT" check-ignore projects/x/workspace.local.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "projects/x/workspace.local.yaml" ]
}

# Creates a git repo under DEV_REPO_ROOT, an overlay workspace.yaml, and a
# workspace record. Echoes the workspace_id.
dev_autostart_fixture() {
  local slug="$1" autostart="$2"
  local worktree="$DEV_REPO_ROOT/$slug"
  mkdir -p "$worktree/.devcontainer"
  printf '%s\n' '{"image":"alpine"}' >"$worktree/.devcontainer/devcontainer.json"
  git -C "$worktree" init -q
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  mkdir -p "$DEV_OVERLAY_ROOT/$slug"
  printf 'autostart: %s\n' "$autostart" >"$DEV_OVERLAY_ROOT/$slug/workspace.yaml"

  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  local id
  id=$(dev_resolve_workspace_id "$worktree")
  dev_state_new "$id" "$slug" "$slug" "$worktree" >"$DEV_STATE_ROOT/workspaces/$id.json"
  printf '%s\n' "$id"
}

# Stubs docker/mise/devcontainer so `devcontainer up` appends one line to
# $DEV_UP_MARKER and reports a plausible container.
dev_autostart_stubs() {
  export DEV_UP_MARKER="$TEST_ROOT/up.log"
  : >"$DEV_UP_MARKER"
  stub_command docker 'exit 0'
  stub_command mise 'if [[ "${1:-}" == "exec" ]]; then
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  exec "$@"
fi
exit 0'
  stub_command devcontainer 'case "${1:-}" in
  --version)
    echo "0.86.1"
    ;;
  up)
    printf "up\n" >>"$DEV_UP_MARKER"
    printf "%s\n" "{\"outcome\":\"success\",\"containerId\":\"cid-abc\",\"remoteUser\":\"node\",\"remoteWorkspaceFolder\":\"/workspaces/app\"}"
    ;;
  *)
    exit 0
    ;;
esac'
}

@test "dev-autostart runs devcontainer up exactly once for an eligible workspace" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  run wc -l <"$DEV_UP_MARKER"
  [ "$(tr -d ' ' <<<"$output")" = "1" ]
}

@test "dev-autostart skips a workspace without autostart" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app false >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
}

@test "dev-autostart skips a linked worktree" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null
  rm -f "$DEV_STATE_ROOT"/workspaces/*.json

  local linked="$DEV_REPO_ROOT/app-pr5"
  git -C "$DEV_REPO_ROOT/app" worktree add -q -b pr5 "$linked"
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  local id
  id=$(dev_resolve_workspace_id "$linked")
  dev_state_new "$id" app "app--app-pr5" "$linked" >"$DEV_STATE_ROOT/workspaces/$id.json"

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"linked worktree"* ]]
}

@test "dev-autostart skips a record whose worktree is gone" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null
  rm -rf "$DEV_REPO_ROOT/app"

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"worktree is gone"* ]]
}

@test "dev-autostart skips a workspace whose operation lock is held" {
  setup_dev_test
  dev_autostart_stubs
  local id
  id=$(dev_autostart_fixture app true)

  local op_lock="$DEV_STATE_ROOT/locks/$id.op"
  : >"$op_lock"
  flock "$op_lock" sleep 30 &
  local holder=$!
  # Wait until the background flock genuinely owns the lock.
  local i
  for i in $(seq 1 50); do
    flock -n "$op_lock" true || break
    sleep 0.1
  done

  run "$REPO_ROOT/tools/dev/dev-autostart"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"operation lock held"* ]]
}

@test "dev-autostart creates no tmux session" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ -s "$DEV_UP_MARKER" ]

  # The real test socket must have no server at all: autostart starts containers,
  # not sessions (ADR-5).
  run tmux -L "$DEV_TMUX_SOCKET" list-sessions
  [ "$status" -ne 0 ]
}
