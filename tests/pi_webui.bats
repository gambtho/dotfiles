#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  WEBUI_FIXTURE="$TEST_ROOT/repo"
  STATE_ROOT="$HOME/.local/share/pi-webui"
  INSTALLED_RUNTIME="$STATE_ROOT/runtimes/current"
  LANDING_WORKTREE="$STATE_ROOT/worktrees/dotfiles"
  UNIT_PATH="$XDG_CONFIG_HOME/systemd/user/pi-webui.service"
  MUTATION_CALLS="$TEST_ROOT/mutation-calls"
  CREDENTIAL_CALLS="$TEST_ROOT/credential-calls"
  CALLS="$TEST_ROOT/calls"
  CADDY_ROOT="$TEST_ROOT/caddy-root"
  export WEBUI_FIXTURE STATE_ROOT INSTALLED_RUNTIME LANDING_WORKTREE UNIT_PATH MUTATION_CALLS CREDENTIAL_CALLS CALLS CADDY_ROOT
  export PI_WEBUI_CADDY_ROOT="$CADDY_ROOT"
  : >"$CALLS"
  export PI_WEBUI_TESTING=1
  export PI_WEBUI_TEST_OS_RELEASE="$TEST_ROOT/os-release"
  export PI_WEBUI_TEST_UNAME_RELEASE='6.6.0-microsoft-standard-WSL2'
  export PI_WEBUI_TEST_SOURCE_ROOT="$WEBUI_FIXTURE"
  : >"$MUTATION_CALLS"
  : >"$CREDENTIAL_CALLS"
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
  cp "$REPO_ROOT/ai/pi/webui/rollback.sh" "$WEBUI_FIXTURE/ai/pi/webui/rollback.sh"
  cp "$REPO_ROOT/ai/pi/webui/pi-webui.service.in" \
    "$WEBUI_FIXTURE/ai/pi/webui/pi-webui.service.in"
  cp "$REPO_ROOT/ai/pi/webui/Caddyfile.in" "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in"
  cp "$REPO_ROOT/ai/pi/webui/pi-webui-caddy.service.in" \
    "$WEBUI_FIXTURE/ai/pi/webui/pi-webui-caddy.service.in"
  cp "$REPO_ROOT/ai/pi/webui/caddy-entrypoint.sh" "$WEBUI_FIXTURE/ai/pi/webui/caddy-entrypoint.sh"
  cp "$REPO_ROOT/ai/pi/webui/custom-domain.sh" "$WEBUI_FIXTURE/ai/pi/webui/custom-domain.sh"
  chmod +x "$WEBUI_FIXTURE/bin/validate-pi-webui" \
    "$WEBUI_FIXTURE/ai/pi/webui/"{install,tailscale,rollback,caddy-entrypoint,custom-domain}.sh
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
  export HEALTH_JSON='{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}'
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
    HEALTH_JSON='{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[{"cwd":"/tmp/another-project","running":true,"command":"'
    HEALTH_JSON+="$PI_LAUNCHER --mode rpc --session x"
    HEALTH_JSON+='"}]}'
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
ExecStart=$MISE_LAUNCHER exec -- "$INSTALLED_RUNTIME/node_modules/.bin/pi-webui" --host 127.0.0.1 --port 31415 --cwd "$LANDING_WORKTREE" --pi "$PI_LAUNCHER" --no-remote-auth --name pi-webui
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

@test "installer exposes the shared managed paths" {
  make_webui_fixture
  run_installer_function 'set_managed_paths; printf "%s\n" "$STATE_ROOT|$INSTALLED_RUNTIME|$LANDING_WORKTREE|$RUNTIME_LAUNCHER|$UNIT_PATH"'
  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_ROOT|$STATE_ROOT/runtimes/current|$LANDING_WORKTREE|$STATE_ROOT/runtimes/current/node_modules/.bin/pi-webui|$UNIT_PATH" ]
}

write_route() {
  local mode=$1
  case "$mode" in
    empty)
      printf '{}\n' >"$TEST_ROOT/route.json"
      printf 'No serve config\n' >"$TEST_ROOT/route.txt"
      ;;
    legacy-exact)
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      printf 'https://wsl.test.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:31415\n' >"$TEST_ROOT/route.txt"
      ;;
    raw)
      printf '%s\n' \
        '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"}}}' \
        >"$TEST_ROOT/route.json"
      write_raw_human >"$TEST_ROOT/route.txt"
      ;;
    funnel)
      write_route legacy-exact
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":true}}' >"$TEST_ROOT/route.json"
      ;;
    foreign)
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"other.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"other.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      printf 'https://other.test.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:31415\n' >"$TEST_ROOT/route.txt"
      ;;
    multiple)
      write_route legacy-exact
      printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"},"/other":{"Proxy":"http://127.0.0.1:31415"}}}},"AllowFunnel":{"wsl.test.ts.net:443":false}}' >"$TEST_ROOT/route.json"
      ;;
  esac
  cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
}

# The exact human `tailscale serve status` tree Tailscale 1.102.3 prints for a
# node-level raw TCP forward on 443 (cmd/tailscale/cli/serve_legacy.go,
# printTCPStatusTree): a "|-- tcp://<host>:<port> (<funnel status>)" line, one
# "|-- tcp://<addr>:<port>" line per st.TailscaleIPs rendered through
# net.JoinHostPort (so IPv6 is bracketed), then "|--> tcp://<backend>".
write_raw_human() {
  printf '%s\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)' \
    '|-- tcp://100.64.0.1:443' \
    '|-- tcp://[fd7a:115c:a1e0::1]:443' \
    '|--> tcp://127.0.0.1:8443'
}

stub_tailscale_system() {
  stub_healthy_system
  write_route "${1:-empty}"
  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],"Self":{"Online":true,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]}}' >"$TEST_ROOT/tailscale-status.json"
  stub_command systemctl 'case "$*" in
    "is-active tailscaled"|"--user show-environment"|"--user is-active pi-webui.service") exit 0 ;;
    *) printf "systemctl %s\\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
  esac'
  stub_command tailscale 'case "$*" in
    "status --json")
      content=$(cat "$TEST_ROOT/tailscale-status.json")
      if [[ -n "${TAILSCALE_DAEMON_VERSION:-}" ]]; then
        content=${content/1.102.3/$TAILSCALE_DAEMON_VERSION}
      fi
      printf "%s\\n" "$content"
      ;;
    "version --json") printf "{\"short\":\"%s\"}\n" "${TAILSCALE_CLIENT_VERSION:-1.102.3}" ;;
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
      "tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443")
        printf "%s\\n" "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8443\"}}}" >"$TEST_ROOT/route.json"
        cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
        printf "%s\\n" "|-- tcp://wsl.test.ts.net:443 (tailnet only)" "|-- tcp://100.64.0.1:443" "|-- tcp://[fd7a:115c:a1e0::1]:443" "|--> tcp://127.0.0.1:8443" >"$TEST_ROOT/route.txt" ;;
      "tailscale serve --tcp=443 off")
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

run_tailscale_function() {
  local body=$1
  run bash -c 'source "$1"; shift; eval "$1"' bash \
    "$WEBUI_FIXTURE/ai/pi/webui/tailscale.sh" "$body"
}

run_custom_domain_function() {
  local body=$1
  run bash -c 'source "$1"; shift; eval "$1"' bash \
    "$WEBUI_FIXTURE/ai/pi/webui/custom-domain.sh" "$body"
}

run_custom_domain() {
  run "$WEBUI_FIXTURE/ai/pi/webui/custom-domain.sh" "$@"
}

# Writes exactly one DNS record type for every dig view (client resolver and
# every authoritative server alike, since the stub ignores @server and
# always answers from the same fixture files). Clears the other two types so
# each call represents one exact record shape.
write_dns() {
  local type=$1
  shift
  : >"$TEST_ROOT/dns-a"
  : >"$TEST_ROOT/dns-aaaa"
  : >"$TEST_ROOT/dns-cname"
  local file value
  case "$type" in
    A) file="$TEST_ROOT/dns-a" ;;
    AAAA) file="$TEST_ROOT/dns-aaaa" ;;
    CNAME) file="$TEST_ROOT/dns-cname" ;;
  esac
  for value in "$@"; do
    printf '%s\n' "$value" >>"$file"
  done
}

write_ns() {
  : >"$TEST_ROOT/dns-ns"
  local server
  for server in "$@"; do
    printf '%s\n' "$server" >>"$TEST_ROOT/dns-ns"
  done
}

# Writes a fixture private Caddy binary that answers exactly the subcommands
# the implementation runs. $2 distinguishes a prior installed binary from a
# freshly built candidate so restoration can be proven byte-for-byte. The
# real `caddy list-modules --packages` shape is one "<module id> <package>"
# line per module (Caddy v2.11.4 cmd/commandfuncs.go printModuleInfo), with
# blank-line-separated "  Standard modules: N" section counts.
write_caddy_stub_binary() {
  local path=$1 marker=$2
  printf '#!/usr/bin/env bash\n# %s\n' "$marker" >"$path"
  cat >>"$path" <<'EOF'
case "$1" in
  version) printf '%s\n' "${CADDY_VERSION_OUTPUT:-v2.11.4 h1:test}" ;;
  list-modules)
    case " $* " in
      *" --versions "*)
        printf '%s\n' "${CADDY_MODULE_VERSIONS:-dns.providers.godaddy v1.2.0 github.com/caddy-dns/godaddy}" ;;
      *) printf '%s\n' "${CADDY_MODULES:-dns.providers.godaddy github.com/caddy-dns/godaddy}" ;;
    esac ;;
  adapt)
    printf 'caddy adapt token=%s\n' "${GODADDY_API_TOKEN:-unset}" >>"$CALLS"
    if [[ ${FAIL_POINT:-} == adapt ]]; then
      printf 'adapt: invalid configuration\n' >&2
      exit 1
    fi
    printf '{"apps":{}}\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod 0755 "$path"
}

# Writes a fixture private Caddy binary, entrypoint, Caddyfile, and unit
# under $CADDY_ROOT, matching what set_caddy_paths() computes from
# $PI_WEBUI_CADDY_ROOT. The Caddyfile and entrypoint are byte-identical to
# the tracked sources; the unit is rendered with the real fixture entrypoint
# path so validate_installed_caddy()'s byte-for-byte comparison succeeds.
make_caddy_fixture() {
  mkdir -p "$CADDY_ROOT/usr/local/lib/pi-webui" "$CADDY_ROOT/etc/pi-webui-caddy" \
    "$CADDY_ROOT/etc/systemd/system"
  cp "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in" "$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"
  write_caddy_stub_binary "$CADDY_ROOT/usr/local/lib/pi-webui/caddy" 'installed fixture'
  cp "$WEBUI_FIXTURE/ai/pi/webui/caddy-entrypoint.sh" \
    "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"
  chmod +x "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"
  bash -c 'source "$1"; set_caddy_paths; render_caddy_unit "$CADDY_ENTRYPOINT"' bash \
    "$WEBUI_FIXTURE/ai/pi/webui/custom-domain.sh" \
    >"$CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
}

# Full fixture for read-only custom-domain checks: the healthy managed
# Firstp1ck/Tailscale/Caddy/DNS state at the given route, with every
# external boundary (systemctl, ss, curl, dig, openssl, stat, and the
# private Caddy binary) stubbed so nothing live is ever touched.
prepare_custom_domain_check() {
  local mode=${1:-empty}
  make_webui_fixture
  make_external_pi
  make_landing_worktree
  make_installed_runtime
  write_expected_unit
  stub_tailscale_system "$mode"
  mkdir -p "$CADDY_ROOT"
  make_caddy_fixture
  write_ns ns1.example.test.
  write_dns A 100.64.0.1

  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners"
  : >"$TEST_ROOT/caddy-listeners-udp"
  export CADDY_MODULES
  CADDY_MODULES=$(printf '%s\n' \
    'admin.api.load github.com/caddyserver/caddy/v2' \
    'http.handlers.reverse_proxy github.com/caddyserver/caddy/v2' \
    '' \
    '  Standard modules: 2' \
    '' \
    'dns.providers.godaddy github.com/caddy-dns/godaddy' \
    '' \
    '  Non-standard modules: 1')
  export CADDY_VERSION_OUTPUT='v2.11.4 h1:test'
  export CADDY_HEALTH_JSON="$HEALTH_JSON"

  # Bounds every TLS probe the implementation runs through `timeout`; the
  # stall fixture reproduces coreutils' 124 exit status without waiting.
  stub_command timeout 'if [[ ${TLS_STALL:-0} == 1 ]]; then exit 124; fi
    exec /usr/bin/timeout "$@"'

  stub_command systemctl 'case "$*" in
    "--user show-environment"|"--user is-active pi-webui.service"|"is-active tailscaled") exit 0 ;;
    "is-active pi-webui-caddy.service")
      if [[ ${CADDY_SERVICE_INACTIVE:-0} == 1 ]]; then printf "inactive\n"; exit 3; fi
      printf "active\n" ;;
    *) printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
  esac'

  stub_command ss 'case "$1" in
    -ltnH)
      if [[ "$2" == "sport = :31415" ]]; then
        printf "%s\n" "LISTEN 0 128 127.0.0.1:31415 0.0.0.0:*"
      else
        printf "%s\n" "LISTEN 0 128 127.0.0.1:31415 0.0.0.0:*"
        cat "$TEST_ROOT/caddy-listeners" 2>/dev/null
      fi
      ;;
    -lunH) cat "$TEST_ROOT/caddy-listeners-udp" 2>/dev/null ;;
    *) exit 1 ;;
  esac'

  stub_command dig 'shift
    case "$1" in
      NS) cat "$TEST_ROOT/dns-ns" 2>/dev/null ;;
      A) cat "$TEST_ROOT/dns-a" 2>/dev/null ;;
      AAAA) cat "$TEST_ROOT/dns-aaaa" 2>/dev/null ;;
      CNAME) cat "$TEST_ROOT/dns-cname" 2>/dev/null ;;
      *) exit 1 ;;
    esac'

  stub_command stat 'if [[ "$1 $2" == "-c %u" ]]; then
    case "$3" in
      "$PI_WEBUI_CADDY_ROOT/usr/local/lib/pi-webui/caddy"|"$PI_WEBUI_CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"|"$PI_WEBUI_CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"|"$PI_WEBUI_CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service")
        if [[ ${CADDY_FOREIGN_OWNER:-0} == 1 ]]; then printf "1000\n"; else printf "0\n"; fi ;;
      *) exec /usr/bin/stat "$@" ;;
    esac
  else
    exec /usr/bin/stat "$@"
  fi'

  stub_command openssl 'case "$1" in
    s_client)
      if [[ ${TLS_TRUST_FAIL:-0} == 1 ]]; then exit 1; fi
      printf -- "-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\n" ;;
    x509)
      if [[ ${TLS_INVALID:-0} == 1 ]]; then exit 1; fi
      exit 0 ;;
    *) exit 1 ;;
  esac'

  stub_command curl 'printf "curl %s\n" "$*" >>"$CALLS"
    case " $* " in
      *" http://127.0.0.1:31415/api/health "*) printf "%s\n" "$HEALTH_JSON" ;;
      *" https://pi.dpao.la:8443/api/health "*)
        if [[ ${CADDY_HEALTH_FAIL:-0} == 1 ]]; then exit 22; fi
        if [[ ${CURL_STALL:-0} == 1 ]]; then exit 28; fi
        printf "%s\n" "${CADDY_HEALTH_JSON:-$HEALTH_JSON}" ;;
      *" -o "*)
        if [[ ${BAD_KEY_DOWNLOAD:-} == 1 ]]; then printf bad-key; else printf key-bytes; fi >"${@: -1}" ;;
      *"https://172.20.1.4:8443/"*|*"https://192.168.1.7:8443/"*)
        if [[ ${LAN_8443_REACHABLE:-0} == 1 ]]; then exit 0; else exit 7; fi ;;
      *"http://172.20.1.4:31415/"*|*"http://192.168.1.7:31415/"*)
        if [[ ${LAN_31415_REACHABLE:-0} == 1 ]]; then exit 0; else exit 7; fi ;;
      *) exit 7 ;;
    esac'
}

# Full fixture for candidate-first setup. Extends the read-only check fixture
# with stubs for every build, credential, publication, and service boundary:
# nothing is really built, downloaded, decrypted, installed, started, or
# routed. $2 == prior seeds an existing managed installation so restoration
# can be proven.
prepare_custom_domain_setup() {
  local mode=${1:-legacy-exact} prior=${2:-}
  prepare_custom_domain_check "$mode"
  rm -rf "$CADDY_ROOT/usr" "$CADDY_ROOT/etc/pi-webui-caddy" "$CADDY_ROOT/etc/systemd"
  rm -f "$TEST_ROOT/caddy-active" "$TEST_ROOT/caddy-enabled"
  if [[ "$prior" == prior ]]; then
    make_caddy_fixture
    touch "$TEST_ROOT/caddy-active" "$TEST_ROOT/caddy-enabled"
    # Models the prior Caddy process already in memory, so a no-op start
    # cannot be mistaken for a candidate restart.
    sed -n '2p' "$CADDY_ROOT/usr/local/lib/pi-webui/caddy" >"$TEST_ROOT/caddy-running"
  fi

  CADDY_CREDENTIAL="$CADDY_ROOT/etc/credstore.encrypted/godaddy-api-token"
  CADDY_STATE_DIR="$CADDY_ROOT/var/lib/pi-webui-caddy"
  export CADDY_CREDENTIAL CADDY_STATE_DIR
  mkdir -p "$(dirname "$CADDY_CREDENTIAL")" "$CADDY_STATE_DIR"
  printf 'encrypted-credential-blob\n' >"$CADDY_CREDENTIAL"
  chmod 0600 "$CADDY_CREDENTIAL"
  printf 'acme account state\n' >"$CADDY_STATE_DIR/acme.json"

  write_caddy_stub_binary "$TEST_ROOT/candidate-caddy" 'candidate build'
  # Two attempts with no delay: a bounded readiness wait that never sleeps.
  export PI_WEBUI_TEST_READY_BUDGET=2:0

  stub_command mise 'if [[ "$1 $2" == "which pi" ]]; then
    printf "%s\n" "$PI_LAUNCHER"
  elif [[ "$1 $2" == "exec --" ]]; then
    shift 2
    exec "$@"
  else
    exit 97
  fi'
  MISE_LAUNCHER="$STUB_BIN/mise"
  export MISE_LAUNCHER

  stub_command go 'printf "go %s\n" "$*" >>"$CALLS"
    if [[ ${FAIL_POINT:-} == build ]]; then
      printf "xcaddy: build failed\n" >&2
      exit 1
    fi
    output=
    previous=
    for argument in "$@"; do
      if [[ "$previous" == --output ]]; then output=$argument; fi
      previous=$argument
    done
    [[ -n "$output" ]] || exit 3
    cp "$TEST_ROOT/candidate-caddy" "$output"
    chmod 0755 "$output"'

  stub_command shellcheck 'printf "shellcheck %s\n" "$*" >>"$CALLS"
    [[ ${FAIL_POINT:-} != shellcheck ]]'

  stub_command systemd-analyze 'printf "systemd-analyze %s\n" "$*" >>"$CALLS"
    [[ ${FAIL_POINT:-} != unit-verify ]]'

  # Intercepts only the credential validator (node -e); every other Node
  # program in the implementation still runs for real.
  stub_command node 'if [[ "$1" == -e ]]; then
    token=$(cat)
    printf "godaddy-api-request\n" >>"$CREDENTIAL_CALLS"
    case "$token" in
      *:*) ;;
      *) exit 2 ;;
    esac
    if [[ "${GODADDY_API_STATUS:-200}" == 200 ]]; then
      printf "GoDaddy DNS API credential is valid\n"
    else
      printf "error: GoDaddy DNS API returned HTTP %s\n" "$GODADDY_API_STATUS" >&2
      exit 1
    fi
  else
    exec "$SANDBOX_TOOL_BIN/node" "$@"
  fi'

  stub_command systemctl 'printf "systemctl %s\n" "$*" >>"$CALLS"
    unit="$PI_WEBUI_CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
    unit_binary="$PI_WEBUI_CADDY_ROOT/usr/local/lib/pi-webui/caddy"
    case "$*" in
      "--user show-environment"|"is-active tailscaled") exit 0 ;;
      "--user is-active pi-webui.service") [[ ${FIRSTPICK_INACTIVE:-0} != 1 ]] ;;
      "is-active pi-webui-caddy.service")
        if [[ ${STATE_QUERY_FAILS:-} == is-active ]]; then exit 1; fi
        if [[ -f "$TEST_ROOT/caddy-active" ]]; then printf "active\n"; else printf "inactive\n"; exit 3; fi ;;
      "is-enabled pi-webui-caddy.service")
        if [[ ${STATE_QUERY_FAILS:-} == is-enabled ]]; then exit 1; fi
        if [[ -f "$TEST_ROOT/caddy-enabled" ]]; then printf "enabled\n"; else printf "disabled\n"; exit 1; fi ;;
      "daemon-reload") printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS" ;;
      "enable pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        touch "$TEST_ROOT/caddy-enabled"
        [[ ${FAIL_POINT:-} != enable-partial ]] || exit 1 ;;
      "disable pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        # systemd cannot remove an enablement symlink for a unit whose file no
        # longer exists, so restoration has to disable before it deletes.
        if [[ ! -f "$unit" ]]; then
          printf "Failed to disable unit: Unit file pi-webui-caddy.service does not exist.\n" >&2
          exit 1
        fi
        rm -f "$TEST_ROOT/caddy-enabled" ;;
      "start pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        # systemd treats start as a no-op for an already-active unit: the
        # process in memory keeps running the binary it was started with.
        if [[ -f "$TEST_ROOT/caddy-active" ]]; then exit 0; fi
        if [[ ${FAIL_POINT:-} == caddy-start ]]; then exit 1; fi
        touch "$TEST_ROOT/caddy-active"
        sed -n "2p" "$unit_binary" >"$TEST_ROOT/caddy-running" ;;
      "restart pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        rm -f "$TEST_ROOT/caddy-active" "$TEST_ROOT/caddy-running"
        if [[ ${FAIL_POINT:-} == caddy-start ]]; then exit 1; fi
        touch "$TEST_ROOT/caddy-active"
        sed -n "2p" "$unit_binary" >"$TEST_ROOT/caddy-running"
        [[ ${FAIL_POINT:-} != restart-partial ]] || exit 1 ;;
      "stop pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        rm -f "$TEST_ROOT/caddy-active" "$TEST_ROOT/caddy-running" ;;
      *) printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
    esac'

  stub_command stat 'case "$3" in
    "$CADDY_CREDENTIAL")
      case "$1 $2" in
        "-c %u") printf "%s\n" "${CREDENTIAL_OWNER:-0}" ;;
        "-c %a") printf "%s\n" "${CREDENTIAL_MODE:-600}" ;;
        *) exec /usr/bin/stat "$@" ;;
      esac ;;
    "$PI_WEBUI_CADDY_ROOT/usr/local/lib/pi-webui/caddy"|"$PI_WEBUI_CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"|"$PI_WEBUI_CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"|"$PI_WEBUI_CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service")
      if [[ "$1 $2" == "-c %u" ]]; then
        if [[ ${CADDY_FOREIGN_OWNER:-0} == 1 ]]; then printf "1000\n"; else printf "0\n"; fi
      else
        exec /usr/bin/stat "$@"
      fi ;;
    *) exec /usr/bin/stat "$@" ;;
  esac'

  # sudo runs nothing privileged: it records the exact command, answers the
  # credential decryption with a fixture token, and performs publication with
  # the unprivileged real install/mv/rm inside $CADDY_ROOT.
  stub_command sudo 'printf "sudo %s\n" "$*" >>"$CALLS"
    case "$1" in
      systemd-creds)
        printf "credential-check\n" >>"$CALLS"
        printf "systemd-creds decrypt\n" >>"$CREDENTIAL_CALLS"
        if [[ ${FAIL_POINT:-} == decrypt ]]; then exit 1; fi
        printf "%s" "${GODADDY_TOKEN_FIXTURE-testkey:testsecret}" ;;
      install)
        shift
        arguments=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -o|-g) shift 2 ;;
            *) arguments+=("$1"); shift ;;
          esac
        done
        if [[ ${FAIL_POINT:-} == publish && "${arguments[*]}" == *pi-webui-caddy.service.pi-webui-new* ]]; then exit 1; fi
        exec /usr/bin/install "${arguments[@]}" ;;
      mv)
        shift
        if [[ ${RESTORE_FAIL:-0} == 1 && "$*" == *.pi-webui-restore* ]]; then exit 1; fi
        exec /usr/bin/mv "$@" ;;
      rm)
        shift
        exec /usr/bin/rm "$@" ;;
      systemctl)
        shift
        exec systemctl "$@" ;;
      *) printf "%s\n" "$*" >>"$MUTATION_CALLS"; exit 98 ;;
    esac'
}

# Absolute managed artifact paths under the test Caddy root, in publication
# order: binary, entrypoint, Caddyfile, unit.
managed_caddy_paths() {
  printf '%s\n' \
    "$CADDY_ROOT/usr/local/lib/pi-webui/caddy" \
    "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint" \
    "$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile" \
    "$CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
}

assert_no_caddy_publication() {
  [ ! -s "$MUTATION_CALLS" ]
  ! grep -q '^sudo install ' "$CALLS"
  ! grep -q 'tailscale serve' "$CALLS"
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
}

# Full fixture for the interactive migration transaction and for custom-domain
# rollback. Extends the read-only check fixture with a stateful Tailscale route
# stub that transitions only for the four exact Serve commands, records every
# real transition in order, and can inject a failure at each transactional
# boundary. Nothing privileged, routed, decrypted, or networked really runs.
#
# The transition fixtures are generated from write_route(), so the route shapes
# stay single-sourced with the rest of the suite.
prepare_custom_domain_migration() {
  local mode=${1:-legacy-exact} state
  prepare_custom_domain_check "$mode"

  ROUTE_ORDER="$TEST_ROOT/route-order"
  CADDY_CREDENTIAL="$CADDY_ROOT/etc/credstore.encrypted/godaddy-api-token"
  CADDY_STATE_DIR="$CADDY_ROOT/var/lib/pi-webui-caddy"
  TAILSCALE_STATE_DIR="$TEST_ROOT/tailscale/var/lib/tailscale"
  export ROUTE_ORDER CADDY_CREDENTIAL CADDY_STATE_DIR TAILSCALE_STATE_DIR
  : >"$ROUTE_ORDER"

  # Preserved-state fingerprint sources: Caddy certificates and ACME state, the
  # encrypted GoDaddy credential, Pi state, managed Web UI state, and the
  # Tailscale node identity.
  mkdir -p "$(dirname "$CADDY_CREDENTIAL")" "$CADDY_STATE_DIR" "$TAILSCALE_STATE_DIR" \
    "$HOME/.pi/agent/sessions"
  printf 'encrypted-credential-blob\n' >"$CADDY_CREDENTIAL"
  chmod 0600 "$CADDY_CREDENTIAL"
  printf 'acme account state\n' >"$CADDY_STATE_DIR/acme.json"
  printf 'certificate\n' >"$CADDY_STATE_DIR/pi.dpao.la.crt"
  printf 'identity\n' >"$TAILSCALE_STATE_DIR/tailscaled.state"
  printf 'settings\n' >"$HOME/.pi/agent/settings.json"
  printf 'transcript\n' >"$HOME/.pi/agent/sessions/transcript.jsonl"

  for state in empty legacy-exact raw foreign; do
    write_route "$state"
    cp "$TEST_ROOT/route.json" "$TEST_ROOT/fixture-$state.json"
    cp "$TEST_ROOT/route.txt" "$TEST_ROOT/fixture-$state.txt"
  done
  write_route "$mode"

  touch "$TEST_ROOT/caddy-active"
  stub_command systemctl 'printf "systemctl %s\n" "$*" >>"$CALLS"
    case "$*" in
      "--user show-environment"|"is-active tailscaled") exit 0 ;;
      "--user is-active pi-webui.service") [[ ${FIRSTPICK_INACTIVE:-0} != 1 ]] ;;
      "is-active pi-webui-caddy.service")
        if [[ ${CADDY_SERVICE_INACTIVE:-0} != 1 && -f "$TEST_ROOT/caddy-active" ]]; then
          printf "active\n"
        else
          printf "inactive\n"; exit 3
        fi ;;
      "stop pi-webui-caddy.service")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"
        rm -f "$TEST_ROOT/caddy-active" ;;
      "disable pi-webui-caddy.service"|"daemon-reload")
        printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS" ;;
      *) printf "systemctl %s\n" "$*" >>"$MUTATION_CALLS"; exit 99 ;;
    esac'

  stub_command curl 'printf "curl %s\n" "$*" >>"$CALLS"
    raw=0
    if grep -q TCPForward "$TEST_ROOT/route.json" 2>/dev/null; then raw=1; fi
    case " $* " in
      *" http://127.0.0.1:31415/api/health "*) printf "%s\n" "$HEALTH_JSON" ;;
      *" https://pi.dpao.la:8443/api/health "*)
        if [[ ${CADDY_HEALTH_FAIL:-0} == 1 ]]; then exit 22; fi
        if [[ ${CADDY_HEALTH_FAIL_AFTER_RAW:-0} == 1 && $raw == 1 ]]; then exit 22; fi
        printf "%s\n" "${CADDY_HEALTH_JSON:-$HEALTH_JSON}" ;;
      *" https://pi.dpao.la/api/health "*)
        if [[ ${TAILNET_HEALTH_FAIL:-0} == 1 ]]; then exit 22; fi
        printf "%s\n" "${CADDY_HEALTH_JSON:-$HEALTH_JSON}" ;;
      *" https://wsl.test.ts.net/api/health "*)
        if [[ ${LEGACY_HEALTH_FAIL:-0} == 1 ]]; then exit 22; fi
        printf "%s\n" "$HEALTH_JSON"
        # One-shot concurrent route change in the window between restoration
        # and Caddy teardown: the old-URL probe is the last call before it.
        if [[ -n ${ROUTE_CHANGE_BEFORE_TEARDOWN:-} && ! -e "$TEST_ROOT/route-changed" ]]; then
          touch "$TEST_ROOT/route-changed"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_BEFORE_TEARDOWN.json" "$TEST_ROOT/route.json"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_BEFORE_TEARDOWN.json" "$TEST_ROOT/funnel.json"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_BEFORE_TEARDOWN.txt" "$TEST_ROOT/route.txt"
        fi ;;
      *"https://172.20.1.4:8443/"*|*"https://192.168.1.7:8443/"*)
        # One-shot concurrent route change in the window between the last
        # automated verification and the success report: check_caddy_lan is
        # the final probe migration runs before the operator confirmation.
        # Gated on the published raw route so the identical pre-mutation
        # listener check is left alone.
        if [[ -n ${ROUTE_CHANGE_AFTER_VERIFY:-} && $raw == 1 && ! -e "$TEST_ROOT/route-changed" ]]; then
          touch "$TEST_ROOT/route-changed"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_AFTER_VERIFY.json" "$TEST_ROOT/route.json"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_AFTER_VERIFY.json" "$TEST_ROOT/funnel.json"
          cp "$TEST_ROOT/fixture-$ROUTE_CHANGE_AFTER_VERIFY.txt" "$TEST_ROOT/route.txt"
        fi
        if [[ ${LAN_8443_REACHABLE:-0} == 1 ]]; then exit 0; else exit 7; fi ;;
      *"http://172.20.1.4:31415/"*|*"http://192.168.1.7:31415/"*)
        if [[ ${LAN_31415_REACHABLE:-0} == 1 ]]; then exit 0; else exit 7; fi ;;
      *) exit 7 ;;
    esac'

  stub_command openssl 'case "$1" in
    s_client)
      raw=0
      if grep -q TCPForward "$TEST_ROOT/route.json" 2>/dev/null; then raw=1; fi
      if [[ ${TLS_TRUST_FAIL:-0} == 1 ]]; then exit 1; fi
      if [[ ${TLS_TRUST_FAIL_AFTER_RAW:-0} == 1 && $raw == 1 ]]; then exit 1; fi
      printf -- "-----BEGIN CERTIFICATE-----\nMOCK\n-----END CERTIFICATE-----\n" ;;
    x509)
      if [[ ${TLS_INVALID:-0} == 1 ]]; then exit 1; fi
      exit 0 ;;
    *) exit 1 ;;
  esac'

  # sudo runs nothing privileged: it records the exact command, transitions the
  # route fixture only for the four exact Serve commands, and performs artifact
  # removal and service calls with the unprivileged real tools under $TEST_ROOT.
  stub_command sudo 'printf "sudo %s\n" "$*" >>"$CALLS"
    set_route() {
      cp "$TEST_ROOT/fixture-$1.json" "$TEST_ROOT/route.json"
      cp "$TEST_ROOT/fixture-$1.json" "$TEST_ROOT/funnel.json"
      cp "$TEST_ROOT/fixture-$1.txt" "$TEST_ROOT/route.txt"
      printf "%s\n" "$2" >>"$ROUTE_ORDER"
    }
    case "$*" in
      "tailscale serve --https=443 off")
        [[ ${FAIL_POINT:-} != legacy-off ]] || exit 1
        set_route empty legacy-off ;;
      "tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443")
        [[ ${FAIL_POINT:-} != raw-publish ]] || exit 1
        if [[ ${RAW_PUBLISH_FOREIGN:-0} == 1 ]]; then
          set_route foreign raw-on
        elif [[ ${RAW_PUBLISH_STICKS:-0} == 1 ]]; then
          :
        else
          set_route raw raw-on
        fi ;;
      "tailscale serve --tcp=443 off")
        [[ ${FAIL_POINT:-} != raw-off ]] || exit 1
        set_route empty raw-off ;;
      "tailscale serve --bg --https=443 http://127.0.0.1:31415")
        [[ ${FAIL_POINT:-} != legacy-restore ]] || exit 1
        set_route legacy-exact legacy-on ;;
      systemctl*) shift; exec systemctl "$@" ;;
      rm*) shift; exec /usr/bin/rm "$@" ;;
      *) printf "sudo %s\n" "$*" >>"$MUTATION_CALLS"; exit 98 ;;
    esac'
}

# The ordered list of route transitions the Tailscale stub actually performed.
route_call_order() {
  cat "$ROUTE_ORDER"
}

# Classifies the live route fixture by exact content, so a test never has to
# track which transition it expected.
current_route_fixture() {
  local state
  for state in empty legacy-exact raw foreign; do
    if cmp -s "$TEST_ROOT/route.json" "$TEST_ROOT/fixture-$state.json" &&
      cmp -s "$TEST_ROOT/route.txt" "$TEST_ROOT/fixture-$state.txt"; then
      [[ "$state" != raw ]] || state=raw-exact
      printf '%s\n' "$state"
      return 0
    fi
  done
  printf 'unknown\n'
}

reset_migration_state() {
  write_route "${1:-legacy-exact}"
  : >"$ROUTE_ORDER"
  : >"$CALLS"
  : >"$MUTATION_CALLS"
  rm -f "$TEST_ROOT/route-changed"
}

assert_no_route_mutation() {
  [ ! -s "$ROUTE_ORDER" ]
  ! grep -q 'tailscale serve' "$CALLS"
  [ ! -s "$MUTATION_CALLS" ]
  [ "$(current_route_fixture)" = "${1:-legacy-exact}" ]
}

prepare_rollback() {
  make_webui_fixture
  make_external_pi
  make_landing_worktree
  make_installed_runtime
  write_expected_unit
  stub_tailscale_system empty
  stub_command systemctl 'case "$*" in
    "--user show-environment") exit 0 ;;
    "is-active tailscaled") [[ ${TAILSCALED_INACTIVE:-} != 1 ]] ;;
    "--user is-active pi-webui.service") [[ -f "$TEST_ROOT/service-active" ]] ;;
    "--user stop pi-webui.service") printf "%s\n" stop >>"$MUTATION_CALLS"; rm -f "$TEST_ROOT/service-active" "$TEST_ROOT/listener" ;;
    "--user disable pi-webui.service") printf "%s\n" disable >>"$MUTATION_CALLS"; rm -f "$TEST_ROOT/service-enabled" ;;
    "--user daemon-reload") printf "%s\n" reload >>"$MUTATION_CALLS" ;;
    *) exit 97 ;;
  esac'
  stub_command ss '[[ ! -f "$TEST_ROOT/listener" ]]'
}

run_rollback() {
  run "$WEBUI_FIXTURE/ai/pi/webui/rollback.sh" "$@"
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
  [[ "$output" == *"ExecStart=$MISE_LAUNCHER exec -- \"$INSTALLED_RUNTIME/node_modules/.bin/pi-webui\" --host 127.0.0.1 --port 31415 --cwd \"$LANDING_WORKTREE\" --pi \"$PI_LAUNCHER\""* ]]
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
  export HEALTH_JSON='{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}'
  stub_healthy_system
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]

  export HEALTH_JSON="{\"ok\":true,\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":false,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[{\"cwd\":\"/tmp/project\",\"running\":true,\"command\":\"$PI_LAUNCHER --mode rpc --session x\"}]}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -eq 0 ]

  export HEALTH_JSON="{\"ok\":true,\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":false,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[{\"cwd\":\"/tmp/project\",\"running\":true,\"command\":\"/wrong/pi --mode rpc\"}]}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]

  export HEALTH_JSON="{\"ok\":true,\"webuiVersion\":\"0.10.3\",\"piVersion\":\"0.84.4\",\"network\":{\"open\":true,\"host\":\"127.0.0.1\",\"port\":31415,\"networkUrls\":[]},\"tabs\":[]}"
  run_installer_function 'validate_active_health "$PI_LAUNCHER"'
  [ "$status" -ne 0 ]
}

@test "active health rejects non-loopback or multiple listeners" {
  make_webui_fixture
  make_external_pi
  export HEALTH_JSON='{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}'
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
  local unsafe
  make_webui_fixture
  make_external_pi
  make_candidate_installer
  export HEALTH_JSON='{"ok":true,"webuiVersion":"0.10.3","piVersion":"0.84.4","network":{"open":false,"host":"127.0.0.1","port":31415,"networkUrls":[]},"tabs":[]}'
  stub_apply_system

  for unsafe in "$TEST_ROOT/data%unsafe" "$TEST_ROOT/data\$unsafe" "$TEST_ROOT/data unsafe" \
    "$TEST_ROOT/data'unsafe" "$TEST_ROOT/data\"unsafe" "$TEST_ROOT/data\\unsafe" "$TEST_ROOT/"$'data\nunsafe'; do
    export XDG_DATA_HOME="$unsafe"
    export XDG_CONFIG_HOME="$TEST_ROOT/config"
    STATE_ROOT="$XDG_DATA_HOME/pi-webui"
    INSTALLED_RUNTIME="$STATE_ROOT/runtimes/current"
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

@test "apply rejects retained transients and validates candidates before service stop" {
  prepare_apply_fixture candidate-validation
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system
  for retained in "$STATE_ROOT/runtimes/.candidate.retained" "$STATE_ROOT/.apply.retained"; do
    mkdir -p "$retained"
    run_installer --apply
    [[ "$status" -ne 0 && -d "$retained" ]]
    [[ -z $(grep -E '^(npm|systemd-analyze|systemctl --user stop)' "$CALLS") ]]
    assert_prior_apply_state candidate-validation 1 1
    rm -rf "$retained"
  done
  export FAIL_POINT=candidate-verify
  run_installer --apply
  [ "$status" -ne 0 ]
  grep -F "systemd-analyze --user verify " "$CALLS"
  [ "$(grep -c 'systemctl --user stop pi-webui.service' "$CALLS")" -eq 0 ]
  assert_prior_apply_state candidate-validation 1 1
}

@test "apply creates or advances only a clean detached landing worktree" {
  prepare_apply_fixture landing
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
  export FAIL_POINT=daemon-reload
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled"
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  [ "$(grep -c 'systemctl --user daemon-reload' "$CALLS")" -eq 2 ]
  assert_prior_apply_state daemon-failure 1 1
}

@test "apply restores an absent prior installation after partial worktree creation" {
  prepare_apply_fixture absent-prior
  export STRICT_UNLOADED=1
  rm -rf "$INSTALLED_RUNTIME"
  rm -f "$UNIT_PATH"
  git -C "$WEBUI_FIXTURE" worktree remove --force "$LANDING_WORKTREE"
  stub_apply_system
  stub_command git 'if [[ "$*" == *" worktree add --detach "* ]]; then /usr/bin/git "$@"; exit 1; fi; exec /usr/bin/git "$@"'

  run_installer --apply

  [ "$status" -ne 0 ]
  [[ "$output" != *"restoration failed"* ]]
  [ ! -e "$INSTALLED_RUNTIME" ]
  [ ! -e "$UNIT_PATH" ]
  [ ! -e "$LANDING_WORKTREE" ]
  [ ! -e "$TEST_ROOT/service-active" ]
  [ ! -e "$TEST_ROOT/service-enabled" ]
  [ "$(grep -c 'systemctl --user stop pi-webui.service' "$CALLS")" -eq 0 ]
  [ -z "$(find "$STATE_ROOT" -maxdepth 1 -name '.apply.*' -print -quit)" ]
  [ -z "$(find "$STATE_ROOT/runtimes" -maxdepth 1 -name '.candidate.*' -print -quit)" ]
}

@test "apply restores prior commit enablement and activity after health failure" {
  prepare_apply_fixture health-failure
  export FAIL_POINT=health
  stub_apply_system

  run_installer --apply

  [ "$status" -ne 0 ]
  grep -F "systemctl --user start pi-webui.service" "$CALLS"
  assert_prior_apply_state health-failure 0 0
}

@test "route classifier distinguishes empty legacy and exact raw TCP" {
  prepare_tailscale_check empty
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = empty ]

  write_route legacy-exact
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = legacy-exact ]

  write_route raw
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = raw-exact ]
}

@test "raw TCP classifier rejects near-miss route shapes" {
  prepare_tailscale_check empty
  local shape
  for shape in \
    '{"TCP":{"443":{"HTTPS":true}}}' \
    '{"TCP":{"443":{"HTTP":true}}}' \
    '{"TCP":{"443":{"TerminateTLS":true}}}' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:9999"}}}' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"},"8443":{"TCPForward":"127.0.0.1:8443"}}}' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"}},"Web":{"wsl.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:31415"}}}}}' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"}},"AllowFunnel":{"wsl.test.ts.net:443":true}}' \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8443"}},"Unknown":{"anything":true}}'; do
    printf '%s\n' "$shape" >"$TEST_ROOT/route.json"
    cp "$TEST_ROOT/route.json" "$TEST_ROOT/funnel.json"
    run_tailscale_function 'route_state'
    [ "$status" -ne 0 ]
  done
}

@test "raw human status is parsed as an exact dual-stack address set" {
  prepare_tailscale_check raw
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = raw-exact ]

  # The address lines are a set, so the daemon's family order does not matter.
  local human
  printf '%s\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)' \
    '|-- tcp://[fd7a:115c:a1e0::1]:443' \
    '|-- tcp://100.64.0.1:443' \
    '|--> tcp://127.0.0.1:8443' >"$TEST_ROOT/route.txt"
  run_tailscale_function 'route_state'
  [ "$status" -eq 0 ]
  [ "$output" = raw-exact ]

  # Every malformed tree below is rejected: a missing address line, a
  # duplicated address line, a foreign address line, a Funnel or
  # TLS-terminated descriptor, an unbracketed IPv6 address, an extra line,
  # and the pre-1.102.3 prefixless host line.
  for human in \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://100.64.0.1:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://100.64.0.9:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (Funnel on)\n|-- tcp://100.64.0.1:443\n|-- tcp://[fd7a:115c:a1e0::1]:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (TLS-terminated TCP, tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://[fd7a:115c:a1e0::1]:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://fd7a:115c:a1e0::1:443\n|--> tcp://127.0.0.1:8443\n' \
    '|-- tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://[fd7a:115c:a1e0::1]:443\n|--> tcp://127.0.0.1:8443\n|--> tcp://127.0.0.1:9999\n' \
    'tcp://wsl.test.ts.net:443 (tailnet only)\n|-- tcp://100.64.0.1:443\n|-- tcp://[fd7a:115c:a1e0::1]:443\n|--> tcp://127.0.0.1:8443\n'; do
    printf "$human" >"$TEST_ROOT/route.txt"
    run_tailscale_function 'route_state'
    [ "$status" -ne 0 ]
  done

  # The node address set itself must agree between Self and the node-level
  # status the human formatter actually reads.
  write_route raw
  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","TailscaleIPs":["100.64.0.1"],"Self":{"Online":true,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]}}' >"$TEST_ROOT/tailscale-status.json"
  run_tailscale_function 'route_state'
  [ "$status" -ne 0 ]
}

@test "route operations reject mismatched Tailscale client or daemon versions" {
  prepare_tailscale_check raw
  export TAILSCALE_CLIENT_VERSION=1.103.0
  run_tailscale check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]

  run_tailscale_function 'route_state'
  [ "$status" -ne 0 ]

  run_tailscale uninstall
  [ "$status" -ne 0 ]
  ! grep -F 'apt-get remove' "$CALLS"

  export TAILSCALE_CLIENT_VERSION=1.102.3
  export TAILSCALE_DAEMON_VERSION=1.103.0-tforeign
  run_tailscale check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]

  run_tailscale_function 'route_state'
  [ "$status" -ne 0 ]

  : >"$CALLS"
  run_tailscale uninstall
  [ "$status" -ne 0 ]
  ! grep -F 'apt-get remove' "$CALLS"
}

@test "tailscale check accepts empty or raw exact tailnet-only route" {
  prepare_tailscale_check empty
  run_tailscale check
  [ "$status" -eq 0 ]
  write_route raw
  run_tailscale check
  [ "$status" -eq 0 ]
  printf '  |--   tcp://wsl.test.ts.net:443   (tailnet only)  \n  |--   tcp://100.64.0.1:443  \n  |--  tcp://[fd7a:115c:a1e0::1]:443 \n  |-->   tcp://127.0.0.1:8443  \n' >"$TEST_ROOT/route.txt"
  run_tailscale check
  [ "$status" -eq 0 ]
  printf 'tcp://wsl.test.ts.net:443\n|-- tcp://100.64.0.1:443\n|-- tcp://[fd7a:115c:a1e0::1]:443\n|--> tcp://127.0.0.1:8443\n' >"$TEST_ROOT/route.txt"
  run_tailscale check
  [ "$status" -ne 0 ]

  write_route legacy-exact
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
  write_route legacy-exact
  printf '{}\n' >"$TEST_ROOT/funnel.json"
  run_tailscale check
  [ "$status" -ne 0 ]
}

@test "tailscale serve publishes only raw TCP 443 to the loopback backend" {
  prepare_tailscale_check empty
  run_tailscale serve
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443' "$CALLS"

  rm -rf "$INSTALLED_RUNTIME"
  : >"$CALLS"
  run_tailscale serve
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "tailscale serve-off is idempotent and removes only the raw owned route" {
  prepare_tailscale_check empty
  run_tailscale serve-off
  [ "$status" -eq 0 ]
  write_route foreign
  run_tailscale serve-off
  [ "$status" -ne 0 ]
  ! grep -F 'sudo tailscale serve' "$CALLS"
  write_route raw
  export SERVE_OFF_STICKS=1
  run_tailscale serve-off
  [ "$status" -ne 0 ]
  [[ "$output" == *"route remains after removal"* ]]
  unset SERVE_OFF_STICKS
  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"],"Self":{"Online":false,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]}}' >"$TEST_ROOT/tailscale-status.json"
  run_tailscale serve-off
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --tcp=443 off' "$CALLS"
}

@test "transitional legacy ingress has explicit public publish and removal verbs" {
  prepare_tailscale_check empty
  run_tailscale help
  [ "$status" -eq 0 ]
  [[ "$output" == *'serve-legacy'* && "$output" == *'serve-legacy-off'* ]]

  run_tailscale serve-legacy
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$CALLS"

  : >"$CALLS"
  run_tailscale serve-legacy-off
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --https=443 off' "$CALLS"

  # Idempotent from empty, and never applied over a foreign route.
  : >"$CALLS"
  run_tailscale serve-legacy-off
  [ "$status" -eq 0 ]
  ! grep -q 'tailscale serve' "$CALLS"

  write_route foreign
  : >"$CALLS"
  run_tailscale serve-legacy
  [ "$status" -ne 0 ]
  run_tailscale serve-legacy-off
  [ "$status" -ne 0 ]
  ! grep -q 'tailscale serve' "$CALLS"

  # The transitional publication requires the same strict local service the
  # raw publication does.
  write_route empty
  rm -rf "$INSTALLED_RUNTIME"
  : >"$CALLS"
  run_tailscale serve-legacy
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "LAN detection excludes tailscale0 without assuming eth0" {
  prepare_tailscale_check empty
  run_tailscale check
  [ "$status" -eq 0 ]
  grep -F -- '--max-time 5 http://172.20.1.4:31415/' "$CALLS"
  grep -F -- '--max-time 5 http://192.168.1.7:31415/' "$CALLS"
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

@test "rollback removes only the managed service and preserves user state" {
  prepare_rollback
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/service-enabled" "$TEST_ROOT/listener"
  mkdir -p "$HOME/.pi/agent/sessions" "$STATE_ROOT/"{backups,evaluation} "$LANDING_WORKTREE/.pi" "$TEST_ROOT/tailscale/var/lib/tailscale"
  printf settings >"$HOME/.pi/agent/settings.json"
  printf transcript >"$HOME/.pi/agent/sessions/transcript.jsonl"
  printf supervisor >"$HOME/.pi/agent/supervisor.json"
  printf backup >"$STATE_ROOT/backups/old"
  printf evidence >"$STATE_ROOT/evaluation/result"
  printf history >"$LANDING_WORKTREE/.pi/history"
  printf identity >"$TEST_ROOT/tailscale/var/lib/tailscale/tailscaled.state"
  before=$(fingerprint_paths "$HOME/.pi" "$STATE_ROOT" "$TEST_ROOT/tailscale")
  run_rollback
  [ "$status" -eq 0 ]
  [ ! -e "$UNIT_PATH" ]
  [ "$(<"$MUTATION_CALLS")" = $'stop\ndisable\nreload' ]
  after=$(fingerprint_paths "$HOME/.pi" "$STATE_ROOT" "$TEST_ROOT/tailscale")
  [ "$before" = "$after" ]
}

@test "rollback requires the Tailscale daemon before route classification" {
  prepare_rollback
  export TAILSCALED_INACTIVE=1
  rm "$TEST_ROOT/route.json"
  run_rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *"tailscaled is not active"* ]]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "rollback refuses nonempty Serve or a foreign unit" {
  prepare_rollback
  write_route legacy-exact
  run_rollback
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
  write_route empty
  printf foreign >"$UNIT_PATH"
  run_rollback
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
  [ "$(<"$UNIT_PATH")" = foreign ]
}

@test "rollback remove-runtime requires an inactive exact runtime" {
  prepare_rollback
  touch "$TEST_ROOT/service-active" "$TEST_ROOT/listener"
  run_rollback --remove-runtime
  [ "$status" -ne 0 ]
  [ -d "$INSTALLED_RUNTIME" ]
  [ ! -s "$MUTATION_CALLS" ]
  rm "$TEST_ROOT/service-active" "$TEST_ROOT/listener"
  printf foreign >>"$INSTALLED_RUNTIME/package-lock.json"
  run_rollback --remove-runtime
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
  cp "$WEBUI_FIXTURE/ai/pi/webui/runtime/package-lock.json" "$INSTALLED_RUNTIME/package-lock.json"
  run_rollback --remove-runtime
  [ "$status" -eq 0 ]
  [ ! -e "$INSTALLED_RUNTIME" ]
}

@test "rollback remove-worktree requires a clean detached managed worktree without .pi" {
  prepare_rollback
  mkdir -p "$LANDING_WORKTREE/.pi"
  run_rollback --remove-worktree
  [ "$status" -ne 0 ]
  [ -d "$LANDING_WORKTREE" ]
  [ ! -s "$MUTATION_CALLS" ]
  rmdir "$LANDING_WORKTREE/.pi"
  run_rollback --remove-worktree
  [ "$status" -eq 0 ]
  [ ! -e "$LANDING_WORKTREE" ]
}

@test "rollback is idempotent when the managed service is absent" {
  prepare_rollback
  rm "$UNIT_PATH"
  run_rollback
  [ "$status" -eq 0 ]
  run_rollback
  [ "$status" -eq 0 ]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "tailscale uninstall preserves identity and refuses an active route" {
  make_webui_fixture
  stub_tailscale_system legacy-exact
  export PI_WEBUI_TAILSCALE_ROOT="$TEST_ROOT/system-root"
  mkdir -p "$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings" "$PI_WEBUI_TAILSCALE_ROOT/etc/apt/sources.list.d" "$PI_WEBUI_TAILSCALE_ROOT/var/lib/tailscale"
  printf key-bytes >"$PI_WEBUI_TAILSCALE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main' >"$PI_WEBUI_TAILSCALE_ROOT/etc/apt/sources.list.d/tailscale.list"
  run_tailscale uninstall
  [ "$status" -ne 0 ]
  ! grep -F 'apt-get remove' "$CALLS"
  write_route empty
  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","Self":{"Online":false,"DNSName":"wsl.test.ts.net."}}' >"$TEST_ROOT/tailscale-status.json"
  run_tailscale uninstall
  [ "$status" -eq 0 ]
  grep -F 'sudo apt-get remove --yes tailscale' "$CALLS"
  [[ "$(<"$CALLS")" != *purge* && "$(<"$CALLS")" != *logout* && "$(<"$CALLS")" != *var/lib/tailscale* ]]
}

@test "public Web UI targets call only explicit Web UI helpers" {
  fixture="$TEST_ROOT/public-make"
  mkdir -p "$fixture/ai/pi/webui"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$CALLS"\n' >"$fixture/ai/pi/webui/install.sh"
  run make -s -C "$fixture" ai-webui
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = --apply ]
  : >"$CALLS"
  run make -s -C "$fixture" ai-webui-check
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = --check ]
}

@test "ordinary make ai and ai-check remain unchanged" {
  fixture="$TEST_ROOT/ordinary-make"
  mkdir -p "$fixture/ai/pi"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nprintf "ordinary:%%s\\n" "$*" >>"$CALLS"\n' >"$fixture/ai/pi/install.sh"
  run make -s -C "$fixture" ai
  [ "$status" -eq 0 ]
  run make -s -C "$fixture" ai-check
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = $'ordinary:\nordinary:--check' ]
}

@test "custom-domain Make targets are explicit and ordinary AI targets are unchanged" {
  fixture="$TEST_ROOT/domain-make"
  mkdir -p "$fixture/ai/pi/webui" "$fixture/ai/pi"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nprintf "domain:%%s\\n" "$*" >>"$CALLS"\n' \
    >"$fixture/ai/pi/webui/custom-domain.sh"
  printf '#!/usr/bin/env bash\nprintf "ordinary:%%s\\n" "$*" >>"$CALLS"\n' \
    >"$fixture/ai/pi/install.sh"

  run make -s -C "$fixture" ai-webui-domain-check
  [ "$status" -eq 0 ]
  run make -s -C "$fixture" ai-webui-domain-setup
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = $'domain:check\ndomain:setup' ]

  : >"$CALLS"
  run make -s -C "$fixture" ai
  [ "$status" -eq 0 ]
  run make -s -C "$fixture" ai-check
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = $'ordinary:\nordinary:--check' ]
  ! grep -q '^domain:' "$CALLS"

  # The two Web UI recipes stay isolated from the custom-domain subsystem as
  # well: they invoke only install.sh. The one intended behavior change is
  # reached transitively through `tailscale.sh check`, which install.sh
  # --check runs, and which now accepts empty or the raw route rather than
  # the legacy route.
  : >"$CALLS"
  printf '#!/usr/bin/env bash\nprintf "webui:%%s\\n" "$*" >>"$CALLS"\n' \
    >"$fixture/ai/pi/webui/install.sh"
  chmod +x "$fixture/ai/pi/webui/install.sh" "$fixture/ai/pi/webui/custom-domain.sh"
  run make -s -C "$fixture" ai-webui
  [ "$status" -eq 0 ]
  run make -s -C "$fixture" ai-webui-check
  [ "$status" -eq 0 ]
  [ "$(<"$CALLS")" = $'webui:--apply\nwebui:--check' ]
  ! grep -q '^domain:' "$CALLS"
  grep -Fq 'require_route_state empty raw-exact' "$REPO_ROOT/ai/pi/webui/tailscale.sh"
}

@test "custom-domain runbook documents the complete live-operation sequence" {
  runbook="$REPO_ROOT/ai/pi/webui/README.md"
  for text in \
    'pi.dpao.la' \
    'A 100.84.88.33' \
    'Certificate Transparency' \
    'DNS-rebinding' \
    '/etc/credstore.encrypted/godaddy-api-token' \
    'Caddy `v2.11.4`' \
    '127.0.0.1:8443' \
    'Firstp1ck' \
    'Funnel' \
    'make ai-webui-domain-check' \
    'make ai-webui-domain-setup' \
    'custom-domain.sh migrate' \
    'custom-domain.sh rollback' \
    'custom-domain.sh rollback --full' \
    'tailscale.sh serve-legacy' \
    'HTTPS 443 -> http://127.0.0.1:31415' \
    'TCP 443 -> tcp://127.0.0.1:8443' \
    'browser WebSockets disconnect' \
    'Pi drift' \
    'separate approval' \
    'certificates' \
    'trusted' \
    'off-tailnet' \
    'restart' \
    'reboot' \
    '.ts.net` URL is no longer valid' \
    'classic GoDaddy' \
    'deprecated' \
    '_acme-challenge.pi.dpao.la' \
    'empty or exactly the raw route' \
    'refused' \
    'sudo systemd-creds encrypt --name=godaddy-api-token'; do
    grep -Fq -- "$text" "$runbook"
  done
  # The automatic-restoration claim must not be unqualified.
  ! grep -Fq 'Any preflight, verification, or confirmation failure automatically restores' "$runbook"
}

@test "runbook documents setup trust boundary accepted limitations and rollback" {
  runbook="$REPO_ROOT/ai/pi/webui/README.md"
  for text in 'make ai-webui-check' 'make ai-webui' 'http://127.0.0.1:31415' \
    'full authority of the WSL account' 'loopback-only' 'initial landing worktree' \
    'other project tabs' 'permission modal' 'Restart' 'Update the pins' 'preserves' \
    'serve-legacy-off' 'custom-domain.sh rollback --full' \
    'before Pi or mise is upgraded or removed' \
    '--remove-runtime' '--remove-worktree' 'journalctl --user -u pi-webui.service -e'; do
    grep -Fq -- "$text" "$runbook"
  done
}

@test "public READMEs link to the Web UI runbook" {
  grep -Fq '[Pi Web UI](ai/pi/webui/README.md)' "$REPO_ROOT/README.md"
  grep -Fq '[Pi Web UI](pi/webui/README.md)' "$REPO_ROOT/ai/README.md"
}

@test "Caddy source fixes hostname listener backend and DNS provider" {
  make_webui_fixture
  run_custom_domain_function 'render_caddyfile'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'admin off'* ]]
  [[ "$output" == *$'auto_https disable_redirects'* ]]
  [[ "$output" == *$'https_port 8443'* ]]
  [[ "$output" == *$'protocols h1 h2'* ]]
  [[ "$output" == *$'pi.dpao.la {'* ]]
  [[ "$output" == *$'bind 127.0.0.1'* ]]
  [[ "$output" == *$'api_token {env.GODADDY_API_TOKEN}'* ]]
  [[ "$output" == *$'reverse_proxy 127.0.0.1:31415'* ]]
  [[ "$output" != *'0.0.0.0'* ]]
  [[ "$output" != *'::'* ]]
}

@test "Caddy unit uses encrypted credential and no remote admin or secret argv" {
  make_webui_fixture
  run_custom_domain_function 'render_caddy_unit'
  [ "$status" -eq 0 ]
  [[ "$output" == *'LoadCredentialEncrypted=godaddy-api-token'* ]]
  [[ "$output" == *'DynamicUser=yes'* ]]
  [[ "$output" == *'StateDirectory=pi-webui-caddy'* ]]
  [[ "$output" == *'Restart=on-failure'* ]]
  [[ "$output" != *'GODADDY_API_TOKEN='* ]]
  [[ "$output" != *'--environ'* ]]
}

@test "tracked custom-domain files contain no credential or private key" {
  run grep -REn --include='*' \
    '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|[A-Za-z0-9]{20,}:[A-Za-z0-9]{20,})' \
    "$REPO_ROOT/ai/pi/webui"
  [ "$status" -eq 1 ]
}

@test "Caddy source identity is pinned by exact SHA-256 and rejects harmless template drift" {
  make_webui_fixture
  run_custom_domain_function 'validate_caddy_source'
  [ "$status" -eq 0 ]

  printf '\n# harmless trailing comment\n' >>"$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in"
  run_custom_domain_function 'validate_caddy_source'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Caddyfile SHA-256'* ]]

  cp "$REPO_ROOT/ai/pi/webui/Caddyfile.in" "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in"
  printf '\n# harmless trailing comment\n' >>"$WEBUI_FIXTURE/ai/pi/webui/pi-webui-caddy.service.in"
  run_custom_domain_function 'validate_caddy_source'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Caddy unit template SHA-256'* ]]
}

@test "custom-domain preflight requires active exact Firstp1ck before credential access" {
  prepare_custom_domain_check legacy-exact
  rm -rf "$INSTALLED_RUNTIME"
  run_custom_domain check
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed runtime is unavailable'* ]]
  [ ! -s "$CREDENTIAL_CALLS" ]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "current Tailscale IPv4 requires exactly one online 100.64.0.0/10 address" {
  prepare_custom_domain_check empty
  run_custom_domain_function 'current_tailscale_ipv4'
  [ "$status" -eq 0 ]
  [ "$output" = 100.64.0.1 ]
}

@test "DNS must be one A equal to current Tailscale IPv4 with no aliases" {
  prepare_custom_domain_check legacy-exact
  write_dns A 100.64.0.1
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -eq 0 ]

  write_dns A 100.64.0.2
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale Tailscale IPv4'* ]]

  write_dns CNAME personal-desktop.tail74aee.ts.net.
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
}

@test "DNS validation rejects missing multiple AAAA absent-NS offline and non-Tailscale addresses" {
  prepare_custom_domain_check legacy-exact

  write_dns A
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'expected exactly one A answer'* ]]

  write_dns A 100.64.0.1 100.64.0.2
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'expected exactly one A answer'* ]]

  write_dns AAAA 2001:db8::1
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected AAAA answer'* ]]

  write_dns A 100.64.0.1
  : >"$TEST_ROOT/dns-ns"
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
  [[ "$output" == *'no authoritative name server'* ]]
  write_ns ns1.example.test.

  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","Self":{"Online":false,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["100.64.0.1"]}}' >"$TEST_ROOT/tailscale-status.json"
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]

  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","Self":{"Online":true,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["100.64.0.1","100.64.0.2"]}}' >"$TEST_ROOT/tailscale-status.json"
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]

  printf '%s\n' '{"BackendState":"Running","Version":"1.102.3","Self":{"Online":true,"DNSName":"wsl.test.ts.net.","TailscaleIPs":["10.0.0.5"]}}' >"$TEST_ROOT/tailscale-status.json"
  run_custom_domain_function 'validate_public_dns'
  [ "$status" -ne 0 ]
}

@test "installed Caddy validation requires the exact managed Caddy version and GoDaddy module" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -eq 0 ]

  export CADDY_VERSION_OUTPUT='v2.10.0 h1:test'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not v2.11.4'* ]]
  export CADDY_VERSION_OUTPUT='v2.11.4 h1:test'

  export CADDY_MODULES='dns.providers.cloudflare'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must list exactly one dns.providers.godaddy module; found 0'* ]]

  export CADDY_MODULES='  dns.providers.godaddy (github.com/foreign/godaddy)'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must map module dns.providers.godaddy to exactly'* ]]

  export CADDY_MODULES='dns.providers.godaddy github.com/foreign/godaddy'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must map module dns.providers.godaddy to exactly'* ]]
  [[ "$output" == *'github.com/foreign/godaddy'* ]]

  # A local replace directive or a module-info error annotation changes the
  # provenance of an otherwise correctly named package and must be refused.
  export CADDY_MODULES='dns.providers.godaddy github.com/caddy-dns/godaddy => ../local-godaddy'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must map module dns.providers.godaddy to exactly'* ]]

  export CADDY_MODULES='dns.providers.godaddy github.com/caddy-dns/godaddy [missing go.mod]'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must map module dns.providers.godaddy to exactly'* ]]

  # A foreign module whose name merely contains the expected module name as a
  # substring (the exact shape a bare substring check would have accepted)
  # must also be rejected.
  export CADDY_MODULES='dns.providers.godaddyfoo github.com/attacker/evil'
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must list exactly one dns.providers.godaddy module; found 0'* ]]
}

@test "installed Caddy validation requires byte-identical root-owned managed artifacts" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -eq 0 ]

  printf '\nforeign\n' >>"$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed Caddyfile differs'* ]]
  cp "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in" "$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"

  printf '\nforeign\n' >>"$CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed Caddy unit differs'* ]]
  make_caddy_fixture

  export CADDY_FOREIGN_OWNER=1
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be owned by root'* ]]
  unset CADDY_FOREIGN_OWNER

  rm "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'managed Caddy binary is unavailable'* ]]
}

@test "installed Caddy validation requires the managed system service to be active" {
  prepare_custom_domain_check legacy-exact
  export CADDY_SERVICE_INACTIVE=1
  run_custom_domain_function 'validate_installed_caddy'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Caddy service is not active'* ]]
}

@test "Caddy listener validation rejects wildcard IPv6 LAN UDP and port 80" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -eq 0 ]

  local shape
  for shape in \
    'LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:*' \
    'LISTEN 0 4096 [::]:8443 [::]:*' \
    'LISTEN 0 4096 172.20.1.4:8443 0.0.0.0:*' \
    'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*' \
    $'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*\nLISTEN 0 4096 172.20.1.4:8443 0.0.0.0:*'; do
    printf '%s\n' "$shape" >"$TEST_ROOT/caddy-listeners"
    run_custom_domain_function 'validate_caddy_listener'
    [ "$status" -ne 0 ]
  done
  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners"

  printf '%s\n' 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners-udp"
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -ne 0 ]
  [[ "$output" == *'UDP listener on port 8443'* ]]
  : >"$TEST_ROOT/caddy-listeners-udp"

  export LAN_8443_REACHABLE=1
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Caddy is reachable on LAN address'* ]]
  unset LAN_8443_REACHABLE

  export LAN_31415_REACHABLE=1
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Pi Web UI is reachable on LAN address'* ]]
  unset LAN_31415_REACHABLE
}

@test "listener checks stay closed against a large listener table" {
  prepare_custom_domain_check legacy-exact

  # A forbidden listener that matches early, followed by enough further
  # output to fill a pipe buffer: a `grep -q` short-circuit would SIGPIPE the
  # producer and, under `set -o pipefail`, be read as "no match".
  {
    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*'
    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*'
    for i in $(seq 1 20000); do
      printf 'LISTEN 0 4096 10.%d.%d.%d:9000 0.0.0.0:*\n' $((i / 65536 % 256)) $((i / 256 % 256)) $((i % 256))
    done
  } >"$TEST_ROOT/caddy-listeners"
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Caddy listener on port 80'* ]]

  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners"
  {
    printf '%s\n' 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:*'
    for i in $(seq 1 20000); do
      printf 'UNCONN 0 0 10.%d.%d.%d:9000 0.0.0.0:*\n' $((i / 65536 % 256)) $((i / 256 % 256)) $((i % 256))
    done
  } >"$TEST_ROOT/caddy-listeners-udp"
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -ne 0 ]
  [[ "$output" == *'UDP listener on port 8443'* ]]
  : >"$TEST_ROOT/caddy-listeners-udp"

  # A large but clean table still passes.
  {
    printf '%s\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*'
    for i in $(seq 1 20000); do
      printf 'LISTEN 0 4096 10.%d.%d.%d:9000 0.0.0.0:*\n' $((i / 65536 % 256)) $((i / 256 % 256)) $((i % 256))
    done
  } >"$TEST_ROOT/caddy-listeners"
  run_custom_domain_function 'validate_caddy_listener'
  [ "$status" -eq 0 ]
}

@test "Caddy TLS health validation rejects untrusted invalid or unhealthy backend certificates" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -eq 0 ]

  export TLS_TRUST_FAIL=1
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not trusted'* ]]
  unset TLS_TRUST_FAIL

  export TLS_INVALID=1
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'invalid, expired, or hostname-mismatched'* ]]
  unset TLS_INVALID

  export CADDY_HEALTH_FAIL=1
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'health endpoint failed'* ]]
  unset CADDY_HEALTH_FAIL

  export CADDY_HEALTH_JSON='{"ok":false}'
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'health identity is invalid'* ]]
}

@test "network and TLS probes are explicitly bounded and fail on a stall" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -eq 0 ]

  # Every probing curl carries an explicit connect and total bound.
  local line
  while IFS= read -r line; do
    [[ "$line" == *'--connect-timeout '* ]]
    [[ "$line" == *'--max-time '* ]]
  done < <(grep '^curl ' "$CALLS")

  # openssl s_client is bounded by an explicit external timeout.
  run_custom_domain_function 'command -v timeout >/dev/null && printf found\\n'
  [ "$status" -eq 0 ]
  export TLS_STALL=1
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not trusted'* ]]
  unset TLS_STALL

  # A stalled proxied health request is a failure, not a hang.
  export CURL_STALL=1
  run_custom_domain_function 'validate_caddy_tls_health'
  [ "$status" -ne 0 ]
  [[ "$output" == *'health endpoint failed'* ]]
  unset CURL_STALL

  # The documented readiness bound is enforced by wall clock, not by an
  # arithmetic sum: the authoritative listener check probes every
  # non-Tailscale global IPv4 address, so its cost scales with the host's
  # interface count and cannot be added up in advance.
  run_custom_domain_function 'caddy_ready_deadline; printf "%s %s\\n" "$CADDY_READY_DEADLINE" "$CADDY_READY_KILL_GRACE"'
  [ "$status" -eq 0 ]
  deadline=${output% *}
  kill_grace=${output#* }
  [ $((deadline + kill_grace)) -le 300 ]

  # The retry loop only paces inside that deadline: its own worst case plus
  # the authoritative TLS/health validation that always runs once more after
  # the loop exits (bounded by TLS_HANDSHAKE_TIMEOUT + PROBE_MAX_TIME) still
  # fits, so a still-unready service normally fails with the exact remaining
  # boundary error rather than with the deadline error.
  run_custom_domain_function 'caddy_ready_budget; printf "%s %s\\n" "$CADDY_READY_ATTEMPTS" "$CADDY_READY_INTERVAL"'
  [ "$status" -eq 0 ]
  attempts=${output% *}
  interval=${output#* }
  run_custom_domain_function 'printf "%s\\n" "$CADDY_READY_PROBE_TIMEOUT"'
  [ "$status" -eq 0 ]
  probe=$output
  run_custom_domain_function 'printf "%s %s\\n" "$TLS_HANDSHAKE_TIMEOUT" "$PROBE_MAX_TIME"'
  [ "$status" -eq 0 ]
  handshake_timeout=${output% *}
  probe_max_time=${output#* }
  post_loop_validation=$((handshake_timeout + probe_max_time))
  [ $((attempts * probe + (attempts - 1) * interval + post_loop_validation)) -le "$deadline" ]
}

@test "condition-context helpers refuse output from a failing command" {
  prepare_custom_domain_check legacy-exact

  # Each stub prints otherwise-valid output and then exits nonzero: no
  # classification, DNS view, or check may succeed on it.
  stub_command tailscale 'case "$*" in
    "version --json") printf "{\"short\":\"1.102.3\"}\n"; exit 1 ;;
    "status --json") cat "$TEST_ROOT/tailscale-status.json" ;;
    "serve status --json") cat "$TEST_ROOT/route.json" ;;
    "funnel status --json") cat "$TEST_ROOT/funnel.json" ;;
    "serve status") cat "$TEST_ROOT/route.txt" ;;
    *) exit 98 ;;
  esac'
  run_tailscale_function 'route_state'
  [ "$status" -ne 0 ]
  [[ "$output" != *legacy-exact* && "$output" != *raw-exact* ]]
  run_tailscale_function 'if require_tailscale_version; then printf "accepted\n"; fi'
  [[ "$output" != *accepted* ]]
  run_custom_domain check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]

  : >"$MUTATION_CALLS"
  stub_command dig 'shift
    case "$1" in
      NS) cat "$TEST_ROOT/dns-ns" ;;
      A) cat "$TEST_ROOT/dns-a"; exit 1 ;;
      AAAA) cat "$TEST_ROOT/dns-aaaa" ;;
      CNAME) cat "$TEST_ROOT/dns-cname" ;;
      *) exit 1 ;;
    esac'
  stub_command tailscale 'case "$*" in
    "status --json") cat "$TEST_ROOT/tailscale-status.json" ;;
    "version --json") printf "{\"short\":\"1.102.3\"}\n" ;;
    "serve status --json") cat "$TEST_ROOT/route.json" ;;
    "funnel status --json") cat "$TEST_ROOT/funnel.json" ;;
    "serve status") cat "$TEST_ROOT/route.txt" ;;
    *) exit 98 ;;
  esac'
  run_custom_domain_function 'if validate_dns_view "" 100.64.0.1; then printf "accepted\n"; fi'
  [[ "$output" != *accepted* ]]
  [[ "$output" == *'cannot query A'* ]]
  run_custom_domain check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "check_domain classifies ready-to-migrate raw-exact and pre-install states and refuses foreign routes" {
  prepare_custom_domain_check legacy-exact
  run_custom_domain check
  [ "$status" -eq 0 ]
  [[ "$output" == *'ready-to-migrate'* ]]
  [ ! -s "$MUTATION_CALLS" ]

  write_route raw
  run_custom_domain check
  [ "$status" -eq 0 ]
  [[ "$output" == *'raw-exact'* ]]
  [ ! -s "$MUTATION_CALLS" ]

  write_route empty
  rm -rf "$CADDY_ROOT/usr/local/lib/pi-webui" "$CADDY_ROOT/etc/pi-webui-caddy" \
    "$CADDY_ROOT/etc/systemd/system"
  run_custom_domain check
  [ "$status" -eq 0 ]
  [[ "$output" == *'not yet installed'* ]]
  [ ! -s "$MUTATION_CALLS" ]

  write_route foreign
  run_custom_domain check
  [ "$status" -ne 0 ]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "check_domain treats a leftover managed Caddy entrypoint as a partial install, not pre-install" {
  prepare_custom_domain_check empty
  rm -rf "$CADDY_ROOT/usr/local/lib/pi-webui/caddy" "$CADDY_ROOT/etc/pi-webui-caddy" \
    "$CADDY_ROOT/etc/systemd/system"
  [ -e "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint" ]
  run_custom_domain check
  [ "$status" -ne 0 ]
  [[ "$output" != *'not yet installed'* ]]
  [[ "$output" == *'managed Caddy binary is unavailable'* ]]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "custom-domain CLI accepts check setup migrate and rollback verbs" {
  make_webui_fixture
  run_custom_domain
  [ "$status" -eq 2 ]
  [[ "$output" == *'usage: '*'check|setup|migrate|rollback'* ]]
  [[ "$output" == *'--full'* ]]

  run_custom_domain bogus
  [ "$status" -eq 2 ]

  run_custom_domain check setup
  [ "$status" -eq 2 ]

  run_custom_domain rollback --bogus
  [ "$status" -eq 2 ]

  run_custom_domain check --full
  [ "$status" -eq 2 ]
}

@test "setup validates Firstp1ck route DNS and credential before publication" {
  prepare_custom_domain_setup legacy-exact
  run_custom_domain setup
  [ "$status" -eq 0 ]
  first_build=$(grep -n '^go ' "$CALLS" | cut -d: -f1)
  first_publish=$(grep -n '^sudo install ' "$CALLS" | cut -d: -f1 | head -1)
  credential=$(grep -n '^credential-check$' "$CALLS" | cut -d: -f1)
  [ "$credential" -lt "$first_build" ]
  [ "$first_build" -lt "$first_publish" ]
  ! grep -F 'tailscale serve' "$CALLS"
}

@test "setup publishes exact managed artifacts and leaves the route and credential untouched" {
  prepare_custom_domain_setup legacy-exact
  route_before=$(cat "$TEST_ROOT/route.json")
  run_custom_domain setup
  [ "$status" -eq 0 ]
  [[ "$output" == *'ready-to-migrate'* ]]

  # The exact pinned build, in the exact staged validation order.
  grep -Fq 'go run github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 build v2.11.4 --with github.com/caddy-dns/godaddy@v1.2.0 --output' "$CALLS"
  grep -Fq 'caddy adapt token=placeholder:placeholder' "$CALLS"
  grep -q '^systemd-analyze verify ' "$CALLS"

  # The four managed artifacts, with the exact published modes.
  managed=()
  while IFS= read -r path; do managed+=("$path"); done < <(managed_caddy_paths)
  modes=(755 755 644 644)
  for index in 0 1 2 3; do
    [ -f "${managed[index]}" ]
    [ "$(/usr/bin/stat -c %a "${managed[index]}")" = "${modes[index]}" ]
  done
  grep -Fq 'candidate build' "${managed[0]}"
  cmp "${managed[1]}" "$WEBUI_FIXTURE/ai/pi/webui/caddy-entrypoint.sh"
  cmp "${managed[2]}" "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in"
  grep -Fq "ExecStart=${managed[1]}" "${managed[3]}"

  # The service is enabled and running, the staging directory is gone, and
  # neither the encrypted credential nor the Tailscale route was touched.
  [ -f "$TEST_ROOT/caddy-enabled" ]
  [ -f "$TEST_ROOT/caddy-active" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
  ! grep -rqF 'encrypted-credential-blob' "$CADDY_ROOT/usr" "$CADDY_ROOT/etc/pi-webui-caddy" \
    "$CADDY_ROOT/etc/systemd"
  [ "$(cat "$TEST_ROOT/route.json")" = "$route_before" ]

  # The published state now satisfies the independent read-only check.
  run_custom_domain check
  [ "$status" -eq 0 ]
  [[ "$output" == *'ready-to-migrate'* ]]
}

@test "setup refuses Pi drift runtime service version route and DNS failures without mutation" {
  prepare_custom_domain_setup legacy-exact
  before=$(fingerprint_paths "$CADDY_ROOT")

  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.85.0","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_PACKAGE/package.json"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'Pi must be available through mise'* || "$output" == *'0.84.4'* ]]
  printf '%s\n' \
    '{"name":"@earendil-works/pi-coding-agent","version":"0.84.4","bin":{"pi":"dist/bundle/cli.js"}}' \
    >"$PI_PACKAGE/package.json"

  mv "$INSTALLED_RUNTIME" "$TEST_ROOT/runtime-away"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed runtime is unavailable'* ]]
  mv "$TEST_ROOT/runtime-away" "$INSTALLED_RUNTIME"

  export FIRSTPICK_INACTIVE=1
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'Pi Web UI service is not active'* ]]
  unset FIRSTPICK_INACTIVE

  export TAILSCALE_CLIENT_VERSION=1.100.0
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported Tailscale client or daemon version'* ]]
  unset TAILSCALE_CLIENT_VERSION

  write_route raw
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Tailscale route state'* ]]
  write_route legacy-exact

  write_dns A 100.64.0.9
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale Tailscale IPv4'* ]]
  write_dns A 100.64.0.1

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  ! grep -q '^go ' "$CALLS"
  [ ! -s "$CREDENTIAL_CALLS" ]
  assert_no_caddy_publication
}

@test "setup refuses credential build module adapt and unit verification failures without publication" {
  prepare_custom_domain_setup legacy-exact
  before=$(fingerprint_paths "$CADDY_ROOT")

  mv "$CADDY_CREDENTIAL" "$TEST_ROOT/credential-away"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'encrypted GoDaddy credential is unavailable'* ]]
  mv "$TEST_ROOT/credential-away" "$CADDY_CREDENTIAL"

  export CREDENTIAL_MODE=640
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'must not be group- or world-accessible'* ]]
  unset CREDENTIAL_MODE

  export CREDENTIAL_OWNER=1000
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be owned by root'* ]]
  unset CREDENTIAL_OWNER

  export GODADDY_API_STATUS=401
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'HTTP 401'* ]]
  [[ "$output" != *testkey* && "$output" != *testsecret* ]]
  export GODADDY_API_STATUS=403
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'HTTP 403'* ]]
  unset GODADDY_API_STATUS
  ! grep -q '^go ' "$CALLS"

  export FAIL_POINT=build
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'pinned Caddy candidate build failed'* ]]

  export FAIL_POINT=
  export CADDY_MODULES='dns.providers.cloudflare github.com/caddy-dns/cloudflare'
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'must list exactly one dns.providers.godaddy module'* ]]
  unset CADDY_MODULES

  export FAIL_POINT=adapt
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'candidate Caddy configuration failed validation'* ]]

  export FAIL_POINT=unit-verify
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'failed systemd verification'* ]]
  unset FAIL_POINT

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  assert_no_caddy_publication
}

@test "setup refuses a malformed credential through the shipped validator without a network call" {
  prepare_custom_domain_setup legacy-exact
  before=$(fingerprint_paths "$CADDY_ROOT")
  # Restore the real Node runtime: the shipped validator itself must reject a
  # credential that is not exactly key:secret before it opens any connection.
  stub_command node 'exec "$SANDBOX_TOOL_BIN/node" "$@"'
  export GODADDY_TOKEN_FIXTURE='not-a-valid-token'
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'GoDaddy DNS API credential validation failed'* ]]
  [[ "$output" != *not-a-valid-token* ]]
  ! grep -q '^go ' "$CALLS"
  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  assert_no_caddy_publication
}

@test "setup refuses foreign existing managed Caddy artifacts before building" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")

  printf '\nforeign\n' >>"$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to replace a foreign managed Caddyfile'* ]]
  cp "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in" "$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"

  printf '\nforeign\n' >>"$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to replace a foreign managed Caddy entrypoint'* ]]
  cp "$WEBUI_FIXTURE/ai/pi/webui/caddy-entrypoint.sh" \
    "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"

  printf '\nforeign\n' >>"$CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to replace a foreign managed Caddy unit'* ]]
  make_caddy_fixture

  export CADDY_FOREIGN_OWNER=1
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be owned by root'* ]]
  unset CADDY_FOREIGN_OWNER

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  ! grep -q '^go ' "$CALLS"
  assert_no_caddy_publication
}

@test "setup refuses a foreign or unidentifiable existing Caddy binary before building" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")

  export CADDY_VERSION_OUTPUT='v2.10.0 h1:other'
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not v2.11.4'* ]]
  export CADDY_VERSION_OUTPUT='v2.11.4 h1:test'

  export CADDY_MODULES='dns.providers.cloudflare github.com/caddy-dns/cloudflare'
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'must list exactly one dns.providers.godaddy module'* ]]
  unset CADDY_MODULES

  export CADDY_MODULE_VERSIONS='dns.providers.godaddy v1.1.0 github.com/caddy-dns/godaddy'
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'v1.2.0'* ]]
  unset CADDY_MODULE_VERSIONS

  chmod 0644 "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'not executable'* ]]
  chmod 0755 "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  ! grep -q '^go ' "$CALLS"
  assert_no_caddy_publication
}

@test "setup aborts before publication when a systemd state query fails" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")

  local query
  for query in is-enabled is-active; do
    : >"$CALLS"
    : >"$MUTATION_CALLS"
    export STATE_QUERY_FAILS="$query"
    run_custom_domain setup
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot determine"* ]]
    [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
    ! grep -q '^sudo install ' "$CALLS"
    ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
    unset STATE_QUERY_FAILS
  done
}

@test "setup restores after a mutating systemctl call that then fails" {
  prepare_custom_domain_setup legacy-exact
  local scenario
  for scenario in enable-partial restart-partial; do
    : >"$CALLS"
    : >"$MUTATION_CALLS"
    export FAIL_POINT="$scenario"
    run_custom_domain setup
    [ "$status" -ne 0 ]

    while IFS= read -r path; do
      [ ! -e "$path" ]
    done < <(managed_caddy_paths)
    [ ! -e "$TEST_ROOT/caddy-enabled" ]
    [ ! -e "$TEST_ROOT/caddy-active" ]
    [ ! -e "$TEST_ROOT/caddy-running" ]
    grep -q '^systemctl disable pi-webui-caddy.service$' "$MUTATION_CALLS"
    [ -f "$CADDY_CREDENTIAL" ]
    ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
    unset FAIL_POINT
  done
}

@test "setup restores an absent prior installation after a service start failure" {
  prepare_custom_domain_setup legacy-exact
  export FAIL_POINT=caddy-start
  run_custom_domain setup
  [ "$status" -ne 0 ]

  while IFS= read -r path; do
    [ ! -e "$path" ]
  done < <(managed_caddy_paths)
  [ ! -e "$TEST_ROOT/caddy-enabled" ]
  [ ! -e "$TEST_ROOT/caddy-active" ]
  grep -q '^systemctl disable pi-webui-caddy.service$' "$MUTATION_CALLS"
  [ "$(grep -c '^systemctl daemon-reload$' "$MUTATION_CALLS")" -eq 2 ]
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  ! grep -q 'tailscale serve' "$CALLS"
}

@test "setup restarts an active prior installation before readiness and leaves it active" {
  prepare_custom_domain_setup legacy-exact prior
  [ "$(cat "$TEST_ROOT/caddy-running")" = '# installed fixture' ]
  run_custom_domain setup
  [ "$status" -eq 0 ]

  # The process actually in memory is the published candidate, not the prior
  # binary an already-active unit would have kept running through a no-op
  # start.
  [ "$(cat "$TEST_ROOT/caddy-running")" = '# candidate build' ]
  grep -Fq 'candidate build' "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"
  grep -q '^systemctl restart pi-webui-caddy.service$' "$MUTATION_CALLS"
  ! grep -q '^systemctl start pi-webui-caddy.service$' "$MUTATION_CALLS"

  # The restart precedes every readiness probe of the proxied endpoint.
  restart=$(grep -n '^sudo systemctl restart pi-webui-caddy.service$' "$CALLS" | cut -d: -f1 | head -1)
  health=$(grep -n 'https://pi.dpao.la:8443/api/health' "$CALLS" | cut -d: -f1 | head -1)
  [ -n "$restart" ]
  [ -n "$health" ]
  [ "$restart" -lt "$health" ]

  [ -f "$TEST_ROOT/caddy-active" ]
  [ -f "$TEST_ROOT/caddy-enabled" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  ! grep -q 'tailscale serve' "$CALLS"
}

@test "the bounded readiness worker runs every authoritative check inside one deadline" {
  prepare_custom_domain_setup legacy-exact prior

  # The worker runs in a subprocess that re-sources the script, so success
  # here also proves the subprocess inherited the Bats-only path overrides,
  # the readiness budget override, and the stubbed commands: the managed
  # artifacts it validates exist only under the test caddy root.
  run_custom_domain_function 'wait_for_caddy_ready'
  [ "$status" -eq 0 ]
  grep -F -- '--resolve pi.dpao.la:8443:127.0.0.1' "$CALLS"

  # A failing authoritative check still reports its own exact boundary error
  # through the deadline wrapper, not a generic timeout.
  export CADDY_HEALTH_FAIL=1
  run_custom_domain_function 'wait_for_caddy_ready'
  [ "$status" -ne 0 ]
  [[ "$output" == *'health endpoint failed'* ]]
  unset CADDY_HEALTH_FAIL

  # The deadline override is a Bats-only override like the budget.
  run_custom_domain_function 'unset PI_WEBUI_TESTING; PI_WEBUI_TEST_READY_DEADLINE=1 caddy_ready_deadline'
  [ "$status" -ne 0 ]
  [[ "$output" == *'test overrides are unavailable outside Bats'* ]]
}

@test "setup restores prior state when readiness outlasts its wall-clock deadline" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")

  # The readiness signal never answers and one pacing sleep alone outlasts
  # the whole deadline, so the operation is cut off by wall clock instead of
  # running to the end of its own arithmetic budget.
  export CADDY_HEALTH_FAIL=1 PI_WEBUI_TEST_READY_DEADLINE=1 PI_WEBUI_TEST_READY_BUDGET=2:5
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'readiness exceeded its 1-second deadline'* ]]

  # Deadline expiry is an ordinary readiness failure: the prior installation
  # is restored exactly and staging is removed.
  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  ! grep -qF 'candidate build' "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"
  [ -f "$TEST_ROOT/caddy-enabled" ]
  [ -f "$TEST_ROOT/caddy-active" ]
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  ! grep -q 'tailscale serve' "$CALLS"
}

@test "setup restores prior files enablement and activity after a TLS health failure" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")
  export CADDY_HEALTH_FAIL=1
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'health endpoint failed'* ]]

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  ! grep -qF 'candidate build' "$CADDY_ROOT/usr/local/lib/pi-webui/caddy"
  [ "$(cat "$TEST_ROOT/caddy-running")" = '# installed fixture' ]
  [ -f "$TEST_ROOT/caddy-enabled" ]
  [ -f "$TEST_ROOT/caddy-active" ]
  grep -q '^systemctl stop pi-webui-caddy.service$' "$MUTATION_CALLS"
  grep -q '^systemctl start pi-webui-caddy.service$' "$MUTATION_CALLS"
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  ! grep -q 'tailscale serve' "$CALLS"
}

@test "setup restores prior state after a partial publication failure" {
  prepare_custom_domain_setup legacy-exact prior
  before=$(fingerprint_paths "$CADDY_ROOT")
  export FAIL_POINT=publish
  run_custom_domain setup
  [ "$status" -ne 0 ]
  grep -q '^sudo install ' "$CALLS"

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
  [ -f "$TEST_ROOT/caddy-enabled" ]
  [ -f "$TEST_ROOT/caddy-active" ]
  ! compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
}

@test "setup reports the retained staging path when restoration fails" {
  prepare_custom_domain_setup legacy-exact prior
  export CADDY_HEALTH_FAIL=1 RESTORE_FAIL=1
  run_custom_domain setup
  [ "$status" -ne 0 ]
  [[ "$output" == *'restoration failed; preserving staging path: '*"$STATE_ROOT/.caddy-setup."* ]]
  compgen -G "$STATE_ROOT/.caddy-setup.*" >/dev/null
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]
}

@test "migration removes exact legacy route publishes raw and verifies before confirmation" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes
  run_custom_domain migrate
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --https=443 off' "$CALLS"
  grep -Fx 'sudo tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443' "$CALLS"
  [ "$(route_call_order)" = $'legacy-off\nraw-on' ]
  [ "$(current_route_fixture)" = raw-exact ]

  # The literal plan is displayed, without any credential material.
  for line in 'DNS: pi.dpao.la A 100.64.0.1' \
    'Credential: LoadCredentialEncrypted=godaddy-api-token' \
    'Old: HTTPS 443 -> http://127.0.0.1:31415' \
    'New: TCP 443 -> tcp://127.0.0.1:8443' \
    'Rollback: remove TCP 443, then restore HTTPS 443 -> http://127.0.0.1:31415' \
    'Interruption: normally several seconds; browser WebSockets disconnect'; do
    grep -Fxq -- "$line" <<<"$output"
  done
  [[ "$output" == *"Unit: $CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"* ]]
  [[ "$output" != *encrypted-credential-blob* ]]

  # The actual Serve JSON is captured for schema confirmation, and the tailnet
  # address itself is verified before success is reported.
  [[ "$output" == *'"TCPForward":"127.0.0.1:8443"'* ]]
  grep -F -- '--resolve pi.dpao.la:443:100.64.0.1' "$CALLS"
  [[ "$output" == *'https://wsl.test.ts.net'*'no longer valid'* ]]
  [ ! -s "$MUTATION_CALLS" ]
  # Migration never reads, decrypts, or reports the GoDaddy credential.
  [ ! -s "$CREDENTIAL_CALLS" ]
}

@test "migration refuses operator rejection and EOF without mutation" {
  prepare_custom_domain_migration legacy-exact
  export TAILNET_CLIENT_CONFIRM=yes

  export MIGRATION_CONFIRM=no
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'was not approved'* ]]
  [[ "$output" == *'DNS: pi.dpao.la A 100.64.0.1'* ]]
  assert_no_route_mutation

  reset_migration_state
  export MIGRATION_CONFIRM=eof
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'was not approved'* ]]
  assert_no_route_mutation

  reset_migration_state
  export MIGRATION_CONFIRM=maybe
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  assert_no_route_mutation
}

@test "migration refuses every preflight failure without route mutation" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes

  reset_migration_state raw
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Tailscale route state'* ]]
  assert_no_route_mutation raw-exact

  reset_migration_state
  write_dns A 100.64.0.9
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale Tailscale IPv4'* ]]
  assert_no_route_mutation
  write_dns A 100.64.0.1

  reset_migration_state
  export CADDY_SERVICE_INACTIVE=1
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'Caddy service is not active'* ]]
  assert_no_route_mutation
  unset CADDY_SERVICE_INACTIVE

  reset_migration_state
  printf '%s\n' 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:*' >"$TEST_ROOT/caddy-listeners-udp"
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'UDP listener on port 8443'* ]]
  assert_no_route_mutation
  : >"$TEST_ROOT/caddy-listeners-udp"

  reset_migration_state
  export TLS_TRUST_FAIL=1
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not trusted'* ]]
  assert_no_route_mutation
  unset TLS_TRUST_FAIL

  reset_migration_state
  export CADDY_HEALTH_FAIL=1
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'health endpoint failed'* ]]
  assert_no_route_mutation
  unset CADDY_HEALTH_FAIL

  reset_migration_state
  export TAILSCALE_CLIENT_VERSION=1.100.0
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'unsupported Tailscale client or daemon version'* ]]
  assert_no_route_mutation
  unset TAILSCALE_CLIENT_VERSION

  reset_migration_state
  mv "$INSTALLED_RUNTIME" "$TEST_ROOT/runtime-away"
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'installed runtime is unavailable'* ]]
  assert_no_route_mutation
  mv "$TEST_ROOT/runtime-away" "$INSTALLED_RUNTIME"
}

@test "migration restores legacy route after a failed legacy removal or raw publication" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes

  # The legacy removal itself fails: nothing was lost, so restoration reports
  # the already-published legacy route rather than mutating it again.
  reset_migration_state
  export FAIL_POINT=legacy-off
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [ ! -s "$ROUTE_ORDER" ]
  [ "$(current_route_fixture)" = legacy-exact ]
  [ "$(grep -c '^sudo tailscale serve' "$CALLS")" -eq 1 ]

  # The raw publication command fails after the legacy route is already gone.
  reset_migration_state
  export FAIL_POINT=raw-publish
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [ "$(route_call_order)" = $'legacy-off\nlegacy-on' ]
  [ "$(current_route_fixture)" = legacy-exact ]
  grep -Fx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$CALLS"
  unset FAIL_POINT

  # The raw publication reports success but the observed status does not match.
  reset_migration_state
  export RAW_PUBLISH_STICKS=1
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *'did not produce the exact route'* ]]
  [ "$(route_call_order)" = $'legacy-off\nlegacy-on' ]
  [ "$(current_route_fixture)" = legacy-exact ]
  unset RAW_PUBLISH_STICKS
}

@test "migration restores legacy route after post-publication verification failures" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes

  local scenario
  for scenario in TAILNET_HEALTH_FAIL TLS_TRUST_FAIL_AFTER_RAW CADDY_HEALTH_FAIL_AFTER_RAW; do
    reset_migration_state
    export TAILNET_CLIENT_CONFIRM=yes
    export "$scenario=1"
    run_custom_domain migrate
    [ "$status" -ne 0 ]
    [ "$(route_call_order)" = $'legacy-off\nraw-on\nraw-off\nlegacy-on' ]
    [ "$(current_route_fixture)" = legacy-exact ]
    grep -Fx 'sudo tailscale serve --tcp=443 off' "$CALLS"
    grep -Fx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$CALLS"
    [[ "$output" == *'legacy route restored'* ]]
    unset "$scenario"
  done

  # The trusted-tailnet-client confirmation is only reached after automated
  # verification, and rejecting or ending it restores the legacy route.
  local answer
  for answer in no eof; do
    reset_migration_state
    export TAILNET_CLIENT_CONFIRM="$answer"
    run_custom_domain migrate
    [ "$status" -ne 0 ]
    grep -F -- '--resolve pi.dpao.la:443:100.64.0.1' "$CALLS"
    [ "$(route_call_order)" = $'legacy-off\nraw-on\nraw-off\nlegacy-on' ]
    [ "$(current_route_fixture)" = legacy-exact ]
    [[ "$output" == *'operator rejection'* ]]
  done
}

@test "migration restores legacy route after INT and TERM signals" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=block

  local signal expected
  for signal in INT TERM; do
    [ "$signal" = INT ] && expected=130 || expected=143
    reset_migration_state
    rm -f "$STATE_ROOT/.migration-confirm-block"
    # Job control gives the background migration its own process group and the
    # default SIGINT disposition. Without it Bash marks asynchronous commands
    # SIG_IGN for INT, which no interactive operator ever sees.
    set -m
    "$WEBUI_FIXTURE/ai/pi/webui/custom-domain.sh" migrate >"$TEST_ROOT/migrate-$signal.out" 2>&1 &
    local pid=$!
    set +m
    local attempt
    for ((attempt = 0; attempt < 200; attempt++)); do
      [ -e "$STATE_ROOT/.migration-confirm-block" ] && break
      sleep 0.1
    done
    [ -e "$STATE_ROOT/.migration-confirm-block" ]
    kill -"$signal" "$pid"
    status=0
    wait "$pid" || status=$?
    [ "$status" -eq "$expected" ]
    [ "$(route_call_order)" = $'legacy-off\nraw-on\nraw-off\nlegacy-on' ]
    [ "$(current_route_fixture)" = legacy-exact ]
    grep -Fq "signal $signal" "$TEST_ROOT/migrate-$signal.out"
    grep -Fq 'legacy route restored' "$TEST_ROOT/migrate-$signal.out"
  done
}

@test "migration reports a foreign post-mutation route and never overwrites it" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes RAW_PUBLISH_FOREIGN=1
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [ "$(route_call_order)" = $'legacy-off\nraw-on' ]
  [ "$(current_route_fixture)" = foreign ]
  [ "$(grep -c '^sudo tailscale serve' "$CALLS")" -eq 2 ]
  [[ "$output" == *'refusing automatic restoration'* ]]
  [[ "$output" == *'RESTORATION FAILED'* ]]
  [[ "$output" == *'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415'* ]]
  [[ "$output" == *'other.test.ts.net'* ]]
}

@test "legacy route restoration mutates only the exact owned route" {
  prepare_custom_domain_migration empty

  run_tailscale_function 'serve_legacy'
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --bg --https=443 http://127.0.0.1:31415' "$CALLS"
  [ "$(current_route_fixture)" = legacy-exact ]

  : >"$CALLS"
  run_tailscale_function 'serve_legacy_off'
  [ "$status" -eq 0 ]
  grep -Fx 'sudo tailscale serve --https=443 off' "$CALLS"
  [ "$(current_route_fixture)" = empty ]

  # Idempotent from empty: no command runs at all.
  : >"$CALLS"
  run_tailscale_function 'serve_legacy_off'
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]

  # A foreign route is never removed or overwritten, including from a
  # condition context where errexit is suppressed inside the helper.
  write_route foreign
  : >"$CALLS"
  run_tailscale_function 'serve_legacy'
  [ "$status" -ne 0 ]
  ! grep -q 'tailscale serve' "$CALLS"
  run_tailscale_function 'if serve_legacy; then printf "published\n"; fi'
  [[ "$output" != *published* ]]
  ! grep -q 'tailscale serve' "$CALLS"
  run_tailscale_function 'if serve_legacy_off; then printf "removed\n"; fi'
  [[ "$output" != *removed* ]]
  ! grep -q 'tailscale serve' "$CALLS"
  [ "$(current_route_fixture)" = foreign ]
}

@test "custom-domain rollback restores legacy ingress and removes only managed Caddy artifacts" {
  prepare_custom_domain_migration raw
  run_custom_domain rollback
  [ "$status" -eq 0 ]
  [ "$(route_call_order)" = $'raw-off\nlegacy-on' ]
  [ "$(current_route_fixture)" = legacy-exact ]

  while IFS= read -r path; do
    [ ! -e "$path" ]
  done < <(managed_caddy_paths)
  [ "$(<"$MUTATION_CALLS")" = $'systemctl stop pi-webui-caddy.service\nsystemctl disable pi-webui-caddy.service\nsystemctl daemon-reload' ]

  # The legacy route is restored and proven before the Caddy service stops.
  restore=$(grep -n '^sudo tailscale serve --bg --https=443 ' "$CALLS" | cut -d: -f1 | head -1)
  probe=$(grep -n 'https://wsl.test.ts.net/api/health' "$CALLS" | cut -d: -f1 | head -1)
  stop=$(grep -n '^sudo systemctl stop pi-webui-caddy.service$' "$CALLS" | cut -d: -f1 | head -1)
  [ "$restore" -lt "$probe" ]
  [ "$probe" -lt "$stop" ]
}

@test "custom-domain rollback proves the old URL from an already-legacy route" {
  prepare_custom_domain_migration legacy-exact
  export LEGACY_HEALTH_FAIL=1
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'https://wsl.test.ts.net/api/health'* ]]
  [ ! -s "$ROUTE_ORDER" ]
  [ ! -s "$MUTATION_CALLS" ]
  while IFS= read -r path; do
    [ -e "$path" ]
  done < <(managed_caddy_paths)
  unset LEGACY_HEALTH_FAIL

  reset_migration_state legacy-exact
  run_custom_domain rollback
  [ "$status" -eq 0 ]
  # No route command runs: the legacy route is reported as already present
  # rather than republished.
  [ ! -s "$ROUTE_ORDER" ]
  [[ "$output" == *'already published'* ]]
  grep -q 'https://wsl.test.ts.net/api/health' "$CALLS"
  probe=$(grep -n 'https://wsl.test.ts.net/api/health' "$CALLS" | cut -d: -f1 | head -1)
  stop=$(grep -n '^sudo systemctl stop pi-webui-caddy.service$' "$CALLS" | cut -d: -f1 | head -1)
  [ "$probe" -lt "$stop" ]
  while IFS= read -r path; do
    [ ! -e "$path" ]
  done < <(managed_caddy_paths)
}

@test "custom-domain rollback --full leaves Serve empty and permits Web UI rollback" {
  prepare_custom_domain_migration raw
  run_custom_domain rollback --full
  [ "$status" -eq 0 ]
  [ "$(route_call_order)" = 'raw-off' ]
  [ "$(current_route_fixture)" = empty ]
  [[ "$output" == *'rollback.sh'* ]]
  while IFS= read -r path; do
    [ ! -e "$path" ]
  done < <(managed_caddy_paths)
  [ -f "$CADDY_CREDENTIAL" ]
  [ -f "$CADDY_STATE_DIR/acme.json" ]

  # The transitional legacy route is removed the same way.
  make_caddy_fixture
  touch "$TEST_ROOT/caddy-active"
  reset_migration_state legacy-exact
  run_custom_domain rollback --full
  [ "$status" -eq 0 ]
  [ "$(route_call_order)" = 'legacy-off' ]
  [ "$(current_route_fixture)" = empty ]

  # A foreign route is never removed.
  make_caddy_fixture
  touch "$TEST_ROOT/caddy-active"
  reset_migration_state foreign
  run_custom_domain rollback --full
  [ "$status" -ne 0 ]
  [ ! -s "$ROUTE_ORDER" ]
  while IFS= read -r path; do
    [ -e "$path" ]
  done < <(managed_caddy_paths)
}

@test "custom-domain rollback preserves certificates credential Pi state and Tailscale identity" {
  prepare_custom_domain_migration raw
  before=$(fingerprint_paths "$CADDY_STATE_DIR" "$CADDY_CREDENTIAL" "$HOME/.pi" \
    "$STATE_ROOT" "$TAILSCALE_STATE_DIR")
  run_custom_domain rollback
  [ "$status" -eq 0 ]
  [ "$(fingerprint_paths "$CADDY_STATE_DIR" "$CADDY_CREDENTIAL" "$HOME/.pi" \
    "$STATE_ROOT" "$TAILSCALE_STATE_DIR")" = "$before" ]
  [[ "$output" == *'preserved'* ]]
}

@test "custom-domain rollback refuses foreign artifacts and unexpected routes before mutation" {
  prepare_custom_domain_migration raw
  before=$(fingerprint_paths "$CADDY_ROOT")

  printf '\nforeign\n' >>"$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to remove a foreign managed Caddyfile'* ]]
  assert_no_route_mutation raw-exact
  cp "$WEBUI_FIXTURE/ai/pi/webui/Caddyfile.in" "$CADDY_ROOT/etc/pi-webui-caddy/Caddyfile"

  reset_migration_state raw
  printf '\nforeign\n' >>"$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to remove a foreign managed Caddy entrypoint'* ]]
  assert_no_route_mutation raw-exact
  cp "$WEBUI_FIXTURE/ai/pi/webui/caddy-entrypoint.sh" \
    "$CADDY_ROOT/usr/local/lib/pi-webui/caddy-entrypoint"

  reset_migration_state raw
  printf '\nforeign\n' >>"$CADDY_ROOT/etc/systemd/system/pi-webui-caddy.service"
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to remove a foreign managed Caddy unit'* ]]
  assert_no_route_mutation raw-exact
  make_caddy_fixture

  reset_migration_state raw
  export CADDY_VERSION_OUTPUT='v2.10.0 h1:other'
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'refusing to remove a foreign Caddy binary'* ]]
  assert_no_route_mutation raw-exact
  export CADDY_VERSION_OUTPUT='v2.11.4 h1:test'

  reset_migration_state raw
  export CADDY_FOREIGN_OWNER=1
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'must be owned by root'* ]]
  assert_no_route_mutation raw-exact
  unset CADDY_FOREIGN_OWNER

  reset_migration_state empty
  run_custom_domain rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'unexpected Tailscale route state'* ]]
  assert_no_route_mutation empty

  [ "$(fingerprint_paths "$CADDY_ROOT")" = "$before" ]
}

@test "Web UI rollback points to custom-domain rollback while raw ingress is published" {
  prepare_rollback
  write_route raw
  run_rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'custom-domain.sh rollback --full'* ]]
  [ ! -s "$MUTATION_CALLS" ]

  # The transitional legacy route names its own explicit removal verb.
  write_route legacy-exact
  run_rollback
  [ "$status" -ne 0 ]
  [[ "$output" == *'serve-legacy-off'* ]]
  [ ! -s "$MUTATION_CALLS" ]
}

@test "migration refuses success when the route changes after verification" {
  prepare_custom_domain_migration legacy-exact
  export MIGRATION_CONFIRM=yes TAILNET_CLIENT_CONFIRM=yes

  # A concurrent foreign publication lands after the last automated check:
  # success is never reported and the foreign route is never overwritten.
  reset_migration_state
  export ROUTE_CHANGE_AFTER_VERIFY=foreign
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" != *'is now canonical'* ]]
  [[ "$output" == *'refusing automatic restoration'* ]]
  [[ "$output" == *'RESTORATION FAILED'* ]]
  [ "$(route_call_order)" = $'legacy-off\nraw-on' ]
  [ "$(current_route_fixture)" = foreign ]

  # A concurrent removal is recoverable under the existing rules: the exact
  # legacy route is republished instead of reporting a successful migration.
  reset_migration_state
  export ROUTE_CHANGE_AFTER_VERIFY=empty
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" != *'is now canonical'* ]]
  [[ "$output" == *'legacy route restored'* ]]
  [ "$(route_call_order)" = $'legacy-off\nraw-on\nlegacy-on' ]
  [ "$(current_route_fixture)" = legacy-exact ]

  # A concurrent legacy republication is reported, not overwritten again.
  reset_migration_state
  export ROUTE_CHANGE_AFTER_VERIFY=legacy-exact
  run_custom_domain migrate
  [ "$status" -ne 0 ]
  [[ "$output" != *'is now canonical'* ]]
  [ "$(route_call_order)" = $'legacy-off\nraw-on' ]
  [ "$(current_route_fixture)" = legacy-exact ]
  unset ROUTE_CHANGE_AFTER_VERIFY
}

@test "custom-domain rollback refuses teardown when the route changes before teardown" {
  prepare_custom_domain_migration raw
  local change
  for change in raw foreign; do
    reset_migration_state raw
    export ROUTE_CHANGE_BEFORE_TEARDOWN="$change"
    run_custom_domain rollback
    [ "$status" -ne 0 ]
    [[ "$output" == *'unexpected Tailscale route state'* ||
      "$output" == *'foreign, additional, public, or ambiguous'* ]]

    # Restoration ran, but no Caddy artifact, unit state, or service state was
    # touched afterwards.
    [ "$(route_call_order)" = $'raw-off\nlegacy-on' ]
    [ ! -s "$MUTATION_CALLS" ]
    [ -f "$TEST_ROOT/caddy-active" ]
    ! grep -q '^sudo rm ' "$CALLS"
    while IFS= read -r path; do
      [ -e "$path" ]
    done < <(managed_caddy_paths)
    unset ROUTE_CHANGE_BEFORE_TEARDOWN
  done

  # With no concurrent change the same fixture still rolls back cleanly.
  reset_migration_state raw
  run_custom_domain rollback
  [ "$status" -eq 0 ]
  [ "$(current_route_fixture)" = legacy-exact ]
  while IFS= read -r path; do
    [ ! -e "$path" ]
  done < <(managed_caddy_paths)
}
