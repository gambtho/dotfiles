#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export STATE_DIR="$TEST_ROOT/state"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  printf '123|start-id\n' >"$STATE_DIR/proxy.pid"
  printf '127.0.0.1\n' >"$STATE_DIR/proxy-host"
  printf 'ready\n' >"$STATE_DIR/proxy-ready"
  chmod 0600 "$STATE_DIR"/*
}

@test "graceful Vekil stop removes ownership state only after identity changes" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 0; }
    process_matches_start_id() { return 1; }
    kill() { printf "%s\n" "$*" >>"$VEKIL_STATE_DIR/signals"; }
    stop
  ' _ "$REPO_ROOT" "$STATE_DIR"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/proxy.pid" ]
  [ ! -e "$STATE_DIR/proxy-ready" ]
  [ "$(cat "$STATE_DIR/signals")" = 123 ]
  [[ "$output" == *"STOPPED"* ]]
}

@test "forced Vekil stop confirms SIGKILL before reporting success" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" VEKIL_STOP_TIMEOUT=0 VEKIL_KILL_CONFIRM_TIMEOUT=0 bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 0; }
    matches=0
    process_matches_start_id() { (( matches += 1 )); (( matches <= 2 )); }
    kill() { printf "%s\n" "$*" >>"$VEKIL_STATE_DIR/signals"; }
    stop
  ' _ "$REPO_ROOT" "$STATE_DIR"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/proxy.pid" ]
  grep -Fq -- '-9 123' "$STATE_DIR/signals"
}

@test "Vekil stop keeps confirming the recorded process after it execs" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" VEKIL_STOP_TIMEOUT=0 VEKIL_KILL_CONFIRM_TIMEOUT=0 bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 0; }
    process_matches_start_id() { return 0; }
    kill() { :; }
    stop
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(cat "$STATE_DIR/proxy.pid")" = '123|start-id' ]
  [ "$(cat "$STATE_DIR/proxy-stop-failed")" = '123|start-id' ]
}

@test "surviving Vekil process preserves PID and writes a private failure marker" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" VEKIL_STOP_TIMEOUT=0 VEKIL_KILL_CONFIRM_TIMEOUT=0 bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 0; }
    process_matches_start_id() { return 0; }
    kill() { :; }
    stop
  ' _ "$REPO_ROOT" "$STATE_DIR"

  [ "$status" -ne 0 ]
  [ "$(cat "$STATE_DIR/proxy.pid")" = '123|start-id' ]
  [ "$(cat "$STATE_DIR/proxy-stop-failed")" = '123|start-id' ]
  [ "$(stat -c '%a' "$STATE_DIR/proxy-stop-failed")" = 600 ]
  [ ! -e "$STATE_DIR/proxy-ready" ]
  [[ "$output" == *"unable to stop Vekil pid 123"* ]]
}

@test "Vekil stop does not signal a reused PID after identity changes" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 0; }
    process_matches_start_id() { return 1; }
    kill() { printf "%s\n" "$*" >>"$VEKIL_STATE_DIR/signals"; }
    stop
  ' _ "$REPO_ROOT" "$STATE_DIR"

  [ "$status" -eq 0 ]
  [ "$(wc -l <"$STATE_DIR/signals")" -eq 1 ]
  ! grep -Fq -- '-9' "$STATE_DIR/signals"
}

@test "kill confirmation timeout accepts only integers from zero through thirty" {
  run env VEKIL_KILL_CONFIRM_TIMEOUT=31 VEKIL_STATE_DIR="$STATE_DIR" bash "$REPO_ROOT/bin/vekil-proxy" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid VEKIL_KILL_CONFIRM_TIMEOUT"* ]]

  run env VEKIL_KILL_CONFIRM_TIMEOUT=invalid VEKIL_STATE_DIR="$STATE_DIR" bash "$REPO_ROOT/bin/vekil-proxy" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid VEKIL_KILL_CONFIRM_TIMEOUT"* ]]
}

@test "status reports STOP_FAILED before a healthy endpoint" {
  printf '123|start-id\n' >"$STATE_DIR/proxy-stop-failed"
  chmod 0600 "$STATE_DIR/proxy-stop-failed"

  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    process_matches_start_id() { return 0; }
    is_ready() { return 0; }
    is_healthy() { return 0; }
    status
  ' _ "$REPO_ROOT"

  [ "$status" -eq 1 ]
  [ "$output" = 'STOP_FAILED host=127.0.0.1 port=1337 pid=123' ]
}

@test "status removes a stale stop-failure marker and resumes normal classification" {
  printf '123|old-start\n' >"$STATE_DIR/proxy-stop-failed"
  chmod 0600 "$STATE_DIR/proxy-stop-failed"

  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    process_matches_start_id() { return 1; }
    is_ready() { return 1; }
    is_healthy() { return 1; }
    pid_of() { return 1; }
    status
  ' _ "$REPO_ROOT"

  [ "$status" -eq 1 ]
  [ "$output" = 'DOWN host=127.0.0.1 port=1337' ]
  [ ! -e "$STATE_DIR/proxy-stop-failed" ]
}

@test "printed environment uses the documented Claude model" {
  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    print_env
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'ANTHROPIC_MODEL="claude-opus-5"')" -eq 2 ]
  [[ "$output" != *"claude-opus-4.8"* ]]
}

@test "successful stop clears an earlier stop-failure marker" {
  printf '123|start-id\n' >"$STATE_DIR/proxy-stop-failed"
  chmod 0600 "$STATE_DIR/proxy-stop-failed"

  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    pid_record() { printf "123|start-id\n"; }
    process_matches_record() { return 1; }
    process_matches_start_id() { return 1; }
    stop
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/proxy-stop-failed" ]
}

@test "failed start preserves a stop-failure marker" {
  printf '123|start-id\n' >"$STATE_DIR/proxy-stop-failed"
  chmod 0600 "$STATE_DIR/proxy-stop-failed"

  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    require_command() { :; }
    require_vekil() { return 1; }
    start
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(cat "$STATE_DIR/proxy-stop-failed")" = '123|start-id' ]
}

@test "successful start clears a stop-failure marker" {
  printf '123|start-id\n' >"$STATE_DIR/proxy-stop-failed"
  chmod 0600 "$STATE_DIR/proxy-stop-failed"

  run env VEKIL_PROXY_SOURCE_ONLY=1 VEKIL_STATE_DIR="$STATE_DIR" bash -c '
    source "$1/bin/vekil-proxy"
    require_command() { :; }
    require_vekil() { :; }
    pid_record() { printf "123|start-id\n"; }
    is_healthy() { return 0; }
    is_ready() { return 0; }
    publish_ready_marker() { :; }
    start
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/proxy-stop-failed" ]
}
