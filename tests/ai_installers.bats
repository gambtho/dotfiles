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
    find "$HOME" -mindepth 1 -printf '%y %m %P -> %l\n'
    find "$HOME" -type f -exec sha256sum {} +
  } | sort
}

@test "home snapshots include file and directory modes" {
  mkdir -p "$HOME/mode-check"
  : >"$HOME/mode-check/file"
  chmod 0700 "$HOME/mode-check"
  chmod 0600 "$HOME/mode-check/file"

  local before after
  before="$(snapshot_home)"
  [[ "$before" == *"d 700 mode-check -> "* ]]
  [[ "$before" == *"f 600 mode-check/file -> "* ]]

  chmod 0755 "$HOME/mode-check"
  chmod 0644 "$HOME/mode-check/file"
  after="$(snapshot_home)"
  [ "$before" != "$after" ]
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

@test "vekil release downloads use bounded retries" {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/state/vekil"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$VEKIL_CURL_LOG"
output=""
url=""
while (($# > 0)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == */checksums.txt ]]; then
  checksum=$(/usr/bin/sha256sum "${output%/*}/vekil-linux-amd64" | /usr/bin/awk '{print $1}')
  printf '%s  vekil-linux-amd64\n' "$checksum" >"$output"
else
  printf '#!/bin/bash\nexit 0\n' >"$output"
fi
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run /usr/bin/env \
    HOME="$HOME" \
    PATH="$PATH" \
    VEKIL_CURL_LOG="$HOME/curl.log" \
    VEKIL_OS=Linux \
    VEKIL_ARCH=x86_64 \
    VEKIL_SKIP_AUTH=1 \
    VEKIL_SKIP_START=1 \
    bash "$REPO_ROOT/ai/vekil/install.sh"

  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--connect-timeout 10 --max-time 120 --retry 3' "$HOME/curl.log")" -eq 2 ]
}

@test "vekil installer restarts only when refreshed credentials change" {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/state/vekil" "$HOME/.config/vekil"
  printf 'v0.13.3\n' >"$HOME/.local/state/vekil/installed-version"
  printf 'old-token\n' >"$HOME/.config/vekil/access-token"
  chmod 0600 "$HOME/.config/vekil/access-token"
  cat >"$HOME/.local/bin/vekil" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
token_dir=""
while (($# > 0)); do
  if [[ "$1" == "--token-dir" ]]; then token_dir="$2"; shift 2; else shift; fi
done
printf '%s\n' "$VEKIL_TEST_TOKEN" >"$token_dir/access-token"
chmod 0600 "$token_dir/access-token"
SCRIPT
  chmod +x "$HOME/.local/bin/vekil"
  cat >"$STUB_BIN/env" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "${*: -1}" >"$VEKIL_ACTION_FILE"
SCRIPT
  chmod +x "$STUB_BIN/env"

  run /usr/bin/env \
    HOME="$HOME" \
    PATH="$PATH" \
    VEKIL_TEST_TOKEN=new-token \
    VEKIL_ACTION_FILE="$HOME/action" \
    bash "$REPO_ROOT/ai/vekil/install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/action")" = "restart" ]

  run /usr/bin/env \
    HOME="$HOME" \
    PATH="$PATH" \
    VEKIL_TEST_TOKEN=new-token \
    VEKIL_ACTION_FILE="$HOME/action" \
    bash "$REPO_ROOT/ai/vekil/install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/action")" = "start" ]
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

@test "codex install writes placeholder auth when none exists" {
  local codex_home="$HOME/generated-codex"
  local auth="$codex_home/auth.json"

  run env HOME="$HOME" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" bash "$REPO_ROOT/ai/codex/install.sh"
  [ "$status" -eq 0 ]
  [ -f "$auth" ]
  grep -Fq '"auth_mode": "apikey"' "$auth"
  grep -Fq '"OPENAI_API_KEY": "dummy"' "$auth"
  [ "$(stat -c '%a' "$auth")" = "600" ]
}

@test "codex install preserves an existing auth file" {
  local codex_home="$HOME/generated-codex"
  local auth="$codex_home/auth.json"
  mkdir -p "$codex_home"
  printf '{"auth_mode":"chatgpt","real":true}\n' >"$auth"

  run env HOME="$HOME" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" bash "$REPO_ROOT/ai/codex/install.sh"
  [ "$status" -eq 0 ]
  grep -Fq '"auth_mode":"chatgpt"' "$auth"
  grep -Fq '"real":true' "$auth"
}

@test "codex install refreshes the personal plugin from the local marketplace" {
  local codex_home="$HOME/generated-codex"
  cat >"$STUB_BIN/codex" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$HOME/codex-invocation"
SCRIPT
  chmod +x "$STUB_BIN/codex"

  run env HOME="$HOME" CODEX_HOME="$codex_home" PATH="$PATH" \
    bash "$REPO_ROOT/ai/codex/install.sh"

  [ "$status" -eq 0 ]
  grep -Fxq "plugin add my@guarzo" "$HOME/codex-invocation"
}

@test "claude check mode changes no files" {
  assert_check_is_immutable ai/claude/install.sh
}

@test "vekil check mode changes no files" {
  assert_check_is_immutable ai/vekil/install.sh
}

@test "vekil container readiness relies on bounded curl without DNS utilities" {
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/bin/bash
[[ "${*: -1}" == "http://host.docker.internal:1337/readyz" ]]
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$STUB_BIN" REMOTE_CONTAINERS=1 /usr/bin/zsh -f -c \
    'source "$1"; printf "%s\n" "${OPENAI_BASE_URL:-}"' _ "$REPO_ROOT/ai/vekil/env.zsh"

  [ "$status" -eq 0 ]
  [ "$output" = "http://host.docker.internal:1337/v1" ]
}

@test "vekil environment provides direct client commands without proxy variables" {
  cat >"$STUB_BIN/claude" <<'SCRIPT'
#!/bin/bash
printf 'claude:%s|%s|%s|%s\n' "$*" "${ANTHROPIC_BASE_URL-unset}" "${ANTHROPIC_API_KEY-unset}" "${ANTHROPIC_MODEL-unset}"
SCRIPT
  cat >"$STUB_BIN/codex" <<'SCRIPT'
#!/bin/bash
printf 'codex:%s|%s|%s\n' "$*" "${OPENAI_BASE_URL-unset}" "${OPENAI_API_KEY-unset}"
SCRIPT
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"

  run env PATH="$PATH" /usr/bin/zsh -dfc '
    source "$1"
    export ANTHROPIC_BASE_URL=proxy ANTHROPIC_API_KEY=dummy ANTHROPIC_MODEL=proxy-model
    export VEKIL_MANAGED_ANTHROPIC_BASE_URL=proxy VEKIL_MANAGED_ANTHROPIC_API_KEY=dummy VEKIL_MANAGED_ANTHROPIC_MODEL=proxy-model
    export OPENAI_BASE_URL=proxy OPENAI_API_KEY=dummy VEKIL_MANAGED_OPENAI_BASE_URL=proxy VEKIL_MANAGED_OPENAI_API_KEY=dummy
    claude-direct --model direct-model
    codex-direct exec prompt
    unset VEKIL_MANAGED_ANTHROPIC_BASE_URL VEKIL_MANAGED_ANTHROPIC_API_KEY VEKIL_MANAGED_ANTHROPIC_MODEL
    unset VEKIL_MANAGED_OPENAI_BASE_URL VEKIL_MANAGED_OPENAI_API_KEY
    export ANTHROPIC_BASE_URL=custom-anthropic ANTHROPIC_API_KEY=real-anthropic ANTHROPIC_MODEL=direct-model
    export OPENAI_BASE_URL=custom-openai OPENAI_API_KEY=real-openai
    claude-direct direct-prompt
    codex-direct direct-prompt
  ' _ "$REPO_ROOT/ai/vekil/env.zsh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude:--model direct-model|unset|unset|unset"* ]]
  [[ "$output" == *"codex:exec prompt|unset|unset"* ]]
  [[ "$output" == *"claude:direct-prompt|custom-anthropic|real-anthropic|direct-model"* ]]
  [[ "$output" == *"codex:direct-prompt|custom-openai|real-openai"* ]]
}

@test "marketplace check mode changes no files" {
  assert_check_is_immutable ai/marketplace/install.sh
}

@test "vekil proxy rejects unsafe access-token entries" {
  run bash "$REPO_ROOT/tests/vekil-proxy-token-safety.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: Vekil proxy rejects unsafe access-token entries"* ]]
}

@test "vekil access-token validation propagates chmod failure" {
  local token_file="$HOME/access-token"
  : >"$token_file"
  cat >"$STUB_BIN/chmod" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
  /usr/bin/chmod +x "$STUB_BIN/chmod"

  run /usr/bin/env PATH="$PATH" bash -c \
    'source "$1"; validate_vekil_access_token "$2"' _ \
    "$REPO_ROOT/bin/common.sh" "$token_file"

  [ "$status" -ne 0 ]
}

@test "vekil installer safely cleans legacy LiteLLM processes" {
  run bash "$REPO_ROOT/tests/vekil-installer-legacy-cleanup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: Vekil installer safely cleans up legacy LiteLLM processes"* ]]
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
