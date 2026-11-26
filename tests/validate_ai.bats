#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

make_validator_repo() {
  VALIDATOR_REPO="$TEST_ROOT/validator-repo"
  mkdir -p "$VALIDATOR_REPO/libexec"
  cp "$REPO_ROOT/libexec/validate-ai" "$VALIDATOR_REPO/libexec/validate-ai"
  cp -a "$REPO_ROOT/ai" "$VALIDATOR_REPO/ai"
  git -C "$VALIDATOR_REPO" init -q
  git -C "$VALIDATOR_REPO" add ai libexec/validate-ai
}

@test "warnings do not abort validate-ai" {
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warnings:"* ]]
  [[ "$output" == *"PASSED"* ]]
}

@test "validator rejects a broken tracked symlink" {
  make_validator_repo
  ln -s ../missing "$VALIDATOR_REPO/ai/pi/broken-link"
  git -C "$VALIDATOR_REPO" add ai/pi/broken-link

  run bash "$VALIDATOR_REPO/libexec/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked symlink does not resolve"* ]]
}

@test "validator rejects a tracked symlink whose final target escapes the repository" {
  make_validator_repo
  printf 'outside\n' >"$TEST_ROOT/outside"
  ln -s "$TEST_ROOT/outside" "$VALIDATOR_REPO/ai/pi/outside-hop"
  ln -s outside-hop "$VALIDATOR_REPO/ai/pi/escaping-link"
  git -C "$VALIDATOR_REPO" add ai/pi/escaping-link

  run bash "$VALIDATOR_REPO/libexec/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked symlink resolves outside repository"* ]]
}

@test "validator checks every tracked Pi JSON baseline offline" {
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose

  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.json: valid JSON"* ]]
  [[ "$output" == *"keybindings.json: valid JSON"* ]]
  [[ "$output" == *"config/modes.json: valid JSON"* ]]
  [[ "$output" == *"config/file-context.json: valid JSON"* ]]
  [[ "$output" == *"config/permission-system.json: valid JSON"* ]]
  [[ "$output" != *"config/sandbox.json"* ]]
  [[ "$output" == *"config/subagents.json: valid JSON"* ]]
  [[ "$output" == *"config/web-search.json: valid JSON"* ]]
}

@test "validator rejects invalid tracked Pi JSON" {
  make_validator_repo
  printf '{invalid\n' >"$VALIDATOR_REPO/ai/pi/config/subagents.json"

  run bash "$VALIDATOR_REPO/libexec/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"config/subagents.json: invalid JSON"* ]]
}

@test "validator rejects credential-like web configuration properties" {
  make_validator_repo
  local web="$VALIDATOR_REPO/ai/pi/config/web-search.json"
  local temporary="$web.tmp"
  jq '.searchRouting.apiKey = ""' "$web" >"$temporary"
  mv "$temporary" "$web"

  run bash "$VALIDATOR_REPO/libexec/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-like property"* ]]
}

@test "validator rejects web provider shortcuts that bypass ordered routing" {
  local key
  for key in provider searchProvider; do
    make_validator_repo
    local web="$VALIDATOR_REPO/ai/pi/config/web-search.json"
    local temporary="$web.tmp"
    jq --arg key "$key" '.[$key] = "duckduckgo"' "$web" >"$temporary"
    mv "$temporary" "$web"

    run bash "$VALIDATOR_REPO/libexec/validate-ai"

    [ "$status" -ne 0 ]
    [[ "$output" == *"must not declare $key"* ]]
    rm -rf "$VALIDATOR_REPO"
  done
}

@test "validator avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/libexec/validate-ai"
  [ "$status" -eq 1 ]
}
