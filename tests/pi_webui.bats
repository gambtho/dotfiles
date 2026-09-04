#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  WEBUI_FIXTURE="$TEST_ROOT/repo"
  INSTALLED_RUNTIME="$TEST_ROOT/installed-runtime"
  export PI_WEBUI_TESTING=1
  export PI_WEBUI_TEST_OS_RELEASE="$TEST_ROOT/os-release"
  export PI_WEBUI_TEST_UNAME_RELEASE='6.6.0-microsoft-standard-WSL2'
  export PI_WEBUI_TEST_SOURCE_ROOT="$WEBUI_FIXTURE"
}

make_webui_fixture() {
  mkdir -p "$WEBUI_FIXTURE/ai/pi/webui/runtime" "$WEBUI_FIXTURE/bin"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package.json" \
    "$WEBUI_FIXTURE/ai/pi/webui/runtime/package.json"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package-lock.json" \
    "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json"
  cp "$REPO_ROOT/bin/validate-pi-webui" "$WEBUI_FIXTURE/bin/validate-pi-webui"
  chmod +x "$WEBUI_FIXTURE/bin/validate-pi-webui"
}

make_installed_runtime() {
  mkdir -p \
    "$INSTALLED_RUNTIME/node_modules/.bin" \
    "$INSTALLED_RUNTIME/node_modules/@firstpick/pi-package-webui/bin" \
    "$INSTALLED_RUNTIME/node_modules/@earendil-works/pi-coding-agent/dist/bundle"
  cp "$WEBUI_FIXTURE/ai/pi/webui/runtime/package.json" "$INSTALLED_RUNTIME/package.json"
  cp "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json" "$INSTALLED_RUNTIME/package-lock.json"
  printf '%s\n' \
    '{"name":"@firstpick/pi-package-webui","version":"0.10.3","bin":{"pi-webui":"./bin/pi-webui-launcher.mjs"}}' \
    >"$INSTALLED_RUNTIME/node_modules/@firstpick/pi-package-webui/package.json"
  printf '#!/usr/bin/env node\n' \
    >"$INSTALLED_RUNTIME/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
  chmod +x "$INSTALLED_RUNTIME/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
  ln -s ../@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs \
    "$INSTALLED_RUNTIME/node_modules/.bin/pi-webui"
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$INSTALLED_RUNTIME/node_modules/@earendil-works/pi-coding-agent/package.json"
  printf '#!/usr/bin/env node\n' \
    >"$INSTALLED_RUNTIME/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
  chmod +x "$INSTALLED_RUNTIME/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
}

run_webui_validator() {
  run "$WEBUI_FIXTURE/bin/validate-pi-webui" "$@"
}

@test "validator accepts only the exact tracked runtime" {
  make_webui_fixture
  run_webui_validator --tracked-only
  [ "$status" -eq 0 ]
  printf x >>"$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json"
  run_webui_validator --tracked-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"lock SHA-256"* ]]
}

@test "installed validation proves identities and omits node-pty" {
  make_webui_fixture
  make_installed_runtime
  run_webui_validator --installed-runtime "$INSTALLED_RUNTIME"
  [ "$status" -eq 0 ]
  mkdir -p "$INSTALLED_RUNTIME/node_modules/node-pty"
  run_webui_validator --installed-runtime "$INSTALLED_RUNTIME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"node-pty must not be installed"* ]]
}
