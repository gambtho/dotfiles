#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/bin/common.sh"
  printf 'managed\n' >"$TEST_ROOT/source"
}

@test "skip preserves a conflicting file" {
  printf 'local\n' >"$HOME/destination"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config skip apply

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/destination")" = local ]
}

@test "replace changes a conflicting symlink" {
  ln -s "$TEST_ROOT/old" "$HOME/destination"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config replace apply

  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/destination" "$TEST_ROOT/source"
}

@test "backup never overwrites an existing backup" {
  printf 'local\n' >"$HOME/destination"
  printf 'older\n' >"$HOME/destination.backup"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config backup apply

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/destination.backup")" = older ]
  run bash -c 'compgen -G "$1/destination.backup.*"' _ "$HOME"
  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/destination" "$TEST_ROOT/source"
}

@test "check mode describes replacement without mutation" {
  ln -s "$TEST_ROOT/old" "$HOME/destination"
  local before
  before=$(readlink "$HOME/destination")

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config replace check

  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/destination")" = "$before" ]
  [[ "$output" == *"Would replace"* ]]
}

@test "invalid policy fails before mutation" {
  printf 'local\n' >"$HOME/destination"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config prompt apply

  [ "$status" -eq 2 ]
  [ "$(cat "$HOME/destination")" = local ]
}

@test "invalid mode fails before mutation" {
  printf 'local\n' >"$HOME/destination"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config skip pretend

  [ "$status" -eq 2 ]
  [ "$(cat "$HOME/destination")" = local ]
}

@test "an already correct link is unchanged" {
  ln -s "$TEST_ROOT/source" "$HOME/destination"

  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config backup apply

  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/destination" "$TEST_ROOT/source"
  [ ! -e "$HOME/destination.backup" ]
}

@test "check mode describes a missing link without creating it" {
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config backup check

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/destination" ]
  [[ "$output" == *"Would link"* ]]
}

@test "link prompt actions map to non-mutating policies" {
  local action expected
  while IFS=' ' read -r action expected; do
    run link_policy_for_action "$action"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done <<'CASES'
s skip
S skip-all
o replace
O replace-all
b backup
B backup-all
x skip
CASES
}

@test "noninteractive bootstrap preserves a real-file conflict" {
  printf 'local\n' >"$HOME/destination"

  run env HOME="$HOME" BOOTSTRAP_SOURCE_ONLY=1 bash -c '
    source "$1/bin/bootstrap"
    overwrite_all=false
    backup_all=false
    skip_all=true
    link_file "$2" "$3"
  ' _ "$REPO_ROOT" "$TEST_ROOT/source" "$HOME/destination"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/destination")" = local ]
}

@test "relink replaces a different symlink" {
  ln -s "$TEST_ROOT/old" "$HOME/.zshrc"

  run env HOME="$HOME" bash "$REPO_ROOT/bin/relink"

  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/.zshrc" "$REPO_ROOT/core/shell/zshrc.symlink"
}

@test "relink preserves and reports a real-file conflict" {
  printf 'local\n' >"$HOME/.zshrc"

  run env HOME="$HOME" bash "$REPO_ROOT/bin/relink"

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.zshrc")" = local ]
  [[ "$output" == *"left UNLINKED"* ]]
}
