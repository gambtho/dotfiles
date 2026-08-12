#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin:$SANDBOX_TOOL_BIN"
  HELPER="$REPO_ROOT/bin/claude-merge-compose-override"
  OVERRIDE="$TEST_ROOT/docker-compose.override.yml"
  SEED_FILE="$TEST_ROOT/local-seed.sh"
  REMOTE_HOME="/home/vscode"
  SEED_CONTAINER_PATH="/workspaces/demo/.devcontainer/local-seed.sh"
  CONTAINER_WORKSPACE="/workspaces/demo"
  export HELPER OVERRIDE SEED_FILE REMOTE_HOME SEED_CONTAINER_PATH CONTAINER_WORKSPACE

  mkdir -p "$HOME/.claude/config" "$HOME/.claude/commands" \
    "$HOME/.claude/skills" "$HOME/.dotfiles" "$HOME/.ssh" \
    "$HOME/.config/gh"
  printf '{}\n' >"$HOME/.claude/settings.json"
  printf 'guidance\n' >"$HOME/.claude/CLAUDE.md"
}

run_helper() {
  run env HOME="$HOME" "$HELPER" \
    --service app \
    --remote-user vscode \
    --remote-home "$REMOTE_HOME" \
    --seed-file "$SEED_FILE" \
    --seed-container-path "$SEED_CONTAINER_PATH" \
    --base-command-json '["sleep","infinity"]' \
    --workspace "$CONTAINER_WORKSPACE" \
    "$@" "$OVERRIDE"
}

volume_source_for_target() {
  local target="$1"
  TARGET_VOLUME="$target" yq -r '
    .services.app.volumes[]
    | select((split(":")[1]) == strenv(TARGET_VOLUME))
    | split(":")[0]
  ' "$OVERRIDE"
}

@test "default dry-run emits deny-by-default seed and credential mounts without writes" {
  run_helper --dry-run

  [ "$status" -eq 0 ]
  [ ! -e "$OVERRIDE" ]
  [ ! -e "$SEED_FILE" ]
  [[ "$output" == *"$HOME/.claude/settings.json:/host-seed/.claude/settings.json:ro"* ]]
  [[ "$output" == *"$HOME/.dotfiles:/host-seed/.dotfiles:ro"* ]]
  [[ "$output" == *"claude-local-home:$REMOTE_HOME/.claude"* ]]
  [[ "$output" == *"dotfiles-local-home:$REMOTE_HOME/.dotfiles"* ]]
  [[ "$output" == *"ssh-local-home:$REMOTE_HOME/.ssh"* ]]
  [[ "$output" == *"gh-local-home:$REMOTE_HOME/.config/gh"* ]]
  [[ "$output" == *"opencode-local-home:$REMOTE_HOME/.config/opencode"* ]]
  [[ "$output" != *"$HOME/.ssh:$REMOTE_HOME/.ssh"* ]]
  [[ "$output" != *"$HOME/.config/gh:$REMOTE_HOME/.config/gh"* ]]
  [[ "$output" != *"$HOME/.claude:$REMOTE_HOME/.claude"* ]]
  [[ "$output" != *"$HOME/.config/opencode"* ]]
  [[ "$output" != *":cached"* ]]
  [[ "$output" == *"--argv"*"sleep"*"infinity"* ]]
}

@test "host auth opt-in replaces only SSH and GitHub CLI shadows with read-only binds" {
  run_helper --share-host-auth

  [ "$status" -eq 0 ]
  [ "$(volume_source_for_target "$REMOTE_HOME/.ssh")" = "$HOME/.ssh" ]
  [ "$(volume_source_for_target "$REMOTE_HOME/.config/gh")" = "$HOME/.config/gh" ]
  [ "$(volume_source_for_target "$REMOTE_HOME/.config/opencode")" = opencode-local-home ]
  local volumes
  volumes="$(yq -r '.services.app.volumes[]' "$OVERRIDE")"
  grep -Fqx "$HOME/.ssh:$REMOTE_HOME/.ssh:ro" <<<"$volumes"
  grep -Fqx "$HOME/.config/gh:$REMOTE_HOME/.config/gh:ro" <<<"$volumes"
  [[ "$(cat "$OVERRIDE")" != *"$HOME/.claude:$REMOTE_HOME/.claude"* ]]
}

@test "merge preserves unrelated keys and targets while replacing every managed target" {
  cat >"$OVERRIDE" <<YAML
services:
  app:
    environment:
      KEEP_ME: "yes"
    volumes:
      - /cache:/cache
      - $HOME/.claude:$REMOTE_HOME/.claude:cached
      - $HOME/.ssh:$REMOTE_HOME/.ssh
  worker:
    image: example/worker
YAML

  run_helper

  [ "$status" -eq 0 ]
  [ "$(yq -r '.services.app.environment.KEEP_ME' "$OVERRIDE")" = yes ]
  [ "$(yq -r '.services.worker.image' "$OVERRIDE")" = example/worker ]
  [ "$(volume_source_for_target /cache)" = /cache ]
  [ "$(volume_source_for_target "$REMOTE_HOME/.claude")" = claude-local-home ]
  [ "$(volume_source_for_target "$REMOTE_HOME/.ssh")" = ssh-local-home ]
  [ "$(yq -o=json -I=0 '.services.app.command' "$OVERRIDE")" = \
    "[\"bash\",\"$SEED_CONTAINER_PATH\",\"--argv\",\"sleep\",\"infinity\"]" ]
}

@test "scalar commands cross the boundary as one shell argument" {
  run env HOME="$HOME" "$HELPER" \
    --service app --remote-user vscode --remote-home "$REMOTE_HOME" \
    --seed-file "$SEED_FILE" --seed-container-path "$SEED_CONTAINER_PATH" \
    --base-command-json '"printf \"one two\"; sleep infinity"' \
    --workspace "$CONTAINER_WORKSPACE" "$OVERRIDE"

  [ "$status" -eq 0 ]
  [ "$(yq -o=json -I=0 '.services.app.command' "$OVERRIDE")" = \
    "[\"bash\",\"$SEED_CONTAINER_PATH\",\"--shell\",\"printf \\\"one two\\\"; sleep infinity\"]" ]
}

@test "invalid command JSON and unsafe paths fail before writes" {
  local value
  for value in null true false 1 '{}' '""' '[]' '["sleep",1]'; do
    run env HOME="$HOME" "$HELPER" \
      --service app --remote-user vscode --remote-home "$REMOTE_HOME" \
      --seed-file "$SEED_FILE" --seed-container-path "$SEED_CONTAINER_PATH" \
      --base-command-json "$value" --workspace "$CONTAINER_WORKSPACE" "$OVERRIDE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid --base-command-json"* ]]
    [ ! -e "$OVERRIDE" ]
    [ ! -e "$SEED_FILE" ]
  done

  run env HOME="$HOME" "$HELPER" \
    --service app --remote-user vscode --remote-home home/vscode \
    --seed-file "$SEED_FILE" --seed-container-path "$SEED_CONTAINER_PATH" \
    --base-command-json '["sleep"]' --workspace "$CONTAINER_WORKSPACE" "$OVERRIDE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"absolute --remote-home"* ]]

  run env HOME="$HOME" "$HELPER" \
    --service app --remote-user vscode --remote-home "$REMOTE_HOME" \
    --seed-file "$SEED_FILE" --seed-container-path relative/seed.sh \
    --base-command-json '["sleep"]' --workspace "$CONTAINER_WORKSPACE" "$OVERRIDE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"absolute --seed-container-path"* ]]
  [ ! -e "$OVERRIDE" ]
  [ ! -e "$SEED_FILE" ]
}

@test "a missing or unusable workspace fails before writes" {
  run env HOME="$HOME" "$HELPER" \
    --service app --remote-user vscode --remote-home "$REMOTE_HOME" \
    --seed-file "$SEED_FILE" --seed-container-path "$SEED_CONTAINER_PATH" \
    --base-command-json '["sleep"]' "$OVERRIDE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--workspace required"* ]]

  local value
  # Relative, and paths whose characters are sed-replacement metacharacters:
  # both would render a seed pointing somewhere other than the checkout.
  for value in workspaces/demo '/workspaces/de#mo' '/workspaces/de&mo'; do
    run env HOME="$HOME" "$HELPER" \
      --service app --remote-user vscode --remote-home "$REMOTE_HOME" \
      --seed-file "$SEED_FILE" --seed-container-path "$SEED_CONTAINER_PATH" \
      --base-command-json '["sleep"]' --workspace "$value" "$OVERRIDE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--workspace"* ]]
  done

  [ ! -e "$OVERRIDE" ]
  [ ! -e "$SEED_FILE" ]
}

@test "invalid existing Compose fails before the seed or backups are written" {
  printf 'services: [unterminated\n' >"$OVERRIDE"

  run_helper

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid existing Compose"* ]]
  [ ! -e "$SEED_FILE" ]
  run compgen -G "$OVERRIDE.backup*"
  [ "$status" -ne 0 ]
}

@test "occupied backup names allocate UTC numeric fallbacks for both outputs" {
  printf 'services:\n  legacy: {}\n' >"$OVERRIDE"
  printf 'old seed\n' >"$SEED_FILE"
  printf 'older override\n' >"$OVERRIDE.backup"
  printf 'older seed\n' >"$SEED_FILE.backup"
  printf 'collision override\n' >"$OVERRIDE.backup.20260801T120000Z"
  printf 'collision seed\n' >"$SEED_FILE.backup.20260801T120000Z"
  stub_command date 'printf "20260801T120000Z\n"'

  run_helper

  [ "$status" -eq 0 ]
  [ "$(cat "$OVERRIDE.backup")" = "older override" ]
  [ "$(cat "$SEED_FILE.backup")" = "older seed" ]
  [ "$(cat "$OVERRIDE.backup.20260801T120000Z")" = "collision override" ]
  [ "$(cat "$SEED_FILE.backup.20260801T120000Z")" = "collision seed" ]
  [ "$(cat "$OVERRIDE.backup.20260801T120000Z.1")" = $'services:\n  legacy: {}' ]
  [ "$(cat "$SEED_FILE.backup.20260801T120000Z.1")" = "old seed" ]
}

@test "override publication failure rolls both files back and removes stages" {
  printf 'services: {}\n' >"$OVERRIDE"
  printf 'old seed\n' >"$SEED_FILE"
  export FAIL_OVERRIDE="$OVERRIDE" MV_FAILURE_MARKER="$TEST_ROOT/mv-failed"
  cat >"$STUB_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src="${@: -2:1}"
dst="${@: -1}"
if [[ "$src" == *.stage.* && "$dst" == "$FAIL_OVERRIDE" && ! -e "$MV_FAILURE_MARKER" ]]; then
  : >"$MV_FAILURE_MARKER"
  exit 1
fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$STUB_BIN/mv"

  run_helper

  [ "$status" -ne 0 ]
  [ "$(cat "$OVERRIDE")" = "services: {}" ]
  [ "$(cat "$SEED_FILE")" = "old seed" ]
  [ -e "$OVERRIDE.backup" ]
  [ -e "$SEED_FILE.backup" ]
  run bash -c 'compgen -G "$1/*.stage.*"' _ "$TEST_ROOT"
  [ "$status" -ne 0 ]
}

@test "seed is rendered from the repository template with the explicit remote user" {
  run_helper

  [ "$status" -eq 0 ]
  grep -Fqx 'SEED_USER="vscode"' "$SEED_FILE"
  # The seed is mounted at .devcontainer/local-seed.sh, one level below the
  # workspace, so a path derived from `dirname $0` would differ from this.
  grep -Fqx "WORKSPACE=\"$CONTAINER_WORKSPACE\"" "$SEED_FILE"
  run rg -n '\{USER\}|\{WORKSPACE\}' "$SEED_FILE"
  [ "$status" -eq 1 ]
}

@test "failed rollback restore reports the unrecovered destination" {
  run_helper >/dev/null 2>&1 || true
  [ -f "$OVERRIDE" ]
  [ -f "$SEED_FILE" ]
  printf 'drifted\n' >>"$SEED_FILE"
  printf 'services:\n  app:\n    image: drifted\n' >"$OVERRIDE"

  # Publish the seed successfully, fail the override publish to trigger
  # rollback, then fail the restoring cp as well. The operator must be told the
  # seed was left unrecovered rather than seeing a bare abort.
  cat >"$STUB_BIN/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *docker-compose.override.yml ]]; then
  exit 1
fi
exec /usr/bin/mv "$@"
EOF
  cat >"$STUB_BIN/cp" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == *local-seed.sh ]]; then
  exit 1
fi
exec /usr/bin/cp "$@"
EOF
  chmod +x "$STUB_BIN/mv" "$STUB_BIN/cp"

  run_helper

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be restored"* ]]
  [[ "$output" != *"restored previous outputs"* ]]
}

@test "publication preserves existing file modes" {
  run_helper >/dev/null 2>&1 || true
  chmod 0644 "$OVERRIDE" "$SEED_FILE"
  printf 'drifted\n' >>"$SEED_FILE"
  printf 'services:\n  app:\n    image: drifted\n' >"$OVERRIDE"

  run_helper

  [ "$status" -eq 0 ]
  # mktemp stages at 0600 and mv preserves the stage mode, so publishing must
  # restore the destination's permissions. The seed is executed inside the
  # container and the override is read by Compose.
  [ "$(stat -c '%a' "$OVERRIDE")" = "644" ]
  [ "$(stat -c '%a' "$SEED_FILE")" = "644" ]
}
