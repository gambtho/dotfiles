#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

# Sourcing bin/install with INSTALL_SOURCE_ONLY=1 defines main without running
# it; overriding run_phase turns the phase list into observable output.
list_phases() {
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/install"
    run_phase() { printf "%s %s\n" "$1" "$2"; }
    setup_ai() { :; }
    finish_phases() { :; }
    log_success() { :; }
    OS=Ubuntu
    PROFILE=personal
    main
  ' _ "$REPO_ROOT"
}

@test "the projectmux phase is registered" {
  list_phases
  [ "$status" -eq 0 ]
  [[ "$output" == *"projectmux"* ]]
}

@test "the projectmux phase is optional" {
  list_phases
  [ "$status" -eq 0 ]
  [[ "$output" == *"optional projectmux"* ]]
}

@test "the dev phase is gone" {
  # tools/dev/ was removed in design §13 step 8; a phase pointing at a deleted
  # installer would fail every install as an "optional phase failed" warning.
  list_phases
  [ "$status" -eq 0 ]
  [[ "$output" != *"optional dev"* ]]
}

@test "the phase points at the installer this repo ships" {
  run rg -n 'run_phase optional projectmux bash "\$DOTFILES_ROOT/tools/projectmux/install\.sh"' \
    "$REPO_ROOT/bin/install"
  [ "$status" -eq 0 ]
  [ -x "$REPO_ROOT/tools/projectmux/install.sh" ]
}
