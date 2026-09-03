#!/usr/bin/env bash
# Manage the tailnet-only ingress used by the Pi Web UI.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
KEY_URL='https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg'
KEY_SHA256='3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39'
SOURCE_CONTENT='deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main'
SYSTEM_ROOT=''
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

usage() {
  printf 'usage: %s [help|check|install|up|serve|serve-off|uninstall]\n' "$0"
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

configure_test_paths() {
  [[ -z "${PI_WEBUI_TEST_SYSTEM_ROOT:-}" ]] || {
    restricted_test_path "$PI_WEBUI_TEST_SYSTEM_ROOT" PI_WEBUI_TEST_SYSTEM_ROOT
    [[ -d "$PI_WEBUI_TEST_SYSTEM_ROOT" && ! -L "$PI_WEBUI_TEST_SYSTEM_ROOT" ]] || {
      fail 'test system root must be a real directory'
      return 1
    }
    SYSTEM_ROOT=$PI_WEBUI_TEST_SYSTEM_ROOT
    KEY_PATH="$SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
    SOURCE_PATH="$SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list"
  }
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
    fail 'Pi Web UI Tailscale helper requires Ubuntu 24.04 Noble under WSL'
    return 1
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "$1 is required"
    return 1
  }
}

node_command() {
  if command -v node >/dev/null 2>&1; then
    printf '%s\n' node
  elif command -v mise >/dev/null 2>&1; then
    printf '%s\n' mise
  else
    fail 'Node.js is required to validate Tailscale status'
    return 1
  fi
}

run_node() {
  local command_name
  command_name=$(node_command)
  if [[ "$command_name" == node ]]; then
    node "$@"
  else
    mise exec -- node "$@"
  fi
}

require_systemd_daemon() {
  require_command systemctl
  systemctl is-enabled tailscaled.service >/dev/null 2>&1 || {
    fail 'tailscaled.service is not enabled'
    return 1
  }
  systemctl is-active tailscaled.service >/dev/null 2>&1 || {
    fail 'tailscaled.service is not active'
    return 1
  }
}

require_authenticated() {
  local status
  require_command tailscale
  status=$(tailscale status --json)
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
  serve_json=$(tailscale serve status --json)
  funnel_json=$(tailscale funnel status --json)
  human=$(tailscale funnel status)
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

expected_file_owner() {
  if [[ -n "$SYSTEM_ROOT" ]]; then id -u; else printf '0\n'; fi
}

validate_existing_repository_files() {
  local expected_owner
  expected_owner=$(expected_file_owner)
  if [[ -e "$SOURCE_PATH" || -L "$SOURCE_PATH" ]]; then
    [[ -f "$SOURCE_PATH" && ! -L "$SOURCE_PATH" &&
      "$(stat -c '%u' "$SOURCE_PATH")" == "$expected_owner" &&
      "$(stat -c '%a' "$SOURCE_PATH")" == 644 &&
      "$(cat "$SOURCE_PATH")" == "$SOURCE_CONTENT" ]] || {
      fail 'existing Tailscale source is not exact; refusing to overwrite it'
      return 1
    }
  fi
  if [[ -e "$KEY_PATH" || -L "$KEY_PATH" ]]; then
    [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" &&
      "$(stat -c '%u' "$KEY_PATH")" == "$expected_owner" &&
      "$(stat -c '%a' "$KEY_PATH")" == 644 &&
      "$(sha256sum "$KEY_PATH" | cut -d' ' -f1)" == "$KEY_SHA256" ]] || {
      fail 'existing Tailscale key is not exact; refusing to overwrite it'
      return 1
    }
  fi
}

cleanup_install_files() {
  set +e
  if [[ -n "$KEY_ROOT_TEMP" ]]; then sudo rm -f -- "$KEY_ROOT_TEMP" >/dev/null 2>&1; fi
  if [[ -n "$SOURCE_ROOT_TEMP" ]]; then sudo rm -f -- "$SOURCE_ROOT_TEMP" >/dev/null 2>&1; fi
  if [[ -n "$INSTALL_TEMP_DIR" ]]; then rm -rf -- "$INSTALL_TEMP_DIR"; fi
  KEY_ROOT_TEMP=''
  SOURCE_ROOT_TEMP=''
  INSTALL_TEMP_DIR=''
}

publish_repository_file() {
  local source=$1 destination=$2 kind=$3 root_temp
  root_temp=$(sudo mktemp "$(dirname "$destination")/.pi-webui-tailscale-$kind.XXXXXX")
  case "$kind" in
    key) KEY_ROOT_TEMP=$root_temp ;;
    source) SOURCE_ROOT_TEMP=$root_temp ;;
    *)
      fail 'invalid repository-file kind'
      return 1
      ;;
  esac
  sudo install -m 0644 "$source" "$root_temp"
  if ! sudo ln "$root_temp" "$destination"; then
    fail "Tailscale $kind destination appeared during publication; refusing to overwrite it"
    return 1
  fi
  sudo rm -- "$root_temp"
  case "$kind" in
    key) KEY_ROOT_TEMP='' ;;
    source) SOURCE_ROOT_TEMP='' ;;
  esac
}

install_tailscale() {
  local key_temp source_temp digest status
  require_command curl
  require_command sha256sum
  require_command sudo
  require_command systemctl
  systemctl --version >/dev/null 2>&1 || {
    fail 'systemd is unavailable'
    return 1
  }
  validate_existing_repository_files
  INSTALL_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pi-webui-tailscale.XXXXXX")
  chmod 0700 "$INSTALL_TEMP_DIR"
  trap 'status=$?; trap - EXIT; cleanup_install_files; exit "$status"' EXIT
  key_temp="$INSTALL_TEMP_DIR/tailscale-archive-keyring.gpg"
  source_temp="$INSTALL_TEMP_DIR/tailscale.list"
  umask 077
  : >"$key_temp"
  chmod 0600 "$key_temp"
  curl --fail --silent --show-error --location --output "$key_temp" "$KEY_URL"
  [[ -f "$key_temp" && ! -L "$key_temp" && "$(stat -c '%a' "$key_temp")" == 600 ]] || {
    fail 'downloaded Tailscale key is unsafe'
    return 1
  }
  digest=$(sha256sum "$key_temp" | cut -d' ' -f1)
  [[ "$digest" == "$KEY_SHA256" ]] || {
    fail "Tailscale key SHA-256 mismatch: got $digest"
    return 1
  }
  printf '%s\n' "$SOURCE_CONTENT" >"$source_temp"
  chmod 0600 "$source_temp"
  validate_existing_repository_files
  sudo mkdir -p --mode=0755 "$(dirname "$KEY_PATH")"
  sudo mkdir -p --mode=0755 "$(dirname "$SOURCE_PATH")"
  if [[ ! -e "$KEY_PATH" ]]; then publish_repository_file "$key_temp" "$KEY_PATH" key; fi
  validate_existing_repository_files
  if [[ ! -e "$SOURCE_PATH" ]]; then publish_repository_file "$source_temp" "$SOURCE_PATH" source; fi
  validate_existing_repository_files
  sudo apt-get update
  sudo apt-get install tailscale
  sudo systemctl enable --now tailscaled.service
  validate_existing_repository_files
  printf 'ready: Tailscale package and Noble repository are installed\n'
  cleanup_install_files
  trap - EXIT
}

validate_managed_unit() {
  local marker="$CURRENT_RUNTIME/.pi-webui-current"
  [[ -d "$CURRENT_RUNTIME" && ! -L "$CURRENT_RUNTIME" &&
    -f "$marker" && ! -L "$marker" &&
    "$(stat -c '%u' "$CURRENT_RUNTIME")" == "$(id -u)" &&
    "$(cat "$marker")" == pi-webui-task3-current-v1 ]] || {
    fail 'managed Pi Web UI runtime marker is missing or foreign'
    return 1
  }
  bash "$ROOT/bin/validate-pi-webui" --installed-runtime "$CURRENT_RUNTIME" >/dev/null
  [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" &&
    "$(stat -c '%u' "$UNIT_PATH")" == "$(id -u)" &&
    "$(stat -c '%a' "$UNIT_PATH")" == 600 ]] || {
    fail 'managed Pi Web UI unit is unsafe or missing'
    return 1
  }
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
NODE
}

verify_local_service() {
  local health status listener main_pid control_group lan_ip process_root
  validate_managed_unit
  systemctl --user is-active --quiet pi-webui.service || {
    fail 'managed Pi Web UI service is not active'
    return 1
  }
  health=$(curl --fail --silent --show-error http://127.0.0.1:31415/api/health)
  printf '%s' "$health" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const v=JSON.parse(input); if(v.ok!==true || v.webuiVersion!=="0.10.3" || v.piVersion!=="0.84.4") process.exit(1);
});' || {
    fail 'Pi Web UI exact local health failed'
    return 1
  }
  status=$(curl --fail --silent --show-error \
    'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0')
  printf '%s' "$status" | run_node -e '
let input=""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => {
  const v=JSON.parse(input), n=v.data?.network;
  if(v.ok!==true || v.data?.webuiVersion!=="0.10.3" || v.data?.piVersion!=="0.84.4" ||
     n?.host!=="127.0.0.1" || n?.port!==31415 || n?.open!==false || !Array.isArray(n.urls) || n.urls.length) process.exit(1);
});' || {
    fail 'Pi Web UI local network status is not exact'
    return 1
  }
  listener=$(ss -H -ltnp '( sport = :31415 )')
  main_pid=$(systemctl --user show --property=MainPID --value pi-webui.service)
  control_group=$(systemctl --user show --property=ControlGroup --value pi-webui.service)
  process_root=${PI_WEBUI_TEST_PROC_ROOT:-/proc}
  if [[ "$process_root" != /proc ]]; then restricted_test_path "$process_root" PI_WEBUI_TEST_PROC_ROOT; fi
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
  lan_ip=$(ip -4 -o addr show dev eth0 scope global | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')
  [[ -n "$lan_ip" ]] || {
    fail 'cannot determine WSL LAN address'
    return 1
  }
  if curl --connect-timeout 2 --fail --silent "http://$lan_ip:31415/api/health" >/dev/null 2>&1; then
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
  require_systemd_daemon
  require_authenticated
  verify_local_service
  require_safe_route
  if [[ "$ROUTE_STATE" == exact ]]; then
    printf 'ready: exact tailnet-only Pi Web UI route already active\n'
    return 0
  fi
  sudo tailscale serve --bg --https=443 http://127.0.0.1:31415
  require_safe_route
  [[ "$ROUTE_STATE" == exact ]] || {
    fail 'exact Serve route was not established'
    return 1
  }
  printf 'ready: exact tailnet-only Pi Web UI route active\n'
}

serve_off_action() {
  require_systemd_daemon
  require_authenticated
  require_safe_route
  if [[ "$ROUTE_STATE" == empty ]]; then
    printf 'ready: no Tailscale Serve route is configured\n'
    return 0
  fi
  sudo tailscale serve --https=443 off
  require_safe_route
  [[ "$ROUTE_STATE" == empty ]] || {
    fail 'Serve route removal did not produce an empty configuration'
    return 1
  }
  printf 'ready: Pi Web UI Serve route removed\n'
}

uninstall_action() {
  require_command sudo
  require_safe_route
  [[ "$ROUTE_STATE" == empty ]] || {
    fail "remove Serve first with: $0 serve-off"
    return 1
  }
  validate_existing_repository_files
  sudo apt-get remove tailscale
  validate_existing_repository_files
  if [[ -e "$SOURCE_PATH" ]]; then sudo rm -- "$SOURCE_PATH"; fi
  if [[ -e "$KEY_PATH" ]]; then sudo rm -- "$KEY_PATH"; fi
  sudo systemctl daemon-reload
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
  configure_test_paths
  case "$action" in
    check) check_action ;;
    install) install_tailscale ;;
    up)
      require_command sudo
      sudo tailscale up
      ;;
    serve) serve_action ;;
    serve-off) serve_off_action ;;
    uninstall) uninstall_action ;;
  esac
}

main "$@"
