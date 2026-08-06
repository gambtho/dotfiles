#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

# Every test sources the installer instead of executing it, matching the
# pattern in tests/font_install.bats: sourcing lets a test override a single
# function (download_verified_artifact, systemctl) without a PATH stub, and
# keeps the real main() from running.
source_installer() {
  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    PROJECTMUX_CONFIG_ROOT="$TEST_ROOT/config/projectmux" \
    "$@"
}

@test "a non-Linux host is refused before anything is written" {
  source_installer PROJECTMUX_OS=Darwin bash -c '
    source "$1/tools/projectmux/install.sh"
    require_platform
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only"* ]]
  [ ! -e "$TEST_ROOT/bin/projectmux" ]
}

@test "an unsupported architecture is refused" {
  source_installer PROJECTMUX_ARCH=riscv64 bash -c '
    source "$1/tools/projectmux/install.sh"
    require_platform
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported ProjectMux architecture: riscv64"* ]]
}

@test "supported architecture spellings normalize" {
  local spelling
  for spelling in x86_64 amd64; do
    source_installer PROJECTMUX_ARCH="$spelling" bash -c '
      source "$1/tools/projectmux/install.sh"
      require_platform
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = amd64 ]
  done

  for spelling in aarch64 arm64; do
    source_installer PROJECTMUX_ARCH="$spelling" bash -c '
      source "$1/tools/projectmux/install.sh"
      require_platform
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = arm64 ]
  done
}

@test "publish_file refuses a directory destination" {
  mkdir -p "$TEST_ROOT/bin/projectmux"

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    staged=$(mktemp "$TEST_ROOT/bin/.projectmux.XXXXXX")
    printf "new" >"$staged"
    publish_file "$staged" "$PROJECTMUX_BIN"
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to replace directory"* ]]
  [ -d "$TEST_ROOT/bin/projectmux" ]
}

@test "publish_file replaces a symlink instead of writing through it" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/elsewhere"
  printf 'original' >"$TEST_ROOT/elsewhere/projectmux"
  ln -s "$TEST_ROOT/elsewhere/projectmux" "$TEST_ROOT/bin/projectmux"

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    staged=$(mktemp "$TEST_ROOT/bin/.projectmux.XXXXXX")
    printf "replacement" >"$staged"
    publish_file "$staged" "$PROJECTMUX_BIN"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -L "$TEST_ROOT/bin/projectmux" ]
  [ "$(cat "$TEST_ROOT/bin/projectmux")" = replacement ]
  # The link target is untouched -- proof mv -T replaced the link rather than
  # following it.
  [ "$(cat "$TEST_ROOT/elsewhere/projectmux")" = original ]
}

@test "installed_marker treats a symlinked marker as absent" {
  mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/elsewhere"
  printf 'v9.9.9\n' >"$TEST_ROOT/elsewhere/version"
  ln -s "$TEST_ROOT/elsewhere/version" "$TEST_ROOT/state/installed-version"

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    installed_marker
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "prepare_destination_directory accepts a symlinked directory" {
  mkdir -p "$TEST_ROOT/real-bin"
  # setup_dotfiles_test already created $TEST_ROOT/bin as STUB_BIN (a real
  # directory on PATH); ln -s would drop the link inside it instead of
  # replacing it, so clear it first to actually land the symlink here.
  rm -rf -- "$TEST_ROOT/bin"
  ln -s "$TEST_ROOT/real-bin" "$TEST_ROOT/bin"
  [ -L "$TEST_ROOT/bin" ]

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
}

@test "prepare_destination_directory refuses a plain file" {
  # setup_dotfiles_test already created $TEST_ROOT/bin as STUB_BIN (an empty
  # directory on PATH); remove it so this test's plain-file fixture can take
  # its place.
  rm -rf -- "$TEST_ROOT/bin"
  printf 'not a directory' >"$TEST_ROOT/bin"

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "a local binary is symlinked and recorded without touching the pin" {
  mkdir -p "$TEST_ROOT/local"
  printf '#!/usr/bin/env bash\necho local\n' >"$TEST_ROOT/local/projectmux"
  chmod 0755 "$TEST_ROOT/local/projectmux"

  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary
    printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ -L "$TEST_ROOT/bin/projectmux" ]
  [ "$(readlink "$TEST_ROOT/bin/projectmux")" = "$TEST_ROOT/local/projectmux" ]
  [[ "$output" == *"MARKER=local:$TEST_ROOT/local/projectmux"* ]]

  # The override must never mutate the pin -- the whole point of requirement 3.
  run git -C "$REPO_ROOT" diff --exit-code config/versions.env
  [ "$status" -eq 0 ]
}

@test "a relative local binary path is refused" {
  source_installer PROJECTMUX_LOCAL_BINARY=build/projectmux bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an absolute path"* ]]
  [ ! -e "$TEST_ROOT/bin/projectmux" ]
}

@test "a missing local binary is refused" {
  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/nope/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -e "$TEST_ROOT/bin/projectmux" ]
}

@test "a non-executable local binary is refused" {
  mkdir -p "$TEST_ROOT/local"
  printf 'not executable' >"$TEST_ROOT/local/projectmux"
  chmod 0644 "$TEST_ROOT/local/projectmux"

  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
  [ ! -e "$TEST_ROOT/bin/projectmux" ]
}

@test "a directory as the local binary is refused with its own message" {
  mkdir -p "$TEST_ROOT/local/projectmux"

  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"is a directory"* ]]
}

@test "install_binary dispatches on the override" {
  mkdir -p "$TEST_ROOT/local"
  printf '#!/usr/bin/env bash\ntrue\n' >"$TEST_ROOT/local/projectmux"
  chmod 0755 "$TEST_ROOT/local/projectmux"

  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_pinned_binary() { printf "pinned branch taken\n"; }
    install_binary amd64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"pinned branch taken"* ]]
  [ -L "$TEST_ROOT/bin/projectmux" ]

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    install_pinned_binary() { printf "pinned branch taken\n"; }
    install_binary amd64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned branch taken"* ]]
}
