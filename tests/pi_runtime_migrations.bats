#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export AGENT="$TEST_ROOT/agent" OWNED="$TEST_ROOT/owned"
  mkdir -p "$AGENT" "$OWNED/ai/pi/config"
  export PI_AI_REFRESH_PREFERENCES=0
  printf '{"providers":{"github-copilot":{"models":[{"id":"gpt-6-astra","api":"openai-responses"}]}}}\n' >"$OWNED/ai/pi/config/models.json"
}

migration() {
  run bash -c '
    set -euo pipefail
    installer=$(<"$REPO_ROOT/ai/pi/install.sh")
    installer=${installer%$'\''\nmain "$@"'\''}
    eval "$installer"
    [[ ! -f "$ROOT/ai/pi/migrate-runtime-config.sh" ]] || source "$ROOT/ai/pi/migrate-runtime-config.sh"
    PI_AGENT_DIR=$AGENT
    MANAGED_SOURCE_ROOTS=("$OWNED" "$REPO_ROOT")
    MODE=${TEST_MODE:-apply}
    "$@"
  ' "$REPO_ROOT/ai/pi/install.sh" "$@"
}

snapshot() {
  {
    find "$AGENT" -printf '%y %m %P -> %l\n'
    find "$AGENT" -type f -exec sha256sum {} +
  } | sort
}

seed_preferences() {
  # Independent future-baseline literals, not rendered by the migration code.
  printf '%s\n' '{"defaultProvider":"github-copilot","defaultModel":"gpt-6.1-sol","defaultTools":["+codemode"],"codemode":{"mode":"on"},"compaction":{"enabled":true,"reserveTokens":16384,"keepRecentTokens":20000,"modelOverrides":{"github-copilot/gpt-6-luna":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/gpt-6.1-sol":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/gpt-6-astra":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/claude-opus-5.5":{"reserveTokens":650000,"keepRecentTokens":60000}}}}' >"$TEST_ROOT/settings-baseline.json"
  printf '%s\n' '{"modes":{"rush":{"provider":"github-copilot","modelId":"gpt-6-luna"},"smart":{"provider":"github-copilot","modelId":"gpt-6.1-sol"},"deep":{"provider":"github-copilot","modelId":"gpt-6-astra"},"review":{"provider":"github-copilot","modelId":"claude-opus-5.5"}}}' >"$TEST_ROOT/modes-baseline.json"
  printf '%s\n' '{"defaultProvider":"github-copilot","defaultModel":"gpt-5.6-sol","theme":"custom","defaultTools":["read","+custom","-codemode"],"codemode":{"mode":"only","inlineBudget":1234},"compaction":{"enabled":false,"reserveTokens":650000,"keepRecentTokens":60000,"extra":"keep","modelOverrides":{"custom/model":{"reserveTokens":321},"github-copilot/gpt-6-astra":{"reserveTokens":42,"extra":true}}},"unrelated":{"keep":true}}' >"$AGENT/settings.json"
  printf '%s\n' '{"currentMode":"custom","modes":{"rush":{"provider":"github-copilot","modelId":"gpt-5.4-mini","color":"pink","extra":true},"smart":{"provider":"github-copilot","modelId":"gpt-5.6-sol"},"deep":{"provider":"github-copilot","modelId":"gpt-5.6-terra"},"review":{"provider":"github-copilot","modelId":"claude-opus-5"},"custom":{"provider":"other","modelId":"custom","color":"red"}}}' >"$AGENT/modes.json"
}

refresh() {
  migration refresh_pi_preferences "$AGENT/settings.json" "$AGENT/modes.json" "$TEST_ROOT/settings-baseline.json" "$TEST_ROOT/modes-baseline.json"
}

@test "Astra-only override is privately backed up and deleted once with receipt" {
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT/models.json" ]
  cmp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json.backup"
  [ "$(stat -c %a "$AGENT/models.json.backup")" = 600 ]
  [ "$(stat -c %a "$AGENT/dotfiles-migrations.json")" = 600 ]
  jq -e '.astraOverrideRetired == true' "$AGENT/dotfiles-migrations.json"
  local before
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  cmp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
}

@test "Astra retirement preserves other models providers and root or provider metadata" {
  printf '%s\n' '{"root":{"keep":true},"providers":{"github-copilot":{"baseUrl":"custom","models":[{"id":"gpt-6-astra"},{"id":"user-model","extra":true}]},"other":{"models":[{"id":"gpt-6-astra"}]}}}' >"$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  jq -e '.root.keep == true and .providers["github-copilot"].baseUrl == "custom" and .providers["github-copilot"].models == [{"id":"user-model","extra":true}] and .providers.other.models == [{"id":"gpt-6-astra"}]' "$AGENT/models.json"
  rm "$AGENT/dotfiles-migrations.json"
  printf '{"providers":{"github-copilot":{"baseUrl":"keep","models":[{"id":"gpt-6-astra"}]}}}\n' >"$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  jq -e '.providers["github-copilot"] == {"baseUrl":"keep"}' "$AGENT/models.json"
}

@test "Astra retirement converts readable owned links and removes retired dangling owned links" {
  printf '{"custom":true,"providers":{"github-copilot":{"models":[{"id":"gpt-6-astra"}]}}}\n' >"$OWNED/ai/pi/config/models.json"
  ln -s "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  [ ! -L "$AGENT/models.json" ]
  jq -e '.custom == true and (has("providers") | not)' "$AGENT/models.json"
  cmp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json.backup"
  rm "$AGENT/models.json" "$AGENT/dotfiles-migrations.json" "$OWNED/ai/pi/config/models.json"
  ln -s "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  [ ! -L "$AGENT/models.json" ]
}

@test "Astra retirement refuses foreign links invalid JSON and malformed targeted structures without receipt" {
  printf '{not-json\n' >"$TEST_ROOT/foreign.json"
  ln -s "$TEST_ROOT/foreign.json" "$AGENT/models.json"
  local before
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *foreign*symlink* ]]
  [ "$before" = "$(snapshot)" ]
  rm "$AGENT/models.json"
  local value
  for value in '{bad' '[]' '{"providers":{"github-copilot":{"models":{}}}}'; do
    printf '%s\n' "$value" >"$AGENT/models.json"
    before=$(snapshot)
    migration retire_astra_override "$AGENT/models.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *JSON* || "$output" == *structure* ]]
    [ "$before" = "$(snapshot)" ]
    [ ! -e "$AGENT/dotfiles-migrations.json" ]
  done
}

@test "Astra publication failure never records completion and rollback includes receipt" {
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  printf '{"prior":"keep"}\n' >"$AGENT/dotfiles-migrations.json"
  migration eval 'atomic_publish_file() { return 45; }; retire_astra_override "$PI_AGENT_DIR/models.json"'
  [ "$status" -ne 0 ]
  jq -e '.prior == "keep" and (has("astraOverrideRetired") | not)' "$AGENT/dotfiles-migrations.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  cmp <(printf '{"prior":"keep"}\n') "$AGENT/dotfiles-migrations.json.backup"
  [ "$(stat -c %a "$AGENT/dotfiles-migrations.json.backup")" = 600 ]
  cp "$AGENT/models.json.backup" "$AGENT/models.json"
  cp "$AGENT/dotfiles-migrations.json.backup" "$AGENT/dotfiles-migrations.json"
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  [ ! -e "$AGENT/models.json" ]
}

@test "migrations refuse runtime races before replacement and never complete Astra receipt" {
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  migration eval '
    original=$(declare -f backup_regular_contents)
    eval "${original/backup_regular_contents/original_backup}"
    backup_regular_contents() { original_backup "$@"; printf "{\"runtime\":true}\n" >"$1"; }
    retire_astra_override "$PI_AGENT_DIR/models.json"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *changed*during* ]]
  jq -e '.runtime == true' "$AGENT/models.json"
  [ ! -e "$AGENT/dotfiles-migrations.json" ]
}

@test "Astra retirement rejects multiple JSON documents and unsafe receipt destinations" {
  printf '{}\n{}\n' >"$AGENT/models.json"
  local before
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *Invalid*JSON* ]]
  [ "$before" = "$(snapshot)" ]
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  printf '{broken\n' >"$AGENT/dotfiles-migrations.json"
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *Invalid*JSON* ]]
  [ "$before" = "$(snapshot)" ]
  rm "$AGENT/dotfiles-migrations.json"
  ln -s "$TEST_ROOT/foreign-receipt" "$AGENT/dotfiles-migrations.json"
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *foreign*symlink* ]]
  [ "$before" = "$(snapshot)" ]
}

@test "refresh is opt-in and ordinary reconciliation preserves later preference drift" {
  seed_preferences
  local before
  before=$(snapshot)
  refresh
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
  export PI_AI_REFRESH_PREFERENCES=1
  refresh
  [ "$status" -eq 0 ]
  local candidate="$TEST_ROOT/drift.json"
  jq '.defaultModel="custom" | .codemode.mode="only"' "$AGENT/settings.json" >"$candidate"
  mv "$candidate" "$AGENT/settings.json"
  export PI_AI_REFRESH_PREFERENCES=0
  before=$(snapshot)
  refresh
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "explicit refresh selectively upgrades legacy roles compaction and Codemode preserving extras" {
  seed_preferences
  export PI_AI_REFRESH_PREFERENCES=1
  refresh
  [ "$status" -eq 0 ]
  jq -e '.defaultModel == "gpt-6.1-sol" and .theme == "custom" and .unrelated.keep and .codemode == {"mode":"on","inlineBudget":1234} and .defaultTools == ["read","+custom","-codemode","+codemode"] and .compaction.enabled == false and .compaction.reserveTokens == 16384 and .compaction.keepRecentTokens == 20000 and .compaction.extra == "keep" and .compaction.modelOverrides["custom/model"].reserveTokens == 321 and .compaction.modelOverrides["github-copilot/gpt-6-astra"] == {"reserveTokens":42,"keepRecentTokens":60000,"extra":true} and .compaction.modelOverrides["github-copilot/gpt-6-luna"] == {"reserveTokens":650000,"keepRecentTokens":60000} and .compaction.modelOverrides["github-copilot/gpt-6.1-sol"] == {"reserveTokens":650000,"keepRecentTokens":60000} and .compaction.modelOverrides["github-copilot/claude-opus-5.5"] == {"reserveTokens":650000,"keepRecentTokens":60000}' "$AGENT/settings.json"
  jq -e '.currentMode == "custom" and .modes.rush == {"provider":"github-copilot","modelId":"gpt-6-luna","color":"pink","extra":true} and .modes.smart.modelId == "gpt-6.1-sol" and .modes.deep.modelId == "gpt-6-astra" and .modes.review.modelId == "claude-opus-5.5" and .modes.custom == {"provider":"other","modelId":"custom","color":"red"}' "$AGENT/modes.json"
  [ "$(stat -c %a "$AGENT/settings.json.backup")" = 600 ]
  [ "$(stat -c %a "$AGENT/modes.json.backup")" = 600 ]
  local before
  before=$(snapshot)
  refresh
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "refresh adds compaction overrides when the old settings have none" {
  seed_preferences
  printf '{"compaction":{"reserveTokens":650000,"keepRecentTokens":60000}}\n' >"$AGENT/settings.json"
  export PI_AI_REFRESH_PREFERENCES=1
  refresh
  [ "$status" -eq 0 ]
  jq -e '.compaction.reserveTokens == 16384 and .compaction.keepRecentTokens == 20000 and .compaction.modelOverrides == {"github-copilot/gpt-6-luna":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/gpt-6.1-sol":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/gpt-6-astra":{"reserveTokens":650000,"keepRecentTokens":60000},"github-copilot/claude-opus-5.5":{"reserveTokens":650000,"keepRecentTokens":60000}}' "$AGENT/settings.json"
}

@test "refresh preserves unknown models custom token values and non-Copilot roles" {
  seed_preferences
  printf '%s\n' '{"defaultProvider":"other","defaultModel":"gpt-6-sol","defaultTools":["+codemode","+extra"],"compaction":{"reserveTokens":99,"keepRecentTokens":88,"modelOverrides":{"unknown/model":{"keepRecentTokens":77}}}}' >"$AGENT/settings.json"
  printf '%s\n' '{"modes":{"rush":{"provider":"other","modelId":"gpt-5.4-mini"},"smart":{"provider":"github-copilot","modelId":"custom"}}}' >"$AGENT/modes.json"
  export PI_AI_REFRESH_PREFERENCES=1
  refresh
  [ "$status" -eq 0 ]
  jq -e '.defaultProvider == "other" and .defaultModel == "gpt-6-sol" and .defaultTools == ["+codemode","+extra"] and .compaction == {"reserveTokens":99,"keepRecentTokens":88,"modelOverrides":{"unknown/model":{"keepRecentTokens":77}}}' "$AGENT/settings.json"
  jq -e '.modes.rush.provider == "other" and .modes.rush.modelId == "gpt-5.4-mini" and .modes.smart.modelId == "custom"' "$AGENT/modes.json"
}

@test "refresh recognizes authored old role values and defaults missing tool list additively" {
  seed_preferences
  printf '{"defaultProvider":"github-copilot","defaultModel":"gpt-6-sol"}\n' >"$AGENT/settings.json"
  printf '{"modes":{"rush":{"provider":"github-copilot","modelId":"gpt-6-luna"},"smart":{"provider":"github-copilot","modelId":"gpt-6-sol"},"deep":{"provider":"github-copilot","modelId":"gpt-6-astra"},"review":{"provider":"github-copilot","modelId":"claude-opus-5.5"}}}\n' >"$AGENT/modes.json"
  export PI_AI_REFRESH_PREFERENCES=1
  refresh
  [ "$status" -eq 0 ]
  jq -e '.defaultModel == "gpt-6.1-sol" and .defaultTools == ["+codemode"] and .codemode.mode == "on"' "$AGENT/settings.json"
  jq -e '.modes.smart.modelId == "gpt-6.1-sol" and .modes.deep.modelId == "gpt-6-astra"' "$AGENT/modes.json"
}

@test "invalid refresh documents fail before any publication" {
  seed_preferences
  printf '{broken\n' >"$AGENT/modes.json"
  export PI_AI_REFRESH_PREFERENCES=1
  local before
  before=$(snapshot)
  refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *JSON* ]]
  [ "$before" = "$(snapshot)" ]
}

@test "graceTurns retirement preserves all other settings and is privately backed up once" {
  local subagents="$AGENT/subagents.json" before
  printf '%s\n' '{"defaultMaxTurns":37,"graceTurns":5,"wrapUpTurns":7,"maxConcurrent":2,"custom":{"graceTurns":9},"excludedExtensionPackages":["npm:custom"]}' >"$subagents"
  cp "$subagents" "$TEST_ROOT/original-subagents.json"
  migration remove_retired_subagent_grace_turns "$subagents"
  [ "$status" -eq 0 ]
  jq -e '. == {"defaultMaxTurns":37,"wrapUpTurns":7,"maxConcurrent":2,"custom":{"graceTurns":9},"excludedExtensionPackages":["npm:custom"]}' "$subagents"
  cmp "$TEST_ROOT/original-subagents.json" "$subagents.backup"
  [ "$(stat -c %a "$subagents")" = 600 ]
  [ "$(stat -c %a "$subagents.backup")" = 600 ]
  before=$(snapshot)
  migration remove_retired_subagent_grace_turns "$subagents"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "graceTurns retirement removes ignored values without adding wrapUpTurns" {
  local value
  for value in 5 0 null '"custom"'; do
    printf '{"defaultMaxTurns":50,"graceTurns":%s}\n' "$value" >"$AGENT/subagents.json"
    migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
    [ "$status" -eq 0 ]
    jq -e '. == {"defaultMaxTurns":50}' "$AGENT/subagents.json"
  done
}

@test "graceTurns retirement leaves missing files and settings without the key untouched" {
  local before
  before=$(snapshot)
  migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
  printf '{"wrapUpTurns":4,"custom":true}\n' >"$AGENT/subagents.json"
  before=$(snapshot)
  migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "graceTurns retirement check mode reports cleanup without writing" {
  printf '{"graceTurns":5}\n' >"$AGENT/subagents.json"
  local before
  before=$(snapshot)
  export TEST_MODE=check
  migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *Would*back*up* ]]
  [ "$before" = "$(snapshot)" ]
}

@test "graceTurns retirement refuses invalid JSON and foreign links without publication" {
  local value before
  for value in '{bad' '[]' '{} {}'; do
    printf '%s\n' "$value" >"$AGENT/subagents.json"
    before=$(snapshot)
    migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *Invalid*JSON* ]]
    [ "$before" = "$(snapshot)" ]
  done
  rm "$AGENT/subagents.json"
  printf '{"graceTurns":5}\n' >"$TEST_ROOT/foreign.json"
  ln -s "$TEST_ROOT/foreign.json" "$AGENT/subagents.json"
  before=$(snapshot)
  migration remove_retired_subagent_grace_turns "$AGENT/subagents.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *foreign*symlink* ]]
  [ "$before" = "$(snapshot)" ]
  cmp <(printf '{"graceTurns":5}\n') "$TEST_ROOT/foreign.json"
}

@test "graceTurns retirement refuses a detected concurrent replacement" {
  printf '{"graceTurns":5}\n' >"$AGENT/subagents.json"
  migration eval '
    original=$(declare -f backup_regular_contents)
    eval "${original/backup_regular_contents/original_backup}"
    backup_regular_contents() { original_backup "$@"; printf "{\"custom\":\"concurrent\"}\n" >"$1"; }
    remove_retired_subagent_grace_turns "$PI_AGENT_DIR/subagents.json"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *changed*during* ]]
  jq -e '. == {"custom":"concurrent"}' "$AGENT/subagents.json"
  jq -e '. == {"graceTurns":5}' "$AGENT/subagents.json.backup"
}

@test "owned child exclusions converge source versions while preserving unknown entries and preferences" {
  printf '%s\n' '{"maxConcurrent":2,"excludedExtensionPackages":["npm:pi-web-access@0.27.0","npm:custom-local-ui@1.0.0","git:github.com/tmustier/pi-extensions@old","npm:pi-web-access@0.20.0","https://github.com/tmustier/pi-extensions@old","npm:pi-web-access-extra@1"]}' >"$AGENT/subagents.json"
  printf '%s\n' '{"maxConcurrent":4,"excludedExtensionPackages":["npm:pi-web-access","git:github.com/tmustier/pi-extensions","npm:pi-file-context","npm:pi-sub-bar"]}' >"$TEST_ROOT/subagents-baseline.json"
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$TEST_ROOT/subagents-baseline.json"
  [ "$status" -eq 0 ]
  jq -e '.maxConcurrent == 2 and .excludedExtensionPackages == ["npm:pi-web-access","npm:custom-local-ui@1.0.0","git:github.com/tmustier/pi-extensions","https://github.com/tmustier/pi-extensions@old","npm:pi-web-access-extra@1","npm:pi-file-context","npm:pi-sub-bar"]' "$AGENT/subagents.json"
  [ "$(stat -c %a "$AGENT/subagents.json.backup")" = 600 ]
  local before
  before=$(snapshot)
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$TEST_ROOT/subagents-baseline.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "file editor exclusion converges to the reviewed Git release without changing preferences" {
  printf '%s\n' '{"maxConcurrent":2,"wrapUpTurns":7,"custom":{"keep":true},"excludedExtensionPackages":["git:github.com/gambtho/pi-file-editor@old","git:github.com/gambtho/pi-file-editor@older","https://github.com/gambtho/pi-file-editor@old","npm:custom"]}' >"$AGENT/subagents.json"
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
  [ "$status" -eq 0 ]
  jq -e '
    .maxConcurrent == 2 and .wrapUpTurns == 7 and .custom == {keep:true}
    and ([.excludedExtensionPackages[] | select(. == "git:github.com/gambtho/pi-file-editor@v0.1.0")] | length) == 1
    and ([.excludedExtensionPackages[] | select(test("^git:github.com/gambtho/pi-file-editor@old"))] | length) == 0
    and (.excludedExtensionPackages | index("https://github.com/gambtho/pi-file-editor@old")) != null
    and (.excludedExtensionPackages | index("npm:custom")) != null
  ' "$AGENT/subagents.json"
  local before
  before=$(snapshot)
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "retired owned child exclusions disappear without altering opaque lookalikes or preferences" {
  printf '%s\n' '{"maxConcurrent":2,"custom":{"keep":true},"excludedExtensionPackages":["npm:@narumitw/pi-caffeinate","npm:@narumitw/pi-caffeinate@0.49.11","npm:@narumitw/pi-caffeinate@0.50.0-beta.1","npm:@narumitw/pi-caffeinate-extra@1","./pi-caffeinate","https://github.com/narumiruna/pi-caffeinate","npm:@custom/pi-caffeinate@1","npm:@narumitw/pi-caffeinate@","npm:@narumitw/pi-caffeinate@1@custom","npm:@narumitw/pi-caffeinate@1 custom","npm:shitty-extensions","npm:shitty-extensions@1.0.4","npm:shitty-extensions@1.0.9","npm:shitty-extensions@1.1.0-beta.1","npm:shitty-extensions-extra@1","npm:@custom/shitty-extensions@1","https://github.com/hjanuschka/shitty-extensions","git:github.com/hjanuschka/shitty-extensions@old","./shitty-extensions","npm:shitty-extensions@","npm:shitty-extensions@1@custom","npm:shitty-extensions@1 custom","npm:custom@1","npm:custom@1","npm:pi-web-access@old"]}' >"$AGENT/subagents.json"
  cp "$AGENT/subagents.json" "$TEST_ROOT/prior-exclusions.json"
  printf '%s\n' '{"maxConcurrent":4,"excludedExtensionPackages":["npm:pi-web-access"]}' >"$TEST_ROOT/subagents-baseline.json"
  local before
  before=$(snapshot)
  export TEST_MODE=check
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$TEST_ROOT/subagents-baseline.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *Would*back*up* ]]
  [ "$before" = "$(snapshot)" ]
  export TEST_MODE=apply
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$TEST_ROOT/subagents-baseline.json"
  [ "$status" -eq 0 ]
  jq -e '.maxConcurrent == 2 and .custom == {"keep":true} and .excludedExtensionPackages == ["npm:@narumitw/pi-caffeinate-extra@1","./pi-caffeinate","https://github.com/narumiruna/pi-caffeinate","npm:@custom/pi-caffeinate@1","npm:@narumitw/pi-caffeinate@","npm:@narumitw/pi-caffeinate@1@custom","npm:@narumitw/pi-caffeinate@1 custom","npm:shitty-extensions-extra@1","npm:@custom/shitty-extensions@1","https://github.com/hjanuschka/shitty-extensions","git:github.com/hjanuschka/shitty-extensions@old","./shitty-extensions","npm:shitty-extensions@","npm:shitty-extensions@1@custom","npm:shitty-extensions@1 custom","npm:custom@1","npm:custom@1","npm:pi-web-access"]' "$AGENT/subagents.json"
  cmp "$TEST_ROOT/prior-exclusions.json" "$AGENT/subagents.json.backup"
  [ "$(stat -c %a "$AGENT/subagents.json.backup")" = 600 ]
  [ "$(stat -c %a "$AGENT/subagents.json")" = 600 ]
  before=$(snapshot)
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$TEST_ROOT/subagents-baseline.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "retired exclusion migration refuses a concurrent replacement without clobbering it" {
  printf '{"excludedExtensionPackages":["npm:shitty-extensions@1.0.4"]}\n' >"$AGENT/subagents.json"
  migration eval '
    original=$(declare -f backup_regular_contents)
    eval "${original/backup_regular_contents/original_backup}"
    backup_regular_contents() { original_backup "$@"; printf "{\"custom\":\"concurrent\"}\n" >"$1"; }
    reconcile_child_exclusions "$PI_AGENT_DIR/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *changed*during* ]]
  jq -e '. == {"custom":"concurrent"}' "$AGENT/subagents.json"
  jq -e '. == {"excludedExtensionPackages":["npm:shitty-extensions@1.0.4"]}' "$AGENT/subagents.json.backup"
  [ "$(stat -c %a "$AGENT/subagents.json.backup")" = 600 ]
}

@test "exclusions preserve custom duplicates and never add permission guard or skill packages" {
  printf '%s\n' '{"excludedExtensionPackages":["npm:custom@1","npm:custom@1"]}' >"$AGENT/subagents.json"
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
  [ "$status" -eq 0 ]
  jq -e '[.excludedExtensionPackages[] | select(. == "npm:custom@1")] | length == 2' "$AGENT/subagents.json"
  jq -e 'all(.excludedExtensionPackages[]; (test("permission-system|worktree-guard|superpowers|agent-skills") | not))' "$AGENT/subagents.json"
}

@test "invalid exclusion arrays fail without backup or publication" {
  local value before
  for value in '{bad' '[]' '{"excludedExtensionPackages":[42]}' '{"excludedExtensionPackages":null}'; do
    printf '%s\n' "$value" >"$AGENT/subagents.json"
    before=$(snapshot)
    migration reconcile_child_exclusions "$AGENT/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *Invalid*JSON* || "$output" == *Invalid*exclusion* ]]
    [ "$before" = "$(snapshot)" ]
  done
}

@test "file context refresh only changes known old default and preserves custom shortcuts and fields" {
  printf '{"openShortcut":"ctrl+shift+x","extra":true}\n' >"$AGENT/pi-file-context.json"
  migration refresh_pi_file_context "$AGENT/pi-file-context.json" "$REPO_ROOT/ai/pi/config/file-context.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .openShortcut "$AGENT/pi-file-context.json")" = ctrl+shift+x ]
  export PI_AI_REFRESH_PREFERENCES=1
  migration refresh_pi_file_context "$AGENT/pi-file-context.json" "$REPO_ROOT/ai/pi/config/file-context.json"
  [ "$status" -eq 0 ]
  jq -e '.openShortcut == "f8" and .extra == true' "$AGENT/pi-file-context.json"
  local before
  before=$(snapshot)
  migration refresh_pi_file_context "$AGENT/pi-file-context.json" "$REPO_ROOT/ai/pi/config/file-context.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
  printf '{"openShortcut":"alt+o","extra":true}\n' >"$AGENT/pi-file-context.json"
  before=$(snapshot)
  migration refresh_pi_file_context "$AGENT/pi-file-context.json" "$REPO_ROOT/ai/pi/config/file-context.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}

@test "check mode evaluates each pending migration without files backups receipts or directories" {
  seed_preferences
  cp "$OWNED/ai/pi/config/models.json" "$AGENT/models.json"
  printf '{"maxConcurrent":2,"excludedExtensionPackages":["npm:pi-web-access@old"]}\n' >"$AGENT/subagents.json"
  printf '{"openShortcut":"ctrl+shift+x"}\n' >"$AGENT/pi-file-context.json"
  export PI_AI_REFRESH_PREFERENCES=1 TEST_MODE=check
  local before
  before=$(snapshot)
  migration retire_astra_override "$AGENT/models.json"
  [ "$status" -eq 0 ]
  refresh
  [ "$status" -eq 0 ]
  migration reconcile_child_exclusions "$AGENT/subagents.json" "$REPO_ROOT/ai/pi/config/subagents.json"
  [ "$status" -eq 0 ]
  migration refresh_pi_file_context "$AGENT/pi-file-context.json" "$REPO_ROOT/ai/pi/config/file-context.json"
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot)" ]
}
