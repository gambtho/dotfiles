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
