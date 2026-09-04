#!/usr/bin/env bash
# Validate the local Pi Web UI runtime, worktree, and user service.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

canonical_existing() {
  local path=$1 directory base
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    directory=$(dirname "$path")
    base=$(basename "$path")
    [[ -d "$directory" ]] || return 1
    printf '%s/%s\n' "$(cd "$directory" && pwd -P)" "$base"
  fi
}

require_test_override() {
  local path=$1 root home_real path_real
  [[ ${PI_WEBUI_TESTING:-} == 1 && -n ${BATS_TEST_TMPDIR:-} ]] ||
    fail 'test overrides are unavailable outside Bats'
  root=$(canonical_existing "$BATS_TEST_TMPDIR") || fail 'invalid Bats test root'
  home_real=$(canonical_existing "$HOME") || fail 'invalid test HOME'
  path_real=$(canonical_existing "$path") || fail "invalid test fixture path: $path"
  case "$home_real/" in "$root/"*) ;; *) fail 'test HOME must be below the Bats test root' ;; esac
  case "$path_real/" in "$root/"*) ;; *) fail 'test fixture must be below the Bats test root' ;; esac
}

require_supported_platform() {
  local os_release=/etc/os-release kernel id version codename
  if [[ -n ${PI_WEBUI_TEST_OS_RELEASE:-} ]]; then
    require_test_override "$PI_WEBUI_TEST_OS_RELEASE"
    os_release=$PI_WEBUI_TEST_OS_RELEASE
  fi
  [[ -f "$os_release" ]] || fail 'operating-system identity is unavailable'
  id=$(bash -c '. "$1"; printf "%s" "${ID:-}"' bash "$os_release")
  version=$(bash -c '. "$1"; printf "%s" "${VERSION_ID:-}"' bash "$os_release")
  codename=$(bash -c '. "$1"; printf "%s" "${VERSION_CODENAME:-}"' bash "$os_release")
  kernel=$(uname -r)
  if [[ -n ${PI_WEBUI_TEST_UNAME_RELEASE:-} ]]; then
    require_test_override "$os_release"
    kernel=$PI_WEBUI_TEST_UNAME_RELEASE
  fi
  [[ "$id" == ubuntu && "$version" == 24.04 && "$codename" == noble &&
    "$kernel" == *[Mm]icrosoft* ]] ||
    fail 'Pi Web UI requires Ubuntu 24.04 Noble under WSL'
  systemctl --user show-environment >/dev/null ||
    fail 'a working systemd user manager is required'
}

resolve_source() {
  local default_root git_dir
  default_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
  SOURCE_ROOT=$default_root
  if [[ -n ${PI_WEBUI_TEST_SOURCE_ROOT:-} ]]; then
    require_test_override "$PI_WEBUI_TEST_SOURCE_ROOT"
    SOURCE_ROOT=$(canonical_existing "$PI_WEBUI_TEST_SOURCE_ROOT")
  fi
  [[ -d "$SOURCE_ROOT/.git" || -f "$SOURCE_ROOT/.git" ]] ||
    fail 'source root is not a Git checkout'
  git_dir=$(git -C "$SOURCE_ROOT" rev-parse --path-format=absolute --git-dir) ||
    fail 'cannot resolve source Git directory'
  SOURCE_GIT_DIR=$(canonical_existing "$git_dir")
  SOURCE_GIT_COMMON_DIR=$(canonical_existing "$(git -C "$SOURCE_ROOT" rev-parse --path-format=absolute --git-common-dir)")
  PRIMARY_CHECKOUT=$(git -C "$SOURCE_ROOT" worktree list --porcelain | awk 'NR == 1 { print substr($0, 10); exit }')
  PRIMARY_CHECKOUT=$(canonical_existing "$PRIMARY_CHECKOUT")
  if [[ -n ${PI_WEBUI_TEST_SOURCE_ROOT:-} ]]; then
    CANONICAL_CHECKOUT=$PRIMARY_CHECKOUT
  else
    CANONICAL_CHECKOUT=$(canonical_existing "$HOME/.dotfiles") ||
      fail 'cannot resolve the canonical primary checkout'
  fi
  export SOURCE_ROOT SOURCE_GIT_DIR SOURCE_GIT_COMMON_DIR PRIMARY_CHECKOUT CANONICAL_CHECKOUT
}

validate_apply_source() {
  local head upstream
  [[ "$SOURCE_GIT_DIR" == "$SOURCE_GIT_COMMON_DIR" && "$SOURCE_ROOT" == "$PRIMARY_CHECKOUT" &&
    "$PRIMARY_CHECKOUT" == "$CANONICAL_CHECKOUT" ]] ||
    fail 'apply requires the canonical primary checkout'
  [[ -z $(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all) ]] ||
    fail 'apply requires a clean source checkout'
  head=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
  upstream=$(git -C "$SOURCE_ROOT" rev-parse refs/remotes/origin/main 2>/dev/null) ||
    fail 'origin/main is unavailable'
  [[ "$head" == "$upstream" ]] || fail 'apply requires HEAD to equal origin/main'
}

resolve_mise() {
  MISE_LAUNCHER=$(command -v mise 2>/dev/null) || fail 'mise launcher is unavailable'
  [[ "$MISE_LAUNCHER" == /* && -x "$MISE_LAUNCHER" ]] || fail 'mise launcher is invalid'
  MISE_LAUNCHER=$(canonical_existing "$MISE_LAUNCHER") || fail 'cannot resolve mise launcher'
  export MISE_LAUNCHER
}

resolve_pi() {
  PI_LAUNCHER=$("$MISE_LAUNCHER" which pi 2>/dev/null) || fail 'Pi must be available through mise'
  [[ -x "$PI_LAUNCHER" && "$PI_LAUNCHER" == /* ]] || fail 'mise returned an invalid Pi launcher'
  PI_LAUNCHER=$(canonical_existing "$PI_LAUNCHER")
  node - "$PI_LAUNCHER" <<'NODE' || fail 'Pi launcher is not @earendil-works/pi-coding-agent@0.84.4'
const fs = require('node:fs');
const path = require('node:path');
const launcher = fs.realpathSync(process.argv[2]);
let directory = path.dirname(launcher);
for (;;) {
  const manifest = path.join(directory, 'package.json');
  if (fs.existsSync(manifest)) {
    const value = JSON.parse(fs.readFileSync(manifest, 'utf8'));
    if (value.name === '@earendil-works/pi-coding-agent' && value.version === '0.84.4' &&
        typeof value.bin?.pi === 'string' && fs.realpathSync(path.resolve(directory, value.bin.pi)) === launcher) {
      process.exit(0);
    }
  }
  const parent = path.dirname(directory);
  if (parent === directory) break;
  directory = parent;
}
process.exit(1);
NODE
  export PI_LAUNCHER
}

validate_landing_worktree() {
  local worktree=${1:-$LANDING_WORKTREE} common ignored entry owner existing
  if [[ ! -e "$worktree" && ! -L "$worktree" ]]; then
    existing=$(dirname "$worktree")
    while [[ ! -e "$existing" ]]; do existing=$(dirname "$existing"); done
    [[ -d "$existing" && ! -L "$existing" ]] || fail 'landing worktree parent must be a real directory'
    owner=$(stat -c %u "$existing")
    [[ "$owner" == "$(id -u)" ]] || fail 'landing worktree parent must be owned by the current user'
    printf 'landing worktree would be created: %s\n' "$worktree"
    return 0
  fi
  [[ -d "$worktree" && ! -L "$worktree" ]] || fail 'landing worktree must be a real directory'
  owner=$(stat -c %u "$worktree")
  [[ "$owner" == "$(id -u)" ]] || fail 'landing worktree must be owned by the current user'
  common=$(canonical_existing "$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)") ||
    fail 'landing worktree is not a Git worktree'
  [[ "$common" == "$SOURCE_GIT_COMMON_DIR" ]] || fail 'landing worktree belongs to a foreign repository'
  if git -C "$worktree" symbolic-ref -q HEAD >/dev/null; then
    fail 'landing worktree must be detached'
  fi
  [[ -z $(git -C "$worktree" status --porcelain --untracked-files=all) ]] ||
    fail 'landing worktree must be clean'
  ignored=$(git -C "$worktree" status --porcelain --ignored --untracked-files=all)
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == '!! .pi/' ]] || fail 'landing worktree contains ignored state'
  done <<<"$ignored"
  if [[ -e "$worktree/.pi" ]]; then
    [[ -d "$worktree/.pi" && ! -L "$worktree/.pi" ]] || fail '.pi must be a real directory'
    [[ -d "$worktree/.pi/plans" && ! -L "$worktree/.pi/plans" ]] || fail '.pi may contain only plans/'
    [[ -z $(find "$worktree/.pi" -mindepth 1 -maxdepth 1 ! -name plans -print -quit) ]] ||
      fail '.pi may contain only plans/'
    [[ -z $(find "$worktree/.pi/plans" -mindepth 1 -print -quit) ]] || fail '.pi/plans must be empty'
  fi
}

safe_unit_path() {
  local path=$1 without_controls
  [[ "$path" == /* && "$path" != *'%'* && "$path" != *'$'* ]] || {
    fail 'unsafe path for systemd unit'
    return 1
  }
  without_controls=$(printf '%s' "$path" | LC_ALL=C tr -d '[:cntrl:]') || return 1
  [[ "$without_controls" == "$path" ]] || {
    fail 'unsafe path for systemd unit'
    return 1
  }
}

render_unit() {
  local runtime_launcher=${1:-$RUNTIME_LAUNCHER}
  local worktree=${2:-$LANDING_WORKTREE}
  local pi_launcher=${3:-$PI_LAUNCHER}
  local mise_launcher=${4:-$MISE_LAUNCHER}
  local rendered template
  safe_unit_path "$runtime_launcher" || return 1
  safe_unit_path "$worktree" || return 1
  safe_unit_path "$pi_launcher" || return 1
  safe_unit_path "$mise_launcher" || return 1
  template="$SOURCE_ROOT/ai/pi/webui/pi-webui.service.in"
  [[ -f "$template" && ! -L "$template" ]] || fail 'service template is unavailable'
  rendered=$(<"$template")
  rendered=${rendered//@RUNTIME_LAUNCHER@/$runtime_launcher}
  rendered=${rendered//@WORKTREE@/$worktree}
  rendered=${rendered//@PI_LAUNCHER@/$pi_launcher}
  rendered=${rendered//@MISE_LAUNCHER@/$mise_launcher}
  [[ "$rendered" != *'@RUNTIME_LAUNCHER@'* && "$rendered" != *'@WORKTREE@'* &&
    "$rendered" != *'@PI_LAUNCHER@'* && "$rendered" != *'@MISE_LAUNCHER@'* ]] ||
    fail 'service template substitution failed'
  printf '%s\n' "$rendered"
}

validate_unit() {
  local unit=${1:-$UNIT_PATH}
  [[ -f "$unit" && ! -L "$unit" ]] || fail 'installed service unit is unavailable'
  cmp -s "$unit" <(render_unit "$RUNTIME_LAUNCHER" "$LANDING_WORKTREE" "$PI_LAUNCHER") ||
    fail 'installed service unit differs from the managed configuration'
}

validate_active_health() {
  local pi_launcher=${1:-$PI_LAUNCHER} listeners health
  systemctl --user is-active pi-webui.service >/dev/null || fail 'Pi Web UI service is not active'
  listeners=$(ss -ltnH 'sport = :31415') || fail 'cannot inspect Pi Web UI listener'
  [[ $(printf '%s\n' "$listeners" | awk 'NF { count++ } END { print count+0 }') -eq 1 ]] ||
    fail 'expected exactly one Pi Web UI listener'
  [[ $(printf '%s\n' "$listeners" | awk 'NF { print $4 }') == 127.0.0.1:31415 ]] ||
    fail 'Pi Web UI listener is not loopback-only'
  health=$(curl --fail --silent --show-error http://127.0.0.1:31415/api/health) ||
    fail 'Pi Web UI health endpoint failed'
  node - "$pi_launcher" "$health" <<'NODE' || fail 'Pi Web UI health identity is invalid'
const launcher = process.argv[2];
const response = JSON.parse(process.argv[3]);
{
  const data = response.data;
  const network = data?.network;
  if (response.ok !== true || data?.webuiVersion !== '0.10.3' || data?.piVersion !== '0.84.4' ||
      network?.open !== false || network?.host !== '127.0.0.1' || network?.port !== 31415 ||
      !Array.isArray(network?.networkUrls) || network.networkUrls.length !== 0 ||
      !Array.isArray(data?.tabs)) process.exit(1);
  const prefix = `${launcher} --mode rpc`;
  for (const tab of data.tabs) {
    if (tab.running === true && !(tab.command === prefix ||
        (typeof tab.command === 'string' && tab.command.startsWith(prefix) && /\s/.test(tab.command[prefix.length])))) {
      process.exit(1);
    }
  }
}
NODE
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

require_managed_directory() {
  local directory=$1 label=$2
  [[ -d "$directory" && ! -L "$directory" ]] || {
    fail "$label must be a real directory"
    return 1
  }
  [[ $(stat -c %u "$directory") == "$(id -u)" ]] || {
    fail "$label must be owned by the current user"
    return 1
  }
}

prepare_managed_directory() {
  local directory=$1 label=$2
  if ! path_exists "$directory"; then
    mkdir -p "$directory" || return 1
  fi
  require_managed_directory "$directory" "$label" || return 1
}

cleanup_apply_paths() {
  local failed=0
  if [[ -n ${UNIT_TEMPORARY:-} ]] && path_exists "$UNIT_TEMPORARY"; then
    rm -f -- "$UNIT_TEMPORARY" || failed=1
  fi
  if [[ -n ${CANDIDATE_RUNTIME:-} ]] && path_exists "$CANDIDATE_RUNTIME"; then
    rm -rf -- "$CANDIDATE_RUNTIME" || failed=1
  fi
  if [[ -n ${STAGING_DIR:-} ]] && path_exists "$STAGING_DIR"; then
    rm -rf -- "$STAGING_DIR" || failed=1
  fi
  [[ "$failed" -eq 0 ]]
}

reject_retained_apply_state() {
  local path
  for path in \
    "$STATE_ROOT/runtimes/candidate" \
    "$STATE_ROOT/transactions/pending" \
    "$STATE_ROOT/transactions/apply.lock"; do
    if path_exists "$path"; then
      fail "preserving existing apply evidence; resolve it manually: $path"
      return 1
    fi
  done
}

build_candidate() {
  local runtime_parent=$STATE_ROOT/runtime source_runtime unit_directory
  reject_retained_apply_state || return 1
  unit_directory=$(dirname "$UNIT_PATH")
  prepare_managed_directory "$STATE_ROOT" 'Pi Web UI state root' || return 1
  prepare_managed_directory "$runtime_parent" 'Pi Web UI runtime parent' || return 1
  prepare_managed_directory "$unit_directory" 'systemd user unit directory' || return 1

  CANDIDATE_RUNTIME=$(mktemp -d "$runtime_parent/.candidate.XXXXXX") || return 1
  chmod 0700 "$CANDIDATE_RUNTIME" || return 1
  STAGING_DIR=$(mktemp -d "$STATE_ROOT/.apply.XXXXXX") || return 1
  chmod 0700 "$STAGING_DIR" || return 1
  CANDIDATE_UNIT=$STAGING_DIR/pi-webui.service
  PRIOR_RUNTIME_BACKUP=$STAGING_DIR/prior-runtime
  PRIOR_UNIT_BACKUP=$STAGING_DIR/prior-unit
  source_runtime=$SOURCE_ROOT/ai/pi/webui/runtime

  cp "$source_runtime/package.json" "$source_runtime/package-lock.json" "$CANDIDATE_RUNTIME/" || return 1
  "$MISE_LAUNCHER" exec -- npm ci --prefix "$CANDIDATE_RUNTIME" --ignore-scripts --omit=optional ||
    return 1
  "$SOURCE_ROOT/bin/validate-pi-webui" --tracked-only "$CANDIDATE_RUNTIME" || return 1
  "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$CANDIDATE_RUNTIME" || return 1
  render_unit "$RUNTIME_LAUNCHER" "$LANDING_WORKTREE" "$PI_LAUNCHER" >"$CANDIDATE_UNIT" ||
    return 1
  chmod 0600 "$CANDIDATE_UNIT" || return 1
  systemd-analyze --user verify "$CANDIDATE_UNIT" ||
    fail 'candidate service unit failed systemd verification'
}

capture_prior_state() {
  PRIOR_RUNTIME_PRESENT=0
  PRIOR_UNIT_PRESENT=0
  PRIOR_COMMIT=ABSENT
  PRIOR_ENABLED=0
  PRIOR_ACTIVE=0
  if path_exists "$INSTALLED_RUNTIME"; then PRIOR_RUNTIME_PRESENT=1; fi
  if path_exists "$UNIT_PATH"; then
    PRIOR_UNIT_PRESENT=1
    cp "$UNIT_PATH" "$PRIOR_UNIT_BACKUP" || return 1
  fi
  if path_exists "$LANDING_WORKTREE"; then
    PRIOR_COMMIT=$(git -C "$LANDING_WORKTREE" rev-parse HEAD) || return 1
  fi
  if systemctl --user is-enabled pi-webui.service >/dev/null 2>&1; then PRIOR_ENABLED=1; fi
  if systemctl --user is-active pi-webui.service >/dev/null 2>&1; then PRIOR_ACTIVE=1; fi
}

publish_unit() {
  local unit_directory temporary
  unit_directory=$(dirname "$UNIT_PATH")
  mkdir -p "$unit_directory" || return 1
  require_managed_directory "$unit_directory" 'systemd user unit directory' || return 1
  temporary=$(mktemp "$UNIT_PATH.candidate.XXXXXX") || return 1
  UNIT_TEMPORARY=$temporary
  cp "$CANDIDATE_UNIT" "$temporary" || return 1
  chmod 0600 "$temporary" || return 1
  mv "$temporary" "$UNIT_PATH" || return 1
  UNIT_TEMPORARY=
  unit_changed=1
}

publish_candidate() {
  if [[ "$PRIOR_ACTIVE" -eq 1 ]]; then
    systemctl --user stop pi-webui.service || return 1
    stopped=1
  fi

  if [[ "$PRIOR_RUNTIME_PRESENT" -eq 1 ]]; then
    mv "$INSTALLED_RUNTIME" "$PRIOR_RUNTIME_BACKUP" || return 1
    runtime_changed=1
  fi
  if [[ "$PRIOR_COMMIT" == ABSENT ]]; then
    mkdir -p "$(dirname "$LANDING_WORKTREE")" || return 1
    git -C "$SOURCE_ROOT" worktree add --detach "$LANDING_WORKTREE" refs/remotes/origin/main || return 1
  else
    git -C "$LANDING_WORKTREE" checkout --detach refs/remotes/origin/main || return 1
  fi
  worktree_changed=1
  mv "$CANDIDATE_RUNTIME" "$INSTALLED_RUNTIME" || return 1
  runtime_changed=1
  publish_unit || return 1
  systemctl --user daemon-reload || return 1
  daemon_reloaded=1

  if [[ "$PRIOR_UNIT_PRESENT" -eq 0 || "$PRIOR_ENABLED" -eq 1 ]]; then
    systemctl --user enable pi-webui.service || return 1
  else
    systemctl --user disable pi-webui.service || return 1
  fi
  enablement_changed=1
  systemctl --user start pi-webui.service || return 1
  candidate_started=1
  validate_active_health "$PI_LAUNCHER" || return 1
  if [[ "$PRIOR_UNIT_PRESENT" -eq 1 && "$PRIOR_ACTIVE" -eq 0 ]]; then
    systemctl --user stop pi-webui.service || return 1
    candidate_started=0
  fi
}

restore_prior_state() {
  local failed=0 reload_needed=0 temporary
  set +e
  if [[ "$candidate_started" -eq 1 ]]; then
    systemctl --user stop pi-webui.service || failed=1
    candidate_started=0
  fi
  if [[ "$enablement_changed" -eq 1 && "$PRIOR_UNIT_PRESENT" -eq 0 ]]; then
    if systemctl --user disable pi-webui.service; then
      enablement_changed=0
    else
      failed=1
    fi
  fi
  if [[ "$unit_changed" -eq 1 ]]; then
    reload_needed=1
    if [[ "$PRIOR_UNIT_PRESENT" -eq 1 ]]; then
      temporary=$(mktemp "$UNIT_PATH.restore.XXXXXX")
      if [[ -z "$temporary" ]] || ! cp "$PRIOR_UNIT_BACKUP" "$temporary" ||
        ! chmod 0600 "$temporary" || ! mv "$temporary" "$UNIT_PATH"; then
        failed=1
      fi
    else
      rm -f -- "$UNIT_PATH" || failed=1
    fi
    unit_changed=0
  fi
  if [[ "$runtime_changed" -eq 1 ]]; then
    if path_exists "$INSTALLED_RUNTIME"; then
      mv "$INSTALLED_RUNTIME" "$CANDIDATE_RUNTIME" || failed=1
    fi
    if [[ "$PRIOR_RUNTIME_PRESENT" -eq 1 ]]; then
      mv "$PRIOR_RUNTIME_BACKUP" "$INSTALLED_RUNTIME" || failed=1
    fi
    runtime_changed=0
  fi
  if [[ "$worktree_changed" -eq 1 ]]; then
    if [[ "$PRIOR_COMMIT" == ABSENT ]]; then
      git -C "$SOURCE_ROOT" worktree remove "$LANDING_WORKTREE" || failed=1
    else
      git -C "$LANDING_WORKTREE" checkout --detach "$PRIOR_COMMIT" || failed=1
    fi
    worktree_changed=0
  fi
  if [[ "$daemon_reloaded" -eq 1 || "$reload_needed" -eq 1 ]]; then
    systemctl --user daemon-reload || failed=1
    daemon_reloaded=0
  fi
  if [[ "$enablement_changed" -eq 1 ]]; then
    if [[ "$PRIOR_ENABLED" -eq 1 ]]; then
      systemctl --user enable pi-webui.service || failed=1
    else
      systemctl --user disable pi-webui.service || failed=1
    fi
    enablement_changed=0
  fi
  if [[ "$stopped" -eq 1 ]]; then
    if [[ "$PRIOR_ACTIVE" -eq 1 ]]; then
      systemctl --user start pi-webui.service || failed=1
    else
      systemctl --user stop pi-webui.service || failed=1
    fi
  fi
  if [[ "$failed" -eq 0 ]]; then
    cleanup_apply_paths || failed=1
  fi
  set -e
  if [[ "$failed" -ne 0 ]]; then
    fail "restoration failed; preserving staging path: $STAGING_DIR"
    return 1
  fi
}

apply_reconciliation() {
  local status
  stopped=0
  worktree_changed=0
  runtime_changed=0
  unit_changed=0
  daemon_reloaded=0
  enablement_changed=0
  candidate_started=0
  UNIT_TEMPORARY=

  if ! build_candidate; then
    cleanup_apply_paths || true
    return 1
  fi
  if ! capture_prior_state; then
    cleanup_apply_paths || true
    return 1
  fi
  if publish_candidate; then
    cleanup_apply_paths
    return
  else
    status=$?
  fi
  if [[ "$stopped" -eq 1 || "$worktree_changed" -eq 1 || "$runtime_changed" -eq 1 ||
    "$unit_changed" -eq 1 || "$daemon_reloaded" -eq 1 || "$enablement_changed" -eq 1 ||
    "$candidate_started" -eq 1 ]]; then
    restore_prior_state || return 1
  else
    cleanup_apply_paths || true
  fi
  return "$status"
}

main() {
  local mode=${1:-}
  [[ $# -eq 1 && ("$mode" == --check || "$mode" == --apply) ]] || {
    printf 'usage: %s --check|--apply\n' "$0" >&2
    return 2
  }
  require_supported_platform
  resolve_source
  [[ "$mode" != --apply ]] || validate_apply_source
  resolve_mise
  resolve_pi

  "$SOURCE_ROOT/bin/validate-pi-webui" --tracked-only

  STATE_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}/pi-webui
  INSTALLED_RUNTIME=$STATE_ROOT/runtime/current
  LANDING_WORKTREE=$STATE_ROOT/worktrees/dotfiles
  RUNTIME_LAUNCHER=$INSTALLED_RUNTIME/node_modules/.bin/pi-webui
  UNIT_PATH=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pi-webui.service
  export STATE_ROOT INSTALLED_RUNTIME LANDING_WORKTREE RUNTIME_LAUNCHER UNIT_PATH

  validate_landing_worktree "$LANDING_WORKTREE"
  if [[ -e "$INSTALLED_RUNTIME" || -L "$INSTALLED_RUNTIME" ]]; then
    "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$INSTALLED_RUNTIME"
  else
    printf 'installed runtime is absent\n'
  fi
  if [[ -e "$UNIT_PATH" || -L "$UNIT_PATH" ]]; then
    validate_unit "$UNIT_PATH"
  else
    printf 'installed service unit is absent\n'
  fi
  if systemctl --user is-active pi-webui.service >/dev/null 2>&1; then
    validate_active_health "$PI_LAUNCHER"
  fi
  if [[ "$mode" == --check ]]; then
    "$SOURCE_ROOT/ai/pi/webui/tailscale.sh" check
  else
    apply_reconciliation
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
