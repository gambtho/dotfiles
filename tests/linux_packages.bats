#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

compose_packages() {
  local os="$1" profile="$2"
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/install"
    OS="$2"
    PROFILE="$3"
    compose_apt_packages
  ' _ "$REPO_ROOT" "$os" "$profile"
}

@test "every Linux platform and profile composes a sorted package set" {
  local os profile
  for os in Ubuntu WSL; do
    for profile in personal work server; do
      compose_packages "$os" "$profile"
      [ "$status" -eq 0 ]
      [ -n "$output" ]
      [ "$output" = "$(printf '%s\n' "$output" | sort -u)" ]
    done
  done
}

@test "work package composition includes vendor tooling once" {
  compose_packages Ubuntu work

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ndocker-ce\n'* ]]
  [[ "$output" == *$'\nkubectl\n'* ]]
  [[ "$output" == *$'\nazure-cli\n'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^docker-ce$')" -eq 1 ]
}

@test "server package composition stays headless" {
  compose_packages WSL server

  [ "$status" -eq 0 ]
  [[ "$output" != *"ubuntu-desktop"* ]]
  [[ "$output" != *"flatpak"* ]]
  [[ "$output" != *"fonts-"* ]]
  [[ "$output" != *"docker-ce"* ]]
  [[ "$output" != *"azure-cli"* ]]
  [[ "$output" != *"kubectl"* ]]
}

@test "every profile running the flatpak phase installs flatpak itself" {
  local os profile
  for os in Ubuntu WSL; do
    for profile in personal work; do
      compose_packages "$os" "$profile"
      [ "$status" -eq 0 ]
      [[ "$output" == *$'\nflatpak\n'* ]]
      [[ "$output" == *$'\nlibfuse2\n'* ]]
    done
  done
}

@test "manifests exclude packages with no configured APT repository" {
  # 1password, gcm, intune-portal, microsoft-edge-stable and
  # microsoft-identity-broker were present on the migrated workstation but are
  # served by repositories this repo never configures. `apt install` runs as a
  # single required call, so one unresolvable name fails the whole phase.
  run rg -n '^(1password|gcm|intune-portal|microsoft-edge-stable|microsoft-identity-broker)$' \
    "$REPO_ROOT/platforms/linux/packages" "$REPO_ROOT/profiles/packages"

  [ "$status" -eq 1 ]
}

@test "managed binary tools are absent from APT manifests" {
  run rg -n '^(mise|yq)$' "$REPO_ROOT/platforms/linux/packages" "$REPO_ROOT/profiles/packages"

  [ "$status" -eq 1 ]
}

@test "curated manifests exclude machine snapshot packages" {
  run rg -n 'linux-generic|linux-modules|nvidia|grub|shim-signed|efibootmgr|language-pack|ibus-' \
    "$REPO_ROOT/platforms/linux/packages" "$REPO_ROOT/profiles/packages"

  [ "$status" -eq 1 ]
}

@test "work repositories are configured before one composed apt install" {
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/install"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { printf "repositories\n" >>"$EVENTS"; }
    compose_apt_packages() { printf "%s\n" ca-certificates docker-ce; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$events")" = repositories ]
  [ "$(grep -c '^apt install ' "$events")" -eq 1 ]
  grep -Fq 'apt install -y ca-certificates docker-ce' "$events"
}

@test "package composition failure prevents apt installation" {
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/install"
    OS=Ubuntu
    PROFILE=missing
    setup_package_repositories() { printf "repositories\n" >>"$EVENTS"; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  ! grep -q '^apt install ' "$events"
}

@test "repository setup failure prevents later repositories and apt installation" {
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=Ubuntu
    PROFILE=work
    download_apt_key() { printf "key:%s\n" "$1" >>"$EVENTS"; return 1; }
    setup_package_repositories() { setup_work_apt_repositories; }
    sudo() { printf "sudo:%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(grep -c '^key:' "$events")" -eq 1 ]
  ! grep -q 'apt install' "$events"
}

@test "APT key download failure is never masked by cleanup" {
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    curl() { return 1; }
    sudo() { return 0; }
    if download_apt_key https://example.test/key "$2/key.gpg"; then
      exit 0
    else
      exit $?
    fi
  ' _ "$REPO_ROOT" "$TEST_ROOT"

  [ "$status" -ne 0 ]
}

@test "Kubernetes repository follows the canonical channel pin" {
  run rg -n 'core:/stable:/\$\{?KUBERNETES_CHANNEL\}?' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 0 ]
  run rg -n 'core:/stable:/v[0-9]' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}

@test "package audit summarizes unmanaged extras in a sorted detail file" {
  local audit_root="$TEST_ROOT/audit-repo"
  mkdir -p "$audit_root/tmp"

  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/install"
    DOTFILES_ROOT="$2"
    OS=Ubuntu
    PROFILE=personal
    compose_apt_packages() { printf "%s\n" curl git; }
    apt-mark() { printf "%s\n" zoxide git curl another-extra; }
    check_unsaved_apt_packages
  ' _ "$REPO_ROOT" "$audit_root"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Unmanaged manual APT packages: 2"* ]]
  [ "$(cat "$audit_root/tmp/unmanaged-apt-ubuntu-personal.txt")" = $'another-extra\nzoxide' ]
}
