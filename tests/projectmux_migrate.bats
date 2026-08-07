#!/usr/bin/env bats
# Migration off the Bash dev platform (design §13 step 8).
#
# The subject is the *installed* state the deleted sources left behind, so
# every test drives a real tmux server on a private socket. Fixture servers are
# started with `-f /dev/null`: the user's own tmux.conf still sources the
# managed hooks on this machine, and a server that inherits them cannot tell
# "the migration left this" from "the config set it again".

load test_helper

setup() {
  setup_dotfiles_test
  export PATH="$STUB_BIN:/usr/bin:/bin"
  export DEV_SKIP_SERVICE=1
  # The script derives the unit path from XDG_CONFIG_HOME, which the helper
  # does not sandbox. An inherited value would aim these tests at the real
  # ~/.config/systemd/user.
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_STATE_ROOT="$TEST_ROOT/state/dev"
  export MIGRATE_BACKUP_SUFFIX="20260807"
  export PROJECTMUX_TMUX_SOCKET="pmxmigrate-$$-$BATS_TEST_NUMBER"
  MIGRATE="$REPO_ROOT/tools/projectmux/migrate-from-dev.sh"
}

teardown() {
  tmux -L "$PROJECTMUX_TMUX_SOCKET" kill-server 2>/dev/null || true
}

start_server() {
  tmux -L "$PROJECTMUX_TMUX_SOCKET" -f /dev/null new-session -d -s fixture
}

managed_hook() {
  printf 'run-shell -b "%s/tools/dev/dev-event %s"' "$HOME/.dotfiles" "$1"
}

@test "migrate unsets global hooks still carrying the managed dev-event command" {
  start_server
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -g client-attached "$(managed_hook workspace.attached)"
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -g session-closed "$(managed_hook workspace.stopped)"

  run "$MIGRATE"
  [ "$status" -eq 0 ]

  run tmux -L "$PROJECTMUX_TMUX_SOCKET" show-hooks -g
  [[ "$output" != *dev-event* ]]
}

# pane-died is registered with -gw, so it is absent from `show-hooks -g` and
# from `show-hooks -w -t <window>`. A migration that only walked -g would leave
# it set permanently.
@test "migrate unsets the global-window pane-died hook" {
  start_server
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -gw pane-died "$(managed_hook pane.died)"

  run "$MIGRATE"
  [ "$status" -eq 0 ]

  run tmux -L "$PROJECTMUX_TMUX_SOCKET" show-hooks -gw
  [[ "$output" != *dev-event* ]]
}

@test "migrate preserves a hook the user replaced, and warns" {
  start_server
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -g client-attached "run-shell 'echo mine'"

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preserving client-attached[0]"* ]]

  run tmux -L "$PROJECTMUX_TMUX_SOCKET" show-hooks -g
  [[ "$output" == *"echo mine"* ]]
}

# The user appended a handler beside the managed one. Unsetting by hook NAME
# would take both; unsetting by array INDEX takes only ours.
@test "migrate removes only the managed entry when a hook carries both" {
  start_server
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -ga client-attached "run-shell 'echo mine'"
  tmux -L "$PROJECTMUX_TMUX_SOCKET" set-hook -ga client-attached "$(managed_hook workspace.attached)"

  run "$MIGRATE"
  [ "$status" -eq 0 ]

  run tmux -L "$PROJECTMUX_TMUX_SOCKET" show-hooks -g
  [[ "$output" == *"echo mine"* ]]
  [[ "$output" != *dev-event* ]]
}

@test "migrate is not an error when the hooks are already absent" {
  start_server

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" != *Preserving* ]]
}

@test "migrate succeeds with no tmux server running" {
  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tmux server running"* ]]
}

@test "migrate backs the state directory up once and is a no-op on rerun" {
  mkdir -p "$DEV_STATE_ROOT/workspaces"
  printf 'marker\n' >"$DEV_STATE_ROOT/workspaces/keep"

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  assert_file_absent "$DEV_STATE_ROOT"
  [ -f "$DEV_STATE_ROOT.bak-20260807/workspaces/keep" ]

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [ -f "$DEV_STATE_ROOT.bak-20260807/workspaces/keep" ]
}

# A rerun after the directory was recreated must not clobber the backup that
# the validation window depends on.
@test "migrate preserves an existing backup rather than overwriting it" {
  mkdir -p "$DEV_STATE_ROOT.bak-20260807"
  printf 'original\n' >"$DEV_STATE_ROOT.bak-20260807/first"
  mkdir -p "$DEV_STATE_ROOT"
  printf 'second\n' >"$DEV_STATE_ROOT/later"

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ -f "$DEV_STATE_ROOT.bak-20260807/first" ]
  [ -d "$DEV_STATE_ROOT" ]
}

@test "migrate skips systemd when no user manager is available" {
  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No systemd user manager available"* ]]
}

@test "an installed legacy unit is preserved, with a warning, when systemd is unreachable" {
  # Removing the unit file without being able to disable it would strand the
  # default.target.wants/ symlink pointing at a unit that no longer exists,
  # failing on every login. Preserving both keeps the pair consistent and the
  # script re-runnable -- but the run is incomplete, so it must say so.
  mkdir -p "$XDG_CONFIG_HOME/systemd/user"
  local unit="$XDG_CONFIG_HOME/systemd/user/dev-autostart.service"
  printf 'installed\n' >"$unit"

  run "$MIGRATE"
  [ "$status" -eq 0 ]
  [ -f "$unit" ]
  [[ "$output" == *"left in place"* ]]
  [[ "$output" == *"Re-run"* ]]
}
