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

@test "the projectmux phase runs after the dev phase" {
  list_phases
  [ "$status" -eq 0 ]
  local dev_line projectmux_line
  dev_line=$(grep -n 'optional dev$' <<<"$output" | cut -d: -f1)
  projectmux_line=$(grep -n 'optional projectmux$' <<<"$output" | cut -d: -f1)
  [ -n "$dev_line" ]
  [ -n "$projectmux_line" ]
  [ "$projectmux_line" -gt "$dev_line" ]
}

@test "the phase points at the installer this repo ships" {
  run rg -n 'run_phase optional projectmux bash "\$DOTFILES_ROOT/tools/projectmux/install\.sh"' \
    "$REPO_ROOT/bin/install"
  [ "$status" -eq 0 ]
  [ -x "$REPO_ROOT/tools/projectmux/install.sh" ]
}
