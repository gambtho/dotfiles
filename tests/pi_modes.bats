#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  MODES="$REPO_ROOT/ai/pi/modes.json"
}

@test "Pi subagent modes use direct GitHub Copilot models" {
  run jq -e '
    .version == 1
    and .currentMode == "smart"
    and ([.modes[].provider] | all(. == "github-copilot"))
    and .modes.rush.modelId == "claude-haiku-4.5"
    and .modes.smart.modelId == "claude-sonnet-4.6"
    and .modes.deep.modelId == "claude-opus-4.7"
    and .modes.review.modelId == "gpt-5.4"
  ' "$MODES"
  [ "$status" -eq 0 ]
}

@test "Pi subagent modes increase reasoning with task complexity" {
  run jq -e '
    .modes.rush.thinkingLevel == "low"
    and .modes.smart.thinkingLevel == "medium"
    and .modes.deep.thinkingLevel == "high"
    and .modes.review.thinkingLevel == "medium"
  ' "$MODES"
  [ "$status" -eq 0 ]
}

@test "personal workflows route through named modes instead of hard-coded routine models" {
  run rg -n 'mode `smart`' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  [ "$status" -eq 0 ]

  run rg -n 'mode `deep`' \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 0 ]

  run rg -n 'github-copilot/claude-(haiku|sonnet)' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills"
  [ "$status" -eq 1 ]
}
