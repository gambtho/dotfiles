#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  WEBUI_FIXTURE="$TEST_ROOT/repo"
  STATE_ROOT="$HOME/.local/share/pi-webui"
  INSTALLED_RUNTIME="$STATE_ROOT/runtime/current"
  LANDING_WORKTREE="$STATE_ROOT/worktrees/dotfiles"
  UNIT_PATH="$XDG_CONFIG_HOME/systemd/user/pi-webui.service"
  MUTATION_CALLS="$TEST_ROOT/mutation-calls"
  CALLS="$TEST_ROOT/calls"
  export WEBUI_FIXTURE STATE_ROOT INSTALLED_RUNTIME LANDING_WORKTREE UNIT_PATH MUTATION_CALLS CALLS
  : >"$CALLS"
  export PI_WEBUI_TESTING=1
  export PI_WEBUI_TEST_OS_RELEASE="$TEST_ROOT/os-release"
  export PI_WEBUI_TEST_UNAME_RELEASE='6.6.0-microsoft-standard-WSL2'
  export PI_WEBUI_TEST_SOURCE_ROOT="$WEBUI_FIXTURE"
  : >"$MUTATION_CALLS"
}

make_webui_fixture() {
  mkdir -p "$WEBUI_FIXTURE/ai/pi/webui/runtime" "$WEBUI_FIXTURE/bin"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package.json" \
    "$WEBUI_FIXTURE/ai/pi/webui/runtime/package.json"
  cp "$REPO_ROOT/ai/pi/webui/runtime/package-lock.json" \
    "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json"
  cp "$REPO_ROOT/bin/validate-pi-webui" "$WEBUI_FIXTURE/bin/validate-pi-webui"
  cp "$REPO_ROOT/ai/pi/webui/install.sh" "$WEBUI_FIXTURE/ai/pi/webui/install.sh"
  cp "$REPO_ROOT/ai/pi/webui/tailscale.sh" "$WEBUI_FIXTURE/ai/pi/webui/tailscale.sh"
  cp "$REPO_ROOT/ai/pi/webui/pi-webui.service.in" \
    "$WEBUI_FIXTURE/ai/pi/webui/pi-webui.service.in"
  chmod +x "$WEBUI_FIXTURE/bin/validate-pi-webui" "$WEBUI_FIXTURE/ai/pi/webui/"{install,tailscale}.sh
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$PI_WEBUI_TEST_OS_RELEASE"
  printf '.pi/\n' >"$WEBUI_FIXTURE/.gitignore"
  git -C "$WEBUI_FIXTURE" init -q -b main
  git -C "$WEBUI_FIXTURE" config user.name Test
  git -C "$WEBUI_FIXTURE" config user.email test@example.invalid
  git -C "$WEBUI_FIXTURE" add .
  git -C "$WEBUI_FIXTURE" commit -qm fixture
  git -C "$WEBUI_FIXTURE" remote add origin "$TEST_ROOT/origin.git"
  git -C "$WEBUI_FIXTURE" update-ref refs/remotes/origin/main HEAD
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

make_external_pi() {
  PI_PACKAGE="$TEST_ROOT/mise/installs/node/1/lib/node_modules/@earendil-works/pi-coding-agent"
  PI_LAUNCHER="$PI_PACKAGE/dist/bundle/cli.js"
  export PI_PACKAGE PI_LAUNCHER
  mkdir -p "$(dirname "$PI_LAUNCHER")"
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_PACKAGE/package.json"
  printf '#!/usr/bin/env node\n' >"$PI_LAUNCHER"
  chmod +x "$PI_LAUNCHER"
  stub_command mise 'if [[ "$1 $2" == "which pi" ]]; then printf "%s\\n" "$PI_LAUNCHER"; else exec "${@:4}"; fi'
  MISE_LAUNCHER="$STUB_BIN/mise"
  export MISE_LAUNCHER
}

make_landing_worktree() {
  mkdir -p "$(dirname "$LANDING_WORKTREE")"
  git -C "$WEBUI_FIXTURE" worktree add -q --detach "$LANDING_WORKTREE" HEAD
}

make_candidate_installer() {
  cat >"$TEST_ROOT/install-candidate" <<'EOF'
#!/usr/bin/env bash
set -e
runtime=$1
mkdir -p \
  "$runtime/node_modules/.bin" \
  "$runtime/node_modules/@firstpick/pi-package-webui/bin" \
  "$runtime/node_modules/@earendil-works/pi-coding-agent/dist/bundle"
printf '%s\n' \
  '{"name":"@firstpick/pi-package-webui","version":"0.10.3","bin":{"pi-webui":"./bin/pi-webui-launcher.mjs"}}' \
  >"$runtime/node_modules/@firstpick/pi-package-webui/package.json"
printf '#!/usr/bin/env node\n' \
  >"$runtime/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
chmod +x "$runtime/node_modules/@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs"
ln -s ../@firstpick/pi-package-webui/bin/pi-webui-launcher.mjs \
  "$runtime/node_modules/.bin/pi-webui"
printf '%s\n' \
  '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
  >"$runtime/node_modules/@earendil-works/pi-coding-agent/package.json"
printf '#!/usr/bin/env node\n' \
  >"$runtime/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
chmod +x "$runtime/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
EOF
  chmod +x "$TEST_ROOT/install-candidate"
}

prepare_apply_fixture() {
  local identity=$1
  make_webui_fixture
  make_external_pi
  make_candidate_installer
  printf '%s\n' "$identity" >"$WEBUI_FIXTURE/prior-release"
  git -C "$WEBUI_FIXTURE" add prior-release
  git -C "$WEBUI_FIXTURE" commit -qm "prior $identity"
  make_landing_worktree
  PRIOR_COMMIT=$(git -C "$LANDING_WORKTREE" rev-parse HEAD)
  export PRIOR_COMMIT
  printf '%s\n' "$identity" >"$WEBUI_FIXTURE/release"
  git -C "$WEBUI_FIXTURE" add release
  git -C "$WEBUI_FIXTURE" commit -qm "release $identity"
  git -C "$WEBUI_FIXTURE" update-ref refs/remotes/origin/main HEAD
  make_installed_runtime
  printf '%s\n' "$identity" >"$INSTALLED_RUNTIME/prior-$identity"
  write_expected_unit
  cp "$UNIT_PATH" "$TEST_ROOT/prior-unit"
}

stub_apply_system() {
  stub_command mise 'if [[ "$1 $2" == "which pi" ]]; then
    printf "%s\\n" "$PI_LAUNCHER"
  elif [[ "$1 $2 $3 $4 $5 $7 $8" == "exec -- npm ci --prefix --ignore-scripts --omit=optional" ]]; then
    printf "npm %s\\n" "$*" >>"$CALLS"
    bash "$TEST_ROOT/install-candidate" "$6"
  else
    exit 97
  fi'
  MISE_LAUNCHER="$STUB_BIN/mise"
  export MISE_LAUNCHER
  stub_command systemd-analyze 'printf "systemd-analyze %s\\n" "$*" >>"$CALLS"
    [[ ${FAIL_POINT:-} != candidate-verify ]]'
  stub_command systemctl 'printf "systemctl %s\\n" "$*" >>"$CALLS"
    case "$*" in
      "--user show-environment") exit 0 ;;
      "--user is-active pi-webui.service") [[ -f "$TEST_ROOT/service-active" ]] ;;
      "--user is-enabled pi-webui.service") [[ -f "$TEST_ROOT/service-enabled" ]] ;;
      "--user stop pi-webui.service")
        if [[ ${STRICT_UNLOADED:-} == 1 && ! -f "$TEST_ROOT/unit-loaded" ]]; then exit 1; fi
        rm -f "$TEST_ROOT/service-active" "$TEST_ROOT/candidate-running" ;;
      "--user start pi-webui.service")
        touch "$TEST_ROOT/service-active"
        if compgen -G "$INSTALLED_RUNTIME/prior-*" >/dev/null; then
          rm -f "$TEST_ROOT/candidate-running"
        else
          touch "$TEST_ROOT/candidate-running"
        fi ;;
      "--user enable pi-webui.service") touch "$TEST_ROOT/service-enabled" ;;
      "--user disable pi-webui.service")
        if [[ ${STRICT_UNLOADED:-} == 1 && ! -f "$TEST_ROOT/unit-loaded" ]]; then exit 1; fi
        rm -f "$TEST_ROOT/service-enabled" ;;
      "--user daemon-reload")
        if [[ ${FAIL_POINT:-} == daemon-reload && ! -e "$TEST_ROOT/failed-once" ]]; then
          touch "$TEST_ROOT/failed-once"
          exit 1
        fi
        if [[ ${STRICT_UNLOADED:-} == 1 ]]; then
          if [[ -f "$UNIT_PATH" ]]; then
            touch "$TEST_ROOT/unit-loaded"
          else
            rm -f "$TEST_ROOT/unit-loaded"
          fi
        fi ;;
      *) exit 96 ;;
    esac'
  stub_command ss 'if [[ -f "$TEST_ROOT/service-active" ]]; then
    printf "%s\\n" "LISTEN 0 128 127.0.0.1:31415 0.0.0.0:*"
  fi'
  stub_command curl 'if [[ ${FAIL_POINT:-} == health ]] &&
      ! compgen -G "$INSTALLED_RUNTIME/prior-*" >/dev/null; then
    exit 22
  fi
  printf "%s\\n" "$HEALTH_JSON"'
}

assert_prior_apply_state() {
  local identity=$1 expected_active=$2 expected_enabled=$3
  [ "$(git -C "$LANDING_WORKTREE" rev-parse HEAD)" = "$PRIOR_COMMIT" ]
  [ -f "$INSTALLED_RUNTIME/prior-$identity" ]
  cmp "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  if [ "$expected_active" -eq 1 ]; then
    [ -f "$TEST_ROOT/service-active" ]
  else
    [ ! -e "$TEST_ROOT/service-active" ]
  fi
  if [ "$expected_enabled" -eq 1 ]; then
    [ -f "$TEST_ROOT/service-enabled" ]
  else
    [ ! -e "$TEST_ROOT/service-enabled" ]
  fi
  [ ! -e "$TEST_ROOT/candidate-running" ]
}

stub_healthy_system() {
  if [[ -z ${HEALTH_JSON:-} ]]; then
    HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[{"cwd":"/tmp/another-project","running":true,"command":"'
    HEALTH_JSON+="$PI_LAUNCHER --mode rpc --session x"
    HEALTH_JSON+='"}]}}'
    export HEALTH_JSON
  fi
  stub_command systemctl 'case "$*" in
    "--user show-environment"|"--user is-active pi-webui.service") exit 0 ;;
    *) printf "%s\\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
  esac'
  stub_command ss 'printf "%s\\n" "LISTEN 0 128 127.0.0.1:31415 0.0.0.0:*"'
  stub_command curl 'printf "%s\\n" "$HEALTH_JSON"'
}

write_expected_unit() {
  mkdir -p "$(dirname "$UNIT_PATH")"
  cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Firstp1ck Pi Web UI remote interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$MISE_LAUNCHER exec -- $INSTALLED_RUNTIME/node_modules/.bin/pi-webui --host 127.0.0.1 --port 31415 --cwd $LANDING_WORKTREE --pi $PI_LAUNCHER --no-remote-auth --name pi-webui
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
}

fingerprint_paths() {
  local path
  for path in "$@"; do
    if [[ -e "$path" ]]; then
      find "$path" -printf '%P %y %m %s\n' | LC_ALL=C sort
      find "$path" -type f -exec /usr/bin/sha256sum {} + | LC_ALL=C sort
    else
      printf 'absent %s\n' "$path"
    fi
  done | /usr/bin/sha256sum | cut -d' ' -f1
}

run_webui_validator() {
  run "$WEBUI_FIXTURE/bin/validate-pi-webui" "$@"
}

run_installer() {
  run "$WEBUI_FIXTURE/ai/pi/webui/install.sh" "$@"
}

run_installer_function() {
  local body=$1
  run bash -c 'source "$1"; shift; eval "$1"' bash \
    "$WEBUI_FIXTURE/ai/pi/webui/install.sh" "$body"
}

write_route() {
  local mode=$1
  case "$mode" in
    empty)
      printf '{}\n' >"$TEST_ROOT/route.json"
      printf 'No serve config\n' >"$TEST_ROOT/route.txt"
      ;;
    exact)
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      printf 'https://wsl.test.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:31415\n' >"$TEST_ROOT/route.txt"
      ;;
    funnel)
      write_route exact
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":true}}' >"$TEST_ROOT/route.json"
      ;;
    foreign)
      write_route exact
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}},"AllowFunnel":{"wsl.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      ;;
    multiple)
      write_route exact
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"},"/other":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      ;;
  esac
  cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
}

stub_tailscale_system() {
  stub_healthy_system
  write_route "${1:-empty}"
  printf '%s\n' '{"BackendState":"Running","Self":{"Online":true}}' >"$TEST_ROOT/tailscale-status.json"
  stub_command systemctl 'case "$*" in
    "is-active tailscaled"|"--user show-environment"|"--user is-active pi-webui.service") exit 0 ;;
    *) printf "systemctl %s\\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
  esac'
  stub_command tailscale 'case "$*" in
    "status --json") cat "$TEST_ROOT/tailscale-status.json" ;;
    "serve status --json") cat "$TEST_ROOT/route.json" ;;
    "funnel status --json") cat "$TEST_ROOT/funnel.json" ;;
    "serve status") cat "$TEST_ROOT/route.txt" ;;
    *) exit 98 ;;
  esac'
  stub_command ip 'printf "%s\\n" \
    "2: eth1    inet 172.20.1.4/20 brd 172.20.15.255 scope global eth1" \
    "3: wlan0   inet 192.168.1.7/24 brd 192.168.1.255 scope global wlan0" \
    "4: tailscale0 inet 100.64.0.1/32 scope global tailscale0"'
  stub_command curl 'printf "curl %s\\n" "$*" >>"$CALLS"
    case " $* " in
      *" http://127.0.0.1:31415/api/health "*) printf "%s\\n" "$HEALTH_JSON" ;;
      *" -o "*)
        if [[ ${BAD_KEY_DOWNLOAD:-} == 1 ]]; then printf bad-key; else printf key-bytes; fi >"${@: -1}" ;;
      *) exit 7 ;;
    esac'
  stub_command sudo 'printf "sudo %s\\n" "$*" >>"$CALLS"
    case "$*" in
      "tailscale serve --bg --https=443 http://127.0.0.1:31415")
        printf "%s\\n" "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"wsl.test.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:31415\"}}}},\"AllowFunnel\":{\"wsl.test.ts.net:443\":false}}" >"$TEST_ROOT/route.json"
        cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
        printf "https://wsl.test.ts.net (tailnet only)\\n|-- / proxy http://127.0.0.1:31415\\n" >"$TEST_ROOT/route.txt" ;;
      "tailscale serve --https=443 off")
        if [[ ${SERVE_OFF_STICKS:-} != 1 ]]; then
          printf "{}\\n" >"$TEST_ROOT/route.json"
          cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
          printf "No serve config\\n" >"$TEST_ROOT/route.txt"
        fi ;;
      *"tailscale.list") printf "source %s\\n" "$(cat "${@: -2:1}")" >>"$CALLS" ;;
    esac'
  stub_command apt-get 'printf "apt-get %s\\n" "$*" >>"$CALLS"'
  stub_command sha256sum 'printf "sha256sum %s\\n" "$*" >>"$CALLS"
    actual=$(/usr/bin/sha256sum "$1" | cut -d" " -f1)
    good=$(printf key-bytes | /usr/bin/sha256sum | cut -d" " -f1)
    if [[ $actual == "$good" ]]; then
      actual=3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39
    fi
    printf "%s  %s\\n" "$actual" "$1"'
}

prepare_tailscale_check() {
  make_webui_fixture
  make_external_pi
  make_landing_worktree
  make_installed_runtime
  write_expected_unit
  stub_tailscale_system "${1:-empty}"
}

run_tailscale() {
  run "$WEBUI_FIXTURE/ai/pi/webui/tailscale.sh" "$@"
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

@test "installer refuses unsupported platforms before mutation" {
  mkdir -p "$WEBUI_FIXTURE/ai/pi/webui"
  cp "$REPO_ROOT/ai/pi/webui/install.sh" "$WEBUI_FIXTURE/ai/pi/webui/install.sh"
  chmod +x "$WEBUI_FIXTURE/ai/pi/webui/install.sh"
  printf 'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n' >"$PI_WEBUI_TEST_OS_RELEASE"
  before=$(fingerprint_paths "$HOME" "$WEBUI_FIXTURE" "$MUTATION_CALLS")
  run_installer --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ubuntu 24.04 Noble under WSL"* ]]
  after=$(fingerprint_paths "$HOME" "$WEBUI_FIXTURE" "$MUTATION_CALLS")
  [ "$before" = "$after" ]
}

@test "mutation fingerprints remain content-sensitive with command stubs" {
  make_webui_fixture
  stub_tailscale_system empty
  before=$(fingerprint_paths "$WEBUI_FIXTURE")
  printf changed >>"$WEBUI_FIXTURE/ai/pi/webui/runtime/package.json"
  after=$(fingerprint_paths "$WEBUI_FIXTURE")
  [ "$before" != "$after" ]
}

@test "installer check preserves pre-install informational state" {
  make_webui_fixture
  make_external_pi
  stub_tailscale_system empty
  stub_command systemctl 'case "$*" in
    "--user show-environment") exit 0 ;;
    *) exit 3 ;;
  esac'
  run_installer --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed runtime is absent"* ]]
  [[ "$output" == *"installed service unit is absent"* ]]
  [[ "$output" == *"tailscaled is not active"* ]]
  [[ "$output" != *"installed runtime is unavailable"* ]]
}

@test "installer check is mutation-free and accepts the healthy managed layout" {
  make_webui_fixture
  make_external_pi
  make_landing_worktree
  mkdir -p "$LANDING_WORKTREE/.pi/plans"
  make_installed_runtime
  write_expected_unit
  stub_tailscale_system empty
  before=$(fingerprint_paths "$HOME" "$WEBUI_FIXTURE" "$MUTATION_CALLS")
  run_installer --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tailscale state is valid"* ]]
  after=$(fingerprint_paths "$HOME" "$WEBUI_FIXTURE" "$MUTATION_CALLS")
  [ "$before" = "$after" ]

  rm "$UNIT_PATH"
  ln -s "$TEST_ROOT/missing-unit" "$UNIT_PATH"
  run_installer --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"service unit"* ]]
}

@test "installer refuses apply from a linked or non-origin-main checkout" {
  make_webui_fixture
  make_external_pi
  stub_healthy_system
  linked="$TEST_ROOT/review-worktree"
  git -C "$WEBUI_FIXTURE" worktree add -q --detach "$linked" HEAD
  export PI_WEBUI_TEST_SOURCE_ROOT="$linked"
  run "$linked/ai/pi/webui/install.sh" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical primary checkout"* ]]

  export PI_WEBUI_TEST_SOURCE_ROOT="$WEBUI_FIXTURE"
  printf changed >"$WEBUI_FIXTURE/new-file"
  git -C "$WEBUI_FIXTURE" add new-file
  git -C "$WEBUI_FIXTURE" commit -qm newer
  run_installer --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"origin/main"* ]]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "installer ordinary mode rejects a noncanonical primary checkout" {
  make_webui_fixture
  run_installer_function 'unset PI_WEBUI_TESTING PI_WEBUI_TEST_SOURCE_ROOT; resolve_source; validate_apply_source'
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical primary checkout"* ]]
}

@test "installer rejects a foreign or wrong-version Pi package launcher" {
  make_webui_fixture
  make_external_pi
  run_installer_function 'resolve_pi'
  [ "$status" -eq 0 ]

  printf '%s\n' \
    '{"name":"foreign-pi","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_PACKAGE/package.json"
  run_installer_function 'resolve_pi'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi launcher is not @earendil-works/pi-coding-agent@0.84.4"* ]]

  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.3","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_PACKAGE/package.json"
  run_installer_function 'resolve_pi'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi launcher is not @earendil-works/pi-coding-agent@0.84.4"* ]]
}

@test "landing worktree accepts clean detached state and empty .pi/plans" {
  make_webui_fixture
  make_landing_worktree
  run_installer_function 'resolve_source; validate_landing_worktree "$LANDING_WORKTREE"'
  [ "$status" -eq 0 ]
  mkdir -p "$LANDING_WORKTREE/.pi/plans"
  run_installer_function 'resolve_source; validate_landing_worktree "$LANDING_WORKTREE"'
  [ "$status" -eq 0 ]
}

@test "landing worktree refuses primary attached foreign and dirty state" {
  make_webui_fixture
  run_installer_function 'resolve_source; validate_landing_worktree "$WEBUI_FIXTURE"'
  [ "$status" -ne 0 ]

  attached="$TEST_ROOT/attached"
  git -C "$WEBUI_FIXTURE" worktree add -q -b fixture-branch "$attached" HEAD
  run_installer_function 'resolve_source; validate_landing_worktree "$TEST_ROOT/attached"'
  [ "$status" -ne 0 ]

  foreign="$TEST_ROOT/foreign"
  git init -q -b main "$foreign"
  run_installer_function 'resolve_source; validate_landing_worktree "$TEST_ROOT/foreign"'
  [ "$status" -ne 0 ]

  ln -s "$TEST_ROOT/missing-worktree" "$TEST_ROOT/worktree-link"
  run_installer_function 'resolve_source; validate_landing_worktree "$TEST_ROOT/worktree-link"'
  [ "$status" -ne 0 ]

  make_landing_worktree
  printf dirty >"$LANDING_WORKTREE/dirty"
  run_installer_function 'resolve_source; validate_landing_worktree "$LANDING_WORKTREE"'
  [ "$status" -ne 0 ]
}

@test "service template binds loopback and uses exact runtime worktree and Pi launchers" {
  make_webui_fixture
  make_external_pi
  run_installer_function 'resolve_source; resolve_mise; render_unit "$INSTALLED_RUNTIME/node_modules/.bin/pi-webui" "$LANDING_WORKTREE" "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStart=$MISE_LAUNCHER exec -- $INSTALLED_RUNTIME/node_modules/.bin/pi-webui --host 127.0.0.1 --port 31415 --cwd $LANDING_WORKTREE --pi $PI_LAUNCHER"* ]]
  [[ "$output" == *"POST http://127.0.0.1:31415/api/shutdown"* ]]
  [[ "$output" == *"WantedBy=default.target"* ]]
  [[ "$output" != *"0.0.0.0"* ]]
  [[ "$output" != *"Funnel"* ]]
  [[ "$output" != *"network-open"* ]]
  [[ "$output" != *"permission-system"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 19 ]

  run_installer_function 'resolve_source; MISE_LAUNCHER=/usr/bin/mise; render_unit "$INSTALLED_RUNTIME/node_modules/.bin/pi-webui" "$LANDING_WORKTREE" "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStart=/usr/bin/mise exec --"* ]]

  bad_path="$TEST_ROOT/bad%path"
  run_installer_function 'resolve_source; resolve_mise; render_unit "$bad_path" "$LANDING_WORKTREE" "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]
}

@test "active health permits empty tabs and project cwd tabs but rejects wrong launchers or open networking" {
  make_webui_fixture
  make_external_pi
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  stub_healthy_system
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]

  export HEALTH_JSON="{\"ok\":true,\"data\":{\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":false,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[{\"cwd\":\"/tmp/project\",\"running\":true,\"command\":\"$PI_LAUNCHER --mode rpc --session x\"}]}}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]

  export HEALTH_JSON="{\"ok\":true,\"data\":{\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":false,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[{\"cwd\":\"/tmp/project\",\"running\":true,\"command\":\"/wrong/pi --mode rpc\"}]}}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]

  export HEALTH_JSON="{\"ok\":true,\"data\":{\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":true,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[]}}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]
}

@test "active health rejects non-loopback or multiple listeners" {
  make_webui_fixture
  make_external_pi
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  stub_healthy_system

  stub_command ss 'printf "%s\\n" "LISTEN 0 128 0.0.0.0:31415 0.0.0.0:*"'
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"listener is not loopback-only"* ]]

  stub_command ss 'printf "%s\\n" "LISTEN 0 128 127.0.0.1:31415 0.0.0.0:*" "LISTEN 0 128 [::1]:31415 [::]:*"'
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one Pi Web UI listener"* ]]
}

@test "apply uses npm ci --ignore-scripts --omit=optional and preserves the lock" {
  prepare_apply_fixture npm-flags
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system
  before=$(sha256sum "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json")

  run_installer --apply

  [ "$status" -eq 0 ]
  grep -F "npm exec -- npm ci --prefix " "$CALLS"
  grep -F -- "--ignore-scripts --omit=optional" "$CALLS"
  after=$(sha256sum "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json")
  [ "$before" = "$after" ]
  [ -x "$INSTALLED_RUNTIME/node_modules/.bin/pi-webui" ]
  [ ! -e "$INSTALLED_RUNTIME/node_modules/node-pty" ]
}

@test "apply refuses a symlinked managed state directory before publication" {
  prepare_apply_fixture symlinked-state
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system
  mv "$STATE_ROOT" "$TEST_ROOT/state-target"
  ln -s "$TEST_ROOT/state-target" "$STATE_ROOT"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"state root must be a real directory"* ]]
  ! grep -F "systemd-analyze --user verify " "$CALLS"
  ! grep -F "systemctl --user stop pi-webui.service" "$CALLS"
  assert_prior_apply_state symlinked-state 1 1
}

@test "apply refuses a symlinked managed unit directory before publication" {
  prepare_apply_fixture symlinked-unit
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system
  mv "$(dirname "$UNIT_PATH")" "$TEST_ROOT/unit-target"
  ln -s "$TEST_ROOT/unit-target" "$(dirname "$UNIT_PATH")"

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"unit directory must be a real directory"* ]]
  ! grep -F "systemd-analyze --user verify " "$CALLS"
  ! grep -F "systemctl --user stop pi-webui.service" "$CALLS"
  assert_prior_apply_state symlinked-unit 1 1
}

@test "apply rejects unsafe rendered paths before verification or publication" {
  local unsafe label
  make_webui_fixture
  make_external_pi
  make_candidate_installer
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  stub_apply_system

  for label in percent dollar control; do
    case "$label" in
      percent) unsafe="$TEST_ROOT/data%unsafe" ;;
      dollar) unsafe="$TEST_ROOT/data\$unsafe" ;;
      control) unsafe="$TEST_ROOT/"$'data\nunsafe' ;;
    esac
    export XDG_DATA_HOME="$unsafe"
    export XDG_CONFIG_HOME="$TEST_ROOT/config-$label"
    STATE_ROOT="$XDG_DATA_HOME/pi-webui"
    INSTALLED_RUNTIME="$STATE_ROOT/runtime/current"
    LANDING_WORKTREE="$STATE_ROOT/worktrees/dotfiles"
    UNIT_PATH="$XDG_CONFIG_HOME/systemd/user/pi-webui.service"
    export STATE_ROOT INSTALLED_RUNTIME LANDING_WORKTREE UNIT_PATH
    : >"$CALLS"

    run_installer --apply

    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe path for systemd unit"* ]]
    ! grep -F "systemd-analyze --user verify " "$CALLS"
    ! grep -F "systemctl --user stop pi-webui.service" "$CALLS"
    [ ! -e "$INSTALLED_RUNTIME" ]
    [ ! -e "$UNIT_PATH" ]
  done
}

@test "apply validates candidate before stopping the managed service" {
  prepare_apply_fixture candidate-validation
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  export FAIL_POINT=candidate-verify
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  grep -F "systemd-analyze --user verify " "$CALLS"
  ! grep -F "systemctl --user stop pi-webui.service" "$CALLS"
  assert_prior_apply_state candidate-validation 1 1
}

@test "apply creates or advances only a clean detached landing worktree" {
  prepare_apply_fixture landing
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  stub_apply_system
  rm -rf "$LANDING_WORKTREE"
  git -C "$WEBUI_FIXTURE" worktree prune

  run_installer --apply

  [ "$status" -eq 0 ]
  ! git -C "$LANDING_WORKTREE" symbolic-ref -q HEAD
  [ "$(git -C "$LANDING_WORKTREE" rev-parse HEAD)" = "$(git -C "$WEBUI_FIXTURE" rev-parse refs/remotes/origin/main)" ]

  printf dirty >"$LANDING_WORKTREE/dirty"
  : >"$CALLS"
  run_installer --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"landing worktree must be clean"* ]]
  ! grep -F "systemctl --user stop pi-webui.service" "$CALLS"
}

@test "apply restores after runtime publication failure" {
  prepare_apply_fixture runtime-failure
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  export FAIL_POINT=runtime-publication
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system
  stub_command mv 'printf "mv %s\\n" "$*" >>"$CALLS"
    if [[ ${FAIL_POINT:-} == runtime-publication && $2 == "$INSTALLED_RUNTIME" && $1 != *prior-runtime ]]; then
      exit 1
    fi
    exec /usr/bin/mv "$@"'

  run_installer --apply

  [ "$status" -ne 0 ]
  grep -F "systemctl --user stop pi-webui.service" "$CALLS"
  grep -F "mv " "$CALLS"
  assert_prior_apply_state runtime-failure 1 1
}

@test "apply restores after unit or daemon-reload failure" {
  prepare_apply_fixture daemon-failure
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  export FAIL_POINT=daemon-reload
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$(grep -c 'systemctl --user daemon-reload' "$CALLS")" -eq 2 ]
  assert_prior_apply_state daemon-failure 1 1
}

@test "apply restores an absent prior installation after health failure" {
  prepare_apply_fixture absent-prior
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  export FAIL_POINT=health STRICT_UNLOADED=1
  rm -rf "$INSTALLED_RUNTIME"
  rm -f "$UNIT_PATH"
  git -C "$WEBUI_FIXTURE" worktree remove --force "$LANDING_WORKTREE"
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" != *"restoration failed"* ]]
  [ ! -e "$INSTALLED_RUNTIME" ]
  [ ! -e "$UNIT_PATH" ]
  [ ! -e "$LANDING_WORKTREE" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ "$(grep -c 'systemctl --user stop pi-webui.service' "$CALLS")" -eq 1 ]
  [ -z "$(find "$STATE_ROOT" -maxdepth 1 -name '.apply.*' -print -quit)" ]
  [ -z "$(find "$STATE_ROOT/runtime" -maxdepth 1 -name '.candidate.*' -print -quit)" ]
}

@test "apply restores prior commit enablement and activity after health failure" {
  prepare_apply_fixture health-failure
  export HEALTH_JSON='{"ok":true,"data":{"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}}'
  export FAIL_POINT=health
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  grep -F "systemctl --user start pi-webui.service" "$CALLS"
  assert_prior_apply_state health-failure 0 0
}

@test "tailscale check accepts empty or exact tailnet-only route" {
  prepare_tailscale_check empty
  run_tailscale check
  [ "$status" -eq 0 ]
  write_route exact
  run_tailscale check
  [ "$status" -eq 0 ]
  printf '  https://wsl.test.ts.net   (tailnet only)  \n  |--   /   proxy   http://127.0.0.1:31415  \n' >"$TEST_ROOT/route.txt"
  run_tailscale check
  [ "$status" -eq 0 ]
  printf 'https://wsl.test.ts.net\n|-- / proxy http://127.0.0.1:31415\n' >"$TEST_ROOT/route.txt"
  run_tailscale check
  [ "$status" -ne 0 ]
}

@test "Tailscale helper refuses Funnel foreign and multiple routes" {
  prepare_tailscale_check empty
  local mode
  for mode in funnel foreign multiple; do
    write_route "$mode"
    run_tailscale check
    [ "$status" -ne 0 ]
    [ ! -s "$MUTATION_CALLS" ]
  done
  write_route exact
  printf '{}\n' >"$TEST_ROOT/funnel.json"
  run_tailscale check
  [ "$status" -ne 0 ]
}

@test "tailscale serve publishes only HTTPS 443 to the loopback backend" {
  prepare_tailscale_check empty
  run_tailscale serve
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$CALLS"

  rm -rf "$INSTALLED_RUNTIME"
  : >"$CALLS"
  run_tailscale serve
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "tailscale serve-off removes only the exact owned route" {
  prepare_tailscale_check foreign
  run_tailscale serve-off
  [ "$status" -ne 0 ]
  ! grep -F 'sudo tailscale serve' "$CALLS"
  write_route exact
  export SERVE_OFF_STICKS=1
  run_tailscale serve-off
  [ "$status" -ne 0 ]
  [[ "$output" == *"route remains after removal"* ]]
  unset SERVE_OFF_STICKS
  printf '%s\n' '{"BackendState":"Running","Self":{"Online":false}}' >"$TEST_ROOT/tailscale-status.json"
  run_tailscale serve-off
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --https=443 off' "$CALLS"
}

@test "LAN detection excludes tailscale0 without assuming eth0" {
  prepare_tailscale_check empty
  run_tailscale check
  [ "$status" -eq 0 ]
  grep -F 'http://172.20.1.4:31415/' "$CALLS"
  grep -F 'http://192.168.1.7:31415/' "$CALLS"
  ! grep -F 'http://100.64.0.1:31415/' "$CALLS"

  stub_command curl 'case " $* " in
    *" http://127.0.0.1:31415/api/health "*) printf "%s\\n" "$HEALTH_JSON" ;;
    *" --fail "*) exit 22 ;;
    *) exit 0 ;;
  esac'
  run_tailscale check
  [ "$status" -ne 0 ]

  stub_command ip 'exit 4'
  run_tailscale check
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot inspect global IPv4 addresses"* ]]

  stub_command ip 'printf "%s\\n" "4: tailscale0 inet 100.64.0.1/32 scope global tailscale0"'
  run_tailscale check
  [ "$status" -ne 0 ]
  [[ "$output" == *"no non-Tailscale global IPv4 address"* ]]
}

@test "tailscale install verifies the Noble key before sudo publication" {
  make_webui_fixture
  stub_tailscale_system empty
  export PI_WEBUI_TAILSCALE_ROOT="$TEST_ROOT/system-root"
  mkdir -p "$PI_WEBUI_TAILSCALE_ROOT"
  run_tailscale install
  [ "$status" -eq 0 ]
  grep -F 'https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg' "$CALLS"
  sha_line=$(grep -n '^sha256sum ' "$CALLS" | cut -d: -f1)
  sudo_line=$(grep -n '^sudo install ' "$CALLS" | cut -d: -f1 | head -n 1)
  [ "$sha_line" -lt "$sudo_line" ]
  grep -F 'source deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main' "$CALLS"

  mkdir -p "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings"
  ln -s "$TEST_ROOT/missing-key" "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  : >"$CALLS"
  run_tailscale install
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]

  rm "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  printf foreign-key >"$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  : >"$CALLS"
  run_tailscale install
  [ "$status" -ne 0 ]
  ! grep -E '^(curl|sudo) ' "$CALLS"

  rm "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  export BAD_KEY_DOWNLOAD=1
  : >"$CALLS"
  run_tailscale install
  [ "$status" -ne 0 ]
  grep -F 'downloaded Tailscale key has the wrong SHA-256' <<<"$output"
  ! grep -E '^sudo ' "$CALLS"
}

@test "tailscale up is interactive and accepts no auth key" {
  make_webui_fixture
  stub_tailscale_system empty
  run_tailscale up
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale up' "$CALLS"
  run_tailscale up tskey-secret
  [ "$status" -eq 2 ]
  [ "$(grep -c '^sudo tailscale up$' "$CALLS")" -eq 1 ]
}

@test "tailscale uninstall preserves identity and refuses an active route" {
  make_webui_fixture
  stub_tailscale_system exact
  export PI_WEBUI_TAILSCALE_ROOT="$TEST_ROOT/system-root"
  mkdir -p "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings" "$PI_WEBUI_TAILSCALE_ROOT/etc/apt/sources.list.d" "$PI_WEBUI_TAILSCALE_ROOT/var/lib/tailscale"
  printf key-bytes >"$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main' >"$PI_WEBUI_TAILSCALE_ROOT/etc/apt/sources.list.d/tailscale.list"
  run_tailscale uninstall
  [ "$status" -ne 0 ]
  ! grep -F 'apt-get remove' "$CALLS"
  write_route empty
  printf '%s\n' '{"BackendState":"Running","Self":{"Online":false}}' >"$TEST_ROOT/tailscale-status.json"
  run_tailscale uninstall
  [ "$status" -eq 0 ]
  grep -F 'sudo apt-get remove --yes tailscale' "$CALLS"
  [[ "$(<"$CALLS")" != *purge* && "$(<"$CALLS")" != *logout* && "$(<"$CALLS")" != *var/lib/tailscale* ]]
}
