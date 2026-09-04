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
  export SOURCE_ROOT SOURCE_GIT_DIR SOURCE_GIT_COMMON_DIR PRIMARY_CHECKOUT
}

validate_apply_source() {
  local head upstream
  [[ "$SOURCE_GIT_DIR" == "$SOURCE_GIT_COMMON_DIR" && "$SOURCE_ROOT" == "$PRIMARY_CHECKOUT" ]] ||
    fail 'apply requires the canonical primary checkout'
  [[ -z $(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all) ]] ||
    fail 'apply requires a clean source checkout'
  head=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
  upstream=$(git -C "$SOURCE_ROOT" rev-parse refs/remotes/origin/main 2>/dev/null) ||
    fail 'origin/main is unavailable'
  [[ "$head" == "$upstream" ]] || fail 'apply requires HEAD to equal origin/main'
}

resolve_pi() {
  PI_LAUNCHER=$(mise which pi 2>/dev/null) || fail 'Pi must be available through mise'
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
  local path=$1
  [[ "$path" == /* && "$path" != *'%'* && "$path" != *'$'* ]] ||
    fail 'unsafe path for systemd unit'
  if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail 'unsafe path for systemd unit'
  fi
}

render_unit() {
  local runtime_launcher=${1:-$RUNTIME_LAUNCHER}
  local worktree=${2:-$LANDING_WORKTREE}
  local pi_launcher=${3:-$PI_LAUNCHER}
  local rendered template
  safe_unit_path "$runtime_launcher"
  safe_unit_path "$worktree"
  safe_unit_path "$pi_launcher"
  template="$SOURCE_ROOT/ai/pi/webui/pi-webui.service.in"
  [[ -f "$template" && ! -L "$template" ]] || fail 'service template is unavailable'
  rendered=$(<"$template")
  rendered=${rendered//@RUNTIME_LAUNCHER@/$runtime_launcher}
  rendered=${rendered//@WORKTREE@/$worktree}
  rendered=${rendered//@PI_LAUNCHER@/$pi_launcher}
  [[ "$rendered" != *'@RUNTIME_LAUNCHER@'* && "$rendered" != *'@WORKTREE@'* &&
    "$rendered" != *'@PI_LAUNCHER@'* ]] || fail 'service template substitution failed'
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
      !Array.isArray(data?.tabs) || data.tabs.length === 0) process.exit(1);
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

main() {
  local mode=${1:-}
  [[ $# -eq 1 && ("$mode" == --check || "$mode" == --apply) ]] || {
    printf 'usage: %s --check|--apply\n' "$0" >&2
    return 2
  }
  require_supported_platform
  resolve_source
  [[ "$mode" != --apply ]] || validate_apply_source
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
  printf 'Tailscale stage is unavailable until Task 4\n'
  if [[ "$mode" == --apply ]]; then
    fail 'apply reconciliation is not yet available'
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
