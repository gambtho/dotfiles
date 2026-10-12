#!/usr/bin/env bats

load test_helper

setup() {
  local real_pi real_npm real_node
  real_pi=$(command -v pi) || real_pi=""
  real_npm=$(command -v npm)
  real_node=$(command -v node)
  source "$BATS_TEST_DIRNAME/../libexec/lib/pi-runtime.sh"
  resolve_pi_runtime "$real_pi" "${PI_TEST_HOST_ROOT:-}"
  export HOST_ROOT=$PI_RUNTIME_PACKAGE_ROOT REAL_NPM=$real_npm REAL_NODE=$real_node
  setup_dotfiles_test
  export DOTFILES="$REPO_ROOT"
  source "$REPO_ROOT/config/versions.env"
  FIXTURE_PERMISSION_VERSION=29.2.0
  mkdir -p "$HOME/.pi/agent"
  export npm_config_prefix="$TEST_ROOT/global-prefix" npm_config_cache="$TEST_ROOT/npm-cache"
  export npm_config_userconfig="$TEST_ROOT/user.npmrc" npm_config_globalconfig="$TEST_ROOT/global.npmrc"
  export npm_config_logs_dir="$TEST_ROOT/npm-logs" npm_config_update_notifier=false
  printf '' >"$npm_config_userconfig"
  printf '' >"$npm_config_globalconfig"
  mkdir -p "$HOME/.dotfiles/ai/marketplace/plugins/my"
  cp "$REPO_ROOT/ai/marketplace/plugins/my/package.json" "$HOME/.dotfiles/ai/marketplace/plugins/my/package.json"
}

stub_sdk_boundaries() {
  # Real SDK and Git state transitions; only registry/remote transport is isolated.
  stub_command npm '
    if [[ "${@: -2}" == "root -g" ]]; then exec "$REAL_NPM" "$@"; fi
    [[ "$1" == install && "$3" == --prefix ]] || exit 81
    if [[ "${PI_TEST_REQUIRE_RECOVERY:-0}" == 1 ]]; then
      captures=( "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"/package-recovery.*/recovery.json )
      [[ ${#captures[@]} == 1 && -f "${captures[0]}" ]] || exit 86
      jq -e ".priorDeclarations == []" "${captures[0]}" >/dev/null || exit 87
    fi
    if [[ "${PI_TEST_REQUIRE_REGULAR_MIGRATION:-0}" == 1 ]]; then
      [[ ! -e "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/amplike.json" ]] || exit 89
    fi
    "$TEST_ROOT/pi-fixture" install "npm:$2"
    [[ "${PI_TEST_INSTALL_FAIL:-0}" != 1 ]] || exit 42
  '
  /usr/bin/git init -q "$TEST_ROOT/git-seed"
  local tree sha tag
  tree=$(printf '' | /usr/bin/git -C "$TEST_ROOT/git-seed" hash-object -w -t tree --stdin)
  sha=$(printf 'fixture\n' | GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$TEST_ROOT/git-seed" commit-tree "$tree")
  /usr/bin/git -C "$TEST_ROOT/git-seed" update-ref HEAD "$sha"
  for tag in v0.2.0 v6.3.0 0.6.12; do /usr/bin/git -C "$TEST_ROOT/git-seed" tag "$tag" "$sha"; done
  stub_command git '
    if [[ "$1" == -C && "$3" == fetch ]]; then root=$2; shift 3; cd "$root" || exit; exec "$0" fetch "$@"; fi
    case "$1" in
      clone)
        [[ "$2" == https://github.com/*/* ]] || exit 82
        printf "install git:%s\n" "${2#https://}" >>"$HOME/pi-invocations"
        /usr/bin/git clone -q "$TEST_ROOT/git-seed" "$3" || exit
        /usr/bin/git -C "$3" config remote.origin.url "$2"
        exit ;;
      ls-remote)
        [[ "$2" == --symref && "$3" == https://github.com/*/* && "$4" == HEAD ]] || exit 82
        exec /usr/bin/git ls-remote --symref "$TEST_ROOT/git-seed" HEAD ;;
      fetch)
        shift; [[ "$1" == --no-tags ]] && shift
        [[ "$1" == origin || "$1" == https://github.com/*/* ]] || exit 82
        shift
        exec /usr/bin/git fetch --no-tags "$TEST_ROOT/git-seed" "$@" ;;
    esac
    exec /usr/bin/git "$@"
  '
  # The old installer fixture is not a real permission extension. Isolate this
  # external behavioral gate, not the package manager or production checker.
  # tests/pi_permissions.bats separately exercises the actual selected-host gate.
  stub_command node '
    if [[ "${2:-}" == */libexec/validate-pi-security-runtime.ts ]]; then
      printf "validated\n" >>"$TEST_ROOT/validator-events"
      if [[ "${PI_TEST_REQUIRE_GATE_BEFORE_LINKS:-0}" == 1 ]]; then
        [[ ! -e "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/AGENTS.md" && ! -e "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/worktree-guard.ts" ]] || exit 88
      fi
      [[ "${PI_TEST_VALIDATOR_FAIL:-0}" != 1 ]] || exit 43
      exit 0
    fi
    exec "$REAL_NODE" "$@"
  '
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

write_permission_test_schema() {
  cat >"$TEST_ROOT/permission-system-schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["debugLog", "permissionReviewLog", "yoloMode", "permission"],
  "properties": {
    "debugLog": {"type": "boolean"},
    "permissionReviewLog": {"type": "boolean"},
    "yoloMode": {"type": "boolean"},
    "permission": {
      "type": "object",
      "required": ["bash"],
      "properties": {
        "bash": {
          "type": "object",
          "required": ["*"],
          "additionalProperties": {"enum": ["allow", "ask", "deny"]}
        }
      },
      "additionalProperties": true
    }
  },
  "additionalProperties": true
}
JSON
}

stub_existing_pi() {
  write_permission_test_schema
  mkdir -p "$HOME/.pi/agent/bin" "$HOME/.pi/agent/install"
  printf '{"kind":"pi-managed-install","schemaVersion":1,"layout":"releases-v1"}\n' \
    >"$HOME/.pi/agent/install/managed-install.json"
  cat >"$HOME/.pi/agent/bin/pi" <<'SCRIPT'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' "$PI_VERSION"
else
  printf '%s\n' "$*" >"$HOME/pi-invocation"
  printf '%s\n' "$*" >>"$HOME/pi-invocations"
  if [[ "${1:-}" == install && "${2:-}" == npm:* ]]; then
    package_spec=${2#npm:}
    package_name=$package_spec
    package_version=${PI_TEST_NPM_VERSION:-2.3.4}
    if [[ "${package_spec#@}" == *@* ]]; then
      package_version=${package_spec##*@}
      package_name=${package_spec%@*}
    fi
    package_root="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/npm/node_modules/$package_name"
    mkdir -p "$package_root"
    printf '{"name":"%s","version":"%s"}\n' "$package_name" "$package_version" \
      >"$package_root/package.json"
    if [[ "$package_name" == @gotgenes/pi-permission-system ]]; then
      mkdir -p "$package_root/schemas" "$package_root/src"
      cp "$TEST_ROOT/permission-system-schema.json" \
        "$package_root/schemas/permissions.schema.json"
      if [[ "${PI_TEST_OMIT_PERMISSION_MANAGER:-0}" != 1 ]]; then
        printf 'export class PermissionManager {}\n' \
          >"$package_root/src/permission-manager.ts"
      fi
    fi
  elif [[ "${1:-}" == install && "${2:-}" == git:github.com/*/* ]]; then
    source=${2#git:}
    repository=${source%@*}
    package_root="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/git/$repository"
    /usr/bin/git init -q "$package_root"
    tree=$(printf '' | /usr/bin/git -C "$package_root" hash-object -w -t tree --stdin)
    sha=$(printf 'fixture %s\n' "${PI_TEST_GIT_REVISION:-1}" |
      GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
        GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
        /usr/bin/git -C "$package_root" commit-tree "$tree")
    /usr/bin/git -C "$package_root" update-ref HEAD "$sha"
    /usr/bin/git -C "$package_root" config remote.origin.url "https://$repository"
  fi
fi
SCRIPT
  chmod +x "$HOME/.pi/agent/bin/pi"
  cp "$HOME/.pi/agent/bin/pi" "$TEST_ROOT/pi-fixture"
  printf '0.0.0-test\n' >"$HOME/.pi/agent/install/current-version"
  mkdir -p "$HOME/.pi/agent/install/releases/0.0.0-test/node_modules/@earendil-works"
  ln -s "$HOST_ROOT" "$HOME/.pi/agent/install/releases/0.0.0-test/node_modules/@earendil-works/pi-coding-agent"
  stub_sdk_boundaries
}

stub_managed_pi_for_agent() {
  local agent_dir=$1
  mkdir -p "$agent_dir/bin" "$agent_dir/install"
  cp "$HOME/.pi/agent/bin/pi" "$agent_dir/bin/pi"
  cp "$HOME/.pi/agent/install/managed-install.json" "$agent_dir/install/managed-install.json"
  cp "$HOME/.pi/agent/install/current-version" "$agent_dir/install/current-version"
  mkdir -p "$agent_dir/install/releases/0.0.0-test/node_modules/@earendil-works"
  ln -s "$HOST_ROOT" "$agent_dir/install/releases/0.0.0-test/node_modules/@earendil-works/pi-coding-agent"
}

seed_mutable_pi_drift() {
  local agent_dir="$1"
  local web_config="$2"
  mkdir -p "$agent_dir/extensions/pi-permission-system" "$(dirname "$web_config")"
  printf '{"theme":"custom","unknown":true,"packages":["old"]}\n' >"$agent_dir/settings.json"
  printf '{"custom":"modes"}\n' >"$agent_dir/modes.json"
  printf '{"custom":"models"}\n' >"$agent_dir/models.json"
  jq '
    .debugLog = true
    | .permissionReviewLog = true
    | .yoloMode = false
    | .permission.bash["*"] = "ask"
    | .custom = "permission"
  ' "$REPO_ROOT/ai/pi/config/permission-system.json" \
    >"$agent_dir/extensions/pi-permission-system/config.json"
  printf '{"custom":"sandbox"}\n' >"$agent_dir/sandbox.json"
  printf '{"custom":"subagents"}\n' >"$agent_dir/subagents.json"
  printf '{"custom":"web"}\n' >"$web_config"
}

make_legacy_brave_skill() {
  local source=$1 name="${2:-brave-search}"
  mkdir -p "$source"
  cat >"$source/SKILL.md" <<EOF
---
name: $name
description: Legacy search skill
---
EOF
  printf 'preserve me\n' >"$source/payload.txt"
}

run_security_migration() {
  local mode=$1 agent_dir=$2 amp_settings=$3
  shift 3
  run env REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    source "$REPO_ROOT/libexec/common.sh"
    source "$REPO_ROOT/ai/pi/migrate-security-stack.sh"
    migrate_pi_security_stack "$@"
  ' _ "$mode" "$agent_dir" "$amp_settings" "$@"
}

stub_pi_install() {
  stub_existing_pi
  cp "$HOME/.pi/agent/bin/pi" "$TEST_ROOT/pi-fixture"
  rm "$HOME/.pi/agent/bin/pi" "$HOME/.pi/agent/install/managed-install.json"
  cat >"$TEST_ROOT/managed-installer.sh" <<'SCRIPT'
#!/bin/sh
set -eu
printf '%s\n' "$PATH" >"$HOME/install-path"
mkdir -p "$HOME/.pi/agent/bin" "$HOME/.pi/agent/install"
cp "$TEST_ROOT/pi-fixture" "$HOME/.pi/agent/bin/pi"
printf '{"kind":"pi-managed-install","schemaVersion":1,"layout":"releases-v1"}\n' \
  >"$HOME/.pi/agent/install/managed-install.json"
rm -f "$HOME/.local/bin/pi"
SCRIPT
  stub_command curl 'printf "%s\n" "$*" >"$HOME/curl-invocation"; cp "$TEST_ROOT/managed-installer.sh" "${@: -1}"'
}

@test "Pi fresh apply publishes F8 file context and never recreates retired models baseline" {
  export PI_VERSION
  stub_existing_pi
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.pi/agent/models.json" ]
  [ ! -L "$HOME/.pi/agent/models.json" ]
  [ ! -L "$HOME/.pi/agent/pi-file-context.json" ]
  jq -e '.openShortcut == "f8"' "$HOME/.pi/agent/pi-file-context.json"
  jq -e '.astraOverrideRetired == true' "$HOME/.pi/agent/dotfiles-migrations.json"
}

@test "Pi explicit refresh changes old file-context default only and normal apply preserves new drift" {
  export PI_VERSION
  stub_existing_pi
  printf '{"openShortcut":"ctrl+shift+x","custom":true}\n' >"$HOME/.pi/agent/pi-file-context.json"
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .openShortcut "$HOME/.pi/agent/pi-file-context.json")" = ctrl+shift+x ]
  run env PI_AI_REFRESH_PREFERENCES=1 bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  jq -e '.openShortcut == "f8" and .custom == true' "$HOME/.pi/agent/pi-file-context.json"
  [ "$(stat -c %a "$HOME/.pi/agent/pi-file-context.json.backup")" = 600 ]
  printf '{"openShortcut":"alt+o"}\n' >"$HOME/.pi/agent/pi-file-context.json"
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r .openShortcut "$HOME/.pi/agent/pi-file-context.json")" = alt+o ]
}

@test "Pi refresh flag rejects values outside zero or one before mutation" {
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env PI_AI_REFRESH_PREFERENCES=yes bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *PI_AI_REFRESH_PREFERENCES*0*1* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
}

@test "Pi explicit update captures Astra override and prior receipt before migration" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"providers":{"github-copilot":{"models":[{"id":"gpt-6-astra"}]}}}\n' >"$HOME/.pi/agent/models.json"
  printf '{"prior":"keep"}\n' >"$HOME/.pi/agent/dotfiles-migrations.json"
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.pi/agent/models.json" ]
  local captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json) backup
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/models.json")) | .backupPath' "${captures[0]}")
  jq -e '.providers["github-copilot"].models[0].id == "gpt-6-astra"' "$backup"
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/dotfiles-migrations.json")) | .backupPath' "${captures[0]}")
  jq -e '.prior == "keep" and (has("astraOverrideRetired") | not)' "$backup"
  jq -e '.prior == "keep" and .astraOverrideRetired == true' "$HOME/.pi/agent/dotfiles-migrations.json"
}

@test "Pi explicit update captures retired dangling owned models link before removing it" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  ln -s "$REPO_ROOT/ai/pi/config/models.json" "$HOME/.pi/agent/models.json"
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.pi/agent/models.json" ]
  local captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json)
  jq -e '.configBackups[] | select(.destination | endswith("/models.json")) | .state == "owned-link" and .missingTarget == true and (has("backupPath") | not)' "${captures[0]}"
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

@test "installer fixture honors explicit SDK root when pi is absent from PATH" {
  mkdir -p "$TEST_ROOT/hostless-bin"
  ln -s "$REAL_NPM" "$TEST_ROOT/hostless-bin/npm"
  local hostless_path="$TEST_ROOT/hostless-bin:/usr/bin:/bin:$SANDBOX_TOOL_BIN"
  PATH="$hostless_path" run command -v pi
  [ "$status" -ne 0 ]
  PATH="$hostless_path" PI_TEST_HOST_ROOT="$HOST_ROOT" run bats --filter '^explicit update captures private old state before declarations packages links and migrations$' "$BATS_TEST_FILENAME"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ok 1 explicit update captures private old state'* ]]
  PATH="$hostless_path" PI_TEST_HOST_ROOT="" run bats --filter '^explicit update captures private old state before declarations packages links and migrations$' "$BATS_TEST_FILENAME"
  [ "$status" -ne 0 ]
  [[ "$output" == *'error: Pi executable not found on PATH'* ]]
}

@test "regular Pi apply never updates extensions" {
  export PI_VERSION
  stub_existing_pi
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  run grep -E '^update( |$)' "$HOME/pi-invocations"
  [ "$status" -eq 1 ]
}

@test "explicit production update requires stopped-session acknowledgement before any mutation" {
  export PI_VERSION
  stub_existing_pi
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -ne 0 ]
  [[ "$output" == *PI_AI_CONFIRM_STOPPED=1* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
}

@test "explicit update refuses active YOLO before package installation or config cleanup" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  mkdir -p "$HOME/.pi/agent/extensions/pi-permission-system"
  printf '{"yoloMode":true}\n' >"$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -ne 0 ]
  [[ "$output" == *YOLO* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  [ ! -e "$HOME/pi-invocations" ]
}

@test "explicit update selects existing managed host without bootstrapping Pi itself" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_pi_install
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -ne 0 ]
  [[ "$output" == *managed*host* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  [ ! -e "$HOME/curl-invocation" ]
}

@test "make ai-update passes hostile manifest paths as one unchanged data argument" {
  local fixture="$TEST_ROOT/make-fixture" value
  mkdir -p "$fixture/ai/pi"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$#" "$@" >"$TEST_ROOT/make-argv"\n' >"$fixture/ai/pi/install.sh"
  value="$TEST_ROOT/a space ' quote ; \$(touch $TEST_ROOT/SENTINEL) \`touch $TEST_ROOT/SENTINEL\` .json"
  run env PI_AI_RESOLUTION_MANIFEST="$value" make -C "$fixture" ai-update
  [ "$status" -eq 0 ]
  mapfile -t args <"$TEST_ROOT/make-argv"
  [ "${args[0]}" = 3 ]
  [ "${args[1]}" = --update-extensions ]
  [ "${args[2]}" = --resolution-manifest ]
  [ "${args[3]}" = "$value" ]
  [ ! -e "$TEST_ROOT/SENTINEL" ]
  # Make command-line variables escape literal dollars as $$ (documented Make semantics).
  run make -C "$fixture" ai-update "PI_AI_RESOLUTION_MANIFEST=${value//\$/\$\$}"
  [ "$status" -eq 0 ]
  mapfile -t args <"$TEST_ROOT/make-argv"
  [ "${args[0]}" = 3 ]
  [ "${args[3]}" = "$value" ]
  [ ! -e "$TEST_ROOT/SENTINEL" ]
}

@test "explicit update captures private old state before declarations packages links and migrations" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1 PI_TEST_REQUIRE_RECOVERY=1 PI_TEST_REQUIRE_GATE_BEFORE_LINKS=1
  stub_existing_pi
  printf '{"theme":"old","packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"marker":"old-modes"}\n' >"$HOME/.pi/agent/modes.json"
  printf '{"permissions":{"mode":"old"},"keep":true}\n' >"$HOME/.pi/agent/amplike.json"
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  local captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json) backup
  [ "${#captures[@]}" -eq 1 ]
  jq -e '.kind == "pre-update-recovery" and .priorDeclarations == [] and all(.packages[]; .state == "absent")' "${captures[0]}"
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/settings.json")) | .backupPath' "${captures[0]}")
  [ "$(jq -r .theme "$backup")" = old ]
  [ "$(stat -c %a "${captures[0]}")" = 600 ]
  [ "$(stat -c %a "$(dirname "${captures[0]}")")" = 700 ]
  [ "$(stat -c %a "$backup")" = 600 ]
  [ -f "$(dirname "${captures[0]}")/resolution.json" ]
  [ "$(jq -r .marker "$HOME/.pi/agent/modes.json")" = old-modes ]
  jq -e '.keep == true and (has("permissions") | not)' "$HOME/.pi/agent/amplike.json"
  [ -L "$HOME/.pi/agent/AGENTS.md" ]
}

@test "installer accepts trusted HOME aliases but refuses below HOME and custom root links" {
  export PI_VERSION
  stub_existing_pi
  local physical="$HOME" alias="$TEST_ROOT/home-alias" selected before
  ln -s "$physical" "$alias"
  export HOME="$alias"
  run bash "$REPO_ROOT/ai/pi/install.sh"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 0 ]
  for selected in "$physical-other" "$TEST_ROOT/custom-agent"; do
    ln -s "$physical/.pi/agent" "$selected"
    before=$(snapshot_tree "$physical")
    PI_CODING_AGENT_DIR="$selected" run bash "$REPO_ROOT/ai/pi/install.sh" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *unsafe* || "$output" == *symlink* ]]
    [ "$before" = "$(snapshot_tree "$physical")" ]
  done
  mv "$physical/.pi" "$TEST_ROOT/foreign-pi"
  ln -s "$TEST_ROOT/foreign-pi" "$physical/.pi"
  run bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *unsafe* || "$output" == *symlink* ]]
}

@test "installer capture failure reports only retained recovery artifacts" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  stub_command node '
    if [[ " $* " == *" capture-recovery "* ]]; then
      manifest=${@: -1}
      if [[ "${RETAIN_CAPTURE:-0}" == 1 ]]; then printf "{\"retained\":true}\n" >"$manifest"; fi
      if [[ "${RETAIN_CAPTURE:-0}" == backups ]]; then mkdir "$manifest.backups"; printf "retained\n" >"$manifest.backups/0.json"; fi
      exit 46
    fi
    exec "$REAL_NODE" "$@"
  '
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 1 ]
  [[ "$output" == *'recovery: not captured'* ]]
  [[ "$output" != *'/recovery.json'* ]]
  local captures=("$HOME"/.pi/agent/package-recovery.*)
  [ ! -d "${captures[0]}" ]
  export RETAIN_CAPTURE=1
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 1 ]
  captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json)
  [ -f "${captures[0]}" ]
  [[ "$output" == *"recovery: ${captures[0]}"* ]]
  [[ "$output" == *cleanup*failed* ]]
  jq -e '.retained == true' "${captures[0]}"
  export RETAIN_CAPTURE=backups
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 1 ]
  [[ "$output" == *'artifacts retained; no manifest'* ]]
  [[ "$output" == *cleanup*failed* ]]
  local backups=("$HOME"/.pi/agent/package-recovery.*/recovery.json.backups/0.json)
  [ -f "${backups[0]}" ]
  [ "$(<"${backups[0]}")" = retained ]
}

@test "explicit installer and runtime gate failures retain recovery and report failed phase" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"permissions":{}}\n' >"$HOME/.pi/agent/amplike.json"
  export PI_TEST_INSTALL_FAIL=1
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -ne 0 ]
  [[ "$output" == *failed*during*candidate-install*recovery:* ]]
  local captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json)
  [ -f "${captures[0]}" ]
  [ ! -e "$(dirname "${captures[0]}")/resolution.json" ]
  [[ "$output" == *'No rollback was performed'* ]]
  jq -e 'has("permissions")' "$HOME/.pi/agent/amplike.json"
  unset PI_TEST_INSTALL_FAIL
  export PI_TEST_VALIDATOR_FAIL=1
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 43 ]
  [[ "$output" == *failed*during*validate-runtime*recovery:* ]]
  captures=("$HOME"/.pi/agent/package-recovery.*/recovery.json)
  [ "${#captures[@]}" -eq 2 ]
  [ -f "${captures[1]}" ]
  jq -e 'has("permissions")' "$HOME/.pi/agent/amplike.json"
  [ ! -e "$HOME/.pi/agent/extensions/pi-permission-system/config.json" ]
}

@test "installer promotes absent packages through hostile manifest path without floating bootstrap" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  local manifest="$TEST_ROOT/private/a space \" quote ; \$(touch SENTINEL) .json"
  run bash "$REPO_ROOT/libexec/pi-package-lifecycle" snapshot --agent-dir "$HOME/.pi/agent" \
    --repo-root "$REPO_ROOT" --pi-package-root "$HOST_ROOT" --manifest "$manifest"
  [ "$status" -eq 0 ]
  local before
  before=$(sha256sum "$manifest")
  rm -rf "$HOME/.pi/agent/npm" "$HOME/.pi/agent/git"
  rm -f "$HOME/pi-invocations"
  run env PI_AI_RESOLUTION_MANIFEST="$manifest" make -C "$REPO_ROOT" ai-update
  [ "$status" -eq 0 ]
  [ "$before" = "$(sha256sum "$manifest")" ]
  [ ! -e "$REPO_ROOT/SENTINEL" ]
  [ "$(jq -r .version "$HOME/.pi/agent/npm/node_modules/pi-powerline-footer/package.json")" = 2.3.4 ]
  run grep -E '^install npm:[^ ]+@[0-9]' "$HOME/pi-invocations"
  [ "$status" -eq 0 ]
  run grep -E '^install npm:(pi-powerline-footer|pi-amplike)$' "$HOME/pi-invocations"
  [ "$status" -eq 1 ]
}

@test "malformed or unreviewed promotion manifest fails before recovery or any mutation" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  mkdir -m 700 "$TEST_ROOT/private"
  local manifest="$TEST_ROOT/private/resolution.json" before
  printf '{"schemaVersion":1}\n' >"$manifest"
  chmod 600 "$manifest"
  before=$(snapshot_tree "$TEST_ROOT")
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions --resolution-manifest "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *manifest*schema* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  [ -z "$(find "$HOME/.pi/agent" -name 'package-recovery.*' -print)" ]
}

@test "explicit update rejects unsafe config ancestors before recovery or declaration publication" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1
  stub_existing_pi
  mkdir -p "$TEST_ROOT/foreign-config"
  ln -s "$TEST_ROOT/foreign-config" "$TEST_ROOT/xdg-alias"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env XDG_CONFIG_HOME="$TEST_ROOT/xdg-alias" bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -ne 0 ]
  [[ "$output" == *'symlink in managed path'*'/xdg-alias'* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
}

@test "explicit reset retains private ordinary config backups alongside recovery" {
  export PI_VERSION PI_AI_CONFIRM_STOPPED=1 PI_AI_RESET_MUTABLE_CONFIG=1
  stub_existing_pi
  printf '{"packages":[]}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"old":true}\n' >"$HOME/.pi/agent/modes.json"
  chmod 644 "$HOME/.pi/agent/settings.json" "$HOME/.pi/agent/modes.json"
  run bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$HOME/.pi/agent/settings.json.backup")" = 600 ]
  [ "$(stat -c %a "$HOME/.pi/agent/modes.json.backup")" = 600 ]
}

@test "installer rejects conflicting duplicate missing and relative update flags without mutation" {
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  local -a cases=('--check --update-extensions' '--update-extensions --update-extensions' '--check --check' '--resolution-manifest' '--resolution-manifest /tmp/unused.json' '--update-extensions --resolution-manifest relative.json')
  local args
  for args in "${cases[@]}"; do
    read -r -a argv <<<"$args"
    run bash "$REPO_ROOT/ai/pi/install.sh" "${argv[@]}"
    [ "$status" -eq 2 ]
    [[ "$output" == *usage:* || "$output" == *absolute*path* ]]
    [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  done
}

@test "managed Pi make ai-check with installed SDK leaves all temporary roots unchanged" {
  export PI_VERSION
  stub_existing_pi
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run make -C "$REPO_ROOT" ai-check
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  [ -z "$(find "$HOME/.pi/agent" -name 'package-recovery.*' -print)" ]
}

@test "Pi installer reuses a managed Pi without downgrading or reinstalling it" {
  export PI_VERSION=1.99.0
  stub_existing_pi
  stub_command curl 'printf "unexpected download\\n" >"$HOME/curl-invocation"; exit 1'

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/curl-invocation" ]
  [ -f "$TEST_ROOT/validator-events" ]
}

@test "Pi installer migrates the user-local npm copy without installing a repo-pinned Pi" {
  export PI_VERSION
  stub_pi_install
  mkdir -p "$HOME/.local/bin"
  cp "$TEST_ROOT/pi-fixture" "$HOME/.local/bin/pi"

  run env HOME="$HOME" PATH="$PATH" TMPDIR="$TEST_ROOT" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/pi" ]
  [ -x "$HOME/.pi/agent/bin/pi" ]
  [ -f "$HOME/.pi/agent/install/managed-install.json" ]
  [[ "$(<"$HOME/curl-invocation")" == '-fsSL https://pi.dev/install.sh -o '* ]]
  [ -z "$(find "$TEST_ROOT" -name 'pi-managed-installer.*' -print)" ]
  [[ "$(<"$HOME/install-path")" == "$HOME/.local/bin:$HOME/.pi/agent/bin:"* ]]
  [ ! -e "$HOME/npm-invocation" ]
}

@test "Pi installer keeps the legacy npm launcher when the managed download fails" {
  export PI_VERSION
  stub_pi_install
  mkdir -p "$HOME/.local/bin"
  cp "$TEST_ROOT/pi-fixture" "$HOME/.local/bin/pi"
  stub_command curl 'printf "touch \"%s\"\n" "$HOME/partial-script-ran"; if [[ "$*" == *" -o "* ]]; then printf "partial\n" >"${@: -1}"; fi; exit 22'

  run env HOME="$HOME" PATH="$PATH" TMPDIR="$TEST_ROOT" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [ -x "$HOME/.local/bin/pi" ]
  [ ! -e "$HOME/.pi/agent/bin/pi" ]
  [ ! -e "$HOME/partial-script-ran" ]
  [ -z "$(find "$TEST_ROOT" -name 'pi-managed-installer.*' -print)" ]
}

@test "Pi installer cleans up the downloaded script when it fails" {
  export PI_VERSION
  stub_pi_install
  stub_command curl 'printf "#!/bin/sh\nprintf script-ran >%s\nexit 42\n" "$HOME/script-ran" >"${@: -1}"'

  run env HOME="$HOME" PATH="$PATH" TMPDIR="$TEST_ROOT" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 42 ]
  [ -f "$HOME/script-ran" ]
  [ -z "$(find "$TEST_ROOT" -name 'pi-managed-installer.*' -print)" ]
  [ ! -e "$HOME/.pi/agent/bin/pi" ]
}

@test "Pi installer reuses a managed launcher outside the overridden HOME" {
  export PI_VERSION
  stub_existing_pi
  local external_agent="$TEST_ROOT/external-agent"
  stub_managed_pi_for_agent "$external_agent"
  rm "$HOME/.pi/agent/bin/pi" "$HOME/.pi/agent/install/managed-install.json"
  ln -s "$external_agent/bin/pi" "$STUB_BIN/pi"
  stub_command curl 'printf "unexpected download\\n" >"$HOME/curl-invocation"; exit 1'

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/curl-invocation" ]
  [ -x "$external_agent/bin/pi" ]
  [ -f "$TEST_ROOT/validator-events" ]
  [ -f "$HOME/.pi/agent/settings.json" ]
}

@test "Pi installer migrates a local npm copy before reusing an external managed launcher" {
  export PI_VERSION
  stub_pi_install
  local external_agent="$TEST_ROOT/external-agent"
  mkdir -p "$external_agent/bin" "$external_agent/install" "$HOME/.local/bin"
  cp "$TEST_ROOT/pi-fixture" "$external_agent/bin/pi"
  cp "$TEST_ROOT/pi-fixture" "$HOME/.local/bin/pi"
  printf '{"kind":"pi-managed-install","schemaVersion":1,"layout":"releases-v1"}\n' \
    >"$external_agent/install/managed-install.json"
  ln -s "$external_agent/bin/pi" "$STUB_BIN/pi"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/pi" ]
  [ -x "$HOME/.pi/agent/bin/pi" ]
  [ -e "$HOME/curl-invocation" ]
}

@test "Pi installer refuses an unrecognized destination even with another managed Pi on PATH" {
  export PI_VERSION
  stub_existing_pi
  local external_agent="$TEST_ROOT/external-agent"
  stub_managed_pi_for_agent "$external_agent"
  ln -s "$external_agent/bin/pi" "$STUB_BIN/pi"
  printf '#!/bin/sh\nexit 0\n' >"$HOME/.pi/agent/bin/pi"
  rm "$HOME/.pi/agent/install/managed-install.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to replace an unrecognized Pi launcher"* ]]
  [ ! -e "$HOME/pi-invocation" ]
}

@test "Pi installer refuses an unrelated Pi ahead of a fresh managed install" {
  export PI_VERSION
  stub_pi_install
  stub_command pi 'printf "foreign\\n"'
  local before after
  before=$(snapshot_home)

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_home)
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to migrate unrelated Pi"* ]]
  [ ! -e "$HOME/curl-invocation" ]
  [ "$before" = "$after" ]
}

@test "Pi installer prefers PATH Python for permission validation" {
  export PI_VERSION
  stub_existing_pi
  stub_command python3 '
    printf "%s\n" "$*" >>"$TEST_ROOT/python-invocations"
    exec /usr/bin/python3 "$@"
  '
  local agent_dir="$TEST_ROOT/path-python-agent"
  stub_managed_pi_for_agent "$agent_dir"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  grep -q '^-c import jsonschema$' "$TEST_ROOT/python-invocations"
  grep -Fq "$REPO_ROOT/libexec/validate-pi-permission-config --schema " "$TEST_ROOT/python-invocations"
  [ -f "$agent_dir/extensions/pi-permission-system/config.json" ]
}

@test "Pi installer falls back to system Python when PATH Python lacks jsonschema" {
  export PI_VERSION
  stub_existing_pi
  stub_command python3 'exec /usr/bin/python3 -S "$@"'
  local agent_dir="$TEST_ROOT/fallback-python-agent"
  stub_managed_pi_for_agent "$agent_dir"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/bin/python3"* ]]
  [ -f "$agent_dir/extensions/pi-permission-system/config.json" ]
  jq -e '.permission.bash["*"] == "allow"' \
    "$agent_dir/extensions/pi-permission-system/config.json"
  [ -f "$TEST_ROOT/validator-events" ]
}

@test "Pi check mode uses system Python fallback without mutation" {
  stub_command python3 'exec /usr/bin/python3 -S "$@"'
  local agent_dir="$TEST_ROOT/fallback-check-agent"
  local before after
  before=$(snapshot_tree "$TEST_ROOT")

  run env HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

@test "Pi installer reports missing jsonschema in both interpreters before mutation" {
  export PI_VERSION
  stub_existing_pi
  stub_command python3 'exec /usr/bin/python3 -S "$@"'
  mkdir -p "$TEST_ROOT/python-modules"
  printf 'raise ImportError("jsonschema unavailable for test")\n' \
    >"$TEST_ROOT/python-modules/jsonschema.py"
  export PYTHONPATH="$TEST_ROOT/python-modules" PYTHONDONTWRITEBYTECODE=1
  local agent_dir="$TEST_ROOT/missing-jsonschema-agent"
  local before after
  before=$(snapshot_tree "$TEST_ROOT")

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"Python jsonschema is required for Pi permission validation"* ]]
  [[ "$output" == *"install the Python jsonschema module"* ]]
  [[ "$output" != *"python3-jsonschema"* ]]
  [[ "$output" != *"fails the exact installed schema"* ]]
  [ "$before" = "$after" ]
  [ ! -e "$agent_dir" ]
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
  [[ "$output" == *"$agent_dir/pi-file-context.json"* ]]
  [[ "$output" == *"$agent_dir/dotfiles-migrations.json"* ]]
  [[ "$output" == *"$agent_dir/agents/rush.md"* ]]
  [[ "$output" == *"$agent_dir/agents/smart.md"* ]]
  [[ "$output" == *"$agent_dir/agents/deep.md"* ]]
  [[ "$output" == *"$agent_dir/agents/review.md"* ]]
  [[ "$output" == *"$agent_dir/extensions/herdr-agent-state.ts"* ]]
  [[ "$output" == *"$agent_dir/extensions/herdr-prompt-state.ts"* ]]
  [[ "$output" == *"$agent_dir/extensions/worktree-guard.ts"* ]]
  [[ "$output" == *"$agent_dir/extensions/pi-permission-system/config.json"* ]]
  [[ "$output" != *"$agent_dir/sandbox.json"* ]]
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
  stub_command install 'printf "shadow install invoked\\n" >"$HOME/shadow-install"; exit 99'
  cat >"$HOME/.pi/agent/settings.json" <<'JSON'
{"theme":"custom","lastChangelogVersion":"seen","unknown":{"keep":true},"packages":["old"]}
JSON

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/shadow-install" ]
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
  assert_symlink_target "$HOME/.pi/agent/extensions/herdr-prompt-state.ts" \
    "$REPO_ROOT/ai/pi/extensions/herdr-prompt-state.ts"
  assert_symlink_target "$HOME/.pi/agent/extensions/worktree-guard.ts" \
    "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts"

  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$HOME/.pi/agent/modes.json"
  [ ! -e "$HOME/.pi/agent/models.json" ]
  cmp "$REPO_ROOT/ai/pi/config/file-context.json" "$HOME/.pi/agent/pi-file-context.json"
  [ ! -e "$HOME/.pi/agent/sandbox.json" ]
  cmp "$REPO_ROOT/ai/pi/config/subagents.json" "$HOME/.pi/agent/subagents.json"
  cmp "$REPO_ROOT/ai/pi/config/web-search.json" "$XDG_CONFIG_HOME/pi/web-search.json"
  [ "$(stat -c '%a' "$HOME/.pi/agent/settings.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/modes.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/pi-file-context.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/extensions/pi-permission-system/config.json")" = 644 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/subagents.json")" = 600 ]
  [ "$(stat -c '%a' "$XDG_CONFIG_HOME/pi/web-search.json")" = 600 ]
  [ "$(stat -c '%a' "$HOME/.pi/agent/extensions/pi-permission-system")" = 700 ]
  run jq -e --arg auth "$HOME/.pi/agent/auth.json" '
    .permission.path_read[$auth] == "deny"
    and .permission.path_write[$auth] == "deny"
    and ([paths(scalars) as $path | getpath($path) | strings | select(contains("__PI_AGENT_DIR__"))] | length == 0)
  ' "$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/validator-events" ]
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
    source "$REPO_ROOT/libexec/common.sh"
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

@test "Pi keybindings retain message copy and model-clear shortcuts" {
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

@test "Pi selects the floating workflow and security packages" {
  run jq -e '
    [.packages[] | if type == "string" then . else .source end] as $sources
    | ($sources | index("git:github.com/tmustier/pi-queue-steer")) != null
    and ($sources | index("npm:pi-web-access")) != null
    and ($sources | index("npm:@narumitw/pi-lsp")) != null
    and ($sources | index("npm:@gotgenes/pi-subagents")) != null
    and ($sources | index("npm:@gotgenes/pi-permission-system")) != null
    and ($sources | map(select(contains("pi-sandbox"))) | length == 0)
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi installer resets permissions before disabling sandbox" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  mkdir -p "$(dirname "$permission")"
  printf '{"yoloMode":true,"permission":{"bash":{"*":"allow"}}}\n' >"$permission"
  jq '.excludedExtensionPackages += ["git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72"]' \
    "$REPO_ROOT/ai/pi/config/subagents.json" >"$HOME/.pi/agent/subagents.json"
  jq '.packages += ["git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72"]' \
    "$REPO_ROOT/ai/pi/settings.json" >"$HOME/.pi/agent/settings.json"
  printf '{"custom":"retired policy"}\n' >"$HOME/.pi/agent/sandbox.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  run jq -e '.yoloMode == false and .permission.bash["*"] == "allow"' "$permission"
  [ "$status" -eq 0 ]
  run jq -e '
    [.excludedExtensionPackages[] | select(contains("pi-sandbox"))] | length == 0
  ' "$HOME/.pi/agent/subagents.json"
  [ "$status" -eq 0 ]
  run jq -e '
    [.packages[] | if type == "string" then . else .source end]
    | map(select(contains("pi-sandbox"))) | length == 0
  ' "$HOME/.pi/agent/settings.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .custom "$HOME/.pi/agent/sandbox.json")" = "retired policy" ]
  [ "$(find "$HOME/.pi/agent" -name '*.backup*' | wc -l)" -eq 2 ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME/.pi/agent" -name '*.backup*' | wc -l)" -eq 2 ]
}

@test "Pi installer replaces malformed or partial permissions during sandbox retirement" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  mkdir -p "$(dirname "$permission")"

  local policy
  for policy in '{invalid' '{"yoloMode":true}'; do
    printf '%s\n' "$policy" >"$permission"
    jq '.packages += ["git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72"]' \
      "$REPO_ROOT/ai/pi/settings.json" >"$HOME/.pi/agent/settings.json"

    run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
      bash "$REPO_ROOT/ai/pi/install.sh"

    [ "$status" -eq 0 ]
    run jq -e '.yoloMode == false and .permission.bash["*"] == "allow"' "$permission"
    [ "$status" -eq 0 ]
    run jq -e '
      [.packages[] | if type == "string" then . else .source end]
      | map(select(contains("pi-sandbox"))) | length == 0
    ' "$HOME/.pi/agent/settings.json"
    [ "$status" -eq 0 ]
  done
}

@test "Pi installer refuses malformed package entries before disabling sandbox" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  mkdir -p "$(dirname "$permission")"
  printf '{"yoloMode":true,"permission":{"bash":{"*":"allow"}}}\n' >"$permission"
  jq '.packages += [42, "git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72"]' \
    "$REPO_ROOT/ai/pi/settings.json" >"$HOME/.pi/agent/settings.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot safely inspect Pi package inventory"* ]]
  run jq -e '
    [.packages[] | strings | select(contains("pi-sandbox"))] | length == 1
  ' "$HOME/.pi/agent/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi installer preserves healthy preexisting npm resolutions without reinstalling them" {
  export PI_TEST_NPM_VERSION=$FIXTURE_PERMISSION_VERSION
  export PI_VERSION
  stub_existing_pi
  local source
  while IFS= read -r source; do
    "$HOME/.pi/agent/bin/pi" install "$source"
  done < <(jq -r '.packages[] | if type == "object" then .source else . end
    | select(startswith("npm:"))' "$REPO_ROOT/ai/pi/settings.json")
  rm -f "$HOME/pi-invocations" "$HOME/pi-invocation"

  run bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  run grep -E '^install npm:' "$HOME/pi-invocations"
  [ "$status" -eq 1 ]
  [ "$(jq -r .version "$HOME/.pi/agent/npm/node_modules/@gotgenes/pi-permission-system/package.json")" = "$FIXTURE_PERMISSION_VERSION" ]
}

@test "Pi installer explicitly installs missing floating npm packages including parent UI resources" {
  export PI_VERSION
  stub_existing_pi

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  for source in \
    "npm:pi-web-access" \
    "npm:@narumitw/pi-lsp" \
    "npm:@gotgenes/pi-permission-system" \
    "npm:@gotgenes/pi-subagents" \
    "npm:@narumitw/pi-worktree" \
    "npm:@narumitw/pi-file-context"; do
    run grep -Fx "install $source" "$HOME/pi-invocations"
    [ "$status" -eq 0 ]
  done
}

@test "Pi installer repairs a matching permission package with a missing required artifact" {
  export PI_VERSION
  stub_existing_pi
  local package_root="$HOME/.pi/agent/npm/node_modules/@gotgenes/pi-permission-system"
  local missing
  mkdir -p "$package_root/schemas" "$package_root/src"
  printf '{"name":"@gotgenes/pi-permission-system","version":"%s"}\n' \
    "$FIXTURE_PERMISSION_VERSION" >"$package_root/package.json"

  for missing in schemas/permissions.schema.json src/permission-manager.ts; do
    cp "$TEST_ROOT/permission-system-schema.json" \
      "$package_root/schemas/permissions.schema.json"
    printf 'export class PermissionManager {}\n' \
      >"$package_root/src/permission-manager.ts"
    rm "$package_root/$missing"
    : >"$HOME/pi-invocations"

    run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
      bash "$REPO_ROOT/ai/pi/install.sh"

    [ "$status" -eq 0 ]
    [ -f "$package_root/schemas/permissions.schema.json" ]
    [ -f "$package_root/src/permission-manager.ts" ]
    [ "$(grep -Fxc "install npm:@gotgenes/pi-permission-system@$FIXTURE_PERMISSION_VERSION" \
      "$HOME/pi-invocations")" -eq 1 ]
  done
}

@test "Pi installer fails when permission package reinstall remains incomplete" {
  export PI_VERSION
  stub_existing_pi
  local package_root="$HOME/.pi/agent/npm/node_modules/@gotgenes/pi-permission-system"
  mkdir -p "$package_root/schemas"
  printf '{"name":"@gotgenes/pi-permission-system","version":"%s"}\n' \
    "$FIXTURE_PERMISSION_VERSION" >"$package_root/package.json"
  cp "$TEST_ROOT/permission-system-schema.json" \
    "$package_root/schemas/permissions.schema.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_TEST_OMIT_PERMISSION_MANAGER=1 bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"incomplete package npm:@gotgenes/pi-permission-system"* ]]
  [[ "$output" == *"src/permission-manager.ts"* ]]
  [ "$(grep -Fxc "install npm:@gotgenes/pi-permission-system@$FIXTURE_PERMISSION_VERSION" \
    "$HOME/pi-invocations")" -eq 1 ]
  [ ! -e "$package_root/src/permission-manager.ts" ]
}

@test "Pi installer hashes permission policy with the macOS shasum fallback" {
  export PI_VERSION
  stub_existing_pi
  local fallback_bin="$TEST_ROOT/fallback-bin"
  local command name
  mkdir -p "$fallback_bin"
  for command in /usr/bin/*; do
    name=${command##*/}
    [[ "$name" == sha256sum || "$name" == shasum ]] && continue
    ln -s "$command" "$fallback_bin/$name"
  done
  cat >"$fallback_bin/shasum" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >>"$HOME/shasum-invocations"
[[ "$1" == -a && "$2" == 256 ]] || exit 2
printf '%064d  %s\n' 0 "$3"
SCRIPT
  chmod +x "$fallback_bin/shasum"
  ln -sf "$STUB_BIN/npm" "$fallback_bin/npm"
  ln -sf "$STUB_BIN/git" "$fallback_bin/git"
  ln -sf "$STUB_BIN/node" "$fallback_bin/node"

  run env HOME="$HOME" PATH="$fallback_bin" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ -s "$HOME/shasum-invocations" ]
  grep -Fq -- '-a 256 ' "$HOME/shasum-invocations"
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

@test "Pi loads permission-system and enables code actions without sandbox" {
  run jq -e '
    [.packages[] | if type == "string" then . else .source end] as $sources
    | ($sources | index("npm:@gotgenes/pi-permission-system")) != null
    and ($sources | map(select(contains("pi-sandbox"))) | length == 0)
    and ([.packages[] | objects | select(.source == "git:github.com/tmustier/pi-extensions")][0].extensions
      | index("code-actions/index.ts")) != null
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi loads the complete Superpowers package" {
  run jq -e '
    [.packages[] | objects | select(.source == "git:github.com/obra/superpowers")]
    | length == 1
      and (.[0] | has("extensions") | not)
      and (.[0] | has("skills") | not)
      and (.[0] | has("prompts") | not)
      and (.[0] | has("themes") | not)
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi loads only selected agent-skills without its router" {
  run jq -e '
    [.packages[] | objects | select(.source == "git:github.com/addyosmani/agent-skills")]
    | length == 1
      and .[0].extensions == []
      and .[0].prompts == []
      and .[0].themes == []
      and (.[0].skills | sort) == [
        "skills/performance-optimization/SKILL.md",
        "skills/security-and-hardening/SKILL.md"
      ]
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "Pi installer publishes authoritative permission policy while preserving runtime controls" {
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
  [ "$(jq -r .custom "$HOME/.pi/agent/models.json")" = models ]
  run jq -s -e --arg agent_dir "$HOME/.pi/agent" '
    .[0] as $runtime
    | (.[1] | walk(
        if type == "object" then
          with_entries(.key |= gsub("__PI_AGENT_DIR__"; $agent_dir))
        elif type == "string" then
          gsub("__PI_AGENT_DIR__"; $agent_dir)
        else
          .
        end
      )) as $baseline
    | $runtime.permission == $baseline.permission
    and $runtime.debugLog == true
    and $runtime.permissionReviewLog == true
    and $runtime.yoloMode == false
    and ($runtime | has("custom") | not)
  ' "$HOME/.pi/agent/extensions/pi-permission-system/config.json" \
    "$REPO_ROOT/ai/pi/config/permission-system.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .custom "$HOME/.pi/agent/sandbox.json")" = sandbox ]
  [ "$(jq -r .custom "$HOME/.pi/agent/subagents.json")" = subagents ]
  [ "$(jq -r .custom "$XDG_CONFIG_HOME/pi/web-search.json")" = web ]
  [[ "$install_output" == *preserved* ]]
  [[ "$install_output" == *PI_AI_RESET_MUTABLE_CONFIG=1* ]]
  [ "$(find "$HOME/.pi/agent/extensions/pi-permission-system" -name 'config.json.backup*' | wc -l)" -eq 1 ]
  [ -f "$HOME/.pi/agent/subagents.json.backup" ]
  jq -e '.custom == "subagents"' "$HOME/.pi/agent/subagents.json.backup"
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 2 ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME/.pi/agent/extensions/pi-permission-system" -name 'config.json.backup*' | wc -l)" -eq 1 ]
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 2 ]
}

@test "Pi installer refuses active YOLO permission policy replacement even during reset" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]

  local candidate="$TEST_ROOT/active-yolo.json" before after
  jq '.yoloMode = true' "$permission" >"$candidate"
  mv "$candidate" "$permission"
  before=$(snapshot_home)

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_AI_RESET_MUTABLE_CONFIG=1 bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_home)
  [ "$status" -ne 0 ]
  [[ "$output" == *"disable YOLO"* ]]
  [ "$before" = "$after" ]
  run jq -e '.yoloMode == true' "$permission"
  [ "$status" -eq 0 ]
}

@test "Pi installer validates the permission policy candidate before backup or publication" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  local package_root="$HOME/.pi/agent/npm/node_modules/@gotgenes/pi-permission-system"
  local original="$TEST_ROOT/original-permission.json"
  mkdir -p "$package_root/schemas"
  printf '{"name":"@gotgenes/pi-permission-system","version":"%s"}\n' \
    "$FIXTURE_PERMISSION_VERSION" >"$package_root/package.json"
  mkdir -p "$package_root/src"
  printf 'export class PermissionManager {}\n' >"$package_root/src/permission-manager.ts"
  cat >"$package_root/schemas/permissions.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "permission": {
      "type": "object",
      "properties": {
        "bash": {
          "type": "object",
          "properties": {"*": {"const": "deny"}}
        }
      }
    }
  }
}
JSON
  seed_mutable_pi_drift "$HOME/.pi/agent" "$XDG_CONFIG_HOME/pi/web-search.json"
  cp "$permission" "$original"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"permission schema"* ]]
  cmp "$original" "$permission"
  [ "$(find "$(dirname "$permission")" -name 'config.json.backup*' | wc -l)" -eq 0 ]
}

@test "Pi installer migrates invalid runtime permission policy controls without preserving them" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  local original="$TEST_ROOT/invalid-runtime-permission.json"
  mkdir -p "$(dirname "$permission")"
  printf '{"debugLog":"yes","permissionReviewLog":null,"yoloMode":false,"permission":{"bash":{"*":"ask"}},"custom":"invalid"}\n' \
    >"$permission"
  cp "$permission" "$original"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  cmp "$original" "$permission.backup"
  run jq -e '
    .debugLog == false
    and .permissionReviewLog == false
    and .yoloMode == false
    and .permission.bash["*"] == "allow"
    and (has("custom") | not)
  ' "$permission"
  [ "$status" -eq 0 ]
  [ "$(find "$(dirname "$permission")" -name 'config.json.backup*' | wc -l)" -eq 1 ]
}

@test "Pi installer preserves a concurrent runtime permission policy change" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]

  local drift="$TEST_ROOT/permission-drift.json"
  jq '.permission.bash["*"] = "ask"' "$permission" >"$drift"
  mv "$drift" "$permission"

  local hook="$BATS_TEST_TMPDIR/permission-before-publish"
  local output_file="$BATS_TEST_TMPDIR/concurrent-runtime-output"
  local pid attempt concurrent_status race_output
  mkdir -p "$hook"
  env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" BATS_TEST_NAME="$BATS_TEST_NAME" \
    BATS_TEST_FILENAME="$BATS_TEST_FILENAME" \
    PI_AI_TEST_PERMISSION_BEFORE_PUBLISH="$hook" \
    bash "$REPO_ROOT/ai/pi/install.sh" >"$output_file" 2>&1 &
  pid=$!

  for attempt in $(seq 1 500); do
    [[ -e "$hook/ready" ]] && break
    sleep 0.01
  done
  if [[ ! -e "$hook/ready" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    false
  fi

  jq '.debugLog = true | .custom = "concurrent"' "$permission" >"$drift"
  mv "$drift" "$permission"
  touch "$hook/continue"
  if wait "$pid"; then
    concurrent_status=0
  else
    concurrent_status=$?
  fi
  race_output=$(<"$output_file")

  [ "$concurrent_status" -ne 0 ]
  [[ "$race_output" == *"changed during reconciliation"* ]]
  run jq -e '
    .debugLog == true
    and .custom == "concurrent"
    and .permission.bash["*"] == "ask"
  ' "$permission"
  [ "$status" -eq 0 ]
  [ "$(find "$(dirname "$permission")" -name 'config.json.backup*' | wc -l)" -eq 0 ]
}

@test "Pi installer preserves a runtime permission change after backup" {
  export PI_VERSION
  stub_existing_pi
  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]

  local drift="$TEST_ROOT/post-backup-permission-drift.json"
  jq '.permission.bash["*"] = "ask"' "$permission" >"$drift"
  mv "$drift" "$permission"

  local hook="$BATS_TEST_TMPDIR/permission-before-publish-after-backup"
  local output_file="$BATS_TEST_TMPDIR/post-backup-runtime-output"
  local pid attempt concurrent_status race_output
  mkdir -p "$hook"
  env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" BATS_TEST_NAME="$BATS_TEST_NAME" \
    BATS_TEST_FILENAME="$BATS_TEST_FILENAME" \
    PI_AI_TEST_PERMISSION_BEFORE_PUBLISH="$hook" \
    bash "$REPO_ROOT/ai/pi/install.sh" >"$output_file" 2>&1 &
  pid=$!

  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -e "$hook/ready" ]] && break
    sleep 0.01
  done
  if [[ ! -e "$hook/ready" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    false
  fi
  touch "$hook/continue"

  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -e "$hook/ready-before-publish" ]] && break
    sleep 0.01
  done
  if [[ ! -e "$hook/ready-before-publish" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    false
  fi

  jq '.debugLog = true | .custom = "post-backup-concurrent"' "$permission" >"$drift"
  mv "$drift" "$permission"
  touch "$hook/continue-before-publish"
  if wait "$pid"; then
    concurrent_status=0
  else
    concurrent_status=$?
  fi
  race_output=$(<"$output_file")

  [ "$concurrent_status" -ne 0 ]
  [[ "$race_output" == *"changed during reconciliation"* ]]
  run jq -e '
    .debugLog == true
    and .custom == "post-backup-concurrent"
    and .permission.bash["*"] == "ask"
  ' "$permission"
  [ "$status" -eq 0 ]
  [ "$(find "$(dirname "$permission")" -name 'config.json.backup*' | wc -l)" -eq 1 ]
}

@test "Pi installer confines the permission policy race hook to Bats temporary paths" {
  export PI_VERSION
  stub_existing_pi
  local hook="$BATS_TEST_TMPDIR/non-bats-hook"
  local non_bats_agent="$TEST_ROOT/non-bats-hook-agent"
  local before after
  mkdir -p "$hook"
  before=$(snapshot_tree "$TEST_ROOT")

  run env -u BATS_TEST_TMPDIR -u BATS_TEST_NAME -u BATS_TEST_FILENAME \
    HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$non_bats_agent" \
    PI_AI_TEST_PERMISSION_BEFORE_PUBLISH="$hook" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -ne 0 ]
  [[ "$output" == *"unavailable outside Bats"* ]]
  [ "$before" = "$after" ]
  [ ! -e "$hook/ready" ]
  [ ! -e "$non_bats_agent" ]

  local permission="$HOME/.pi/agent/extensions/pi-permission-system/config.json"
  local drift="$TEST_ROOT/hook-policy-drift.json"
  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  jq '.permission.bash["*"] = "ask"' "$permission" >"$drift"
  mv "$drift" "$permission"

  local outside_hook
  outside_hook="$(dirname "$BATS_TEST_TMPDIR")/outside-permission-hook-${BATS_TEST_NUMBER:-0}"
  mkdir -p "$outside_hook"
  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" BATS_TEST_NAME="$BATS_TEST_NAME" \
    BATS_TEST_FILENAME="$BATS_TEST_FILENAME" \
    PI_AI_TEST_PERMISSION_BEFORE_PUBLISH="$outside_hook" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"below the Bats test root"* ]]
  [ ! -e "$outside_hook/ready" ]
  run jq -e '.permission.bash["*"] == "ask"' "$permission"
  [ "$status" -eq 0 ]
}

@test "Pi installer converts a recognized permission policy link after validation" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/recognized-permission-agent"
  stub_managed_pi_for_agent "$agent_dir"
  local permission="$agent_dir/extensions/pi-permission-system/config.json"
  mkdir -p "$(dirname "$permission")"
  ln -s "$REPO_ROOT/ai/pi/config/permission-system.json" "$permission"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agent_dir" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$permission" ]
  [ ! -L "$permission" ]
  [ -f "$permission.backup" ]
  [ "$(stat -c '%a' "$permission")" = 644 ]
  run jq -e --arg auth "$agent_dir/auth.json" '
    .yoloMode == false
    and .permission.path_read[$auth] == "deny"
    and .permission.path_write[$auth] == "deny"
  ' "$permission"
  [ "$status" -eq 0 ]
}

@test "Pi installer refuses foreign permission policy symlinks and invalid destination types" {
  export PI_VERSION
  stub_existing_pi
  local foreign="$TEST_ROOT/foreign-permission-config.json"
  local symlink_agent="$TEST_ROOT/foreign-permission-config-agent"
  local symlink_permission="$symlink_agent/extensions/pi-permission-system/config.json"
  mkdir -p "$(dirname "$symlink_permission")"
  printf '{"foreign":true}\n' >"$foreign"
  ln -s "$foreign" "$symlink_permission"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$symlink_agent" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  assert_symlink_target "$symlink_permission" "$foreign"
  [ "$(jq -r .foreign "$foreign")" = true ]

  local invalid_agent="$TEST_ROOT/invalid-permission-config-agent"
  local invalid_permission="$invalid_agent/extensions/pi-permission-system/config.json"
  mkdir -p "$invalid_permission"
  printf 'preserve\n' >"$invalid_permission/marker"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$invalid_agent" bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -ne 0 ]
  [ -d "$invalid_permission" ]
  [ "$(cat "$invalid_permission/marker")" = preserve ]
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
  [ ! -e "$HOME/.pi/agent/models.json.backup" ]
  [ "$(jq -r .custom "$HOME/.pi/agent/models.json")" = models ]
  [ -f "$HOME/.pi/agent/extensions/pi-permission-system/config.json.backup" ]
  [ ! -e "$HOME/.pi/agent/sandbox.json.backup" ]
  [ "$(jq -r .custom "$HOME/.pi/agent/sandbox.json")" = sandbox ]
  [ -f "$HOME/.pi/agent/subagents.json.backup" ]
  [ -f "$XDG_CONFIG_HOME/pi/web-search.json.backup" ]
  cmp "$REPO_ROOT/ai/pi/settings.json" "$HOME/.pi/agent/settings.json"
  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$HOME/.pi/agent/modes.json"
  [ "$(jq -r .custom "$HOME/.pi/agent/models.json")" = models ]
  cmp "$REPO_ROOT/ai/pi/config/subagents.json" "$HOME/.pi/agent/subagents.json"
  cmp "$REPO_ROOT/ai/pi/config/web-search.json" "$XDG_CONFIG_HOME/pi/web-search.json"
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 5 ]

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_AI_RESET_MUTABLE_CONFIG=1 bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$(find "$HOME" -name '*.backup*' | wc -l)" -eq 5 ]
}

@test "Pi installer converts recognized legacy links without discarding readable state" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/legacy-agent"
  stub_managed_pi_for_agent "$agent_dir"
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

@test "Pi explicit refresh accepts readable legacy modes links without preflight mutation" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/refresh-legacy-agent" canonical="$TEST_ROOT/canonical-dotfiles"
  stub_managed_pi_for_agent "$agent_dir"
  mkdir -p "$canonical/ai/pi"
  printf '{"currentMode":"smart","extra":true,"modes":{"smart":{"provider":"github-copilot","modelId":"gpt-5.6-sol","color":"pink"}}}\n' >"$canonical/ai/pi/modes.json"
  ln -s "$canonical/ai/pi/modes.json" "$agent_dir/modes.json"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/modes.json" ]
  jq -s -e '.[0].modes.smart.modelId == .[1].modes.smart.modelId and .[0].modes.smart.color == "pink" and .[0].extra == true' \
    "$agent_dir/modes.json" "$REPO_ROOT/ai/pi/config/modes.json"
  cmp "$canonical/ai/pi/modes.json" "$agent_dir/modes.json.backup"
  [ "$(stat -c %a "$agent_dir/modes.json.backup")" = 600 ]
  local count
  count=$(find "$agent_dir" -name 'modes.json.backup*' | wc -l)
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ "$count" = "$(find "$agent_dir" -name 'modes.json.backup*' | wc -l)" ]
}

@test "Pi explicit refresh accepts supported dangling legacy modes links without preflight mutation" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/refresh-dangling-agent"
  stub_managed_pi_for_agent "$agent_dir"
  ln -s "$REPO_ROOT/ai/pi/modes.json" "$agent_dir/modes.json"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env PI_AI_REFRESH_PREFERENCES=1 PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  run env PI_AI_REFRESH_PREFERENCES=1 PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/modes.json" ]
  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$agent_dir/modes.json"
  [ ! -e "$agent_dir/modes.json.backup" ]
}

@test "Pi explicit refresh accepts supported dangling settings links without preflight mutation" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/refresh-dangling-settings" canonical="$TEST_ROOT/dangling-dotfiles"
  stub_managed_pi_for_agent "$agent_dir"
  ln -s "$TEST_ROOT/retired-dotfiles" "$canonical"
  ln -s "$canonical/ai/pi/settings.json" "$agent_dir/settings.json"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -eq 0 ]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/settings.json" ]
  cmp "$REPO_ROOT/ai/pi/settings.json" "$agent_dir/settings.json"
  [ ! -e "$agent_dir/settings.json.backup" ]
}

@test "Pi explicit update with refresh captures readable legacy modes links before conversion" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/update-legacy-agent" canonical="$HOME/.dotfiles"
  stub_managed_pi_for_agent "$agent_dir"
  mkdir -p "$canonical/ai/pi"
  printf '{"packages":[]}\n' >"$agent_dir/settings.json"
  printf '{"extra":"old-modes","modes":{"smart":{"provider":"github-copilot","modelId":"gpt-5.6-sol","color":"pink"}}}\n' >"$canonical/ai/pi/modes.json"
  ln -s "$canonical/ai/pi/modes.json" "$agent_dir/modes.json"
  run env PI_AI_REFRESH_PREFERENCES=1 DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/modes.json" ]
  local captures=("$agent_dir"/package-recovery.*/recovery.json) backup
  jq -e --arg target "$canonical/ai/pi/modes.json" '.configBackups[] | select(.destination | endswith("/modes.json")) | .state == "owned-link" and .linkTarget == $target' "${captures[0]}"
  backup=$(jq -r '.configBackups[] | select(.destination | endswith("/modes.json")) | .backupPath' "${captures[0]}")
  cmp "$canonical/ai/pi/modes.json" "$backup"
  jq -e '.modes.smart.modelId == "gpt-5.6-sol" and .extra == "old-modes"' "$backup"
  [ "$(stat -c %a "$backup")" = 600 ]
  jq -s -e '.[0].modes.smart.modelId == .[1].modes.smart.modelId and .[0].modes.smart.color == "pink" and .[0].extra == "old-modes"' \
    "$agent_dir/modes.json" "$REPO_ROOT/ai/pi/config/modes.json"
}

@test "Pi explicit update with refresh captures supported dangling legacy modes links before conversion" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/update-dangling-agent"
  stub_managed_pi_for_agent "$agent_dir"
  printf '{"packages":[]}\n' >"$agent_dir/settings.json"
  ln -s "$REPO_ROOT/ai/pi/modes.json" "$agent_dir/modes.json"
  run env PI_AI_REFRESH_PREFERENCES=1 PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --update-extensions
  [ "$status" -eq 0 ]
  [ ! -L "$agent_dir/modes.json" ]
  local captures=("$agent_dir"/package-recovery.*/recovery.json)
  jq -e --arg target "$REPO_ROOT/ai/pi/modes.json" '.configBackups[] | select(.destination | endswith("/modes.json")) | .state == "owned-link" and .linkTarget == $target and .missingTarget == true and (has("backupPath") | not)' "${captures[0]}"
  cmp "$REPO_ROOT/ai/pi/config/modes.json" "$agent_dir/modes.json"
}

@test "Pi explicit refresh still refuses foreign legacy-shaped modes links without mutation" {
  local agent_dir="$TEST_ROOT/foreign-refresh-agent" foreign="$TEST_ROOT/foreign/ai/pi/modes.json"
  mkdir -p "$agent_dir" "$(dirname "$foreign")"
  printf '{invalid\n' >"$foreign"
  ln -s "$foreign" "$agent_dir/modes.json"
  local before
  before=$(snapshot_tree "$TEST_ROOT")
  run env PI_AI_REFRESH_PREFERENCES=1 PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *foreign*mutable*symlink* ]]
  [ "$before" = "$(snapshot_tree "$TEST_ROOT")" ]
}

@test "Pi installer replaces a dangling recognized settings link with the baseline" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/dangling-settings-agent"
  stub_managed_pi_for_agent "$agent_dir"
  local canonical="$TEST_ROOT/canonical-dotfiles"
  mkdir -p "$agent_dir"
  ln -s "$TEST_ROOT/retired-dotfiles" "$canonical"
  ln -s "$canonical/ai/pi/settings.json" "$agent_dir/settings.json"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    DOTFILES="$canonical" PI_CODING_AGENT_DIR="$agent_dir" \
    bash "$REPO_ROOT/ai/pi/install.sh"

  [ "$status" -eq 0 ]
  [ -f "$agent_dir/settings.json" ]
  [ ! -L "$agent_dir/settings.json" ]
  cmp "$REPO_ROOT/ai/pi/settings.json" "$agent_dir/settings.json"
  [ ! -e "$agent_dir/settings.json.backup" ]
  [[ "$output" != *"Backed up Pi settings"* ]]
}

@test "Pi installer replaces a dangling recognized modes link with the baseline" {
  export PI_VERSION
  stub_existing_pi
  local agent_dir="$TEST_ROOT/dangling-agent"
  stub_managed_pi_for_agent "$agent_dir"
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
  stub_managed_pi_for_agent "$agent_dir"
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

  local agents_agent="$TEST_ROOT/foreign-agents-agent"
  local foreign_agents="$TEST_ROOT/foreign-agents"
  mkdir -p "$agents_agent" "$foreign_agents"
  printf 'foreign\n' >"$foreign_agents/marker"
  ln -s "$foreign_agents" "$agents_agent/agents"

  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" \
    PI_CODING_AGENT_DIR="$agents_agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  assert_symlink_target "$agents_agent/agents" "$foreign_agents"
  [ "$(cat "$foreign_agents/marker")" = foreign ]
  [ ! -e "$foreign_agents/rush.md" ]
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
    PI_CODING_AGENT_DIR="$HOME/.pi/agent/." bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical checkout"* || "$output" == *"dot segments"* ]]

  local agent_alias="$TEST_ROOT/production-agent-alias"
  ln -s "$HOME/.pi/agent" "$agent_alias"
  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" DOTFILES="$canonical" \
    PI_CODING_AGENT_DIR="$agent_alias" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical checkout"* ]]

  stub_managed_pi_for_agent "$TEST_ROOT/isolated-agent"
  run env HOME="$HOME" PATH="$PATH" PI_VERSION="$PI_VERSION" DOTFILES="$canonical" \
    PI_CODING_AGENT_DIR="$TEST_ROOT/isolated-agent" bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
}

@test "Pi security migration removes exact managed Amp settings links" {
  local agent_dir="$TEST_ROOT/migration-agent"
  local amp_settings="$TEST_ROOT/amp/settings.json"
  local current_root="$TEST_ROOT/current-root"
  local canonical_root="$TEST_ROOT/canonical-root"
  mkdir -p "$agent_dir" "$(dirname "$amp_settings")"

  ln -s "$current_root/ai/pi/permissions.json" "$amp_settings"
  run_security_migration apply "$agent_dir" "$amp_settings" "$current_root" "$canonical_root"
  [ "$status" -eq 0 ]
  [ ! -L "$amp_settings" ]

  ln -s "$canonical_root/ai/pi/permissions.json" "$amp_settings"
  run_security_migration apply "$agent_dir" "$amp_settings" "$current_root" "$canonical_root"
  [ "$status" -eq 0 ]
  [ ! -L "$amp_settings" ]
}

@test "Pi security migration preserves real and foreign Amp settings" {
  local agent_dir="$TEST_ROOT/migration-agent"
  local amp_settings="$TEST_ROOT/amp/settings.json"
  local managed_root="$TEST_ROOT/managed-root"
  mkdir -p "$agent_dir" "$(dirname "$amp_settings")"
  printf '{"custom":true}\n' >"$amp_settings"

  run_security_migration apply "$agent_dir" "$amp_settings" "$managed_root"
  [ "$status" -eq 0 ]
  [ "$(jq -r .custom "$amp_settings")" = true ]
  [[ "$output" == *"Preserving"* ]]

  rm "$amp_settings"
  ln -s "$TEST_ROOT/foreign-settings.json" "$amp_settings"
  run_security_migration apply "$agent_dir" "$amp_settings" "$managed_root"
  [ "$status" -eq 0 ]
  assert_symlink_target "$amp_settings" "$TEST_ROOT/foreign-settings.json"
  [[ "$output" == *"foreign"* ]]
}

@test "Pi security migration removes only the Amp permissions object" {
  local agent_dir="$TEST_ROOT/migration-agent"
  local amp_settings="$TEST_ROOT/amp/settings.json"
  mkdir -p "$agent_dir"
  printf '{"permissions":{"mode":"yolo"}}\n' >"$agent_dir/amplike.json"

  run_security_migration apply "$agent_dir" "$amp_settings" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$agent_dir/amplike.json" ]

  printf '{"permissions":{"mode":"yolo"},"other":{"keep":true}}\n' \
    >"$agent_dir/amplike.json"
  run_security_migration apply "$agent_dir" "$amp_settings" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run jq -e '(has("permissions") | not) and .other.keep == true' "$agent_dir/amplike.json"
  [ "$status" -eq 0 ]
}

@test "Pi security migration preserves malformed and non-object Amp state" {
  local agent_dir="$TEST_ROOT/migration-agent"
  local amp_settings="$TEST_ROOT/amp/settings.json"
  local value
  mkdir -p "$agent_dir"
  for value in 'not json' '[]'; do
    printf '%s\n' "$value" >"$agent_dir/amplike.json"
    run_security_migration apply "$agent_dir" "$amp_settings" "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$(cat "$agent_dir/amplike.json")" = "$value" ]
    [[ "$output" == *"Preserving"* ]]
  done
}

@test "Pi security migration quarantines only the identified Brave skill intact" {
  local agent_dir="$TEST_ROOT/migration-agent"
  local source="$agent_dir/skills/pi-skills/brave-search"
  local destination="$agent_dir/disabled-skills/pi-skills-brave-search"
  make_legacy_brave_skill "$source"
  mkdir -p "$agent_dir/skills/sibling"
  printf 'sibling\n' >"$agent_dir/skills/sibling/keep"

  run_security_migration apply "$agent_dir" "$TEST_ROOT/amp/settings.json" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$source" ]
  [ -f "$destination/SKILL.md" ]
  [ "$(cat "$destination/payload.txt")" = "preserve me" ]
  [ "$(cat "$agent_dir/skills/sibling/keep")" = sibling ]

  run_security_migration apply "$agent_dir" "$TEST_ROOT/amp/settings.json" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$destination" ]
}

@test "Pi security migration preserves mismatched or colliding Brave directories" {
  local mismatch_agent="$TEST_ROOT/mismatch-agent"
  local mismatch_source="$mismatch_agent/skills/pi-skills/brave-search"
  make_legacy_brave_skill "$mismatch_source" other-search
  printf '\nname: brave-search\n' >>"$mismatch_source/SKILL.md"

  run_security_migration apply "$mismatch_agent" "$TEST_ROOT/amp/settings.json" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$mismatch_source" ]
  [[ "$output" == *"identity"* ]]

  local collision_agent="$TEST_ROOT/collision-agent"
  local collision_source="$collision_agent/skills/pi-skills/brave-search"
  local collision_destination="$collision_agent/disabled-skills/pi-skills-brave-search"
  make_legacy_brave_skill "$collision_source"
  mkdir -p "$collision_destination"
  printf 'existing\n' >"$collision_destination/keep"

  run_security_migration apply "$collision_agent" "$TEST_ROOT/amp/settings.json" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -d "$collision_source" ]
  [ "$(cat "$collision_destination/keep")" = existing ]
  [[ "$output" == *"already exists"* ]]
}

@test "Pi security migration check mode is mutation-free" {
  local agent_dir="$TEST_ROOT/check-migration-agent"
  local amp_settings="$TEST_ROOT/amp/settings.json"
  mkdir -p "$agent_dir" "$(dirname "$amp_settings")"
  printf '{"permissions":{"mode":"yolo"},"keep":true}\n' >"$agent_dir/amplike.json"
  ln -s "$REPO_ROOT/ai/pi/permissions.json" "$amp_settings"
  make_legacy_brave_skill "$agent_dir/skills/pi-skills/brave-search"
  local before after
  before=$(snapshot_tree "$TEST_ROOT")

  run_security_migration check "$agent_dir" "$amp_settings" "$REPO_ROOT"

  after=$(snapshot_tree "$TEST_ROOT")
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "regular Pi installer invokes security migration before package bootstrap" {
  export PI_VERSION PI_TEST_REQUIRE_REGULAR_MIGRATION=1
  stub_existing_pi
  printf '{"permissions":{"mode":"old"}}\n' >"$HOME/.pi/agent/amplike.json"
  run bash "$REPO_ROOT/ai/pi/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.pi/agent/amplike.json" ]
  [ -f "$HOME/.pi/agent/npm/node_modules/pi-amplike/package.json" ]
}

@test "Pi installer callers no longer reference retired tracked modes or permissions" {
  [ ! -e "$REPO_ROOT/ai/pi/modes.json" ]
  [ ! -e "$REPO_ROOT/ai/pi/permissions.json" ]
  run rg -n '\$ROOT/ai/pi/(permissions|modes)\.json' \
    "$REPO_ROOT/ai/pi/install.sh" "$REPO_ROOT/tests/feature_workflow_policy.bats"
  [ "$status" -eq 1 ]
}
