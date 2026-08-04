#!/usr/bin/env bats

load test_helper

# Stubs docker and the devcontainer CLI. Container identity is read from
# $TEST_ROOT/container.id at call time, so a test can replace the container by
# writing a new id; an empty file means "no such container is running", which is
# how container loss is simulated.
lifecycle_stubs() {
  printf 'cid-one\n' >"$TEST_ROOT/container.id"
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
    cid=$(cat "$TEST_ROOT/container.id")
    printf "%s\n" "{\"outcome\":\"success\",\"containerId\":\"$cid\",\"remoteUser\":\"node\",\"remoteWorkspaceFolder\":\"/workspaces/app\"}"
    ;;
  exec)
    shift
    exit 0
    ;;
  *)
    exit 0
    ;;
esac'
  stub_command docker 'cid=$(cat "$TEST_ROOT/container.id")
case "${1:-}" in
  info)
    exit 0
    ;;
  inspect)
    want="${*: -1}"
    if [[ -n "$cid" && "$want" == "$cid" ]]; then
      printf "true\n"
      exit 0
    fi
    printf "Error: No such object: %s\n" "$want" >&2
    exit 1
    ;;
  exec)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac'
}

lifecycle_repo() {
  local worktree="$DEV_REPO_ROOT/app"
  mkdir -p "$worktree/.devcontainer"
  printf '%s\n' '{"image":"alpine"}' >"$worktree/.devcontainer/devcontainer.json"
  git -C "$worktree" init -q
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  mkdir -p "$DEV_OVERLAY_ROOT/app"
  # `agent:` is a command string, not a flag, and a window may set `agent` or
  # `command` but never both -- Task 4's validation exits 5 on that pair. Windows
  # merge by name (Task 4), so these four entries rewrite the shipped default's
  # four windows rather than adding a fifth; without the rewrite `agent-1` and
  # `agent-2` would run the default `claude`, which does not exist here, and
  # their panes would die the moment they were created.
  cat >"$DEV_OVERLAY_ROOT/app/workspace.yaml" <<'YAML'
windows:
  - name: agent-1
    agent: sleep 600
  - name: agent-2
    agent: sleep 600
  - name: shell
    command: sleep 600
  - name: scratch
    command: sleep 600
YAML
  printf '%s\n' "$worktree"
}

# Appends a hook-shaped event directly, the way tools/dev/dev-event does from a
# tmux hook. The record must not be touched here -- reconcile is what projects it.
lifecycle_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$LIFE_ID" app app "$LIFE_WORKTREE" "$data")
  dev_event_append "$line"
}

# Reconcile and return this workspace's entry from the public snapshot. `dev
# status` is prose for a human and has no --json (Task 13); `dev list --json` is
# the snapshot contract, so the observation steps below go through it. Selecting
# by slug rather than session name keeps this working if ADR-7's collision guard
# ever renames the session.
lifecycle_snapshot() {
  "$REPO_ROOT/bin/dev" list --json |
    jq -e --arg slug app '.workspaces[] | select(.slug == $slug)'
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

@test "folding the event log from empty reproduces the reconciled record" {
  setup_dev_test
  lifecycle_stubs

  LIFE_WORKTREE=$(lifecycle_repo)
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  LIFE_ID=$(dev_resolve_workspace_id "$LIFE_WORKTREE")

  # 1. Open: reconcile, container up, session create, layout apply.
  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  tmux -L "$DEV_TMUX_SOCKET" has-session -t "=app"

  # 2. Attach: emitted by tmux's client-attached hook, folds to last_seen only.
  lifecycle_emit workspace.attached '{"client":"/dev/pts/9"}'
  run lifecycle_snapshot
  [ "$status" -eq 0 ]

  # 3. Container loss: the container disappears out from under the record.
  : >"$TEST_ROOT/container.id"
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = "lost" ]

  # 4. Container replace: a different id comes back on the next open.
  printf 'cid-two\n' >"$TEST_ROOT/container.id"
  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.id' <<<"$output")" = "cid-two" ]

  # 5. Agent exit: kill the agent pane's process and let reconcile observe it.
  #    remain-on-exit keeps the pane, so the window survives as dead.
  tmux -L "$DEV_TMUX_SOCKET" respawn-pane -k -t "=app:agent-1" true
  local i
  for i in $(seq 1 50); do
    [[ "$(tmux -L "$DEV_TMUX_SOCKET" display-message -p -t "=app:agent-1" '#{pane_dead}')" == "1" ]] && break
    sleep 0.1
  done
  run lifecycle_snapshot
  [ "$status" -eq 0 ]

  # 6. Stop: the only destructive verb. It reconciles after the kill, so the
  #    record is already projected forward when this returns.
  run "$REPO_ROOT/bin/dev" stop app
  [ "$status" -eq 0 ]

  # The record as the commands left it.
  local record
  record=$(dev_state_read "$LIFE_ID")
  [ -n "$record" ]
  [ "$(jq -r '.status' <<<"$record")" = "stopped" ]
  [ "$(jq -r '.stopped_reason' <<<"$record")" = "user" ]

  # The same state derived only from the event stream, folded in one pass from a
  # fresh record. Restrict to this workspace so the fold sees exactly the events
  # a consumer of this workspace would see.
  local empty folded
  empty=$(dev_state_new "$LIFE_ID" app app "$LIFE_WORKTREE")
  folded=$(dev_events_read_all |
    jq -c --arg id "$LIFE_ID" 'select(.workspace_id == $id)' |
    dev_fold_stream "$empty")
  [ -n "$folded" ]

  # last_seen and container.observed_at are set by reconcile at observation time
  # and scanned_through is the fold cursor; the fold owns every other field.
  local strip='del(.last_seen, .scanned_through, .container.observed_at)'
  diff <(jq -S -c "$strip" <<<"$record") <(jq -S -c "$strip" <<<"$folded")
}

@test "the lifecycle emitted every event type the record depends on" {
  # Guards against the equivalence above passing vacuously: if open/stop stopped
  # emitting events entirely, both sides would fold to the same empty-ish record.
  setup_dev_test
  lifecycle_stubs

  LIFE_WORKTREE=$(lifecycle_repo)
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  LIFE_ID=$(dev_resolve_workspace_id "$LIFE_WORKTREE")

  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  : >"$TEST_ROOT/container.id"
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/bin/dev" stop app
  [ "$status" -eq 0 ]

  local types
  types=$(dev_events_read_all |
    jq -r --arg id "$LIFE_ID" 'select(.workspace_id == $id) | .event' | sort -u)
  local want
  for want in workspace.opened container.starting container.ready container.lost workspace.stopped; do
    grep -qx "$want" <<<"$types" || {
      printf 'missing event type: %s\nsaw:\n%s\n' "$want" "$types" >&2
      return 1
    }
  done
}
