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

@test "Pi read-oriented agents restrict direct tools and recognizable mutation" {
  local agent actual
  for agent in rush deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '
      (.permission | has("path_write") | not)
      and .permission.write == "deny"
      and .permission.edit == "deny"
      and .permission.bash["*"] == "allow"
      and .permission.bash["*git *"] == "deny"
      and .permission.bash["*$*"] == "deny"
      and (.permission.bash as $bash
        | all([
            "git status*",
            "git show*",
            "git diff*",
            "git log*",
            "git grep*",
            "git rev-parse*",
            "git branch --show-current*",
            "git worktree list*",
            "gh auth status*",
            "gh repo view*",
            "gh pr list*",
            "gh pr view*",
            "gh pr checks*",
            "gh issue list*",
            "gh issue view*",
            "gh run list*",
            "gh run view*"
          ][]; . as $pattern | $bash[$pattern] == "allow"))
      and (.permission.bash as $bash
        | all([
            "*git *show *--ext-d*",
            "*git *show *--textc*",
            "*git *diff *--ext-d*",
            "*git *diff *--textc*",
            "*git *log *--ext-d*",
            "*git *log *--textc*",
            "git grep -O*",
            "git grep -nO*",
            "git grep -inO*",
            "git grep -nHO*",
            "git grep * -O*",
            "git grep * -nO*",
            "git grep * -inO*",
            "git grep * -nHO*",
            "git grep --open*",
            "git grep * --open*",
            "git grep --op=*",
            "git grep * --op=*",
            "*gh pr create*",
            "*gh pr edit*",
            "*gh pr merge*",
            "*gh issue create*",
            "*gh issue edit*",
            "*gh issue close*",
            "*gh repo delete*",
            "*gh api * --method DELETE*",
            "*$*"
          ][]; . as $pattern | $bash[$pattern] == "deny"))
      and (.permission.bash as $bash
        | all(["*git *grep -*O*", "*git *grep * -*O*", "*git *grep *--op*"][];
            . as $pattern | $bash | has($pattern) | not))
      and (.permission.bash as $bash
        | all(["make *", "npm *", "pnpm *", "cargo *", "go *"][];
            . as $pattern | $bash | has($pattern) | not))
    ' <<<"$actual"
    [ "$status" -eq 0 ]
  done

  actual=$(agent_frontmatter smart)
  run jq -e '.permission == {"bash": {"*$*": "deny"}}' <<<"$actual"
  [ "$status" -eq 0 ]
}

@test "Pi read-oriented agent permissions stay structurally identical" {
  local agent actual expected
  expected=$(agent_frontmatter rush | jq -c '.permission')

  for agent in deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e --argjson expected "$expected" '.permission == $expected' <<<"$actual"
    [ "$status" -eq 0 ]
  done
}

@test "Pi read-oriented agents scope the complete direct Git reader allowlist" {
  local agent actual
  for agent in rush deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '
      def direct_read_rules: [
        "git status*",
        "git show*",
        "git diff*",
        "git log*",
        "git grep*",
        "git rev-parse*",
        "git merge-base*",
        "git branch --show-current*",
        "git branch --list*",
        "git branch --merged*",
        "git worktree list*",
        "git blame*",
        "git describe*",
        "git shortlog*",
        "git name-rev*",
        "git ls-files*",
        "git ls-tree*",
        "git cat-file*",
        "git for-each-ref*",
        "git check-ignore*",
        "git check-attr*",
        "git range-diff*",
        "git fsck*",
        "git count-objects*",
        "git reflog show*",
        "git submodule status*",
        "git remote -v",
        "git remote get-url*",
        "git config --get*",
        "git config --get-regexp*",
        "git config --list*",
        "git config -l*"
      ];
      def scoped_read_rules: [
        "git -C ?* status*",
        "git -C ?* show*",
        "git -C ?* diff*",
        "git -C ?* log*",
        "git -C ?* grep*",
        "git -C ?* rev-parse*",
        "git -C ?* merge-base*",
        "git -C ?* branch --show-current*",
        "git -C ?* branch --list*",
        "git -C ?* branch --merged*",
        "git -C ?* worktree list*",
        "git -C ?* blame*",
        "git -C ?* describe*",
        "git -C ?* shortlog*",
        "git -C ?* name-rev*",
        "git -C ?* ls-files*",
        "git -C ?* ls-tree*",
        "git -C ?* cat-file*",
        "git -C ?* for-each-ref*",
        "git -C ?* check-ignore*",
        "git -C ?* check-attr*",
        "git -C ?* range-diff*",
        "git -C ?* fsck*",
        "git -C ?* count-objects*",
        "git -C ?* reflog show*",
        "git -C ?* submodule status*",
        "git -C ?* remote -v",
        "git -C ?* remote get-url*",
        "git -C ?* config --get*",
        "git -C ?* config --get-regexp*",
        "git -C ?* config --list*",
        "git -C ?* config -l*"
      ];
      def git_tripwire_rules: [
        "git show *--ext-d*",
        "git show *--textc*",
        "git diff *--ext-d*",
        "git diff *--textc*",
        "git log *--ext-d*",
        "git log *--textc*",
        "git -C ?* show *--ext-d*",
        "git -C ?* show *--textc*",
        "git -C ?* diff *--ext-d*",
        "git -C ?* diff *--textc*",
        "git -C ?* log *--ext-d*",
        "git -C ?* log *--textc*",
        "*git *show *--ext-d*",
        "*git *show *--textc*",
        "*git *diff *--ext-d*",
        "*git *diff *--textc*",
        "*git *log *--ext-d*",
        "*git *log *--textc*",
        "git grep -O*",
        "git grep -nO*",
        "git grep -inO*",
        "git grep -nHO*",
        "git grep * -O*",
        "git grep * -nO*",
        "git grep * -inO*",
        "git grep * -nHO*",
        "git grep --open*",
        "git grep * --open*",
        "git grep --op=*",
        "git grep * --op=*",
        "git -C ?* grep -O*",
        "git -C ?* grep -nO*",
        "git -C ?* grep -inO*",
        "git -C ?* grep -nHO*",
        "git -C ?* grep * -O*",
        "git -C ?* grep * -nO*",
        "git -C ?* grep * -inO*",
        "git -C ?* grep * -nHO*",
        "git -C ?* grep --open*",
        "git -C ?* grep * --open*",
        "git -C ?* grep --op=*",
        "git -C ?* grep * --op=*"
      ];
      .permission.bash as $bash
      | ($bash | keys_unsorted) as $keys
      | $bash["*git *"] == "deny"
      and (direct_read_rules
        | all(.[]; . as $pattern | $bash[$pattern] == "allow"))
      and (scoped_read_rules
        | all(.[]; . as $pattern | $bash[$pattern] == "allow"))
      and (git_tripwire_rules
        | all(.[]; . as $pattern | $bash[$pattern] == "deny"))
      and (scoped_read_rules
        | all(.[]; . as $pattern
          | ($keys | index($pattern)) > ($keys | index("*git *"))))
      and (([direct_read_rules[] as $pattern | $keys | index($pattern)] | max)
        < ([scoped_read_rules[] as $pattern | $keys | index($pattern)] | min))
      and (([scoped_read_rules[] as $pattern | $keys | index($pattern)] | max)
        < ([git_tripwire_rules[] as $pattern | $keys | index($pattern)] | min))
    ' <<<"$actual"
    [ "$status" -eq 0 ]
  done
}

@test "PR review fan-out uses only read-only named agent types" {
  local prompt="$REPO_ROOT/ai/marketplace/plugins/my/prompts/review-prs.md"
  run grep -F 'partition the selected PRs into `rush` and `deep` groups' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F '| Medium | `deep` |' "$prompt"
  [ "$status" -eq 0 ]
  run rg -n 'subagent_type: smart|`smart` group|`rush`, `smart`' "$prompt"
  [ "$status" -eq 1 ]
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

@test "personal workflows route review-only work through read-only agents" {
  local workflow
  for workflow in \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"; do
    run grep -F 'subagent_type: deep' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'subagent_type: smart' "$workflow"
    [ "$status" -eq 1 ]
  done

  run rg -n 'subagent_type: deep' \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 0 ]

  run rg -n 'github-copilot/(claude-(haiku|sonnet)|gpt-5\.6)' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills"
  [ "$status" -eq 1 ]
}
