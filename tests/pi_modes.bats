#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  MODES="$REPO_ROOT/ai/pi/modes.json"
  SETTINGS="$REPO_ROOT/ai/pi/settings.json"
}

@test "Pi defaults to the smart GPT-5.6 model" {
  run jq -e '
    .defaultProvider == "github-copilot"
    and .defaultModel == "gpt-5.6-sol"
    and .defaultThinkingLevel == "medium"
  ' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "Pi subagent modes use direct GitHub Copilot models" {
  run jq -e '
    .version == 1
    and .currentMode == "smart"
    and ([.modes[].provider] | all(. == "github-copilot"))
    and .modes.rush.modelId == "gpt-5.4-mini"
    and .modes.smart.modelId == "gpt-5.6-sol"
    and .modes.deep.modelId == "gpt-5.6-terra"
    and .modes.review.modelId == "claude-opus-5"
  ' "$MODES"
  [ "$status" -eq 0 ]
}

@test "Pi subagent modes increase reasoning with task complexity" {
  run jq -e '
    .modes.rush.thinkingLevel == "low"
    and .modes.smart.thinkingLevel == "medium"
    and .modes.deep.thinkingLevel == "high"
    and .modes.review.thinkingLevel == "high"
  ' "$MODES"
  [ "$status" -eq 0 ]
}

@test "PR review batches are partitioned by mode" {
  local prompt="$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md"
  run grep -F 'partition the selected PRs into `rush`, `smart`, and `deep` groups' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'never mix PRs requiring different modes in the same call' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'up to 2 tasks when `RATE_LIMITED=true`' "$prompt"
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

  run rg -n 'github-copilot/(claude-(haiku|sonnet)|gpt-5\\.6)' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills"
  [ "$status" -eq 1 ]
}
