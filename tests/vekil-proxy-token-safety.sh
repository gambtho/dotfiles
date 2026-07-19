#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
PROXY="$ROOT/bin/vekil-proxy"
INSTALLER="$ROOT/ai/vekil/install.sh"
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
  grep -Fq "Vekil access token must be absent or a regular file: $case_dir/token/access-token" "$case_dir/output" ||
    fail "$command did not use the shared access-token error message"
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

installer_dir="$TMP/installer-directory-race"
mkdir -p "$installer_dir/bin" "$installer_dir/home/.local/state/vekil" "$installer_dir/token" "$installer_dir/token-target"
: >"$installer_dir/invocations"
printf 'v0.13.3\n' >"$installer_dir/home/.local/state/vekil/installed-version"
cat >"$installer_dir/bin/chmod" <<'EOF'
#!/bin/bash
set -euo pipefail
/usr/bin/chmod "$@"
if [[ "${1:-}" == "0700" && "${2:-}" == "$VEKIL_TOKEN_DIR" ]]; then
  rm -rf -- "$VEKIL_TOKEN_DIR"
  ln -s "$VEKIL_TEST_TOKEN_TARGET" "$VEKIL_TOKEN_DIR"
fi
EOF
chmod +x "$installer_dir/bin/chmod"
if env \
  HOME="$installer_dir/home" \
  PATH="$installer_dir/bin:/usr/bin:/bin" \
  VEKIL_BIN="$TMP/bin/vekil" \
  VEKIL_STATE_DIR="$installer_dir/home/.local/state/vekil" \
  VEKIL_TOKEN_DIR="$installer_dir/token" \
  VEKIL_TEST_TOKEN_TARGET="$installer_dir/token-target" \
  VEKIL_TEST_LOG="$installer_dir/invocations" \
  VEKIL_SKIP_START=1 \
  bash "$INSTALLER" >"$installer_dir/output" 2>&1; then
  fail "installer accepted a token directory replaced after chmod"
fi
[[ ! -s "$installer_dir/invocations" ]] || fail "installer invoked Vekil after the token directory was replaced"
grep -Fq "Vekil token directory must be a real directory: $installer_dir/token" "$installer_dir/output" ||
  fail "installer did not report the replaced token directory"

echo "PASS: Vekil proxy rejects unsafe access-token entries"
