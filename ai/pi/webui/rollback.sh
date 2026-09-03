#!/usr/bin/env bash
# Retire the managed Pi Web UI service while preserving user state by default.

set -euo pipefail

TRUSTED_SYSTEM_PATH='/usr/sbin:/usr/bin:/sbin:/bin'
if [[ -n "${PI_WEBUI_TEST_TRUSTED_BIN_DIR:-}" ]]; then
  [[ "${PI_WEBUI_TESTING:-0}" == 1 && -n "${BATS_TEST_TMPDIR:-}" ]] || {
    printf '%s\n' 'error: PI_WEBUI_TEST_TRUSTED_BIN_DIR is restricted to the test sandbox' >&2
    exit 1
  }
  case "$HOME/" in "$BATS_TEST_TMPDIR"/*) ;; *)
    printf '%s\n' 'error: test HOME must be below BATS_TEST_TMPDIR' >&2
    exit 1
    ;;
  esac
  case "$PI_WEBUI_TEST_TRUSTED_BIN_DIR/" in "$BATS_TEST_TMPDIR"/*) ;; *)
    printf '%s\n' 'error: trusted test bin must be below BATS_TEST_TMPDIR' >&2
    exit 1
    ;;
  esac
  [[ -d "$PI_WEBUI_TEST_TRUSTED_BIN_DIR" && ! -L "$PI_WEBUI_TEST_TRUSTED_BIN_DIR" &&
    "$(/usr/bin/stat -c '%u' "$PI_WEBUI_TEST_TRUSTED_BIN_DIR")" == "$(/usr/bin/id -u)" ]] || {
    printf '%s\n' 'error: trusted test bin must be an owned real directory' >&2
    exit 1
  }
  PATH="$PI_WEBUI_TEST_TRUSTED_BIN_DIR:$TRUSTED_SYSTEM_PATH"
else
  PATH=$TRUSTED_SYSTEM_PATH
fi
export PATH

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
STATE_ROOT="$HOME/.local/share/pi-webui"
CURRENT_RUNTIME="$STATE_ROOT/runtimes/current"
WORKTREE="$STATE_ROOT/worktrees/dotfiles"
APPLY_LOCK="$STATE_ROOT/transactions/apply.lock"
CANDIDATE_RUNTIME="$STATE_ROOT/runtimes/candidate"
PENDING_TRANSACTION="$STATE_ROOT/transactions/pending"
SYSTEMD_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_PATH="$SYSTEMD_CONFIG_HOME/systemd/user/pi-webui.service"
REMOVE_RUNTIME=0
REMOVE_WORKTREE=0
MANAGED_PI_LAUNCHER=''
RUNTIME_IDENTITY=''
WORKTREE_IDENTITY=''
WORKTREE_HEAD=''
WORKTREE_GIT_DIR=''

usage() {
  printf 'usage: %s [--remove-runtime] [--remove-worktree]\n' "$0"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

restricted_test_path() {
  local value=$1 label=$2
  [[ "${PI_WEBUI_TESTING:-0}" == 1 && -n "${BATS_TEST_TMPDIR:-}" ]] || {
    fail "$label is restricted to the test sandbox"
    return 1
  }
  case "$HOME/" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      fail 'test HOME must be below BATS_TEST_TMPDIR'
      return 1
      ;;
  esac
  case "$value/" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      fail "$label must be below BATS_TEST_TMPDIR"
      return 1
      ;;
  esac
}

platform_release_file() {
  if [[ -z "${PI_WEBUI_TEST_OS_RELEASE:-}" ]]; then
    printf '%s\n' /etc/os-release
    return 0
  fi
  restricted_test_path "$PI_WEBUI_TEST_OS_RELEASE" PI_WEBUI_TEST_OS_RELEASE
  [[ -f "$PI_WEBUI_TEST_OS_RELEASE" && ! -L "$PI_WEBUI_TEST_OS_RELEASE" ]] || {
    fail 'test os-release fixture must be a regular file'
    return 1
  }
  printf '%s\n' "$PI_WEBUI_TEST_OS_RELEASE"
}

require_supported_platform() {
  local release_file id='' version_id='' codename='' key value kernel
  release_file=$(platform_release_file)
  while IFS='=' read -r key value; do
    value=${value#\"}
    value=${value%\"}
    case "$key" in
      ID) id=$value ;;
      VERSION_ID) version_id=$value ;;
      VERSION_CODENAME) codename=$value ;;
    esac
  done <"$release_file"
  kernel=$(uname -r)
  if [[ "$id" != ubuntu || "$version_id" != 24.04 || "$codename" != noble ||
    "$kernel" != *[Mm]icrosoft* ]]; then
    fail 'Pi Web UI rollback requires Ubuntu 24.04 Noble under WSL'
    return 1
  fi
  command -v systemctl >/dev/null 2>&1 || {
    fail 'systemd user manager is unavailable'
    return 1
  }
  systemctl --user show-environment >/dev/null 2>&1 || {
    fail 'systemd user manager is unavailable'
    return 1
  }
}

run_node() {
  if command -v node >/dev/null 2>&1; then
    node "$@"
  elif command -v mise >/dev/null 2>&1; then
    mise exec -- node "$@"
  else
    fail 'Node.js is required for exact rollback validation'
    return 1
  fi
}

require_safe_existing_directory() {
  local directory=$1 label=$2 mode
  [[ -e "$directory" || -L "$directory" ]] || return 0
  [[ -d "$directory" && ! -L "$directory" ]] || {
    fail "$label must be a real directory"
    return 1
  }
  [[ "$(stat -c '%u' "$directory")" == "$(id -u)" ]] || {
    fail "$label must be owned by the current user"
    return 1
  }
  mode=$(stat -c '%a' "$directory")
  (((8#$mode & 022) == 0)) || {
    fail "$label must not be group or world writable"
    return 1
  }
}

validate_state_parent_chain() {
  require_safe_existing_directory "$HOME" 'HOME directory'
  require_safe_existing_directory "$HOME/.local" 'HOME .local directory'
  require_safe_existing_directory "$HOME/.local/share" 'HOME share directory'
  require_safe_existing_directory "$STATE_ROOT" 'Pi Web UI state root'
  require_safe_existing_directory "$STATE_ROOT/runtimes" 'Pi Web UI runtimes parent'
  require_safe_existing_directory "$STATE_ROOT/worktrees" 'Pi Web UI worktrees parent'
}

canonical_contained_target() {
  local target=$1 suffix=$2 canonical_state canonical_target
  [[ -d "$STATE_ROOT" && ! -L "$STATE_ROOT" && -d "$target" && ! -L "$target" ]] || return 1
  canonical_state=$(cd "$STATE_ROOT" && pwd -P)
  canonical_target=$(cd "$target" && pwd -P)
  [[ "$canonical_target" == "$canonical_state/$suffix" ]] || {
    fail "managed target escapes the canonical Pi Web UI state root: $target"
    return 1
  }
  printf '%s\n' "$canonical_target"
}

require_empty_serve() {
  local serve_json funnel_json result
  command -v tailscale >/dev/null 2>&1 || return 0
  serve_json=$(tailscale serve status --json) || {
    fail 'cannot inspect Tailscale Serve configuration'
    return 1
  }
  funnel_json=$(tailscale funnel status --json) || {
    fail 'cannot inspect shared Tailscale Funnel configuration'
    return 1
  }
  result=$(SERVE_JSON="$serve_json" FUNNEL_JSON="$funnel_json" run_node -e '
function empty(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  if (Object.values(value.AllowFunnel || {}).some(Boolean)) return false;
  if (Object.keys(value.TCP || {}).length || Object.keys(value.Web || {}).length) return false;
  for (const [key, candidate] of Object.entries(value)) {
    if (key === "AllowFunnel") {
      if (Object.values(candidate || {}).some(Boolean)) return false;
    } else if (candidate != null && candidate !== false &&
      (!Array.isArray(candidate) || candidate.length) &&
      (typeof candidate !== "object" || Object.keys(candidate).length)) return false;
  }
  return true;
}
try {
  const serve=JSON.parse(process.env.SERVE_JSON), funnel=JSON.parse(process.env.FUNNEL_JSON);
  process.stdout.write(empty(serve) && empty(funnel) ? "empty" : "active");
} catch (_) { process.exit(2); }
') || {
    fail 'cannot parse Tailscale Serve/Funnel configuration'
    return 1
  }
  [[ "$result" == empty ]] || {
    fail "Tailscale Serve must be removed first: $ROOT/ai/pi/webui/tailscale.sh serve-off"
    return 1
  }
}

validate_pi_launcher() {
  run_node - "$MANAGED_PI_LAUNCHER" <<'NODE'
const fs=require('node:fs'), path=require('node:path');
const launcher=process.argv[2];
if(!path.isAbsolute(launcher)) process.exit(1);
const real=fs.realpathSync(launcher);
let current=path.dirname(real);
while(true) {
  const manifestPath=path.join(current,'package.json');
  if(fs.existsSync(manifestPath)) {
    const manifest=JSON.parse(fs.readFileSync(manifestPath,'utf8'));
    if(manifest.name==='@earendil-works/pi-coding-agent') {
      if(manifest.version!=='0.84.4' || typeof manifest.bin?.pi!=='string' ||
         fs.realpathSync(path.resolve(current,manifest.bin.pi))!==real) process.exit(1);
      process.exit(0);
    }
  }
  const parent=path.dirname(current);
  if(parent===current) process.exit(1);
  current=parent;
}
NODE
}

validate_unit_shape() {
  [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" &&
    "$(stat -c '%u' "$UNIT_PATH")" == "$(id -u)" &&
    "$(stat -c '%a' "$UNIT_PATH")" == 600 ]] || {
    fail 'Pi Web UI unit is unsafe or foreign'
    return 1
  }
  MANAGED_PI_LAUNCHER=$(
    run_node - "$ROOT/ai/pi/webui/pi-webui.service.in" "$UNIT_PATH" \
      "$CURRENT_RUNTIME/node_modules/.bin/pi-webui" "$WORKTREE" <<'NODE'
const fs=require('node:fs');
const [templatePath, unitPath, runtime, worktree]=process.argv.slice(2);
const unit=fs.readFileSync(unitPath,'utf8');
const match=unit.match(/ --pi "([^"\n]+)" --no-remote-auth /);
if(!match || !match[1].startsWith('/')) process.exit(1);
let expected=fs.readFileSync(templatePath,'utf8')
  .replace('@RUNTIME_LAUNCHER@',JSON.stringify(runtime))
  .replace('@WORKTREE@',JSON.stringify(worktree))
  .replace('@PI_LAUNCHER@',JSON.stringify(match[1]));
if(unit!==expected || /@[A-Z][A-Z0-9_]*@/.test(expected)) process.exit(1);
process.stdout.write(match[1]);
NODE
  ) || {
    fail 'Pi Web UI unit is foreign'
    return 1
  }
  validate_pi_launcher || {
    fail 'Pi Web UI Pi launcher identity is foreign'
    return 1
  }
}

validate_runtime() {
  local marker="$CURRENT_RUNTIME/.pi-webui-current" mode
  [[ -d "$CURRENT_RUNTIME" && ! -L "$CURRENT_RUNTIME" ]] || {
    fail 'managed runtime must be a real directory'
    return 1
  }
  mode=$(stat -c '%a' "$CURRENT_RUNTIME")
  [[ "$(stat -c '%u' "$CURRENT_RUNTIME")" == "$(id -u)" && "$mode" == 700 ]] || {
    fail 'managed runtime must be owner-only and current-user-owned'
    return 1
  }
  [[ -f "$marker" && ! -L "$marker" &&
    "$(stat -c '%u' "$marker")" == "$(id -u)" &&
    "$(cat "$marker")" == pi-webui-task3-current-v1 ]] || {
    fail 'managed runtime marker is missing or foreign'
    return 1
  }
  bash "$ROOT/bin/validate-pi-webui" --installed-runtime "$CURRENT_RUNTIME" >/dev/null
}

canonical_git_path() {
  local checkout=$1 value=$2 parent base
  case "$value" in
    /*) ;;
    *) value="$checkout/$value" ;;
  esac
  if [[ -d "$value" ]]; then
    (cd "$value" && pwd -P)
  else
    parent=$(cd "$(dirname "$value")" && pwd -P) || return 1
    base=$(basename "$value")
    printf '%s/%s\n' "$parent" "$base"
  fi
}

validate_worktree() {
  local source_top source_common_raw source_common target_common_raw target_common
  local target_git_raw target_git status mode
  [[ -d "$WORKTREE" && ! -L "$WORKTREE" ]] || {
    fail 'managed worktree must be a real directory'
    return 1
  }
  [[ "$(stat -c '%u' "$WORKTREE")" == "$(id -u)" ]] || {
    fail 'managed worktree has foreign ownership'
    return 1
  }
  mode=$(stat -c '%a' "$WORKTREE")
  (((8#$mode & 022) == 0)) || {
    fail 'managed worktree must not be group or world writable'
    return 1
  }
  source_top=$(git -C "$ROOT" rev-parse --show-toplevel)
  source_common_raw=$(git -C "$source_top" rev-parse --git-common-dir)
  source_common=$(canonical_git_path "$source_top" "$source_common_raw")
  git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    fail 'managed worktree belongs to a foreign repository'
    return 1
  }
  target_common_raw=$(git -C "$WORKTREE" rev-parse --git-common-dir)
  target_common=$(canonical_git_path "$WORKTREE" "$target_common_raw")
  [[ "$target_common" == "$source_common" ]] || {
    fail 'managed worktree belongs to a foreign repository'
    return 1
  }
  target_git_raw=$(git -C "$WORKTREE" rev-parse --git-dir)
  target_git=$(canonical_git_path "$WORKTREE" "$target_git_raw")
  [[ "$target_git" != "$target_common" ]] || {
    fail 'managed worktree must not be the primary checkout'
    return 1
  }
  if git -C "$WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'managed worktree must be detached'
    return 1
  fi
  status=$(git -C "$WORKTREE" status --porcelain --untracked-files=all --ignored=matching)
  [[ -z "$status" ]] || {
    fail 'managed worktree must be clean, including ignored files'
    return 1
  }
}

validate_destructive_state() {
  if [[ -e "$APPLY_LOCK" || -L "$APPLY_LOCK" ]]; then
    fail 'Pi Web UI installer apply lock is present; refusing destructive rollback'
    return 1
  fi
  if [[ -e "$CANDIDATE_RUNTIME" || -L "$CANDIDATE_RUNTIME" ||
    -e "$PENDING_TRANSACTION" || -L "$PENDING_TRANSACTION" ]]; then
    fail 'Pi Web UI candidate or pending transaction is present; refusing destructive rollback'
    return 1
  fi
  if [[ "$REMOVE_RUNTIME" == 1 && (-e "$CURRENT_RUNTIME" || -L "$CURRENT_RUNTIME") ]]; then
    validate_runtime
    canonical_contained_target "$CURRENT_RUNTIME" runtimes/current >/dev/null || return 1
    RUNTIME_IDENTITY=$(stat -c '%d:%i' "$CURRENT_RUNTIME")
  fi
  if [[ "$REMOVE_WORKTREE" == 1 && (-e "$WORKTREE" || -L "$WORKTREE") ]]; then
    validate_worktree
    canonical_contained_target "$WORKTREE" worktrees/dotfiles >/dev/null || return 1
    WORKTREE_IDENTITY=$(stat -c '%d:%i' "$WORKTREE")
    WORKTREE_HEAD=$(git -C "$WORKTREE" rev-parse --verify HEAD)
    WORKTREE_GIT_DIR=$(canonical_git_path "$WORKTREE" "$(git -C "$WORKTREE" rev-parse --git-dir)")
  fi
}

loaded_unit_is_local() {
  local fragment
  fragment=$(systemctl --user show --property=FragmentPath --value pi-webui.service 2>/dev/null) || {
    fail 'cannot inspect loaded Pi Web UI unit'
    return 1
  }
  [[ -z "$fragment" || "$fragment" == "$UNIT_PATH" ]] || {
    fail 'loaded Pi Web UI unit is foreign'
    return 1
  }
}

verify_active_service_identity() {
  local health status
  systemctl --user is-active --quiet pi-webui.service || return 0
  health=$(curl --fail --silent --show-error http://127.0.0.1:31415/api/health)
  printf '%s' "$health" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const value=JSON.parse(input);
  if(value.ok!==true || value.webuiVersion!=="0.10.3" || value.piVersion!=="0.84.4") process.exit(1);
});' || {
    fail 'active Pi Web UI exact health validation failed'
    return 1
  }
  status=$(curl --fail --silent --show-error \
    'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0')
  # shellcheck disable=SC2016 # JavaScript template literal, not shell expansion.
  printf '%s' "$status" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const [worktree,launcher]=process.argv.slice(1), value=JSON.parse(input), data=value.data, network=data?.network, tabs=data?.tabs;
  if(value.ok!==true || data?.webuiVersion!=="0.10.3" || data?.piVersion!=="0.84.4" ||
     network?.host!=="127.0.0.1" || network?.port!==31415 || network?.open!==false ||
     !Array.isArray(network.urls) || network.urls.length || !Array.isArray(tabs) || tabs.length<1 ||
     tabs.some(tab => tab.cwd!==worktree || tab.running!==true || typeof tab.command!=="string" ||
       !tab.command.startsWith(`${launcher} --mode rpc`))) process.exit(1);
});' "$WORKTREE" "$MANAGED_PI_LAUNCHER" || {
    fail 'active Pi Web UI detailed identity validation failed'
    return 1
  }
}

verify_no_listener() {
  local output
  output=$(ss -H -ltn '( sport = :31415 )')
  [[ -z "$output" ]] || {
    fail 'port 31415 still has a listener'
    return 1
  }
}

run_process_check() {
  local hook=${PI_WEBUI_TEST_PROCESS_CHECK:-}
  if [[ -n "$hook" ]]; then
    restricted_test_path "$hook" PI_WEBUI_TEST_PROCESS_CHECK
    [[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || {
      fail 'test process check must be an executable regular file'
      return 1
    }
    "$hook"
    return
  fi
  run_node - "$CURRENT_RUNTIME" "$WORKTREE" "$HOME/.local/share/pi-webui-runtime" \
    "$HOME/.dotfiles/tmp/worktrees/piface-smoke" <<'NODE'
const fs=require('node:fs');
const [runtime, worktree, trialRuntime, trialWorktree]=process.argv.slice(2);
const self=new Set([process.pid,process.ppid]);
const offenders=[];
for(const name of fs.readdirSync('/proc')) {
  if(!/^\d+$/.test(name)||self.has(Number(name))) continue;
  try {
    const cwd=fs.readlinkSync(`/proc/${name}/cwd`);
    const args=fs.readFileSync(`/proc/${name}/cmdline`).toString().split('\0').filter(Boolean);
    const text=args.join(' ');
    const scoped=cwd===worktree||cwd===trialWorktree;
    const webui=text.includes(`${runtime}/`)||text.includes(`${trialRuntime}/`)||/(?:^|\/)(?:pi-webui|pi-webui\.mjs)(?:\s|$)/.test(text)&&scoped;
    const supervisor=/rpc-supervisor/.test(text)&&scoped;
    const pi=scoped&&/(?:^|\/)pi(?:\s|$)/.test(text);
    if(webui||supervisor||pi) offenders.push(`${name}:${cwd}:${args[0]||''}`);
  } catch(error) {
    if(!['ENOENT','EACCES'].includes(error.code)) throw error;
  }
}
if(offenders.length) { console.error(`managed Pi Web UI processes remain: ${offenders.join(', ')}`); process.exit(1); }
NODE
}

stop_and_remove_unit() {
  systemctl --user disable --now pi-webui.service
  if systemctl --user is-active --quiet pi-webui.service; then
    fail 'Pi Web UI service remained active after disable'
    return 1
  fi
  verify_no_listener
  run_process_check
  validate_unit_shape
  rm -- "$UNIT_PATH"
  systemctl --user daemon-reload
  printf 'removed: managed Pi Web UI service unit\n'
}

remove_runtime() {
  local observed_identity
  if [[ ! -e "$CURRENT_RUNTIME" && ! -L "$CURRENT_RUNTIME" ]]; then
    printf 'ready: managed Pi Web UI runtime already absent\n'
    return 0
  fi
  validate_state_parent_chain
  validate_runtime
  canonical_contained_target "$CURRENT_RUNTIME" runtimes/current >/dev/null || return 1
  observed_identity=$(stat -c '%d:%i' "$CURRENT_RUNTIME")
  [[ -n "$RUNTIME_IDENTITY" && "$observed_identity" == "$RUNTIME_IDENTITY" ]] || {
    fail 'managed runtime identity changed before removal'
    return 1
  }
  rm -rf -- "$CURRENT_RUNTIME"
  [[ ! -e "$CURRENT_RUNTIME" && ! -L "$CURRENT_RUNTIME" ]] || {
    fail 'managed runtime removal failed'
    return 1
  }
  printf 'removed: managed Pi Web UI runtime\n'
}

remove_worktree() {
  local source_top observed_identity observed_head observed_git_dir
  if [[ ! -e "$WORKTREE" && ! -L "$WORKTREE" ]]; then
    printf 'ready: managed Pi Web UI worktree already absent\n'
    return 0
  fi
  source_top=$(git -C "$ROOT" rev-parse --show-toplevel)
  validate_state_parent_chain
  validate_worktree
  canonical_contained_target "$WORKTREE" worktrees/dotfiles >/dev/null || return 1
  observed_identity=$(stat -c '%d:%i' "$WORKTREE")
  observed_head=$(git -C "$WORKTREE" rev-parse --verify HEAD)
  observed_git_dir=$(canonical_git_path "$WORKTREE" "$(git -C "$WORKTREE" rev-parse --git-dir)")
  [[ -n "$WORKTREE_IDENTITY" && "$observed_identity" == "$WORKTREE_IDENTITY" &&
    "$observed_head" == "$WORKTREE_HEAD" && "$observed_git_dir" == "$WORKTREE_GIT_DIR" ]] || {
    fail 'managed worktree identity changed before removal'
    return 1
  }
  git -C "$source_top" worktree remove "$WORKTREE"
  [[ ! -e "$WORKTREE" && ! -L "$WORKTREE" ]] || {
    fail 'managed worktree removal failed'
    return 1
  }
  if git -C "$source_top" worktree list --porcelain | grep -Fqx "worktree $WORKTREE"; then
    fail 'managed worktree remains registered'
    return 1
  fi
  printf 'removed: clean detached managed worktree\n'
}

parse_arguments() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --remove-runtime) REMOVE_RUNTIME=1 ;;
      --remove-worktree) REMOVE_WORKTREE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        return 2
        ;;
    esac
  done
}

main() {
  parse_arguments "$@"
  require_supported_platform
  validate_state_parent_chain
  require_empty_serve
  loaded_unit_is_local
  validate_destructive_state

  if [[ -e "$UNIT_PATH" || -L "$UNIT_PATH" ]]; then
    validate_unit_shape
    validate_runtime
    validate_worktree
    verify_active_service_identity
    stop_and_remove_unit
  else
    if systemctl --user is-active --quiet pi-webui.service ||
      systemctl --user is-enabled --quiet pi-webui.service; then
      fail 'loaded Pi Web UI service has no managed unit file'
      return 1
    fi
    if [[ -e "$CURRENT_RUNTIME" || -L "$CURRENT_RUNTIME" ]]; then
      validate_runtime || {
        fail 'residual Pi Web UI runtime is foreign'
        return 1
      }
    fi
    verify_no_listener
    run_process_check
    printf 'ready: Pi Web UI service is not installed\n'
  fi

  if [[ "$REMOVE_RUNTIME" == 1 ]]; then remove_runtime; fi
  if [[ "$REMOVE_WORKTREE" == 1 ]]; then remove_worktree; fi
  printf '%s\n' 'preserved: settings, supervisor state, transcripts, Tailscale identity, trial evidence, and backups'
}

main "$@"
