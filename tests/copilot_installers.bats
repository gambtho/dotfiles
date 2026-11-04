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
