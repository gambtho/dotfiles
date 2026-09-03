#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

ACCEPTED_MANIFEST_SHA256=073ba87cad124eb709eb8cafdd77c44c10b5d12bf5841acea140a50ac5177763
ACCEPTED_LOCK_SHA256=39593de061e22a36668a0a0d1449e339b84e644d6c65e6b1618af9d177fc71d0

setup() {
  setup_dotfiles_test
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
  stub_command systemctl '
if [[ "$1 ${2:-}" == "--user show-environment" ]]; then
  printf "systemd-user\\n" >>"$TEST_COMMAND_LOG"
  exit 0
fi
printf "unexpected systemctl: %s\\n" "$*" >&2
exit 90'
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
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" HOME="$HOME" PATH="$PATH" \
    TEST_COMMAND_LOG="$TEST_COMMAND_LOG" PI_TEST_LAUNCHER="$PI_TEST_LAUNCHER" \
    INSTALLER_REPO="$INSTALLER_REPO" bash "$INSTALLER" "$@"
}

file_tree_hashes() {
  find "$1" -type f -exec sha256sum {} + | sort
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
  "$prefix/node_modules/@firstpick/pi-package-webui/bin" \
  "$prefix/node_modules/@earendil-works/pi-coding-agent/dist/bundle"
printf '%s\n' \
  '{"name":"@firstpick/pi-package-webui","version":"0.10.3","bin":{"pi-webui":"./bin/pi-webui-launcher.mjs"}}' \
  >"$prefix/node_modules/@firstpick/pi-package-webui/package.json"
: >"$prefix/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
printf '%s\n' \
  '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
  >"$prefix/node_modules/@earendil-works/pi-coding-agent/package.json"
: >"$prefix/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
SCRIPT
  chmod +x "$STUB_BIN/npm"
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

@test "installer apply validates first, uses exact npm ci flags, and creates Task 3 inputs" {
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci
  instrument_validator
  local state="$HOME/.local/share/pi-webui"
  mkdir -p "$state/runtimes/current"
  printf 'live runtime remains\n' >"$state/runtimes/current/sentinel"

  run_installer --apply

  [ "$status" -eq 0 ]
  local install_output=$output
  local candidate="$state/runtimes/candidate"
  local worktree="$state/worktrees/dotfiles"
  local transaction="$state/transactions/pending"
  cmp "$INSTALLER_REPO/ai/pi/webui/runtime/package.json" "$candidate/package.json"
  cmp "$INSTALLER_REPO/ai/pi/webui/runtime/package-lock.json" "$candidate/package-lock.json"
  [ "$(cat "$TEST_ROOT/npm-args")" = "$(printf '%s\n' ci --prefix "$candidate" --ignore-scripts --omit=optional)" ]
  [ "$(cat "$state/runtimes/current/sentinel")" = 'live runtime remains' ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$SOURCE_HEAD" ]
  run ! git -C "$worktree" symbolic-ref -q HEAD
  [ "$(cat "$transaction/worktree-previous-head")" = ABSENT ]
  [ "$(cat "$transaction/source-head")" = "$SOURCE_HEAD" ]
  [ "$(cat "$transaction/pi-launcher")" = "$PI_TEST_LAUNCHER" ]
  [ "$(cat "$transaction/pi-real-executable")" = "$PI_TEST_REAL" ]
  [ "$(stat -c '%a' "$state")" = 700 ]
  [ "$(stat -c '%a' "$state/runtimes")" = 700 ]
  [ ! -e "$state/transactions/apply.lock" ]
  [[ "$install_output" == *"PI_WEBUI_MODE=apply"* ]]
  [[ "$install_output" == *"PI_WEBUI_TRANSACTION=$transaction"* ]]
  [ "$(grep -n '^validator --tracked-only$' "$TEST_COMMAND_LOG" | cut -d: -f1)" -lt \
    "$(grep -n '^npm-ci$' "$TEST_COMMAND_LOG" | cut -d: -f1)" ]
  [ "$(grep -c '^npm-ci$' "$TEST_COMMAND_LOG")" -eq 1 ]
  run ! grep -Eq 'pi install|npx|npm install|systemctl .* (stop|start|enable|disable|daemon-reload)' \
    "$TEST_COMMAND_LOG"
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
  [ "$(cat "$HOME/.local/share/pi-webui/transactions/pending/worktree-previous-head")" = "$previous" ]
  [ "$(cat "$HOME/.local/share/pi-webui/transactions/pending/worktree-head")" = "$SOURCE_HEAD" ]
}

@test "installer supports source, Pi, HOME, candidate, and worktree paths with spaces" {
  HOME="$TEST_ROOT/home with spaces"
  mkdir -p "$HOME"
  export HOME
  make_installer_repo
  make_valid_platform
  make_valid_pi
  stub_successful_npm_ci

  run_installer --apply

  [ "$status" -eq 0 ]
  [ -d "$HOME/.local/share/pi-webui/runtimes/candidate" ]
  [ -d "$HOME/.local/share/pi-webui/worktrees/dotfiles" ]
  [ "$(cat "$HOME/.local/share/pi-webui/transactions/pending/pi-launcher")" = "$PI_TEST_LAUNCHER" ]
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
  mkdir -p "$state/runtimes/current"
  printf 'keep live runtime\n' >"$state/runtimes/current/sentinel"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate lock changed during npm ci"* ]]
  [ ! -e "$state/runtimes/candidate" ]
  [ ! -e "$state/transactions/pending" ]
  [ ! -e "$state/worktrees/dotfiles" ]
  [ "$(cat "$state/runtimes/current/sentinel")" = 'keep live runtime' ]
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

@test "repeated apply refuses a valid pending transaction without changing evidence" {
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
  local candidate_before transaction_before head_before
  candidate_before=$(file_tree_hashes "$candidate")
  transaction_before=$(file_tree_hashes "$transaction")
  head_before=$(git -C "$worktree" rev-parse HEAD)
  : >"$TEST_COMMAND_LOG"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"pending transaction already exists; Task 3 must consume or discard it explicitly"* ]]
  [ "$candidate_before" = "$(file_tree_hashes "$candidate")" ]
  [ "$transaction_before" = "$(file_tree_hashes "$transaction")" ]
  [ "$(git -C "$worktree" rev-parse HEAD)" = "$head_before" ]
  [ -z "$(git -C "$worktree" status --porcelain --untracked-files=all --ignored=matching)" ]
  run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
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
      foreign-directory) mkdir "$lock"; printf 'foreign\n' >"$lock/sentinel" ;;
    esac
    : >"$TEST_COMMAND_LOG"

    run_installer --apply

    [ "$status" -ne 0 ]
    [[ "$output" == *"apply lock"* ]]
    run ! grep -q '^npm-ci$' "$TEST_COMMAND_LOG"
    case "$kind" in
      symlink) [ -L "$lock" ]; [ "$(cat "$outside/sentinel")" = 'preserve foreign lock' ] ;;
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
