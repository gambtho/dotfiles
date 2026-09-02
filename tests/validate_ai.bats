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

write_pi_inventory() {
  local kind="$1" json="$2"
  local package="$VALIDATOR_REPO/ai/marketplace/plugins/my/package.json"
  local temporary="$package.tmp"
  jq --arg kind "$kind" --argjson values "$json" '.pi[$kind] = $values' "$package" >"$temporary"
  mv "$temporary" "$package"
}

write_pi_skills() {
  write_pi_inventory skills "$1"
}

write_pi_prompts() {
  write_pi_inventory prompts "$1"
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
  [[ "$output" == *"package.json: exhaustive Pi skills inventory"* ]]
}

@test "real Pi manifest is an exhaustive inventory of prompts" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose

  [ "$status" -eq 0 ]
  [[ "$output" == *"package.json: exhaustive Pi prompts inventory"* ]]
}

@test "Jekyll gallery skill frontmatter has a scalar description" {
  local skill="$REPO_ROOT/ai/marketplace/plugins/my/skills/jekyll-media-gallery/SKILL.md"
  run grep -n '^description:.*: ' "$skill"
  [ "$status" -eq 1 ]
}

@test "validator rejects a nonexistent declared Pi skill" {
  make_validator_repo
  write_pi_skills '["./skills/not-real/SKILL.md"]'

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"declared Pi skill does not exist"* ]]
}

@test "validator rejects a nonexistent declared Pi prompt" {
  make_validator_repo
  write_pi_prompts '["./prompts/not-real.md"]'

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"declared Pi prompt does not exist"* ]]
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

@test "validator rejects a tracked symlink whose final target escapes the repository" {
  make_validator_repo
  printf 'outside\n' >"$TEST_ROOT/outside"
  ln -s "$TEST_ROOT/outside" "$VALIDATOR_REPO/ai/marketplace/plugins/my/outside-hop"
  ln -s outside-hop "$VALIDATOR_REPO/ai/marketplace/plugins/my/escaping-link"
  git -C "$VALIDATOR_REPO" add ai/marketplace/plugins/my/escaping-link

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked symlink resolves outside repository"* ]]
}

@test "validator checks every tracked Pi JSON baseline offline" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose

  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.json: valid JSON"* ]]
  [[ "$output" == *"keybindings.json: valid JSON"* ]]
  [[ "$output" == *"config/modes.json: valid JSON"* ]]
  [[ "$output" == *"config/permission-system.json: valid JSON"* ]]
  [[ "$output" == *"config/sandbox.json: valid JSON"* ]]
  [[ "$output" == *"config/subagents.json: valid JSON"* ]]
  [[ "$output" == *"config/web-search.json: valid JSON"* ]]
}

@test "validator rejects invalid tracked Pi JSON" {
  make_validator_repo
  printf '{invalid\n' >"$VALIDATOR_REPO/ai/pi/config/sandbox.json"

  run bash "$VALIDATOR_REPO/bin/validate-ai"

  [ "$status" -ne 0 ]
  [[ "$output" == *"config/sandbox.json: invalid JSON"* ]]
}

@test "validator rejects credential-like web configuration properties" {
  make_validator_repo
  local web="$VALIDATOR_REPO/ai/pi/config/web-search.json"
  local temporary="$web.tmp"
  jq '.searchRouting.apiKey = ""' "$web" >"$temporary"
  mv "$temporary" "$web"

  run bash "$VALIDATOR_REPO/bin/validate-ai"

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

    run bash "$VALIDATOR_REPO/bin/validate-ai"

    [ "$status" -ne 0 ]
    [[ "$output" == *"must not declare $key"* ]]
    rm -rf "$VALIDATOR_REPO"
  done
}

@test "validator avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin/validate-ai"
  [ "$status" -eq 1 ]
}
