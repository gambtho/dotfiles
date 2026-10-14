#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  RUNTIME="$REPO_ROOT/ai/pi/paseo/runtime"
  VALIDATOR="$REPO_ROOT/libexec/validate-pi-paseo"
}

@test "retired Web UI backend is not shipped or callable through Make" {
  [ ! -e "$REPO_ROOT/ai/pi/webui" ]
  [ ! -e "$REPO_ROOT/libexec/validate-pi-webui" ]
  run make -n -C "$REPO_ROOT" ai-webui
  [ "$status" -ne 0 ]
  run make -n -C "$REPO_ROOT" ai-paseo-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"ai/pi/paseo/install.sh --check"* ]]
}

@test "Paseo runtime has a dedicated pin and does not bundle Pi" {
  run bash -c 'source "$1/config/versions.env"; test "${PASEO_VERSION:-}" = 0.11.2; test -z "${PI_VERSION+x}"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$RUNTIME/package.json" ]
  run jq -e '.name == "pi-paseo-runtime" and .dependencies == {"@getpaseo/cli":"0.11.2"}' "$RUNTIME/package.json"
  [ "$status" -eq 0 ]
  run jq -e '.lockfileVersion == 3 and .packages[""].dependencies == {"@getpaseo/cli":"0.11.2"} and .packages["node_modules/@getpaseo/cli"].version == "0.11.2" and .packages["node_modules/@earendil-works/pi-coding-agent"] == null' "$RUNTIME/package-lock.json"
  [ "$status" -eq 0 ]
}

@test "Paseo validator accepts the exact source runtime" {
  [ -f "$VALIDATOR" ]
  run bash "$VALIDATOR" --tracked-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"validated Paseo 0.11.2"* ]]
}

@test "Paseo validator refuses changed manifests locks and symlinked inputs" {
  [ -f "$VALIDATOR" ]
  local copy="$TEST_ROOT/runtime"
  mkdir "$copy"
  cp "$RUNTIME/"*.json "$copy/"
  printf '\n' >>"$copy/package.json"
  run bash "$VALIDATOR" --tracked-only "$copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest SHA-256"* ]]
  cp "$RUNTIME/package.json" "$copy/package.json"
  printf '\n' >>"$copy/package-lock.json"
  run bash "$VALIDATOR" --tracked-only "$copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock SHA-256"* ]]
  rm "$copy/package-lock.json"
  ln -s "$RUNTIME/package-lock.json" "$copy/package-lock.json"
  run bash "$VALIDATOR" --tracked-only "$copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regular file"* ]]
}

@test "Paseo installed validator refuses missing packages and linked roots" {
  [ -f "$VALIDATOR" ]
  local copy="$TEST_ROOT/runtime"
  mkdir "$copy"
  cp "$RUNTIME/"*.json "$copy/"
  run bash "$VALIDATOR" --installed-runtime "$copy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed Paseo"* ]]
  ln -s "$copy" "$TEST_ROOT/linked-runtime"
  run bash "$VALIDATOR" --installed-runtime "$TEST_ROOT/linked-runtime"
  [ "$status" -ne 0 ]
  [[ "$output" == *"real directory"* ]]
}
