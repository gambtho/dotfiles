#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  MODES="$REPO_ROOT/ai/pi/config/modes.json"
  SETTINGS="$REPO_ROOT/ai/pi/settings.json"
  AGENTS="$REPO_ROOT/ai/pi/agents"
}

agent_frontmatter() {
  awk 'NR == 1 { next } /^---$/ { exit } { print }' "$AGENTS/$1.md" | yq -o=json '.'
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

@test "Pi named agents match the tracked mode routing" {
  local agent expected_model expected_thinking actual
  for agent in rush smart deep review; do
    expected_model=$(jq -r --arg agent "$agent" \
      '"\(.modes[$agent].provider)/\(.modes[$agent].modelId)"' "$MODES")
    expected_thinking=$(jq -r --arg agent "$agent" \
      '.modes[$agent].thinkingLevel' "$MODES")
    actual=$(agent_frontmatter "$agent")

    run jq -e \
      --arg model "$expected_model" \
      --arg thinking "$expected_thinking" \
      '.model == $model and .thinking == $thinking and .prompt_mode == "append"' \
      <<<"$actual"
    [ "$status" -eq 0 ]
  done
}

@test "Pi named agents declare complete tool allowlists" {
  local agent actual
  for agent in rush deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '.tools == "read, bash, grep, find, ls"' <<<"$actual"
    [ "$status" -eq 0 ]
  done

  actual=$(agent_frontmatter smart)
  run jq -e '.tools == "read, write, edit, bash, grep, find, ls"' <<<"$actual"
  [ "$status" -eq 0 ]
}

@test "Pi read-only agents preserve hard GitHub denies without a broad override" {
  local agent actual
  for agent in rush deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '
      .permission.path_write == "deny"
      and .permission.write == "deny"
      and .permission.edit == "deny"
      and (.permission.bash | has("gh *") | not)
      and (.permission.bash as $bash
        | all([
            "gh auth status*",
            "gh repo view*",
            "gh pr list*",
            "gh pr view*",
            "gh pr checks*",
            "gh issue list*",
            "gh issue view*",
            "gh run list*",
            "gh run view*"
          ][]; . as $pattern | $bash[$pattern] == "ask"))
      and .permission.bash["gh repo delete*"] == "deny"
      and .permission.bash["gh api * --method DELETE*"] == "deny"
      and .permission.bash["*$*"] == "deny"
    ' <<<"$actual"
    [ "$status" -eq 0 ]
  done

  actual=$(agent_frontmatter smart)
  run jq -e '.permission == {"bash": {"*$*": "deny"}}' <<<"$actual"
  [ "$status" -eq 0 ]
}

@test "PR review fan-out is partitioned by named agent type" {
  local prompt="$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md"
  run grep -F 'partition the selected PRs into `rush`, `smart`, and `deep` groups' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'never mix PRs requiring different `subagent_type` values' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'up to 2 sibling calls when `RATE_LIMITED=true`' "$prompt"
  [ "$status" -eq 0 ]
}

@test "Pi workflows contain no Amp batch or mode contract" {
  run rg -n 'tasks:|one `subagent` tool call|mode `(rush|smart|deep|review)`|one parallel call' \
    "$REPO_ROOT/ai/pi/AGENTS.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/second-opinion.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 1 ]
}

@test "Pi fan-out workflows dispatch sibling agents and poll without blocking" {
  local workflow
  for workflow in \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"; do
    run grep -F 'run_in_background: true' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'get_subagent_result' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'wait: false' "$workflow"
    [ "$status" -eq 0 ]
  done

  run rg -n 'wait: true|after (90 seconds|5 minutes)|agent timed out' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 1 ]
}

@test "second opinion dispatches one described named reviewer" {
  local prompt="$REPO_ROOT/ai/marketplace/plugins/my/prompts/second-opinion.md"
  run grep -F 'subagent_type: review' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'subagent_type: deep' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'description' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F 'one foreground `subagent` call' "$prompt"
  [ "$status" -eq 0 ]
}

@test "personal workflows route through named agent types" {
  run rg -n 'subagent_type: smart' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  [ "$status" -eq 0 ]

  run rg -n 'subagent_type: deep' \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 0 ]

  run rg -n 'github-copilot/(claude-(haiku|sonnet)|gpt-5\.6)' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills"
  [ "$status" -eq 1 ]
}
