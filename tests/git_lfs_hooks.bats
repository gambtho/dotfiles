#!/usr/bin/env bats
#
# These four hooks ship straight from `git lfs install`, but the dotfiles wire
# them up through a GLOBAL core.hooksPath rather than per-repo. That changes what
# "git-lfs is missing" means: stock behaviour (`exit 2`) is right for a repo that
# opted into LFS, and wrong for every other repo on a machine without the binary
# — which is every devcontainer built from a stock language image.

load test_helper

setup() {
  setup_dotfiles_test
  HOOK_DIR="$REPO_ROOT/core/git/git-hooks.symlink"
}

# The default test PATH keeps /usr/bin, where the host's own git-lfs lives, so
# absence has to be staged per-invocation. Scoping it to the hook process rather
# than the test shell keeps bats' own teardown (which needs /usr/bin) working.
run_without_git_lfs() {
  run env PATH="$STUB_BIN" "$@"
}

lfs_hooks() {
  echo post-checkout post-commit post-merge pre-push
}

@test "the lfs hooks step aside instead of failing when git-lfs is missing" {
  for hook in $(lfs_hooks); do
    run_without_git_lfs "$HOOK_DIR/$hook"

    # exit 2 here is what broke lazy.nvim's plugin clones: git reports the
    # checkout as failed and the caller sees an error naming LFS.
    [ "$status" -eq 0 ]
    [[ "$output" == *"git-lfs not found"* ]]
    # The message has to name the hook, or a failing clone gives no clue which
    # of the four fired.
    [[ "$output" == *"$hook"* ]]
  done
}

@test "the lfs hooks still delegate to git-lfs when it is installed" {
  # `git lfs <hook>` is reached via the `git` on PATH, so stubbing git is enough
  # to observe delegation without installing git-lfs.
  stub_command git-lfs 'exit 0'
  stub_command git 'echo "git $*"'

  for hook in $(lfs_hooks); do
    run "$HOOK_DIR/$hook" arg1 arg2

    [ "$status" -eq 0 ]
    [ "$output" = "git lfs $hook arg1 arg2" ]
  done
}
