#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "all Linux profiles account for the separate keyring dependency set" {
  local os profile
  for os in Ubuntu WSL; do
    for profile in personal work server; do
      run bash -c '
        INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
        OS="$2" PROFILE="$3"
        compose_managed_apt_packages
      ' _ "$REPO_ROOT" "$os" "$profile"
      [ "$status" -eq 0 ]
      [ "$output" = "$(printf '%s\n' "$output" | sort -u)" ]
      for package in dbus-user-session gir1.2-glib-2.0 gnome-keyring python3-gi; do
        printf '%s\n' "$output" | grep -Fxq "$package"
      done
      ! printf '%s\n' "$output" | grep -Eq '^(libpam-gnome-keyring|seahorse)$'
    done
  done
}

@test "keyring dependencies use a separate no-recommends APT call" {
  local events="$TEST_ROOT/events"
  run bash -c '
    INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
    OS=Ubuntu PROFILE=personal
    setup_package_repositories() { return 0; }
    compose_apt_packages() { printf "%s\n" curl git; }
    EVENTS="$2"
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT" "$events"
  [ "$status" -eq 0 ]
  grep -Fxq 'apt install -y curl git' "$events"
  grep -Fxq 'apt-get install -y --no-install-recommends dbus-user-session gir1.2-glib-2.0 gnome-keyring python3-gi' "$events"
  [ "$(grep -c '^apt install ' "$events")" -eq 1 ]
  [ "$(grep -c '^apt-get install ' "$events")" -eq 1 ]
  [ "$(grep -n '^apt-get install ' "$events" | cut -d: -f1)" -lt "$(grep -n '^apt upgrade ' "$events" | cut -d: -f1)" ]
}

@test "scoped keyring dependency failure prevents upgrade and cleanup" {
  local events="$TEST_ROOT/events"
  run bash -c '
    INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
    OS=Ubuntu PROFILE=personal
    setup_package_repositories() { return 0; }
    compose_apt_packages() { printf "%s\n" curl; }
    EVENTS="$2"
    sudo() {
      printf "%s\n" "$*" >>"$EVENTS"
      [[ "$1" != apt-get ]] || return 42
    }
    install_platform_packages
  ' _ "$REPO_ROOT" "$events"
  [ "$status" -eq 42 ]
  ! grep -Eq '^apt (upgrade|autoremove|autoclean)' "$events"
}

@test "managed package audit omits all scoped keyring dependencies" {
  local root="$TEST_ROOT/audit-repo"
  mkdir -p "$root/platforms/linux/packages"
  cp "$REPO_ROOT/platforms/linux/packages/keyring_apt" "$root/platforms/linux/packages/"
  run bash -c '
    INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
    DOTFILES_ROOT="$2" OS=Ubuntu PROFILE=server
    compose_apt_packages() { printf "%s\n" curl; }
    apt-mark() { printf "%s\n" curl dbus-user-session gir1.2-glib-2.0 gnome-keyring python3-gi extra; }
    check_unsaved_apt_packages
  ' _ "$REPO_ROOT" "$root"
  [ "$status" -eq 0 ]
  [ "$(<"$root/tmp/unmanaged-apt-ubuntu-server.txt")" = extra ]
}

@test "macOS package provisioning never runs APT keyring installation" {
  run bash -c '
    INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
    OS=macOS PROFILE=personal
    update_homebrew() { printf "native Homebrew path\n"; }
    sudo() { printf "unexpected sudo\n"; return 1; }
    install_platform_packages
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = 'native Homebrew path' ]
}
