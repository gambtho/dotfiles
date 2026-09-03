#!/usr/bin/bash -p
# Manage the tailnet-only ingress used by the Pi Web UI.

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
IP_BIN='/usr/sbin/ip'
SUDO_BIN='/usr/bin/sudo'
INSTALL_BIN='/usr/bin/install'
APT_GET_BIN='/usr/bin/apt-get'
SHA256SUM_BIN='/usr/bin/sha256sum'
STAT_BIN='/usr/bin/stat'
ID_BIN='/usr/bin/id'
GIT_BIN='/usr/bin/git'
AWK_BIN='/usr/bin/awk'
MISE_SYSTEM_BIN='/usr/bin/mise'
MISE_SYSTEM_OWNER=0
MISE_USER_BIN="$HOME/.local/bin/mise"
TRUST_ANCHOR='/'
OS_RELEASE_FILE='/etc/os-release'
PROC_ROOT='/proc'
REPOSITORY_FILE_OWNER=0

ROOT="$(cd "$(/usr/bin/dirname "$0")/../../.." && pwd -P)"
KEY_URL='https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg'
KEY_SHA256='3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'
SOURCE_CONTENT='deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main'
KEY_PATH='/usr/share/keyrings/tailscale-archive-keyring.gpg'
SOURCE_PATH='/etc/apt/sources.list.d/tailscale.list'
STATE_ROOT="$HOME/.local/share/pi-webui"
CURRENT_RUNTIME="$STATE_ROOT/runtimes/current"
WORKTREE="$STATE_ROOT/worktrees/dotfiles"
SYSTEMD_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_PATH="$SYSTEMD_CONFIG_HOME/systemd/user/pi-webui.service"
ROUTE_STATE=''
INSTALL_TEMP_DIR=''
KEY_ROOT_TEMP=''
SOURCE_ROOT_TEMP=''
TAILSCALE_COMMAND=''
MANAGED_PI_LAUNCHER=''
MISE_BIN=''
MISE_PATH_IDENTITY=''
MISE_TARGET=''
MISE_TARGET_IDENTITY=''
MISE_HASH=''
NODE_BIN=''
NODE_IDENTITY=''
NODE_HASH=''

usage() {
  printf 'usage: %s [help|check|install|up|serve|serve-off|uninstall]\n' "$0"
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
    fail 'Pi Web UI Tailscale helper requires Ubuntu 24.04 Noble under WSL'
    return 1
  fi
}

require_executable() {
  [[ -x "$1" && ! -d "$1" ]] || {
    fail "$2 is required at $1"
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

run_mise_fd() {
  "$BASH_BIN" -p -c 'exec -a mise /proc/self/fd/8 "$@"' _ "$@"
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
  NODE_BIN=$(run_mise_fd which node) || {
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

require_systemd_daemon() {
  require_executable "$SYSTEMCTL_BIN" systemctl || return 1
  "$SYSTEMCTL_BIN" is-enabled tailscaled.service >/dev/null 2>&1 || {
    fail 'tailscaled.service is not enabled'
    return 1
  }
  "$SYSTEMCTL_BIN" is-active tailscaled.service >/dev/null 2>&1 || {
    fail 'tailscaled.service is not active'
    return 1
  }
}

resolve_tailscale_command() {
  [[ -n "$TAILSCALE_COMMAND" ]] && return 0
  TAILSCALE_COMMAND=$TAILSCALE_BIN
  [[ "$TAILSCALE_COMMAND" == /* && -x "$TAILSCALE_COMMAND" ]] || {
    fail 'trusted tailscale executable is invalid'
    return 1
  }
}

require_authenticated() {
  local status
  resolve_tailscale_command || return 1
  status=$("$TAILSCALE_COMMAND" status --json)
  printf '%s' "$status" | run_node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const value = JSON.parse(input);
  if (value.BackendState !== "Running" || value.Self?.Online !== true) process.exit(1);
});
' || {
    fail 'Tailscale is not authenticated and online'
    return 1
  }
}

classify_route() {
  local serve_json funnel_json human
  resolve_tailscale_command
  serve_json=$("$TAILSCALE_COMMAND" serve status --json)
  funnel_json=$("$TAILSCALE_COMMAND" funnel status --json)
  human=$("$TAILSCALE_COMMAND" funnel status)
  ROUTE_STATE=$(SERVE_JSON="$serve_json" FUNNEL_JSON="$funnel_json" SERVE_HUMAN="$human" \
    run_node -e '
function emptyValue(value) {
  if (value == null || value === false) return true;
  if (Array.isArray(value)) return value.length === 0;
  if (typeof value === "object") return Object.keys(value).length === 0;
  return false;
}
function classify(value, human) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "foreign";
  const allow = value.AllowFunnel || {};
  if (Object.values(allow).some(Boolean)) return "funnel";
  const encoded = JSON.stringify(value);
  if (/"(?:Funnel|Public)"\s*:\s*true/i.test(encoded)) return "funnel";
  const tcp = value.TCP || {};
  const web = value.Web || {};
  const tcpKeys = Object.keys(tcp);
  const webKeys = Object.keys(web);
  if (tcpKeys.length === 0 && webKeys.length === 0) {
    for (const [key, candidate] of Object.entries(value)) {
      if (key === "AllowFunnel") {
        if (Object.values(candidate || {}).some(Boolean)) return "funnel";
      } else if (!emptyValue(candidate)) return "foreign";
    }
    return "empty";
  }
  if (tcpKeys.length !== 1 || tcpKeys[0] !== "443") return "foreign";
  const tcp443 = tcp["443"];
  if (!tcp443 || tcp443.HTTPS !== true || Object.keys(tcp443).some(key => key !== "HTTPS")) return "foreign";
  if (webKeys.length !== 1 || !webKeys[0].endsWith(":443")) return "foreign";
  const host = webKeys[0];
  const webEntry = web[host];
  if (!webEntry || Object.keys(webEntry).some(key => key !== "Handlers")) return "foreign";
  const handlers = webEntry.Handlers || {};
  if (Object.keys(handlers).length !== 1 || !handlers["/"]) return "foreign";
  const root = handlers["/"];
  if (root.Proxy !== "http://127.0.0.1:31415" || Object.keys(root).some(key => key !== "Proxy")) return "foreign";
  const allowKeys = Object.keys(allow);
  if (allowKeys.some(key => key !== host || allow[key] !== false)) return "foreign";
  for (const [key, candidate] of Object.entries(value)) {
    if (!["TCP", "Web", "AllowFunnel"].includes(key) && !emptyValue(candidate)) return "foreign";
  }
  if (!human.includes("(tailnet only)") || !human.includes("http://127.0.0.1:31415") || /Funnel on/i.test(human)) {
    return "foreign";
  }
  return "exact";
}
let serve;
let funnel;
try {
  serve = JSON.parse(process.env.SERVE_JSON);
  funnel = JSON.parse(process.env.FUNNEL_JSON);
} catch (_) {
  process.exit(2);
}
const left = classify(serve, process.env.SERVE_HUMAN || "");
const right = classify(funnel, process.env.SERVE_HUMAN || "");
if (left !== right) process.stdout.write("foreign");
else process.stdout.write(left);
') || {
    fail 'cannot parse Tailscale Serve/Funnel status'
    return 1
  }
}

require_safe_route() {
  classify_route
  case "$ROUTE_STATE" in
    empty | exact) ;;
    funnel)
      fail 'Tailscale Funnel is enabled'
      return 1
      ;;
    *)
      fail 'foreign or multiple Serve routes detected'
      return 1
      ;;
  esac
}

validate_existing_repository_files() {
  local expected_owner
  expected_owner=$REPOSITORY_FILE_OWNER
  if [[ -e "$SOURCE_PATH" || -L "$SOURCE_PATH" ]]; then
    [[ -f "$SOURCE_PATH" && ! -L "$SOURCE_PATH" &&
      "$("$STAT_BIN" -c '%u' "$SOURCE_PATH")" == "$expected_owner" &&
      "$("$STAT_BIN" -c '%a' "$SOURCE_PATH")" == 644 &&
      "$(cat "$SOURCE_PATH")" == "$SOURCE_CONTENT" ]] || {
      fail 'existing Tailscale source is not exact; refusing to overwrite it'
      return 1
    }
  fi
  if [[ -e "$KEY_PATH" || -L "$KEY_PATH" ]]; then
    [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" &&
      "$("$STAT_BIN" -c '%u' "$KEY_PATH")" == "$expected_owner" &&
      "$("$STAT_BIN" -c '%a' "$KEY_PATH")" == 644 &&
      "$("$SHA256SUM_BIN" "$KEY_PATH" | /usr/bin/cut -d' ' -f1)" == "$KEY_SHA256" ]] || {
      fail 'existing Tailscale key is not exact; refusing to overwrite it'
      return 1
    }
  fi
}

cleanup_install_files() {
  local sudo_command rm_command
  set +e
  sudo_command=$SUDO_BIN
  rm_command=/usr/bin/rm
  if [[ -n "$KEY_ROOT_TEMP" ]]; then "$sudo_command" "$rm_command" -f -- "$KEY_ROOT_TEMP" >/dev/null 2>&1; fi
  if [[ -n "$SOURCE_ROOT_TEMP" ]]; then "$sudo_command" "$rm_command" -f -- "$SOURCE_ROOT_TEMP" >/dev/null 2>&1; fi
  if [[ -n "$INSTALL_TEMP_DIR" ]]; then /usr/bin/rm -rf -- "$INSTALL_TEMP_DIR"; fi
  KEY_ROOT_TEMP=''
  SOURCE_ROOT_TEMP=''
  INSTALL_TEMP_DIR=''
}

publish_repository_file() {
  local source=$1 destination=$2 kind=$3 root_temp sudo_command
  sudo_command=$SUDO_BIN
  root_temp=$("$sudo_command" /usr/bin/mktemp "$(/usr/bin/dirname "$destination")/.pi-webui-tailscale-$kind.XXXXXX")
  case "$kind" in
    key) KEY_ROOT_TEMP=$root_temp ;;
    source) SOURCE_ROOT_TEMP=$root_temp ;;
    *)
      fail 'invalid repository-file kind'
      return 1
      ;;
  esac
  "$sudo_command" "$INSTALL_BIN" -m 0644 "$source" "$root_temp"
  if ! "$sudo_command" /usr/bin/ln "$root_temp" "$destination"; then
    fail "Tailscale $kind destination appeared during publication; refusing to overwrite it"
    return 1
  fi
  "$sudo_command" /usr/bin/rm -- "$root_temp"
  case "$kind" in
    key) KEY_ROOT_TEMP='' ;;
    source) SOURCE_ROOT_TEMP='' ;;
  esac
}

install_tailscale() {
  local key_temp source_temp digest status sudo_command apt_get_command systemctl_command
  require_executable "$CURL_BIN" curl
  require_executable "$SHA256SUM_BIN" sha256sum
  require_executable "$SUDO_BIN" sudo
  require_executable "$SYSTEMCTL_BIN" systemctl
  require_executable "$INSTALL_BIN" install
  require_executable "$APT_GET_BIN" apt-get
  sudo_command=$SUDO_BIN
  apt_get_command=$APT_GET_BIN
  systemctl_command=$SYSTEMCTL_BIN
  "$SYSTEMCTL_BIN" --version >/dev/null 2>&1 || {
    fail 'systemd is unavailable'
    return 1
  }
  validate_existing_repository_files
  INSTALL_TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pi-webui-tailscale.XXXXXX")
  /usr/bin/chmod 0700 "$INSTALL_TEMP_DIR"
  trap 'status=$?; trap - EXIT; cleanup_install_files; exit "$status"' EXIT
  key_temp="$INSTALL_TEMP_DIR/tailscale-archive-keyring.gpg"
  source_temp="$INSTALL_TEMP_DIR/tailscale.list"
  umask 077
  : >"$key_temp"
  /usr/bin/chmod 0600 "$key_temp"
  "$CURL_BIN" --fail --silent --show-error --location --output "$key_temp" "$KEY_URL"
  [[ -f "$key_temp" && ! -L "$key_temp" && "$("$STAT_BIN" -c '%a' "$key_temp")" == 600 ]] || {
    fail 'downloaded Tailscale key is unsafe'
    return 1
  }
  digest=$("$SHA256SUM_BIN" "$key_temp" | /usr/bin/cut -d' ' -f1)
  [[ "$digest" == "$KEY_SHA256" ]] || {
    fail "Tailscale key SHA-256 mismatch: got $digest"
    return 1
  }
  printf '%s\n' "$SOURCE_CONTENT" >"$source_temp"
  /usr/bin/chmod 0600 "$source_temp"
  validate_existing_repository_files
  "$sudo_command" /usr/bin/mkdir -p --mode=0755 "$(/usr/bin/dirname "$KEY_PATH")"
  "$sudo_command" /usr/bin/mkdir -p --mode=0755 "$(/usr/bin/dirname "$SOURCE_PATH")"
  if [[ ! -e "$KEY_PATH" ]]; then publish_repository_file "$key_temp" "$KEY_PATH" key; fi
  validate_existing_repository_files
  if [[ ! -e "$SOURCE_PATH" ]]; then publish_repository_file "$source_temp" "$SOURCE_PATH" source; fi
  validate_existing_repository_files
  "$sudo_command" "$apt_get_command" update
  "$sudo_command" "$apt_get_command" install tailscale
  "$sudo_command" "$systemctl_command" enable --now tailscaled.service
  validate_existing_repository_files
  printf 'ready: Tailscale package and Noble repository are installed\n'
  cleanup_install_files
  trap - EXIT
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

canonical_git_path() {
  local checkout=$1 value=$2 parent base
  case "$value" in /*) ;; *) value="$checkout/$value" ;; esac
  if [[ -d "$value" ]]; then
    (cd "$value" && pwd -P)
  else
    parent=$(cd "$(dirname "$value")" && pwd -P) || return 1
    base=$(basename "$value")
    printf '%s/%s\n' "$parent" "$base"
  fi
}

require_empty_git_output() {
  local message=$1 temporary status=0
  shift
  temporary=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/pi-webui-git.XXXXXXXX") || return 1
  /usr/bin/chmod 0600 "$temporary"
  "$GIT_BIN" "$@" >"$temporary" || status=$?
  if [[ "$status" != 0 ]]; then
    /usr/bin/rm -f "$temporary"
    fail 'cannot inspect managed worktree Git state'
    return 1
  fi
  if [[ -s "$temporary" ]]; then
    /usr/bin/rm -f "$temporary"
    fail "$message"
    return 1
  fi
  /usr/bin/rm -f "$temporary"
}

require_empty_find_output() {
  local message=$1 temporary status=0
  shift
  temporary=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/pi-webui-find.XXXXXXXX") || return 1
  /usr/bin/chmod 0600 "$temporary"
  /usr/bin/find -P "$@" >"$temporary" || status=$?
  if [[ "$status" != 0 ]]; then
    /usr/bin/rm -f "$temporary"
    fail 'cannot enumerate managed Pi directories'
    return 1
  fi
  if [[ -s "$temporary" ]]; then
    /usr/bin/rm -f "$temporary"
    fail "$message"
    return 1
  fi
  /usr/bin/rm -f "$temporary"
}

validate_managed_plan_tree() {
  local pi_root="$WORKTREE/.pi" plans_root="$WORKTREE/.pi/plans"
  local current_uid canonical_worktree canonical_pi canonical_plans
  [[ -e "$pi_root" || -L "$pi_root" ]] || return 0
  [[ -d "$pi_root" && ! -L "$pi_root" && -d "$plans_root" && ! -L "$plans_root" ]] || {
    fail 'managed Pi state must be the exact empty .pi/plans directory tree'
    return 1
  }
  current_uid=$("$ID_BIN" -u)
  [[ "$("$STAT_BIN" -c '%u' "$pi_root")" == "$current_uid" &&
  "$("$STAT_BIN" -c '%u' "$plans_root")" == "$current_uid" &&
  "$("$STAT_BIN" -c '%a' "$pi_root")" == 700 &&
  "$("$STAT_BIN" -c '%a' "$plans_root")" == 700 ]] || {
    fail 'managed Pi directories must be owner-only mode 0700'
    return 1
  }
  canonical_worktree=$(cd "$WORKTREE" && pwd -P) || return 1
  canonical_pi=$(cd "$pi_root" && pwd -P) || return 1
  canonical_plans=$(cd "$plans_root" && pwd -P) || return 1
  [[ "$canonical_pi" == "$canonical_worktree/.pi" &&
    "$canonical_plans" == "$canonical_pi/plans" ]] || {
    fail 'managed Pi directories escape the worktree'
    return 1
  }
  require_empty_find_output 'managed Pi directory contains unsupported state' \
    "$pi_root" -mindepth 1 -maxdepth 1 ! -path "$plans_root" -print -quit || return 1
  require_empty_find_output 'managed Pi plans directory must be empty' \
    "$plans_root" -mindepth 1 -print -quit
}

validate_managed_worktree() {
  local mode source_top source_common target_common target_git raw
  [[ -d "$WORKTREE" && ! -L "$WORKTREE" && "$("$STAT_BIN" -c '%u' "$WORKTREE")" == "$("$ID_BIN" -u)" ]] || {
    fail 'managed Pi Web UI worktree is unsafe or foreign'
    return 1
  }
  mode=$("$STAT_BIN" -c '%a' "$WORKTREE")
  (((8#$mode & 022) == 0)) || {
    fail 'managed Pi Web UI worktree must not be group or world writable'
    return 1
  }
  source_top=$("$GIT_BIN" -C "$ROOT" rev-parse --show-toplevel)
  raw=$("$GIT_BIN" -C "$source_top" rev-parse --git-common-dir)
  source_common=$(canonical_git_path "$source_top" "$raw")
  "$GIT_BIN" -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    fail 'managed Pi Web UI worktree belongs to a foreign repository'
    return 1
  }
  raw=$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-common-dir)
  target_common=$(canonical_git_path "$WORKTREE" "$raw")
  raw=$("$GIT_BIN" -C "$WORKTREE" rev-parse --git-dir)
  target_git=$(canonical_git_path "$WORKTREE" "$raw")
  [[ "$target_common" == "$source_common" && "$target_git" != "$target_common" ]] || {
    fail 'managed Pi Web UI worktree belongs to a foreign or primary repository'
    return 1
  }
  ! "$GIT_BIN" -C "$WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1 || {
    fail 'managed Pi Web UI worktree must be detached'
    return 1
  }
  require_empty_git_output 'managed Pi Web UI worktree must be clean, including ignored files' \
    -C "$WORKTREE" status --porcelain=v1 -z --untracked-files=all
  require_empty_git_output 'ignored files are not permitted in the managed worktree' \
    -C "$WORKTREE" ls-files --others -i --exclude-standard -z
  require_empty_git_output 'current worktree commit tracks .pi' \
    -C "$WORKTREE" ls-tree -r --name-only -z HEAD -- .pi
  validate_managed_plan_tree
}

validate_pi_launcher() {
  run_node - "$MANAGED_PI_LAUNCHER" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const launcher = process.argv[2];
if (!path.isAbsolute(launcher)) process.exit(1);
const real = fs.realpathSync(launcher);
let current = path.dirname(real);
while (true) {
  const manifestPath = path.join(current, 'package.json');
  if (fs.existsSync(manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (manifest.name === '@earendil-works/pi-coding-agent') {
      if (manifest.version !== '0.84.4' || typeof manifest.bin?.pi !== 'string' ||
          fs.realpathSync(path.resolve(current, manifest.bin.pi)) !== real) process.exit(1);
      process.exit(0);
    }
  }
  const parent = path.dirname(current);
  if (parent === current) process.exit(1);
  current = parent;
}
NODE
}

validate_managed_unit() {
  local marker="$CURRENT_RUNTIME/.pi-webui-current"
  validate_state_parent_chain
  [[ -d "$CURRENT_RUNTIME" && ! -L "$CURRENT_RUNTIME" &&
    -f "$marker" && ! -L "$marker" &&
    "$("$STAT_BIN" -c '%u' "$CURRENT_RUNTIME")" == "$("$ID_BIN" -u)" &&
    "$("$STAT_BIN" -c '%a' "$CURRENT_RUNTIME")" == 700 &&
    "$(cat "$marker")" == pi-webui-task3-current-v1 ]] || {
    fail 'managed Pi Web UI runtime marker, ownership, or mode is unsafe'
    return 1
  }
  validate_installed_runtime
  validate_managed_worktree
  [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" &&
    "$("$STAT_BIN" -c '%u' "$UNIT_PATH")" == "$("$ID_BIN" -u)" &&
    "$("$STAT_BIN" -c '%a' "$UNIT_PATH")" == 600 ]] || {
    fail 'managed Pi Web UI unit is unsafe or missing'
    return 1
  }
  MANAGED_PI_LAUNCHER=$(
    run_node - "$ROOT/ai/pi/webui/pi-webui.service.in" "$UNIT_PATH" \
      "$CURRENT_RUNTIME/node_modules/.bin/pi-webui" "$WORKTREE" <<'NODE'
const fs = require('node:fs');
const [templatePath, unitPath, runtime, worktree] = process.argv.slice(2);
const unit = fs.readFileSync(unitPath, 'utf8');
const match = unit.match(/ --pi "([^"\n]+)" --no-remote-auth /);
if (!match || !match[1].startsWith('/')) process.exit(1);
let expected = fs.readFileSync(templatePath, 'utf8');
expected = expected.replace('@RUNTIME_LAUNCHER@', JSON.stringify(runtime));
expected = expected.replace('@WORKTREE@', JSON.stringify(worktree));
expected = expected.replace('@PI_LAUNCHER@', JSON.stringify(match[1]));
if (unit !== expected || /@[A-Z][A-Z0-9_]*@/.test(expected)) process.exit(1);
process.stdout.write(match[1]);
NODE
  ) || {
    fail 'managed Pi Web UI unit is foreign'
    return 1
  }
  validate_pi_launcher || {
    fail 'managed Pi Web UI Pi launcher identity is foreign'
    return 1
  }
}

verify_local_service() {
  local health status listener main_pid control_group lan_ip process_root
  validate_managed_unit
  "$SYSTEMCTL_BIN" --user is-active --quiet pi-webui.service || {
    fail 'managed Pi Web UI service is not active'
    return 1
  }
  health=$("$CURL_BIN" --fail --silent --show-error http://127.0.0.1:31415/api/health)
  printf '%s' "$health" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const v=JSON.parse(input); if(v.ok!==true || v.webuiVersion!=="0.10.3" || v.piVersion!=="0.84.4") process.exit(1);
});' || {
    fail 'Pi Web UI exact local health failed'
    return 1
  }
  status=$("$CURL_BIN" --fail --silent --show-error \
    'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0')
  # shellcheck disable=SC2016 # JavaScript template literal, not shell expansion.
  printf '%s' "$status" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const [worktree, launcher] = process.argv.slice(1), rpcCommand=`${launcher} --mode rpc`;
  const v=JSON.parse(input), n=v.data?.network, tabs=v.data?.tabs;
  if(v.ok!==true || v.data?.webuiVersion!=="0.10.3" || v.data?.piVersion!=="0.84.4" ||
     n?.host!=="127.0.0.1" || n?.port!==31415 || n?.open!==false ||
     Object.prototype.hasOwnProperty.call(n, "urls") ||
     !Array.isArray(n.networkUrls) || n.networkUrls.length ||
     !Array.isArray(tabs) || tabs.length<1 || tabs.some(tab => tab.cwd!==worktree || tab.running!==true ||
       typeof tab.command!=="string" || !(tab.command===rpcCommand ||
         (tab.command.startsWith(rpcCommand) && /\s/.test(tab.command[rpcCommand.length]))))) process.exit(1);
});' "$WORKTREE" "$MANAGED_PI_LAUNCHER" || {
    fail 'Pi Web UI local network status is not exact'
    return 1
  }
  listener=$("$SS_BIN" -H -ltnp '( sport = :31415 )')
  main_pid=$("$SYSTEMCTL_BIN" --user show --property=MainPID --value pi-webui.service)
  control_group=$("$SYSTEMCTL_BIN" --user show --property=ControlGroup --value pi-webui.service)
  process_root=$PROC_ROOT
  LISTENER="$listener" run_node - "$process_root" "$main_pid" "$control_group" <<'NODE'
const fs=require('node:fs'), path=require('node:path');
const [root, mainText, cgroup]=process.argv.slice(2), line=process.env.LISTENER || '';
const lines=line.split('\n').filter(Boolean);
if(lines.length!==1 || !/^LISTEN\s+\S+\s+\S+\s+127\.0\.0\.1:31415\s/.test(lines[0])) process.exit(1);
const match=lines[0].match(/pid=(\d+)/); if(!match) process.exit(1);
let pid=Number(match[1]), main=Number(mainText), owned=false, seen=new Set();
for(let depth=0; depth<256 && pid>0 && !seen.has(pid); depth++) {
  seen.add(pid); if(pid===main) owned=true;
  const cg=fs.readFileSync(path.join(root,String(pid),'cgroup'),'utf8').split('\n').map(x=>x.split(':').slice(2).join(':'));
  if(cgroup.startsWith('/') && cg.includes(cgroup)) owned=true;
  const status=fs.readFileSync(path.join(root,String(pid),'status'),'utf8');
  const parent=status.match(/^PPid:\s*(\d+)$/m); if(!parent) process.exit(1);
  if(owned) break; pid=Number(parent[1]);
}
if(!owned) process.exit(1);
NODE
  # shellcheck disable=SC2016 # awk field references are not shell expansions.
  lan_ip=$("$IP_BIN" -4 -o addr show dev eth0 scope global | "$AWK_BIN" 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')
  [[ -n "$lan_ip" ]] || {
    fail 'cannot determine WSL LAN address'
    return 1
  }
  if "$CURL_BIN" --connect-timeout 2 --fail --silent "http://$lan_ip:31415/api/health" >/dev/null 2>&1; then
    fail 'Pi Web UI is reachable directly from the WSL LAN address'
    return 1
  fi
}

check_action() {
  require_systemd_daemon
  require_authenticated
  require_safe_route
  printf 'ready: Tailscale authenticated; route=%s\n' \
    "$(if [[ "$ROUTE_STATE" == exact ]]; then printf exact-tailnet-only; else printf empty; fi)"
}

serve_action() {
  local sudo_command
  require_systemd_daemon
  require_authenticated
  verify_local_service
  require_safe_route
  if [[ "$ROUTE_STATE" == exact ]]; then
    printf 'ready: exact tailnet-only Pi Web UI route already active\n'
    return 0
  fi
  sudo_command=$SUDO_BIN
  "$sudo_command" "$TAILSCALE_COMMAND" serve --bg --https=443 http://127.0.0.1:31415
  require_safe_route
  [[ "$ROUTE_STATE" == exact ]] || {
    fail 'exact Serve route was not established'
    return 1
  }
  printf 'ready: exact tailnet-only Pi Web UI route active\n'
}

serve_off_action() {
  local sudo_command
  require_systemd_daemon
  require_authenticated
  require_safe_route
  if [[ "$ROUTE_STATE" == empty ]]; then
    printf 'ready: no Tailscale Serve route is configured\n'
    return 0
  fi
  sudo_command=$SUDO_BIN
  "$sudo_command" "$TAILSCALE_COMMAND" serve --https=443 off
  require_safe_route
  [[ "$ROUTE_STATE" == empty ]] || {
    fail 'Serve route removal did not produce an empty configuration'
    return 1
  }
  printf 'ready: Pi Web UI Serve route removed\n'
}

uninstall_action() {
  local sudo_command apt_get_command systemctl_command rm_command
  require_executable "$SUDO_BIN" sudo
  sudo_command=$SUDO_BIN
  apt_get_command=$APT_GET_BIN
  systemctl_command=$SYSTEMCTL_BIN
  rm_command=/usr/bin/rm
  require_safe_route
  [[ "$ROUTE_STATE" == empty ]] || {
    fail "remove Serve first with: $0 serve-off"
    return 1
  }
  validate_existing_repository_files
  "$sudo_command" "$apt_get_command" remove tailscale
  validate_existing_repository_files
  if [[ -e "$SOURCE_PATH" ]]; then "$sudo_command" "$rm_command" -- "$SOURCE_PATH"; fi
  if [[ -e "$KEY_PATH" ]]; then "$sudo_command" "$rm_command" -- "$KEY_PATH"; fi
  "$sudo_command" "$systemctl_command" daemon-reload
  printf 'ready: Tailscale package removed; Tailscale identity state preserved\n'
}

main() {
  local action=${1:-help}
  [[ $# -le 1 ]] || {
    usage >&2
    return 2
  }
  case "$action" in
    help | -h | --help)
      usage
      return 0
      ;;
    check | install | up | serve | serve-off | uninstall) ;;
    *)
      usage >&2
      return 2
      ;;
  esac
  require_supported_platform
  case "$action" in
    check) check_action ;;
    install) install_tailscale ;;
    up)
      require_executable "$SUDO_BIN" sudo
      resolve_tailscale_command
      "$SUDO_BIN" "$TAILSCALE_COMMAND" up
      ;;
    serve) serve_action ;;
    serve-off) serve_off_action ;;
    uninstall) uninstall_action ;;
  esac
}

main "$@"
