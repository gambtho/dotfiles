#!/usr/bin/env bats
# Fake bodies expand when run; Bats isolates each test's exported fixture state.
# shellcheck disable=SC2016,SC2030,SC2031

load test_helper

setup() {
  setup_dotfiles_test
  export XDG_CACHE_HOME="$HOME/.cache"
  HELPER="$REPO_ROOT/libexec/cache-prune"
  export CALLS="$TEST_ROOT/calls" DU_CALLS="$TEST_ROOT/du-calls" ENVS="$TEST_ROOT/envs"
  export TIMEOUTS="$TEST_ROOT/timeouts" PS_CALLS="$TEST_ROOT/ps-calls"
  export DOCKER_CALLS="$TEST_ROOT/docker-calls"
  touch "$CALLS" "$DU_CALLS" "$ENVS" "$TIMEOUTS" "$PS_CALLS" "$DOCKER_CALLS"
  unset DOCKER_READY DOCKER_FAIL PS_DOCKER
  export GO_SIZE=20971520 UV_SIZE=5242880 NPM_SIZE=5242880
  export GOENV="$HOME/go-env" GOFLAGS=-modcache GOTOOLCHAIN=auto
  export GOCACHE="$HOME/custom-go" UV_CACHE_DIR="$HOME/custom-uv" npm_config_cache="$HOME/custom-npm"
  export npm_config_logs_dir="$TEST_ROOT/external-logs" npm_config_logs_max=0
  printf 'GOFLAGS=-modcache\nGOTOOLCHAIN=auto\nGOCACHE=%s\n' "$HOME/custom-go" >"$GOENV"
  unset PROBE_FAIL FAIL_TOOL DU_FAIL DU_BAD PS_FAIL PS_NAMES RACE_TARGET DROP_ROOT
  mkdir -p "$XDG_CACHE_HOME/go-build/00" "$XDG_CACHE_HOME/go-build/ff" \
    "$XDG_CACHE_HOME/uv" "$HOME/.npm/_cacache"
  touch "$XDG_CACHE_HOME/go-build/log.txt"
  local tool
  for tool in go uv npm; do
    stub_command "$tool" '
tool=${0##*/}
printf "%s" "$tool" >>"$CALLS"; printf "|%s" "$@" >>"$CALLS"; printf "\n" >>"$CALLS"
printf "%s|%s|%s|%s|%s|%s|%s\n" "$tool" "$MISE_AUTO_INSTALL" "$PWD" "${GOCACHE-}" "${GOENV-}" "${GOTOOLCHAIN-}" "${GOFLAGS-absent}" >>"$ENVS"
if [[ "$1" == version || "$1" == --version ]]; then
  [[ "${PROBE_FAIL-}" != "$tool" ]] || exit 127
  echo "$tool fixture version"
else
  [[ "${FAIL_TOOL-}" != "$tool" ]] || exit 124
  [[ "${DROP_ROOT-}" != uv || "$tool" != uv ]] || rmdir "$XDG_CACHE_HOME/uv"
fi'
  done
  # Never let the host Docker CLI/daemon escape the fixture.
  stub_command docker '
printf "%s" "$1" >>"$DOCKER_CALLS"
for arg in "${@:2}"; do printf "|%s" "$arg" >>"$DOCKER_CALLS"; done
printf "\n" >>"$DOCKER_CALLS"
[[ "${DOCKER_READY-}" == yes ]] || exit 124
case "$*" in
  "info") echo server ;;
  "system df")
    count=$(grep -c "^system|df$" "$DOCKER_CALLS")
    [[ "${DOCKER_FAIL-}" != "df$count" ]] || { echo "measurement failed" >&2; exit 124; }
    printf "TYPE TOTAL ACTIVE SIZE RECLAIMABLE\nImages 2 1 10MB 5MB\n" ;;
  "system prune -a -f" | "volume prune -a -f" | "buildx prune -a -f")
    [[ "${DOCKER_FAIL-}" != "$1" ]] || { echo "prune failed" >&2; exit 124; }
    printf "Deleted unused data\nTotal reclaimed space: 5MB\n" ;;
  *) echo "unexpected docker arguments" >&2; exit 99 ;;
esac'
  stub_command timeout '
printf "%s|" "$@" >>"$TIMEOUTS"; printf "\n" >>"$TIMEOUTS"
[[ "$1" != --kill-after=5s ]] || shift
shift
exec "$@"'
  stub_command ps '
printf "%s|" "$@" >>"$PS_CALLS"; printf "\n" >>"$PS_CALLS"
[[ "${PS_FAIL-}" != yes ]] || exit 1
if [[ "$*" == *comm=,args=* ]]; then
  printf "%s\n" "${PS_DOCKER-}"
else
  printf "%s\n" "${PS_NAMES-}"
fi'
  stub_command du '
printf "%s|" "$@" >>"$DU_CALLS"; printf "\n" >>"$DU_CALLS"
case "$*" in
  *go-build*) tool=go; size=$GO_SIZE ;;
  */uv*) tool=uv; size=$UV_SIZE ;;
  *_cacache*) tool=npm; size=$NPM_SIZE ;;
  *) echo "unexpected measurement" >&2; exit 1 ;;
esac
[[ "${DU_FAIL-}" != "$tool" ]] || exit 124
[[ "${DU_BAD-}" != "$tool" ]] || size=invalid
if [[ -n "${RACE_TARGET-}" && "$tool" == uv ]]; then
  rmdir "$RACE_TARGET"
  ln -s "$HOME/custom-uv" "$RACE_TARGET"
fi
printf "%s\ttotal\n" "$size"'
  # Any accidental installation command must fail rather than touch the host.
  stub_command mise 'echo "unexpected mise call" >&2; exit 99'
  cd "$TEST_ROOT" || return
}

clean_count() {
  grep -c "^$1|\(cache|\)\?clean|" "$CALLS" || true
}

@test "inclusive literal thresholds clean exactly once with pinned native arguments and bounded timeouts" {
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)" -eq 1 ]
  [ "$(clean_count uv)" -eq 1 ]
  [ "$(clean_count npm)" -eq 1 ]
  grep -Fx "go|clean|-cache" "$CALLS"
  grep -Fx "uv|cache|clean|--cache-dir|$XDG_CACHE_HOME/uv" "$CALLS"
  grep -Fx "npm|cache|clean|--force|--cache|$HOME/.npm|--logs-dir|$HOME/.npm/_cacache" "$CALLS"
  [ "$(wc -l <"$CALLS")" -eq 6 ]
  grep -Fx 'go|version' "$CALLS"
  [ "$(grep -Fxc "go|false|$HOME|$XDG_CACHE_HOME/go-build|off|local|absent" "$ENVS")" -eq 2 ]
  [ "$(grep -Fc "|false|$HOME|" "$ENVS")" -eq 6 ]
  [ "$(grep -c '|residual' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^10s|' "$TIMEOUTS")" -eq 3 ]
  [ "$(grep -c '^60s|du|' "$TIMEOUTS")" -eq 6 ]
  [ "$(grep -c '^--kill-after=5s|2m|' "$TIMEOUTS")" -eq 3 ]
  grep -Fx -- "-u|$UID|-o|comm=|" "$PS_CALLS"
  [ "$(grep -Ec '^go\|env(\||$)|-modcache|-fuzzcache' "$CALLS" || true)" -eq 0 ]
}

@test "npm startup logging is pinned to removable cache for probes and cleanup" {
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  grep -Fx "npm|--version|--cache|$HOME/.npm|--logs-dir|$HOME/.npm/_cacache" "$CALLS"
  grep -Fx "npm|cache|clean|--force|--cache|$HOME/.npm|--logs-dir|$HOME/.npm/_cacache" "$CALLS"
}

@test "one KiB below each threshold never cleans" {
  export GO_SIZE=20971519 UV_SIZE=5242879 NPM_SIZE=5242879
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 000 ]
  [ ! -s "$PS_CALLS" ]
}

@test "Go fuzz and npm npx logs do not contribute to measured scopes" {
  mkdir -p "$XDG_CACHE_HOME/go-build/fuzz" "$HOME/.npm/_npx" "$HOME/.npm/_logs"
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  grep -Fx -- "-skc|--|$XDG_CACHE_HOME/go-build/00|$XDG_CACHE_HOME/go-build/ff|$XDG_CACHE_HOME/go-build/log.txt|" "$DU_CALLS"
  grep -Fx -- "-skc|--|$HOME/.npm/_cacache|" "$DU_CALLS"
  grep -Fx -- "-skc|--|$XDG_CACHE_HOME/uv|" "$DU_CALLS"
  [ "$(grep -Ec 'fuzz|_npx|_logs' "$DU_CALLS" || true)" -eq 0 ]
}

@test "unresolved version probe skips only that cache without installing" {
  export PROBE_FAIL=go
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)" -eq 0 ]
  [ "$(clean_count uv)$(clean_count npm)" = 11 ]
  [[ "$output" == *go*skip* ]]
}

@test "unresolved uv shim skips uv without failing Go or npm" {
  export PROBE_FAIL=uv
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count uv)" -eq 0 ]
  [ "$(clean_count go)$(clean_count npm)" = 11 ]
  [[ "$output" == *'uv|skip: tool missing or version unresolved'* ]]
}

@test "missing optional tool skips while other fake tools continue" {
  mkdir "$TEST_ROOT/minbin"
  local tool
  for tool in bash mkdir chmod flock; do
    ln -s "$(command -v "$tool")" "$TEST_ROOT/minbin/$tool"
  done
  for tool in uv npm du ps timeout; do
    ln -s "$STUB_BIN/$tool" "$TEST_ROOT/minbin/$tool"
  done
  PATH="$TEST_ROOT/minbin" run /bin/bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)" -eq 0 ]
  [ "$(clean_count uv)$(clean_count npm)" = 11 ]
}

@test "help and invalid usage exit before creating state or probing tools" {
  run bash "$HELPER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *Usage:* ]]
  run bash "$HELPER" "$HOME"
  [ "$status" -eq 2 ]
  run bash "$HELPER" --help extra
  [ "$status" -eq 2 ]
  [ ! -e "$XDG_STATE_HOME" ]
  [ ! -s "$CALLS" ]
  [ ! -s "$DOCKER_CALLS" ]
}

@test "absent caches are expected skips without native probes or recreation" {
  rmdir "$XDG_CACHE_HOME/go-build/00" "$XDG_CACHE_HOME/go-build/ff"
  rm "$XDG_CACHE_HOME/go-build/log.txt"
  rmdir "$XDG_CACHE_HOME/go-build" "$XDG_CACHE_HOME/uv" "$HOME/.npm/_cacache" "$HOME/.npm"
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ ! -d "$HOME/.npm" ]
}

@test "unsafe cache paths skip Go and uv while npm continues but unsafe state is an error" {
  local path
  for path in relative "$HOME/../home/.cache" "$TEST_ROOT/outside"; do
    XDG_CACHE_HOME="$path" run bash "$HELPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'skip: unsafe cache root'* ]]
  done
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 003 ]
  XDG_STATE_HOME=relative run bash "$HELPER"
  [ "$status" -eq 1 ]
  [ "$(clean_count npm)" -eq 3 ]
}

@test "HOME root is rejected before native calls" {
  HOME=/ run bash "$HELPER"
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
  [ ! -s "$DOCKER_CALLS" ]
}

@test "symlinked cache ancestor and state directory are rejected" {
  ln -s "$XDG_CACHE_HOME" "$HOME/cache-link"
  XDG_CACHE_HOME="$HOME/cache-link" run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 001 ]
  mkdir -p "$HOME/state"
  ln -s "$HOME/state" "$HOME/state-link"
  XDG_STATE_HOME="$HOME/state-link" run bash "$HELPER"
  [ "$status" -eq 1 ]
  [ "$(clean_count npm)" -eq 1 ]
}

@test "symlinked immediate Go bucket log and npm target block that cleanup only" {
  local target
  for target in "$XDG_CACHE_HOME/go-build/00" "$XDG_CACHE_HOME/go-build/log.txt" "$HOME/.npm/_cacache"; do
    if [[ -d "$target" ]]; then rmdir "$target"; else rm "$target"; fi
    ln -s "$HOME" "$target"
  done
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'skip: unsafe cache target'* ]]
  [ "$(clean_count go)$(clean_count npm)$(clean_count uv)" = 001 ]
}

@test "non-directory cache root is an unsafe skip while other caches continue" {
  rmdir "$XDG_CACHE_HOME/uv"
  touch "$XDG_CACHE_HOME/uv"
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count uv)$(clean_count go)$(clean_count npm)" = 011 ]
}

@test "nested uv symlink is allowed and paths with spaces remain single arguments" {
  mkdir -p "$HOME/cache space"
  mv "$XDG_CACHE_HOME/go-build" "$XDG_CACHE_HOME/uv" "$HOME/cache space/"
  export XDG_CACHE_HOME="$HOME/cache space" XDG_STATE_HOME="$HOME/state space"
  ln -s "$HOME/custom-uv" "$XDG_CACHE_HOME/uv/internal-link"
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  grep -Fx "uv|cache|clean|--cache-dir|$HOME/cache space/uv" "$CALLS"
  [ "$(clean_count go)$(clean_count npm)" = 11 ]
}

@test "safety is rechecked after measurement before native cleanup" {
  mkdir "$HOME/custom-uv"
  export RACE_TARGET="$XDG_CACHE_HOME/uv"
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count uv)$(clean_count go)$(clean_count npm)" = 011 ]
}

@test "all exact Go build process names skip Go but do not kill or block other tools" {
  local name
  for name in go compile link asm cgo vet; do
    export PS_NAMES="$name"
    run bash "$HELPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *go*busy* ]]
  done
  [ "$(clean_count go)" -eq 0 ]
  [ "$(clean_count uv)$(clean_count npm)" = 66 ]
}

@test "gopls and non-exact Go names do not block Go" {
  export PS_NAMES=$'gopls\ncompile-helper\nlinker'
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)" -eq 1 ]
}

@test "fetching npm commands with command-word boundary skip npm including truncated title" {
  local title
  for title in 'npm install lod' 'npm install' 'npm i' 'npm ci' 'npm update pkg' 'npm add pkg'; do
    export PS_NAMES="$title"
    run bash "$HELPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *npm*busy* ]]
  done
  [ "$(clean_count npm)" -eq 0 ]
  [ "$(clean_count go)$(clean_count uv)" = 66 ]
}

@test "npm exec run npx node init and adduser never trigger the fetching gate" {
  export PS_NAMES=$'npm exec\nnpm run build\nnpx\nnode\nnpm init\nnpm adduser'
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count npm)" -eq 1 ]
}

@test "process inspection failure skips Go and npm but allows uv" {
  export PS_FAIL=yes
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(clean_count go)$(clean_count npm)$(clean_count uv)" = 001 ]
  [[ "$output" == *inspection* ]]
}

@test "native failure is visible nonzero and does not stop remaining caches" {
  export FAIL_TOOL=go
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$output" == *go*failed* ]]
  [ "$(clean_count go)" -eq 1 ]
  [ "$(clean_count uv)$(clean_count npm)" = 11 ]
}

@test "failed du and invalid numeric output do not guess sizes or stop other caches" {
  export DU_FAIL=go DU_BAD=uv
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 001 ]
  [[ "$output" == *measurement* ]]
}

@test "private state and nonblocking flock distinguish contention from lock errors" {
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  local state="$XDG_STATE_HOME/dotfiles-cache-maintenance"
  [ "$(stat -c %a "$state")" = 700 ]
  [ "$(stat -c %a "$state/lock")" = 600 ]
  exec 8>"$state/lock"
  flock -n 8
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  flock -u 8
  exec 8>&-
  stub_command flock 'exit 9'
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already running"* ]]
}

@test "native removal of the entire uv root reports zero residual without recreating it" {
  export DROP_ROOT=uv
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'uv|residual=0 KiB'* ]]
  [ ! -e "$XDG_CACHE_HOME/uv" ]
  [ "$(grep -c '/uv|' "$DU_CALLS")" -eq 1 ]
}

@test "symlinked lock cannot redirect lock writes or change another file mode" {
  local state="$XDG_STATE_HOME/dotfiles-cache-maintenance"
  mkdir -p "$state"
  touch "$HOME/untouched"
  chmod 644 "$HOME/untouched"
  ln -s "$HOME/untouched" "$state/lock"
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
  [ "$(stat -c %a "$HOME/untouched")" = 644 ]
  [ ! -s "$DOCKER_CALLS" ]
}

@test "state setup failure is an error not already-running status" {
  touch "$HOME/not-a-directory"
  XDG_STATE_HOME="$HOME/not-a-directory/state" run bash "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already running"* ]]
  [ ! -s "$DOCKER_CALLS" ]
}

@test "Docker prunes exact unused scopes between summary measurements with bounded calls" {
  export DOCKER_READY=yes
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(<"$DOCKER_CALLS")" = $'info\nsystem|df\nsystem|prune|-a|-f\nvolume|prune|-a|-f\nbuildx|prune|-a|-f\nsystem|df' ]
  [[ "$output" == *'docker|before: TYPE TOTAL ACTIVE SIZE RECLAIMABLE'* ]]
  [[ "$output" == *'docker|after: Images 2 1 10MB 5MB'* ]]
  [[ "$output" == *'docker|system prune: Total reclaimed space: 5MB'* ]]
  [[ "$output" == *'docker|volume prune: Deleted unused data'* ]]
  [[ "$output" == *'docker|buildx prune: Deleted unused data'* ]]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 111 ]
  grep -Fx -- '--kill-after=5s|10s|docker|info|' "$TIMEOUTS"
  [ "$(grep -Fxc -- '--kill-after=5s|60s|docker|system|df|' "$TIMEOUTS")" -eq 2 ]
  [ "$(grep -c '^--kill-after=5s|2m|docker|' "$TIMEOUTS")" -eq 3 ]
  grep -Fx -- '--kill-after=5s|2m|docker|volume|prune|-a|-f|' "$TIMEOUTS"
  if grep -Eq '^TYPE|^Images|^Deleted|^Total' <<<"$output"; then return 1; fi
}

@test "Docker unavailable or timed out daemon skips successfully without deletion" {
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'docker|skip: daemon unavailable'* ]]
  [ "$(<"$DOCKER_CALLS")" = info ]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 111 ]
}

@test "missing Docker CLI skips without invoking a daemon" {
  mkdir "$TEST_ROOT/minbin"
  local tool
  for tool in bash mkdir chmod flock; do
    ln -s "$(command -v "$tool")" "$TEST_ROOT/minbin/$tool"
  done
  for tool in go uv npm du ps timeout; do
    ln -s "$STUB_BIN/$tool" "$TEST_ROOT/minbin/$tool"
  done
  PATH="$TEST_ROOT/minbin" run /bin/bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'docker|skip: tool missing'* ]]
  [ ! -s "$DOCKER_CALLS" ]
}

@test "Docker build compose and buildx clients skip deletion after summary" {
  export DOCKER_READY=yes
  local process
  for process in 'docker docker build .' 'docker /usr/bin/docker --context dev buildx bake' \
    'docker docker compose up' 'docker-buildx /plugins/docker-buildx build .' \
    'docker-compose docker-compose up' 'buildx buildx bake'; do
    export PS_DOCKER="$process"
    : >"$DOCKER_CALLS"
    run bash "$HELPER"
    [ "$status" -eq 0 ]
    [[ "$output" == *'docker|skip: busy'* ]]
    [ "$(<"$DOCKER_CALLS")" = $'info\nsystem|df' ]
  done
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 666 ]
}

@test "unrelated processes and Docker inspection do not block pruning" {
  export DOCKER_READY=yes PS_DOCKER=$'node node script build\ndocker docker ps\ndockerd dockerd'
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  grep -Fx 'system|prune|-a|-f' "$DOCKER_CALLS"
}

@test "Docker process inspection failure skips deletion but allows uv" {
  export DOCKER_READY=yes PS_FAIL=yes
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'docker|skip: process inspection failed'* ]]
  [ "$(<"$DOCKER_CALLS")" = $'info\nsystem|df' ]
  [ "$(clean_count go)$(clean_count uv)$(clean_count npm)" = 010 ]
}

@test "Docker before measurement failure prevents all pruning" {
  export DOCKER_READY=yes DOCKER_FAIL=df1
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$output" == *'docker|before: measurement failed'* ]]
  [ "$(<"$DOCKER_CALLS")" = $'info\nsystem|df' ]
}

@test "Docker cleanup failure does not retry or omit remaining cleanup and after summary" {
  export DOCKER_READY=yes
  local step
  for step in system volume buildx; do
    export DOCKER_FAIL="$step"
    : >"$DOCKER_CALLS"
    run bash "$HELPER"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker|$step prune: prune failed"* ]]
    [[ "$output" == *'docker|error:'* ]]
    [[ "$output" == *'docker|after:'* ]]
    [ "$(<"$DOCKER_CALLS")" = $'info\nsystem|df\nsystem|prune|-a|-f\nvolume|prune|-a|-f\nbuildx|prune|-a|-f\nsystem|df' ]
  done
}

@test "Docker after measurement timeout fails even after successful pruning" {
  export DOCKER_READY=yes DOCKER_FAIL=df2
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  [[ "$output" == *'docker|after: measurement failed'* ]]
  [[ "$output" == *'docker|error:'* ]]
  grep -Fx 'buildx|prune|-a|-f' "$DOCKER_CALLS"
}

@test "earlier cache failure still runs Docker and keeps failure status" {
  export DOCKER_READY=yes FAIL_TOOL=go
  run bash "$HELPER"
  [ "$status" -eq 1 ]
  grep -Fx 'buildx|prune|-a|-f' "$DOCKER_CALLS"
  [[ "$output" == *'docker|after:'* ]]
}

@test "helper lock contention prevents even Docker probes" {
  export DOCKER_READY=yes
  local state="$XDG_STATE_HOME/dotfiles-cache-maintenance"
  mkdir -p "$state"
  exec 8>"$state/lock"
  flock -n 8
  run bash "$HELPER"
  [ "$status" -eq 0 ]
  [[ "$output" == *'already running'* ]]
  [ ! -s "$DOCKER_CALLS" ]
  flock -u 8
  exec 8>&-
}
