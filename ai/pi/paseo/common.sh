#!/usr/bin/env bash
# Shared read-only guards for Paseo and the retained private domain proxy.
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}
path_exists() { [[ -e "$1" || -L "$1" ]]; }
canonical_existing() {
  local path=$1 directory base
  if [[ -d "$path" ]]; then (cd "$path" && pwd -P); else
    directory=$(dirname "$path")
    base=$(basename "$path")
    [[ -d "$directory" ]] || return 1
    printf '%s/%s\n' "$(cd "$directory" && pwd -P)" "$base"
  fi
}

paseo_selected() {
  case "${DOTFILES_PASEO_ENABLED:-}" in
    1) return 0 ;;
    '' | 0) return 1 ;;
    *)
      fail 'invalid DOTFILES_PASEO_ENABLED; use 1 to opt in or 0/unset to skip'
      return 2
      ;;
  esac
}

set_managed_paths() {
  STATE_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}/paseo
  INSTALLED_RUNTIME=$STATE_ROOT/runtimes/current
  PASEO_HOME=$STATE_ROOT/home
  RUNTIME_LAUNCHER=$INSTALLED_RUNTIME/node_modules/@getpaseo/cli/bin/paseo
  MANAGED_LAUNCHER=$STATE_ROOT/paseo
  UNIT_PATH=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/paseo.service
  TRIAL_ROOT=$HOME/.local/share/paseo-trial
  export STATE_ROOT INSTALLED_RUNTIME PASEO_HOME RUNTIME_LAUNCHER MANAGED_LAUNCHER UNIT_PATH TRIAL_ROOT
}

require_test_override() {
  local path=$1 root home_real path_real
  [[ ${PI_PASEO_TESTING:-} == 1 && -n ${BATS_TEST_TMPDIR:-} ]] || {
    fail 'test overrides are unavailable outside Bats'
    return 1
  }
  root=$(canonical_existing "$BATS_TEST_TMPDIR") || return 1
  home_real=$(canonical_existing "$HOME") || return 1
  path_real=$(canonical_existing "$path") || return 1
  case "$home_real/" in "$root/"*) ;; *)
    fail 'test HOME must be below the Bats test root'
    return 1
    ;;
  esac
  case "$path_real/" in "$root/"*) ;; *)
    fail 'test fixture must be below the Bats test root'
    return 1
    ;;
  esac
}

require_supported_platform() {
  local release=/etc/os-release kernel identity
  if [[ -n ${PI_PASEO_TEST_OS_RELEASE:-} ]]; then
    require_test_override "$PI_PASEO_TEST_OS_RELEASE" || return 1
    release=$PI_PASEO_TEST_OS_RELEASE
  fi
  [[ -f "$release" ]] || {
    fail 'operating-system identity is unavailable'
    return 1
  }
  identity=$(bash -c '. "$1"; printf "%s:%s:%s" "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}"' bash "$release") || return 1
  kernel=$(uname -r) || return 1
  if [[ -n ${PI_PASEO_TEST_UNAME_RELEASE:-} ]]; then
    require_test_override "$release" || return 1
    kernel=$PI_PASEO_TEST_UNAME_RELEASE
  fi
  [[ "$identity" == ubuntu:24.04:noble && "$kernel" == *[Mm]icrosoft* ]] || {
    fail 'Paseo requires Ubuntu 24.04 Noble under WSL'
    return 1
  }
  systemctl --user show-environment >/dev/null || fail 'a working systemd user manager is required'
}

resolve_source() {
  local git_dir
  SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P) || return 1
  if [[ -n ${PI_PASEO_TEST_SOURCE_ROOT:-} ]]; then
    require_test_override "$PI_PASEO_TEST_SOURCE_ROOT" || return 1
    SOURCE_ROOT=$(canonical_existing "$PI_PASEO_TEST_SOURCE_ROOT") || return 1
  fi
  git_dir=$(git -C "$SOURCE_ROOT" rev-parse --path-format=absolute --git-dir) || {
    fail 'source root is not a Git checkout'
    return 1
  }
  SOURCE_GIT_DIR=$(canonical_existing "$git_dir") || return 1
  git_dir=$(git -C "$SOURCE_ROOT" rev-parse --path-format=absolute --git-common-dir) || return 1
  SOURCE_GIT_COMMON_DIR=$(canonical_existing "$git_dir") || return 1
  PRIMARY_CHECKOUT=$(git -C "$SOURCE_ROOT" worktree list --porcelain | awk 'NR==1 {print substr($0,10); exit}') || return 1
  PRIMARY_CHECKOUT=$(canonical_existing "$PRIMARY_CHECKOUT") || return 1
  if [[ -n ${PI_PASEO_TEST_SOURCE_ROOT:-} ]]; then CANONICAL_CHECKOUT=$PRIMARY_CHECKOUT; else
    CANONICAL_CHECKOUT=$(canonical_existing "$HOME/.dotfiles") || return 1
  fi
  export SOURCE_ROOT SOURCE_GIT_DIR SOURCE_GIT_COMMON_DIR PRIMARY_CHECKOUT CANONICAL_CHECKOUT
}

validate_apply_source() {
  local head upstream dirty
  [[ "$SOURCE_GIT_DIR" == "$SOURCE_GIT_COMMON_DIR" && "$SOURCE_ROOT" == "$PRIMARY_CHECKOUT" && "$PRIMARY_CHECKOUT" == "$CANONICAL_CHECKOUT" ]] || {
    fail 'apply requires the canonical primary checkout'
    return 1
  }
  dirty=$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all) || return 1
  [[ -z "$dirty" ]] || {
    fail 'apply requires a clean source checkout'
    return 1
  }
  head=$(git -C "$SOURCE_ROOT" rev-parse HEAD) || return 1
  upstream=$(git -C "$SOURCE_ROOT" rev-parse refs/remotes/origin/main) || return 1
  [[ "$head" == "$upstream" ]] || fail 'apply requires HEAD to equal origin/main'
}

resolve_mise() {
  MISE_LAUNCHER=$(command -v mise) || {
    fail 'mise launcher is unavailable'
    return 1
  }
  [[ "$MISE_LAUNCHER" == /* && -x "$MISE_LAUNCHER" ]] || {
    fail 'mise launcher is invalid'
    return 1
  }
  MISE_LAUNCHER=$(canonical_existing "$MISE_LAUNCHER") || return 1
  export MISE_LAUNCHER
}

resolve_pi() {
  PI_LAUNCHER=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/bin/pi
  if [[ ! -x "$PI_LAUNCHER" ]]; then
    PI_LAUNCHER=$("$MISE_LAUNCHER" which pi) || {
      fail 'native Pi launcher is unavailable'
      return 1
    }
  fi
  [[ "$PI_LAUNCHER" == /* && -x "$PI_LAUNCHER" ]] || {
    fail 'native Pi launcher is invalid'
    return 1
  }
  PI_LAUNCHER=$(canonical_existing "$PI_LAUNCHER") || return 1
  source "$SOURCE_ROOT/libexec/lib/pi-runtime.sh"
  resolve_pi_runtime "$PI_LAUNCHER" || return 1
  node - "$PI_RUNTIME_PACKAGE_ROOT" <<'NODE' || {
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const p = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const v = /^(\d+)\.(\d+)\.(\d+)(?:\+[\w.-]+)?$/.exec(p.version || '');
if (p.name !== '@earendil-works/pi-coding-agent' || !v || !(Number(v[1]) > 1 || (Number(v[1]) === 1 && Number(v[2]) >= 1)) || !['dist/cli.js', 'dist/bundle/cli.js'].includes(p.bin?.pi) || !fs.statSync(path.join(root, p.bin.pi)).isFile()) process.exit(1);
NODE
    fail 'Paseo requires the native @earendil-works/pi-coding-agent at Pi 1.1+'
    return 1
  }
  export PI_LAUNCHER
}

safe_unit_path() {
  local path=$1 clean
  [[ "$path" == /* && "$path" != *'%'* && "$path" != *'$'* && "$path" != *' '* && "$path" != *"'"* && "$path" != *'"'* && "$path" != *'\'* ]] || {
    fail 'unsafe path for systemd unit'
    return 1
  }
  clean=$(printf '%s' "$path" | LC_ALL=C tr -d '[:cntrl:]') || return 1
  [[ "$clean" == "$path" ]] || fail 'unsafe path for systemd unit'
}

require_managed_directory() {
  [[ -d "$1" && ! -L "$1" && $(stat -c %u "$1") == "$(id -u)" ]] || {
    fail "$2 must be a real directory owned by the current user"
    return 1
  }
}
prepare_managed_directory() {
  if ! path_exists "$1"; then mkdir -p "$1" || return 1; fi
  require_managed_directory "$1" "$2"
}

daemon_env_keys() {
  local key file=$SOURCE_ROOT/ai/pi/paseo/daemon-environment.list
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS= read -r key; do
    [[ -n "$key" && "$key" != \#* ]] || continue
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
      fail 'invalid daemon environment key'
      return 1
    }
    printf '%s ' "$key"
  done <"$file"
}

render_launcher() {
  local keys
  safe_unit_path "$MISE_LAUNCHER" || return 1
  safe_unit_path "$RUNTIME_LAUNCHER" || return 1
  safe_unit_path "$PASEO_HOME" || return 1
  keys=$(daemon_env_keys) || return 1
  # Scrub after mise resolves its environment, not before it can reintroduce
  # deployment overrides from an otherwise valid user-level mise config.
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf "exec \"%s\" exec -- bash -c '\nset -euo pipefail\nunset %s\n" "$MISE_LAUNCHER" "$keys"
  printf 'exec node "%s" --home "%s" "$@"\n' "$RUNTIME_LAUNCHER" "$PASEO_HOME"
  printf "' paseo-managed \"\$@\"\n"
}

render_unit() {
  local rendered keys template=$SOURCE_ROOT/ai/pi/paseo/paseo.service.in
  safe_unit_path "$MANAGED_LAUNCHER" || return 1
  [[ -f "$template" && ! -L "$template" ]] || return 1
  keys=$(daemon_env_keys) || return 1
  rendered=$(<"$template")
  rendered=${rendered//@MANAGED_LAUNCHER@/$MANAGED_LAUNCHER}
  rendered=${rendered//@DAEMON_ENV_KEYS@/$keys}
  printf '%s\n' "$rendered"
}

validate_unit() {
  local unit=${1:-$UNIT_PATH}
  [[ -f "$unit" && ! -L "$unit" && $(stat -c %u "$unit") == "$(id -u)" ]] || {
    fail 'installed service unit is unavailable or foreign'
    return 1
  }
  cmp -s "$unit" <(render_unit) || fail 'installed service unit differs from the managed configuration'
}

# Migration evidence only: this is the exact independently created 0.11.2 trial,
# not a machine-selection rule or an active Node/Pi version pin.
render_trial_unit() {
  local rendered
  rendered=$(<"$SOURCE_ROOT/ai/pi/paseo/trial.service.in")
  rendered=${rendered//@MISE_LAUNCHER@/$MISE_LAUNCHER}
  printf '%s\n' "$rendered"
}
render_trial_launcher() {
  printf '%s\n' '#!/bin/sh' "# Keep this trial independent of global PATH and Paseo's default home."
  printf 'exec %s/.local/share/mise/installs/node/26.5.0/bin/node \\\n' "$HOME"
  printf '  %s/runtime/node_modules/@getpaseo/cli/bin/paseo \\\n' "$TRIAL_ROOT"
  printf '  --home %s/home "$@"\n' "$TRIAL_ROOT"
}
validate_trial_bundle() {
  require_managed_directory "$TRIAL_ROOT" 'trial root' || return 1
  require_managed_directory "$TRIAL_ROOT/home" 'trial home' || return 1
  require_managed_directory "$TRIAL_ROOT/runtime" 'trial runtime' || return 1
  [[ -f "$TRIAL_ROOT/paseo" && ! -L "$TRIAL_ROOT/paseo" && -x "$TRIAL_ROOT/paseo" ]] || {
    fail 'trial launcher is foreign'
    return 1
  }
  cmp -s "$TRIAL_ROOT/paseo" <(render_trial_launcher) || {
    fail 'trial launcher is foreign'
    return 1
  }
  node - "$TRIAL_ROOT/runtime" "$SOURCE_ROOT/ai/pi/paseo/runtime/package-lock.json" <<'NODE' || {
const fs=require('node:fs'),path=require('node:path');
const [root,source]=process.argv.slice(2);
try {
  const read=f=>{if(!fs.lstatSync(f).isFile())throw Error();return JSON.parse(fs.readFileSync(f,'utf8'))};
  const manifest=read(path.join(root,'package.json')),lock=read(path.join(root,'package-lock.json'));
  if(manifest.name!=='paseo-local-trial'||manifest.dependencies?.['@getpaseo/cli']!=='0.11.2'||Object.keys(manifest.dependencies).length!==1)process.exit(1);
  lock.name='pi-paseo-runtime';lock.version='0.0.0';lock.packages[''].name=lock.name;lock.packages[''].version=lock.version;
  if(JSON.stringify(lock,null,2)+'\n'!==fs.readFileSync(source,'utf8'))process.exit(1);
  const cli=read(path.join(root,'node_modules/@getpaseo/cli/package.json'));
  if(cli.name!=='@getpaseo/cli'||cli.version!=='0.11.2'||cli.bin?.paseo!=='bin/paseo')process.exit(1);
} catch {process.exit(1)}
NODE
    fail 'trial runtime identity is foreign'
    return 1
  }
}
classify_existing_unit() {
  UNIT_KIND=absent
  export UNIT_KIND
  if ! path_exists "$UNIT_PATH"; then return 0; fi
  [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" && $(stat -c %u "$UNIT_PATH") == "$(id -u)" ]] || {
    fail 'foreign Paseo unit'
    return 1
  }
  if cmp -s "$UNIT_PATH" <(render_unit); then
    UNIT_KIND=managed
    return 0
  fi
  if cmp -s "$UNIT_PATH" <(render_trial_unit); then
    validate_trial_bundle || return 1
    UNIT_KIND=trial
    return 0
  fi
  fail 'foreign or unidentified Paseo unit; refusing replacement'
}

read_service_state() {
  local unit=$1 data
  data=$(systemctl --user show "$unit" -p LoadState -p ActiveState -p UnitFileState -p FragmentPath) || {
    fail 'cannot establish service state'
    return 1
  }
  SERVICE_LOAD=$(printf '%s\n' "$data" | awk -F= '$1=="LoadState" {print $2}')
  SERVICE_ACTIVE_STATE=$(printf '%s\n' "$data" | awk -F= '$1=="ActiveState" {print $2}')
  SERVICE_FILE_STATE=$(printf '%s\n' "$data" | awk -F= '$1=="UnitFileState" {print $2}')
  export SERVICE_FRAGMENT
  SERVICE_FRAGMENT=$(printf '%s\n' "$data" | awk -F= '$1=="FragmentPath" {print substr($0,14)}')
  [[ "$SERVICE_LOAD" == loaded || "$SERVICE_LOAD" == not-found ]] || {
    fail 'unknown service load state'
    return 1
  }
  [[ "$SERVICE_ACTIVE_STATE" == active || "$SERVICE_ACTIVE_STATE" == inactive || "$SERVICE_ACTIVE_STATE" == failed ]] || {
    fail 'unknown service activity state'
    return 1
  }
  [[ "$SERVICE_FILE_STATE" == enabled || "$SERVICE_FILE_STATE" == disabled || "$SERVICE_FILE_STATE" == static || -z "$SERVICE_FILE_STATE" ]] || {
    fail 'unknown service enablement state'
    return 1
  }
}

validate_state_root() {
  if ! path_exists "$STATE_ROOT"; then return 0; fi
  require_managed_directory "$STATE_ROOT" 'Paseo state root' || return 1
  [[ -f "$STATE_ROOT/.managed.json" && ! -L "$STATE_ROOT/.managed.json" ]] || {
    fail 'refusing unowned Paseo state root'
    return 1
  }
  node - "$STATE_ROOT/.managed.json" <<'NODE' || {
const fs = require('node:fs');
try {
  const p=process.argv[2],s=fs.lstatSync(p),v=JSON.parse(fs.readFileSync(p,'utf8'));
  if (!s.isFile() || s.uid!==process.getuid() || (s.mode&0o077) || v.kind!=='dotfiles-paseo' || v.schemaVersion!==1) process.exit(1);
} catch { process.exit(1); }
NODE
    fail 'refusing unowned Paseo state root'
    return 1
  }
  local directory
  for directory in "$STATE_ROOT/runtimes" "$INSTALLED_RUNTIME" "$PASEO_HOME"; do
    if path_exists "$directory"; then require_managed_directory "$directory" 'managed Paseo directory' || return 1; fi
  done
}

validate_launcher() {
  [[ -f "$MANAGED_LAUNCHER" && ! -L "$MANAGED_LAUNCHER" && -x "$MANAGED_LAUNCHER" ]] || {
    fail 'managed Paseo launcher is unavailable'
    return 1
  }
  cmp -s "$MANAGED_LAUNCHER" <(render_launcher) || fail 'managed Paseo launcher is foreign or changed'
}

validate_active_health() {
  local listeners
  systemctl --user is-active paseo.service >/dev/null || {
    fail 'Paseo service is not active'
    return 1
  }
  listeners=$(ss -ltnH 'sport = :31415') || return 1
  [[ $(printf '%s\n' "$listeners" | awk 'NF {n++} END {print n+0}') == 1 && $(printf '%s\n' "$listeners" | awk 'NF {print $4}') == 127.0.0.1:31415 ]] || {
    fail 'expected exactly one loopback-only Paseo listener'
    return 1
  }
  timeout --kill-after=2 10 "$MISE_LAUNCHER" exec -- node "$SOURCE_ROOT/ai/pi/paseo/probe.mjs" health "$INSTALLED_RUNTIME" "$PASEO_HOME" || return 1
}

require_quiescent() {
  local runtime=${1:-$INSTALLED_RUNTIME} home=${2:-$PASEO_HOME}
  timeout --kill-after=2 10 "$MISE_LAUNCHER" exec -- node "$SOURCE_ROOT/ai/pi/paseo/probe.mjs" quiescent "$runtime" "$home" || {
    fail 'active work, pending approvals, or unavailable status; close work before replacement'
    return 1
  }
}

paseo_readiness_worker() {
  while ! validate_active_health >/dev/null 2>&1; do sleep 0.5; done
}
wait_for_active_health() {
  local deadline=30 status=0
  if [[ -n ${PI_PASEO_TEST_READY_DEADLINE:-} ]]; then
    require_test_override "$STATE_ROOT" || return 1
    deadline=$PI_PASEO_TEST_READY_DEADLINE
    [[ "$deadline" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  fi
  timeout --kill-after=2 "$deadline" bash -c 'source "$1"; paseo_readiness_worker' bash "${BASH_SOURCE[0]}" || status=$?
  [[ "$status" -eq 0 ]] || {
    fail 'Paseo did not establish authenticated readiness within its deadline'
    return 1
  }
}

check_paseo() {
  validate_state_root || return 1
  if ! path_exists "$STATE_ROOT"; then
    printf 'Paseo not installed\n'
    return 0
  fi
  if path_exists "$INSTALLED_RUNTIME"; then
    "$SOURCE_ROOT/libexec/validate-pi-paseo" --installed-runtime "$INSTALLED_RUNTIME" || return 1
    validate_launcher || return 1
  else
    printf 'managed runtime not installed\n'
    return 0
  fi
  node "$SOURCE_ROOT/ai/pi/paseo/config.mjs" validate "$PASEO_HOME/config.json" "$PI_LAUNCHER" || return $?
  if path_exists "$UNIT_PATH"; then validate_unit "$UNIT_PATH" || return 1; else
    printf 'prepared; service not installed\n'
    return 0
  fi
  read_service_state paseo.service || return 1
  if [[ "$SERVICE_ACTIVE_STATE" == active ]]; then validate_active_health || return 1; fi
}
