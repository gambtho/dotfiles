setup_dotfiles_test() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  export REPO_ROOT
  export TEST_ROOT="$BATS_TEST_TMPDIR/test-root"
  export HOME="$TEST_ROOT/home"
  export STUB_BIN="$TEST_ROOT/bin"
  mkdir -p "$HOME" "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
}

stub_command() {
  local name="$1"
  shift
  cat >"$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$STUB_BIN/$name"
}

assert_file_absent() {
  [ ! -e "$1" ]
}

assert_symlink_target() {
  [ -L "$1" ]
  [ "$(readlink "$1")" = "$2" ]
}

setup_dev_test() {
  setup_dotfiles_test
  # yq lives in /usr/local/bin, which setup_dotfiles_test drops from PATH.
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin"
  export DEV_DOTFILES_ROOT="$REPO_ROOT"
  export DEV_STATE_ROOT="$TEST_ROOT/state"
  export DEV_REPO_ROOT="$TEST_ROOT/workspace"
  export DEV_OVERLAY_ROOT="$TEST_ROOT/overlay"
  export DEV_TMUX_SOCKET="devtest-$$-$BATS_TEST_NUMBER"
  # Point the vekil probe at a directory that does not exist, so tests never
  # see the developer machine's real proxy state (XDG_STATE_HOME can leak in
  # from the invoking environment; HOME scoping alone does not cover it).
  export VEKIL_STATE_DIR="$TEST_ROOT/no-vekil"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" \
    "$DEV_STATE_ROOT/locks" "$DEV_REPO_ROOT" "$DEV_OVERLAY_ROOT"
}
