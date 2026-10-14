#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

compose_packages() {
  local os="$1" profile="$2"
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/dot-install"
    OS="$2"
    PROFILE="$3"
    compose_apt_packages
  ' _ "$REPO_ROOT" "$os" "$profile"
}

setup_asciinema_apt_fixture() {
  command -v apt-cache >/dev/null || skip "APT policy fixtures require apt-cache"
  export APT_FIXTURE="$TEST_ROOT/apt"
  mkdir -p "$APT_FIXTURE/lists" "$APT_FIXTURE/empty"
  : >"$APT_FIXTURE/status"
  printf '%s\n' 'deb [trusted=yes] https://example.invalid stable main' >"$APT_FIXTURE/sources.list"
  local version
  for version in "$@"; do
    printf 'Package: asciinema\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nFilename: pool/asciinema.deb\nSize: 1\nDescription: test fixture\n\n' "$version"
  done >"$APT_FIXTURE/lists/example.invalid_dists_stable_main_binary-amd64_Packages"
  printf '%s\n' \
    "Dir::State::status \"$APT_FIXTURE/status\";" \
    "Dir::State::lists \"$APT_FIXTURE/lists\";" \
    "Dir::Etc::sourcelist \"$APT_FIXTURE/sources.list\";" \
    "Dir::Etc::sourceparts \"$APT_FIXTURE/empty\";" \
    "Dir::Etc::preferences \"$REPO_ROOT/work/apt-preferences/asciinema\";" \
    "Dir::Etc::preferencesparts \"$APT_FIXTURE/empty\";" \
    'Dir::Cache::pkgcache "";' \
    'Dir::Cache::srcpkgcache "";' \
    'APT::Architecture "amd64";' >"$APT_FIXTURE/config"
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

@test "every Linux profile includes Pi validation dependencies without retired sandbox packages" {
  local os profile
  for os in Ubuntu WSL; do
    for profile in personal work server; do
      compose_packages "$os" "$profile"
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" | grep -Fxq ripgrep
      printf '%s\n' "$output" | grep -Fxq python3-jsonschema
      ! printf '%s\n' "$output" | grep -Eq '^(bubblewrap|socat)$'
    done
  done
}

@test "mise-managed Python installs the Pi schema validator module" {
  run grep -Fx jsonschema "$REPO_ROOT/languages/python/default-python-packages.symlink"

  [ "$status" -eq 0 ]
}

@test "work package composition includes vendor tooling once" {
  compose_packages Ubuntu work

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\ndocker-ce\n'* ]]
  [[ "$output" == *$'\nkubectl\n'* ]]
  [[ "$output" == *$'\nazure-cli\n'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^docker-ce$')" -eq 1 ]
}

@test "work package composition provisions recording and Rust tools on Ubuntu and WSL" {
  local os package
  for os in Ubuntu WSL; do
    compose_packages "$os" work
    [ "$status" -eq 0 ]
    for package in asciinema ffmpeg rustup; do
      printf '%s\n' "$output" | grep -Fxq "$package"
    done
  done
}

@test "asciinema policy prefers the newest 2.4.0 distro revision over other upstream releases" {
  setup_asciinema_apt_fixture 2.4.0-1 2.4.0-9 2.4.0-rc1-1 2.4.1-1 3.0.0-1

  run env LC_ALL=C apt-cache -c "$APT_FIXTURE/config" policy asciinema

  [ "$status" -eq 0 ]
  [[ "$output" == *"Candidate: 2.4.0-9"* ]]
}

@test "asciinema policy rejects repositories with no 2.4.0 release" {
  setup_asciinema_apt_fixture 2.4.0-rc1-1 2.4.1-1 3.0.0-1

  run env LC_ALL=C apt-cache -c "$APT_FIXTURE/config" policy asciinema

  [ "$status" -eq 0 ]
  [[ "$output" == *"Candidate: (none)"* ]]
}

@test "work install rejects a 2.4.0-looking upstream prerelease" {
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/dot-install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { return 0; }
    apt-cache() { printf "  Candidate: 2.4.0-rc1-1\n"; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"asciinema 2.4.0"* ]]
  [[ "$output" == *"2.4.0-rc1-1"* ]]
  ! grep -q '^apt install ' "$events"
}

@test "work install refuses to downgrade an existing newer asciinema" {
  setup_asciinema_apt_fixture 2.4.0-9 3.0.0-1
  printf 'Package: asciinema\nStatus: install ok installed\nVersion: 3.0.0-1\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: test fixture\n' >"$APT_FIXTURE/status"
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/dot-install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { return 0; }
    apt-cache() { /usr/bin/apt-cache -c "$APT_FIXTURE/config" "$@"; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"asciinema 2.4.0"* ]]
  [[ "$output" == *"(none)"* ]]
  ! grep -q '^apt install ' "$events"
  ! grep -q '^apt upgrade ' "$events"
}

@test "work install fails clearly when the pinned asciinema release is unavailable" {
  setup_asciinema_apt_fixture 3.0.0-1
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/dot-install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=WSL
    PROFILE=work
    setup_package_repositories() { return 0; }
    apt-cache() { /usr/bin/apt-cache -c "$APT_FIXTURE/config" "$@"; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"asciinema 2.4.0"* ]]
  [[ "$output" == *"(none)"* ]]
  ! grep -q '^apt install ' "$events"
}

@test "work repositories publish the asciinema preference before APT runs" {
  local events="$TEST_ROOT/events" published="$TEST_ROOT/published-pin"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" PUBLISHED_PIN="$published" bash -c '
    source "$1/bin/dot-install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { setup_work_apt_repositories; }
    setup_docker_repository() { return 0; }
    setup_kubernetes_repository() { return 0; }
    setup_microsoft_repositories() { return 0; }
    sudo() {
      printf "%s\n" "$*" >>"$EVENTS"
      if [[ "$1" == install && "${@: -1}" == /etc/apt/preferences.d/dotfiles-asciinema ]]; then
        /usr/bin/install -m 0644 "$4" "$PUBLISHED_PIN"
      fi
    }
    apt-cache() { printf "  Candidate: 2.4.0-1.1\n"; }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  cmp "$REPO_ROOT/work/apt-preferences/asciinema" "$published"
  [ "$(grep -n 'dotfiles-asciinema$' "$events" | cut -d: -f1)" -lt "$(grep -n '^apt update$' "$events" | cut -d: -f1)" ]
  [ "$(grep -c '^apt install ' "$events")" -eq 1 ]
  grep '^apt install ' "$events" | grep -wq asciinema
  grep '^apt install ' "$events" | grep -wq ffmpeg
  grep '^apt install ' "$events" | grep -wq rustup
}

@test "asciinema preference publication failure prevents package updates" {
  local events="$TEST_ROOT/events"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/dot-install"
    WORK_INSTALL_SOURCE_ONLY=1 source "$1/work/install.sh"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { setup_work_apt_repositories; }
    setup_docker_repository() { return 0; }
    setup_kubernetes_repository() { return 0; }
    setup_microsoft_repositories() { return 0; }
    sudo() {
      printf "%s\n" "$*" >>"$EVENTS"
      if [[ "${@: -1}" == /etc/apt/preferences.d/dotfiles-asciinema ]]; then
        return 42
      fi
    }
    install_platform_packages
  ' _ "$REPO_ROOT"

  [ "$status" -eq 42 ]
  ! grep -q '^apt update$' "$events"
  ! grep -q '^apt install ' "$events"
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
  ! printf '%s\n' "$output" | grep -Eq '^(asciinema|ffmpeg|rustup)$'
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
    source "$1/bin/dot-install"
    OS=Ubuntu
    PROFILE=work
    setup_package_repositories() { printf "repositories\n" >>"$EVENTS"; }
    verify_asciinema_apt_candidate() { return 0; }
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
    source "$1/bin/dot-install"
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
    source "$1/bin/dot-install"
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
    source "$1/bin/dot-install"
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

@test "package audit stops when manifest composition fails" {
  local audit_root="$TEST_ROOT/audit-repo"
  local events="$TEST_ROOT/audit-events"
  mkdir -p "$audit_root/tmp"

  run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" bash -c '
    source "$1/bin/dot-install"
    DOTFILES_ROOT="$2"
    OS=Ubuntu
    PROFILE=missing
    compose_apt_packages() { return 42; }
    apt-mark() { printf "apt-mark called\n" >>"$EVENTS"; }
    if check_unsaved_apt_packages; then
      exit 0
    else
      exit $?
    fi
  ' _ "$REPO_ROOT" "$audit_root"

  [ "$status" -ne 0 ]
  [ ! -e "$audit_root/tmp/unmanaged-apt-ubuntu-missing.txt" ]
  [ ! -s "$events" ]
  run bash -c 'compgen -G "$1/tmp/managed-apt.*"' _ "$audit_root"
  [ "$status" -eq 1 ]
}
