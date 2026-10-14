# Shared isolated runtime/service doubles; no production test hooks.
fixture_runtime_installer() {
  cat >"$TEST_ROOT/npm-install" <<'SCRIPT'
#!/usr/bin/env bash
set -e
runtime=$1
mkdir -p "$runtime/node_modules/"{.bin,node-pty,ws,@getpaseo/cli/bin,@getpaseo/client,@getpaseo/server,@getpaseo/protocol}
for p in cli client server protocol; do
  printf '{"name":"@getpaseo/%s","version":"0.11.2","type":"module","bin":{"paseo":"bin/paseo"},"exports":{"./daemon-control":"./control.mjs"}}\n' "$p" >"$runtime/node_modules/@getpaseo/$p/package.json"
done
printf '#!/usr/bin/env node\n' >"$runtime/node_modules/@getpaseo/cli/bin/paseo"
chmod +x "$runtime/node_modules/@getpaseo/cli/bin/paseo"
ln -s ../@getpaseo/cli/bin/paseo "$runtime/node_modules/.bin/paseo"
printf 'exports.spawn=()=>({kill(){},onData(f){setImmediate(()=>f("paseo-pty-ready"))},onExit(f){setImmediate(()=>f({exitCode:0}))}});\n' >"$runtime/node_modules/node-pty/index.js"
printf 'module.exports=class {};\n' >"$runtime/node_modules/ws/index.js"
cat >"$runtime/node_modules/@getpaseo/server/control.mjs" <<'JS'
export async function readDaemonInstance(home){if(process.env.TRIAL_INACTIVE==='1'&&home.includes('paseo-trial'))return null;return {pid:1,listen:'127.0.0.1:31415',serverId:'fixture'}}
export function readLocalCredentialForTarget(){return 'fixture-token'}
JS
node -e 'const fs=require("fs"),f=process.argv[1],v=JSON.parse(fs.readFileSync(f));v.exports["./internal/daemon-client"]="./client.mjs";fs.writeFileSync(f,JSON.stringify(v))' "$runtime/node_modules/@getpaseo/client/package.json"
cat >"$runtime/node_modules/@getpaseo/client/client.mjs" <<'JS'
export class DaemonClient {
 async connect(){if(process.env.FAKE_UNAVAILABLE==='1')throw Error('unavailable')}
 getLastServerInfoMessage(){return {serverId:'fixture',version:'0.11.2'}}
 async fetchAgents(){return {entries:process.env.FAKE_BUSY==='1'?[{agent:{status:'running',pendingPermissions:[]}}]:[],pageInfo:{hasMore:false,nextCursor:null}}}
 async fetchWorkspaces(){return {entries:[],pageInfo:{hasMore:false,nextCursor:null}}}
 async listTerminals(){return {terminals:[]}}
 async close(){}
}
JS
SCRIPT
  chmod +x "$TEST_ROOT/npm-install"
  export FAKE_INSTALLER="$TEST_ROOT/npm-install"
  stub_command npm 'printf "%s\n" "$*" >>"$CALLS"; [[ "$*" == *"--ignore-scripts"* && "$*" == *"--omit=dev"* ]] || exit 90; while [[ $# -gt 0 ]]; do if [[ "$1" == --prefix ]]; then exec "$FAKE_INSTALLER" "$2"; fi; shift; done; exit 91'
  stub_command systemd-analyze 'printf "%s\n" "$*" >>"$CALLS"; [[ ${FAIL_VERIFY:-} != 1 ]]'
}

fixture_service() {
  export SERVICE_ACTIVE=0 SERVICE_ENABLED=0
  mkdir -p "$TEST_ROOT/service"
  printf '0\n' >"$TEST_ROOT/service/active"
  printf '0\n' >"$TEST_ROOT/service/enabled"
  export SERVICE_STATE="$TEST_ROOT/service"
  stub_command systemctl '
    printf "%s\n" "$*" >>"$CALLS"
    case "$2" in
      show-environment) exit 0 ;;
      show)
        if [[ "$3" == pi-webui.service ]]; then
          if [[ ${LEGACY_ENABLED:-} == 1 ]]; then printf "LoadState=loaded\nActiveState=inactive\nUnitFileState=enabled\nFragmentPath=legacy\n"; else
            printf "LoadState=not-found\nActiveState=inactive\nUnitFileState=\nFragmentPath=\n"
          fi
        elif [[ -f "$UNIT_PATH" ]]; then
          printf "LoadState=loaded\nFragmentPath=%s\n" "$UNIT_PATH"
          if [[ $(<"$SERVICE_STATE/active") == 1 ]]; then printf "ActiveState=active\n"; else printf "ActiveState=inactive\n"; fi
          if [[ $(<"$SERVICE_STATE/enabled") == 1 ]]; then printf "UnitFileState=enabled\n"; else printf "UnitFileState=disabled\n"; fi
        else printf "LoadState=not-found\nActiveState=inactive\nUnitFileState=\nFragmentPath=\n"; fi ;;
      is-active) [[ $(<"$SERVICE_STATE/active") == 1 ]] ;;
      is-enabled) [[ $(<"$SERVICE_STATE/enabled") == 1 ]] ;;
      stop)
        printf "0\n" >"$SERVICE_STATE/active"
        if [[ ${CHANGE_CONFIG_ON_STOP:-} == 1 ]]; then
          jq ".theme = \"changed-during-stop\"" "$PASEO_HOME/config.json" >"$PASEO_HOME/config.changed"
          mv "$PASEO_HOME/config.changed" "$PASEO_HOME/config.json"
        fi ;;
      start) printf "1\n" >"$SERVICE_STATE/active"; if [[ ${FAIL_START:-} == 1 && ! -e "$SERVICE_STATE/start-failed" ]]; then touch "$SERVICE_STATE/start-failed"; exit 94; fi ;;
      enable) [[ -f "$UNIT_PATH" ]] || exit 96; printf "1\n" >"$SERVICE_STATE/enabled" ;;
      disable) [[ -f "$UNIT_PATH" ]] || exit 96; printf "0\n" >"$SERVICE_STATE/enabled" ;;
      daemon-reload) if [[ ${FAIL_RELOAD:-} == 1 && ! -e "$SERVICE_STATE/reload-failed" ]]; then touch "$SERVICE_STATE/reload-failed"; exit 92; fi ;;
      *) exit 93 ;;
    esac'
  stub_command ss 'printf "LISTEN 0 4096 127.0.0.1:31415 0.0.0.0:*\n"'
  stub_command curl 'if [[ "$*" == *"/api/status"* ]]; then printf "{\"status\":\"server_info\",\"version\":\"0.11.2\",\"listen\":\"127.0.0.1:31415\",\"serverId\":\"fixture\"}\n"; else printf "{\"status\":\"ok\",\"timestamp\":\"2026-10-14T00:00:00.000Z\"}\n"; fi'
}

prepare_paseo() {
  fixture_source
  fixture_pi
  fixture_runtime_installer
  fixture_service
  export DOTFILES_PASEO_ENABLED=1
  export PI_PASEO_TEST_READY_DEADLINE=2
}

write_test_password() {
  node -e 'const f=process.argv[1],s=require("fs"),v=JSON.parse(s.readFileSync(f,"utf8"));v.daemon.auth={password:"$2b$12$"+"A".repeat(53)};s.writeFileSync(f,JSON.stringify(v),{mode:0o600})' "$PASEO_HOME/config.json"
  printf 'fixture-token\n' >"$PASEO_HOME/local-credential"
  chmod 600 "$PASEO_HOME/local-credential"
}

fixture_trial() {
  local trial="$HOME/.local/share/paseo-trial"
  mkdir -p "$trial/home" "$(dirname "$UNIT_PATH")"
  cp -R "$INSTALLED_RUNTIME" "$trial/runtime"
  node -e 'const fs=require("fs"),r=process.argv[1];for(const f of ["package.json","package-lock.json"]){const p=r+"/"+f,v=JSON.parse(fs.readFileSync(p));v.name="paseo-local-trial";v.version="1.0.0";if(v.packages){v.packages[""].name=v.name;v.packages[""].version=v.version}fs.writeFileSync(p,JSON.stringify(v,null,2)+"\n")}' "$trial/runtime"
  printf 'fixture-token\n' >"$trial/home/local-credential"
  chmod 600 "$trial/home/local-credential"
  printf 'obsolete-test-only\n' >"$trial/password.txt"
  cat >"$trial/paseo" <<SCRIPT
#!/bin/sh
# Keep this trial independent of global PATH and Paseo's default home.
exec $HOME/.local/share/mise/installs/node/26.5.0/bin/node \\
  $trial/runtime/node_modules/@getpaseo/cli/bin/paseo \\
  --home $trial/home "\$@"
SCRIPT
  chmod +x "$trial/paseo"
  cat >"$UNIT_PATH" <<SCRIPT
[Unit]
Description=Paseo Pi interface for pi.dpao.la
Conflicts=pi-webui.service

[Service]
Type=simple
WorkingDirectory=%h
Environment=PATH=%h/.dotfiles/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$STUB_BIN/mise exec -- %h/.local/share/paseo-trial/paseo daemon run
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
UMask=0077

[Install]
WantedBy=default.target
SCRIPT
  printf '1\n' >"$SERVICE_STATE/active"
  printf '1\n' >"$SERVICE_STATE/enabled"
}
