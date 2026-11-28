#!/usr/bin/env bats

load test_helper

# The script runs from a fixture copy. sudo runs the command without
# privileges and logs it. dpkg-query, apt-get and apparmor_parser are fakes
# with state under $STATE; the fake bwrap and codex work only once the fake
# parser has loaded the profile, as on Ubuntu 24.04 with the restriction on.
setup() {
  setup_dotfiles_test
  FIXTURE="$TEST_ROOT/repo"
  STATE="$TEST_ROOT/state"
  SYSTEM_BIN="$TEST_ROOT/system-bin"
  export STATE LANE_WORKER_SYSTEM_PATH="$SYSTEM_BIN" FAKE_UNAME=Linux
  export CODEX_SANDBOX_USERNS_KNOB="$TEST_ROOT/userns-knob"
  export CODEX_SANDBOX_APPARMOR_DIR="$TEST_ROOT/etc/apparmor.d"
  export CODEX_SANDBOX_BWRAP="$SYSTEM_BIN/bwrap"
  mkdir -p "$FIXTURE"/{tools/lane-worker,libexec/lib} "$STATE" "$SYSTEM_BIN" "$CODEX_SANDBOX_APPARMOR_DIR"
  cp "$REPO_ROOT/tools/lane-worker/codex-sandbox.sh" "$FIXTURE/tools/lane-worker/"
  cp "$REPO_ROOT/tools/lane-worker/bwrap-userns-restrict.apparmor" "$FIXTURE/tools/lane-worker/"
  cp "$REPO_ROOT/libexec/lib/apt.sh" "$FIXTURE/libexec/lib/"
  cp "$REPO_ROOT/libexec/log-helper" "$FIXTURE/libexec/"
  SCRIPT="$FIXTURE/tools/lane-worker/codex-sandbox.sh"
  PROFILE="$CODEX_SANDBOX_APPARMOR_DIR/bwrap-userns-restrict"
  echo 1 >"$CODEX_SANDBOX_USERNS_KNOB"

  stub_command uname 'echo "$FAKE_UNAME"'
  stub_command sudo 'echo "$*" >>"$STATE/sudo"; exec "$@"'
  stub_command dpkg 'exit 0'
  stub_command dpkg-query '
    grep -qx "${*: -1}" "$STATE/installed" 2>/dev/null || exit 1
    printf "install ok installed"
  '
  # Installing bubblewrap puts the fake bwrap in the system folder.
  stub_command apt-get "
    echo \"apt-get \$*\" >>\"\$STATE/apt\"
    [[ \"\$1\" == install ]] || exit 0
    echo bubblewrap >>\"\$STATE/installed\"
    printf '#!/bin/sh\\n[ -f \"%s/loaded\" ]\\n' \"\$STATE\" >\"$SYSTEM_BIN/bwrap\"
    chmod +x \"$SYSTEM_BIN/bwrap\"
  "
  stub_command apparmor_parser '
    [[ "$1" == -r ]] || exit 2
    echo "$2" >>"$STATE/parsed"
    [[ -f "$STATE/parser-fails" ]] || touch "$STATE/loaded"
  '
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "codex $*" >>"%s/codex"\n[ -f "%s/loaded" ]\n' "$STATE" "$STATE" >"$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
}

@test "usage: exactly one of --check or --apply" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --apply --check
  [ "$status" -eq 2 ]
}

@test "the profile is Ubuntu's bwrap-userns-restrict, attached to /usr/bin/bwrap only" {
  local file="$REPO_ROOT/tools/lane-worker/bwrap-userns-restrict.apparmor"
  grep -qx 'profile bwrap /usr/bin/bwrap flags=(attach_disconnected) {' "$file"
  grep -qx '  allow px /\*\* -> bwrap//&unpriv_bwrap,' "$file"
  grep -qx '  audit deny capability,' "$file"
  [ "$(grep -c '^profile ' "$file")" -eq 2 ]
}

@test "--check says what it would do and changes nothing" {
  run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] Would install bubblewrap (apt)"* ]]
  [[ "$output" == *"[dry-run] Would install $PROFILE (Ubuntu's bwrap-userns-restrict) and load it."* ]]
  [ ! -e "$STATE/sudo" ]
  [ ! -e "$PROFILE" ]
  [ ! -e "$STATE/codex" ]
}

@test "--apply installs bubblewrap and the profile, loads it, checks Codex, and a second run changes nothing" {
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  cmp "$FIXTURE/tools/lane-worker/bwrap-userns-restrict.apparmor" "$PROFILE"
  [ "$(stat -c %a "$PROFILE")" = 644 ]
  [ "$(cat "$STATE/parsed")" = "$PROFILE" ]
  grep -q '^apt-get install .* bubblewrap$' "$STATE/sudo"
  [[ "$output" == *"Loaded $PROFILE."* ]]
  [[ "$output" == *"Codex's sandbox runs commands."* ]]
  [ "$(cat "$STATE/codex")" = "codex sandbox -- true" ]
  # The restriction itself stays on.
  [ "$(cat "$CODEX_SANDBOX_USERNS_KNOB")" = 1 ]
  ! grep -q sysctl "$STATE/sudo"

  rm "$STATE/sudo"
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"bubblewrap is installed."* ]]
  [[ "$output" == *"$SYSTEM_BIN/bwrap can set up its sandbox."* ]]
  [ ! -e "$STATE/sudo" ]
  run bash "$SCRIPT" --check
  [[ "$output" != *"[dry-run]"* ]]
  [[ "$output" == *"Codex's sandbox runs commands."* ]]
}

@test "an installed profile that is not loaded yet is loaded again" {
  bash "$SCRIPT" --apply
  rm "$STATE/loaded" "$STATE/parsed"
  run bash "$SCRIPT" --check
  [[ "$output" == *"[dry-run] $SYSTEM_BIN/bwrap cannot set up its sandbox yet; --apply would load $PROFILE."* ]]
  [ ! -e "$STATE/parsed" ]
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/parsed")" = "$PROFILE" ]
}

@test "a bwrap that already works gets no profile" {
  echo bubblewrap >"$STATE/installed"
  printf '#!/bin/sh\nexit 0\n' >"$SYSTEM_BIN/bwrap"
  chmod +x "$SYSTEM_BIN/bwrap"
  touch "$STATE/loaded" # so the fake codex works too
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SYSTEM_BIN/bwrap can set up its sandbox."* ]]
  [[ "$output" == *"Codex's sandbox runs commands."* ]]
  [ ! -e "$PROFILE" ]
  [ ! -e "$STATE/parsed" ]
  [ ! -e "$STATE/sudo" ]
}

@test "a different file at the profile path is left alone" {
  echo 'profile other {}' >"$PROFILE"
  run bash "$SCRIPT" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not Ubuntu's profile this script installs, so it was left alone"* ]]
  [ "$(cat "$PROFILE")" = 'profile other {}' ]
  [ ! -e "$STATE/parsed" ]
}

@test "a profile that loads but does not help fails loudly" {
  touch "$STATE/parser-fails"
  run bash "$SCRIPT" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"still cannot set up its sandbox after loading $PROFILE"* ]]
}

@test "nothing to do without the restriction, or on macOS" {
  echo 0 >"$CODEX_SANDBOX_USERNS_KNOB"
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not restrict unprivileged user namespaces here; nothing to do."* ]]
  rm "$CODEX_SANDBOX_USERNS_KNOB"
  run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  FAKE_UNAME=Darwin run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex uses the system sandbox on Darwin; nothing to do."* ]]
  [ ! -e "$STATE/sudo" ]
  [ ! -e "$PROFILE" ]
}
