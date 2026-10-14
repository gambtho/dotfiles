#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  INSTALL="$REPO_ROOT/ai/pi/paseo/install.sh"
  COMMON="$REPO_ROOT/ai/pi/paseo/common.sh"
  STATE_ROOT="$XDG_DATA_HOME/paseo"
  PASEO_HOME="$STATE_ROOT/home"
  INSTALLED_RUNTIME="$STATE_ROOT/runtimes/current"
  UNIT_PATH="$XDG_CONFIG_HOME/systemd/user/paseo.service"
  CALLS="$TEST_ROOT/calls"
  export STATE_ROOT PASEO_HOME INSTALLED_RUNTIME UNIT_PATH CALLS
  : >"$CALLS"
  unset DOTFILES_PASEO_ENABLED PI_CODING_AGENT_DIR
}

fixture_source() {
  export PI_PASEO_TESTING=1 PI_PASEO_TEST_SOURCE_ROOT="$TEST_ROOT/repo"
  export PI_PASEO_TEST_OS_RELEASE="$TEST_ROOT/os-release"
  export PI_PASEO_TEST_UNAME_RELEASE=6.6-microsoft-standard-WSL2
  mkdir -p "$PI_PASEO_TEST_SOURCE_ROOT/ai/pi" "$PI_PASEO_TEST_SOURCE_ROOT/libexec/lib"
  cp -R "$REPO_ROOT/ai/pi/paseo" "$PI_PASEO_TEST_SOURCE_ROOT/ai/pi/"
  cp "$REPO_ROOT/libexec/validate-pi-paseo" "$PI_PASEO_TEST_SOURCE_ROOT/libexec/"
  cp "$REPO_ROOT/libexec/lib/pi-runtime.sh" "$PI_PASEO_TEST_SOURCE_ROOT/libexec/lib/"
  printf 'ID=ubuntu\nVERSION_ID=24.04\nVERSION_CODENAME=noble\n' >"$PI_PASEO_TEST_OS_RELEASE"
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" init -q -b main
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" config user.name Test
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" config user.email test@example.invalid
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" add .
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" commit -qm fixture
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" update-ref refs/remotes/origin/main HEAD
  stub_command systemctl 'printf "%s\n" "$*" >>"$CALLS"; [[ "$*" == "--user show-environment" ]]'
}

fixture_pi() {
  export PI_LAUNCHER="$TEST_ROOT/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  mkdir -p "$(dirname "$PI_LAUNCHER")" "$TEST_ROOT/pi/node_modules/jiti/lib"
  printf '{"name":"@earendil-works/pi-coding-agent","version":"1.2.0","bin":{"pi":"dist/cli.js"}}\n' >"$(dirname "$PI_LAUNCHER")/../package.json"
  printf 'export {};\n' >"$(dirname "$PI_LAUNCHER")/index.js"
  printf '#!/usr/bin/env node\n' >"$PI_LAUNCHER"
  chmod +x "$PI_LAUNCHER"
  touch "$TEST_ROOT/pi/node_modules/jiti/lib/jiti-cli.mjs"
  export FIXTURE_PI_LAUNCHER="$PI_LAUNCHER"
  stub_command mise 'if [[ "$*" == "which pi" ]]; then printf "%s\n" "$FIXTURE_PI_LAUNCHER"; else exec "${@:3}"; fi'
}

load paseo_helper

run_common() {
  run bash -c 'source "$1"; shift; "$@"' _ "$COMMON" "$@"
}

@test "Paseo check is opt-in and does not inspect platform or mutate services" {
  [ -f "$INSTALL" ]
  stub_command systemctl 'printf unexpected >>"$CALLS"; exit 99'
  for selection in unset '' 0; do
    if [[ "$selection" == unset ]]; then unset DOTFILES_PASEO_ENABLED; else export DOTFILES_PASEO_ENABLED="$selection"; fi
    run bash "$INSTALL" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"not selected"* ]]
    [ ! -s "$CALLS" ]
    [ ! -e "$STATE_ROOT" ]
  done
}

@test "Paseo apply requires explicit selection and rejects invalid values" {
  [ -f "$INSTALL" ]
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"DOTFILES_PASEO_ENABLED=1"* ]]
  export DOTFILES_PASEO_ENABLED=yes
  run bash "$INSTALL" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid"* ]]
  [ ! -e "$STATE_ROOT" ]
}

@test "Paseo check reports installed but not selected without disabling it" {
  [ -f "$INSTALL" ]
  mkdir -p "$(dirname "$UNIT_PATH")"
  printf 'existing unit\n' >"$UNIT_PATH"
  run bash "$INSTALL" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed but not selected"* ]]
  [ ! -s "$CALLS" ]
  [ "$(<"$UNIT_PATH")" = 'existing unit' ]
}

@test "Paseo paths are distinct from Pi history and trial state" {
  [ -f "$COMMON" ]
  run bash -c 'source "$1"; set_managed_paths; printf "%s\n" "$STATE_ROOT" "$PASEO_HOME" "$UNIT_PATH"' _ "$COMMON"
  [ "$status" -eq 0 ]
  [ "$output" = "$XDG_DATA_HOME/paseo"$'\n'"$XDG_DATA_HOME/paseo/home"$'\n'"$XDG_CONFIG_HOME/systemd/user/paseo.service" ]
}

@test "Paseo platform guard refuses unsupported systems before mutation" {
  [ -f "$COMMON" ]
  fixture_source
  printf 'ID=ubuntu\nVERSION_ID=22.04\nVERSION_CODENAME=jammy\n' >"$PI_PASEO_TEST_OS_RELEASE"
  run_common require_supported_platform
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ubuntu 24.04 Noble under WSL"* ]]
  [ ! -s "$CALLS" ]
}

@test "Paseo test overrides require isolated HOME and paths" {
  [ -f "$COMMON" ]
  export PI_PASEO_TESTING=1
  run_common require_test_override "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"below the Bats"* ]]
  run_common require_test_override "$HOME"
  [ "$status" -eq 0 ]
  export HOME=/tmp
  run_common require_test_override "$TEST_ROOT"
  [ "$status" -ne 0 ]
}

@test "Paseo refuses canonical apply from a linked checkout" {
  [ -f "$COMMON" ]
  fixture_source
  git -C "$PI_PASEO_TEST_SOURCE_ROOT" worktree add -q --detach "$TEST_ROOT/linked" HEAD
  export PI_PASEO_TEST_SOURCE_ROOT="$TEST_ROOT/linked"
  run bash -c 'source "$1"; resolve_source; validate_apply_source' _ "$COMMON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical primary checkout"* ]]
}

@test "Paseo validates the separate Pi host floor rather than a runtime Pi pin" {
  [ -f "$COMMON" ]
  fixture_source
  fixture_pi
  run bash -c 'source "$1"; resolve_source; resolve_mise; resolve_pi' _ "$COMMON"
  [ "$status" -eq 0 ]
  jq '.version="0.85.1"' "$(dirname "$PI_LAUNCHER")/../package.json" >"$TEST_ROOT/wrong-pi.json"
  cp "$TEST_ROOT/wrong-pi.json" "$(dirname "$PI_LAUNCHER")/../package.json"
  run bash -c 'source "$1"; resolve_source; resolve_mise; resolve_pi' _ "$COMMON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pi 1.1+"* ]]
}

run_config() {
  run node "$REPO_ROOT/ai/pi/paseo/config.mjs" "$@"
}

@test "Paseo fresh config defaults to the verified working feature set" {
  [ -f "$REPO_ROOT/ai/pi/paseo/config.mjs" ]
  run_config reconcile "$TEST_ROOT/absent.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$TEST_ROOT/config.json")" = 600 ]
  run jq -e '.daemon.listen == "127.0.0.1:31415" and .daemon.relay.enabled == false and .daemon.mcp == {"enabled":false,"injectIntoAgents":false} and .daemon.browserTools.enabled == false and .daemon.serviceProxy.enabled == false and .pluginsEnabled == false and .features.webUi.enabled == true and .app.baseUrl == "https://pi.dpao.la" and .agents.providers.pi.command == ["/native/pi"] and .agents.providers.claude.enabled == false' "$TEST_ROOT/config.json"
  [ "$status" -eq 0 ]
  run_config validate "$TEST_ROOT/config.json" /native/pi
  [ "$status" -eq 2 ]
  [[ "$output" == *"password required"* ]]
}

@test "Paseo reconciliation preserves password and optional preferences" {
  [ -f "$REPO_ROOT/ai/pi/paseo/config.mjs" ]
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({daemon:{auth:{password:"$2b$12$"+"A".repeat(53)},mcp:{enabled:true,injectIntoAgents:true},browserTools:{enabled:true},listen:"0.0.0.0:9999"},pluginsEnabled:true,theme:"custom"}),{mode:0o600})' "$TEST_ROOT/input.json"
  run_config reconcile "$TEST_ROOT/input.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -eq 0 ]
  run jq -e --slurpfile prior "$TEST_ROOT/input.json" '.daemon.auth == $prior[0].daemon.auth and .daemon.mcp == $prior[0].daemon.mcp and .daemon.browserTools == $prior[0].daemon.browserTools and .pluginsEnabled == true and .theme == "custom" and .daemon.listen == "127.0.0.1:31415"' "$TEST_ROOT/config.json"
  [ "$status" -eq 0 ]
  run_config validate "$TEST_ROOT/config.json" /native/pi
  [ "$status" -eq 0 ]
}

@test "Paseo config refuses invalid shapes secrets and symlinks without leaking values" {
  [ -f "$REPO_ROOT/ai/pi/paseo/config.mjs" ]
  printf '{"daemon":"do-not-log-this"}\n' >"$TEST_ROOT/input.json"
  chmod 600 "$TEST_ROOT/input.json"
  run_config reconcile "$TEST_ROOT/input.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -ne 0 ]
  [[ "$output" != *"do-not-log-this"* ]]
  [ ! -e "$TEST_ROOT/config.json" ]
  printf '{"daemon": {"auth":{"password":"do-not-log-this"}}}\n' >"$TEST_ROOT/input.json"
  run_config reconcile "$TEST_ROOT/input.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -ne 0 ]
  [[ "$output" != *"do-not-log-this"* ]]
  ln -s "$TEST_ROOT/input.json" "$TEST_ROOT/alias.json"
  run_config reconcile "$TEST_ROOT/alias.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regular private file"* ]]
}

@test "Paseo config validation rejects drift and unbounded extra listeners" {
  [ -f "$REPO_ROOT/ai/pi/paseo/config.mjs" ]
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({daemon:{auth:{password:"$2b$12$"+"A".repeat(53)}}}),{mode:0o600})' "$TEST_ROOT/input.json"
  run_config reconcile "$TEST_ROOT/input.json" "$TEST_ROOT/config.json" /native/pi "$REPO_ROOT/ai/pi/paseo/config.json"
  [ "$status" -eq 0 ]
  for mutation in '.daemon.listen="0.0.0.0:31415"' '.daemon.relay.enabled=true' '.features.webUi.enabled=false' '.agents.providers.pi.command=["/foreign/pi"]' '.daemon.serviceProxy={"enabled":true,"listen":"0.0.0.0:9999"}'; do
    jq "$mutation" "$TEST_ROOT/config.json" >"$TEST_ROOT/changed.json"
    chmod 600 "$TEST_ROOT/changed.json"
    run_config validate "$TEST_ROOT/changed.json" /native/pi
    [ "$status" -ne 0 ]
  done
}

@test "Paseo launcher binds password setup to managed home and drops daemon overrides only" {
  [ -f "$COMMON" ]
  fixture_source
  fixture_pi
  mkdir -p "$INSTALLED_RUNTIME/node_modules/@getpaseo/cli/bin"
  printf 'console.log(JSON.stringify({args:process.argv.slice(2),override:process.env.PASEO_PASSWORD,listen:process.env.PASEO_LISTEN,providerPresent:!!process.env.OPENAI_API_KEY}));\n' >"$INSTALLED_RUNTIME/node_modules/@getpaseo/cli/bin/paseo"
  run bash -c 'source "$1"; resolve_source; resolve_mise; set_managed_paths; render_launcher' _ "$COMMON"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$TEST_ROOT/launcher"
  chmod +x "$TEST_ROOT/launcher"
  # mise may add deployment overrides after the outer launcher starts.
  stub_command mise '[[ "$1 $2" == "exec --" ]] || exit 97; shift 2; export PASEO_PASSWORD=test-only-unused PASEO_LISTEN=0.0.0.0:9999 PASEO_HOME="$TEST_ROOT/wrong-home"; exec "$@"'
  export PASEO_PASSWORD=test-only-unused PASEO_LISTEN=0.0.0.0:9999 PASEO_HOME="$TEST_ROOT/wrong-home" OPENAI_API_KEY=test-only-unused
  run "$TEST_ROOT/launcher" daemon set-password
  [ "$status" -eq 0 ]
  run jq -e --arg home "$STATE_ROOT/home" '.args == ["--home",$home,"daemon","set-password"] and .override == null and .listen == null and .providerPresent == true' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "Paseo unit owns foreground cgroup and rejects unsafe rendered paths" {
  [ -f "$COMMON" ]
  fixture_source
  fixture_pi
  run bash -c 'source "$1"; resolve_source; set_managed_paths; render_unit' _ "$COMMON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ExecStart=$STATE_ROOT/paseo daemon run"* ]]
  [[ "$output" == *"KillMode=control-group"* ]]
  [[ "$output" == *"Conflicts=pi-webui.service"* ]]
  [[ "$output" == *"UnsetEnvironment="*"PASEO_CORS_ORIGINS"* ]]
  export XDG_DATA_HOME="$TEST_ROOT/unsafe%path"
  run bash -c 'source "$1"; resolve_source; set_managed_paths; render_unit' _ "$COMMON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe path"* ]]
}

@test "Paseo quiescence checks all pages and rejects work approvals and malformed responses" {
  [ -f "$REPO_ROOT/ai/pi/paseo/probe.mjs" ]
  run node --input-type=module - "$REPO_ROOT/ai/pi/paseo/probe.mjs" <<'NODE'
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {assertQuiescent} = await import(pathToFileURL(process.argv[2]));
const page = (entries, nextCursor=null) => ({entries,pageInfo:{hasMore:nextCursor!==null,nextCursor,prevCursor:null}});
const agent = (status='idle', pendingPermissions=[], activeTurn=null) => ({agent:{status,pendingPermissions,activeTurn}});
function client(pages) { let i=0; return {fetchAgents:async ({page:p})=>{ if(i===1) assert.equal(p.cursor,'next'); return pages[i++]; }, fetchWorkspaces:async()=>page([]),listTerminals:async()=>({terminals:[]})}; }
await assertQuiescent(client([page([agent()],'next'),page([agent('closed')])]));
for(const bad of [agent('running'),agent('initializing'),agent('idle',[{id:'pending'}]),agent('idle',[],{turnId:'inflight'}),agent('unknown')]) {
  await assert.rejects(assertQuiescent(client([page([agent()],'next'),page([bad])])));
}
await assert.rejects(assertQuiescent(client([{entries:[],pageInfo:{hasMore:true,nextCursor:null}}])));
await assert.rejects(assertQuiescent(client([{entries:null}])));
const terminal = client([page([])]); terminal.listTerminals=async()=>({terminals:[{id:'pty'}]});
await assert.rejects(assertQuiescent(terminal));
const script = client([page([])]); script.fetchWorkspaces=async()=>page([{status:'running',scripts:[{lifecycle:'running'}]}]);
await assert.rejects(assertQuiescent(script));
console.log('all paginated quiescence cases passed');
NODE
  [ "$status" -eq 0 ]
}

@test "Paseo health requires matching authenticated instance version and loopback identity" {
  run node --input-type=module - "$REPO_ROOT/ai/pi/paseo/probe.mjs" <<'NODE'
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {assertHealth} = await import(pathToFileURL(process.argv[2]));
const info = {status:'server_info',version:'0.11.2',listen:'127.0.0.1:31415',serverId:'instance'};
const instance = {listen:'127.0.0.1:31415',serverId:'instance'};
const health = {status:'ok',timestamp:'2026-10-14T00:00:00.000Z'};
assert.equal(typeof assertHealth,'function');
assertHealth(info,health,instance,'127.0.0.1:31415');
for (const bad of [{...info,version:'0.12.0'},{...info,listen:'0.0.0.0:31415'},{...info,serverId:'foreign'},{}]) assert.throws(()=>assertHealth(bad,health,instance,'127.0.0.1:31415'));
assert.throws(()=>assertHealth(info,{status:'ok'},instance,'127.0.0.1:31415'));
console.log('strict health cases passed');
NODE
  [ "$status" -eq 0 ]
}

@test "Paseo prepares offline auth bootstrap and reapply starts the managed service" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"$STATE_ROOT/paseo daemon set-password"* ]]
  [ -x "$STATE_ROOT/paseo" ]
  [ -f "$PASEO_HOME/config.json" ]
  [ ! -e "$UNIT_PATH" ]
  [ ! -e "$SERVICE_STATE/active" ] || [ "$(<"$SERVICE_STATE/active")" = 0 ]
  ! grep -q -- '--user start\|--user stop\|--user daemon-reload' "$CALLS"
  write_test_password
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
  [ "$(<"$SERVICE_STATE/enabled")" = 1 ]
  [ -f "$UNIT_PATH" ]
  grep -q -- '--ignore-scripts --omit=dev' "$CALLS"
  [ ! -e "$HOME/.pi/agent/auth.json" ]
}

@test "Paseo refuses foreign state symlinked destinations and enabled legacy service" {
  prepare_paseo
  mkdir -p "$STATE_ROOT"
  printf 'unrelated\n' >"$STATE_ROOT/keep"
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"unowned"* ]]
  [ "$(<"$STATE_ROOT/keep")" = unrelated ]
  ! grep -q '^ci ' "$CALLS"
  rm -r "$STATE_ROOT"
  mkdir "$TEST_ROOT/foreign"
  ln -s "$TEST_ROOT/foreign" "$STATE_ROOT"
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"real directory"* ]]
  [ -L "$STATE_ROOT" ]
  rm "$STATE_ROOT"
  export LEGACY_ENABLED=1
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy"* ]]
  ! grep -q -- '--user stop' "$CALLS"
}

@test "Paseo publication failure restores the exact prior unit and reloads it" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  mkdir -p "$(dirname "$UNIT_PATH")"
  run bash -c 'source "$1"; resolve_source; set_managed_paths; render_unit' _ "$COMMON"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$UNIT_PATH"
  cp "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  export FAIL_RELOAD=1
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  cmp -s "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  [ "$(<"$SERVICE_STATE/active")" = 0 ]
  [ "$(<"$SERVICE_STATE/enabled")" = 0 ]
  [ "$(grep -c -- '--user daemon-reload' "$CALLS")" -eq 2 ]
}

@test "Paseo candidate validation fails before changing service ownership" {
  prepare_paseo
  export FAIL_VERIFY=1
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [ ! -e "$UNIT_PATH" ]
  ! grep -q -- '--user start\|--user stop' "$CALLS"
}

@test "Paseo trial replacement refuses busy or unavailable work before stopping" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  fixture_trial
  cp "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  for flag in FAKE_BUSY FAKE_UNAVAILABLE; do
    export "$flag"=1
    : >"$CALLS"
    run bash "$INSTALL" --apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"close work"* ]]
    cmp -s "$UNIT_PATH" "$TEST_ROOT/prior-unit"
    ! grep -q -- '--user stop' "$CALLS"
    unset "$flag"
  done
}

@test "Paseo fresh replacement leaves trial metadata and password for explicit retirement" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  fixture_trial
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  grep -q "ExecStart=$STATE_ROOT/paseo daemon run" "$UNIT_PATH"
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
  [ -f "$HOME/.local/share/paseo-trial/password.txt" ]
  [ -d "$HOME/.local/share/paseo-trial/home" ]
  run node -e 'const fs=require("fs"),r=process.argv[1];if(!fs.readdirSync(r).some(x=>x.startsWith(".rollback-trial.")))process.exit(1)' "$STATE_ROOT"
  [ "$status" -eq 0 ]
}

@test "Paseo failed replacement restores trial unit bytes activity and enablement" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  fixture_trial
  cp "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  export FAIL_START=1
  : >"$CALLS"
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  grep -q -- '--user start paseo.service' "$CALLS"
  [ "$(grep -c -- '--user daemon-reload' "$CALLS")" -eq 2 ]
  cmp -s "$UNIT_PATH" "$TEST_ROOT/prior-unit"
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
  [ "$(<"$SERVICE_STATE/enabled")" = 1 ]
  [ -d "$HOME/.local/share/paseo-trial/home" ]
}

@test "Paseo rollback disables only an identified idle managed service" {
  [ -f "$REPO_ROOT/ai/pi/paseo/rollback.sh" ]
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  export FAKE_BUSY=1
  run bash "$REPO_ROOT/ai/pi/paseo/rollback.sh"
  [ "$status" -ne 0 ]
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
  unset FAKE_BUSY
  run bash "$REPO_ROOT/ai/pi/paseo/rollback.sh"
  [ "$status" -eq 0 ]
  [ "$(<"$SERVICE_STATE/active")" = 0 ]
  [ "$(<"$SERVICE_STATE/enabled")" = 0 ]
  [ -d "$INSTALLED_RUNTIME" ]
  [ -f "$PASEO_HOME/config.json" ]
  ! grep -q 'caddy\|tailscale' "$CALLS"
}

@test "Paseo explicit retirement preserves original sessions repositories and symlink targets" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  fixture_trial
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  mkdir -p "$HOME/.pi/agent/sessions" "$TEST_ROOT/original-repo"
  printf 'original session\n' >"$HOME/.pi/agent/sessions/original.jsonl"
  printf 'original auth\n' >"$HOME/.pi/agent/auth.json"
  printf 'source code\n' >"$TEST_ROOT/original-repo/source"
  ln -s "$TEST_ROOT/original-repo" "$HOME/.local/share/paseo-trial/home/repository-reference"
  export TRIAL_INACTIVE=1
  run bash "$INSTALL" --retire-trial
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/share/paseo-trial" ]
  [ "$(<"$HOME/.pi/agent/sessions/original.jsonl")" = 'original session' ]
  [ "$(<"$HOME/.pi/agent/auth.json")" = 'original auth' ]
  [ "$(<"$TEST_ROOT/original-repo/source")" = 'source code' ]
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
}

@test "Paseo retirement refuses ambiguous files or Git worktrees without deletion" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  fixture_trial
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  export TRIAL_INACTIVE=1
  printf 'unowned\n' >"$HOME/.local/share/paseo-trial/foreign"
  run bash "$INSTALL" --retire-trial
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
  [ -f "$HOME/.local/share/paseo-trial/password.txt" ]
  rm "$HOME/.local/share/paseo-trial/foreign"
  mkdir -p "$HOME/.local/share/paseo-trial/home/worktrees/code/.git"
  run bash "$INSTALL" --retire-trial
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git"* ]]
  [ -d "$HOME/.local/share/paseo-trial/home/worktrees/code/.git" ]
}

@test "Paseo restores a runtime after its backup move mutates then fails" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  printf 'prior runtime\n' >"$INSTALLED_RUNTIME/prior-sentinel"
  stub_command mv 'if [[ "$*" == *"/prior-runtime" && ! -e "$SERVICE_STATE/move-failed" ]]; then /usr/bin/mv "$@"; touch "$SERVICE_STATE/move-failed"; exit 95; fi; exec /usr/bin/mv "$@"'
  run bash "$INSTALL" --apply
  [ "$status" -ne 0 ]
  [ -f "$INSTALLED_RUNTIME/prior-sentinel" ]
}

@test "Paseo check is read-only and requires exact listener ownership" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  : >"$CALLS"
  run bash "$INSTALL" --check
  [ "$status" -eq 0 ]
  ! grep -q '^ci \|--user stop\|--user start\|--user daemon-reload' "$CALLS"
  stub_command ss 'printf "LISTEN 0 4096 0.0.0.0:31415 0.0.0.0:*\n"'
  run bash "$INSTALL" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopback-only"* ]]
}

@test "fresh readiness failure removes enablement before removing its unit" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  stub_command curl 'exit 22'
  run bash "$INSTALL" --apply
  [ "$status" -eq 1 ]
  [[ "$output" != *"restoration failed"* ]]
  [ "$(<"$SERVICE_STATE/enabled")" = 0 ]
  [ "$(<"$SERVICE_STATE/active")" = 0 ]
  [ ! -e "$UNIT_PATH" ]
  [ ! -e "$STATE_ROOT/.install.lock" ]
}

@test "managed upgrade refuses a config change during stop and restarts prior service" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  run bash "$INSTALL" --apply
  [ "$status" -eq 0 ]
  export CHANGE_CONFIG_ON_STOP=1
  run bash "$INSTALL" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"configuration changed"* ]]
  [ "$(jq -r .theme "$PASEO_HOME/config.json")" = changed-during-stop ]
  [ "$(<"$SERVICE_STATE/active")" = 1 ]
  [ ! -e "$STATE_ROOT/.install.lock" ]
}

@test "apply rejects original symlinked config rather than validating a copy" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  mv "$PASEO_HOME/config.json" "$TEST_ROOT/external-config"
  ln -s "$TEST_ROOT/external-config" "$PASEO_HOME/config.json"
  : >"$CALLS"
  run bash "$INSTALL" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"private regular"* ]]
  [ -L "$PASEO_HOME/config.json" ]
  ! grep -q -- '--user stop' "$CALLS"
}

@test "hangup during runtime swap restores the prior runtime and reports interruption" {
  prepare_paseo
  run bash "$INSTALL" --apply
  [ "$status" -eq 2 ]
  write_test_password
  printf 'prior runtime\n' >"$INSTALLED_RUNTIME/prior-sentinel"
  stub_command mv 'if [[ "$*" == *"/prior-runtime" && ! -e "$SERVICE_STATE/hup-sent" ]]; then /usr/bin/mv "$@"; touch "$SERVICE_STATE/hup-sent"; kill -HUP "$PPID"; exit 0; fi; exec /usr/bin/mv "$@"'
  run bash "$INSTALL" --apply
  [ "$status" -eq 129 ]
  [ -f "$INSTALLED_RUNTIME/prior-sentinel" ]
  [ ! -e "$STATE_ROOT/.install.lock" ]
}
