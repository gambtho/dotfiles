#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "warnings do not abort validate-ai" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warnings:"* ]]
  [[ "$output" == *"PASSED"* ]]
}
