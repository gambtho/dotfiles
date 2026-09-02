#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "Herdr prompt-state adapter behavior passes" {
  run node --test "$REPO_ROOT/tests/herdr_pi_prompt_state.test.mjs"

  [ "$status" -eq 0 ]
}
