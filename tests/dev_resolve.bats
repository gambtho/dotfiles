#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
}

# The test HOME has no gitconfig, so the default branch name and the commit
# identity must be supplied explicitly on every git invocation.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -c init.defaultBranch=main init -q "$dir"
  git -C "$dir" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m init
}

add_worktree() {
  local repo="$1" path="$2" branch="$3"
  mkdir -p "$(dirname "$path")"
  git -C "$repo" -c user.email=t@example.com -c user.name=t \
    worktree add -q "$path" -b "$branch"
}

@test "workspace_id is the full 64-hex sha256 of the real path" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  run dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "workspace_id is stable across a trailing slash and a symlinked path" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  ln -s "$DEV_REPO_ROOT/euro_trip" "$TEST_ROOT/link"
  local plain slashed linked
  plain="$(dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip")"
  slashed="$(dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip/")"
  linked="$(dev_resolve_workspace_id "$TEST_ROOT/link")"
  [ "$plain" = "$slashed" ]
  [ "$plain" = "$linked" ]
}

@test "a primary working tree and a non-git directory are both primary" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  mkdir -p "$DEV_REPO_ROOT/plain"
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip"
  [ "$status" -eq 0 ]
  run dev_resolve_is_primary "$DEV_REPO_ROOT/plain"
  [ "$status" -eq 0 ]
}

@test "a linked worktree is not primary, including from a subdirectory" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  mkdir -p "$DEV_REPO_ROOT/euro_trip-pr5/sub"
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip-pr5"
  [ "$status" -eq 1 ]
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip-pr5/sub"
  [ "$status" -eq 1 ]
}

@test "a primary tree resolves to the bare slug as its session name" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  run dev_resolve euro_trip
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .is_primary <<<"$output")" = "true" ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/euro_trip" ]
}

@test "a sibling worktree inherits the parent slug and gets slug--basename" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  run dev_resolve euro_trip-pr5
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip--euro_trip-pr5" ]
  [ "$(jq -r .is_primary <<<"$output")" = "false" ]
}

@test "a nested .worktrees tree is found and inherits the parent slug" {
  make_repo "$DEV_REPO_ROOT/slabledger"
  add_worktree "$DEV_REPO_ROOT/slabledger" \
    "$DEV_REPO_ROOT/slabledger/.worktrees/review" review
  run dev_resolve review
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "slabledger" ]
  [ "$(jq -r .session_name <<<"$output")" = "slabledger--review" ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/slabledger/.worktrees/review" ]
}

@test "two same-basename worktrees under different parents exit 3 and list both" {
  make_repo "$DEV_REPO_ROOT/slabledger"
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/slabledger" \
    "$DEV_REPO_ROOT/slabledger/.worktrees/review" review
  add_worktree "$DEV_REPO_ROOT/euro_trip" \
    "$DEV_REPO_ROOT/euro_trip/.claude/worktrees/review" review
  run dev_resolve review
  [ "$status" -eq 3 ]
  [[ "$output" == *"slabledger/.worktrees/review"* ]]
  [[ "$output" == *"euro_trip/.claude/worktrees/review"* ]]
  [[ "$output" == *"no argument"* ]]
  [[ "$output" == *"renaming"* ]]
}

@test "an unknown name exits 4 and names the searched roots" {
  run dev_resolve nosuchproject
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown workspace: nosuchproject"* ]]
  [[ "$output" == *"$DEV_REPO_ROOT"* ]]
  [[ "$output" == *".claude/worktrees"* ]]
}

@test "cwd resolution from a subdirectory resolves to the worktree root" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  mkdir -p "$DEV_REPO_ROOT/euro_trip-pr5/deep/nested"
  cd "$DEV_REPO_ROOT/euro_trip-pr5/deep/nested"
  run dev_resolve
  [ "$status" -eq 0 ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/euro_trip-pr5" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip--euro_trip-pr5" ]
}

@test "cwd resolution outside git falls back to the current directory" {
  mkdir -p "$TEST_ROOT/notgit"
  cd "$TEST_ROOT/notgit"
  run dev_resolve
  [ "$status" -eq 0 ]
  [ "$(jq -r .worktree <<<"$output")" = "$TEST_ROOT/notgit" ]
  [ "$(jq -r .slug <<<"$output")" = "notgit" ]
  [ "$(jq -r .is_primary <<<"$output")" = "true" ]
}
