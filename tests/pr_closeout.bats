#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  SKILL_DIR="$REPO_ROOT/ai/marketplace/plugins/my/skills/pr-closeout"
}

@test "pr-closeout is discoverable through the validated Pi package inventory" {
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:    pr-closeout/SKILL.md"* ]]
}

@test "pr-closeout snapshot helper is executable and prints usage" {
  [ -x "$SKILL_DIR/scripts/pr_snapshot.sh" ]
  run "$SKILL_DIR/scripts/pr_snapshot.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: pr_snapshot.sh"* ]]
}

@test "pr-closeout drafts human replies and keeps repo-specific commands out" {
  run grep -c "Human threads" "$SKILL_DIR/SKILL.md"
  [ "$output" -ge 1 ]
  run grep -E "make lint-fix|bun run" "$SKILL_DIR/SKILL.md"
  [ "$status" -ne 0 ]
}
