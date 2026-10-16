#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  INSTALL="$REPO_ROOT/tools/herdr/heeler/install.sh"
}

@test "Heeler is explicitly opt-in and opt-out writes nothing" {
  for selected in '' 0; do
    run bash -c 'DOTFILES_HEELER_ENABLED="$1" bash "$2" --apply' _ "$selected" "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not selected"* ]]
    [ ! -e "$HOME/.local/share/heeler" ]
    [ ! -e "$HOME/.config/systemd" ]
  done
}

@test "opt-out does not write bytecode into authored resources" {
  local fixture="$TEST_ROOT/feature"
  mkdir -p "$fixture"
  cp "$REPO_ROOT/tools/herdr/heeler/"*.py "$fixture/"
  cp "$INSTALL" "$fixture/install.sh"
  run bash -c 'unset PYTHONDONTWRITEBYTECODE; DOTFILES_HEELER_ENABLED=0 bash "$1" --check' _ "$fixture/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$fixture/__pycache__" ]
}

@test "Heeler CLI rejects an invalid selector without writes" {
  run bash -c 'DOTFILES_HEELER_ENABLED=invalid bash "$1" --apply' _ "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be 1, 0 or unset"* ]]
  [ ! -e "$HOME/.config/systemd" ]
}

@test "Heeler help explains explicit prepare and check actions" {
  run bash "$INSTALL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--apply"* ]]
  [[ "$output" == *"--check"* ]]
}

@test "Heeler refuses a HOME override before preparing another account" {
  run bash -c 'DOTFILES_HEELER_ENABLED=1 bash "$1" --apply' _ "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HOME must match"* ]]
  [ ! -e "$HOME/.local/share/heeler-trial" ]
}

@test "Heeler Make targets delegate only to unprivileged explicit actions" {
  run make -n -C "$REPO_ROOT" ai-heeler
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash tools/herdr/heeler/install.sh --apply"* ]]
  run make -n -C "$REPO_ROOT" ai-heeler-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash tools/herdr/heeler/install.sh --check"* ]]
  run make -n -C "$REPO_ROOT" ai ai-check
  [ "$status" -eq 0 ]
  [[ "$output" != *"tools/herdr/heeler/install.sh"* ]]
}

@test "nested Heeler shell launcher is included in syntax discovery" {
  run bash -c '"$1/libexec/list-check-files" bash | tr "\0" "\n"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tools/herdr/heeler/install.sh"* ]]
}
