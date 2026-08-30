#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/config/versions.env"
  mkdir -p "$HOME/.pi/agent"
}

snapshot_home() {
  {
    find "$HOME" -mindepth 1 -printf '%y %m %P -> %l\n'
    find "$HOME" -type f -exec sha256sum {} +
  } | sort
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

@test "Pi check mode changes no files" {
  printf 'sentinel\n' >"$HOME/.pi/agent/settings.json"
  local before after
  before=$(snapshot_home)

  run env HOME="$HOME" PATH="$PATH" bash "$REPO_ROOT/ai/pi/install.sh" --check

  after=$(snapshot_home)
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

@test "Pi check mode reports every managed destination" {
  run env HOME="$HOME" PATH="$PATH" bash "$REPO_ROOT/ai/pi/install.sh" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.pi/agent/settings.json"* ]]
  [[ "$output" == *"$HOME/.pi/agent/AGENTS.md"* ]]
  [[ "$output" == *"$HOME/.pi/agent/keybindings.json"* ]]
  [[ "$output" == *"$HOME/.pi/agent/modes.json"* ]]
  [[ "$output" == *"$HOME/.pi/agent/extensions"* ]]
  [[ "$output" == *"$HOME/.config/amp/settings.json"* ]]
  [[ "$output" == *"reconcile Pi packages"* ]]
}

@test "Pi installer uses the pinned npm package and links configuration" {
  export PI_VERSION
  stub_pi_install

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  grep -Fq "@earendil-works/pi-coding-agent@$PI_VERSION" "$HOME/npm-invocation"
  grep -Fq -- '--ignore-scripts' "$HOME/npm-invocation"
  assert_symlink_target "$HOME/.pi/agent/settings.json" "$REPO_ROOT/ai/pi/settings.json"
  assert_symlink_target "$HOME/.pi/agent/AGENTS.md" "$REPO_ROOT/ai/pi/AGENTS.md"
  assert_symlink_target "$HOME/.pi/agent/keybindings.json" "$REPO_ROOT/ai/pi/keybindings.json"
  assert_symlink_target "$HOME/.pi/agent/modes.json" "$REPO_ROOT/ai/pi/modes.json"
  assert_symlink_target "$HOME/.pi/agent/extensions" "$REPO_ROOT/ai/pi/extensions"
  assert_symlink_target "$HOME/.config/amp/settings.json" "$REPO_ROOT/ai/pi/permissions.json"
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

@test "Pi installer backs up conflicting authored configuration" {
  printf 'local settings\n' >"$HOME/.pi/agent/settings.json"
  export PI_VERSION
  stub_pi_install

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.pi/agent/settings.json.backup")" = "local settings" ]
  assert_symlink_target "$HOME/.pi/agent/settings.json" "$REPO_ROOT/ai/pi/settings.json"
}
