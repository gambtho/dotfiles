#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "versions list shows mise and non-mise pins" {
  run bash "$REPO_ROOT/bin/versions" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise go 1.25.12"* ]]
  [[ "$output" == *"git prezto 9739c8bdc9c288ffc134c209225543180e32ff69"* ]]
  [[ "$output" == *"channel kubernetes v1.28"* ]]
}

@test "versions check fails when mise cannot check pins" {
  stub_command mise 'exit 1'
  stub_command git 'printf "unrelated-ref\\n"'
  stub_command curl 'printf "v1.28.0\\n"'

  run bash "$REPO_ROOT/bin/versions" check
  [ "$status" -ne 0 ]
}

@test "non-mise pins have one canonical manifest" {
  run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL)=' "$REPO_ROOT" \
    --glob '!docs/**' --glob '!tests/**'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/config/versions.env" ]
}

@test "versions rejects unknown commands" {
  run bash "$REPO_ROOT/bin/versions" unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
