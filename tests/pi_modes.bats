#!/usr/bin/env bats

load test_helper

setup() {
  local real_pi
  real_pi=$(command -v pi) || real_pi=""
  source "$BATS_TEST_DIRNAME/../libexec/lib/pi-runtime.sh"
  resolve_pi_runtime "$real_pi" "${PI_TEST_HOST_ROOT:-}"
  export HOST_ROOT=$PI_RUNTIME_PACKAGE_ROOT
  setup_dotfiles_test
  MODES="$REPO_ROOT/ai/pi/config/modes.json"
  SETTINGS="$REPO_ROOT/ai/pi/settings.json"
  AGENTS="$REPO_ROOT/ai/pi/agents"
}

agent_frontmatter() {
  awk 'NR == 1 { next } /^---$/ { exit } { print }' "$AGENTS/$1.md" | yq -o=json '.'
}

@test "modes fixture honors explicit SDK root when pi is absent from PATH" {
  stub_command pi 'exit 99'
  run command -v pi
  [ "$status" -eq 0 ]
  [ "$output" = "$STUB_BIN/pi" ]
  local no_pi_path="$TEST_ROOT/no-pi-bin" tool
  mkdir -p "$no_pi_path"
  for tool in bats bash env readlink dirname basename cat mkdir mktemp rm ln touch nl sort uniq cut grep node yq; do
    ln -s "$(command -v "$tool")" "$no_pi_path/$tool"
  done
  PATH="$no_pi_path" run command -v pi
  [ "$status" -ne 0 ]
  PATH="$no_pi_path" PI_TEST_HOST_ROOT="$HOST_ROOT" run bats --filter '^native Copilot compaction thresholds' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 native Copilot compaction"* ]]
  PATH="$no_pi_path" PI_TEST_HOST_ROOT="" run bats --filter '^native Copilot compaction thresholds' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi executable not found on PATH"* ]]
}

@test "Pi defaults to the smart GPT-6 model without restricting cycling" {
  run jq -e '
    .defaultProvider == "github-copilot"
    and .defaultModel == "gpt-6.1-sol"
    and .defaultThinkingLevel == "medium"
    and (has("enabledModels") | not)
  ' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "compaction uses safe fallbacks and exactly four selected-model overrides" {
  run jq -e '
    .compaction.enabled == true
    and .compaction.reserveTokens == 16384
    and .compaction.keepRecentTokens == 20000
    and .compaction.modelOverrides == {
      "github-copilot/gpt-6-luna": {"reserveTokens":650000,"keepRecentTokens":60000},
      "github-copilot/gpt-6.1-sol": {"reserveTokens":650000,"keepRecentTokens":60000},
      "github-copilot/gpt-6-astra": {"reserveTokens":650000,"keepRecentTokens":60000},
      "github-copilot/claude-opus-5.5": {"reserveTokens":650000,"keepRecentTokens":60000}
    }
    and .defaultTools == ["+codemode"]
    and .codemode == {"mode":"on"}
    and (has("lastChangelogVersion") | not)
  ' "$SETTINGS"
  [ "$status" -eq 0 ]
}

@test "native Copilot compaction thresholds remain positive and switch budgets by model" {
  run node --experimental-import-meta-resolve --input-type=module - "$HOST_ROOT" "$SETTINGS" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const entry = pathToFileURL(`${process.argv[2]}/dist/index.js`).href;
const { SettingsManager, shouldCompact } = await import(entry);
const { githubCopilotProvider } = await import(import.meta.resolve("@earendil-works/pi-ai/providers/github-copilot", entry));
const settings = SettingsManager.inMemory(JSON.parse(readFileSync(process.argv[3], "utf8")));
const catalog = githubCopilotProvider().getModels();
const selected = ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "claude-opus-5.5"];
const fallback = catalog.filter(model => model.type === "chat" && !selected.includes(model.id));
assert.ok(fallback.length > 0, "native catalog has no non-overridden chat models to test");
for (const [id, reserve, recent] of [
  ...selected.map(id => [id, 650000, 60000]),
  ...fallback.map(model => [model.id, 16384, 20000]),
]) {
  const model = catalog.find(model => model.id === id);
  assert.ok(model, `native catalog missing ${id}`);
  assert.equal(model.type, "chat");
  assert.equal(model.provider, "github-copilot");
  if (selected.includes(id)) assert.ok(model.contextWindow >= 1000000);
  const budget = settings.getCompactionSettings(model);
  assert.deepEqual(budget, { enabled: true, reserveTokens: reserve, keepRecentTokens: recent });
  const threshold = model.contextWindow - reserve;
  assert.ok(threshold > recent, `${id} has no positive usable context budget`);
  assert.equal(shouldCompact(0, model.contextWindow, budget), false);
  assert.equal(shouldCompact(threshold, model.contextWindow, budget), false);
  assert.equal(shouldCompact(threshold + 1, model.contextWindow, budget), true);
  console.log(`${id}: window=${model.contextWindow} reserve=${reserve} recent=${recent} threshold=${threshold}`);
}
assert.deepEqual(settings.getDefaultTools(), ["read", "bash", "edit", "write", "codemode"]);
assert.equal(settings.getGlobalSettings().codemode.mode, "on");
JS
  [ "$status" -eq 0 ]
}

@test "Pi subagent modes use direct GitHub Copilot models" {
  run jq -e '
    .version == 1
    and .currentMode == "smart"
    and ([.modes[].provider] | all(. == "github-copilot"))
    and .modes.rush.modelId == "gpt-6-luna"
    and .modes.smart.modelId == "gpt-6.1-sol"
    and .modes.deep.modelId == "gpt-6-astra"
    and .modes.review.modelId == "claude-opus-5.5"
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

@test "Pi inspector uses standard reasoning with deep-equivalent restrictions" {
  local expected actual
  expected=$(agent_frontmatter deep)
  actual=$(agent_frontmatter inspector)
  run jq -e --argjson expected "$expected" '
    .model == "github-copilot/gpt-6.1-sol" and .thinking == "medium"
    and .tools == $expected.tools and .permission == $expected.permission
    and .prompt_mode == "append"
  ' <<<"$actual"
  [ "$status" -eq 0 ]
}

@test "Pi named agents declare complete tool allowlists" {
  local agent actual
  for agent in rush inspector deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '.tools == "read, bash, grep, find, ls, codemode"' <<<"$actual"
    [ "$status" -eq 0 ]
  done

  actual=$(agent_frontmatter smart)
  run jq -e '.tools == "read, write, edit, bash, grep, find, ls, codemode"' <<<"$actual"
  [ "$status" -eq 0 ]
}

@test "Pi read-oriented agents restrict direct tools and recognizable mutation" {
  local agent actual
  for agent in rush inspector deep review; do
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

@test "Pi read-oriented agents keep metadata approvals without remote Git overrides" {
  local agent actual
  for agent in rush inspector deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e '
      .permission.bash as $bash
      | all([
          "printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL",
          "printenv XDG_CONFIG_HOME PI_CODING_AGENT_DIR",
          "/usr/bin/printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL",
          "/usr/bin/printenv XDG_CONFIG_HOME PI_CODING_AGENT_DIR"
        ][]; . as $command | $bash[$command] == "allow"
          and ($bash | has($command + "*") | not))
      and ([$bash | keys[] | select(contains("ls-remote"))] | length == 0)
      and ($bash | has("gh api *") | not)
      and ($bash | has("*/gh api *") | not)
      and $bash["*git *"] == "deny" and $bash["*$*"] == "deny"
    ' <<<"$actual"
    [ "$status" -eq 0 ]
  done
}

@test "Pi read-oriented agent permissions stay structurally identical" {
  local agent actual expected
  expected=$(agent_frontmatter rush | jq -c '.permission')

  for agent in inspector deep review; do
    actual=$(agent_frontmatter "$agent")
    run jq -e --argjson expected "$expected" '.permission == $expected' <<<"$actual"
    [ "$status" -eq 0 ]
  done
}

@test "Pi read-oriented agents scope the complete direct Git reader allowlist" {
  local agent actual
  for agent in rush inspector deep review; do
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
  run grep -F 'partition the selected PRs into `rush`, `inspector` and `deep` groups' "$prompt"
  [ "$status" -eq 0 ]
  run grep -F '| Medium | `inspector` |' "$prompt"
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
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/second-opinion-core/SKILL.md" \
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
  local prompt="$REPO_ROOT/ai/marketplace/plugins/my/skills/second-opinion-core/SKILL.md"
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
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts/fix-pr.md"; do
    run grep -F 'subagent_type: deep' "$workflow"
    [ "$status" -eq 0 ]
    run grep -F 'subagent_type: smart' "$workflow"
    [ "$status" -eq 1 ]
  done

  run grep -F 'subagent_type: inspector' "$REPO_ROOT/ai/marketplace/plugins/my/skills/polish-core/SKILL.md"
  [ "$status" -eq 0 ]
  run rg -n 'subagent_type: deep' \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills/improve/references/platforms.md"
  [ "$status" -eq 0 ]

  run rg -n 'github-copilot/(claude-(haiku|sonnet)|gpt-5\.6)' \
    "$REPO_ROOT/ai/marketplace/plugins/my/prompts" \
    "$REPO_ROOT/ai/marketplace/plugins/my/skills"
  [ "$status" -eq 1 ]
}
