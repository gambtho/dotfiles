#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "retired browser targets cannot provision a backend or gateway" {
  local target
  for target in ai-paseo ai-paseo-check ai-paseo-domain-check ai-paseo-domain-setup; do
    run make -n -C "$REPO_ROOT" "$target"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No rule to make target '$target'"* ]]
  done
}

@test "retired browser installers runtime and validator are absent" {
  local path
  for path in ai/pi/paseo libexec/validate-pi-paseo tests/pi_paseo.bats \
    tests/paseo_installers.bats tests/paseo_runtime.bats tests/paseo_helper.bash; do
    [ ! -e "$REPO_ROOT/$path" ]
  done
}

@test "old browser selection cannot re-enable browser provisioning through ordinary AI" {
  run bash -c 'DOTFILES_PASEO_ENABLED=1 make -n -C "$1" ai ai-check' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ai/pi/paseo/"* ]]
  [[ "$output" != *"pi-webui"* ]]
}
