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

@test "require_platform refuses a non-Linux host" {
  source_installer PROJECTMUX_OS=Darwin bash -c '
    source "$1/tools/projectmux/install.sh"
    require_platform
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only"* ]]
}

@test "a non-Linux host is refused before anything is written" {
  # Goes through main (not require_platform directly) so the assertions below
  # actually exercise the ordering the test name claims: the platform gate
  # runs before install_binary/install_config/install_unit, so none of the
  # published artifacts should exist afterward.
  source_installer PROJECTMUX_OS=Darwin bash -c '
    source "$1/tools/projectmux/install.sh"
    main
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only"* ]]
  [ ! -e "$TEST_ROOT/bin/projectmux" ]
  [ ! -e "$TEST_ROOT/config/projectmux/defaults.yaml" ]
  [ ! -e "$TEST_ROOT/home/.config/systemd/user/projectmux-autostart.service" ]
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

@test "installed_marker preserves interior whitespace in a local path" {
  mkdir -p "$TEST_ROOT/local/My Projects"
  printf '#!/usr/bin/env bash\necho local\n' >"$TEST_ROOT/local/My Projects/projectmux"
  chmod 0755 "$TEST_ROOT/local/My Projects/projectmux"

  source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/My Projects/projectmux" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_local_binary >/dev/null
    printf "MARKER=%s\n" "$(installed_marker)"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"MARKER=local:$TEST_ROOT/local/My Projects/projectmux"* ]]
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

@test "pinned install publishes a regular file and records the version" {
  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    bash -c '
      source "$1/tools/projectmux/install.sh"
      download_verified_artifact() { printf "binary" >"$3"; }
      install_pinned_binary amd64
      printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
    ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"MARKER=v0.1.0"* ]]
  [ -f "$TEST_ROOT/bin/projectmux" ]
  [ ! -L "$TEST_ROOT/bin/projectmux" ]
  [ -x "$TEST_ROOT/bin/projectmux" ]
}

@test "a matching marker and a regular file skip the download entirely" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
  printf 'installed' >"$TEST_ROOT/bin/projectmux"
  chmod 0755 "$TEST_ROOT/bin/projectmux"
  printf 'v0.1.0\n' >"$TEST_ROOT/state/installed-version"

  # return 99 rather than a stub download: if the short-circuit fails to fire,
  # the install errors instead of quietly succeeding with fabricated content.
  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    bash -c '
      source "$1/tools/projectmux/install.sh"
      download_verified_artifact() { return 99; }
      install_pinned_binary amd64
      printf "EXACT=%s\n" "$(installed_marker)"
    ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/bin/projectmux")" = installed ]
  # Exact equality, not a substring: the short-circuit compares installed_marker
  # to the bare tag, so a future change that leaves stray whitespace in the
  # marker read must fail this test rather than pass on a loose match.
  [ "${lines[-1]}" = "EXACT=v0.1.0" ]
}

@test "a matching marker with a symlink destination still reinstalls" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/local"
  printf 'local build' >"$TEST_ROOT/local/projectmux"
  chmod 0755 "$TEST_ROOT/local/projectmux"
  ln -s "$TEST_ROOT/local/projectmux" "$TEST_ROOT/bin/projectmux"
  # The pathological pair the Reconciliation invariant describes: a pinned
  # marker naming a version the destination does not actually hold.
  printf 'v0.1.0\n' >"$TEST_ROOT/state/installed-version"

  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    bash -c '
      source "$1/tools/projectmux/install.sh"
      download_verified_artifact() { printf "pinned" >"$3"; }
      install_pinned_binary amd64
    ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -L "$TEST_ROOT/bin/projectmux" ]
  [ "$(cat "$TEST_ROOT/bin/projectmux")" = pinned ]
  # The local build itself is untouched -- the symlink was replaced, not followed.
  [ "$(cat "$TEST_ROOT/local/projectmux")" = "local build" ]
}

@test "a local marker cannot short-circuit, so the pin is restored" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/local"
  printf 'local build' >"$TEST_ROOT/local/projectmux"
  chmod 0755 "$TEST_ROOT/local/projectmux"
  ln -s "$TEST_ROOT/local/projectmux" "$TEST_ROOT/bin/projectmux"
  printf 'local:%s\n' "$TEST_ROOT/local/projectmux" >"$TEST_ROOT/state/installed-version"

  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    bash -c '
      source "$1/tools/projectmux/install.sh"
      download_verified_artifact() { printf "pinned" >"$3"; }
      install_pinned_binary amd64
      printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
    ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"MARKER=v0.1.0"* ]]
  [ -f "$TEST_ROOT/bin/projectmux" ]
  [ ! -L "$TEST_ROOT/bin/projectmux" ]
  [ "$(cat "$TEST_ROOT/bin/projectmux")" = pinned ]
}

@test "a failed verification leaves the installed binary untouched" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
  printf 'previous' >"$TEST_ROOT/bin/projectmux"
  chmod 0755 "$TEST_ROOT/bin/projectmux"
  printf 'v0.0.9\n' >"$TEST_ROOT/state/installed-version"

  run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
    PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
    PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
    bash -c '
      source "$1/tools/projectmux/install.sh"
      download_verified_artifact() { printf "checksum mismatch\n" >&2; return 1; }
      install_pinned_binary amd64
    ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_ROOT/bin/projectmux")" = previous ]
  [ "$(cat "$TEST_ROOT/state/installed-version")" = v0.0.9 ]
}

@test "defaults.yaml is created with the configured repository roots" {
  source_installer PROJECTMUX_REPOSITORY_ROOTS="$TEST_ROOT/workspace:$TEST_ROOT/other" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  local config="$TEST_ROOT/config/projectmux/defaults.yaml"
  [ -f "$config" ]
  grep -Fq "  - '$TEST_ROOT/workspace'" "$config"
  grep -Fq "  - '$TEST_ROOT/other'" "$config"
  [[ "$(cat "$config")" != *"@REPOSITORY_ROOTS@"* ]]
  grep -Fq 'shell: true' "$config"
  # command: null sets zero window modes and fails v1 validation.
  [[ "$(cat "$config")" != *"command: null"* ]]
  [ -d "$TEST_ROOT/config/projectmux/workspaces" ]
}

@test "an existing config is never overwritten and drift is reported" {
  mkdir -p "$TEST_ROOT/config/projectmux"
  printf 'version: 1\n# hand edited\n' >"$TEST_ROOT/config/projectmux/defaults.yaml"

  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the shipped defaults"* ]]
  [ "$(cat "$TEST_ROOT/config/projectmux/defaults.yaml")" = $'version: 1\n# hand edited' ]
}

@test "a second run of an unedited config warns about nothing" {
  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    install_config
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"differs from the shipped defaults"* ]]
}

@test "no staging file is left behind in the config root" {
  source_installer bash -c '
    source "$1/tools/projectmux/install.sh"
    install_config
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  run bash -c 'compgen -G "$1/.defaults.yaml.*"' _ "$TEST_ROOT/config/projectmux"
  [ "$status" -eq 1 ]
}

@test "a repository root containing a space renders as one quoted entry" {
  source_installer PROJECTMUX_REPOSITORY_ROOTS="$TEST_ROOT/my code" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  grep -Fq "  - '$TEST_ROOT/my code'" "$TEST_ROOT/config/projectmux/defaults.yaml"
  # Anchored to a quoted entry: the windows list below repository_roots also
  # uses "  - " bullets, so an unanchored count would pass for the wrong reason.
  [ "$(grep -c "^  - '" "$TEST_ROOT/config/projectmux/defaults.yaml")" -eq 1 ]
}

@test "the user unit is written with the installed binary path" {
  source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_unit
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  local unit="$TEST_ROOT/config/systemd/user/projectmux-autostart.service"
  [ -f "$unit" ]
  [ ! -L "$unit" ]
  grep -Fq "ExecStart=$TEST_ROOT/bin/projectmux autostart" "$unit"
  [[ "$(cat "$unit")" != *"@PROJECTMUX_BIN@"* ]]
}

@test "installing the unit never invokes systemctl" {
  # A stub that fails loudly: if install_unit ever grows a daemon-reload or an
  # enable, this test fails instead of the change quietly mutating the user
  # manager on every machine that runs bin/install.
  mkdir -p "$TEST_ROOT/stub-bin"
  printf '#!/usr/bin/env bash\nprintf "systemctl called\\n" >&2\nexit 1\n' \
    >"$TEST_ROOT/stub-bin/systemctl"
  chmod 0755 "$TEST_ROOT/stub-bin/systemctl"

  source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" \
    PATH="$TEST_ROOT/stub-bin:$PATH" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_unit
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"systemctl called"* ]]
}

@test "no systemctl invocation exists anywhere in the installer" {
  run rg -n 'systemctl' "$REPO_ROOT/tools/projectmux/install.sh"
  [ "$status" -eq 1 ]
}

@test "rewriting an unchanged unit leaves it untouched" {
  source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" bash -c '
    source "$1/tools/projectmux/install.sh"
    install_unit
    install_unit
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$(grep -c 'Installed ProjectMux user unit' <<<"$output")" -eq 1 ]
  run bash -c 'compgen -G "$1/.projectmux-autostart.service.*"' \
    _ "$TEST_ROOT/config/systemd/user"
  [ "$status" -eq 1 ]
}
