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

@test "zshrc configures healthy Vekil endpoints" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command mise 'exit 0'
  stub_command curl 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/zshrc.symlink" || exit 1
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
    source "$DOTFILES/core/shell/zshrc.symlink" || exit 1
    (( ${+functions[codex]} )) || { print -r -- "NO_MANAGED_CODEX_WRAPPER"; exit 1; }
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

@test "personal zshrc does not load Agency" {
  printf 'personal\n' >"$HOME/.dotfiles-profile"
  stub_command mise 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="/usr/bin:/bin" zsh -dfc '
    path=("$STUB_BIN" /usr/bin /bin)
    export PATH
    source "$DOTFILES/core/shell/zshrc.symlink"
    print -r -- "$PATH"
  '

  [ "$status" -eq 0 ]
  [[ ":$output:" != *":$HOME/.config/agency/CurrentVersion:"* ]]
  [[ "$output" != *"/home/tng/.config/agency/CurrentVersion"* ]]
}

@test "work zshrc loads the HOME-relative Agency path exactly once" {
  printf 'work\n' >"$HOME/.dotfiles-profile"
  stub_command mise 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="/usr/bin:/bin" zsh -dfc '
    path=("$STUB_BIN" /usr/bin /bin)
    export PATH
    source "$DOTFILES/core/shell/zshrc.symlink"
    source "$DOTFILES/core/shell/zshrc.symlink"
    paths=("${(@s/:/)PATH}")
    count=0
    for path in $paths; do
      [[ $path == "$HOME/.config/agency/CurrentVersion" ]] && (( count += 1 ))
    done
    print -r -- "$count|$PATH"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"1|"* ]]
}

@test "normal zshrc initialization performs one Vekil readiness probe" {
  local state_dir="$HOME/.local/state/vekil"
  local curl_log="$TEST_ROOT/vekil-curl.log"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  printf 'ready\n' >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VEKIL_CURL_LOG"
exit 0
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" VEKIL_CURL_LOG="$curl_log" zsh -dfc '
    source "$DOTFILES/core/shell/zshrc.symlink"
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c '/readyz' "$curl_log")" -eq 1 ]
}

@test "deliberate Vekil env re-source performs a fresh convergence probe" {
  local state_dir="$HOME/.local/state/vekil"
  local curl_log="$TEST_ROOT/vekil-curl.log"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  printf 'ready\n' >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VEKIL_CURL_LOG"
if [[ "$(cat "$VEKIL_PROBE_STATE")" == ready ]]; then exit 0; fi
exit 1
SCRIPT
  chmod +x "$STUB_BIN/curl"
  printf 'ready\n' >"$TEST_ROOT/probe-state"

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" \
    VEKIL_CURL_LOG="$curl_log" VEKIL_PROBE_STATE="$TEST_ROOT/probe-state" zsh -dfc '
      unset OPENAI_BASE_URL OPENAI_API_KEY
      unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_MODEL
      unset VEKIL_MANAGED_OPENAI_BASE_URL VEKIL_MANAGED_OPENAI_API_KEY
      unset VEKIL_MANAGED_ANTHROPIC_BASE_URL VEKIL_MANAGED_ANTHROPIC_API_KEY
      unset VEKIL_MANAGED_ANTHROPIC_MODEL
      source "$DOTFILES/ai/vekil/env.zsh"
      first=$OPENAI_BASE_URL
      print unavailable >"$VEKIL_PROBE_STATE"
      source "$DOTFILES/ai/vekil/env.zsh"
      print -r -- "$first|${OPENAI_BASE_URL-unset}|${OPENAI_API_KEY-unset}|${ANTHROPIC_BASE_URL-unset}|${ANTHROPIC_API_KEY-unset}|${ANTHROPIC_MODEL-unset}"
    '

  [ "$status" -eq 0 ]
  [ "$(grep -c '/readyz' "$curl_log")" -eq 2 ]
  [[ "$output" == *"http://127.0.0.1:1337/v1|unset|unset|unset|unset|unset"* ]]
}
