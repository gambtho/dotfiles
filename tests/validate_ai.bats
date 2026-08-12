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

@test "project setup executable assets remain inside and linked from the canonical skill" {
  local skill="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup"

  [ -f "$skill/templates/local-seed.sh" ]
  [ -f "$skill/templates/compose-override.yml" ]
  # One grep per file, not one grep over both: a multi-file grep succeeds when
  # EITHER matches, so a reference dropped from SKILL.md would pass silently as
  # long as the other document still mentioned it.
  local doc
  for doc in "$skill/SKILL.md" "$skill/devcontainer-host-mounts.md"; do
    grep -Fq 'templates/local-seed.sh' "$doc"
    grep -Fq 'templates/compose-override.yml' "$doc"
    grep -Fq 'bin/claude-merge-compose-override' "$doc"
  done
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

@test "validator avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin/validate-ai"
  [ "$status" -eq 1 ]
}
