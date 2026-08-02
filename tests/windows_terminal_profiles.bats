#!/usr/bin/env bats

load test_helper

SCRIPT_PATH() { printf '%s\n' "$REPO_ROOT/platforms/windows/setup-wt-claude-profiles.sh"; }

setup() {
  setup_dotfiles_test
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin"
}

@test "sourcing with WT_PROFILES_SOURCE_ONLY=1 skips host discovery outside WSL" {
  run env -u WSL_DISTRO_NAME WT_PROFILES_SOURCE_ONLY=1 bash -c '
    source "$1" || exit 1
    declare -f publish_settings >/dev/null || exit 1
    declare -f main >/dev/null || exit 1
  ' _ "$(SCRIPT_PATH)"

  [ "$status" -eq 0 ]
}

@test "publish_settings publishes atomically and preserves old settings across backup collisions" {
  SETTINGS="$TEST_ROOT/settings.json"
  MERGED="$TEST_ROOT/merged.json"
  printf '{"old":true}\n' >"$SETTINGS"
  printf '{"new":true}\n' >"$MERGED"
  printf 'stale backup\n' >"$SETTINGS.backup"
  printf 'stale collision\n' >"$SETTINGS.backup.20260801T120000Z"
  stub_command date 'printf "20260801T120000Z\n"'

  run env WT_PROFILES_SOURCE_ONLY=1 bash -c '
    source "$1"
    publish_settings "$2" "$3"
  ' _ "$(SCRIPT_PATH)" "$MERGED" "$SETTINGS"

  [ "$status" -eq 0 ]
  [ "$(cat "$SETTINGS")" = '{"new":true}' ]
  [ "$(cat "$SETTINGS.backup")" = "stale backup" ]
  [ "$(cat "$SETTINGS.backup.20260801T120000Z")" = "stale collision" ]
  [ "$(cat "$SETTINGS.backup.20260801T120000Z.1")" = '{"old":true}' ]
}

@test "publish_settings failure restores destination and backup and leaves no stage" {
  SETTINGS="$TEST_ROOT/settings.json"
  MERGED="$TEST_ROOT/merged.json"
  printf '{"old":true}\n' >"$SETTINGS"
  printf '{"new":true}\n' >"$MERGED"
  MV_FAILURE_MARKER="$TEST_ROOT/mv-failed"
  export MV_FAILURE_MARKER
  cat >"$STUB_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src="${@: -2:1}"
dst="${@: -1}"
if [[ "$src" == *.stage.* && ! -e "$MV_FAILURE_MARKER" ]]; then
  : >"$MV_FAILURE_MARKER"
  exit 1
fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$STUB_BIN/mv"

  run env WT_PROFILES_SOURCE_ONLY=1 MV_FAILURE_MARKER="$MV_FAILURE_MARKER" bash -c '
    source "$1"
    publish_settings "$2" "$3"
  ' _ "$(SCRIPT_PATH)" "$MERGED" "$SETTINGS"

  [ "$status" -ne 0 ]
  [ "$(cat "$SETTINGS")" = '{"old":true}' ]
  [ -e "$SETTINGS.backup" ]
  run bash -c 'compgen -G "$1/"*.stage.*' _ "$TEST_ROOT"
  [ "$status" -ne 0 ]
}

@test "publish_settings reports failure and leaves destination untouched when the stage copy fails" {
  SETTINGS="$TEST_ROOT/settings.json"
  MERGED="$TEST_ROOT/merged.json"
  printf '{"old":true}\n' >"$SETTINGS"
  printf '{"new":true}\n' >"$MERGED"
  cat >"$STUB_BIN/cp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$STUB_BIN/cp"

  run env WT_PROFILES_SOURCE_ONLY=1 bash -c '
    source "$1"
    if publish_settings "$2" "$3"; then
      echo REPORTED SUCCESS
    else
      echo REPORTED FAILURE
    fi
  ' _ "$(SCRIPT_PATH)" "$MERGED" "$SETTINGS"

  [[ "$output" == *"REPORTED FAILURE"* ]]
  [ "$(cat "$SETTINGS")" = '{"old":true}' ]
  [ ! -e "$SETTINGS.backup" ]
  run bash -c 'compgen -G "$1/"*.stage.*' _ "$TEST_ROOT"
  [ "$status" -ne 0 ]
}

@test "explicit fixture overrides run end-to-end without host discovery" {
  mkdir -p "$TEST_ROOT/projects/demo"
  git -C "$TEST_ROOT/projects/demo" init -q
  printf '{"profiles":{"list":[]}}\n' >"$TEST_ROOT/settings.json"

  run env -u WSL_DISTRO_NAME \
    WT_SETTINGS_PATH="$TEST_ROOT/settings.json" \
    WT_WINDOWS_USER=tester \
    WT_WSL_DISTRO=Ubuntu \
    bash "$(SCRIPT_PATH)" \
    --project-root "$TEST_ROOT/projects" --yes

  [ "$status" -eq 0 ]
  run jq -e '.profiles.list | length > 0' "$TEST_ROOT/settings.json"
  [ "$status" -eq 0 ]
  [ -e "$TEST_ROOT/settings.json.backup" ]
}

@test "partial fixture overrides are rejected rather than mixed with host discovery" {
  run env -u WSL_DISTRO_NAME WT_SETTINGS_PATH="$TEST_ROOT/settings.json" \
    bash "$(SCRIPT_PATH)" --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"WT_SETTINGS_PATH"* ]]
  [[ "$output" == *"WT_WINDOWS_USER"* ]]
  [[ "$output" == *"WT_WSL_DISTRO"* ]]
}

@test "two of three fixture overrides are also rejected" {
  run env -u WSL_DISTRO_NAME \
    WT_SETTINGS_PATH="$TEST_ROOT/settings.json" \
    WT_WINDOWS_USER=tester \
    bash "$(SCRIPT_PATH)" --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"together"* || "$output" == *"all three"* ]]
}
