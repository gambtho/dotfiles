#!/usr/bin/env bats

load test_helper

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
  sleep 0.8

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
  sleep 1.2

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
  sleep 1.2

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
