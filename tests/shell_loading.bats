#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

run_loader() {
  local profile="$1"
  printf '%s\n' "$profile" >"$HOME/.dotfiles-profile"
  run env HOME="$HOME" DOTFILES="$REPO_ROOT" zsh -fc '
    source "$DOTFILES/core/shell/load-custom.zsh" || exit 1
    print "WORK_PROFILE=${WORK_PROFILE:-}"
    print "SERVER_PROFILE=${SERVER_PROFILE:-}"
    if alias aks >/dev/null 2>&1; then
      print WORK_ALIAS_PRESENT
    fi
  '
}

@test "personal profile does not load work or server configuration" {
  run_loader personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORK_PROFILE="* ]]
  [[ "$output" == *"SERVER_PROFILE="* ]]
  [[ "$output" != *"WORK_ALIAS_PRESENT"* ]]
}

@test "work profile loads work configuration" {
  run_loader work
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORK_PROFILE=1"* ]]
  [[ "$output" == *"WORK_ALIAS_PRESENT"* ]]
}

@test "server profile does not load work configuration" {
  run_loader server
  [ "$status" -eq 0 ]
  [[ "$output" == *"SERVER_PROFILE=1"* ]]
  [[ "$output" != *"WORK_ALIAS_PRESENT"* ]]
}

@test "archived zsh files are never loaded" {
  run env HOME="$HOME" DOTFILES="$REPO_ROOT" zsh -fc '
    source "$DOTFILES/core/shell/load-custom.zsh" || exit 1
    print "${GOPRIVATE:-}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"goms.io"* ]]
}

@test "core path never places the current directory on PATH" {
  run zsh -fc 'PATH=./bin:/usr/bin:/bin; ZSH="$1"; HOME="$2"; source "$1/core/path.zsh"; print -r -- "$PATH"' _ "$REPO_ROOT" "$HOME"
  [ "$status" -eq 0 ]
  [[ ":$output:" != *":./bin:"* ]]
  [[ ":$output:" == *":$REPO_ROOT/bin:"* ]]
}

@test "zshrc loads customizations from configured DOTFILES root" {
  local custom_root="$TEST_ROOT/custom-dotfiles"
  mkdir -p "$custom_root/core/shell"
  printf 'print CUSTOM_DOTFILES_LOADED\n' >"$custom_root/core/shell/load-custom.zsh"

  run env HOME="$HOME" DOTFILES="$custom_root" PATH="$PATH" zsh -dfc 'source "$1/core/shell/zshrc.symlink"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CUSTOM_DOTFILES_LOADED"* ]]
}

@test "zshrc performs no network or git operations" {
  stub_command git 'echo git-called >&2; exit 99'
  stub_command curl 'echo curl-called >&2; exit 99'
  ln -s "$REPO_ROOT" "$HOME/.dotfiles"

  run env HOME="$HOME" PATH="$PATH" zsh -dfc 'source "$1/core/shell/zshrc.symlink"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"called"* ]]
}
