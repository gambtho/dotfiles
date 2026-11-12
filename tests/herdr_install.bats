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
  [[ "$output" == "v0.9.5" ]]
}

@test "the reviewed pin selects the verified Linux asset and checksum for each architecture" {
  local arch digest
  while read -r arch digest; do
    source_installer HERDR_EXPECTED_URL="https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-linux-$arch" \
      HERDR_EXPECTED_SHA256="$digest" bash -c '
      source "$1/tools/herdr/install.sh"
      download_verified_artifact() {
        [[ "$1" == "$HERDR_EXPECTED_URL" && "$2" == "$HERDR_EXPECTED_SHA256" && "$4" == 0755 ]] || {
          printf "Unexpected Herdr artifact request: %s %s %s\n" "$1" "$2" "$4" >&2
          return 1
        }
        printf "verified-asset\n" >"$3"
        chmod "$4" "$3"
      }
      install_pinned_binary "$2"
    ' _ "$REPO_ROOT" "$arch"

    [ "$status" -eq 0 ]
    [ -x "$TEST_ROOT/bin/herdr" ]
    [ "$(<"$TEST_ROOT/bin/herdr")" = verified-asset ]
    [ "$(<"$TEST_ROOT/state/installed-version")" = v0.9.5 ]
    rm "$TEST_ROOT/bin/herdr" "$TEST_ROOT/state/installed-version"
  done <<'ASSETS'
x86_64 14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
aarch64 17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c
ASSETS
}

@test "a previous 0.8.0 marker does not skip the reviewed upgrade" {
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
  printf 'old-herdr\n' >"$TEST_ROOT/bin/herdr"
  chmod +x "$TEST_ROOT/bin/herdr"
  printf 'v0.8.0\n' >"$TEST_ROOT/state/installed-version"

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    download_verified_artifact() { printf "replacement-herdr\n" >"$3"; chmod "$4" "$3"; }
    install_pinned_binary x86_64
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$(<"$TEST_ROOT/bin/herdr")" = replacement-herdr ]
  [ "$(<"$TEST_ROOT/state/installed-version")" = v0.9.5 ]
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

  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    printf "%s\n" "$HERDR_VERSION" >"$HERDR_STATE_ROOT/installed-version"
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

@test "new installs render lane attention defaults" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_config
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run python3 - "$TEST_ROOT/config/herdr/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as source:
    config = tomllib.load(source)
ui = config["ui"]
assert ui["prompt_new_workspace_name"] is False
assert ui["agent_panel_sort"] == "priority"
assert ui["hide_tab_bar_when_single_tab"] is True
assert ui["toast"]["delivery"] == "herdr"
assert config["onboarding"] is False
assert ui["sidebar"]["agents"]["rows"] == [["state_icon"]]
spaces = ui["sidebar"]["spaces"]["rows"][0]
assert spaces[:2] == ["state_icon", "workspace"]
assert spaces[2]["token"] == "$needs"
assert spaces[2]["rules"] == [{"equals": "0", "hide": True}]
PY
  [ "$status" -eq 0 ]
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
  [[ "$output" == *"v0.9.5"* ]]
  [[ "$output" != *"plugin:"* ]]
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

@test "fresh config has no retired plugin actions" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_config
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  run python3 - "$TEST_ROOT/config/herdr/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as source:
    config = tomllib.load(source)
assert not any(command.get("command", "").startswith("devcontainer.")
               for command in config.get("keys", {}).get("command", []))
PY
  [ "$status" -eq 0 ]
}

@test "explicit config refresh backs up exact bytes without installing binary" {
  mkdir -p "$TEST_ROOT/config/herdr"
  printf '[theme]\nname = "kanagawa"\n' >"$TEST_ROOT/config/herdr/config.toml"
  cp "$TEST_ROOT/config/herdr/config.toml" "$TEST_ROOT/original"
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    install_pinned_binary() { return 99; }
    main --refresh-config
    main --refresh-config
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  cmp "$REPO_ROOT/tools/herdr/config.toml.template" "$TEST_ROOT/config/herdr/config.toml"
  local -a backups=("$TEST_ROOT"/config/herdr/config.toml.backup.*)
  [ "${#backups[@]}" -eq 1 ]
  cmp "$TEST_ROOT/original" "${backups[0]}"
  [ "$(stat -c %a "${backups[0]}")" = 600 ]
  [ ! -e "$TEST_ROOT/bin/herdr" ]
}

@test "refresh publication failure preserves original config and backup" {
  mkdir -p "$TEST_ROOT/config/herdr"
  printf 'original\n' >"$TEST_ROOT/config/herdr/config.toml"
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    publish_file() { return 77; }
    main --refresh-config
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [ "$(<"$TEST_ROOT/config/herdr/config.toml")" = original ]
  local -a backups=("$TEST_ROOT"/config/herdr/config.toml.backup.*)
  [ "$(<"${backups[0]}")" = original ]
}

@test "refresh backup failure leaves existing config untouched" {
  mkdir -p "$TEST_ROOT/config/herdr"
  printf 'original\n' >"$TEST_ROOT/config/herdr/config.toml"
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    mktemp() { case "$*" in *backup*) return 70;; *) command mktemp "$@";; esac; }
    main --refresh-config
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [ "$(<"$TEST_ROOT/config/herdr/config.toml")" = original ]
}

@test "explicit refresh accepts a reviewed machine-local source" {
  printf 'onboarding = false\n' >"$TEST_ROOT/reviewed.toml"
  source_installer HERDR_CONFIG_TEMPLATE="$TEST_ROOT/reviewed.toml" bash -c '
    source "$1/tools/herdr/install.sh"
    main --refresh-config
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/reviewed.toml" "$TEST_ROOT/config/herdr/config.toml"
}

@test "unknown and combined modes refuse before writing" {
  for args in '--typo' '--check --refresh-config'; do
    source_installer bash -c 'source "$1/tools/herdr/install.sh"; shift; main "$@"' _ "$REPO_ROOT" $args
    [ "$status" -eq 2 ]
    [ ! -e "$TEST_ROOT/config/herdr/config.toml" ]
  done
}

@test "dashboard installs a stable copy and can be registered again" {
  mkdir -p "$TEST_ROOT/bin"
  cat >"$TEST_ROOT/bin/herdr" <<'SH'
#!/bin/sh
[ "$1 $2" = 'plugin link' ] || exit 80
[ -x "$3/dashboard.py" ] && [ -f "$3/herdr-plugin.toml" ] || exit 81
printf '%s\n' "$3" >>"$HOME/dashboard-links"
SH
  chmod +x "$TEST_ROOT/bin/herdr"
  source_installer XDG_DATA_HOME="$TEST_ROOT/data with spaces" bash -c '
    source "$1/tools/herdr/install.sh"
    main --install-dashboard
    main --install-dashboard
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  local destination="$TEST_ROOT/data with spaces/dotfiles/herdr-dashboard"
  [ -L "$destination" ]
  cmp "$REPO_ROOT/tools/herdr/dashboard/dashboard.py" "$destination/dashboard.py"
  [[ "$(readlink "$destination")" != *".dotfiles-worktrees"* ]]
  [ "$(find "$TEST_ROOT/data with spaces/dotfiles" -maxdepth 1 -type d -name '.herdr-dashboard-*' | wc -l)" -eq 1 ]
}

@test "dashboard content update switches the copy while retaining the old version" {
  mkdir -p "$TEST_ROOT/source/tools/herdr/dashboard" "$TEST_ROOT/bin"
  cp "$REPO_ROOT"/tools/herdr/dashboard/{dashboard.py,herdr-plugin.toml} "$TEST_ROOT/source/tools/herdr/dashboard/"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/herdr"
  chmod +x "$TEST_ROOT/bin/herdr"
  source_installer XDG_DATA_HOME="$TEST_ROOT/data" bash -c '
    source "$1/tools/herdr/install.sh"
    DOTFILES_ROOT="$TEST_ROOT/source"
    main --install-dashboard
    before=$(readlink "$TEST_ROOT/data/dotfiles/herdr-dashboard")
    printf "\n# refreshed\n" >>"$DOTFILES_ROOT/tools/herdr/dashboard/dashboard.py"
    main --install-dashboard
    after=$(readlink "$TEST_ROOT/data/dotfiles/herdr-dashboard")
    [[ "$before" != "$after" && -f "$before/dashboard.py" ]]
    cmp "$DOTFILES_ROOT/tools/herdr/dashboard/dashboard.py" "$after/dashboard.py"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "normal convergence never invokes Herdr plugin commands" {
  source_installer bash -c '
    source "$1/tools/herdr/install.sh"
    download_verified_artifact() {
      printf "#!/bin/sh\nprintf called >>%s\nexit 0\n" "$TEST_ROOT/plugin-calls" >"$3"
      chmod "$4" "$3"
    }
    main
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/plugin-calls" ]
}
