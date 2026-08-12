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

@test "fails open when git is unavailable" {
  tool_bin="$TEST_ROOT/no-git-bin"
  mkdir -p "$tool_bin"
  for tool in cat dirname jq readlink; do
    ln -s "$(command -v "$tool")" "$tool_bin/$tool"
  done

  write_input "$REPO/file.txt"
  run env PATH="$tool_bin" /bin/bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uses a portable fallback when readlink -m is unsupported" {
  mkdir -p "$TEST_ROOT/outside"
  printf 'x\n' >"$REPO/target.txt"
  ln -s "$REPO/target.txt" "$TEST_ROOT/outside/link.txt"
  cat >"$STUB_BIN/readlink" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  exit 1
fi
exec /usr/bin/readlink "$@"
SCRIPT
  cat >"$STUB_BIN/realpath" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$STUB_BIN/readlink"
  chmod +x "$STUB_BIN/realpath"

  write_input "$TEST_ROOT/outside/link.txt"
  run env PATH="$PATH" /bin/bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "denies edit through a symlink into a primary checkout" {
  mkdir -p "$TEST_ROOT/outside"
  printf 'x\n' >"$REPO/target.txt"
  ln -s "$REPO/target.txt" "$TEST_ROOT/outside/link.txt"
  write_input "$TEST_ROOT/outside/link.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "allows edit through a symlink into a linked worktree" {
  linked="$TEST_ROOT/linked-sym"
  git -C "$REPO" worktree add --quiet -b sym-feature "$linked"
  printf 'x\n' >"$linked/target.txt"
  mkdir -p "$TEST_ROOT/outside"
  ln -s "$linked/target.txt" "$TEST_ROOT/outside/wt-link.txt"
  write_input "$TEST_ROOT/outside/wt-link.txt"
  run bash "$GUARD" <"$INPUT_FILE"
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

@test "denies edit in an existing subdirectory of a primary checkout" {
  mkdir -p "$REPO/sub/deeper"
  write_input "$REPO/sub/deeper/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "allows edit in an existing subdirectory of a linked worktree" {
  linked="$TEST_ROOT/linked-sub"
  git -C "$REPO" worktree add --quiet -b sub-feature "$linked"
  mkdir -p "$linked/sub/deeper"
  write_input "$linked/sub/deeper/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denies for a new file in a not-yet-created subdirectory" {
  write_input "$REPO/newdir/sub/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}
