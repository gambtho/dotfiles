#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

ACCEPTED_MANIFEST_SHA256=073ba87cad124eb709eb8cafdd77c44c10b5d12bf5841acea140a50ac5177763
ACCEPTED_LOCK_SHA256=39593de061e22a36668a0a0d1449e339b84e644d6c65e6b1618af9d177fc71d0

setup() {
  setup_dotfiles_test
  unset PI_WEBUI_TEST_STATUS_JSON PI_WEBUI_TEST_HEALTH_ATTEMPTS
  unset TEST_BEFORE_LOCK_HOOK TEST_AFTER_NPM_HOOK TEST_BEFORE_TRIAL_STAGE_HOOK
  FIXTURE_RUNTIME="$TEST_ROOT/runtime"
  mkdir -p "$FIXTURE_RUNTIME"
}

make_runtime_fixture() {
  cp "$REPO_ROOT/ai/pi/webui/runtime/package.json" "$FIXTURE_RUNTIME/package.json"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package-lock.json" "$FIXTURE_RUNTIME/package-lock.json"
}

make_installed_fixture() {
  make_runtime_fixture
  mkdir -p \
    "$FIXTURE_RUNTIME/node_modules/@firstpick/pi-package-webui/bin" \
    "$FIXTURE_RUNTIME/node_modules/@earendil-works/pi-coding-agent/dist/bundle"
  printf '%s\n' \
    '{"name":"@firstpick/pi-package-webui","version":"0.10.3","bin":{"pi-webui":"./bin/pi-webui-launcher.mjs"}}' \
    >"$FIXTURE_RUNTIME/node_modules/@firstpick/pi-package-webui/package.json"
  : >"$FIXTURE_RUNTIME/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$FIXTURE_RUNTIME/node_modules/@earendil-works/pi-coding-agent/package.json"
  : >"$FIXTURE_RUNTIME/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
}

make_valid_platform() {
  TEST_OS_RELEASE="$TEST_ROOT/os-release"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$TEST_OS_RELEASE"
  export TEST_OS_RELEASE
  stub_command uname 'printf "%s\\n" "6.6.87.2-microsoft-standard-WSL2"'
  cat >"$STUB_BIN/stat" <<'SCRIPT'
#!/usr/bin/env bash
exec /usr/bin/stat "$@"
SCRIPT
  chmod +x "$STUB_BIN/stat"
  PROC_ROOT="$TEST_ROOT/proc"
  mkdir -p "$PROC_ROOT/4200" "$PROC_ROOT/4201"
  printf '%b\n' 'Name:\tmise' 'PPid:\t1' >"$PROC_ROOT/4200/status"
  printf '%s\n' '4200 (mise) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100' >"$PROC_ROOT/4200/stat"
  printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/pi-webui.service' \
    >"$PROC_ROOT/4200/cgroup"
  printf '%b\n' 'Name:\tnode' 'PPid:\t4200' >"$PROC_ROOT/4201/status"
  printf '%s\n' '4201 (node wrapper child) S 4200 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 101' \
    >"$PROC_ROOT/4201/stat"
  printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/pi-webui.service' \
    >"$PROC_ROOT/4201/cgroup"
  export PROC_ROOT
  cat >"$STUB_BIN/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'systemctl %s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$1" == --version ]]; then
  printf '%s\n' 'systemd 255'
  exit 0
fi
if [[ "$1" != --user ]]; then
  case "$1" in
    is-active) [[ "$2" == tailscaled.service && -f "$TEST_ROOT/tailscaled-active" ]] ;;
    is-enabled) [[ "$2" == tailscaled.service && -f "$TEST_ROOT/tailscaled-enabled" ]] ;;
    enable)
      [[ "$2" == --now && "$3" == tailscaled.service ]]
      : >"$TEST_ROOT/tailscaled-active"
      : >"$TEST_ROOT/tailscaled-enabled"
      ;;
    daemon-reload) exit 0 ;;
    *) printf 'unexpected system systemctl: %s\n' "$*" >&2; exit 89 ;;
  esac
  exit
fi
shift
case "$1" in
  show-environment) exit 0 ;;
  show)
    case "$*" in
      *--property=FragmentPath*)
        if [[ -f "$TEST_ROOT/fragment-path" ]]; then cat "$TEST_ROOT/fragment-path"; fi
        ;;
      *--property=MainPID*) printf '%s\n' 4200 ;;
      *--property=ControlGroup*)
        printf '%s\n' '/user.slice/user-1000.slice/user@1000.service/app.slice/pi-webui.service'
        ;;
    esac
    ;;
  is-active) [[ -f "$TEST_ROOT/service-active" ]] ;;
  is-enabled) [[ -f "$TEST_ROOT/service-enabled" ]] ;;
  daemon-reload) exit 0 ;;
  stop) rm -f "$TEST_ROOT/service-active" ;;
  start)
    if [[ -f "$TEST_ROOT/health-observed" ]] &&
      grep -Fq -- 'pi-webui-runtime/node_modules/.bin/pi-webui' \
        "$HOME/.config/systemd/user/pi-webui.service" 2>/dev/null; then
      [[ -d "$HOME/.local/share/pi-webui-runtime" ]] || exit 67
      : >"$TEST_ROOT/trial-runtime-restored-before-start"
    fi
    if [[ -f "$TEST_ROOT/fail-rollback-start" && -f "$TEST_ROOT/health-observed" ]]; then
      exit 66
    fi
    if [[ -f "$TEST_ROOT/rollback-start-inactive" && -f "$TEST_ROOT/health-observed" ]]; then
      exit 0
    fi
    : >"$TEST_ROOT/service-active"
    ;;
  enable)
    : >"$TEST_ROOT/service-enabled"
    if [[ " $* " == *" --now "* ]]; then : >"$TEST_ROOT/service-active"; fi
    ;;
  disable)
    rm -f "$TEST_ROOT/service-enabled"
    if [[ " $* " == *" --now "* ]]; then rm -f "$TEST_ROOT/service-active"; fi
    ;;
  *) printf 'unexpected systemctl: %s\n' "$*" >&2; exit 90 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/systemctl"
  stub_command systemd-analyze '
printf "systemd-analyze %s\\n" "$*" >>"$TEST_COMMAND_LOG"
[[ "$1 ${2:-}" == "--user verify" ]]
[[ "$3" == *.service ]]
[[ "$(stat -c "%a" "$3")" == 600 ]]
[[ ! -f "$TEST_ROOT/fail-unit-verify" ]]'
  stub_command curl '
printf "curl %s\\n" "$*" >>"$TEST_COMMAND_LOG"
case "$*" in
  *api/health*)
    if [[ -f "$TEST_ROOT/health-fail" ]]; then
      if [[ -f "$TEST_ROOT/expect-trial-runtime-moved" ]]; then
        [[ ! -e "$HOME/.local/share/pi-webui-runtime" ]] || exit 95
        : >"$TEST_ROOT/trial-runtime-move-observed"
      fi
      : >"$TEST_ROOT/health-observed"
      rm -f "$TEST_ROOT/health-fail"
      printf "%s\\n" '\''{"ok":false,"webuiVersion":"0.10.3","piVersion":"0.84.4"}'\''
      exit 0
    fi
    printf "%s\\n" '\''{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4"}'\''
    ;;
  *api/webui-status*)
    if [[ -n "${PI_WEBUI_TEST_STATUS_JSON:-}" ]]; then
      printf "%s\\n" "$PI_WEBUI_TEST_STATUS_JSON"
    else
      status_cwd="$HOME/.local/share/pi-webui/worktrees/dotfiles"
      status_launcher="$PI_TEST_LAUNCHER"
      if grep -Fq -- 'pi-webui-runtime/node_modules/.bin/pi-webui' \
        "$HOME/.config/systemd/user/pi-webui.service" 2>/dev/null; then
        status_cwd='/home/tng/.dotfiles/tmp/worktrees/piface-smoke'
        status_launcher="$HOME/.local/share/mise/installs/node/26.5.0/bin/pi"
      fi
      printf '\''{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc"}]}}'\'' \
        "$status_cwd" "$status_launcher"
    fi
    ;;
  *api/shutdown*) printf "%s\\n" '\''{"ok":true}'\'' ;;
  *) exit 94 ;;
esac'
  stub_command ss '
printf "ss %s\\n" "$*" >>"$TEST_COMMAND_LOG"
if [[ -f "$TEST_ROOT/service-active" ]]; then
  if [[ -f "$TEST_ROOT/wildcard-listener" ]]; then
    printf "%s\\n" "LISTEN 0 511 0.0.0.0:31415 0.0.0.0:* users:((\"node\",pid=4201,fd=20))"
  elif [[ -f "$TEST_ROOT/spoof-listener" ]]; then
    printf "%s\\n" "LISTEN 0 511 127.0.0.1:31415 0.0.0.0:* users:((\"foreign\",pid=7331,fd=9))"
  else
    printf "%s\\n" "LISTEN 0 511 127.0.0.1:31415 0.0.0.0:* users:((\"node\",pid=4201,fd=20))"
  fi
fi'
  PROCESS_CHECK="$TEST_ROOT/process-check"
  cat >"$PROCESS_CHECK" <<'SCRIPT'
#!/usr/bin/env bash
printf 'process-check %s\n' "$*" >>"$TEST_COMMAND_LOG"
exit 0
SCRIPT
  chmod +x "$PROCESS_CHECK"
  export PROCESS_CHECK
}

make_valid_pi() {
  PI_TEST_PACKAGE="$TEST_ROOT/mise installs/node/lib/node_modules/@earendil-works/pi-coding-agent"
  PI_TEST_REAL="$PI_TEST_PACKAGE/dist/bundle/cli.js"
  PI_TEST_LAUNCHER="$TEST_ROOT/mise installs/node/bin/pi"
  mkdir -p "$(dirname "$PI_TEST_REAL")" "$(dirname "$PI_TEST_LAUNCHER")"
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"
  printf '#!/usr/bin/env node\n' >"$PI_TEST_REAL"
  chmod +x "$PI_TEST_REAL"
  ln -s "../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
    "$PI_TEST_LAUNCHER"
  NODE_TEST_BIN="$HOME/.local/share/mise/installs/node/26.5.0/bin/node"
  mkdir -p "$(dirname "$NODE_TEST_BIN")"
  local real_node
  real_node=$(node -p 'process.execPath')
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_node" >"$NODE_TEST_BIN"
  chmod +x "$NODE_TEST_BIN"
  export PI_TEST_PACKAGE PI_TEST_REAL PI_TEST_LAUNCHER NODE_TEST_BIN
  cat >"$STUB_BIN/mise" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'mise %s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$1 ${2:-}" == "which pi" ]]; then
  printf '%s\n' "$PI_TEST_LAUNCHER"
  exit 0
fi
if [[ "$1 ${2:-}" == "which node" ]]; then
  printf '%s\n' "$NODE_TEST_BIN"
  exit 0
fi
if [[ "$1 ${2:-}" == "exec --" ]]; then
  shift 2
  exec "$@"
fi
printf 'unexpected mise invocation: %s\n' "$*" >&2
exit 91
SCRIPT
  chmod +x "$STUB_BIN/mise"
  stub_command npm '
if [[ "${1:-}" == --version ]]; then
  printf "%s\\n" "11.6.2"
  exit 0
fi
printf "unexpected npm invocation before apply fixture: %s\\n" "$*" >&2
exit 92'
}

patch_webui_helper_constants() {
  local helper=$1
  node - "$helper" "$STUB_BIN" "$TEST_ROOT" "$(id -u)" <<'NODE'
const fs = require('node:fs');
const [file, bin, root, uid] = process.argv.slice(2);
let source = fs.readFileSync(file, 'utf8');
const replacements = new Map([
  ["TRUST_ANCHOR='/'", `TRUST_ANCHOR='${root}'`],
  ["OS_RELEASE_FILE='/etc/os-release'", `OS_RELEASE_FILE='${root}/os-release'`],
  ["KEY_PATH='/usr/share/keyrings/tailscale-archive-keyring.gpg'", `KEY_PATH='${root}/system-root/usr/share/keyrings/tailscale-archive-keyring.gpg'`],
  ["SOURCE_PATH='/etc/apt/sources.list.d/tailscale.list'", `SOURCE_PATH='${root}/system-root/etc/apt/sources.list.d/tailscale.list'`],
  ["PROC_ROOT='/proc'", `PROC_ROOT='${root}/proc'`],
  ["PROCESS_CHECK_HOOK=''", `PROCESS_CHECK_HOOK='${root}/process-check'`],
  ["UNAME_BIN='/usr/bin/uname'", `UNAME_BIN='${bin}/uname'`],
  ["SYSTEMCTL_BIN='/usr/bin/systemctl'", `SYSTEMCTL_BIN='${bin}/systemctl'`],
  ["TAILSCALE_BIN='/usr/bin/tailscale'", `TAILSCALE_BIN='${bin}/tailscale'`],
  ["CURL_BIN='/usr/bin/curl'", `CURL_BIN='${bin}/curl'`],
  ["SS_BIN='/usr/bin/ss'", `SS_BIN='${bin}/ss'`],
  ["IP_BIN='/usr/sbin/ip'", `IP_BIN='${bin}/ip'`],
  ["SUDO_BIN='/usr/bin/sudo'", `SUDO_BIN='${bin}/sudo'`],
  ["SHA256SUM_BIN='/usr/bin/sha256sum'", `SHA256SUM_BIN='${bin}/sha256sum'`],
  ["STAT_BIN='/usr/bin/stat'", `STAT_BIN='${bin}/stat'`],
  ["MISE_SYSTEM_BIN='/usr/bin/mise'", `MISE_SYSTEM_BIN='${bin}/mise'`],
  ["MISE_SYSTEM_OWNER=0", `MISE_SYSTEM_OWNER=${uid}`],
  ["REPOSITORY_FILE_OWNER=0", `REPOSITORY_FILE_OWNER=${uid}`],
]);
for (const [from, to] of replacements) {
  if (source.includes(from)) source = source.replace(from, to);
}
fs.writeFileSync(file, source);
NODE
}

make_installer_repo() {
  INSTALLER_REPO="$TEST_ROOT/source repo"
  mkdir -p "$INSTALLER_REPO/ai/pi/webui/runtime" "$INSTALLER_REPO/bin"
  cp "$REPO_ROOT/ai/pi/webui/install.sh" "$INSTALLER_REPO/ai/pi/webui/install.sh"
  if [[ -f "$REPO_ROOT/ai/pi/webui/tailscale.sh" ]]; then
    cp "$REPO_ROOT/ai/pi/webui/tailscale.sh" "$INSTALLER_REPO/ai/pi/webui/tailscale.sh"
  fi
  if [[ -f "$REPO_ROOT/ai/pi/webui/rollback.sh" ]]; then
    cp "$REPO_ROOT/ai/pi/webui/rollback.sh" "$INSTALLER_REPO/ai/pi/webui/rollback.sh"
  fi
  if [[ -f "$INSTALLER_REPO/ai/pi/webui/tailscale.sh" ]]; then
    patch_webui_helper_constants "$INSTALLER_REPO/ai/pi/webui/tailscale.sh"
  fi
  if [[ -f "$INSTALLER_REPO/ai/pi/webui/rollback.sh" ]]; then
    patch_webui_helper_constants "$INSTALLER_REPO/ai/pi/webui/rollback.sh"
  fi
  if [[ -f "$REPO_ROOT/ai/pi/webui/pi-webui.service.in" ]]; then
    cp "$REPO_ROOT/ai/pi/webui/pi-webui.service.in" \
      "$INSTALLER_REPO/ai/pi/webui/pi-webui.service.in"
  fi
  cp "$REPO_ROOT/ai/pi/webui/runtime/package.json" \
    "$INSTALLER_REPO/ai/pi/webui/runtime/package.json"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package-lock.json" \
    "$INSTALLER_REPO/ai/pi/webui/runtime/package-lock.json"
  cp "$REPO_ROOT/bin/validate-pi-webui" "$INSTALLER_REPO/bin/validate-pi-webui"
  git -C "$INSTALLER_REPO" init -q
  git -C "$INSTALLER_REPO" config user.name 'Pi WebUI Test'
  git -C "$INSTALLER_REPO" config user.email 'pi-webui@example.test'
  git -C "$INSTALLER_REPO" add .
  git -C "$INSTALLER_REPO" commit -qm initial
  INSTALLER="$INSTALLER_REPO/ai/pi/webui/install.sh"
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  TEST_COMMAND_LOG="$TEST_ROOT/commands.log"
  : >"$TEST_COMMAND_LOG"
  export INSTALLER_REPO INSTALLER SOURCE_HEAD TEST_COMMAND_LOG
}

run_installer() {
  run env PI_WEBUI_TESTING=1 PI_WEBUI_TEST_OS_RELEASE="$TEST_OS_RELEASE" \
    PI_WEBUI_TEST_BEFORE_LOCK_HOOK="${TEST_BEFORE_LOCK_HOOK:-}" \
    PI_WEBUI_TEST_AFTER_NPM_HOOK="${TEST_AFTER_NPM_HOOK:-}" \
    PI_WEBUI_TEST_BEFORE_TRIAL_STAGE_HOOK="${TEST_BEFORE_TRIAL_STAGE_HOOK:-}" \
    PI_WEBUI_TEST_PROCESS_CHECK="$PROCESS_CHECK" \
    PI_WEBUI_TEST_PROC_ROOT="$PROC_ROOT" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" HOME="$HOME" PATH="$PATH" \
    TEST_COMMAND_LOG="$TEST_COMMAND_LOG" TEST_ROOT="$TEST_ROOT" \
    PI_TEST_LAUNCHER="$PI_TEST_LAUNCHER" \
    PI_WEBUI_TEST_STATUS_JSON="${PI_WEBUI_TEST_STATUS_JSON:-}" \
    PI_WEBUI_TEST_HEALTH_ATTEMPTS="${PI_WEBUI_TEST_HEALTH_ATTEMPTS:-}" \
    INSTALLER_REPO="$INSTALLER_REPO" bash "$INSTALLER" "$@"
}

file_tree_hashes() {
  find "$1" -type f -exec sha256sum {} + | sort
}

directory_fingerprint() {
  (cd "$1" && find . -type f -exec sha256sum {} + | sort)
}

stub_successful_npm_ci() {
  cat >"$STUB_BIN/npm" <<'SCRIPT'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' '11.6.2'
  exit 0
fi
printf 'npm-ci\n' >>"$TEST_COMMAND_LOG"
printf '%s\n' "$@" >"$TEST_ROOT/npm-args"
[[ "$1" == ci && "$2" == --prefix ]]
prefix=$3
mkdir -p \
  "$prefix/node_modules/.bin" \
  "$prefix/node_modules/@firstpick/pi-package-webui/bin" \
  "$prefix/node_modules/@earendil-works/pi-coding-agent/dist/bundle"
printf '%s\n' \
  '{"name":"@firstpick/pi-package-webui","version":"0.10.3","bin":{"pi-webui":"./bin/pi-webui-launcher.mjs"}}' \
  >"$prefix/node_modules/@firstpick/pi-package-webui/package.json"
: >"$prefix/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
chmod +x "$prefix/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
ln -s ../@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs \
  "$prefix/node_modules/.bin/pi-webui"
printf '%s\n' \
  '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
  >"$prefix/node_modules/@earendil-works/pi-coding-agent/package.json"
: >"$prefix/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
SCRIPT
  chmod +x "$STUB_BIN/npm"
}

make_trial_unit_and_runtime() {
  local unit="$HOME/.config/systemd/user/pi-webui.service"
  mkdir -p "$(dirname "$unit")"
  cat >"$unit" <<'EOF'
[Unit]
Description=Firstp1ck Pi Web UI remote interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/mise exec -- %h/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui --host 127.0.0.1 --port 31415 --cwd /home/tng/.dotfiles/tmp/worktrees/piface-smoke --pi %h/.local/share/mise/installs/node/26.5.0/bin/pi --no-remote-auth --name pi-webui-smoke
ExecStop=/usr/bin/curl --fail --silent --show-error -X POST http://127.0.0.1:31415/api/shutdown
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  chmod 0600 "$unit"
  make_installed_fixture
  mkdir -p "$HOME/.local/share"
  mv "$FIXTURE_RUNTIME" "$HOME/.local/share/pi-webui-runtime"
  chmod 0700 "$HOME/.local/share/pi-webui-runtime"
  FIXTURE_RUNTIME="$TEST_ROOT/runtime"
  mkdir -p "$FIXTURE_RUNTIME"
  : >"$TEST_ROOT/service-active"
  : >"$TEST_ROOT/service-enabled"
  TRIAL_UNIT_FIXTURE="$TEST_ROOT/trial-unit"
  cp "$unit" "$TRIAL_UNIT_FIXTURE"
  export TRIAL_UNIT_FIXTURE
  cat >"$STUB_BIN/sha256sum" <<'SCRIPT'
#!/usr/bin/env bash
unit="$HOME/.config/systemd/user/pi-webui.service"
if [[ "$#" == 1 && "$1" == "$unit" ]] && cmp -s "$TRIAL_UNIT_FIXTURE" "$unit"; then
  printf '%s  %s\n' c3ba39ea60e3b6e7be197f96d13091e61f1c02220ff1d17cb7489dc7a0e8dac4 "$unit"
else
  exec /usr/bin/sha256sum "$@"
fi
SCRIPT
  chmod +x "$STUB_BIN/sha256sum"
}

instrument_validator() {
  mv "$INSTALLER_REPO/bin/validate-pi-webui" "$INSTALLER_REPO/bin/validate-pi-webui.real"
  cat >"$INSTALLER_REPO/bin/validate-pi-webui" <<'SCRIPT'
#!/usr/bin/env bash
printf 'validator %s\n' "$*" >>"$TEST_COMMAND_LOG"
exec bash "$(dirname "$0")/validate-pi-webui.real" "$@"
SCRIPT
  chmod +x "$INSTALLER_REPO/bin/validate-pi-webui"
}

mutate_json() {
  local file=$1 mutation=$2
  node - "$file" "$mutation" <<'NODE'
const fs = require('node:fs');
const [file, mutation] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const webui = 'node_modules/@firstpick/pi-package-webui';
const hardenedPrefix = 'node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/';
const hardened = `${hardenedPrefix}pi-agent-core`;
let rendering = 'pretty';
switch (mutation) {
  case 'manifest-content': rendering = 'extra-newline'; break;
  case 'manifest-format': rendering = 'compact'; break;
  case 'manifest-order': rendering = 'reordered'; break;
  case 'manifest-version': value.dependencies['@firstpick/pi-package-webui'] = '0.10.4'; break;
  case 'manifest-scripts': value.scripts = {postinstall: 'false'}; break;
  case 'manifest-optionals': value.optionalDependencies = {foo: '1.0.0'}; break;
  case 'lock-version': value.lockfileVersion = 2; break;
  case 'lock-root-version': value.packages[''].dependencies['@firstpick/pi-package-webui'] = '0.10.4'; break;
  case 'lock-package-version': value.packages[webui].version = '0.10.4'; break;
  case 'lock-root-scripts': value.packages[''].scripts = {postinstall: 'false'}; break;
  case 'lock-root-optionals': value.packages[''].optionalDependencies = {foo: '1.0.0'}; break;
  case 'firstpick-integrity': value.packages[webui].integrity = 'sha512-AAAAAAAA'; break;
  case 'missing-integrity': delete value.packages['node_modules/bowser'].integrity; break;
  case 'non-sha512-integrity': value.packages['node_modules/bowser'].integrity = 'sha1-AAAAAAAA'; break;
  case 'non-registry': value.packages['node_modules/bowser'].resolved = 'https://example.com/bowser.tgz'; break;
  case 'link': value.packages['node_modules/bowser'] = {resolved: '../bowser', link: true}; break;
  case 'hardened-integrity': value.packages[hardened].integrity = 'sha512-AAAAAAAA'; break;
  case 'hardened-missing': delete value.packages[hardened]; break;
  case 'hardened-seventh':
    value.packages[`${hardenedPrefix}pi-extra`] = {
      version: '0.84.4',
      resolved: 'https://registry.npmjs.org/@earendil-works/pi-extra/-/pi-extra-0.84.4.tgz',
      integrity: 'sha512-AAAAAAAA',
    };
    break;
  case 'hash-drift': value.requires = false; break;
  default: throw new Error(`unknown mutation: ${mutation}`);
}
let rendered;
if (rendering === 'compact') {
  rendered = `${JSON.stringify(value)}\n`;
} else if (rendering === 'reordered') {
  const reordered = {
    dependencies: value.dependencies,
    private: value.private,
    version: value.version,
    name: value.name,
  };
  rendered = `${JSON.stringify(reordered, null, 2)}\n`;
} else {
  rendered = `${JSON.stringify(value, null, 2)}\n`;
  if (rendering === 'extra-newline') rendered += '\n';
}
fs.writeFileSync(file, rendered);
NODE
}

TASK4_EMPTY_JSON='{}'
TASK4_EXACT_JSON='{"TCP":{"443":{"HTTPS":true}},"Web":{"node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}}}'
TASK4_FUNNEL_JSON='{"TCP":{"443":{"HTTPS":true}},"Web":{"node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"node.example.ts.net:443":true}}'
TASK4_FOREIGN_JSON='{"TCP":{"443":{"HTTPS":true}},"Web":{"node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"},"/foreign":{"Proxy":"http://127.0.0.1:9000"}}}},"AllowFunnel":{"node.example.ts.net:443":false}}'

setup_task4_stubs() {
  TASK4_SYSTEM_ROOT="$TEST_ROOT/system-root"
  TASK4_SERVE_JSON="$TEST_ROOT/serve.json"
  TASK4_SERVE_HUMAN="$TEST_ROOT/serve.txt"
  mkdir -p "$TASK4_SYSTEM_ROOT"
  printf '%s\n' "$TASK4_EMPTY_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'No serve config' >"$TASK4_SERVE_HUMAN"
  : >"$TEST_ROOT/tailscaled-active"
  : >"$TEST_ROOT/tailscaled-enabled"
  export TASK4_SYSTEM_ROOT TASK4_SERVE_JSON TASK4_SERVE_HUMAN
  if [[ -x "$SANDBOX_TOOL_BIN/node" ]]; then
    ln -sf "$SANDBOX_TOOL_BIN/node" "$STUB_BIN/node"
  fi
  if [[ ! -x "$STUB_BIN/mise" ]]; then
    NODE_TEST_BIN="$HOME/.local/share/mise/installs/node/26.5.0/bin/node"
    mkdir -p "$(dirname "$NODE_TEST_BIN")"
    local real_node
    real_node=$(node -p 'process.execPath')
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_node" >"$NODE_TEST_BIN"
    chmod +x "$NODE_TEST_BIN"
    export NODE_TEST_BIN
    cat >"$STUB_BIN/mise" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'which node' ]]; then
  printf '%s\n' "$NODE_TEST_BIN"
  exit 0
fi
exit 87
SCRIPT
    chmod +x "$STUB_BIN/mise"
  fi

  cat >"$STUB_BIN/tailscale" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'tailscale %s\n' "$*" >>"$TEST_COMMAND_LOG"
case "$1 ${2:-} ${3:-}" in
  'status --json ')
    printf '%s\n' '{"BackendState":"Running","Self":{"Online":true}}'
    ;;
  'serve status --json') cat "$TASK4_SERVE_JSON" ;;
  'serve status ' ) cat "$TASK4_SERVE_HUMAN" ;;
  'funnel status --json') cat "$TASK4_SERVE_JSON" ;;
  'funnel status ' ) cat "$TASK4_SERVE_HUMAN" ;;
  *) printf 'unexpected tailscale command: %s\n' "$*" >&2; exit 88 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/tailscale"

  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'curl %s\n' "$*" >>"$TEST_COMMAND_LOG"
case "$*" in
  *noble.noarmor.gpg*)
    output=''
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then output=$2; break; fi
      shift
    done
    [[ -n "$output" ]]
    printf '%s\n' 'official-key-fixture' >"$output"
    ;;
  *127.0.0.1:31415/api/health*)
    printf '%s\n' '{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4"}'
    ;;
  *127.0.0.1:31415/api/webui-status*)
    if [[ -n "${PI_WEBUI_TEST_STATUS_JSON:-}" ]]; then
      printf '%s\n' "$PI_WEBUI_TEST_STATUS_JSON"
    else
      printf '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc"}]}}\n' \
        "$HOME/.local/share/pi-webui/worktrees/dotfiles" "$PI_TEST_LAUNCHER"
    fi
    ;;
  *192.0.2.20:31415*) exit 7 ;;
  *) printf 'unexpected curl command: %s\n' "$*" >&2; exit 87 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  stub_command ip 'printf "%s\\n" "2: eth0    inet 192.0.2.20/24 scope global eth0"'
  cat >"$STUB_BIN/sha256sum" <<'SCRIPT'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$#" == 1 ]] && grep -Fqx 'official-key-fixture' "$1" 2>/dev/null; then
  printf '%s  %s\n' 3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39 "$1"
else
  exec /usr/bin/sha256sum "$@"
fi
SCRIPT
  chmod +x "$STUB_BIN/sha256sum"

  cat >"$STUB_BIN/sudo" <<'SCRIPT'
#!/usr/bin/env bash
set -e
raw=("$@")
name=${1##*/}
shift
printf 'sudo-raw %s\n' "${raw[*]}" >>"$TEST_COMMAND_LOG"
printf 'sudo %s %s\n' "$name" "$*" >>"$TEST_COMMAND_LOG"
case "$name" in
  mkdir|install|rm|mktemp|ln) exec "${raw[@]}" ;;
  apt-get) exit 0 ;;
  systemctl) exec "${raw[@]}" ;;
  tailscale)
    if [[ "$1" == up && $# == 1 ]]; then exit 0; fi
    if [[ "$*" == 'serve --bg --https=443 http://127.0.0.1:31415' ]]; then
      printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
      printf '%s\n' 'https://node.example.ts.net (tailnet only)' '|-- / proxy http://127.0.0.1:31415' >"$TASK4_SERVE_HUMAN"
      exit 0
    fi
    if [[ "$*" == 'serve --https=443 off' ]]; then
      printf '%s\n' "$TASK4_EMPTY_JSON" >"$TASK4_SERVE_JSON"
      printf '%s\n' 'No serve config' >"$TASK4_SERVE_HUMAN"
      exit 0
    fi
    ;;
esac
printf 'unexpected sudo command: %s\n' "$*" >&2
exit 86
SCRIPT
  chmod +x "$STUB_BIN/sudo"
}

make_task4_managed_service() {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  setup_task4_stubs
  : >"$TEST_COMMAND_LOG"
}

run_tailscale_helper() {
  run env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" \
    TEST_ROOT="$TEST_ROOT" TEST_COMMAND_LOG="$TEST_COMMAND_LOG" \
    TASK4_SERVE_JSON="$TASK4_SERVE_JSON" TASK4_SERVE_HUMAN="$TASK4_SERVE_HUMAN" \
    TASK4_EXACT_JSON="$TASK4_EXACT_JSON" TASK4_EMPTY_JSON="$TASK4_EMPTY_JSON" \
    PI_WEBUI_TEST_STATUS_JSON="${PI_WEBUI_TEST_STATUS_JSON:-}" PI_TEST_LAUNCHER="${PI_TEST_LAUNCHER:-}" \
    "$INSTALLER_REPO/ai/pi/webui/tailscale.sh" "$@"
}

run_rollback_helper() {
  run env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" TEST_ROOT="$TEST_ROOT" \
    TEST_COMMAND_LOG="$TEST_COMMAND_LOG" TASK4_SERVE_JSON="$TASK4_SERVE_JSON" \
    TASK4_SERVE_HUMAN="$TASK4_SERVE_HUMAN" PI_TEST_LAUNCHER="${PI_TEST_LAUNCHER:-}" \
    PI_WEBUI_TEST_STATUS_JSON="${PI_WEBUI_TEST_STATUS_JSON:-}" \
    "$INSTALLER_REPO/ai/pi/webui/rollback.sh" "$@"
}

@test "tailscale helper help and default are nonmutating explicit interfaces" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  [ "$(stat -c '%a' "$INSTALLER_REPO/ai/pi/webui/tailscale.sh")" = 755 ]
  [ "$(stat -c '%a' "$INSTALLER_REPO/ai/pi/webui/rollback.sh")" = 755 ]

  run_tailscale_helper
  [ "$status" -eq 0 ]
  [[ "$output" == *'check|install|up|serve|serve-off|uninstall'* ]]
  run_tailscale_helper help
  [ "$status" -eq 0 ]
  run ! grep -q '^sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale helper gates every explicit action to exact Noble WSL" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  printf 'ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\n' >"$TEST_OS_RELEASE"
  local action
  for action in check install up serve serve-off uninstall; do
    run_tailscale_helper "$action"
    [ "$status" -ne 0 ]
    [[ "$output" == *'requires Ubuntu 24.04 Noble under WSL'* ]]
  done
  run ! grep -q '^sudo \|^tailscale ' "$TEST_COMMAND_LOG"
}

@test "tailscale install hashes the user-temp official key before exact sudo publication" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs

  run_tailscale_helper install

  [ "$status" -eq 0 ]
  local key="$TASK4_SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  local source="$TASK4_SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list"
  [ "$(cat "$key")" = official-key-fixture ]
  [ "$(cat "$source")" = 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main' ]
  local hash_line install_line
  hash_line=$(grep -n '^sha256sum ' "$TEST_COMMAND_LOG" | head -n1 | cut -d: -f1)
  install_line=$(grep -n '^sudo install -m 0644 ' "$TEST_COMMAND_LOG" | head -n1 | cut -d: -f1)
  [ "$hash_line" -lt "$install_line" ]
  grep -Fqx 'sudo apt-get update' "$TEST_COMMAND_LOG"
  grep -Fqx 'sudo apt-get install tailscale' "$TEST_COMMAND_LOG"
  grep -Fqx 'sudo systemctl enable --now tailscaled.service' "$TEST_COMMAND_LOG"
  grep -Fqx 'sudo-raw /usr/bin/apt-get update' "$TEST_COMMAND_LOG"
  grep -Fqx 'sudo-raw /usr/bin/apt-get install tailscale' "$TEST_COMMAND_LOG"
  grep -Eq '^sudo-raw /usr/bin/install -m 0644 ' "$TEST_COMMAND_LOG"
  run ! grep -Eq 'curl .*[|].*(sh|bash)|wget .*[|].*(sh|bash)|noble\.tailscale-keyring\.list' "$TEST_COMMAND_LOG"
}

@test "tailscale install requires systemd before download or package mutation" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  stub_command systemctl 'exit 1'

  run_tailscale_helper install

  [ "$status" -ne 0 ]
  [[ "$output" == *'systemd is unavailable'* ]]
  run ! grep -Eq '^curl |^sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale install refuses a repository-file collision that appears during publication" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  cat >"$STUB_BIN/sudo" <<'SCRIPT'
#!/usr/bin/env bash
set -e
raw=("$@")
name=${1##*/}
printf 'sudo-raw %s\n' "${raw[*]}" >>"$TEST_COMMAND_LOG"
printf 'sudo %s %s\n' "$name" "${*:2}" >>"$TEST_COMMAND_LOG"
if [[ "$name" == ln && "$*" == *tailscale-archive-keyring.gpg ]]; then
  destination=${!#}
  printf '%s\n' 'foreign-race-winner' >"$destination"
fi
case "$name" in
  mkdir|install|mktemp|ln|rm) exec "${raw[@]}" ;;
  *) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/sudo"

  run_tailscale_helper install

  [ "$status" -ne 0 ]
  [ "$(cat "$TASK4_SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg")" = foreign-race-winner ]
  run ! grep -q '^sudo apt-get' "$TEST_COMMAND_LOG"
}

@test "tailscale install refuses mismatched managed repository files before sudo" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  local source="$TASK4_SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list"
  mkdir -p "$(dirname "$source")"
  printf '%s\n' 'foreign repository' >"$source"

  run_tailscale_helper install

  [ "$status" -ne 0 ]
  [[ "$output" == *'existing Tailscale source is not exact'* ]]
  [ "$(cat "$source")" = 'foreign repository' ]
  run ! grep -q '^sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale up is only the interactive command and contains no auth secret surface" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs

  run_tailscale_helper up

  [ "$status" -eq 0 ]
  [ "$(grep '^sudo tailscale ' "$TEST_COMMAND_LOG")" = 'sudo tailscale up' ]
  run ! grep -Eqi 'auth[-_]?key|oauth|token' "$TEST_COMMAND_LOG"
}

@test "tailscale check validates daemon authentication and reads shared route state" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (tailnet only)' '|-- / proxy http://127.0.0.1:31415' >"$TASK4_SERVE_HUMAN"

  run_tailscale_helper check

  [ "$status" -eq 0 ]
  [[ "$output" == *'route=exact-tailnet-only'* ]]
  grep -Fqx 'tailscale status --json' "$TEST_COMMAND_LOG"
  grep -Fqx 'tailscale serve status --json' "$TEST_COMMAND_LOG"
  grep -Fqx 'tailscale funnel status --json' "$TEST_COMMAND_LOG"
  grep -Fqx 'tailscale funnel status' "$TEST_COMMAND_LOG"
  run ! grep -q '^sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale serve creates only the exact tailnet route after managed local proof" {
  make_task4_managed_service

  run_tailscale_helper serve

  [ "$status" -eq 0 ]
  grep -Fqx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$TEST_COMMAND_LOG"
  grep -Fqx "sudo-raw $STUB_BIN/tailscale serve --bg --https=443 http://127.0.0.1:31415" "$TEST_COMMAND_LOG"
  [ "$(cat "$TASK4_SERVE_JSON")" = "$TASK4_EXACT_JSON" ]
  [[ "$(cat "$TASK4_SERVE_HUMAN")" == *'(tailnet only)'* ]]
  grep -q 'api/health' "$TEST_COMMAND_LOG"
  grep -q '192.0.2.20:31415' "$TEST_COMMAND_LOG"
}

@test "tailscale serve is idempotent for exact shared JSON and refuses foreign or Funnel config" {
  make_task4_managed_service
  printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (tailnet only)' '|-- / proxy http://127.0.0.1:31415' >"$TASK4_SERVE_HUMAN"

  run_tailscale_helper serve
  [ "$status" -eq 0 ]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"

  printf '%s\n' "$TASK4_FOREIGN_JSON" >"$TASK4_SERVE_JSON"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  [[ "$output" == *'foreign or multiple Serve routes'* ]]

  printf '%s\n' "$TASK4_FUNNEL_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (Funnel on)' >"$TASK4_SERVE_HUMAN"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  [[ "$output" == *'Funnel is enabled'* ]]
}

@test "tailscale serve-off removes only the exact owned route and verifies semantic emptiness" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (tailnet only)' '|-- / proxy http://127.0.0.1:31415' >"$TASK4_SERVE_HUMAN"

  run_tailscale_helper serve-off

  [ "$status" -eq 0 ]
  grep -Fqx 'sudo tailscale serve --https=443 off' "$TEST_COMMAND_LOG"
  [ "$(cat "$TASK4_SERVE_JSON")" = "$TASK4_EMPTY_JSON" ]

  printf '%s\n' "$TASK4_FOREIGN_JSON" >"$TASK4_SERVE_JSON"
  run_tailscale_helper serve-off
  [ "$status" -ne 0 ]
  [[ "$output" == *'foreign or multiple Serve routes'* ]]
}

@test "tailscale uninstall refuses active Serve then removes only exact repository files without purging identity" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  run_tailscale_helper install
  [ "$status" -eq 0 ]
  printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (tailnet only)' '|-- / proxy http://127.0.0.1:31415' >"$TASK4_SERVE_HUMAN"
  : >"$TEST_COMMAND_LOG"

  run_tailscale_helper uninstall
  [ "$status" -ne 0 ]
  [[ "$output" == *'remove Serve first'* ]]
  run ! grep -q '^sudo apt-get remove' "$TEST_COMMAND_LOG"

  printf '%s\n' "$TASK4_EMPTY_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'No serve config' >"$TASK4_SERVE_HUMAN"
  run_tailscale_helper uninstall
  [ "$status" -eq 0 ]
  grep -Fqx 'sudo apt-get remove tailscale' "$TEST_COMMAND_LOG"
  [ ! -e "$TASK4_SYSTEM_ROOT/etc/apt/sources.list.d/tailscale.list" ]
  [ ! -e "$TASK4_SYSTEM_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg" ]
  [[ "$output" == *'Tailscale identity state preserved'* ]]
  run ! grep -Eq 'purge|/var/lib/tailscale|tailscale logout' "$TEST_COMMAND_LOG"
}

@test "rollback default refuses Serve and prints the exact prerequisite command" {
  make_task4_managed_service
  printf '%s\n' "$TASK4_EXACT_JSON" >"$TASK4_SERVE_JSON"
  printf '%s\n' 'https://node.example.ts.net (tailnet only)' >"$TASK4_SERVE_HUMAN"

  run_rollback_helper

  [ "$status" -ne 0 ]
  [[ "$output" == *"$INSTALLER_REPO/ai/pi/webui/tailscale.sh serve-off"* ]]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]
  [ -f "$TEST_ROOT/service-active" ]
}

@test "rollback default removes only the managed unit and preserves all state" {
  make_task4_managed_service
  mkdir -p "$HOME/.pi/webui" "$HOME/.local/state/pi-webui" "$HOME/.pi/agent/sessions"
  printf 'settings\n' >"$HOME/.pi/webui/settings.json"
  printf 'supervisor\n' >"$HOME/.local/state/pi-webui/state"
  printf 'transcript\n' >"$HOME/.pi/agent/sessions/session.jsonl"
  printf 'trial\n' >"$HOME/.local/share/pi-webui/evaluation-2026-09-02.md"

  run_rollback_helper

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/current" ]
  [ -d "$HOME/.local/share/pi-webui/worktrees/dotfiles" ]
  [ -f "$HOME/.pi/webui/settings.json" ]
  [ -f "$HOME/.local/state/pi-webui/state" ]
  [ -f "$HOME/.pi/agent/sessions/session.jsonl" ]
  [ -f "$HOME/.local/share/pi-webui/evaluation-2026-09-02.md" ]
  grep -Fqx 'systemctl --user disable --now pi-webui.service' "$TEST_COMMAND_LOG"
  grep -Fqx 'systemctl --user daemon-reload' "$TEST_COMMAND_LOG"
}

@test "rollback is idempotent when the managed service was never installed" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  setup_task4_stubs

  run_rollback_helper
  [ "$status" -eq 0 ]
  [[ "$output" == *'Pi Web UI service is not installed'* ]]
  run_rollback_helper
  [ "$status" -eq 0 ]
}

@test "rollback refuses foreign and symlinked units without service mutation" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  setup_task4_stubs
  local unit="$HOME/.config/systemd/user/pi-webui.service"
  mkdir -p "$(dirname "$unit")"
  printf '[Service]\nExecStart=/bin/false\n' >"$unit"
  chmod 0600 "$unit"
  : >"$TEST_ROOT/service-active"

  run_rollback_helper
  [ "$status" -ne 0 ]
  [[ "$output" == *'unit is foreign'* ]]
  [ -f "$TEST_ROOT/service-active" ]
  run ! grep -q '^systemctl --user disable' "$TEST_COMMAND_LOG"

  rm "$unit"
  printf 'foreign target\n' >"$TEST_ROOT/foreign-unit"
  ln -s "$TEST_ROOT/foreign-unit" "$unit"
  run_rollback_helper
  [ "$status" -ne 0 ]
  [[ "$output" == *'unit is unsafe or foreign'* ]]
  [ "$(cat "$TEST_ROOT/foreign-unit")" = 'foreign target' ]
}

@test "rollback destructive flags remove only validated runtime and a clean detached source worktree" {
  make_task4_managed_service
  local runtime="$HOME/.local/share/pi-webui/runtimes/current"
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"

  run_rollback_helper --remove-runtime --remove-worktree

  [ "$status" -eq 0 ]
  [ ! -e "$runtime" ]
  [ ! -e "$worktree" ]
  local registrations
  registrations=$(git -C "$INSTALLER_REPO" worktree list --porcelain)
  [[ "$registrations" != *"worktree $worktree"* ]]

  run_rollback_helper --remove-runtime --remove-worktree
  [ "$status" -eq 0 ]
  [[ "$output" == *'already absent'* ]]
}

@test "rollback destructive guards preserve symlink runtime and dirty or attached worktrees" {
  make_task4_managed_service
  local runtime="$HOME/.local/share/pi-webui/runtimes/current"
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  local outside="$TEST_ROOT/runtime-outside"
  mv "$runtime" "$outside"
  ln -s "$outside" "$runtime"

  run_rollback_helper --remove-runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *'runtime must be a real directory'* ]]
  [ -L "$runtime" ]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]

  rm "$runtime"
  mv "$outside" "$runtime"
  printf 'preserve dirty\n' >"$worktree/ignored-local"
  printf 'ignored-local\n' >>"$(git -C "$worktree" rev-parse --git-path info/exclude)"
  run_rollback_helper --remove-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *'worktree must be clean, including ignored files'* ]]
  [ "$(cat "$worktree/ignored-local")" = 'preserve dirty' ]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]

  rm "$worktree/ignored-local"
  git -C "$worktree" checkout -q -b attached-rollback-test
  run_rollback_helper --remove-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *'worktree must be detached'* ]]
  [ -d "$worktree" ]
}

@test "tailscale install rejects a bad key digest before every sudo command" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  cat >"$STUB_BIN/sha256sum" <<'SCRIPT'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >>"$TEST_COMMAND_LOG"
printf '%s  %s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$1"
SCRIPT
  chmod +x "$STUB_BIN/sha256sum"

  run_tailscale_helper install

  [ "$status" -ne 0 ]
  [[ "$output" == *'Tailscale key SHA-256 mismatch'* ]]
  run ! grep -q '^sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale serve rejects wildcard foreign and directly reachable LAN listeners before route mutation" {
  make_task4_managed_service
  : >"$TEST_ROOT/wildcard-listener"

  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"

  rm "$TEST_ROOT/wildcard-listener"
  : >"$TEST_ROOT/spoof-listener"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"

  rm "$TEST_ROOT/spoof-listener"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *api/webui-status*)
    printf '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc"}]}}\n' \
      "$HOME/.local/share/pi-webui/worktrees/dotfiles" "$PI_TEST_LAUNCHER"
    ;;
  *api/health*) printf '%s\n' '{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4"}' ;;
esac
exit 0
SCRIPT
  chmod +x "$STUB_BIN/curl"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  [[ "$output" == *'reachable directly from the WSL LAN address'* ]]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"
}

@test "tailscale serve-off is idempotent when shared Serve and Funnel JSON is semantically empty" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs

  run_tailscale_helper serve-off

  [ "$status" -eq 0 ]
  [[ "$output" == *'no Tailscale Serve route is configured'* ]]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"
}

@test "rollback gates the platform and refuses foreign residual runtime state" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  setup_task4_stubs
  printf 'ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\n' >"$TEST_OS_RELEASE"

  run_rollback_helper
  [ "$status" -ne 0 ]
  [[ "$output" == *'requires Ubuntu 24.04 Noble under WSL'* ]]

  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$TEST_OS_RELEASE"
  local runtime="$HOME/.local/share/pi-webui/runtimes/current"
  mkdir -p "$runtime"
  printf 'foreign\n' >"$runtime/sentinel"
  run_rollback_helper
  [ "$status" -ne 0 ]
  [[ "$output" == *'runtime'*'foreign'* ]]
  [ "$(cat "$runtime/sentinel")" = foreign ]
}

@test "rollback leaves a proven unit in place when scoped process cleanup fails" {
  make_task4_managed_service
  cat >"$PROCESS_CHECK" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'scoped Pi child remains' >&2
exit 43
SCRIPT
  chmod +x "$PROCESS_CHECK"

  run_rollback_helper

  [ "$status" -eq 43 ]
  [[ "$output" == *'scoped Pi child remains'* ]]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]
  [ ! -e "$TEST_ROOT/service-active" ]
}

@test "rollback refuses apply locks malformed runtime markers and foreign or symlink worktrees" {
  make_task4_managed_service
  local lock="$HOME/.local/share/pi-webui/transactions/apply.lock"
  mkdir -p "$lock"
  printf 'foreign lock\n' >"$lock/sentinel"

  run_rollback_helper --remove-runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *'apply lock is present'* ]]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]

  rm -rf "$lock"
  printf 'wrong-marker\n' >"$HOME/.local/share/pi-webui/runtimes/current/.pi-webui-current"
  run_rollback_helper --remove-runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *'runtime marker is missing or foreign'* ]]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]

  printf '%s\n' pi-webui-task3-current-v1 >"$HOME/.local/share/pi-webui/runtimes/current/.pi-webui-current"
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  git -C "$INSTALLER_REPO" worktree remove "$worktree"
  mkdir -p "$TEST_ROOT/worktree-target"
  ln -s "$TEST_ROOT/worktree-target" "$worktree"
  run_rollback_helper --remove-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *'worktree must be a real directory'* ]]
  [ -L "$worktree" ]

  rm "$worktree"
  git -C "$TEST_ROOT/worktree-target" init -q
  printf 'foreign\n' >"$TEST_ROOT/worktree-target/sentinel"
  git -C "$TEST_ROOT/worktree-target" add sentinel
  git -C "$TEST_ROOT/worktree-target" -c user.name=test -c user.email=test@example.test commit -qm foreign
  mv "$TEST_ROOT/worktree-target" "$worktree"
  run_rollback_helper --remove-worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *'worktree belongs to a foreign repository'* ]]
  [ "$(cat "$worktree/sentinel")" = foreign ]
}

@test "rollback refuses a symlinked state root before deleting the external runtime" {
  make_task4_managed_service
  local state="$HOME/.local/share/pi-webui"
  local outside="$TEST_ROOT/outside-state"
  mv "$state" "$outside"
  ln -s "$outside" "$state"
  printf 'preserve\n' >"$outside/runtimes/current/sentinel"

  run_rollback_helper --remove-runtime

  [ "$status" -ne 0 ]
  [ -L "$state" ]
  [ "$(cat "$outside/runtimes/current/sentinel")" = preserve ]
  [ -f "$TEST_ROOT/service-active" ]
}

@test "rollback refuses symlinked runtimes and worktrees parents before destructive cleanup" {
  make_task4_managed_service
  local state="$HOME/.local/share/pi-webui"
  local outside="$TEST_ROOT/outside-runtimes"
  mv "$state/runtimes" "$outside"
  ln -s "$outside" "$state/runtimes"
  printf 'preserve\n' >"$outside/current/sentinel"

  run_rollback_helper --remove-runtime

  [ "$status" -ne 0 ]
  [ "$(cat "$outside/current/sentinel")" = preserve ]
  [ -f "$TEST_ROOT/service-active" ]

  rm "$state/runtimes"
  mv "$outside" "$state/runtimes"
  outside="$TEST_ROOT/outside-worktrees"
  mv "$state/worktrees" "$outside"
  ln -s "$outside" "$state/worktrees"
  printf 'preserve\n' >"$outside/sentinel"

  run_rollback_helper --remove-worktree

  [ "$status" -ne 0 ]
  [ -d "$outside/dotfiles" ]
  [ "$(cat "$outside/sentinel")" = preserve ]
  [ -f "$TEST_ROOT/service-active" ]
}

@test "rollback refuses permissive and foreign-owned managed parents before deletion" {
  make_task4_managed_service
  local runtimes="$HOME/.local/share/pi-webui/runtimes"
  printf 'preserve\n' >"$runtimes/current/sentinel"
  chmod 0777 "$runtimes"

  run_rollback_helper --remove-runtime

  [ "$status" -ne 0 ]
  [ "$(cat "$runtimes/current/sentinel")" = preserve ]
  [ -f "$TEST_ROOT/service-active" ]

  chmod 0700 "$runtimes"
  cat >"$STUB_BIN/stat" <<'SCRIPT'
#!/usr/bin/env bash
last=${!#}
if [[ "$last" == "$HOME/.local/share/pi-webui/runtimes" && "$1 $2" == '-c %u' ]]; then
  printf '%s\n' 99999
  exit 0
fi
exec /usr/bin/stat "$@"
SCRIPT
  chmod +x "$STUB_BIN/stat"

  run_rollback_helper --remove-runtime

  [ "$status" -ne 0 ]
  [ "$(cat "$runtimes/current/sentinel")" = preserve ]
  [ -f "$TEST_ROOT/service-active" ]
}

@test "tailscale ingress ignores a hostile caller PATH and never trusts fake safe preflight" {
  make_task4_managed_service
  local malicious="$TEST_ROOT/malicious-bin"
  mkdir -p "$malicious"
  cp -a "$STUB_BIN/." "$malicious/"
  rm -f "$malicious/node"
  printf '[Service]\nExecStart=/bin/false\n' >"$HOME/.config/systemd/user/pi-webui.service"
  chmod 0600 "$HOME/.config/systemd/user/pi-webui.service"
  cat >"$malicious/node" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$*" == *'const left = classify'* ]]; then
  if [[ -f "$TEST_ROOT/malicious-sudo-ran" ]]; then printf exact; else printf empty; fi
fi
exit 0
SCRIPT
  cat >"$malicious/sudo" <<'SCRIPT'
#!/usr/bin/env bash
printf 'malicious sudo %s\n' "$*" >>"$TEST_COMMAND_LOG"
: >"$TEST_ROOT/malicious-sudo-ran"
exit 0
SCRIPT
  chmod +x "$malicious/node" "$malicious/sudo"

  run env PI_WEBUI_TESTING=1 PI_WEBUI_TEST_OS_RELEASE="$TEST_OS_RELEASE" \
    PI_WEBUI_TEST_TRUSTED_BIN_DIR="$STUB_BIN" PI_WEBUI_TEST_SYSTEM_ROOT="$TASK4_SYSTEM_ROOT" \
    PI_WEBUI_TEST_PROC_ROOT="$PROC_ROOT" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$malicious:$PATH" \
    TEST_ROOT="$TEST_ROOT" TEST_COMMAND_LOG="$TEST_COMMAND_LOG" \
    TASK4_SERVE_JSON="$TASK4_SERVE_JSON" TASK4_SERVE_HUMAN="$TASK4_SERVE_HUMAN" \
    TASK4_EXACT_JSON="$TASK4_EXACT_JSON" TASK4_EMPTY_JSON="$TASK4_EMPTY_JSON" \
    PI_TEST_LAUNCHER="$PI_TEST_LAUNCHER" \
    bash "$INSTALLER_REPO/ai/pi/webui/tailscale.sh" serve

  [ "$status" -ne 0 ]
  [ ! -e "$TEST_ROOT/malicious-sudo-ran" ]
  run ! grep -q '^malicious sudo ' "$TEST_COMMAND_LOG"
}

@test "tailscale serve requires the exact external Pi launcher owner and owner-only runtime" {
  make_task4_managed_service
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.3","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"

  run_tailscale_helper serve

  [ "$status" -ne 0 ]
  run ! grep -q '^sudo .*tailscale.* serve' "$TEST_COMMAND_LOG"

  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"
  chmod 0770 "$HOME/.local/share/pi-webui/runtimes/current"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run ! grep -q '^sudo .*tailscale.* serve' "$TEST_COMMAND_LOG"
}

@test "tailscale serve refuses symlink dirty attached and foreign managed worktrees" {
  make_task4_managed_service
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  local target="$TEST_ROOT/worktree-target"
  mv "$worktree" "$target"
  ln -s "$target" "$worktree"

  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run ! grep -q '^sudo .*tailscale.* serve' "$TEST_COMMAND_LOG"

  rm "$worktree"
  mv "$target" "$worktree"
  printf 'dirty\n' >"$worktree/dirty"
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  rm "$worktree/dirty"

  git -C "$worktree" checkout -qb task4-attached
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  git -C "$worktree" checkout -q --detach

  git -C "$INSTALLER_REPO" worktree remove "$worktree"
  mkdir -p "$worktree"
  git -C "$worktree" init -q
  printf 'foreign\n' >"$worktree/sentinel"
  git -C "$worktree" add sentinel
  git -C "$worktree" -c user.name=test -c user.email=test@example.test commit -qm foreign
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  [ "$(cat "$worktree/sentinel")" = foreign ]
  run ! grep -q '^sudo .*tailscale.* serve' "$TEST_COMMAND_LOG"
}

@test "tailscale serve refuses detailed status with a mismatched cwd or Pi command" {
  make_task4_managed_service
  # shellcheck disable=SC2089 # Exported JSON is consumed as data, not shell syntax.
  PI_WEBUI_TEST_STATUS_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"/foreign","running":true,"command":"/foreign/pi --mode rpc"}]}}'
  # shellcheck disable=SC2090
  export PI_WEBUI_TEST_STATUS_JSON

  run_tailscale_helper serve

  [ "$status" -ne 0 ]
  run ! grep -q '^sudo .*tailscale.* serve' "$TEST_COMMAND_LOG"
}

@test "rollback default requires exact Pi worktree and detailed tab identity before stop" {
  make_task4_managed_service
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.3","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"

  run_rollback_helper
  [ "$status" -ne 0 ]
  [ -f "$TEST_ROOT/service-active" ]

  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"
  printf 'dirty\n' >"$HOME/.local/share/pi-webui/worktrees/dotfiles/dirty"
  run_rollback_helper
  [ "$status" -ne 0 ]
  [ -f "$TEST_ROOT/service-active" ]

  rm "$HOME/.local/share/pi-webui/worktrees/dotfiles/dirty"
  # shellcheck disable=SC2089 # Exported JSON is consumed as data, not shell syntax.
  PI_WEBUI_TEST_STATUS_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"/foreign","running":true,"command":"/foreign/pi --mode rpc"}]}}'
  # shellcheck disable=SC2090
  export PI_WEBUI_TEST_STATUS_JSON
  run_rollback_helper
  [ "$status" -ne 0 ]
  [ -f "$TEST_ROOT/service-active" ]
  run ! grep -q '^systemctl --user disable' "$TEST_COMMAND_LOG"
}

@test "rollback revalidates runtime inode after clean service stop before recursive removal" {
  make_task4_managed_service
  local runtime="$HOME/.local/share/pi-webui/runtimes/current"
  local retained="$TEST_ROOT/pre-stop-runtime"
  cat >"$PROCESS_CHECK" <<'SCRIPT'
#!/usr/bin/env bash
set -e
runtime="$HOME/.local/share/pi-webui/runtimes/current"
retained="$TEST_ROOT/pre-stop-runtime"
mv "$runtime" "$retained"
cp -a "$retained" "$runtime"
printf 'preserve replacement\n' >"$runtime/race-sentinel"
SCRIPT
  chmod +x "$PROCESS_CHECK"

  run_rollback_helper --remove-runtime

  [ "$status" -ne 0 ]
  [[ "$output" == *'runtime identity changed before removal'* ]]
  [ "$(cat "$runtime/race-sentinel")" = 'preserve replacement' ]
  [ -d "$retained" ]
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "production helpers ignore the complete forged legacy executable seam tuple" {
  local malicious="$TEST_ROOT/forged-old-seam"
  mkdir -p "$malicious"
  cat >"$malicious/dirname" <<'SCRIPT'
#!/usr/bin/env bash
printf 'forged executable ran\n' >"$TEST_ROOT/forged-executable-ran"
exec /usr/bin/dirname "$@"
SCRIPT
  chmod +x "$malicious/dirname"
  local release="$TEST_ROOT/forged-release"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$release"

  run env PI_WEBUI_TESTING=1 BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    PI_WEBUI_TEST_TRUSTED_BIN_DIR="$malicious" PI_WEBUI_TEST_OS_RELEASE="$release" \
    PI_WEBUI_TEST_SYSTEM_ROOT="$TEST_ROOT/forged-system" PI_WEBUI_TEST_PROC_ROOT="$TEST_ROOT/forged-proc" \
    PI_WEBUI_TEST_PROCESS_CHECK="$malicious/process-check" HOME="$HOME" PATH="$malicious:$PATH" \
    TEST_ROOT="$TEST_ROOT" "$REPO_ROOT/ai/pi/webui/tailscale.sh" help

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/forged-executable-ran" ]
}

@test "direct helper startup ignores hostile Bash startup state and exported functions" {
  make_task4_managed_service
  local startup="$TEST_ROOT/hostile-bash-env"
  cat >"$startup" <<'SCRIPT'
case "$0" in
  *tailscale.sh|*rollback.sh)
    printf 'BASH_ENV ran\n' >>"$TEST_ROOT/startup-injection-ran"
    trap 'printf "DEBUG trap ran\\n" >>"$TEST_ROOT/startup-injection-ran"' DEBUG
    ;;
esac
SCRIPT

  run env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" TEST_ROOT="$TEST_ROOT" \
    BASH_ENV="$startup" SHELLOPTS=xtrace BASHOPTS=extdebug CDPATH="$TEST_ROOT" \
    'BASH_FUNC_cd%%=() { printf "cd function ran\\n" >>"$TEST_ROOT/startup-injection-ran"; builtin cd "$@"; }' \
    'BASH_FUNC_pwd%%=() { printf "pwd function ran\\n" >>"$TEST_ROOT/startup-injection-ran"; builtin pwd "$@"; }' \
    'BASH_FUNC_systemctl%%=() { printf "systemctl function ran\\n" >>"$TEST_ROOT/startup-injection-ran"; return 99; }' \
    'BASH_FUNC_tailscale%%=() { printf "tailscale function ran\\n" >>"$TEST_ROOT/startup-injection-ran"; return 99; }' \
    "$INSTALLER_REPO/ai/pi/webui/tailscale.sh" help
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/startup-injection-ran" ]

  BASH_ENV=$startup
  CDPATH=$TEST_ROOT
  export BASH_ENV CDPATH
  cd() {
    printf 'cd function ran\n' >>"$TEST_ROOT/startup-injection-ran"
    builtin cd "$@"
  }
  pwd() {
    printf 'pwd function ran\n' >>"$TEST_ROOT/startup-injection-ran"
    builtin pwd "$@"
  }
  systemctl() {
    printf 'systemctl function ran\n' >>"$TEST_ROOT/startup-injection-ran"
    return 99
  }
  tailscale() {
    printf 'tailscale function ran\n' >>"$TEST_ROOT/startup-injection-ran"
    return 99
  }
  export -f cd pwd systemctl tailscale

  run_rollback_helper --help
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/startup-injection-ran" ]
  run_tailscale_helper check
  [ "$status" -eq 0 ]
  run_tailscale_helper serve
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/startup-injection-ran" ]
  unset BASH_ENV CDPATH
  unset -f cd pwd systemctl tailscale
}

@test "non-privileged Bash invocation is refused after any prior BASH_ENV effects" {
  make_installer_repo
  local startup="$TEST_ROOT/nonprivileged-bash-env"
  cat >"$startup" <<'SCRIPT'
printf 'prior BASH_ENV effect\n' >"$TEST_ROOT/prior-bash-env-effect"
SCRIPT

  run env HOME="$HOME" TEST_ROOT="$TEST_ROOT" BASH_ENV="$startup" \
    /usr/bin/bash "$INSTALLER_REPO/ai/pi/webui/tailscale.sh" help

  [ "$status" -eq 126 ]
  [[ "$output" == *'must be executed directly'* ]]
  [ -f "$TEST_ROOT/prior-bash-env-effect" ]
}

@test "mise resolution falls back only to the validated user path" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  mkdir -p "$HOME/.local/bin"
  mv "$STUB_BIN/mise" "$HOME/.local/bin/mise"

  run_tailscale_helper check

  [ "$status" -eq 0 ]
  [[ "$output" == *'Tailscale authenticated'* ]]
}

@test "mise resolution rejects an unsafe user symlink and detects executable replacement" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/outside-mise"
  mv "$STUB_BIN/mise" "$TEST_ROOT/outside-mise/mise"
  ln -s "$TEST_ROOT/outside-mise/mise" "$HOME/.local/bin/mise"

  run_tailscale_helper check
  [ "$status" -ne 0 ]
  [[ "$output" == *'no safe supported mise executable'* ]]

  rm "$HOME/.local/bin/mise"
  cp "$TEST_ROOT/outside-mise/mise" "$STUB_BIN/mise"
  cat >"$STUB_BIN/mise" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == 'which node' ]]; then
  mv "$MISE_TEST_PATH" "$MISE_TEST_PATH.before-swap"
  cp "$MISE_TEST_PATH.before-swap" "$MISE_TEST_PATH"
  chmod +x "$MISE_TEST_PATH"
  printf '%s\n' "$NODE_TEST_BIN"
  exit 0
fi
exit 87
SCRIPT
  chmod +x "$STUB_BIN/mise"
  MISE_TEST_PATH="$STUB_BIN/mise"
  export MISE_TEST_PATH

  run_tailscale_helper check
  [ "$status" -ne 0 ]
  [[ "$output" == *'mise executable identity changed after validation'* ]]
}

@test "mise and Node validation rejects permissive parents and Node replacement" {
  make_installer_repo
  make_valid_platform
  setup_task4_stubs

  chmod 0775 "$HOME/.local/share/mise/installs/node/26.5.0/bin"
  run_tailscale_helper check
  [ "$status" -ne 0 ]
  [[ "$output" == *'Node.js'*'parent'* || "$output" == *'unsafe Node.js'* ]]
  chmod 0755 "$HOME/.local/share/mise/installs/node/26.5.0/bin"

  mkdir -p "$HOME/.local/bin"
  mv "$STUB_BIN/mise" "$HOME/.local/bin/mise"
  chmod 0775 "$HOME/.local/bin"
  run_tailscale_helper check
  [ "$status" -ne 0 ]
  [[ "$output" == *'mise'*'parent'* || "$output" == *'safe supported mise'* ]]
  chmod 0755 "$HOME/.local/bin"
  mv "$HOME/.local/bin/mise" "$STUB_BIN/mise"

  local real_node
  real_node=$(node -p 'process.execPath')
  cat >"$NODE_TEST_BIN" <<SCRIPT
#!/usr/bin/env bash
mv "\$NODE_TEST_BIN" "\$NODE_TEST_BIN.before-swap"
cp "\$NODE_TEST_BIN.before-swap" "\$NODE_TEST_BIN"
chmod +x "\$NODE_TEST_BIN"
exec "$real_node" "\$@"
SCRIPT
  chmod +x "$NODE_TEST_BIN"

  run_tailscale_helper check
  [ "$status" -ne 0 ]
  [[ "$output" == *'Node.js executable identity changed after validation'* ]]
}

@test "tailscale and rollback enforce an rpc argument boundary" {
  make_task4_managed_service
  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc-suffix"}]}}' \
    "$HOME/.local/share/pi-webui/worktrees/dotfiles" "$PI_TEST_LAUNCHER")
  export PI_WEBUI_TEST_STATUS_JSON

  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run ! grep -q '^sudo tailscale serve' "$TEST_COMMAND_LOG"

  run_rollback_helper
  [ "$status" -ne 0 ]
  [ -f "$TEST_ROOT/service-active" ]
  run ! grep -q '^systemctl --user disable' "$TEST_COMMAND_LOG"

  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":null}]}}' \
    "$HOME/.local/share/pi-webui/worktrees/dotfiles")
  export PI_WEBUI_TEST_STATUS_JSON
  run_tailscale_helper serve
  [ "$status" -ne 0 ]
  run_rollback_helper
  [ "$status" -ne 0 ]
  [ -f "$TEST_ROOT/service-active" ]

  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc --resume accepted"}]}}' \
    "$HOME/.local/share/pi-webui/worktrees/dotfiles" "$PI_TEST_LAUNCHER")
  export PI_WEBUI_TEST_STATUS_JSON
  run_tailscale_helper serve
  [ "$status" -eq 0 ]
  run_tailscale_helper serve-off
  [ "$status" -eq 0 ]
  run_rollback_helper
  [ "$status" -eq 0 ]
}

@test "installer rejects rpc-suffix tab commands during candidate verification" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc-suffix"}]}}' \
    "$worktree" "$PI_TEST_LAUNCHER")
  export PI_WEBUI_TEST_STATUS_JSON

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *'detailed status validation failed'* ]]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/current" ]
}

@test "installer requires every detailed tab command to be a string" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true}]}}' \
    "$worktree")
  export PI_WEBUI_TEST_STATUS_JSON

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *'detailed status validation failed'* ]]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/current" ]
}

@test "tracked runtime accepts the exact authored package graph by default" {
  run bash "$REPO_ROOT/bin/validate-pi-webui"

  [ "$status" -eq 0 ]
  [[ "$output" == *"validated 350 registry packages"* ]]
}

@test "tracked-only mode accepts the exact authored package graph" {
  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only

  [ "$status" -eq 0 ]
}

@test "validator rejects a wrong Firstp1ck manifest version" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package.json" manifest-version

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest dependency must be exactly @firstpick/pi-package-webui@0.10.3"* ]]
}

@test "validator byte-pins manifest formatting, property order, and content" {
  local mutation
  for mutation in manifest-format manifest-order manifest-content; do
    make_runtime_fixture
    mutate_json "$FIXTURE_RUNTIME/package.json" "$mutation"

    run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest SHA-256 must be $ACCEPTED_MANIFEST_SHA256"* ]]
    rm -rf "$FIXTURE_RUNTIME"
    mkdir -p "$FIXTURE_RUNTIME"
  done
}

@test "validator rejects a wrong Firstp1ck lock version" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-root-version

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock root dependency must be exactly @firstpick/pi-package-webui@0.10.3"* ]]
}

@test "validator rejects a wrong Firstp1ck package-entry version" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-package-version

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock package must be exactly @firstpick/pi-package-webui@0.10.3"* ]]
}

@test "validator rejects a wrong Firstp1ck integrity" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" firstpick-integrity

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected Firstp1ck integrity"* ]]
}

@test "validator rejects lock hash drift after semantic validation" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" hash-drift

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock SHA-256 must be $ACCEPTED_LOCK_SHA256"* ]]
}

@test "validator requires lockfile v3" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-version

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lockfileVersion must be 3"* ]]
}

@test "validator rejects a missing package integrity" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" missing-integrity

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing SHA-512 integrity: node_modules/bowser"* ]]
}

@test "validator rejects a non-SHA512 package integrity" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" non-sha512-integrity

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing SHA-512 integrity: node_modules/bowser"* ]]
}

@test "validator rejects a non-registry package" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" non-registry

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"non-registry package: node_modules/bowser"* ]]
}

@test "validator rejects a linked package" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" link

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"linked package is forbidden: node_modules/bowser"* ]]
}

@test "validator rejects manifest lifecycle scripts" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package.json" manifest-scripts

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime manifest must not declare scripts"* ]]
}

@test "validator rejects manifest optional dependencies" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package.json" manifest-optionals

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime manifest must not declare optionalDependencies"* ]]
}

@test "validator rejects lock-root lifecycle scripts" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-root-scripts

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock root must not declare scripts"* ]]
}

@test "validator rejects lock-root optional dependencies" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-root-optionals

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock root must not declare optionalDependencies"* ]]
}

@test "validator pins the six hardened nested Earendil entries exactly" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" hardened-integrity

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected hardened Earendil entry: pi-agent-core"* ]]
}

@test "validator rejects a missing hardened nested Earendil entry" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" hardened-missing

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock must contain exactly the six hardened nested Earendil entries"* ]]
}

@test "validator rejects a seventh hardened nested Earendil entry" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" hardened-seventh

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock must contain exactly the six hardened nested Earendil entries"* ]]
}

@test "installed mode accepts exact package identities and launchers in a spaced path" {
  make_installed_fixture
  mv "$FIXTURE_RUNTIME" "$TEST_ROOT/runtime with spaces"
  FIXTURE_RUNTIME="$TEST_ROOT/runtime with spaces"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -eq 0 ]
}

@test "installed mode rejects a symlink runtime root" {
  make_installed_fixture
  mv "$FIXTURE_RUNTIME" "$TEST_ROOT/runtime target"
  ln -s "$TEST_ROOT/runtime target" "$FIXTURE_RUNTIME"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME/"

  [ "$status" -ne 0 ]
  [[ "$output" == *"installed runtime root must not be a symbolic link"* ]]
}

@test "installed mode rejects a Firstp1ck package path symlink escape" {
  make_installed_fixture
  mv "$FIXTURE_RUNTIME/node_modules/@firstpick" "$TEST_ROOT/outside firstpick"
  ln -s "$TEST_ROOT/outside firstpick" "$FIXTURE_RUNTIME/node_modules/@firstpick"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"installed Firstp1ck path contains a symbolic link"* ]]
}

@test "installed mode rejects a Pi package path symlink escape" {
  make_installed_fixture
  mv "$FIXTURE_RUNTIME/node_modules/@earendil-works" "$TEST_ROOT/outside pi"
  ln -s "$TEST_ROOT/outside pi" "$FIXTURE_RUNTIME/node_modules/@earendil-works"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"installed Pi path contains a symbolic link"* ]]
}

@test "installed mode rejects a prohibited node-pty installation" {
  make_installed_fixture
  mkdir -p "$FIXTURE_RUNTIME/node_modules/node-pty"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"node-pty must not be installed"* ]]
}

@test "installed mode rejects a nested prohibited node-pty installation" {
  make_installed_fixture
  mkdir -p "$FIXTURE_RUNTIME/node_modules/@firstpick/pi-package-webui/node_modules/node-pty"

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"node-pty must not be installed"* ]]
}

@test "fixture mutations never alter the tracked lock" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" hash-drift

  run sha256sum "$REPO_ROOT/ai/pi/webui/runtime/package-lock.json"

  [ "$status" -eq 0 ]
  [ "${output%% *}" = "$ACCEPTED_LOCK_SHA256" ]
}

@test "installer renders and installs the exact owner-only service on first apply" {
  HOME="$TEST_ROOT/home with spaces"
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME"
  export HOME XDG_CONFIG_HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local state="$HOME/.local/share/pi-webui"
  local worktree="$state/worktrees/dotfiles"
  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc"}]}}' \
    "$worktree" "$PI_TEST_LAUNCHER")
  export PI_WEBUI_TEST_STATUS_JSON

  run_installer --apply

  [ "$status" -eq 0 ]
  local unit="$HOME/.config/systemd/user/pi-webui.service"
  local runtime="$state/runtimes/current"
  [ -f "$unit" ]
  [ "$(stat -c '%a' "$unit")" = 600 ]
  [ -x "$runtime/node_modules/.bin/pi-webui" ]
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
  cat >"$TEST_ROOT/expected.service" <<EOF
[Unit]
Description=Firstp1ck Pi Web UI remote interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/mise exec -- "$runtime/node_modules/.bin/pi-webui" --host 127.0.0.1 --port 31415 --cwd "$worktree" --pi "$PI_TEST_LAUNCHER" --no-remote-auth --name pi-webui
ExecStop=/usr/bin/curl --fail --silent --show-error -X POST http://127.0.0.1:31415/api/shutdown
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
  cmp "$TEST_ROOT/expected.service" "$unit"
  [ -f "$TEST_ROOT/service-enabled" ]
  [ -f "$TEST_ROOT/service-active" ]
  [[ "$output" == *"PI_WEBUI_SERVICE_ENABLED=1"* ]]
  [[ "$output" == *"PI_WEBUI_SERVICE_ACTIVE=1"* ]]
  local verify_line reload_line enable_line
  verify_line=$(grep -n '^systemd-analyze --user verify ' "$TEST_COMMAND_LOG" | cut -d: -f1)
  reload_line=$(grep -n '^systemctl --user daemon-reload$' "$TEST_COMMAND_LOG" | cut -d: -f1)
  enable_line=$(grep -n '^systemctl --user enable --now pi-webui.service$' "$TEST_COMMAND_LOG" | cut -d: -f1)
  [ "$verify_line" -lt "$reload_line" ]
  [ "$reload_line" -lt "$enable_line" ]
}

@test "installer rolls back when detailed health exposes network-open or wrong Pi cwd identity" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  # shellcheck disable=SC2089 # Exported JSON is consumed as data, not shell syntax.
  PI_WEBUI_TEST_STATUS_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":true,"urls":["http://lan"]},"tabs":[{"cwd":"/foreign","running":true,"command":"/foreign/pi --mode rpc"}]}}'
  # shellcheck disable=SC2090
  export PI_WEBUI_TEST_STATUS_JSON
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"detailed status validation failed"* ]]
  [ ! -e "$state/runtimes/current" ]
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
}

@test "installer accepts a stable listener descended from the service MainPID" {
  make_installer_repo
  make_valid_platform
  printf '%s\n' '0::/user.slice/foreign.service' >"$PROC_ROOT/4201/cgroup"
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
}

@test "installer accepts a wrapper listener in the exact service cgroup" {
  make_installer_repo
  make_valid_platform
  printf '%b\n' 'Name:\tnode' 'PPid:\t1' >"$PROC_ROOT/4201/status"
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
}

@test "installer rejects expected Web UI JSON from a foreign loopback listener" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  : >"$TEST_ROOT/spoof-listener"
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"listener is not owned by the active Pi Web UI service"* ]]
  [ ! -e "$state/runtimes/current" ]
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
}

@test "installer rolls back a non-loopback listener and leaves no orphan" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  : >"$TEST_ROOT/wildcard-listener"
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"listener is not confined to exact loopback"* ]]
  [ ! -e "$state/runtimes/current" ]
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ "$(grep -c '^process-check' "$TEST_COMMAND_LOG")" -ge 2 ]
}

@test "installer rolls back runtime unit worktree and active enabled state after health failure" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local state="$HOME/.local/share/pi-webui"
  local worktree="$state/worktrees/dotfiles"
  PI_WEBUI_TEST_STATUS_JSON=$(printf \
    '{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"host":"127.0.0.1","port":31415,"open":false,"urls":[]},"tabs":[{"cwd":"%s","running":true,"command":"%s --mode rpc"}]}}' \
    "$worktree" "$PI_TEST_LAUNCHER")
  export PI_WEBUI_TEST_STATUS_JSON
  run_installer --apply
  [ "$status" -eq 0 ]

  local unit="$HOME/.config/systemd/user/pi-webui.service"
  local runtime="$state/runtimes/current"
  local old_head old_unit old_runtime
  old_head=$(git -C "$worktree" rev-parse HEAD)
  old_unit=$(sha256sum "$unit")
  old_runtime=$(file_tree_hashes "$runtime")
  printf 'next source\n' >"$INSTALLER_REPO/next-source"
  git -C "$INSTALLER_REPO" add next-source
  git -C "$INSTALLER_REPO" commit -qm next
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD
  : >"$TEST_ROOT/health-fail"
  export PI_WEBUI_TEST_HEALTH_ATTEMPTS=1

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"exact health check failed"* ]]
  [ "$old_unit" = "$(sha256sum "$unit")" ]
  [ "$old_runtime" = "$(file_tree_hashes "$runtime")" ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$old_head" ]
  [ -f "$TEST_ROOT/service-enabled" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -d "$state/transactions/pending" ]
  [ -d "$state/runtimes/candidate" ]
  [ "$(grep -c 'api/health' "$TEST_COMMAND_LOG")" -ge 3 ]
  [ "$(grep -c 'api/webui-status' "$TEST_COMMAND_LOG")" -ge 2 ]
  [ "$(grep -c '^ss -H -ltnp ' "$TEST_COMMAND_LOG")" -ge 2 ]
}

@test "installer refuses a symlinked systemd unit directory without writing through it" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local outside="$TEST_ROOT/foreign-unit-directory"
  mkdir -p "$HOME/.config/systemd" "$outside"
  ln -s "$outside" "$HOME/.config/systemd/user"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd user unit directory must be a real directory"* ]]
  [ -L "$HOME/.config/systemd/user" ]
  [ ! -e "$outside/pi-webui.service" ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
}

@test "installer refuses a symlinked backup tree before npm or service stop" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  local state="$HOME/.local/share/pi-webui"
  local outside="$TEST_ROOT/foreign-backups"
  rm -rf "$state/backups"
  mkdir -p "$outside"
  printf 'preserve foreign backup target\n' >"$outside/sentinel"
  ln -s "$outside" "$state/backups"
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi Web UI backup parent must be a real directory"* ]]
  [ -L "$state/backups" ]
  [ "$(cat "$outside/sentinel")" = 'preserve foreign backup target' ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ -f "$TEST_ROOT/service-active" ]
}

@test "installer refuses a group-writable backup parent before npm or service stop" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  local backups="$HOME/.local/share/pi-webui/backups"
  chmod 0770 "$backups"
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi Web UI backup parent must not be group or world writable"* ]]
  [ "$(stat -c '%a' "$backups")" = 770 ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ -f "$TEST_ROOT/service-active" ]
}

@test "installer refuses a managed unit whose current runtime is missing" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  rm -rf "$HOME/.local/share/pi-webui/runtimes/current"
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"managed Pi Web UI unit runtime is missing"* ]]
  [ -f "$TEST_ROOT/service-active" ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
}

@test "installer refuses a foreign current runtime before npm or service mutation" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local runtime="$HOME/.local/share/pi-webui/runtimes/current"
  mkdir -p "$runtime"
  chmod 0700 "$runtime"
  printf 'foreign runtime\n' >"$runtime/sentinel"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"current runtime is not an owned Pi Web UI artifact"* ]]
  [ "$(cat "$runtime/sentinel")" = 'foreign runtime' ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
}

@test "installer refuses an inactive foreign loaded unit before npm" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  printf '%s\n' /usr/lib/systemd/user/pi-webui.service >"$TEST_ROOT/fragment-path"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"loaded Pi Web UI service unit is foreign"* ]]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
}

@test "installer surfaces rollback failure and retains post-stop evidence" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  : >"$TEST_ROOT/health-fail"
  : >"$TEST_ROOT/fail-rollback-start"
  export PI_WEBUI_TEST_HEALTH_ATTEMPTS=1
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -eq 78 ]
  [[ "$output" == *"service rollback failed; candidate and transaction evidence retained"* ]]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
  [ -f "$state/transactions/pending/prior-unit" ]
  [ "$(cat "$state/transactions/pending/prior-active")" = 1 ]
  [ "$(cat "$state/transactions/pending/prior-enabled")" = 1 ]
}

@test "installer treats rollback start success without activation as rollback failure" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  : >"$TEST_ROOT/health-fail"
  : >"$TEST_ROOT/rollback-start-inactive"
  export PI_WEBUI_TEST_HEALTH_ATTEMPTS=1
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -eq 78 ]
  [[ "$output" == *"service rollback failed; candidate and transaction evidence retained"* ]]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
  [ -f "$state/transactions/pending/prior-unit" ]
  local rollback_start_line active_probe_line
  rollback_start_line=$(grep -n '^systemctl --user start pi-webui.service$' \
    "$TEST_COMMAND_LOG" | tail -n1 | cut -d: -f1)
  active_probe_line=$(awk -v start="$rollback_start_line" \
    'NR > start && $0 == "systemctl --user is-active --quiet pi-webui.service" { print NR; exit }' \
    "$TEST_COMMAND_LOG")
  [ -n "$active_probe_line" ]
}

@test "installer refuses a foreign unit before npm or service stop" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local unit="$HOME/.config/systemd/user/pi-webui.service"
  mkdir -p "$(dirname "$unit")"
  printf '[Service]\nExecStart=/bin/false\n' >"$unit"
  chmod 0600 "$unit"
  : >"$TEST_ROOT/service-active"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"existing Pi Web UI unit is foreign"* ]]
  [ "$(cat "$unit")" = $'[Service]\nExecStart=/bin/false' ]
  run ! grep -q '^npm-ci$\|^systemctl --user stop' "$TEST_COMMAND_LOG"
}

@test "installer leaves an active service untouched when owner-only candidate unit verification fails" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  local state="$HOME/.local/share/pi-webui"
  local runtime_before
  runtime_before=$(file_tree_hashes "$state/runtimes/current")
  : >"$TEST_ROOT/fail-unit-verify"
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$runtime_before" = "$(file_tree_hashes "$state/runtimes/current")" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
}

@test "installer validates candidate runtime and unit before stopping an active managed service" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  instrument_validator
  run_installer --apply
  [ "$status" -eq 0 ]
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -eq 0 ]
  local candidate="$HOME/.local/share/pi-webui/runtimes/candidate"
  local validator_line verify_line stop_line
  validator_line=$(grep -n "^validator --installed-runtime $candidate$" "$TEST_COMMAND_LOG" | cut -d: -f1)
  verify_line=$(grep -n '^systemd-analyze --user verify ' "$TEST_COMMAND_LOG" | cut -d: -f1)
  stop_line=$(grep -n '^systemctl --user stop pi-webui.service$' "$TEST_COMMAND_LOG" | head -n1 | cut -d: -f1)
  [ "$validator_line" -lt "$stop_line" ]
  [ "$verify_line" -lt "$stop_line" ]
}

@test "installer preserves a previously disabled inactive managed service after verification" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  rm -f "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ "$(grep -c '^systemctl --user start pi-webui.service$' "$TEST_COMMAND_LOG")" -eq 1 ]
  [ "$(grep -c '^systemctl --user stop pi-webui.service$' "$TEST_COMMAND_LOG")" -eq 1 ]
  [ "$(grep -c '^process-check' "$TEST_COMMAND_LOG")" -ge 2 ]
}

@test "installer rejects service template policy drift before stopping" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  node - "$INSTALLER_REPO/ai/pi/webui/pi-webui.service.in" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];
fs.writeFileSync(path, fs.readFileSync(path, 'utf8').replace('Restart=on-failure', 'Restart=always'));
NODE
  git -C "$INSTALLER_REPO" add ai/pi/webui/pi-webui.service.in
  git -C "$INSTALLER_REPO" commit -qm 'invalid service policy'
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"service template SHA-256"* ]]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "installer rejects unknown service template tokens before stopping" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  printf '\nEnvironment=UNKNOWN=@BOGUS_PATH@\n' \
    >>"$INSTALLER_REPO/ai/pi/webui/pi-webui.service.in"
  git -C "$INSTALLER_REPO" add ai/pi/webui/pi-webui.service.in
  git -C "$INSTALLER_REPO" commit -qm 'invalid service token'
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"unresolved tokens"* ]]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "installer rejects a systemd dollar path before stopping the service" {
  HOME="$TEST_ROOT/home\$unsafe"
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME"
  export HOME XDG_CONFIG_HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd expansion character (\$)"* ]]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "installer rejects a systemd percent path before stopping the service" {
  HOME="$TEST_ROOT/home%unsafe"
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME"
  export HOME XDG_CONFIG_HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd specifier character (%)"* ]]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "installer rejects a newline systemd path before stopping the service" {
  HOME="$TEST_ROOT/"$'home\nunsafe'
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME"
  export HOME XDG_CONFIG_HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"contains a newline"* ]]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ ! -e "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "successful trial migration retains the exact legacy runtime in the previous backup" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  make_trial_unit_and_runtime
  local state="$HOME/.local/share/pi-webui"
  local trial="$HOME/.local/share/pi-webui-runtime"
  local retained="$state/backups/previous/accepted-trial-runtime"
  local runtime_before
  runtime_before=$(directory_fingerprint "$trial")

  run_installer --apply

  [ "$status" -eq 0 ]
  [ ! -e "$trial" ]
  [ -d "$retained" ]
  [ ! -L "$retained" ]
  [ "$runtime_before" = "$(directory_fingerprint "$retained")" ]
  [ -f "$state/runtimes/current/.pi-webui-current" ]
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]

  : >"$TEST_COMMAND_LOG"
  run_installer --apply

  [ "$status" -eq 0 ]
  [ ! -e "$trial" ]
  [ -d "$retained" ]
  [ "$runtime_before" = "$(directory_fingerprint "$retained")" ]
  [ "$(grep -c '^npm-ci$' "$TEST_COMMAND_LOG")" -eq 1 ]
}

@test "trial stage failure validates the unstaged runtime and restores the old service" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  make_trial_unit_and_runtime
  local state="$HOME/.local/share/pi-webui"
  local trial="$HOME/.local/share/pi-webui-runtime"
  local runtime_before
  runtime_before=$(directory_fingerprint "$trial")
  TEST_BEFORE_TRIAL_STAGE_HOOK="$TEST_ROOT/fail-trial-stage"
  cat >"$TEST_BEFORE_TRIAL_STAGE_HOOK" <<'SCRIPT'
#!/usr/bin/env bash
: >"$TEST_ROOT/trial-stage-hook-observed"
chmod 0500 "$HOME/.local/share/pi-webui/backups"
SCRIPT
  chmod +x "$TEST_BEFORE_TRIAL_STAGE_HOOK"
  export TEST_BEFORE_TRIAL_STAGE_HOOK

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$status" -ne 78 ]
  [ -f "$TEST_ROOT/trial-stage-hook-observed" ]
  [ -d "$trial" ]
  [ "$runtime_before" = "$(directory_fingerprint "$trial")" ]
  [ ! -e "$state/runtimes/current" ]
  [ ! -e "$state/worktrees/dotfiles" ]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
  [ "$(grep -c '^systemctl --user start pi-webui.service$' "$TEST_COMMAND_LOG")" -eq 1 ]
}

@test "migration health failure restores the exact accepted trial unit runtime and cwd" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  make_trial_unit_and_runtime
  local unit="$HOME/.config/systemd/user/pi-webui.service"
  local trial="$HOME/.local/share/pi-webui-runtime"
  local unit_before runtime_before
  unit_before=$(file_tree_hashes "$(dirname "$unit")")
  runtime_before=$(file_tree_hashes "$trial")
  : >"$TEST_ROOT/health-fail"
  : >"$TEST_ROOT/expect-trial-runtime-moved"
  export PI_WEBUI_TEST_HEALTH_ATTEMPTS=1

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$status" -ne 78 ]
  [[ "$output" == *"exact health check failed"* ]]
  [[ "$PI_TEST_LAUNCHER" != "$HOME/.local/share/mise/installs/node/26.5.0/bin/pi" ]]
  [ -f "$TEST_ROOT/trial-runtime-move-observed" ]
  [ -f "$TEST_ROOT/trial-runtime-restored-before-start" ]
  [ "$unit_before" = "$(file_tree_hashes "$(dirname "$unit")")" ]
  [ "$runtime_before" = "$(file_tree_hashes "$trial")" ]
  grep -Fq -- '--cwd /home/tng/.dotfiles/tmp/worktrees/piface-smoke' "$unit"
  grep -Fq -- '%h/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui' "$unit"
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/current" ]
  [ ! -e "$HOME/.local/share/pi-webui/worktrees/dotfiles" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ -d "$HOME/.local/share/pi-webui/transactions/pending" ]
  run ! grep -qi 'tailscale\|serve\|funnel' "$TEST_COMMAND_LOG"
}

@test "installer restores the old service when clean stop detects a scoped orphan" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  run_installer --apply
  [ "$status" -eq 0 ]
  local state="$HOME/.local/share/pi-webui"
  local worktree="$state/worktrees/dotfiles"
  local old_runtime old_head
  old_runtime=$(file_tree_hashes "$state/runtimes/current")
  old_head=$(git -C "$worktree" rev-parse HEAD)
  cat >"$PROCESS_CHECK" <<'SCRIPT'
#!/usr/bin/env bash
printf 'process-check %s\n' "$*" >>"$TEST_COMMAND_LOG"
[[ -f "$TEST_ROOT/service-active" ]]
SCRIPT
  chmod +x "$PROCESS_CHECK"

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$old_runtime" = "$(file_tree_hashes "$state/runtimes/current")" ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$old_head" ]
  [ -f "$TEST_ROOT/service-active" ]
  [ -f "$TEST_ROOT/service-enabled" ]
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
}

@test "installer rejects systems other than Ubuntu 24.04 Noble before mutation" {
  local os_release="$TEST_ROOT/os-release"
  printf 'ID=ubuntu\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\n' >"$os_release"
  local before after
  before=$(find "$TEST_ROOT" -mindepth 1 -printf '%y %m %P -> %l\n' | sort)

  run env PI_WEBUI_TESTING=1 PI_WEBUI_TEST_OS_RELEASE="$os_release" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" HOME="$HOME" PATH="$PATH" \
    bash "$REPO_ROOT/ai/pi/webui/install.sh" --check

  after=$(find "$TEST_ROOT" -mindepth 1 -printf '%y %m %P -> %l\n' | sort)
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires Ubuntu 24.04 Noble under WSL"* ]]
  [ "$before" = "$after" ]
}

@test "installer rejects a non-WSL kernel and unavailable systemd user manager" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_command uname 'printf "%s\\n" "6.8.0-generic"'

  run_installer --check

  [ "$status" -ne 0 ]
  [[ "$output" == *"requires Ubuntu 24.04 Noble under WSL"* ]]
  [ ! -e "$HOME/.local/share/pi-webui" ]

  stub_command uname 'printf "%s\\n" "6.6.87.2-microsoft-standard-WSL2"'
  stub_command systemctl 'exit 1'
  run_installer --check

  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd user manager is unavailable"* ]]
  [ ! -e "$HOME/.local/share/pi-webui" ]
}

@test "installer check resolves the exact mise Pi owner and is mutation-free" {
  make_installer_repo
  make_valid_platform
  make_valid_pi

  run_installer --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"PI_WEBUI_MODE=check"* ]]
  [[ "$output" == *"PI_WEBUI_PI_LAUNCHER=$PI_TEST_LAUNCHER"* ]]
  [[ "$output" == *"PI_WEBUI_CANDIDATE_RUNTIME=$HOME/.local/share/pi-webui/runtimes/candidate"* ]]
  [[ "$output" == *"PI_WEBUI_WORKTREE=$HOME/.local/share/pi-webui/worktrees/dotfiles"* ]]
  [[ "$output" == *"would create detached worktree at $SOURCE_HEAD"* ]]
  [ ! -e "$HOME/.local/share/pi-webui" ]
  [ -z "$(git -C "$INSTALLER_REPO" status --porcelain --untracked-files=all)" ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"
}

@test "installer rejects the wrong Pi owner or version before npm and mutation" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.3","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_TEST_PACKAGE/package.json"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"must be @earendil-works/pi-coding-agent@0.84.4"* ]]
  [ ! -e "$HOME/.local/share/pi-webui" ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"
}

@test "installer test platform override cannot be enabled accidentally" {
  make_installer_repo
  make_valid_platform
  make_valid_pi

  run env PI_WEBUI_TEST_OS_RELEASE="$TEST_OS_RELEASE" HOME="$HOME" PATH="$PATH" \
    bash "$INSTALLER" --check

  [ "$status" -ne 0 ]
  [[ "$output" == *"restricted to the test sandbox"* ]]
  [ ! -e "$HOME/.local/share/pi-webui" ]
}

@test "installer refuses a symlink or foreign durable worktree before npm" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")" "$TEST_ROOT/symlink target"
  ln -s "$TEST_ROOT/symlink target" "$worktree"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"durable worktree must not be a symbolic link"* ]]
  [ -L "$worktree" ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"

  rm "$worktree"
  mkdir -p "$worktree"
  git -C "$worktree" init -q
  git -C "$worktree" config user.name 'Foreign Test'
  git -C "$worktree" config user.email 'foreign@example.test'
  : >"$worktree/foreign"
  git -C "$worktree" add foreign
  git -C "$worktree" commit -qm foreign

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"durable worktree belongs to a foreign repository"* ]]
  [ -f "$worktree/foreign" ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"
}

@test "installer refuses the source primary checkout as the durable target" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  mv "$INSTALLER_REPO" "$worktree"
  git -C "$worktree" worktree add --detach "$TEST_ROOT/installer runner" -q
  INSTALLER_REPO="$TEST_ROOT/installer runner"
  INSTALLER="$INSTALLER_REPO/ai/pi/webui/install.sh"
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export INSTALLER_REPO INSTALLER SOURCE_HEAD

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"durable worktree must not be the primary checkout"* ]]
  [ -d "$worktree/.git" ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"
}

@test "installer refuses attached and dirty linked worktrees without changing them" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  git -C "$INSTALLER_REPO" worktree add -q -b task2-attached "$worktree" HEAD

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"durable worktree must be detached"* ]]
  [ "$(git -C "$worktree" symbolic-ref --short HEAD)" = task2-attached ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"

  git -C "$INSTALLER_REPO" worktree remove "$worktree"
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" HEAD
  printf 'preserve dirty worktree\n' >"$worktree/untracked sentinel"

  run_installer --check

  [ "$status" -ne 0 ]
  [[ "$output" == *"durable worktree must be clean, including untracked and ignored files"* ]]
  [ "$(cat "$worktree/untracked sentinel")" = 'preserve dirty worktree' ]
  run ! grep -q '^mise exec -- npm ci' "$TEST_COMMAND_LOG"
}

@test "installer apply validates first, uses exact npm ci flags, and consumes its Task 3 inputs" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  instrument_validator
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -eq 0 ]
  local install_output=$output
  local candidate="$state/runtimes/candidate"
  local runtime="$state/runtimes/current"
  local worktree="$state/worktrees/dotfiles"
  local transaction="$state/transactions/pending"
  cmp "$INSTALLER_REPO/ai/pi/webui/runtime/package.json" "$runtime/package.json"
  cmp "$INSTALLER_REPO/ai/pi/webui/runtime/package-lock.json" "$runtime/package-lock.json"
  [ "$(cat "$TEST_ROOT/npm-args")" = "$(printf '%s\n' ci --prefix "$candidate" --ignore-scripts --omit=optional)" ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$SOURCE_HEAD" ]
  run ! git -C "$worktree" symbolic-ref -q HEAD
  [ ! -e "$transaction" ]
  [ ! -e "$candidate" ]
  [ "$(stat -c '%a' "$state")" = 700 ]
  [ "$(stat -c '%a' "$state/runtimes")" = 700 ]
  [ ! -e "$state/transactions/apply.lock" ]
  [[ "$install_output" == *"PI_WEBUI_MODE=apply"* ]]
  [[ "$install_output" == *"PI_WEBUI_RUNTIME=$runtime"* ]]
  [ "$(grep -n '^validator --tracked-only$' "$TEST_COMMAND_LOG" | cut -d: -f1)" -lt \
    "$(grep -n '^npm-ci$' "$TEST_COMMAND_LOG" | cut -d: -f1)" ]
  [ "$(grep -c '^npm-ci$' "$TEST_COMMAND_LOG")" -eq 1 ]
  run ! grep -Eq 'pi install|npx|npm install' "$TEST_COMMAND_LOG"
  [ "$(grep -c '^systemctl --user enable --now pi-webui.service$' "$TEST_COMMAND_LOG")" -eq 1 ]
}

@test "installer updates a clean detached worktree and records its prior commit" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  local previous=$SOURCE_HEAD
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" "$previous"
  printf 'new source commit\n' >"$INSTALLER_REPO/new-file"
  git -C "$INSTALLER_REPO" add new-file
  git -C "$INSTALLER_REPO" commit -qm update
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD

  run_installer --apply

  [ "$status" -eq 0 ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$SOURCE_HEAD" ]
  run ! git -C "$worktree" symbolic-ref -q HEAD
  [ -z "$(git -C "$worktree" status --porcelain --untracked-files=all --ignored=matching)" ]
  [ "$(cat "$HOME/.local/share/pi-webui/backups/previous/worktree-previous-head")" = "$previous" ]
  [ "$(cat "$HOME/.local/share/pi-webui/backups/previous/worktree-head")" = "$SOURCE_HEAD" ]
}

@test "installer supports source, Pi, HOME, candidate, and worktree paths with spaces" {
  HOME="$TEST_ROOT/home with spaces"
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME"
  export HOME XDG_CONFIG_HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -eq 0 ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/current" ]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ -d "$HOME/.local/share/pi-webui/worktrees/dotfiles" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/pending" ]
  [ -f "$HOME/.config/systemd/user/pi-webui.service" ]
}

@test "installer removes a candidate whose lock is mutated by npm and leaves live state untouched" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  cat >>"$STUB_BIN/npm" <<'SCRIPT'
printf '\n' >>"$prefix/package-lock.json"
SCRIPT
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate lock changed during npm ci"* ]]
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
  [ ! -e "$state/worktrees/dotfiles" ]
  [ ! -e "$state/runtimes/current" ]
  [ "$(grep -c '^npm-ci$' "$TEST_COMMAND_LOG")" -eq 1 ]
}

@test "installer cleans a partial candidate when npm ci fails" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  cat >"$STUB_BIN/npm" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' '11.6.2'
  exit 0
fi
printf 'npm-ci\n' >>"$TEST_COMMAND_LOG"
prefix=$3
mkdir -p "$prefix/node_modules/partial-install"
printf 'partial\n' >"$prefix/node_modules/partial-install/sentinel"
exit 47
SCRIPT
  chmod +x "$STUB_BIN/npm"
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -eq 47 ]
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
  [ ! -e "$state/worktrees/dotfiles" ]
}

@test "installer preserves and rejects an unowned stale candidate before npm" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local candidate="$HOME/.local/share/pi-webui/runtimes/candidate"
  mkdir -p "$candidate"
  printf 'foreign candidate\n' >"$candidate/sentinel"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"stale candidate runtime is not an owned Pi Web UI artifact"* ]]
  [ "$(cat "$candidate/sentinel")" = 'foreign candidate' ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
}

@test "installer check preserves recognized stale transaction inputs" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  local state="$HOME/.local/share/pi-webui"
  local candidate="$state/runtimes/candidate"
  local transaction="$state/transactions/pending"
  mkdir -p "$candidate" "$transaction"
  printf '%s\n' pi-webui-task2-candidate-v1 >"$candidate/.pi-webui-candidate"
  printf 'stale candidate\n' >"$candidate/sentinel"
  printf '%s\n' pi-webui-task2-transaction-v1 >"$transaction/.pi-webui-transaction"
  printf 'stale transaction\n' >"$transaction/sentinel"
  local candidate_before transaction_before
  candidate_before=$(find "$candidate" -type f -exec sha256sum {} + | sort)
  transaction_before=$(find "$transaction" -type f -exec sha256sum {} + | sort)

  run_installer --check

  [ "$status" -eq 0 ]
  [ "$candidate_before" = "$(find "$candidate" -type f -exec sha256sum {} + | sort)" ]
  [ "$transaction_before" = "$(find "$transaction" -type f -exec sha256sum {} + | sort)" ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
}

@test "installer restores the prior detached commit when worktree update reports failure" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  local previous=$SOURCE_HEAD
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" "$previous"
  printf 'new source commit\n' >"$INSTALLER_REPO/new-file"
  git -C "$INSTALLER_REPO" add new-file
  git -C "$INSTALLER_REPO" commit -qm update
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD
  cat >"$STUB_BIN/git" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == -C && "$2" == "$HOME/.local/share/pi-webui/worktrees/dotfiles" &&
  "$3" == checkout && "$4" == --detach ]]; then
  /usr/bin/git "$@"
  exit 48
fi
exec /usr/bin/git "$@"
SCRIPT
  chmod +x "$STUB_BIN/git"

  run_installer --apply

  [ "$status" -eq 48 ]
  [ "$(/usr/bin/git -C "$worktree" rev-parse HEAD)" = "$previous" ]
  run ! /usr/bin/git -C "$worktree" symbolic-ref -q HEAD
  [ -z "$(/usr/bin/git -C "$worktree" status --porcelain --untracked-files=all --ignored=matching)" ]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/pending" ]
}

@test "installer refuses an ignored file that a source update would start tracking" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  printf 'future-file\n' >"$INSTALLER_REPO/.gitignore"
  git -C "$INSTALLER_REPO" add .gitignore
  git -C "$INSTALLER_REPO" commit -qm 'ignore future file'
  local previous
  previous=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" "$previous"
  printf 'preserve local ignored content\n' >"$worktree/future-file"
  : >"$INSTALLER_REPO/.gitignore"
  printf 'tracked source content\n' >"$INSTALLER_REPO/future-file"
  git -C "$INSTALLER_REPO" add .gitignore future-file
  git -C "$INSTALLER_REPO" commit -qm 'track future file'

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"must be clean, including untracked and ignored files"* ]]
  [ "$(cat "$worktree/future-file")" = 'preserve local ignored content' ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$previous" ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
}

@test "repeated apply consumes each invocation's own candidate and pending transaction" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply
  [ "$status" -eq 0 ]

  local state="$HOME/.local/share/pi-webui"
  local candidate="$state/runtimes/candidate"
  local transaction="$state/transactions/pending"
  local worktree="$state/worktrees/dotfiles"
  [ ! -e "$candidate" ]
  [ ! -e "$transaction" ]
  local head_before runtime_before unit_before
  head_before=$(git -C "$worktree" rev-parse HEAD)
  runtime_before=$(directory_fingerprint "$state/runtimes/current")
  unit_before=$(sha256sum "$HOME/.config/systemd/user/pi-webui.service")
  unit_before=${unit_before%% *}
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -eq 0 ]
  [ ! -e "$candidate" ]
  [ ! -e "$transaction" ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$head_before" ]
  [ -z "$(git -C "$worktree" status --porcelain --untracked-files=all --ignored=matching)" ]
  [ "$(grep -c '^npm-ci$' "$TEST_COMMAND_LOG")" -eq 1 ]
  [ "$runtime_before" = "$(directory_fingerprint "$state/runtimes/previous")" ]
  [ "$unit_before" = "$(sha256sum "$state/backups/previous/prior-unit" | cut -d' ' -f1)" ]
  [ "$(cat "$state/backups/previous/prior-runtime-kind")" = managed ]
  [ "$(cat "$state/backups/previous/prior-active")" = 1 ]
  [ "$(cat "$state/backups/previous/prior-enabled")" = 1 ]
  [ "$(stat -c '%a' "$state/backups/previous")" = 700 ]
}

@test "installer surfaces failed rollback and retains candidate transaction evidence" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  local previous=$SOURCE_HEAD
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" "$previous"
  printf 'new source commit\n' >"$INSTALLER_REPO/new-file"
  git -C "$INSTALLER_REPO" add new-file
  git -C "$INSTALLER_REPO" commit -qm update
  SOURCE_HEAD=$(git -C "$INSTALLER_REPO" rev-parse HEAD)
  export SOURCE_HEAD
  cat >"$STUB_BIN/git" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == -C && "$2" == "$HOME/.local/share/pi-webui/worktrees/dotfiles" &&
  "$3" == checkout && "$4" == --detach ]]; then
  if [[ "$5" == "$SOURCE_HEAD" ]]; then
    /usr/bin/git "$@"
    exit 48
  fi
  exit 49
fi
exec /usr/bin/git "$@"
SCRIPT
  chmod +x "$STUB_BIN/git"

  run_installer --apply

  [ "$status" -eq 75 ]
  [[ "$output" == *"worktree rollback failed; candidate and transaction evidence retained"* ]]
  [ "$(/usr/bin/git -C "$worktree" rev-parse HEAD)" = "$SOURCE_HEAD" ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ "$(cat "$HOME/.local/share/pi-webui/transactions/pending/worktree-previous-head")" = "$previous" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/apply.lock" ]
}

@test "installer refuses symlink non-directory and foreign apply lock collisions" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local transactions="$HOME/.local/share/pi-webui/transactions"
  local lock="$transactions/apply.lock"
  local outside="$TEST_ROOT/foreign lock target"
  local kind
  mkdir -p "$transactions" "$outside"
  printf 'preserve foreign lock\n' >"$outside/sentinel"

  for kind in symlink file foreign-directory; do
    rm -rf "$lock"
    case "$kind" in
      symlink) ln -s "$outside" "$lock" ;;
      file) printf 'preserve lock file\n' >"$lock" ;;
      foreign-directory)
        mkdir "$lock"
        printf 'foreign\n' >"$lock/sentinel"
        ;;
    esac
    : >"$TEST_COMMAND_LOG"

    run_installer --apply

    [ "$status" -ne 0 ]
    [[ "$output" == *"apply lock"* ]]
    run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
    case "$kind" in
      symlink)
        [ -L "$lock" ]
        [ "$(cat "$outside/sentinel")" = 'preserve foreign lock' ]
        ;;
      file) [ "$(cat "$lock")" = 'preserve lock file' ] ;;
      foreign-directory) [ "$(cat "$lock/sentinel")" = foreign ] ;;
    esac
  done
}

@test "installer refuses an existing owned apply lock repeatedly without cleaning it" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local lock="$HOME/.local/share/pi-webui/transactions/apply.lock"
  mkdir -p "$lock"
  printf '%s\n' pi-webui-task2-lock-v1 >"$lock/.pi-webui-lock"
  printf '%s\n' other-process-token >"$lock/.pi-webui-owner"
  local before
  before=$(file_tree_hashes "$lock")

  run_installer --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"apply lock is already held"* ]]
  [ "$before" = "$(file_tree_hashes "$lock")" ]

  run_installer --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"apply lock is already held"* ]]
  [ "$before" = "$(file_tree_hashes "$lock")" ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
}

@test "installer validates its transaction metadata before worktree or service mutation" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  TEST_AFTER_NPM_HOOK="$TEST_ROOT/mutate-transaction"
  cat >"$TEST_AFTER_NPM_HOOK" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$TEST_ROOT/foreign-runtime" \
  >"$HOME/.local/share/pi-webui/transactions/pending/candidate-runtime"
SCRIPT
  chmod +x "$TEST_AFTER_NPM_HOOK"
  export TEST_AFTER_NPM_HOOK
  local state="$HOME/.local/share/pi-webui"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"transaction metadata changed"* ]]
  [ ! -e "$state/worktrees/dotfiles" ]
  run ! grep -q '^systemctl --user stop' "$TEST_COMMAND_LOG"
  [ -d "$state/runtimes/candidate" ]
  [ -d "$state/transactions/pending" ]
}

@test "installer revalidates worktree cleanliness after npm before mutation" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local worktree="$HOME/.local/share/pi-webui/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" HEAD
  TEST_AFTER_NPM_HOOK="$TEST_ROOT/after-npm-hook"
  cat >"$TEST_AFTER_NPM_HOOK" <<'SCRIPT'
#!/usr/bin/env bash
printf 'post-preflight dirtiness\n' >"$HOME/.local/share/pi-webui/worktrees/dotfiles/post-preflight"
SCRIPT
  chmod +x "$TEST_AFTER_NPM_HOOK"
  export TEST_AFTER_NPM_HOOK
  local head_before
  head_before=$(git -C "$worktree" rev-parse HEAD)

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"must be clean, including untracked and ignored files"* ]]
  [ "$(cat "$worktree/post-preflight")" = 'post-preflight dirtiness' ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$head_before" ]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/pending" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/apply.lock" ]
}

@test "installer never removes an apply lock whose ownership token changes" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  TEST_AFTER_NPM_HOOK="$TEST_ROOT/replace-lock-owner"
  cat >"$TEST_AFTER_NPM_HOOK" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' foreign-process-token >"$HOME/.local/share/pi-webui/transactions/apply.lock/.pi-webui-owner"
SCRIPT
  chmod +x "$TEST_AFTER_NPM_HOOK"
  export TEST_AFTER_NPM_HOOK
  local lock="$HOME/.local/share/pi-webui/transactions/apply.lock"

  run_installer --apply

  [ "$status" -eq 76 ]
  [[ "$output" == *"owned apply lock changed; refusing cleanup"* ]]
  [[ "$output" == *"apply lock cleanup failed; transaction evidence retained"* ]]
  [ "$(cat "$lock/.pi-webui-owner")" = foreign-process-token ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ -d "$HOME/.local/share/pi-webui/transactions/pending" ]
}

@test "installer after-npm seam is unavailable outside its Bats sandbox" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local hook="$TEST_ROOT/forbidden-after-npm-hook"
  cat >"$hook" <<'SCRIPT'
#!/usr/bin/env bash
printf 'hook ran\n' >"$HOME/hook-ran"
SCRIPT
  chmod +x "$hook"

  run env -u PI_WEBUI_TESTING -u BATS_TEST_TMPDIR \
    PI_WEBUI_TEST_AFTER_NPM_HOOK="$hook" HOME="$HOME" PATH="$PATH" \
    TEST_COMMAND_LOG="$TEST_COMMAND_LOG" PI_TEST_LAUNCHER="$PI_TEST_LAUNCHER" \
    bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"PI_WEBUI_TEST_AFTER_NPM_HOOK is restricted to the test sandbox"* ]]
  [ ! -e "$HOME/hook-ran" ]
  [ ! -e "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ ! -e "$HOME/.local/share/pi-webui/transactions/apply.lock" ]
}

@test "installer preserves a pending handoff that appears before lock acquisition" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  local state="$HOME/.local/share/pi-webui"
  local candidate="$state/runtimes/candidate"
  local transaction="$state/transactions/pending"
  local worktree="$state/worktrees/dotfiles"
  mkdir -p "$(dirname "$worktree")"
  git -C "$INSTALLER_REPO" worktree add -q --detach "$worktree" HEAD
  local head_before
  head_before=$(git -C "$worktree" rev-parse HEAD)
  TEST_BEFORE_LOCK_HOOK="$TEST_ROOT/before-lock-handoff"
  cat >"$TEST_BEFORE_LOCK_HOOK" <<'SCRIPT'
#!/usr/bin/env bash
set -e
candidate="$HOME/.local/share/pi-webui/runtimes/candidate"
transaction="$HOME/.local/share/pi-webui/transactions/pending"
mkdir -p "$candidate" "$transaction"
printf '%s\n' pi-webui-task2-candidate-v1 >"$candidate/.pi-webui-candidate"
printf 'preserve candidate handoff\n' >"$candidate/sentinel"
printf '%s\n' pi-webui-task2-transaction-v1 >"$transaction/.pi-webui-transaction"
printf 'preserve transaction handoff\n' >"$transaction/sentinel"
find "$candidate" -type f -exec sha256sum {} + | sort >"$TEST_ROOT/candidate-before-lock"
find "$transaction" -type f -exec sha256sum {} + | sort >"$TEST_ROOT/transaction-before-lock"
SCRIPT
  chmod +x "$TEST_BEFORE_LOCK_HOOK"
  export TEST_BEFORE_LOCK_HOOK

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"pending transaction already exists; Task 3 must consume or discard it explicitly"* ]]
  [ "$(cat "$TEST_ROOT/candidate-before-lock")" = "$(file_tree_hashes "$candidate")" ]
  [ "$(cat "$TEST_ROOT/transaction-before-lock")" = "$(file_tree_hashes "$transaction")" ]
  [ "$(cat "$candidate/sentinel")" = 'preserve candidate handoff' ]
  [ "$(cat "$transaction/sentinel")" = 'preserve transaction handoff' ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$head_before" ]
  [ -z "$(git -C "$worktree" status --porcelain --untracked-files=all --ignored=matching)" ]
  [ ! -e "$state/transactions/apply.lock" ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
}

make_public_target_fixture() {
  PUBLIC_TARGET_REPO="$TEST_ROOT/repository path with spaces"
  PUBLIC_TARGET_LOG="$TEST_ROOT/public-targets.log"
  mkdir -p "$PUBLIC_TARGET_REPO/ai/pi/webui" "$PUBLIC_TARGET_REPO/bin"
  cp "$REPO_ROOT/Makefile" "$PUBLIC_TARGET_REPO/Makefile"
  : >"$PUBLIC_TARGET_LOG"
  export PUBLIC_TARGET_REPO PUBLIC_TARGET_LOG

  local helper
  for helper in install.sh tailscale.sh; do
    cat >"$PUBLIC_TARGET_REPO/ai/pi/webui/$helper" <<'SCRIPT'
#!/usr/bin/bash -p
[[ $- == *p* ]] || exit 126
printf '%s|%s\n' "${0##*/}" "$*" >>"$PUBLIC_TARGET_LOG"
SCRIPT
    chmod +x "$PUBLIC_TARGET_REPO/ai/pi/webui/$helper"
  done
  cat >"$PUBLIC_TARGET_REPO/bin/validate-pi-webui" <<'SCRIPT'
#!/usr/bin/bash -p
[[ $- == *p* ]] || exit 126
printf '%s|%s\n' "${0##*/}" "$*" >>"$PUBLIC_TARGET_LOG"
SCRIPT
  chmod +x "$PUBLIC_TARGET_REPO/bin/validate-pi-webui"
}

@test "public Make targets invoke Web UI interfaces directly and support spaced repository paths" {
  make_public_target_fixture

  run make -C "$PUBLIC_TARGET_REPO" ai-webui
  [ "$status" -eq 0 ]
  [ "$(cat "$PUBLIC_TARGET_LOG")" = 'install.sh|--apply' ]

  : >"$PUBLIC_TARGET_LOG"
  run make -C "$PUBLIC_TARGET_REPO" ai-webui-check
  [ "$status" -eq 0 ]
  [[ "$output" == *'installed runtime absent; skipping installed-runtime validation'* ]]
  [ "$(cat "$PUBLIC_TARGET_LOG")" = "$(printf '%s\n' \
    'validate-pi-webui|--tracked-only' \
    'install.sh|--check' \
    'tailscale.sh|check')" ]

  mkdir -p "$HOME/.local/share/pi-webui/runtimes/current"
  : >"$PUBLIC_TARGET_LOG"
  run make -C "$PUBLIC_TARGET_REPO" ai-webui-check
  [ "$status" -eq 0 ]
  [ "$(cat "$PUBLIC_TARGET_LOG")" = "$(printf '%s\n' \
    'validate-pi-webui|--tracked-only' \
    "validate-pi-webui|--installed-runtime $HOME/.local/share/pi-webui/runtimes/current" \
    'install.sh|--check' \
    'tailscale.sh|check')" ]
}

@test "public Web UI targets do not add sudo or alter normal AI and global orchestration" {
  run make -n -C "$REPO_ROOT" ai-webui ai-webui-check
  [ "$status" -eq 0 ]
  [[ "$output" != *'bash ./ai/pi/webui/'* ]]
  [[ "$output" != *'bash ai/pi/webui/'* ]]
  [[ "$output" != *sudo* ]]

  run grep -F 'check: syntax lint test python-test validate' "$REPO_ROOT/Makefile"
  [ "$status" -eq 0 ]
  run grep -F 'test:' "$REPO_ROOT/Makefile"
  [[ "$output" == *'test:'* ]]
  run make -n -C "$REPO_ROOT" ai ai-check
  [ "$status" -eq 0 ]
  [[ "$output" != *'ai/pi/webui/'* ]]
  run grep -F 'ai/pi/webui' "$REPO_ROOT/bin/install"
  [ "$status" -eq 1 ]
}

@test "Pi Web UI runbook documents exact setup order trust boundaries and accepted limits" {
  local readme="$REPO_ROOT/ai/pi/webui/README.md"
  [ -f "$readme" ]

  local previous=0 line command
  for command in \
    'make ai' \
    'make ai-webui-check' \
    './ai/pi/webui/tailscale.sh install' \
    './ai/pi/webui/tailscale.sh up' \
    'make ai-webui' \
    './ai/pi/webui/tailscale.sh serve'; do
    line=$(grep -nFx "$command" "$readme" | head -n1 | cut -d: -f1)
    [ -n "$line" ]
    [ "$line" -gt "$previous" ]
    previous=$line
  done
  line=$(grep -nFx 'make ai-webui-check' "$readme" | tail -n1 | cut -d: -f1)
  [ "$line" -gt "$previous" ]

  local phrase
  for phrase in \
    'Ubuntu 24.04 Noble under WSL' \
    'full WSL-account control' \
    'trusted devices only' \
    '127.0.0.1:31415' \
    'Funnel' \
    'network-open' \
    'auth keys or secrets' \
    'permission system is unchanged' \
    '.local/share/pi-webui/worktrees/dotfiles' \
    'linked worktree' \
    'run-level Abort is unavailable while a permission modal is open' \
    'Deny/Cancel' \
    'fresh tab' \
    'manually resume' \
    'installed runtime absent' \
    'Tailscale Funnel status shares the Serve graph'; do
    run grep -Fi "$phrase" "$readme"
    [ "$status" -eq 0 ]
  done
}

@test "Pi Web UI runbook pins identity and documents operations migration and rollback exactly" {
  local readme="$REPO_ROOT/ai/pi/webui/README.md"
  local phrase
  for phrase in \
    '@firstpick/pi-package-webui` `0.10.3' \
    '@earendil-works/pi-coding-agent` `0.84.4' \
    '39593de061e22a36668a0a0d1449e339b84e644d6c65e6b1618af9d177fc71d0' \
    'npm ci --ignore-scripts --omit=optional' \
    'do not use the browser self-update' \
    'accepted trial runtime' \
    'evaluation-2026-09-02.md' \
    'settings, supervisor state, transcripts, Tailscale identity, trial evidence, and backups' \
    'Tailscale identity state'; do
    run grep -Fi "$phrase" "$readme"
    [ "$status" -eq 0 ]
  done

  local command
  for command in \
    'systemctl --user status pi-webui.service' \
    'systemctl --user stop pi-webui.service' \
    'systemctl --user start pi-webui.service' \
    "curl --fail --silent http://127.0.0.1:31415/api/health" \
    "journalctl --user -u pi-webui.service -n 150 --no-pager" \
    './ai/pi/webui/tailscale.sh serve-off' \
    './ai/pi/webui/rollback.sh' \
    './ai/pi/webui/rollback.sh --remove-runtime' \
    './ai/pi/webui/rollback.sh --remove-worktree' \
    './ai/pi/webui/rollback.sh --remove-runtime --remove-worktree' \
    './ai/pi/webui/tailscale.sh uninstall'; do
    run grep -Fx "$command" "$readme"
    [ "$status" -eq 0 ]
  done
}

@test "public docs link to the single Pi Web UI operations runbook" {
  run grep -F 'ai/pi/webui/README.md' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  run grep -F 'pi/webui/README.md' "$REPO_ROOT/ai/README.md"
  [ "$status" -eq 0 ]
  run grep -F 'make ai-webui' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  run grep -F 'make ai-webui-check' "$REPO_ROOT/ai/README.md"
  [ "$status" -eq 0 ]
}

@test "every documented Pi Web UI helper action is declared by mutation-free help" {
  local readme="$REPO_ROOT/ai/pi/webui/README.md"
  local helper action help_output

  for helper in install.sh tailscale.sh rollback.sh; do
    run "$REPO_ROOT/ai/pi/webui/$helper" --help
    if [[ "$helper" == install.sh ]]; then
      [ "$status" -eq 2 ]
    else
      [ "$status" -eq 0 ]
    fi
    help_output=$output
    while IFS= read -r action; do
      [[ "$help_output" == *"$action"* ]]
    done < <(grep -oE "\./ai/pi/webui/$helper( [^[:space:]\x60]+)*" "$readme" |
      awk '{for (field = 2; field <= NF; field++) print $field}' | sort -u)
  done
}
