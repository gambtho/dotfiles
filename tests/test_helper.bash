setup_dotfiles_test() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  export REPO_ROOT
  export TEST_ROOT="$BATS_TEST_TMPDIR/test-root"
  export HOME="$TEST_ROOT/home"
  export STUB_BIN="$TEST_ROOT/bin"
  mkdir -p "$HOME" "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
  # Sanitizing PATH is not enough on a machine where the interactive shell ran
  # `mise activate` (languages/mise/env.zsh). That exports mise's session state,
  # including __MISE_ORIG_PATH -- the real login PATH. Tests that source zshrc
  # re-enter `mise activate`, which sees a live session and restores that PATH
  # *ahead* of $STUB_BIN, so stubs lose to the real binaries they shadow.
  # Clearing the session state makes the sandbox PATH authoritative. This list
  # mirrors the teardown in mise's own activate output; __MISE_ORIG_PATH is the
  # load-bearing one, the rest keep mise from reconstructing the session.
  unset MISE_SHELL __MISE_SESSION __MISE_ORIG_PATH __MISE_DIFF \
    __MISE_ZSH_PRECMD_RUN __MISE_ZSH_CHPWD_RAN \
    __MISE_ZSH_ACTIVATE_PATH __MISE_ZSH_ACTIVATE_ENV
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
