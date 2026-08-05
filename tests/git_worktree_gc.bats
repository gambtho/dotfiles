#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  GC="$REPO_ROOT/bin/git-worktree-gc"
  REPO="$TEST_ROOT/repo"
  # Captured before any git stub is installed, so pass-through stubs can reach
  # the real binary rather than recursing into themselves.
  REAL_GIT=$(command -v git)

  git init -q -b main "$REPO"
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  echo one >"$REPO/file"
  git -C "$REPO" add file
  git -C "$REPO" commit -q -m one

  # git-worktree-gc acts on the current repository, so every test must stand
  # inside the fixture — not in the dotfiles checkout bats was invoked from.
  cd "$REPO"
}

# Adds a worktree whose branch carries a commit that is NOT an ancestor of
# main — the shape a squash merge leaves behind.
add_worktree() {
  local name="$1"
  git -C "$REPO" worktree add -q -b "$name" "$TEST_ROOT/wt-$name" main
  echo "$name" >"$TEST_ROOT/wt-$name/$name"
  git -C "$TEST_ROOT/wt-$name" add "$name"
  git -C "$TEST_ROOT/wt-$name" commit -q -m "$name"
}

# A gh stub that honors --base, so tests can prove the base filter is passed
# and respected. Args: <base-the-PRs-landed-in> <branch>...
stub_gh_merged_into() {
  local base="$1"
  shift
  stub_command gh "
base=''
while [ \$# -gt 0 ]; do
  [ \"\$1\" = '--base' ] && base=\$2
  shift
done
[ \"\$base\" = '$base' ] || exit 0
printf '%s\n' $(printf "'%s' " "$@")
"
}

stub_gh_merged() {
  stub_gh_merged_into main "$@"
}

@test "dry run reports a squash-merged worktree without removing it" {
  add_worktree shipped
  stub_gh_merged shipped

  run "$GC" --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *shipped* ]]
  [[ "$output" == *"Dry run"* ]]
  [ -d "$TEST_ROOT/wt-shipped" ]
}

@test "--yes removes a squash-merged worktree but keeps its branch" {
  add_worktree shipped
  stub_gh_merged shipped

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  assert_file_absent "$TEST_ROOT/wt-shipped"
  git -C "$REPO" show-ref --verify --quiet refs/heads/shipped
}

@test "--delete-branches deletes the squash-merged branch too" {
  add_worktree shipped
  stub_gh_merged shipped

  run "$GC" --base main --yes --delete-branches
  [ "$status" -eq 0 ]
  assert_file_absent "$TEST_ROOT/wt-shipped"
  ! git -C "$REPO" show-ref --verify --quiet refs/heads/shipped
}

@test "an unmerged worktree is left alone" {
  add_worktree shipped
  add_worktree wip
  stub_gh_merged shipped

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/wt-wip" ]
  [[ "$output" == *"1 worktree(s) on unmerged branches"* ]]
}

@test "uncommitted changes keep a merged worktree" {
  add_worktree shipped
  stub_gh_merged shipped
  echo dirty >"$TEST_ROOT/wt-shipped/scratch"
  git -C "$TEST_ROOT/wt-shipped" add scratch

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/wt-shipped" ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "a locked worktree is kept unless --include-locked" {
  add_worktree shipped
  stub_gh_merged shipped
  git -C "$REPO" worktree lock "$TEST_ROOT/wt-shipped"

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/wt-shipped" ]
  [[ "$output" == *locked* ]]

  # The first run left it locked and untouched; --include-locked unlocks it.
  run "$GC" --base main --yes --include-locked
  [ "$status" -eq 0 ]
  assert_file_absent "$TEST_ROOT/wt-shipped"
}

@test "ancestry-merged branches are found without gh" {
  git -C "$REPO" worktree add -q -b landed "$TEST_ROOT/wt-landed" main

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  assert_file_absent "$TEST_ROOT/wt-landed"
}

@test "a missing gh warns that squash merges are invisible" {
  add_worktree shipped
  # gh sits in /usr/bin beside git, so the only way to hide it is a PATH built
  # from the handful of binaries this script and bats actually need.
  mkdir -p "$TEST_ROOT/minbin"
  for tool in env bash sh git rm; do
    ln -s "$(command -v "$tool")" "$TEST_ROOT/minbin/$tool"
  done
  PATH="$TEST_ROOT/minbin"

  run "$GC" --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh not found"* ]]
  [ -d "$TEST_ROOT/wt-shipped" ]
}

@test "a failing gh falls back to ancestry rather than reporting a clean sweep" {
  add_worktree shipped
  stub_command gh "echo 'no git remotes found' >&2; exit 1"

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"continuing on ancestry alone"* ]]
  [ -d "$TEST_ROOT/wt-shipped" ]
}

@test "the main worktree is never a candidate" {
  stub_gh_merged main

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [ -d "$REPO" ]
  [[ "$output" == *"Nothing to remove"* ]]
}

@test "a bad base ref fails loudly" {
  run "$GC" --base no-such-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "a PR merged into a different base is not treated as landed" {
  add_worktree shipped
  # Merged, but into a release branch — nothing to do with main.
  stub_gh_merged_into release shipped

  run "$GC" --base main --yes
  [ "$status" -eq 0 ]
  [ -d "$TEST_ROOT/wt-shipped" ]
  [[ "$output" == *"1 worktree(s) on unmerged branches"* ]]
}

@test "an origin-prefixed base still reaches gh as a branch name" {
  add_worktree shipped
  stub_gh_merged_into main shipped
  git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse main)"

  run "$GC" --base origin/main --yes
  [ "$status" -eq 0 ]
  assert_file_absent "$TEST_ROOT/wt-shipped"
}

# Forces the exact race the removal path guards: the worktree is clean when the
# plan checks it, and dirty by the time `git worktree remove` runs. Only this
# early refusal leaves the worktree registered — a later failure (an
# undeletable directory) deregisters it first, so nothing remains to re-lock.
stub_git_dirties_before_remove() {
  stub_command git "
if [ \"\$1\" = 'worktree' ] && [ \"\$2\" = 'remove' ]; then
  echo raced >\"\$3/raced-untracked\"
fi
exec $REAL_GIT \"\$@\"
"
}

@test "a failed removal re-locks the worktree with its original reason" {
  add_worktree shipped
  stub_gh_merged shipped
  git -C "$REPO" worktree lock --reason "held for review" "$TEST_ROOT/wt-shipped"
  stub_git_dirties_before_remove

  run "$GC" --base main --yes --include-locked
  [ "$status" -eq 1 ]
  [ -d "$TEST_ROOT/wt-shipped" ]
  [[ "$output" == *"could not remove"* ]]

  run git -C "$REPO" worktree list --porcelain
  [[ "$output" == *"locked held for review"* ]]
}

@test "a failed removal of an unlocked worktree leaves it unlocked" {
  add_worktree shipped
  stub_gh_merged shipped
  stub_git_dirties_before_remove

  run "$GC" --base main --yes
  [ "$status" -eq 1 ]

  run git -C "$REPO" worktree list --porcelain
  [[ "$output" != *locked* ]]
}
