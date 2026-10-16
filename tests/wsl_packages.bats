#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  [ -f "$REPO_ROOT/libexec/lib/wsl-packages.sh" ]
  export EVENTS="$TEST_ROOT/events" MASK_STATE="$TEST_ROOT/masked"
  : >"$EVENTS"
  stub_command systemctl '
    case "$1" in
      show)
        if [[ "$2" == --property=Version ]]; then
          [[ ${NO_SYSTEMD:-0} == 0 ]] || exit 1
          printf "255\n"; exit
        fi
        [[ ${QUERY_FAIL:-0} == 0 ]] || exit 1
        state=${SSH_STATE:-fresh}
        [[ ! -f "$MASK_STATE" ]] || state=masked
        case "$state" in
          fresh) load=not-found; unit=; fragment= ;;
          masked) load=masked; unit=masked; fragment=/etc/systemd/system/$2 ;;
          stock) load=loaded; unit=disabled; fragment=/usr/lib/systemd/system/$2 ;;
          *) load=loaded; unit=enabled; fragment=/etc/systemd/system/ssh.service ;;
        esac
        printf "LoadState=%s\nUnitFileState=%s\nFragmentPath=%s\nActiveState=%s\nDropInPaths=%s\n" "$load" "$unit" "$fragment" "${SSH_ACTIVE:-inactive}" "${SSH_DROPINS:-}" ;;
      mask)
        [[ "$*" == "mask ssh.service ssh.socket" ]] || exit 98
        [[ ${MASK_FAIL:-0} == 0 ]] || exit 1
        touch "$MASK_STATE" ;;
      *) exit 97 ;;
    esac'
  stub_command ss '[[ ${SS_FAIL:-0} == 0 ]] || exit 1
    if [[ ${SSH22:-0} == 1 ]]; then printf "LISTEN 0 128 [::]:22 [::]:*\n"; fi'
  stub_command dpkg-query 'case "${SSH_PACKAGE:-absent}" in
    absent) exit 1 ;;
    broken) exit 2 ;;
    *) printf "install ok installed\n" ;;
  esac'
  stub_command sudo 'printf "%s\n" "$*" >>"$EVENTS"; "$@"'
  stub_command mise 'exit 0'
  stub_command curl 'exit 90'
  stub_command apt 'printf "APT %s\n" "$*" >>"$EVENTS"'
  stub_command apt-get 'printf "APT %s\n" "$*" >>"$EVENTS"'
}

run_guard() {
  run bash -c '
    source "$1/libexec/lib/wsl-packages.sh"
    OS="$2"
    wsl_ssh_configuration_exists() { [[ ${SSH_CONFIGURED:-0} == 1 ]]; }
    ensure_wsl_ssh_closed
  ' _ "$REPO_ROOT" "${1:-WSL}"
}

@test "fresh WSL masks service and socket and rechecks before returning" {
  run_guard
  [ "$status" -eq 0 ]
  [ "$(<"$EVENTS")" = 'systemctl mask ssh.service ssh.socket' ]
  [ -f "$MASK_STATE" ]
}

@test "remembered but not installed OpenSSH is fresh when units config and listeners are absent" {
  export DPKG_FIXTURE="$TEST_ROOT/dpkg"
  mkdir -p "$DPKG_FIXTURE"
  stub_command dpkg-query 'exec /usr/bin/dpkg-query --admindir="$DPKG_FIXTURE" "$@"'
  local wanted
  # dpkg may normalize deinstall/purge plus not-installed back to unknown.
  for wanted in unknown install hold; do
    printf 'Package: openssh-server\nStatus: %s ok not-installed\nArchitecture: amd64\n\n' "$wanted" >"$DPKG_FIXTURE/status"
    run /usr/bin/dpkg-query --admindir="$DPKG_FIXTURE" -W '-f=${Status}' openssh-server
    [ "$status" -eq 0 ]
    [ "$output" = "$wanted ok not-installed" ]
    run_guard
    [ "$status" -eq 0 ]
    [ "$(<"$EVENTS")" = 'systemctl mask ssh.service ssh.socket' ]
    rm "$MASK_STATE"
    : >"$EVENTS"
  done
}

@test "dpkg residual config installed and repair required states still refuse before masking" {
  export DPKG_FIXTURE="$TEST_ROOT/dpkg"
  mkdir -p "$DPKG_FIXTURE"
  stub_command dpkg-query 'exec /usr/bin/dpkg-query --admindir="$DPKG_FIXTURE" "$@"'
  local package_status
  for package_status in 'deinstall ok config-files' 'install ok installed' 'unknown reinstreq not-installed'; do
    printf 'Package: openssh-server\nStatus: %s\nArchitecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: Test fixture\n\n' "$package_status" >"$DPKG_FIXTURE/status"
    run /usr/bin/dpkg-query --admindir="$DPKG_FIXTURE" -W '-f=${Status}' openssh-server
    [ "$status" -eq 0 ]
    [ "$output" = "$package_status" ]
    run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"Existing or unknown OpenSSH deployment"* ]]
    [ ! -s "$EVENTS" ]
  done
}

@test "not installed OpenSSH with leftover configuration still refuses before masking" {
  export SSH_CONFIGURED=1
  stub_command dpkg-query 'printf "unknown ok not-installed"'
  run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"Existing or unknown OpenSSH deployment"* ]]
  [ ! -s "$EVENTS" ]
}

@test "already onboarded WSL with masked stock SSH needs no changes" {
  export SSH_STATE=masked SSH_PACKAGE=installed
  run_guard
  [ "$status" -eq 0 ]
  [ ! -s "$EVENTS" ]
}

@test "existing active customized and unknown SSH state refuses without changes" {
  local failure
  for failure in SSH_ACTIVE=active SSH_STATE=custom SSH_DROPINS=custom.conf SSH22=1 QUERY_FAIL=1 SS_FAIL=1 SSH_PACKAGE=installed SSH_PACKAGE=broken SSH_CONFIGURED=1 NO_SYSTEMD=1; do
    run bash -c '
      export "$2"
      source "$1/libexec/lib/wsl-packages.sh"
      OS=WSL
      wsl_ssh_configuration_exists() { [[ ${SSH_CONFIGURED:-0} == 1 ]]; }
      ensure_wsl_ssh_closed
    ' _ "$REPO_ROOT" "$failure"
    [ "$status" -ne 0 ]
    [ ! -s "$EVENTS" ]
  done
}

@test "inactive unmasked SSH refusal gives conditional operator guidance without policy changes" {
  export SSH_STATE=stock SSH_PACKAGE=installed
  run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"both inactive and masked"* ]]
  [[ "$output" == *"already inactive and unneeded"* ]]
  [[ "$output" == *"sudo systemctl mask ssh.service ssh.socket"* ]]
  [ ! -s "$EVENTS" ]
}

@test "mask failure is returned and never unmasked or stopped" {
  export MASK_FAIL=1
  run_guard
  [ "$status" -ne 0 ]
  [ "$(<"$EVENTS")" = 'systemctl mask ssh.service ssh.socket' ]
}

@test "non WSL package flow does not inspect or mutate SSH" {
  export NO_SYSTEMD=1
  run_guard Ubuntu
  [ "$status" -eq 0 ]
  [ ! -s "$EVENTS" ]
}

@test "both bootstrap and normal WSL package entrypoints gate before APT" {
  local entry
  for entry in bootstrap install; do
    run bash -c '
      export BOOTSTRAP_SOURCE_ONLY=1 INSTALL_SOURCE_ONLY=1
      if [[ "$2" == bootstrap ]]; then source "$1/libexec/bootstrap"; else source "$1/bin/dot-install"; fi
      OS=WSL PROFILE=personal
      ensure_wsl_ssh_closed() { printf "guard\n" >>"$EVENTS"; return 42; }
      if [[ "$2" == bootstrap ]]; then linux_prep; else install_apt_packages; fi
    ' _ "$REPO_ROOT" "$entry"
    [ "$status" -eq 42 ]
    [ "$(<"$EVENTS")" = guard ]
    : >"$EVENTS"
  done
}
