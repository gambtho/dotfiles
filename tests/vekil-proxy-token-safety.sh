#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PROXY="$ROOT/bin/vekil-proxy"
TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/vekil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$VEKIL_TEST_LOG"
if [[ "${VEKIL_TEST_CREATE_TOKEN_SYMLINK:-0}" == "1" && "${1:-}" == "${VEKIL_TEST_SYMLINK_COMMAND:-login}" ]]; then
  rm -f -- "$VEKIL_TOKEN_DIR/access-token"
  ln -s "$VEKIL_TEST_SYMLINK_TARGET" "$VEKIL_TOKEN_DIR/access-token"
fi
EOF
chmod +x "$TMP/bin/vekil"

run_proxy() {
  local case_dir="$1" command="$2"
  shift 2
  env \
    VEKIL_BIN="$TMP/bin/vekil" \
    VEKIL_TOKEN_DIR="$case_dir/token" \
    VEKIL_STATE_DIR="$case_dir/state" \
    VEKIL_TEST_LOG="$case_dir/invocations" \
    VEKIL_HOST=127.0.0.1 \
    VEKIL_PORT=61337 \
    VEKIL_START_TIMEOUT=1 \
    "$@" \
    "$PROXY" "$command"
}

assert_symlink_rejected() {
  local command="$1" case_dir
  case_dir="$TMP/symlink-$command"
  mkdir -p "$case_dir/token" "$case_dir/state"
  : > "$case_dir/target"
  : > "$case_dir/invocations"
  ln -s "$case_dir/target" "$case_dir/token/access-token"

  if run_proxy "$case_dir" "$command" >"$case_dir/output" 2>&1; then
    fail "$command accepted a symlinked access token"
  fi
  [[ ! -s "$case_dir/invocations" ]] || fail "$command invoked Vekil before rejecting the token symlink"
}

for command in login start logout; do
  assert_symlink_rejected "$command"
done

mode_dir="$TMP/mode"
mkdir -p "$mode_dir/token" "$mode_dir/state"
: > "$mode_dir/token/access-token"
: > "$mode_dir/invocations"
chmod 0644 "$mode_dir/token/access-token"
run_proxy "$mode_dir" login >"$mode_dir/output" 2>&1 || fail "login rejected a valid regular access token"
mode=$(stat -c '%a' "$mode_dir/token/access-token" 2>/dev/null || stat -f '%Lp' "$mode_dir/token/access-token")
[[ "$mode" == "600" ]] || fail "login left access-token mode at $mode instead of 600"

for command in login logout; do
  post_dir="$TMP/post-$command"
  mkdir -p "$post_dir/token" "$post_dir/state"
  : > "$post_dir/token/access-token"
  : > "$post_dir/target"
  : > "$post_dir/invocations"
  if run_proxy "$post_dir" "$command" \
    VEKIL_TEST_CREATE_TOKEN_SYMLINK=1 \
    VEKIL_TEST_SYMLINK_COMMAND="$command" \
    VEKIL_TEST_SYMLINK_TARGET="$post_dir/target" \
    >"$post_dir/output" 2>&1; then
    fail "$command accepted an access-token symlink created by Vekil"
  fi
  [[ -s "$post_dir/invocations" ]] || fail "post-$command validation case did not invoke fake Vekil"
done

echo "PASS: Vekil proxy rejects unsafe access-token entries"
