#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  mkdir -p \
    "$HOME/.claude" \
    "$HOME/.codex" \
    "$HOME/.config/litellm"
  printf 'sentinel\n' >"$HOME/.claude/settings.json"
  printf 'sentinel\n' >"$HOME/.codex/config.toml"
  printf 'sentinel\n' >"$HOME/.config/litellm/config.yaml"
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

stub_successful_remote_download() {
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
while (($# > 0)); do
  if [[ "$1" == "--output" ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"$2"
    exit 0
  fi
  shift
done
exit 1
SCRIPT
  chmod +x "$STUB_BIN/curl"
}

@test "codex check mode changes no files" {
  assert_check_is_immutable ai/codex/install.sh
}

@test "codex install generates config with local marketplace" {
  local codex_home="$HOME/generated-codex"
  local config="$codex_home/config.toml"

  run env HOME="$HOME" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" bash "$REPO_ROOT/ai/codex/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$config" ]
  grep -Fq '[marketplaces.guarzo]' "$config"
  grep -Fq 'source_type = "local"' "$config"
  grep -Fq "source = \"$REPO_ROOT/ai/marketplace\"" "$config"
  assert_symlink_target "$codex_home/AGENTS.md" "$REPO_ROOT/ai/codex/AGENTS.md"
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

@test "claude installer failure still links settings and exits nonzero" {
  run env HOME="$HOME" PATH="/usr/bin:/bin" bash "$REPO_ROOT/ai/claude/install.sh"
  [ "$status" -ne 0 ]
  assert_symlink_target "$HOME/.claude/settings.json" "$REPO_ROOT/ai/claude/settings.json"
}

@test "successful claude install and settings linking exit successfully" {
  stub_successful_remote_download

  run env ALLOW_REMOTE_INSTALLERS=1 HOME="$HOME" PATH="$PATH" bash "$REPO_ROOT/ai/claude/install.sh"
  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/.claude/settings.json" "$REPO_ROOT/ai/claude/settings.json"
}
