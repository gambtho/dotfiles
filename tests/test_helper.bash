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
