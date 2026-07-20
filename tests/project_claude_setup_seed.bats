#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test

  REFERENCE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md"
  SEED_SCRIPT="$TEST_ROOT/local-seed.sh"
  SUDO_LOG="$TEST_ROOT/sudo.log"
  export REFERENCE SEED_SCRIPT SUDO_LOG

  mkdir -p "$TEST_ROOT/host-seed/.claude" \
    "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace" \
    "$HOME/.claude" "$HOME/.dotfiles"

  cat >"$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SUDO_LOG"
[ "${1:-}" = chown ] || exit 64
shift
[ "${1:-}" = -R ] && shift
shift
chmod -R u+rwX "$@"
EOF
  chmod +x "$STUB_BIN/sudo"

  extract_seed_script
}

teardown() {
  chmod -R u+rwX "$HOME/.claude" "$HOME/.dotfiles" 2>/dev/null || true
}

extract_seed_script() {
  awk '
    /Write `\{WORKSPACE\}\/\.devcontainer\/local-seed\.sh` with:/ { found = 1; next }
    found && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$REFERENCE" >"$SEED_SCRIPT"

  sed -i \
    -e "s|SEED_CLAUDE=\"/host-seed/.claude\"|SEED_CLAUDE=\"$TEST_ROOT/host-seed/.claude\"|" \
    -e "s|SEED_DOTFILES=\"/host-seed/.dotfiles\"|SEED_DOTFILES=\"$TEST_ROOT/host-seed/.dotfiles\"|" \
    "$SEED_SCRIPT"
}

@test "fresh named-volume mountpoints are made writable and seeded" {
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"
  chmod 500 "$HOME/.claude" "$HOME/.dotfiles"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  grep -F "chown -R $(id -u):$(id -g)" "$SUDO_LOG"
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [ -f "$HOME/.claude/.seeded" ]
}

@test "ownership is repaired before a stale sentinel skips seeding" {
  touch "$HOME/.claude/.seeded"
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"
  chmod 500 "$HOME/.claude" "$HOME/.dotfiles"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  grep -F "chown -R $(id -u):$(id -g)" "$SUDO_LOG"
  [ ! -e "$HOME/.claude/settings.json" ]
  [ ! -e "$HOME/.dotfiles/ai/marketplace/marker" ]
  [[ "$output" == *"already seeded"* ]]
}
