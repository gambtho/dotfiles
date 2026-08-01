#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

make_validator_repo() {
  VALIDATOR_REPO="$TEST_ROOT/validator-repo"
  mkdir -p "$VALIDATOR_REPO/bin"
  cp "$REPO_ROOT/bin/validate-ai" "$VALIDATOR_REPO/bin/validate-ai"
  cp -a "$REPO_ROOT/ai" "$VALIDATOR_REPO/ai"
  git -C "$VALIDATOR_REPO" init -q
  git -C "$VALIDATOR_REPO" add ai bin/validate-ai
}

write_pi_skills() {
  local json="$1"
  local package="$VALIDATOR_REPO/ai/marketplace/plugins/my/package.json"
  local temporary="$package.tmp"
  jq --argjson skills "$json" '.pi.skills = $skills' "$package" >"$temporary"
  mv "$temporary" "$package"
}

@test "warnings do not abort validate-ai" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warnings:"* ]]
  [[ "$output" == *"PASSED"* ]]
}

@test "real Pi manifest is an exhaustive inventory of skills" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose

  [ "$status" -eq 0 ]
  [[ "$output" == *"package.json: exhaustive Pi skill inventory"* ]]
}

@test "validator rejects a nonexistent declared Pi skill" {
  make_validator_repo
  write_pi_skills '["./skills/not-real/SKILL.md"]'

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"declared Pi skill does not exist"* ]]
}

@test "validator rejects an actual skill omitted from Pi metadata" {
  make_validator_repo
  write_pi_skills '["./skills/improve/SKILL.md"]'

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi manifest omits skill"* ]]
}

@test "validator rejects Pi skill paths that escape the skills inventory" {
  make_validator_repo
  write_pi_skills '["../outside/SKILL.md"]'

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Pi skill path"* ]]
}

@test "validator rejects a broken tracked symlink" {
  make_validator_repo
  ln -s ../missing "$VALIDATOR_REPO/ai/marketplace/plugins/my/broken-link"
  git -C "$VALIDATOR_REPO" add ai/marketplace/plugins/my/broken-link

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked symlink does not resolve"* ]]
}
