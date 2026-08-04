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
  cp "$REPO_ROOT/tools/dev/default-workspace.yaml" "$TEST_ROOT/root/tools/dev/default-workspace.yaml"
  export DEV_DOTFILES_ROOT="$TEST_ROOT/root"
}

stub_open_command() {
  cat > "$TEST_ROOT/root/tools/dev/commands/open.sh" <<'EOF'
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
  printf '%s' "$output" | jq -e . > /dev/null
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
  cat > "$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
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
  printf '%s' "$output" | jq -e . > /dev/null
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
    }' > "$DEV_STATE_ROOT/workspaces/${id}.json"
}

@test "dev list --json emits v:1 and every workspace, and parses as JSON" {
  make_fixture_repo "alpha"
  make_fixture_repo "beta"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:x" false
  write_record "$(printf 'b%.0s' {1..64})" beta beta "$DEV_REPO_ROOT/beta" stopped none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . > /dev/null
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
