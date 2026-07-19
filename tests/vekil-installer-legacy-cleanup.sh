#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
INSTALLER="$ROOT/ai/vekil/install.sh"
TMP=$(mktemp -d)
BACKGROUND_PIDS=()

cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

prepare_home() {
  local name="$1" home
  home="$TMP/$name/home"
  mkdir -p "$home/.local/bin" "$home/.local/state/vekil" "$home/.config/litellm" "$home/bin"
  cat > "$home/.local/bin/vekil" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$home/.local/bin/vekil"
  printf 'v0.13.3\n' > "$home/.local/state/vekil/installed-version"
  : > "$home/.config/litellm/config.yaml"
  cat > "$home/bin/litellm" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 0.1
done
EOF
  chmod +x "$home/bin/litellm"
  printf '%s\n' "$home"
}

run_installer() {
  local home="$1"
  shift
  env \
    HOME="$home" \
    VEKIL_INSTALL_DIR="$home/.local/bin" \
    VEKIL_STATE_DIR="$home/.local/state/vekil" \
    VEKIL_TOKEN_DIR="$home/.config/vekil" \
    VEKIL_SKIP_AUTH=1 \
    VEKIL_SKIP_START=1 \
    VEKIL_LEGACY_STOP_TIMEOUT="${VEKIL_LEGACY_STOP_TIMEOUT:-2}" \
    bash "$INSTALLER" "$@"
}

start_process() {
  local executable="$1"
  shift
  "$executable" "$@" &
  STARTED_PID=$!
  BACKGROUND_PIDS+=("$STARTED_PID")
  sleep 0.1
  kill -0 "$STARTED_PID" 2>/dev/null || fail "controlled process $STARTED_PID did not start"
}

assert_dead() {
  local pid="$1" label="$2"
  for _ in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  fail "$label process $pid is still running"
}

matching_case() {
  local name="$1" pid_name="$2" port="$3" home pid_file
  home=$(prepare_home "$name")
  pid_file="$home/.config/litellm/$pid_name"
  start_process "$home/bin/litellm" --config "$home/.config/litellm/config.yaml" --port "$port"
  printf '%s\n' "$STARTED_PID" > "$pid_file"
  run_installer "$home" >"$TMP/$name/output" 2>&1 || fail "$name installer run failed"
  assert_dead "$STARTED_PID" "$name"
  [[ ! -e "$pid_file" ]] || fail "$name PID file was not removed"
  run_installer "$home" >"$TMP/$name/second-output" 2>&1 || fail "$name idempotent installer run failed"
}

matching_case port-4000 proxy.pid 4000
matching_case port-4001 codex-proxy.pid 4001

resolved_home=$(prepare_home resolved-config)
resolved_target="$resolved_home/.config/litellm/resolved-config.yaml"
rm -f "$resolved_home/.config/litellm/config.yaml"
: > "$resolved_target"
ln -s "$resolved_target" "$resolved_home/.config/litellm/config.yaml"
start_process "$resolved_home/bin/litellm" --config "$resolved_target" --port 4000
resolved_pid=$STARTED_PID
resolved_pid_file="$resolved_home/.config/litellm/proxy.pid"
printf '%s\n' "$resolved_pid" > "$resolved_pid_file"
run_installer "$resolved_home" >"$TMP/resolved-config/output" 2>&1 || fail "resolved-config installer run failed"
assert_dead "$resolved_pid" "resolved-config"
[[ ! -e "$resolved_pid_file" ]] || fail "resolved-config PID file was not removed"

force_home=$(prepare_home force)
cat > "$force_home/bin/litellm" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while :; do
  sleep 0.1
done
EOF
chmod +x "$force_home/bin/litellm"
start_process "$force_home/bin/litellm" --config "$force_home/.config/litellm/config.yaml" --port 4000
force_pid=$STARTED_PID
force_pid_file="$force_home/.config/litellm/proxy.pid"
printf '%s\n' "$force_pid" > "$force_pid_file"
VEKIL_LEGACY_STOP_TIMEOUT=0 run_installer "$force_home" >"$TMP/force/output" 2>&1 || fail "force-stop installer run failed"
assert_dead "$force_pid" "force-stop"
[[ ! -e "$force_pid_file" ]] || fail "force-stop PID file was not removed"
rg -q 'forcing shutdown' "$TMP/force/output" || fail "force-stop did not report escalation"

stale_home=$(prepare_home stale)
stale_pid_file="$stale_home/.config/litellm/proxy.pid"
start_process "$stale_home/bin/litellm" --config "$stale_home/.config/litellm/config.yaml" --port 4000
stale_pid=$STARTED_PID
kill "$stale_pid"
wait "$stale_pid" 2>/dev/null || true
printf '%s\n' "$stale_pid" > "$stale_pid_file"
run_installer "$stale_home" >"$TMP/stale/output" 2>&1 || fail "stale PID installer run failed"
[[ ! -e "$stale_pid_file" ]] || fail "stale PID file was not removed"

malformed_home=$(prepare_home malformed)
malformed_pid_file="$malformed_home/.config/litellm/proxy.pid"
printf 'not-a-pid\n' > "$malformed_pid_file"
run_installer "$malformed_home" >"$TMP/malformed/output" 2>&1 || fail "malformed PID installer run failed"
[[ -f "$malformed_pid_file" ]] || fail "malformed PID file was removed"
rg -q 'malformed|invalid' "$TMP/malformed/output" || fail "malformed PID file did not produce a warning"

symlink_home=$(prepare_home symlink)
symlink_pid_file="$symlink_home/.config/litellm/proxy.pid"
printf '123\n' > "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$symlink_pid_file"
run_installer "$symlink_home" >"$TMP/symlink/output" 2>&1 || fail "symlink PID installer run failed"
[[ -L "$symlink_pid_file" ]] || fail "symlinked PID file was removed"
rg -q 'unsafe|symlink' "$TMP/symlink/output" || fail "symlinked PID file did not produce a warning"

mismatch_case() {
  local name="$1" executable_name="$2" config_argument="$3" port_argument="$4" home pid pid_file
  home=$(prepare_home "$name")
  if [[ "$executable_name" != "litellm" ]]; then
    cat > "$home/bin/$executable_name" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 0.1
done
EOF
    chmod +x "$home/bin/$executable_name"
  fi
  [[ "$config_argument" != "EXPECTED" ]] || config_argument="$home/.config/litellm/config.yaml"
  start_process "$home/bin/$executable_name" --config "$config_argument" --port "$port_argument"
  pid=$STARTED_PID
  pid_file="$home/.config/litellm/proxy.pid"
  printf '%s\n' "$pid" > "$pid_file"
  run_installer "$home" >"$TMP/$name/output" 2>&1 || fail "$name installer run failed"
  kill -0 "$pid" 2>/dev/null || fail "$name process was terminated"
  [[ -f "$pid_file" ]] || fail "$name PID file was removed"
  rg -q 'does not match|refusing' "$TMP/$name/output" || fail "$name did not produce a warning"
}

mismatch_case mismatch-executable other-service EXPECTED 4000
mismatch_case mismatch-config litellm "$TMP/not-the-config.yaml" 4000
mismatch_case mismatch-port litellm EXPECTED 4999

check_home=$(prepare_home check)
start_process "$check_home/bin/litellm" --config "$check_home/.config/litellm/config.yaml" --port 4000
check_pid=$STARTED_PID
check_pid_file="$check_home/.config/litellm/proxy.pid"
printf '%s\n' "$check_pid" > "$check_pid_file"
run_installer "$check_home" --check >"$TMP/check/output" 2>&1 || fail "installer --check failed"
kill -0 "$check_pid" 2>/dev/null || fail "installer --check terminated a legacy process"
[[ -f "$check_pid_file" ]] || fail "installer --check removed a legacy PID file"
rg -q 'proxy.pid.*4000' "$TMP/check/output" || fail "installer --check did not report the port-4000 cleanup target"
rg -q 'codex-proxy.pid.*4001' "$TMP/check/output" || fail "installer --check did not report the port-4001 cleanup target"

if VEKIL_LEGACY_STOP_TIMEOUT=invalid run_installer "$check_home" --check >"$TMP/check/invalid-timeout" 2>&1; then
  fail "installer accepted a non-numeric legacy stop timeout"
fi
if VEKIL_LEGACY_STOP_TIMEOUT=301 run_installer "$check_home" --check >"$TMP/check/oversized-timeout" 2>&1; then
  fail "installer accepted a legacy stop timeout above 300 seconds"
fi

echo "PASS: Vekil installer safely cleans up legacy LiteLLM processes"
