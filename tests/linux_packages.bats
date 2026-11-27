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
    ensure_wsl_ssh_closed() { return 0; }
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
  [ "$(grep -n 'dotfiles-asciinema$' "$events" | cut -d: -f1)" -lt "$(grep -n '^apt update ' "$events" | cut -d: -f1)" ]
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
  ! grep -q '^apt update' "$events"
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
  grep -Fq 'apt install -o DPkg::Lock::Timeout=600 -y ca-certificates docker-ce' "$events"
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

# A fresh Ubuntu 24.04 offers gh 2.45 from its archive; with Ubuntu Pro, the
# esm-apps repository offers a rebuild of it at priority 510.
setup_gh_apt_fixture() {
  command -v apt-cache >/dev/null || skip "APT policy fixtures require apt-cache"
  export APT_FIXTURE="$TEST_ROOT/apt"
  mkdir -p "$APT_FIXTURE/lists" "$APT_FIXTURE/empty" "$APT_FIXTURE/preferences.d"
  : >"$APT_FIXTURE/status"
  printf '%s\n' \
    'deb [trusted=yes] http://archive.ubuntu.com/ubuntu noble universe' \
    'deb [trusted=yes] https://cli.github.com/packages stable main' >"$APT_FIXTURE/sources.list"
  gh_apt_fixture_source archive.ubuntu.com_ubuntu_dists_noble Ubuntu universe 2.45.0-1ubuntu0.3
  gh_apt_fixture_source cli.github.com_packages_dists_stable GitHub main 2.83.1
}

gh_apt_fixture_with_esm() {
  printf '%s\n' 'deb [trusted=yes] https://esm.ubuntu.com/apps/ubuntu noble-apps-security main' >>"$APT_FIXTURE/sources.list"
  gh_apt_fixture_source esm.ubuntu.com_apps_ubuntu_dists_noble-apps-security UbuntuESMApps main 2.45.0-1ubuntu0.3+esm1
  # The rule Ubuntu Pro installs as /etc/apt/preferences.d/ubuntu-pro-esm-apps.
  printf 'Package: *\nPin: release o=UbuntuESMApps\nPin-Priority: 510\n' >"$APT_FIXTURE/preferences.d/ubuntu-pro-esm-apps"
}

gh_apt_fixture_source() {
  local list="$APT_FIXTURE/lists/$1" origin="$2" component="$3" version="$4"
  printf 'Origin: %s\nComponents: %s\nArchitectures: amd64\n' "$origin" "$component" >"${list}_Release"
  printf 'Package: gh\nVersion: %s\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nFilename: pool/gh.deb\nSize: 1\nDescription: test fixture\n' \
    "$version" >"${list}_${component}_binary-amd64_Packages"
}

gh_candidate() {
  local preferences="$1"
  printf '%s\n' \
    "Dir::State::status \"$APT_FIXTURE/status\";" \
    "Dir::State::lists \"$APT_FIXTURE/lists\";" \
    "Dir::Etc::sourcelist \"$APT_FIXTURE/sources.list\";" \
    "Dir::Etc::sourceparts \"$APT_FIXTURE/empty\";" \
    "Dir::Etc::preferences \"$preferences\";" \
    "Dir::Etc::preferencesparts \"$APT_FIXTURE/preferences.d\";" \
    'Dir::Cache::pkgcache "";' \
    'Dir::Cache::srcpkgcache "";' \
    'APT::Architecture "amd64";' >"$APT_FIXTURE/config"
  LC_ALL=C apt-cache -c "$APT_FIXTURE/config" policy gh | awk '$1 == "Candidate:" { print $2 }'
}

@test "the gh pin takes GitHub's build with and without Ubuntu Pro esm-apps" {
  local pin="$REPO_ROOT/platforms/linux/apt-preferences/gh-from-github"
  setup_gh_apt_fixture

  [ "$(gh_candidate "$pin")" = 2.83.1 ]

  gh_apt_fixture_with_esm
  # Without the pin, esm-apps holds the old build despite the newer version.
  [ "$(gh_candidate /dev/null)" = 2.45.0-1ubuntu0.3+esm1 ]
  [ "$(gh_candidate "$pin")" = 2.83.1 ]

  # A machine that already has the old build upgrades to GitHub's.
  printf 'Package: gh\nStatus: install ok installed\nVersion: 2.45.0-1ubuntu0.3+esm1\nArchitecture: amd64\nMaintainer: Test <test@example.invalid>\nDescription: test fixture\n' >"$APT_FIXTURE/status"
  [ "$(gh_candidate "$pin")" = 2.83.1 ]
}

# Runs dot-install's Linux package phase with sudo writing into a fixture /etc/apt.
run_gh_package_setup() {
  local etc="$TEST_ROOT/etc/apt"
  mkdir -p "$etc/sources.list.d"
  run env INSTALL_SOURCE_ONLY=1 EVENTS="$TEST_ROOT/events" ETC="$etc" APT_CACHE_STATUS="$1" bash -c '
    source "$1/bin/dot-install"
    OS=Ubuntu
    PROFILE=server
    APT_ETC=$ETC
    curl() { printf "curl %s\n" "${@: -3:1}" >>"$EVENTS"; printf "keyring\n" >"${@: -1}"; }
    dpkg() { printf "arm64\n"; }
    sudo() {
      local to="${@: -1}"
      case "$1" in
        install) printf "install %s\n" "${to#$ETC}" >>"$EVENTS"; mkdir -p "${to%/*}"; cp "${@: -2:1}" "$to" ;;
        tee) printf "tee %s\n" "${2#$ETC}" >>"$EVENTS"; cat >"$2" ;;
        rm) printf "rm %s\n" "${to#$ETC}" >>"$EVENTS"; rm -f -- "$to" ;;
        cat) cat -- "$to" ;;
        apt-cache) printf "%s\n" "$*" >>"$EVENTS"; return "$APT_CACHE_STATUS" ;;
        *) printf "%s\n" "$*" >>"$EVENTS" ;;
      esac
    }
    install_platform_packages
  ' _ "$REPO_ROOT"
}

@test "Linux package setup publishes GitHub's gh repository and pin before APT runs" {
  local etc="$TEST_ROOT/etc/apt"
  run_gh_package_setup 0

  [ "$status" -eq 0 ]
  [ "$(sed -n 1,6p "$TEST_ROOT/events")" = "curl https://cli.github.com/packages/githubcli-archive-keyring.gpg
install /keyrings/githubcli-archive-keyring.gpg
tee /sources.list.d/github-cli.list
apt-cache policy
install /preferences.d/gh-from-github
apt update -o DPkg::Lock::Timeout=600" ]
  [ "$(<"$etc/keyrings/githubcli-archive-keyring.gpg")" = keyring ]
  [ "$(<"$etc/sources.list.d/github-cli.list")" = "deb [arch=arm64 signed-by=$etc/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" ]
  cmp "$REPO_ROOT/platforms/linux/apt-preferences/gh-from-github" "$etc/preferences.d/gh-from-github"
  grep '^apt install ' "$TEST_ROOT/events" | grep -wq gh
}

@test "a gh source APT rejects is put back as it was, and gh is still pinned" {
  local etc="$TEST_ROOT/etc/apt" old='deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main'
  mkdir -p "$etc/sources.list.d"
  printf '%s\n' "$old" >"$etc/sources.list.d/github-cli.list"
  run_gh_package_setup 100

  [ "$status" -eq 0 ]
  [[ "$output" == *"APT rejected $etc/sources.list.d/github-cli.list"* ]]
  [ "$(<"$etc/sources.list.d/github-cli.list")" = "$old" ]
  cmp "$REPO_ROOT/platforms/linux/apt-preferences/gh-from-github" "$etc/preferences.d/gh-from-github"

  rm -r "$etc" "$TEST_ROOT/events"
  run_gh_package_setup 100

  [ "$status" -eq 0 ]
  [ ! -e "$etc/sources.list.d/github-cli.list" ]
  grep -Fxq 'rm /sources.list.d/github-cli.list' "$TEST_ROOT/events"
  [ -f "$etc/preferences.d/gh-from-github" ]
}

@test "a failed or empty gh keyring download leaves the gh source alone and continues" {
  local events="$TEST_ROOT/events" etc="$TEST_ROOT/etc/apt" curl_status

  for curl_status in 22 0; do
    rm -f "$events"
    run env INSTALL_SOURCE_ONLY=1 EVENTS="$events" TMPDIR="$TEST_ROOT" CURL_STATUS="$curl_status" bash -c '
      source "$1/bin/dot-install"
      OS=Ubuntu
      PROFILE=server
      APT_ETC=$2
      curl() { : >"${@: -1}"; return "$CURL_STATUS"; }
      sudo() { printf "%s\n" "${*//$APT_ETC/}" >>"$EVENTS"; }
      install_platform_packages
    ' _ "$REPO_ROOT" "$etc"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not download GitHub's gh signing key"* ]]
    [ "$(sed -n 1p "$events")" = "install -D -m 0644 $REPO_ROOT/platforms/linux/apt-preferences/gh-from-github /preferences.d/gh-from-github" ]
    run grep -E 'keyrings|github-cli.list|apt-cache' "$events"
    [ "$status" -eq 1 ]
    grep -q '^apt install ' "$events"
    [ -z "$(find "$TEST_ROOT" -maxdepth 1 -name 'tmp.*')" ]
  done
}

@test "Kubernetes repository follows the canonical channel pin" {
  run rg -n 'core:/stable:/\$\{?KUBERNETES_CHANNEL\}?' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 0 ]
  run rg -n 'core:/stable:/v[0-9]' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}

@test "package audit summarizes unmanaged extras in a sorted detail file" {
  local audit_root="$TEST_ROOT/audit-repo"
  mkdir -p "$audit_root/tmp" "$audit_root/platforms/linux/packages"
  cp "$REPO_ROOT/platforms/linux/packages/keyring_apt" "$audit_root/platforms/linux/packages/"

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

# --- waiting for package locks ------------------------------------------------
#
# A fresh server runs unattended upgrades and its daily index refresh just
# after boot. sudo_apt waits for those instead of failing the install.

run_sudo_apt() {
  run env EVENTS="$TEST_ROOT/events" DOTFILES_APT_LOCK_TIMEOUT="${TIMEOUT:-600}" bash -c '
    source "$1/libexec/common.sh"
    sleep() { printf "sleep %s\n" "$*" >>"$EVENTS"; SECONDS=$((SECONDS + $1)); }
    '"$1"'
    shift
    sudo_apt "$@"
  ' _ "$REPO_ROOT" "${@:2}"
}

@test "APT installs wait for the dpkg lock" {
  run_sudo_apt 'sudo() { printf "%s\n" "$*" >>"$EVENTS"; }' apt-get install -y git

  [ "$status" -eq 0 ]
  [ "$(<"$TEST_ROOT/events")" = "apt-get install -o DPkg::Lock::Timeout=600 -y git" ]
}

@test "an install retries while another process holds the download cache lock" {
  run_sudo_apt 'sudo() {
    printf "%s\n" "$*" >>"$EVENTS"
    if (($(grep -c "^apt-get " "$EVENTS") < 2)); then
      printf "E: Could not get lock /var/cache/apt/archives/lock. It is held by process 1 (apt-get)\n" >&2
      return 100
    fi
  }' apt-get install -y git

  [ "$status" -eq 0 ]
  [ "$(grep -c '^apt-get install ' "$TEST_ROOT/events")" -eq 2 ]
}

@test "an index refresh retries while another process holds the index lock" {
  run_sudo_apt 'sudo() {
    printf "%s\n" "$*" >>"$EVENTS"
    if (($(grep -c "^apt " "$EVENTS") < 3)); then
      printf "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (apt-get)\n" >&2
      return 100
    fi
  }' apt update

  [ "$status" -eq 0 ]
  [ "$(grep -c '^apt update ' "$TEST_ROOT/events")" -eq 3 ]
  [ "$(grep -c '^sleep ' "$TEST_ROOT/events")" -eq 2 ]
  [[ "$output" != *"Could not get lock"* ]]
}

@test "an index refresh that fails for another reason is not retried" {
  run_sudo_apt 'sudo() {
    printf "%s\n" "$*" >>"$EVENTS"
    printf "E: Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)\n" >&2
    printf "E: Failed to fetch http://archive.invalid/dists/InRelease\n" >&2
    return 100
  }' apt-get update

  [ "$status" -eq 100 ]
  [ "$(wc -l <"$TEST_ROOT/events")" -eq 1 ]
  [[ "$output" == *"Failed to fetch"* ]]
}

@test "an index refresh stops waiting at the lock timeout" {
  TIMEOUT=7 run_sudo_apt 'sudo() {
    printf "%s\n" "$*" >>"$EVENTS"
    printf "E: Could not get lock /var/lib/apt/lists/lock.\n" >&2
    return 100
  }' apt-get update

  [ "$status" -eq 100 ]
  # Seven seconds allow one five-second wait, then no further attempt.
  [ "$(grep -c '^apt-get update -o DPkg::Lock::Timeout=7$' "$TEST_ROOT/events")" -eq 2 ]
  [ "$(grep -c '^sleep 5$' "$TEST_ROOT/events")" -eq 1 ]
  [[ "$output" == *"Could not get lock"* ]]
}

@test "no installer calls APT without the lock wait" {
  run rg -n 'sudo +apt(-get)? ' "$REPO_ROOT/bin" "$REPO_ROOT/libexec" "$REPO_ROOT/core" \
    "$REPO_ROOT/languages" "$REPO_ROOT/work" "$REPO_ROOT/tools" "$REPO_ROOT/ai" \
    --glob '*.sh' --glob 'bin/*' --glob 'libexec/*' --glob '!lib/apt.sh'
  [ "$status" -eq 1 ]
}

# --- the en_US.UTF-8 locale ---------------------------------------------------
#
# Fresh WSL and minimal Ubuntu generate only C.UTF-8. With LANG=en_US.UTF-8 from
# the terminal, every perl apt starts warns "Setting locale failed".

run_locale() {
  run env EVENTS="$TEST_ROOT/events" LOCALES="$1" LOCALE_GEN="$2" bash -c '
    source "$1/libexec/common.sh"
    locale() { [[ "$*" == -a ]] && printf "%b" "$LOCALES"; }
    sudo() { printf "%s\n" "$*" >>"$EVENTS"; }
    ensure_en_us_locale
  ' _ "$REPO_ROOT"
}

@test "a generated en_US.UTF-8 locale is left alone" {
  local generator="$TEST_ROOT/locale-gen"
  printf '#!/bin/sh\n' >"$generator"
  chmod +x "$generator"

  run_locale 'C\nC.utf8\nen_US.utf8\nPOSIX\n' "$generator"

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/events" ]
}

@test "a missing en_US.UTF-8 locale is generated, installing locales only when needed" {
  local generator="$TEST_ROOT/locale-gen"
  printf '#!/bin/sh\n' >"$generator"
  chmod +x "$generator"

  run_locale 'C\nC.utf8\nPOSIX\n' "$generator"
  [ "$status" -eq 0 ]
  [ "$(<"$TEST_ROOT/events")" = "$generator en_US.UTF-8" ]

  rm "$generator" "$TEST_ROOT/events"
  run_locale 'C\nC.utf8\nPOSIX\n' "$generator"
  [ "$status" -eq 0 ]
  [ "$(<"$TEST_ROOT/events")" = "apt-get update -o DPkg::Lock::Timeout=600
apt-get install -o DPkg::Lock::Timeout=600 -y locales
$generator en_US.UTF-8" ]
}

@test "bootstrap and the normal install generate the locale before APT, and go on if it fails" {
  local entry
  for entry in bootstrap install; do
    run env EVENTS="$TEST_ROOT/events" bash -c '
      export BOOTSTRAP_SOURCE_ONLY=1 INSTALL_SOURCE_ONLY=1
      if [[ "$2" == bootstrap ]]; then source "$1/libexec/bootstrap"; else source "$1/bin/dot-install"; fi
      OS=Ubuntu PROFILE=personal
      ensure_en_us_locale() { printf "locale\n" >>"$EVENTS"; return 1; }
      sudo_apt() { printf "%s\n" "$*" >>"$EVENTS"; return 42; }
      setup_package_repositories() { :; }
      if [[ "$2" == bootstrap ]]; then linux_prep; else install_apt_packages; fi
    ' _ "$REPO_ROOT" "$entry"
    [ "$status" -eq 42 ]
    [ "$(head -1 "$TEST_ROOT/events")" = locale ]
    [ "$(sed -n 2p "$TEST_ROOT/events")" = "apt update" ]
    [[ "$output" == *"Could not generate the en_US.UTF-8 locale"* ]]
    rm "$TEST_ROOT/events"
  done
}
