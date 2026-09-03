#!/usr/bin/bash -p
# Retire the managed Pi Web UI service while preserving user state by default.

if [[ $- != *p* ]]; then
  builtin printf '%s\n' 'error: this helper must be executed directly (privileged Bash startup mode is required)' >&2
  builtin exit 126
fi
set -euo pipefail

PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

BASH_BIN='/usr/bin/bash'
UNAME_BIN='/usr/bin/uname'
SYSTEMCTL_BIN='/usr/bin/systemctl'
TAILSCALE_BIN='/usr/bin/tailscale'
CURL_BIN='/usr/bin/curl'
SS_BIN='/usr/bin/ss'
STAT_BIN='/usr/bin/stat'
SHA256SUM_BIN='/usr/bin/sha256sum'
ID_BIN='/usr/bin/id'
GIT_BIN='/usr/bin/git'
MISE_SYSTEM_BIN='/usr/bin/mise'
MISE_SYSTEM_OWNER=0
MISE_USER_BIN="$HOME/.local/bin/mise"
TRUST_ANCHOR='/'
OS_RELEASE_FILE='/etc/os-release'
PROC_ROOT='/proc'
PROCESS_CHECK_HOOK=''

ROOT="$(cd "$(/usr/bin/dirname "$0")/../../.." && pwd -P)"
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
MISE_BIN=''
MISE_PATH_IDENTITY=''
MISE_TARGET=''
MISE_TARGET_IDENTITY=''
MISE_HASH=''
NODE_BIN=''
NODE_IDENTITY=''
NODE_HASH=''

usage() {
  printf 'usage: %s [--remove-runtime] [--remove-worktree]\n' "$0"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

require_supported_platform() {
  local release_file id='' version_id='' codename='' key value kernel
  release_file=$OS_RELEASE_FILE
  while IFS='=' read -r key value; do
    value=${value#\"}
    value=${value%\"}
    case "$key" in
      ID) id=$value ;;
      VERSION_ID) version_id=$value ;;
      VERSION_CODENAME) codename=$value ;;
    esac
  done <"$release_file"
  kernel=$("$UNAME_BIN" -r)
  if [[ "$id" != ubuntu || "$version_id" != 24.04 || "$codename" != noble ||
    "$kernel" != *[Mm]icrosoft* ]]; then
    fail 'Pi Web UI rollback requires Ubuntu 24.04 Noble under WSL'
    return 1
  fi
  [[ -x "$SYSTEMCTL_BIN" && ! -d "$SYSTEMCTL_BIN" ]] || {
    fail 'systemd user manager is unavailable'
    return 1
  }
  "$SYSTEMCTL_BIN" --user show-environment >/dev/null 2>&1 || {
    fail 'systemd user manager is unavailable'
    return 1
  }
}

validate_safe_parent_chain() {
  local path=$1 directory parent owner mode current_uid
  [[ "$path" == /* ]] || return 1
  if [[ "$TRUST_ANCHOR" != / ]]; then
    case "$path/" in "$TRUST_ANCHOR"/*) ;; *) return 1 ;; esac
  fi
  directory=${path%/*}
  [[ -n "$directory" ]] || directory=/
  current_uid=$(/usr/bin/id -u)
  while :; do
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner=$("$STAT_BIN" -c '%u' "$directory") || return 1
    [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
    mode=$("$STAT_BIN" -c '%a' "$directory") || return 1
    (((8#$mode & 022) == 0)) || return 1
    [[ "$directory" == "$TRUST_ANCHOR" ]] && return 0
    parent=${directory%/*}
    [[ -n "$parent" ]] || parent=/
    [[ "$parent" != "$directory" ]] || return 1
    directory=$parent
  done
}

validate_executable_target() {
  local path=$1 expected_owner=$2 mode
  validate_safe_parent_chain "$path" || return 1
  [[ -f "$path" && ! -L "$path" && -x "$path" &&
    "$("$STAT_BIN" -c '%u' "$path")" == "$expected_owner" ]] || return 1
  mode=$("$STAT_BIN" -c '%a' "$path")
  (((8#$mode & 022) == 0))
}

hash_file() {
  "$SHA256SUM_BIN" "$1" | /usr/bin/cut -d' ' -f1
}

validate_mise_candidate() {
  local candidate=$1 expected_owner=$2 target
  [[ -e "$candidate" || -L "$candidate" ]] || return 1
  validate_safe_parent_chain "$candidate" || return 1
  [[ ! -d "$candidate" && -x "$candidate" && "$("$STAT_BIN" -c '%u' "$candidate")" == "$expected_owner" ]] || return 1
  target=$(/usr/bin/readlink -f "$candidate") || return 1
  validate_executable_target "$target" "$expected_owner" || return 1
  if [[ "$candidate" == "$MISE_USER_BIN" && "$target" != "$candidate" ]]; then
    case "$target" in "$HOME/.local/share/mise/"*) ;; *) return 1 ;; esac
  fi
  MISE_BIN=$candidate
  MISE_PATH_IDENTITY=$("$STAT_BIN" -c '%d:%i' "$candidate")
  MISE_TARGET=$target
  MISE_TARGET_IDENTITY=$("$STAT_BIN" -c '%d:%i' "$target")
  MISE_HASH=$(hash_file "$target")
  exec 8<"$target" || return 1
  [[ "$("$STAT_BIN" -L -c '%d:%i' /proc/self/fd/8)" == "$MISE_TARGET_IDENTITY" &&
  "$(hash_file /proc/self/fd/8)" == "$MISE_HASH" ]] || return 1
}

validate_mise_stable() {
  local expected_owner
  if [[ "$MISE_BIN" == "$MISE_SYSTEM_BIN" ]]; then expected_owner=$MISE_SYSTEM_OWNER; else expected_owner=$(/usr/bin/id -u); fi
  if [[ -z "$MISE_BIN" || -z "$MISE_TARGET" ]] ||
    ! validate_safe_parent_chain "$MISE_BIN" ||
    ! validate_executable_target "$MISE_TARGET" "$expected_owner"; then
    fail 'mise executable identity changed after validation'
    return 1
  fi
  if [[ "$("$STAT_BIN" -c '%d:%i' "$MISE_BIN" 2>/dev/null)" != "$MISE_PATH_IDENTITY" ||
  "$(/usr/bin/readlink -f "$MISE_BIN" 2>/dev/null)" != "$MISE_TARGET" ||
  "$("$STAT_BIN" -c '%d:%i' "$MISE_TARGET" 2>/dev/null)" != "$MISE_TARGET_IDENTITY" ||
  "$(hash_file "$MISE_TARGET")" != "$MISE_HASH" ||
  "$("$STAT_BIN" -L -c '%d:%i' /proc/self/fd/8 2>/dev/null)" != "$MISE_TARGET_IDENTITY" ||
  "$(hash_file /proc/self/fd/8)" != "$MISE_HASH" ]]; then
    fail 'mise executable identity changed after validation'
    return 1
  fi
}

resolve_mise_and_node() {
  local relative version current_uid
  [[ -n "$NODE_BIN" ]] && return 0
  current_uid=$(/usr/bin/id -u)
  if [[ -e "$MISE_SYSTEM_BIN" || -L "$MISE_SYSTEM_BIN" ]]; then
    validate_mise_candidate "$MISE_SYSTEM_BIN" "$MISE_SYSTEM_OWNER" || {
      fail 'system mise executable or parent chain is unsafe'
      return 1
    }
  else
    validate_mise_candidate "$MISE_USER_BIN" "$current_uid" || {
      fail 'no safe supported mise executable and parent chain is available'
      return 1
    }
  fi
  validate_mise_stable || return 1
  NODE_BIN=$(/proc/self/fd/8 which node) || {
    fail 'mise cannot resolve Node.js'
    return 1
  }
  validate_mise_stable || return 1
  relative=${NODE_BIN#"$HOME/.local/share/mise/installs/node/"}
  version=${relative%%/*}
  [[ -n "$version" && "$relative" == "$version/bin/node" ]] || {
    fail 'mise resolved Node.js outside the expected installs root'
    return 1
  }
  validate_executable_target "$NODE_BIN" "$current_uid" || {
    fail 'mise resolved an unsafe Node.js executable or parent chain'
    return 1
  }
  NODE_IDENTITY=$("$STAT_BIN" -c '%d:%i' "$NODE_BIN")
  NODE_HASH=$(hash_file "$NODE_BIN")
  exec 9<"$NODE_BIN" || return 1
  [[ "$("$STAT_BIN" -L -c '%d:%i' /proc/self/fd/9)" == "$NODE_IDENTITY" &&
  "$(hash_file /proc/self/fd/9)" == "$NODE_HASH" ]] || {
    fail 'Node.js executable changed while opening it'
    return 1
  }
}

validate_node_stable() {
  validate_mise_stable || return 1
  if [[ -z "$NODE_BIN" ]] || ! validate_executable_target "$NODE_BIN" "$(/usr/bin/id -u)"; then
    fail 'Node.js executable identity changed after validation'
    return 1
  fi
  if [[ "$("$STAT_BIN" -c '%d:%i' "$NODE_BIN" 2>/dev/null)" != "$NODE_IDENTITY" ||
  "$(hash_file "$NODE_BIN")" != "$NODE_HASH" ||
  "$("$STAT_BIN" -L -c '%d:%i' /proc/self/fd/9 2>/dev/null)" != "$NODE_IDENTITY" ||
  "$(hash_file /proc/self/fd/9)" != "$NODE_HASH" ]]; then
    fail 'Node.js executable identity changed after validation'
    return 1
  fi
}

run_node() {
  local status=0
  resolve_mise_and_node || return 1
  validate_node_stable || return 1
  /proc/self/fd/9 "$@" || status=$?
  validate_node_stable || return 1
  return "$status"
}

validate_installed_runtime() {
  local status=0 shim_dir
  resolve_mise_and_node || return 1
  validate_node_stable || return 1
  shim_dir=$(/usr/bin/mktemp -d /tmp/pi-webui-node-shim.XXXXXX) || return 1
  /usr/bin/chmod 0700 "$shim_dir"
  printf '%s\n' '#!/usr/bin/bash -p' 'exec /proc/self/fd/9 "$@"' >"$shim_dir/node"
  /usr/bin/chmod 0700 "$shim_dir/node"
  PATH="$shim_dir:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$BASH_BIN" -p "$ROOT/bin/validate-pi-webui" --installed-runtime "$CURRENT_RUNTIME" >/dev/null || status=$?
  /usr/bin/rm -rf -- "$shim_dir"
  validate_node_stable || return 1
  return "$status"
}

require_safe_existing_directory() {
  local directory=$1 label=$2 mode
  [[ -e "$directory" || -L "$directory" ]] || return 0
  [[ -d "$directory" && ! -L "$directory" ]] || {
    fail "$label must be a real directory"
    return 1
  }
  [[ "$("$STAT_BIN" -c '%u' "$directory")" == "$("$ID_BIN" -u)" ]] || {
    fail "$label must be owned by the current user"
    return 1
  }
  mode=$("$STAT_BIN" -c '%a' "$directory")
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
  [[ -x "$TAILSCALE_BIN" && ! -d "$TAILSCALE_BIN" ]] || return 0
  serve_json=$("$TAILSCALE_BIN" serve status --json) || {
    fail 'cannot inspect Tailscale Serve configuration'
    return 1
  }
  funnel_json=$("$TAILSCALE_BIN" funnel status --json) || {
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
    "$("$STAT_BIN" -c '%u' "$UNIT_PATH")" == "$("$ID_BIN" -u)" &&
    "$("$STAT_BIN" -c '%a' "$UNIT_PATH")" == 600 ]] || {
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
  mode=$("$STAT_BIN" -c '%a' "$CURRENT_RUNTIME")
  [[ "$("$STAT_BIN" -c '%u' "$CURRENT_RUNTIME")" == "$("$ID_BIN" -u)" && "$mode" == 700 ]] || {
    fail 'managed runtime must be owner-only and current-user-owned'
    return 1
  }
  [[ -f "$marker" && ! -L "$marker" &&
    "$("$STAT_BIN" -c '%u' "$marker")" == "$("$ID_BIN" -u)" &&
    "$(cat "$marker")" == pi-webui-task3-current-v1 ]] || {
    fail 'managed runtime marker is missing or foreign'
    return 1
  }
  validate_installed_runtime
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
  [[ "$("$STAT_BIN" -c '%u' "$WORKTREE")" == "$("$ID_BIN" -u)" ]] || {
    fail 'managed worktree has foreign ownership'
    return 1
  }
  mode=$("$STAT_BIN" -c '%a' "$WORKTREE")
  (((8#$mode & 022) == 0)) || {
    fail 'managed worktree must not be group or world writable'
    return 1
  }
  source_top=$("$GIT_BIN" -C "$ROOT" rev-parse --show-toplevel)
  source_common_raw=$("$GIT_BIN" -C "$source_top" rev-parse --git-common-dir)
  source_common=$(canonical_git_path "$source_top" "$source_common_raw")
  "$GIT_BIN" -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    fail 'managed worktree belongs to a foreign repository'
    return 1
  }
  target_common_raw=$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-common-dir)
  target_common=$(canonical_git_path "$WORKTREE" "$target_common_raw")
  [[ "$target_common" == "$source_common" ]] || {
    fail 'managed worktree belongs to a foreign repository'
    return 1
  }
  target_git_raw=$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-dir)
  target_git=$(canonical_git_path "$WORKTREE" "$target_git_raw")
  [[ "$target_git" != "$target_common" ]] || {
    fail 'managed worktree must not be the primary checkout'
    return 1
  }
  if "$GIT_BIN" -C "$WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'managed worktree must be detached'
    return 1
  fi
  status=$("$GIT_BIN" -C "$WORKTREE" status --porcelain --untracked-files=all --ignored=matching)
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
    RUNTIME_IDENTITY=$("$STAT_BIN" -c '%d:%i' "$CURRENT_RUNTIME")
  fi
  if [[ "$REMOVE_WORKTREE" == 1 && (-e "$WORKTREE" || -L "$WORKTREE") ]]; then
    validate_worktree
    canonical_contained_target "$WORKTREE" worktrees/dotfiles >/dev/null || return 1
    WORKTREE_IDENTITY=$("$STAT_BIN" -c '%d:%i' "$WORKTREE")
    WORKTREE_HEAD=$("$GIT_BIN" -C "$WORKTREE" rev-parse --verify HEAD)
    WORKTREE_GIT_DIR=$(canonical_git_path "$WORKTREE" "$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-dir)")
  fi
}

loaded_unit_is_local() {
  local fragment
  fragment=$("$SYSTEMCTL_BIN" --user show --property=FragmentPath --value pi-webui.service 2>/dev/null) || {
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
  "$SYSTEMCTL_BIN" --user is-active --quiet pi-webui.service || return 0
  health=$("$CURL_BIN" --fail --silent --show-error http://127.0.0.1:31415/api/health)
  printf '%s' "$health" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const value=JSON.parse(input);
  if(value.ok!==true || value.webuiVersion!=="0.10.3" || value.piVersion!=="0.84.4") process.exit(1);
});' || {
    fail 'active Pi Web UI exact health validation failed'
    return 1
  }
  status=$("$CURL_BIN" --fail --silent --show-error \
    'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0')
  # shellcheck disable=SC2016 # JavaScript template literal, not shell expansion.
  printf '%s' "$status" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const [worktree,launcher]=process.argv.slice(1), rpcCommand=`${launcher} --mode rpc`, value=JSON.parse(input), data=value.data, network=data?.network, tabs=data?.tabs;
  if(value.ok!==true || data?.webuiVersion!=="0.10.3" || data?.piVersion!=="0.84.4" ||
     network?.host!=="127.0.0.1" || network?.port!==31415 || network?.open!==false ||
     !Array.isArray(network.urls) || network.urls.length || !Array.isArray(tabs) || tabs.length<1 ||
     tabs.some(tab => tab.cwd!==worktree || tab.running!==true || typeof tab.command!=="string" ||
       !(tab.command===rpcCommand ||
         (tab.command.startsWith(rpcCommand) && /\s/.test(tab.command[rpcCommand.length]))))) process.exit(1);
});' "$WORKTREE" "$MANAGED_PI_LAUNCHER" || {
    fail 'active Pi Web UI detailed identity validation failed'
    return 1
  }
}

verify_no_listener() {
  local output
  output=$("$SS_BIN" -H -ltn '( sport = :31415 )')
  [[ -z "$output" ]] || {
    fail 'port 31415 still has a listener'
    return 1
  }
}

run_process_check() {
  if [[ -n "$PROCESS_CHECK_HOOK" ]]; then
    [[ -f "$PROCESS_CHECK_HOOK" && ! -L "$PROCESS_CHECK_HOOK" && -x "$PROCESS_CHECK_HOOK" ]] || {
      fail 'fixed process check hook must be an executable regular file'
      return 1
    }
    "$PROCESS_CHECK_HOOK"
    return
  fi
  run_node - "$PROC_ROOT" "$CURRENT_RUNTIME" "$WORKTREE" "$HOME/.local/share/pi-webui-runtime" \
    "$HOME/.dotfiles/tmp/worktrees/piface-smoke" <<'NODE'
const fs=require('node:fs'), path=require('node:path');
const [root, runtime, worktree, trialRuntime, trialWorktree]=process.argv.slice(2);
const self=new Set([process.pid,process.ppid]);
const offenders=[];
for(const name of fs.readdirSync(root)) {
  if(!/^\d+$/.test(name)||self.has(Number(name))) continue;
  try {
    const cwd=fs.readlinkSync(path.join(root,name,'cwd'));
    const args=fs.readFileSync(path.join(root,name,'cmdline')).toString().split('\0').filter(Boolean);
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
  "$SYSTEMCTL_BIN" --user disable --now pi-webui.service
  if "$SYSTEMCTL_BIN" --user is-active --quiet pi-webui.service; then
    fail 'Pi Web UI service remained active after disable'
    return 1
  fi
  verify_no_listener
  run_process_check
  validate_unit_shape
  /usr/bin/rm -- "$UNIT_PATH"
  "$SYSTEMCTL_BIN" --user daemon-reload
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
  observed_identity=$("$STAT_BIN" -c '%d:%i' "$CURRENT_RUNTIME")
  [[ -n "$RUNTIME_IDENTITY" && "$observed_identity" == "$RUNTIME_IDENTITY" ]] || {
    fail 'managed runtime identity changed before removal'
    return 1
  }
  /usr/bin/rm -rf -- "$CURRENT_RUNTIME"
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
  source_top=$("$GIT_BIN" -C "$ROOT" rev-parse --show-toplevel)
  validate_state_parent_chain
  validate_worktree
  canonical_contained_target "$WORKTREE" worktrees/dotfiles >/dev/null || return 1
  observed_identity=$("$STAT_BIN" -c '%d:%i' "$WORKTREE")
  observed_head=$("$GIT_BIN" -C "$WORKTREE" rev-parse --verify HEAD)
  observed_git_dir=$(canonical_git_path "$WORKTREE" "$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-dir)")
  [[ -n "$WORKTREE_IDENTITY" && "$observed_identity" == "$WORKTREE_IDENTITY" &&
    "$observed_head" == "$WORKTREE_HEAD" && "$observed_git_dir" == "$WORKTREE_GIT_DIR" ]] || {
    fail 'managed worktree identity changed before removal'
    return 1
  }
  "$GIT_BIN" -C "$source_top" worktree remove "$WORKTREE"
  [[ ! -e "$WORKTREE" && ! -L "$WORKTREE" ]] || {
    fail 'managed worktree removal failed'
    return 1
  }
  if "$GIT_BIN" -C "$source_top" worktree list --porcelain | /usr/bin/grep -Fqx "worktree $WORKTREE"; then
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
    if "$SYSTEMCTL_BIN" --user is-active --quiet pi-webui.service ||
      "$SYSTEMCTL_BIN" --user is-enabled --quiet pi-webui.service; then
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
