#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "Herdr agent-state session paths pass" {
  run node --test "$REPO_ROOT/tests/herdr_pi_agent_state.test.mjs"

  [ "$status" -eq 0 ]
}
