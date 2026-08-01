#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  UNTRACKED_FILE="$REPO_ROOT/bin/example-check-script-$BATS_TEST_NUMBER"
  IGNORED_DIR="$REPO_ROOT/bin/.opencode"
  IGNORED_FILE="$IGNORED_DIR/project-$BATS_TEST_NUMBER.sh"
  mkdir -p "$IGNORED_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$UNTRACKED_FILE"
  printf '#!/usr/bin/env bash\nfalse\n' >"$IGNORED_FILE"
}

teardown() {
  rm -f -- "$UNTRACKED_FILE" "$IGNORED_FILE"
  rmdir "$IGNORED_DIR" 2>/dev/null || true
}

list_files() {
  local class="$1"
  run bash -c '"$1/bin/list-check-files" "$2" | tr "\0" "\n"' _ "$REPO_ROOT" "$class"
}

@test "bash discovery includes tracked and untracked source but excludes ignored state" {
  list_files bash

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/install"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"core/shell/zshrc.symlink"* ]]
}

@test "zsh discovery includes shell symlinks and zsh sources" {
  list_files zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"core/shell/zshrc.symlink"* ]]
  [[ "$output" == *"core/path.zsh"* ]]
  [[ "$output" != *"bin/install"* ]]
}

@test "shellcheck discovery includes repository shell entry points" {
  list_files shellcheck

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/install"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"ai/claude/install.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$REPO_ROOT/"}"* ]]
}

@test "shfmt discovery includes the shared Bats helper" {
  list_files shfmt

  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/test_helper.bash"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"ai/claude/install.sh"* ]]
}

@test "Makefile check pipelines propagate discovery failures portably" {
  run rg -n 'sort -z|sort -zu|xargs[^\n]* -r([[:space:]]|$)' "$REPO_ROOT/bin/list-check-files" "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]

  run rg -n "bash -o pipefail -c" "$REPO_ROOT/Makefile"
  [ "$status" -eq 0 ]
}

@test "discovery rejects unknown classes" {
  run "$REPO_ROOT/bin/list-check-files" ruby

  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "discovery fails clearly outside a Git checkout" {
  run bash -c 'cd "$1" && "$2/bin/list-check-files" bash' _ "$TEST_ROOT" "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"must run inside a Git checkout"* ]]
}
