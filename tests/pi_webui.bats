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
[[ "$1" == --user ]]
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
  export PI_TEST_PACKAGE PI_TEST_REAL PI_TEST_LAUNCHER
  cat >"$STUB_BIN/mise" <<'SCRIPT'
#!/usr/bin/env bash
set -e
printf 'mise %s\n' "$*" >>"$TEST_COMMAND_LOG"
if [[ "$1 ${2:-}" == "which pi" ]]; then
  printf '%s\n' "$PI_TEST_LAUNCHER"
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

make_installer_repo() {
  INSTALLER_REPO="$TEST_ROOT/source repo"
  mkdir -p "$INSTALLER_REPO/ai/pi/webui/runtime" "$INSTALLER_REPO/bin"
  cp "$REPO_ROOT/ai/pi/webui/install.sh" "$INSTALLER_REPO/ai/pi/webui/install.sh"
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
