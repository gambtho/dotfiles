#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test

  REFERENCE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md"
  SKILL_DOC="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md"
  SEED_SCRIPT="$TEST_ROOT/local-seed.sh"
  SUDO_LOG="$TEST_ROOT/sudo.log"
  export REFERENCE SKILL_DOC SEED_SCRIPT SUDO_LOG

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
  local vekil_hook='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'

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

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc "$vekil_hook" "$HOME/.zshrc")" -eq 1 ]
}

@test "the installed zsh hook loads Vekil endpoints and the Codex wrapper" {
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/ai/vekil"
  cp "$REPO_ROOT/ai/vekil/env.zsh" \
    "$TEST_ROOT/host-seed/.dotfiles/ai/vekil/env.zsh"
  stub_command curl 'exit 0'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]

  run env \
    -u OPENAI_BASE_URL -u OPENAI_API_KEY \
    -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_MODEL \
    -u VEKIL_MANAGED_OPENAI_BASE_URL -u VEKIL_MANAGED_OPENAI_API_KEY \
    -u VEKIL_MANAGED_ANTHROPIC_BASE_URL -u VEKIL_MANAGED_ANTHROPIC_API_KEY \
    -u VEKIL_MANAGED_ANTHROPIC_MODEL \
    HOME="$HOME" PATH="$PATH" REMOTE_CONTAINERS=true \
    zsh -dic 'print -r -- "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print -r -- "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -w codex'

  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENAI_BASE_URL=http://host.docker.internal:1337/v1"* ]]
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://host.docker.internal:1337"* ]]
  [[ "$output" == *"codex: function"* ]]
}

@test "tracked devcontainer files are explicitly inspection-only" {
  grep -F "Dockerfile, devcontainer.json, and base Compose files are inspection-only" \
    "$SKILL_DOC" "$REFERENCE"
  grep -F "The only permitted devcontainer writes are" "$SKILL_DOC"
  grep -F 'Capture the initial `git status --short` output' "$SKILL_DOC"
  grep -F "Never edit a project Dockerfile" "$SKILL_DOC" "$REFERENCE"
}

@test "login-shell troubleshooting excludes tracked rc and retry-loop changes" {
  grep -F "zsh -lic" "$SKILL_DOC" "$REFERENCE"
  grep -F "Empty endpoint variables or Codex resolving to the raw binary" \
    "$SKILL_DOC" "$REFERENCE"
  ! grep -F 'for _ in {1..30}' "$SKILL_DOC" "$REFERENCE"
  ! grep -F 'config_files=($DOTFILES/**/*.zsh)' "$SKILL_DOC" "$REFERENCE"
}
