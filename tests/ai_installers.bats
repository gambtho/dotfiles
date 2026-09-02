#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export DOTFILES="$REPO_ROOT"
  source "$REPO_ROOT/config/versions.env"
  mkdir -p "$HOME/.pi/agent"
}

snapshot_tree() {
  local root="${1:-$HOME}"
  {
    find "$root" -mindepth 1 -printf '%y %m %P -> %l\n'
    find "$root" -type f -exec sha256sum {} +
  } | sort
}

snapshot_home() {
  snapshot_tree "$HOME"
}

stub_existing_pi() {
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/pi" <<'SCRIPT'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' "$PI_VERSION"
else
  printf '%s\n' "$*" >"$HOME/pi-invocation"
fi
SCRIPT
  chmod +x "$HOME/.local/bin/pi"
}

seed_mutable_pi_drift() {
  local agent_dir="$1"
  local web_config="$2"
  mkdir -p "$agent_dir/extensions/pi-permission-system" "$(dirname "$web_config")"
  printf '{"theme":"custom","unknown":true,"packages":["old"]}\n' >"$agent_dir/settings.json"
  printf '{"custom":"modes"}\n' >"$agent_dir/modes.json"
  printf '{"custom":"permission"}\n' >"$agent_dir/extensions/pi-permission-system/config.json"
  printf '{"custom":"sandbox"}\n' >"$agent_dir/sandbox.json"
  printf '{"custom":"subagents"}\n' >"$agent_dir/subagents.json"
  printf '{"custom":"web"}\n' >"$web_config"
}

stub_pi_install() {
  cat >"$STUB_BIN/npm" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >"$HOME/npm-invocation"
mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/pi" <<PI
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then
  printf '%s\n' "$PI_VERSION"
else
  printf '%s\n' "\$*" >"$HOME/pi-invocation"
fi
PI
chmod +x "$HOME/.local/bin/pi"
SCRIPT
  chmod +x "$STUB_BIN/npm"
}

@test "Pi check mode changes no files with custom agent and XDG roots" {
  local agent_dir="$TEST_ROOT/custom-agent"
  local xdg_dir="$TEST_ROOT/custom-xdg"
  mkdir -p "$agent_dir" "$xdg_dir/pi"
  printf '{"sentinel":true}\n' >"$agent_dir/settings.json"
  printf 'web sentinel\n' >"$xdg_dir/pi/web-search.json"
  local before after
  before=$(snapshot_tree "$TEST_ROOT")

  run env HOME="$HOME" PATH="$PATH" \
    PI_CODING_AGENT_DIR="$agent_dir" XDG_CONFIG_HOME="$xdg_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

@test "Pi check mode reports every managed destination" {
  local agent_dir="$TEST_ROOT/custom-agent"

  run env HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$agent_dir" \
    XDG_CONFIG_HOME="$TEST_ROOT/custom-xdg" bash "$REPO_ROOT/ai/pi/install.sh" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"$agent_dir/settings.json"* ]]
  [[ "$output" == *"$agent_dir/AGENTS.md"* ]]
  [[ "$output" == *"$agent_dir/keybindings.json"* ]]
  [[ "$output" == *"$agent_dir/modes.json"* ]]
  [[ "$output" == *"$agent_dir/agents/rush.md"* ]]
  [[ "$output" == *"$agent_dir/agents/smart.md"* ]]
  [[ "$output" == *"$agent_dir/agents/deep.md"* ]]
  [[ "$output" == *"$agent_dir/agents/review.md"* ]]
  [[ "$output" == *"$agent_dir/extensions/herdr-agent-state.ts"* ]]
  [[ "$output" == *"$agent_dir/extensions/worktree-guard.ts"* ]]
  [[ "$output" == *"$agent_dir/extensions/pi-permission-system/config.json"* ]]
  [[ "$output" == *"$agent_dir/sandbox.json"* ]]
  [[ "$output" == *"$agent_dir/subagents.json"* ]]
  [[ "$output" == *"$agent_dir/web-search.json"* ]]
  [[ "$output" == *"reconcile Pi packages"* ]]

  run env HOME="$HOME" PATH="$PATH" XDG_CONFIG_HOME="$TEST_ROOT/default-xdg" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_ROOT/default-xdg/pi/web-search.json"* ]]
}

@test "Pi installer publishes mutable files and individual authored links" {
  export PI_VERSION
  stub_existing_pi
  cat >"$HOME/.pi/agent/settings.json" <<'JSON'
{"theme":"custom","lastChangelogVersion":"seen","unknown":{"keep":true},"packages":["old"]}
JSON

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.pi/agent/settings.json" ]
  run jq -e '
    .theme == "custom"
    and .lastChangelogVersion == "seen"
    and .unknown.keep == true
  ' "$HOME/.pi/agent/settings.json"
  [ "$status" -eq 0 ]
  run jq -s -e '.[0].packages == .[1].packages' \
    "$HOME/.pi/agent/settings.json" "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]

  assert_symlink_target "$HOME/.pi/agent/AGENTS.md" "$REPO_ROOT/ai/pi/AGENTS.md"
  assert_symlink_target "$HOME/.pi/agent/keybindings.json" "$REPO_ROOT/ai/pi/keybindings.json"
  assert_symlink_target "$HOME/.pi/agent/agents/rush.md" "$REPO_ROOT/ai/pi/agents/rush.md"
  assert_symlink_target "$HOME/.pi/agent/agents/smart.md" "$REPO_ROOT/ai/pi/agents/smart.md"
  assert_symlink_target "$HOME/.pi/agent/agents/deep.md" "$REPO_ROOT/ai/pi/agents/deep.md"
  assert_symlink_target "$HOME/.pi/agent/agents/review.md" "$REPO_ROOT/ai/pi/agents/review.md"
  assert_symlink_target "$HOME/.pi/agent/extensions/herdr-agent-state.ts" \
    "$REPO_ROOT/ai/pi/extensions/herdr-agent-state.ts"
  assert_symlink_target "$HOME/.pi/agent/extensions/worktree-guard.ts" \
    "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts"

  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$HOME/.pi/agent/modes.json"
  run jq -e --arg auth "$HOME/.pi/agent/auth.json" '
    (.filesystem.denyRead | index($auth) != null)
    and (.filesystem.denyWrite | index($auth) != null)
  ' "$HOME/.pi/agent/sandbox.json"
  [ "$status" -eq 0 ]
  cmp "$REPO_ROOT/ai/pi/config/subagents.json" "$HOME/.pi/agent/subagents.json"
  cmp "$REPO_ROOT/ai/pi/config/web-search.json" "$XDG_CONFIG_HOME/pi/web-search.json"
  [ "$(stat -c '%a' "$HOME/.pi/agent/settings.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/modes.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/extensions/pi-permission-system/config.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/sandbox.json")" = 600 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/subagents.json")" = 600 ]
  [ "$(stat -c '%a' "$XDG_CONFIG_HOME/pi/web-search.json")" = 600 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/extensions/pi-permission-system")" = 700 ]
  run jq -e --arg auth "$HOME/.pi/agent/auth.json" '
    .permission.path_read[$auth] == "deny"
    and .permission.path_write[$auth] == "deny"
    and ([paths(scalars) as $path | getpath($path) | strings | select(contains("__PI_AGENT_DIR__"))] | length == 0)
  ' "$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/pi-invocation")" = "update --extensions" ]
}

@test "Pi installer removes positively identified Vekil and generated client remnants" {
  export PI_VERSION
  stub_pi_install
  mkdir -p "$HOME/.config/systemd/user/vekil.service.d" \
    "$HOME/.local/bin" "$HOME/.local/state/vekil" \
    "$HOME/.config/vekil" "$HOME/.codex" "$HOME/.claude"
  cat >"$HOME/.config/systemd/user/vekil.service" <<EOF
[Service]
ExecStart=$REPO_ROOT/bin/vekil-proxy start
EOF
  printf '[Service]\nEnvironment=VEKIL_BIN=/tmp/vekil\n' \
    >"$HOME/.config/systemd/user/vekil.service.d/override.conf"
  printf '#!/bin/sh\n' >"$HOME/.local/bin/vekil"
  chmod +x "$HOME/.local/bin/vekil"
  printf 'v0.14.0\n' >"$HOME/.local/state/vekil/installed-version"
  printf 'token\n' >"$HOME/.config/vekil/access-token"
  printf '{"auth_mode":"apikey","OPENAI_API_KEY":"dummy"}\n' >"$HOME/.codex/auth.json"
  ln -s "$REPO_ROOT/ai/codex/AGENTS.md" "$HOME/.codex/AGENTS.md"
  ln -s "$REPO_ROOT/ai/claude/settings.json" "$HOME/.claude/settings.json"
  stub_command systemctl 'printf "%s\n" "$*" >>"$HOME/systemctl-invocations"'

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_ALLOW_REDIRECTED_SYSTEMD=1 bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/systemd/user/vekil.service" ]
  [ ! -e "$HOME/.config/systemd/user/vekil.service.d" ]
  [ ! -e "$HOME/.local/bin/vekil" ]
  [ ! -e "$HOME/.local/state/vekil" ]
  [ ! -e "$HOME/.codex/auth.json" ]
  [ ! -e "$HOME/.codex/AGENTS.md" ]
  [ ! -e "$HOME/.claude/settings.json" ]
  [ "$(cat "$HOME/.config/vekil/access-token")" = token ]
  grep -Fxq -- '--user disable vekil.service' "$HOME/systemctl-invocations"
  grep -Fxq -- '--user daemon-reload' "$HOME/systemctl-invocations"
}

@test "legacy cleanup stops only the Vekil process recorded with matching identity" {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/state/vekil"
  cp /bin/sleep "$HOME/.local/bin/vekil"
  "$HOME/.local/bin/vekil" 60 &
  local vekil_pid=$!
  local start_id
  start_id=$(awk '{print $22}' "/proc/$vekil_pid/stat")
  printf '%s|%s\n' "$vekil_pid" "$start_id" >"$HOME/.local/state/vekil/proxy.pid"
  printf 'v0.14.0\n' >"$HOME/.local/state/vekil/installed-version"

  run env HOME="$HOME" PATH="$PATH" REPO_ROOT="$REPO_ROOT" bash -c '
    source "$REPO_ROOT/bin/common.sh"
    source "$REPO_ROOT/ai/pi/cleanup-legacy.sh"
    cleanup_legacy_ai
  '

  [ "$status" -eq 0 ]
  ! kill -0 "$vekil_pid" 2>/dev/null
  [ ! -e "$HOME/.local/bin/vekil" ]
  [ ! -e "$HOME/.local/state/vekil" ]
}

@test "Pi installer preserves machine-local authentication" {
  printf '{"github-copilot":{"type":"oauth"}}\n' >"$HOME/.pi/agent/auth.json"
  export PI_VERSION
  stub_pi_install

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  grep -Fq 'github-copilot' "$HOME/.pi/agent/auth.json"
  [ ! -L "$HOME/.pi/agent/auth.json" ]
}

@test "Pi keybindings reserve ctrl+x for plan mode" {
  run jq -e '
    .["app.message.copy"] == "ctrl+shift+x"
    and .["app.models.clearAll"] == "alt+x"
    and ([to_entries[] | select(.value == "ctrl+x")] | length == 0)
  ' "$REPO_ROOT/ai/pi/keybindings.json"
  [ "$status" -eq 0 ]
}

@test "Pi package selection omits files-widget system dependencies" {
  run jq -e '
    [.packages[] | objects | .extensions[]?]
    | index("files-widget/index.ts") == null
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi selects the pinned workflow and security packages" {
  run jq -e '
    [.packages[] | if type == "string" then . else .source end] as $sources
    | ($sources | index("git:github.com/tmustier/pi-queue-steer@v0.2.0")) != null
    and ($sources | index("npm:pi-web-access@0.27.0")) != null
    and ($sources | index("npm:@narumitw/pi-lsp@0.49.6")) != null
    and ($sources | index("npm:@gotgenes/pi-subagents@21.2.0")) != null
    and ($sources | index("npm:@gotgenes/pi-permission-system@29.2.0")) != null
    and ($sources | index("git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72")) != null
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi filters Amp permissions subagents and legacy web resources" {
  run jq -e '
    [.packages[] | objects | select(.source == "npm:pi-amplike")][0] as $amp
    | $amp.extensions == [
        "extensions/btw.ts",
        "extensions/handoff.ts",
        "extensions/modes.ts",
        "extensions/session-query.ts"
      ]
    and $amp.skills == ["skills/session-query/SKILL.md"]
    and $amp.prompts == []
    and $amp.themes == []
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi loads permission-system before sandbox and enables code actions" {
  run jq -e '
    [.packages[] | if type == "string" then . else .source end] as $sources
    | ($sources | index("npm:@gotgenes/pi-permission-system@29.2.0"))
      < ($sources | index("git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72"))
    and ([.packages[] | objects | select(.source == "git:github.com/tmustier/pi-extensions")][0].extensions
      | index("code-actions/index.ts")) != null
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi loads the complete Superpowers package" {
  run jq -e '
    [.packages[] | objects | select(.source | startswith("git:github.com/obra/superpowers@"))]
    | length == 1
      and (.[0] | has("extensions") | not)
      and (.[0] | has("skills") | not)
      and (.[0] | has("prompts") | not)
      and (.[0] | has("themes") | not)
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi installer preserves differing mutable files and skips identical baselines" {
  export PI_VERSION
  stub_existing_pi
  seed_mutable_pi_drift "$HOME/.pi/agent" "$XDG_CONFIG_HOME/pi/web-search.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  local install_output=$output
  run jq -e '.theme == "custom" and .unknown == true' "$HOME/.pi/agent/settings.json"
  [ "$status" -eq 0 ]
  run jq -s -e '.[0].packages == .[1].packages' \
    "$HOME/.pi/agent/settings.json" "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .custom "$HOME/.pi/agent/modes.json")" = modes ]
  [ "$(jq -r .custom "$HOME/.pi/agent/extensions/pi-permission-system/config.json")" = permission ]
  [ "$(jq -r .custom "$HOME/.pi/agent/sandbox.json")" = sandbox ]
  [ "$(jq -r .custom "$HOME/.pi/agent/subagents.json")" = subagents ]
  [ "$(jq -r .custom "$XDG_CONFIG_HOME/pi/web-search.json")" = web ]
  [[ "$install_output" == *preserved* ]]
  [[ "$install_output" == *PI_AI_RESET_MUTABLE_CONFIG=1* ]]
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 0 ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 0 ]
}

@test "Pi mutable reset backs up once and publishes tracked baselines" {
  export PI_VERSION
  stub_existing_pi
  seed_mutable_pi_drift "$HOME/.pi/agent" "$XDG_CONFIG_HOME/pi/web-search.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_AI_RESET_MUTABLE_CONFIG=1 bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$HOME/.pi/agent/settings.json.backup" ]
  [ -f "$HOME/.pi/agent/modes.json.backup" ]
  [ -f "$HOME/.pi/agent/extensions/pi-permission-system/config.json.backup" ]
  [ -f "$HOME/.pi/agent/sandbox.json.backup" ]
  [ -f "$HOME/.pi/agent/subagents.json.backup" ]
  [ -f "$XDG_CONFIG_HOME/pi/web-search.json.backup" ]
  cmp "$REPO_ROOT/ai/pi/settings.json" "$HOME/.pi/agent/settings.json"
  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$HOME/.pi/agent/modes.json"
  run jq -e --arg auth "$HOME/.pi/agent/auth.json" '
    (.filesystem.denyRead | index($auth) != null)
    and (.filesystem.denyWrite | index($auth) != null)
  ' "$HOME/.pi/agent/sandbox.json"
  [ "$status" -eq 0 ]
  cmp "$REPO_ROOT/ai/pi/config/subagents.json" "$HOME/.pi/agent/subagents.json"
  cmp "$REPO_ROOT/ai/pi/config/web-search.json" "$XDG_CONFIG_HOME/pi/web-search.json"
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 6 ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_AI_RESET_MUTABLE_CONFIG=1 bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 6 ]
}

@test "Pi installer converts recognized legacy links without discarding readable state" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/legacy-agent"
  local canonical="$TEST_ROOT/canonical-dotfiles"
  mkdir -p "$agent_dir" "$canonical/ai/pi"
  printf '{"theme":"legacy","packages":["old"]}\n' >"$canonical/ai/pi/settings.json"
  printf '{"legacyMode":true}\n' >"$canonical/ai/pi/modes.json"
  ln -s "$canonical/ai/pi/settings.json" "$agent_dir/settings.json"
  ln -s "$canonical/ai/pi/modes.json" "$agent_dir/modes.json"
  ln -s "$REPO_ROOT/ai/pi/extensions" "$agent_dir/extensions"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/settings.json" ]
  [ ! -L "$agent_dir/modes.json" ]
  [ ! -L "$agent_dir/extensions" ]
  [ -d "$agent_dir/extensions" ]
  [ "$(jq -r .theme "$agent_dir/settings.json")" = legacy ]
  [ "$(jq -r .legacyMode "$agent_dir/modes.json")" = true ]
  run jq -s -e '.[0].packages == .[1].packages' \
    "$agent_dir/settings.json" "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
  assert_symlink_target "$agent_dir/extensions/herdr-agent-state.ts" \
    "$REPO_ROOT/ai/pi/extensions/herdr-agent-state.ts"
  assert_symlink_target "$agent_dir/extensions/worktree-guard.ts" \
    "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts"
}

@test "Pi installer replaces a dangling recognized modes link with the baseline" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/dangling-agent"
  mkdir -p "$agent_dir"
  ln -s "$REPO_ROOT/ai/pi/modes.json" "$agent_dir/modes.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/modes.json" ]
  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$agent_dir/modes.json"
}

@test "Pi extension migration preserves unrelated entries and prunes owned stale links" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/extensions-agent"
  mkdir -p "$agent_dir/extensions/local-directory"
  printf 'local\n' >"$agent_dir/extensions/local.ts"
  ln -s /tmp/foreign-extension.ts "$agent_dir/extensions/foreign.ts"
  ln -s "$REPO_ROOT/ai/pi/extensions/retired.ts" "$agent_dir/extensions/retired.ts"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$agent_dir/extensions/local.ts" ]
  [ -d "$agent_dir/extensions/local-directory" ]
  assert_symlink_target "$agent_dir/extensions/foreign.ts" /tmp/foreign-extension.ts
  [ ! -e "$agent_dir/extensions/retired.ts" ]
  [ ! -L "$agent_dir/extensions/retired.ts" ]
}

@test "Pi installer rejects foreign extension and mutable symlinks without following them" {
  export PI_VERSION
  stub_existing_pi
  local foreign_dir="$TEST_ROOT/foreign-extensions"
  local extension_agent="$TEST_ROOT/foreign-extension-agent"
  mkdir -p "$foreign_dir" "$extension_agent"
  printf 'foreign\n' >"$foreign_dir/marker"
  ln -s "$foreign_dir" "$extension_agent/extensions"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$extension_agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  assert_symlink_target "$extension_agent/extensions" "$foreign_dir"
  [ "$(cat "$foreign_dir/marker")" = foreign ]

  local mutable_agent="$TEST_ROOT/foreign-mutable-agent"
  local foreign_modes="$TEST_ROOT/foreign-modes.json"
  mkdir -p "$mutable_agent"
  printf '{"foreign":true}\n' >"$foreign_modes"
  ln -s "$foreign_modes" "$mutable_agent/modes.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$mutable_agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  assert_symlink_target "$mutable_agent/modes.json" "$foreign_modes"
  [ "$(jq -r .foreign "$foreign_modes")" = true ]

  local permission_agent="$TEST_ROOT/foreign-permission-agent"
  local foreign_permission="$TEST_ROOT/foreign-permission"
  mkdir -p "$permission_agent/extensions" "$foreign_permission"
  printf 'foreign\n' >"$foreign_permission/marker"
  ln -s "$foreign_permission" "$permission_agent/extensions/pi-permission-system"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$permission_agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  assert_symlink_target "$permission_agent/extensions/pi-permission-system" "$foreign_permission"
  [ "$(cat "$foreign_permission/marker")" = foreign ]
  [ ! -e "$foreign_permission/config.json" ]
}

@test "Pi installer rejects relative custom agent directories before mutation" {
  export PI_VERSION
  stub_existing_pi
  local before after
  before=$(snapshot_tree "$TEST_ROOT")

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR=relative/agent bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -ne 0 ]
  [[ "$output" == *"PI_CODING_AGENT_DIR must be absolute"* ]]
  [ "$before" = "$after" ]
}

@test "Pi installer refuses production rollout from a noncanonical linked worktree" {
  export PI_VERSION
  stub_existing_pi
  local canonical="$HOME/.dotfiles"
  mkdir -p "$canonical"
  local before after
  before=$(snapshot_home)

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" DOTFILES="$canonical" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_home)
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical checkout"* ]]
  [ "$before" = "$after" ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" DOTFILES="$canonical" \
    PI_CODING_AGENT_DIR="$TEST_ROOT/isolated-agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
}

@test "Pi installer callers no longer reference retired tracked modes or permissions" {
  [ ! -e "$REPO_ROOT/ai/pi/modes.json" ]
  [ ! -e "$REPO_ROOT/ai/pi/permissions.json" ]
  run rg -n '\$ROOT/ai/pi/(permissions|modes)\\.json' \
    "$REPO_ROOT/ai/pi/install.sh" "$REPO_ROOT/tests/feature_workflow_policy.bats"
  [ "$status" -eq 1 ]
}
