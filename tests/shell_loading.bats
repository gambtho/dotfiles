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

@test "zshrc removes inherited Vekil-managed environment without touching user overrides" {
  stub_command mise 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" \
    OPENAI_BASE_URL=http://proxy/v1 \
    VEKIL_MANAGED_OPENAI_BASE_URL=http://proxy/v1 \
    OPENAI_API_KEY=dummy \
    VEKIL_MANAGED_OPENAI_API_KEY=dummy \
    ANTHROPIC_BASE_URL=https://user.example \
    VEKIL_MANAGED_ANTHROPIC_BASE_URL=http://proxy \
    ANTHROPIC_API_KEY=dummy \
    VEKIL_MANAGED_ANTHROPIC_API_KEY=dummy \
    ANTHROPIC_MODEL=claude-opus-5 \
    VEKIL_MANAGED_ANTHROPIC_MODEL=claude-opus-5 \
    CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
    VEKIL_MANAGED_CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
    zsh -dfc '
      source "$DOTFILES/core/shell/zshrc.symlink" || exit 1
      print -r -- "${OPENAI_BASE_URL-unset}|${OPENAI_API_KEY-unset}|${ANTHROPIC_BASE_URL-unset}|${ANTHROPIC_API_KEY-unset}|${ANTHROPIC_MODEL-unset}|${CLAUDE_CODE_DISABLE_ADVISOR_TOOL-unset}"
      env | grep -E "^VEKIL_MANAGED_" || true
    '

  [ "$status" -eq 0 ]
  [[ "$output" == *"unset|unset|https://user.example|unset|unset|unset"* ]]
  [[ "$output" != *"VEKIL_MANAGED_"* ]]
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
