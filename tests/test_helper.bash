setup_dotfiles_test() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  export REPO_ROOT
  export TEST_ROOT="$BATS_TEST_TMPDIR/test-root"
  export HOME="$TEST_ROOT/home"
  export STUB_BIN="$TEST_ROOT/bin"
  mkdir -p "$HOME" "$STUB_BIN"

  # Resolve tools the sandbox needs but cannot assume are in a system
  # directory while the ambient PATH is still intact. A tool installed through
  # mise, Homebrew, or another user-level manager may otherwise disappear when
  # tests sanitize PATH.
  #
  # Symlink each tool into a dedicated directory rather than appending its
  # containing directory. The symlink farm exposes exactly the named tools and
  # nothing installed beside them.
  export SANDBOX_TOOL_BIN="$TEST_ROOT/tool-bin"
  mkdir -p "$SANDBOX_TOOL_BIN"
  local tool tool_path
  for tool in yq node; do
    tool_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$tool_path" "$SANDBOX_TOOL_BIN/$tool"
  done

  # $SANDBOX_TOOL_BIN goes last, after $STUB_BIN and the system directories,
  # so a stub still shadows the real binary it is meant to replace.
  export PATH="$STUB_BIN:/usr/bin:/bin:$SANDBOX_TOOL_BIN"
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
