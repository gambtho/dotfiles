#!/usr/bin/env bats

# Coverage for bin/common.sh's ensure_stable_link_root.
#
# Overlay symlinks written into project trees used to store a $HOME-derived
# absolute target, so they only resolved on the machine that created them — a
# devcontainer bind-mounting the same tree under a different $HOME saw every one
# of them dangle. The fix is an indirection each environment establishes for
# itself: a stable root path pointing at that environment's own checkout.
#
# DOTFILES_LINK_ROOT is a TEST-ONLY override. Every test sets it to a temp path,
# so nothing here touches the real /opt.

load test_helper

setup() {
  setup_dotfiles_test
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bin/common.sh"

  CHECKOUT="$TEST_ROOT/dotfiles"
  ROOT="$TEST_ROOT/opt/dotfiles"
  mkdir -p "$CHECKOUT"
  export DOTFILES_LINK_ROOT="$ROOT"
}

@test "the root is created pointing at the given checkout" {
  run ensure_stable_link_root "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT")" = "$CHECKOUT" ]
}

@test "re-running is idempotent" {
  ensure_stable_link_root "$CHECKOUT"
  run ensure_stable_link_root "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT")" = "$CHECKOUT" ]
  [[ "$output" == *"already correct"* ]]
}

@test "a root aimed at the wrong checkout is repointed" {
  # The live hazard: bootstrap and relink both derive their own root from the
  # running script's location, so running either from a linked worktree would
  # otherwise leave every overlay link resolving into a disposable directory.
  mkdir -p "$TEST_ROOT/worktree" "$(dirname "$ROOT")"
  ln -sfn "$TEST_ROOT/worktree" "$ROOT"

  run ensure_stable_link_root "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT")" = "$CHECKOUT" ]
}

@test "-n keeps a repoint from nesting inside the old target" {
  # Without ln -n the existing symlink is dereferenced and the new link lands
  # at <old-target>/dotfiles, leaving the root itself stale and unnoticed.
  mkdir -p "$TEST_ROOT/worktree" "$(dirname "$ROOT")"
  ln -sfn "$TEST_ROOT/worktree" "$ROOT"

  ensure_stable_link_root "$CHECKOUT"
  [ ! -e "$TEST_ROOT/worktree/dotfiles" ]
}

@test "a real directory occupying the root is never clobbered" {
  mkdir -p "$ROOT/real-content"

  run ensure_stable_link_root "$CHECKOUT"
  [ "$status" -eq 0 ]
  [ ! -L "$ROOT" ]
  [ -d "$ROOT/real-content" ]
  [[ "$output" == *"real file or directory"* ]]
}

@test "a missing target is refused rather than linked" {
  run ensure_stable_link_root "$TEST_ROOT/nope"
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
  [[ "$output" == *"not a directory"* ]]
}

@test "an empty target is refused" {
  run ensure_stable_link_root ""
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
  [[ "$output" == *"no target given"* ]]
}

@test "a failure to create the root warns instead of aborting bootstrap" {
  # A locked-down host must still bootstrap: the overlay links then fall back
  # to $HOME-absolute targets, which is the pre-existing behaviour.
  mkdir -p "$(dirname "$ROOT")"
  chmod a-w "$(dirname "$ROOT")"
  stub_command sudo 'exit 1'

  run ensure_stable_link_root "$CHECKOUT"
  chmod u+w "$(dirname "$ROOT")"

  [ "$status" -eq 0 ]
  [ ! -e "$ROOT" ]
  [[ "$output" == *"Could not create"* || "$output" == *"sudo is unavailable"* ]]
}
