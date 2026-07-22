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

@test "shell loader configures healthy Vekil endpoints" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command mise 'exit 0'
  stub_command curl 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/load-custom.zsh" || exit 1
    print -r -- "$OPENAI_BASE_URL|$ANTHROPIC_BASE_URL"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:1337/v1|http://127.0.0.1:1337"* ]]
}

@test "zshrc loads Vekil before deferred customizations run" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir" "$HOME/.zsh-defer"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command curl 'exit 0'
  cat >"$HOME/.zsh-defer/zsh-defer.plugin.zsh" <<'SCRIPT'
zsh-defer() { :; }
SCRIPT

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/zshrc.symlink" || exit 1
    print -r -- "VEKIL_CODEX_FUNCTION=${+functions[codex]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"VEKIL_CODEX_FUNCTION=1"* ]]
}

@test "localrc endpoint overrides the managed Codex wrapper" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  printf 'export OPENAI_BASE_URL=https://custom.example/v1\n' >"$HOME/.localrc"
  stub_command curl 'exit 0'
  cat >"$STUB_BIN/codex" <<'SCRIPT'
#!/bin/bash
printf '%s|%s\n' "$*" "$OPENAI_BASE_URL"
SCRIPT
  chmod +x "$STUB_BIN/codex"

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/load-custom.zsh" || exit 1
    codex exec prompt
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"exec prompt|https://custom.example/v1"* ]]
}

@test "core path never places the current directory on PATH" {
  run zsh -fc 'PATH=./bin:/usr/bin:/bin; ZSH="$1"; HOME="$2"; source "$1/core/path.zsh"; print -r -- "$PATH"' _ "$REPO_ROOT" "$HOME"
  [ "$status" -eq 0 ]
  [[ ":$output:" != *":./bin:"* ]]
  [[ ":$output:" == *":$REPO_ROOT/bin:"* ]]
}

@test "core path changes persist after function-scoped loading" {
  run env HOME="$HOME" PATH="/usr/bin:/bin" zsh -dfc '
    load_path() {
      ZSH="$1"
      source "$1/core/path.zsh"
    }
    load_path "$1"
    print -r -- "$PATH"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ ":$output:" == *":$REPO_ROOT/bin:"* ]]
  [[ ":$output:" == *":/usr/bin:"* ]]
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
