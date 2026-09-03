#!/usr/bin/env bats

load test_helper

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

mutate_json() {
  local file=$1 mutation=$2
  node - "$file" "$mutation" <<'NODE'
const fs = require('node:fs');
const [file, mutation] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const webui = 'node_modules/@firstpick/pi-package-webui';
const hardened = 'node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-agent-core';
switch (mutation) {
  case 'manifest-version': value.dependencies['@firstpick/pi-package-webui'] = '0.10.4'; break;
  case 'manifest-scripts': value.scripts = {postinstall: 'false'}; break;
  case 'manifest-optionals': value.optionalDependencies = {foo: '1.0.0'}; break;
  case 'lock-version': value.lockfileVersion = 2; break;
  case 'lock-root-version': value.packages[''].dependencies['@firstpick/pi-package-webui'] = '0.10.4'; break;
  case 'lock-root-scripts': value.packages[''].scripts = {postinstall: 'false'}; break;
  case 'lock-root-optionals': value.packages[''].optionalDependencies = {foo: '1.0.0'}; break;
  case 'firstpick-integrity': value.packages[webui].integrity = 'sha512-AAAAAAAA'; break;
  case 'missing-integrity': delete value.packages['node_modules/bowser'].integrity; break;
  case 'non-sha512-integrity': value.packages['node_modules/bowser'].integrity = 'sha1-AAAAAAAA'; break;
  case 'non-registry': value.packages['node_modules/bowser'].resolved = 'https://example.com/bowser.tgz'; break;
  case 'link': value.packages['node_modules/bowser'] = {resolved: '../bowser', link: true}; break;
  case 'hardened-integrity': value.packages[hardened].integrity = 'sha512-AAAAAAAA'; break;
  case 'hash-drift': value.requires = false; break;
  default: throw new Error(`unknown mutation: ${mutation}`);
}
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
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

@test "validator rejects a wrong Firstp1ck lock version" {
  make_runtime_fixture
  mutate_json "$FIXTURE_RUNTIME/package-lock.json" lock-root-version

  run bash "$REPO_ROOT/bin/validate-pi-webui" --tracked-only "$FIXTURE_RUNTIME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"lock root dependency must be exactly @firstpick/pi-package-webui@0.10.3"* ]]
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

@test "installed mode accepts exact package identities and launchers" {
  make_installed_fixture

  run bash "$REPO_ROOT/bin/validate-pi-webui" --installed-runtime "$FIXTURE_RUNTIME"

  [ "$status" -eq 0 ]
}

@test "installed mode rejects a prohibited node-pty installation" {
  make_installed_fixture
  mkdir -p "$FIXTURE_RUNTIME/node_modules/node-pty"

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
