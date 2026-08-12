#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

# Every test sources the installer instead of executing it, matching the
# pattern in tests/font_install.bats: sourcing lets a test override a single
# function (download_verified_artifact) without a PATH stub, and keeps the
# real main() from running.
source_installer() {
  run env HERDR_INSTALL_SOURCE_ONLY=1 \
    HERDR_INSTALL_DIR="$TEST_ROOT/bin" \
    HERDR_STATE_ROOT="$TEST_ROOT/state" \
    HERDR_CONFIG_ROOT="$TEST_ROOT/config/herdr" \
    "$@"
}

@test "require_platform refuses a non-Linux host" {
  source_installer HERDR_OS=Darwin bash -c '
    source "$1/tools/herdr/install.sh"
    require_platform
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only"* ]]
}

@test "a non-Linux host is refused before anything is written" {
  # Goes through main (not require_platform directly) so the assertion below
  # exercises the ordering the test name claims: the platform gate runs before
  # install_pinned_binary and install_config, so neither published artifact
  # should exist afterward.
  source_installer HERDR_OS=Darwin bash -c '
    source "$1/tools/herdr/install.sh"
    main
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only"* ]]
  [ ! -e "$TEST_ROOT/bin/herdr" ]
  [ ! -e "$TEST_ROOT/config/herdr/config.toml" ]
}

@test "an unsupported architecture is refused" {
  source_installer HERDR_ARCH=riscv64 bash -c '
    source "$1/tools/herdr/install.sh"
    require_platform
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported Herdr architecture: riscv64"* ]]
}

@test "architecture spellings map to upstream asset names" {
  # Upstream names assets by uname arch (x86_64/aarch64), not amd64/arm64, so
  # both spellings of each have to land on the uname form or the download 404s.
  local spelling expected
  for spelling in x86_64 amd64; do
    source_installer HERDR_ARCH="$spelling" bash -c '
      source "$1/tools/herdr/install.sh"
      require_platform
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == "x86_64" ]]
  done

  for spelling in aarch64 arm64; do
    source_installer HERDR_ARCH="$spelling" bash -c '
      source "$1/tools/herdr/install.sh"
      require_platform
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == "aarch64" ]]
  done
}

@test "the pinned install publishes the binary, then the marker" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    download_verified_artifact() { printf "fake-herdr\n" >"$3"; chmod "$4" "$3"; }
    install_pinned_binary x86_64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/bin/herdr" ]
  [ -x "$TEST_ROOT/bin/herdr" ]
  [ ! -L "$TEST_ROOT/bin/herdr" ]
  run cat "$TEST_ROOT/state/installed-version"
  [[ "$output" == "v0.8.0" ]]
}

@test "a second run with a matching marker does not re-download" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    download_verified_artifact() { printf "fake-herdr\n" >"$3"; chmod "$4" "$3"; }
    install_pinned_binary x86_64
    # Any download on the second pass is a failure, not a no-op.
    download_verified_artifact() { printf "re-downloaded\n" >&2; return 1; }
    install_pinned_binary x86_64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [[ "$output" != *"re-downloaded"* ]]
}

@test "a symlinked binary with a matching marker is repaired, not trusted" {
  # The binary and the marker are published by two separate renames, so an
  # interrupted run can pair one with the other. The marker test alone would
  # skip the reinstall and leave the mismatch in place forever.
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
  ln -s /nonexistent "$TEST_ROOT/bin/herdr"
  printf 'v0.8.0\n' >"$TEST_ROOT/state/installed-version"

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    download_verified_artifact() { printf "fake-herdr\n" >"$3"; chmod "$4" "$3"; }
    install_pinned_binary x86_64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -L "$TEST_ROOT/bin/herdr" ]
  [ -f "$TEST_ROOT/bin/herdr" ]
}

@test "a symlinked marker is treated as absent rather than followed" {
  mkdir -p "$TEST_ROOT/state"
  printf 'v0.8.0\n' >"$TEST_ROOT/state/planted"
  ln -s "$TEST_ROOT/state/planted" "$TEST_ROOT/state/installed-version"

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    installed_marker
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
}

@test "the config is installed when absent" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ -f "$TEST_ROOT/config/herdr/config.toml" ]
  run cat "$TEST_ROOT/config/herdr/config.toml"
  [[ "$output" == *'name = "tokyo-night"'* ]]
  [[ "$output" == *"version_check = false"* ]]
}

@test "an edited config is left alone and reported as drift" {
  mkdir -p "$TEST_ROOT/config/herdr"
  printf '[theme]\nname = "kanagawa"\n' >"$TEST_ROOT/config/herdr/config.toml"

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"differs from the shipped defaults"* ]]
  run cat "$TEST_ROOT/config/herdr/config.toml"
  [[ "$output" == *"kanagawa"* ]]
}

@test "install_config leaves no staging litter behind" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_config
    install_config
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  run find "$TEST_ROOT/config/herdr" -name '.config.toml.*'
  [[ -z "$output" ]]
}

@test "a directory at the destination is refused rather than descended into" {
  mkdir -p "$TEST_ROOT/bin/herdr"

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    validate_install_target "$2"
  ' _ "$REPO_ROOT" "$TEST_ROOT/bin/herdr"

  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to replace directory"* ]]
}

@test "--check reports the plan without writing anything" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    main --check
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"v0.8.0"* ]]
  [[ "$output" == *"gambtho/herdr-devcontainer@v0.1.0"* ]]
  [[ "$output" == *"(none)"* ]]
  [ ! -e "$TEST_ROOT/bin/herdr" ]
  [ ! -e "$TEST_ROOT/config/herdr/config.toml" ]
}

@test "the shipped config disables the background updater" {
  # The pin in config/versions.env is only meaningful if Herdr does not update
  # itself out from under it.
  run cat "$REPO_ROOT/tools/herdr/config.toml.template"
  [ "$status" -eq 0 ]
  [[ "$output" == *"version_check = false"* ]]
}

@test "the shipped config binds the Dev Container plugin it installs" {
  # Two dead keys otherwise: the config binds actions the plugin phase provides.
  run cat "$REPO_ROOT/tools/herdr/config.toml.template"
  [ "$status" -eq 0 ]
  [[ "$output" == *"devcontainer.open-shell"* ]]
  [[ "$output" == *"devcontainer.open-stop"* ]]

  # prefix+shift+d is Herdr's built-in close_workspace; stop must not sit under
  # a mis-key of it.
  [[ "$output" != *'key = "prefix+shift+d"'* ]]
}

# A fake herdr: enough of `plugin list --json` to drive install_plugin, plus a
# log of every other plugin subcommand so a test can assert what was invoked.
# A fake cargo goes alongside it so the build-hook guard does not turn these
# into silent skips on a host without a Rust toolchain.
fake_herdr() {
  local list_json="$1"
  mkdir -p "$TEST_ROOT/bin"
  cat >"$TEST_ROOT/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "plugin list" ]]; then
  printf '%s\n' '$list_json'
  exit 0
fi
printf '%s\n' "\$*" >>"$TEST_ROOT/plugin-calls"
exit \${FAKE_HERDR_STATUS:-0}
EOF
  chmod 0755 "$TEST_ROOT/bin/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ROOT/bin/cargo"
  chmod 0755 "$TEST_ROOT/bin/cargo"
}

run_install_plugin() {
  source_installer PATH="$TEST_ROOT/bin:$PATH" bash -c '
    source "$1/tools/herdr/install.sh"
    install_plugin
  ' _ "$REPO_ROOT"
}

@test "the plugin is installed at the pinned ref when absent" {
  fake_herdr '{"result":{"plugins":[]}}'

  run_install_plugin

  [ "$status" -eq 0 ]
  run cat "$TEST_ROOT/plugin-calls"
  [[ "$output" == *"plugin install gambtho/herdr-devcontainer --ref v0.1.0 --yes"* ]]
}

@test "a locally linked plugin is left alone" {
  # Someone developing the plugin has it linked from a checkout; replacing that
  # with a tagged release would drop their working tree out of the pane path.
  fake_herdr '{"result":{"plugins":[{"plugin_id":"devcontainer","source":{"kind":"local"}}]}}'

  run_install_plugin

  [ "$status" -eq 0 ]
  [[ "$output" == *"linked from a local checkout"* ]]
  [ ! -e "$TEST_ROOT/plugin-calls" ]
}

@test "a plugin already at the pinned ref is not reinstalled" {
  fake_herdr '{"result":{"plugins":[{"plugin_id":"devcontainer","source":{"kind":"github","requested_ref":"v0.1.0"}}]}}'

  run_install_plugin

  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  [ ! -e "$TEST_ROOT/plugin-calls" ]
}

@test "a plugin pinned to a different ref is uninstalled before reinstalling" {
  fake_herdr '{"result":{"plugins":[{"plugin_id":"devcontainer","source":{"kind":"github","requested_ref":"v0.0.9"}}]}}'

  run_install_plugin

  [ "$status" -eq 0 ]
  run cat "$TEST_ROOT/plugin-calls"
  [[ "$output" == *"plugin uninstall devcontainer"* ]]
  [[ "$output" == *"plugin install gambtho/herdr-devcontainer --ref v0.1.0 --yes"* ]]
}

@test "a failed plugin install warns without failing the phase" {
  # Plugin registration goes through the running server's socket API, so a first
  # bootstrap cannot register anything -- and must not take down bin/install.
  fake_herdr '{"result":{"plugins":[]}}'

  source_installer PATH="$TEST_ROOT/bin:$PATH" FAKE_HERDR_STATUS=1 bash -c '
    source "$1/tools/herdr/install.sh"
    install_plugin
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"rerun after Herdr has started once"* ]]
}

@test "a missing herdr binary skips the plugin instead of failing" {
  run_install_plugin

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the devcontainer plugin"* ]]
}
