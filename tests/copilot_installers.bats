#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export TMPDIR="$TEST_ROOT/tmp"
  unset ALLOW_REMOTE_INSTALLERS
  mkdir -p "$TMPDIR"
  stub_command curl '
    [[ "$*" == "--fail --show-error --location --connect-timeout 10 --max-time 120 --retry 3 https://gh.io/copilot-install --output "* ]] || exit 91
    printf "downloaded\n" >>"$TEST_ROOT/downloads"
    cp "$TEST_ROOT/installer" "${!#}"
  '
}

@test "Copilot already installed is reused without download or execution" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexit 99\n' >"$HOME/.local/bin/copilot"
  chmod +x "$HOME/.local/bin/copilot"
  run bash "$REPO_ROOT/ai/copilot/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/downloads" ]
}

@test "Copilot rejects unsupported arguments before checking installation or causing side effects" {
  export ALLOW_REMOTE_INSTALLERS=1
  printf 'touch "$TEST_ROOT/executed"\n' >"$TEST_ROOT/installer"
  local state args
  for state in missing installed; do
    if [[ "$state" == installed ]]; then
      mkdir -p "$HOME/.local/bin"
      printf '#!/bin/sh\nexit 99\n' >"$HOME/.local/bin/copilot"
      chmod +x "$HOME/.local/bin/copilot"
    fi
    for args in --help --chekc --check-extra ''; do
      run bash "$REPO_ROOT/ai/copilot/install.sh" "$args"
      [ "$status" -eq 2 ]
      [[ "$output" == *"Usage:"* ]]
    done
    run bash "$REPO_ROOT/ai/copilot/install.sh" --check extra
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
    [ ! -e "$TEST_ROOT/downloads" ]
    [ ! -e "$TEST_ROOT/executed" ]
    [ -z "$(ls -A "$TMPDIR")" ]
    if [[ "$state" == missing ]]; then
      [ ! -e "$HOME/.local" ]
    fi
  done
}

@test "exact Copilot check is nonmutating with or without an installation" {
  run bash "$REPO_ROOT/ai/copilot/install.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [ ! -e "$HOME/.local" ]
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexit 99\n' >"$HOME/.local/bin/copilot"
  chmod +x "$HOME/.local/bin/copilot"
  run bash "$REPO_ROOT/ai/copilot/install.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [ ! -e "$TEST_ROOT/downloads" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "missing Copilot uses the official installer at the user prefix" {
  printf 'test "$PREFIX" = "$HOME/.local" && test "$VERSION" = latest || exit 92\nmkdir -p "$PREFIX/bin"\nprintf "#!/bin/sh\\nexit 0\\n" >"$PREFIX/bin/copilot"\nchmod +x "$PREFIX/bin/copilot"\n' >"$TEST_ROOT/installer"
  run bash "$REPO_ROOT/ai/copilot/install.sh"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_ROOT/downloads" ]
  export ALLOW_REMOTE_INSTALLERS=1
  run bash "$REPO_ROOT/ai/copilot/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/copilot" ]
  [ "$(wc -l <"$TEST_ROOT/downloads" | tr -d ' ')" -eq 1 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "Copilot installer failure propagates and cleans the downloaded script" {
  printf 'exit 42\n' >"$TEST_ROOT/installer"
  export ALLOW_REMOTE_INSTALLERS=1
  run bash "$REPO_ROOT/ai/copilot/install.sh"
  [ "$status" -eq 42 ]
  [ ! -e "$HOME/.local/bin/copilot" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
