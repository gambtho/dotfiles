#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  GUARD="$REPO_ROOT/ai/claude/hooks/worktree-guard.sh"
  REPO="$TEST_ROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=t \
    commit --quiet --allow-empty -m init
  INPUT_FILE="$TEST_ROOT/input.json"
}

write_input() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" >"$INPUT_FILE"
}

@test "denies edit in the primary worktree on the default branch" {
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision"'* ]]
  [[ "$output" == *'"deny"'* ]]
  [[ "$output" == *'worktree'* ]]
}

@test "denies edit in the primary worktree on a feature branch" {
  git -C "$REPO" checkout --quiet -b feature
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "allows edit in a linked worktree on a feature branch" {
  linked="$TEST_ROOT/linked-feature"
  git -C "$REPO" worktree add --quiet -b feature "$linked"
  write_input "$linked/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows edit outside any git repo" {
  mkdir -p "$TEST_ROOT/plain"
  write_input "$TEST_ROOT/plain/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows repo listed in the allowlist" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' "$REPO" >"$HOME/.claude/worktree-guard-allow"
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allowlist supports tilde paths and comments" {
  mkdir -p "$HOME/.claude" "$HOME/repo2"
  git -C "$HOME/repo2" init --quiet --initial-branch=main
  git -C "$HOME/repo2" -c user.email=t@example.com -c user.name=t \
    commit --quiet --allow-empty -m init
  printf '# comment\n~/repo2\n' >"$HOME/.claude/worktree-guard-allow"
  write_input "$HOME/repo2/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows when CLAUDE_WORKTREE_GUARD=off" {
  write_input "$REPO/file.txt"
  run env CLAUDE_WORKTREE_GUARD=off bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denies detached HEAD in the primary worktree" {
  git -C "$REPO" checkout --quiet --detach
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "allows detached HEAD in a linked worktree" {
  linked="$TEST_ROOT/linked-detached"
  git -C "$REPO" worktree add --quiet --detach "$linked" HEAD
  write_input "$linked/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fails open when jq is unavailable" {
  write_input "$REPO/file.txt"
  run env PATH="$STUB_BIN" /bin/bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denies via notebook_path for NotebookEdit" {
  printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' \
    "$REPO/nb.ipynb" >"$INPUT_FILE"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "denies for a new file in a not-yet-created subdirectory" {
  write_input "$REPO/newdir/sub/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}
