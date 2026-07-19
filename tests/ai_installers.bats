#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  mkdir -p \
    "$HOME/.claude" \
    "$HOME/.codex" \
    "$HOME/.config/litellm" \
    "$HOME/.config/opencode/agents" \
    "$HOME/.copilot/agents" \
    "$HOME/.copilot/skills"
  printf 'sentinel\n' >"$HOME/.claude/settings.json"
  printf 'sentinel\n' >"$HOME/.codex/config.toml"
  printf 'sentinel\n' >"$HOME/.config/litellm/config.yaml"
  printf 'sentinel\n' >"$HOME/.config/opencode/agents/code-explorer.md"
  printf 'sentinel\n' >"$HOME/.copilot/agents/keep.md"
  printf 'sentinel\n' >"$HOME/.copilot/skills/keep.md"
  ln -s "$TEST_ROOT/legacy-commands" "$HOME/.claude/commands"
}

snapshot_home() {
  {
    find "$HOME" -mindepth 1 -printf '%y %P -> %l\n'
    find "$HOME" -type f -exec sha256sum {} +
  } | sort
}

assert_check_is_immutable() {
  local installer="$1"
  local before after
  before="$(snapshot_home)"
  run env HOME="$HOME" PATH="/usr/bin:/bin" bash "$REPO_ROOT/$installer" --check
  after="$(snapshot_home)"
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

@test "opencode check mode changes no files" {
  assert_check_is_immutable ai/opencode/install.sh
}

@test "codex check mode changes no files" {
  assert_check_is_immutable ai/codex/install.sh
}

@test "copilot check mode changes no files" {
  assert_check_is_immutable ai/copilot/install.sh
}

@test "claude check mode changes no files" {
  assert_check_is_immutable ai/claude/install.sh
}

@test "litellm check mode changes no files" {
  assert_check_is_immutable ai/litellm/install.sh
}

@test "marketplace check mode changes no files" {
  assert_check_is_immutable ai/marketplace/install.sh
}
