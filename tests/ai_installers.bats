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
  [[ "$output" == *"$HOME/.pi/agent/extensions"* ]]
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
  assert_symlink_target "$HOME/.pi/agent/extensions" "$REPO_ROOT/ai/pi/extensions"
  [ "$(cat "$HOME/pi-invocation")" = "update --extensions" ]
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

@test "Pi installer backs up conflicting authored configuration" {
  printf 'local settings\n' >"$HOME/.pi/agent/settings.json"
  export PI_VERSION
  stub_pi_install

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.pi/agent/settings.json.backup")" = "local settings" ]
  assert_symlink_target "$HOME/.pi/agent/settings.json" "$REPO_ROOT/ai/pi/settings.json"
}
