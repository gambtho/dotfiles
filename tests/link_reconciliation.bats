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

@test "link creation failure restores the original destination" {
  printf 'local\n' >"$HOME/destination"

  run bash -c '
    source "$1/bin/common.sh"
    ln() { return 1; }
    reconcile_link "$2" "$3" config replace apply
  ' _ "$REPO_ROOT" "$TEST_ROOT/source" "$HOME/destination"

  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/destination")" = local ]
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

@test "interactive bootstrap does not prompt for an already-correct link" {
  ln -s "$TEST_ROOT/source" "$HOME/destination"

  # No /dev/tty is available here, so any attempt to prompt fails loudly
  # instead of silently skipping.
  run env HOME="$HOME" BOOTSTRAP_SOURCE_ONLY=1 bash -c '
    source "$1/bin/bootstrap"
    overwrite_all=false
    backup_all=false
    skip_all=false
    link_file "$2" "$3"
  ' _ "$REPO_ROOT" "$TEST_ROOT/source" "$HOME/destination" </dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"already exists at"* ]]
  [ "$(readlink "$HOME/destination")" = "$TEST_ROOT/source" ]
}

@test "interactive bootstrap still prompts for a genuine conflict" {
  printf 'local\n' >"$HOME/destination"

  run env HOME="$HOME" BOOTSTRAP_SOURCE_ONLY=1 bash -c '
    source "$1/bin/bootstrap"
    overwrite_all=false
    backup_all=false
    skip_all=false
    link_file "$2" "$3"
  ' _ "$REPO_ROOT" "$TEST_ROOT/source" "$HOME/destination" </dev/null

  [[ "$output" == *"already exists at"* ]]
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

@test "managed_link_pairs enumerates symlink and config mappings, excluding archived paths" {
  local fixture="$TEST_ROOT/fixture"
  mkdir -p "$fixture/core/shell"
  mkdir -p "$fixture/config/nvim"
  mkdir -p "$fixture/config/tool with spaces"
  mkdir -p "$fixture/dir with spaces"
  mkdir -p "$fixture/archived/core"
  mkdir -p "$fixture/.git/core"
  mkdir -p "$fixture/.claude/worktrees/core"

  printf 'zshrc\n' >"$fixture/core/shell/zshrc.symlink"
  printf 'spaced\n' >"$fixture/dir with spaces/tool.symlink"
  printf 'archived\n' >"$fixture/archived/core/should-not-appear.symlink"
  printf 'git\n' >"$fixture/.git/core/should-not-appear.symlink"
  printf 'worktree\n' >"$fixture/.claude/worktrees/core/should-not-appear.symlink"

  local pairs=()
  while IFS= read -r -d '' source && IFS= read -r -d '' destination; do
    pairs+=("$source"$'\t'"$destination")
  done < <(managed_link_pairs "$fixture" "$HOME")

  local joined
  joined=$(printf '%s\n' "${pairs[@]}")

  [[ "$joined" == *"$fixture/core/shell/zshrc.symlink"$'\t'"$HOME/.zshrc"* ]]
  [[ "$joined" == *"$fixture/dir with spaces/tool.symlink"$'\t'"$HOME/.tool"* ]]
  [[ "$joined" == *"$fixture/config/nvim"$'\t'"$HOME/.config/nvim"* ]]
  [[ "$joined" == *"$fixture/config/tool with spaces"$'\t'"$HOME/.config/tool with spaces"* ]]
  [[ "$joined" != *"archived"* ]]
  [[ "$joined" != *"/.git/"* ]]
  [[ "$joined" != *"worktrees"* ]]
}

@test "bootstrap and relink both consume managed_link_pairs while keeping their differing conflict policies" {
  grep -q 'managed_link_pairs' "$REPO_ROOT/bin/bootstrap"
  grep -q 'managed_link_pairs' "$REPO_ROOT/bin/relink"

  # bootstrap: interactive conflict still prompts (policy: prompt user)
  printf 'local\n' >"$HOME/destination"
  run env HOME="$HOME" BOOTSTRAP_SOURCE_ONLY=1 bash -c '
    source "$1/bin/bootstrap"
    overwrite_all=false
    backup_all=false
    skip_all=false
    link_file "$2" "$3"
  ' _ "$REPO_ROOT" "$TEST_ROOT/source" "$HOME/destination" </dev/null
  [[ "$output" == *"already exists at"* ]]

  # relink: same conflict is reported non-interactively, not prompted
  printf 'local\n' >"$HOME/destination2"
  run env HOME="$HOME" bash -c '
    source "$1/bin/relink"
  ' _ "$REPO_ROOT"
  [[ "$output" != *"already exists at"* ]]
}

@test "next_backup_path reports failure instead of a malformed name when date fails" {
  printf 'old\n' >"$HOME/settings.json"
  printf 'old\n' >"$HOME/settings.json.backup"
  stub_command date 'exit 1'

  # errexit is suspended for callers invoked as an `if !` condition, so
  # next_backup_path must surface a date failure via its own exit status
  # rather than emitting a path built from an empty timestamp.
  run bash -c '
    set -e
    source "$1/bin/common.sh"
    if candidate="$(next_backup_path "$2")"; then
      printf "REPORTED SUCCESS %s\n" "$candidate"
    else
      printf "REPORTED FAILURE\n"
    fi
  ' _ "$REPO_ROOT" "$HOME/settings.json"

  [[ "$output" == *"REPORTED FAILURE"* ]]
  [[ "$output" != *".backup..1"* ]]
}
