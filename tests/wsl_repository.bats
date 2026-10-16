#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export FIXTURE_ROOT="$TEST_ROOT/root" EVENTS="$TEST_ROOT/events"
  export VENDOR_KEY="$TEST_ROOT/vendor-key" VENDOR_LIST="$TEST_ROOT/vendor-list"
  mkdir -p "$FIXTURE_ROOT/usr/share/keyrings" "$FIXTURE_ROOT/etc/apt/sources.list.d"
  chmod 0755 "$FIXTURE_ROOT" "$FIXTURE_ROOT/usr" "$FIXTURE_ROOT/usr/share" \
    "$FIXTURE_ROOT/usr/share/keyrings" "$FIXTURE_ROOT/etc" "$FIXTURE_ROOT/etc/apt" "$FIXTURE_ROOT/etc/apt/sources.list.d"
  printf 'valid-key\n' >"$VENDOR_KEY"
  printf '# vendor\ndeb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main\n' >"$VENDOR_LIST"
  : >"$EVENTS"
  stub_command curl '
    [[ ${DOWNLOAD_FAIL:-0} == 0 ]] || exit 22
    output='' url=''
    while (($#)); do
      case "$1" in --output) output=$2; shift 2 ;; https:*) url=$1; shift ;; *) shift ;; esac
    done
    case "$url" in
      https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg) cp "$VENDOR_KEY" "$output" ;;
      https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list) cp "$VENDOR_LIST" "$output" ;;
      *) exit 93 ;;
    esac'
  stub_command gpg '
    fingerprint=2596A99EAAB33821893C0A79458CA832957F5868
    if grep -Fxq foreign-valid-key "${@: -1}"; then fingerprint=0000000000000000000000000000000000000001
    else grep -Fxq valid-key "${@: -1}" || exit 1; fi
    printf "pub:-:255:22:synthetic:0:0:::::\nfpr:::::::::%s:\n" "$fingerprint"'
  stub_command stat '
    if [[ "$1 $2" == "-c %u %a" ]]; then
      printf "0 %s\n" "$(/usr/bin/stat -c %a "$3")"
    else exec /usr/bin/stat "$@"; fi'
  stub_command sudo '
    printf "%s\n" "$*" >>"$EVENTS"
    case "$1" in
      install)
        shift; arguments=()
        while (($#)); do case "$1" in -o|-g) shift 2 ;; *) arguments+=("$1"); shift ;; esac; done
        [[ ${INSTALL_FAIL:-0} == 0 ]] || exit 1
        exec /usr/bin/install "${arguments[@]}" ;;
      mv) shift; exec /usr/bin/mv "$@" ;;
      *) exit 95 ;;
    esac'
}

run_repository() {
  run bash -c '
    source "$1/libexec/lib/wsl-packages.sh"
    OS=WSL
    wsl_package_root() { printf "%s\n" "$FIXTURE_ROOT"; }
    wsl_ubuntu_codename() { printf "%s\n" "${CODENAME:-noble}"; }
    setup_wsl_tailscale_repository
  ' _ "$REPO_ROOT"
}

@test "every WSL profile includes SSH and Tailscale without changing other platforms" {
  local profile
  for profile in personal work server; do
    run bash -c 'INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"; OS=WSL PROFILE="$2"; compose_apt_packages' _ "$REPO_ROOT" "$profile"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^openssh-server$')" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c '^tailscale$')" -eq 1 ]
    run bash -c 'INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"; OS=Ubuntu PROFILE="$2"; compose_apt_packages' _ "$REPO_ROOT" "$profile"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -Eq '^(openssh-server|tailscale)$'
  done
}

@test "official signed repository publishes validated files and reapply is no-op" {
  run_repository
  [ "$status" -eq 0 ]
  cmp "$VENDOR_KEY" "$FIXTURE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg"
  cmp "$VENDOR_LIST" "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  : >"$EVENTS"
  run_repository
  [ "$status" -eq 0 ]
  [ ! -s "$EVENTS" ]
}

@test "matching local vendor configuration is reused offline without rewriting comments" {
  run_repository
  [ "$status" -eq 0 ]
  printf '# local documentation\n' >>"$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  : >"$EVENTS"
  export DOWNLOAD_FAIL=1
  run_repository
  [ "$status" -eq 0 ]
  [ ! -s "$EVENTS" ]
  grep -q '# local documentation' "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
}

@test "foreign and duplicate sources are preserved without privileged writes" {
  printf 'foreign\n' >"$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  chmod 0644 "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  run_repository
  [ "$status" -ne 0 ]
  [ "$(<"$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list")" = foreign ]
  [ ! -s "$EVENTS" ]
  rm "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  cp "$VENDOR_LIST" "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  cp "$VENDOR_LIST" "$FIXTURE_ROOT/etc/apt/sources.list.d/other.list"
  run_repository
  [ "$status" -ne 0 ]
  [ -f "$FIXTURE_ROOT/etc/apt/sources.list.d/other.list" ]
  [ ! -s "$EVENTS" ]
}

@test "symlinked and writable repository destinations are refused" {
  local target="$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list"
  ln -s "$VENDOR_LIST" "$target"
  run_repository
  [ "$status" -ne 0 ]
  [ -L "$target" ]
  [ ! -s "$EVENTS" ]
  rm "$target"
  cp "$VENDOR_LIST" "$target"
  chmod 0666 "$target"
  run_repository
  [ "$status" -ne 0 ]
  [ ! -s "$EVENTS" ]
}

@test "downloads invalid keys and incorrect sources fail before publication" {
  export DOWNLOAD_FAIL=1
  run_repository
  [ "$status" -ne 0 ]
  unset DOWNLOAD_FAIL
  printf 'invalid\n' >"$VENDOR_KEY"
  run_repository
  [ "$status" -ne 0 ]
  printf 'valid-key\n' >"$VENDOR_KEY"
  printf 'deb [trusted=yes] https://example.invalid noble main\n' >"$VENDOR_LIST"
  run_repository
  [ "$status" -ne 0 ]
  [ ! -s "$EVENTS" ]
  [ ! -e "$FIXTURE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg" ]
}

@test "well formed foreign signing key cannot replace the official trust anchor" {
  printf 'foreign-valid-key\n' >"$VENDOR_KEY"
  run_repository
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown Tailscale signing key"* ]]
  [ ! -s "$EVENTS" ]
  [ ! -e "$FIXTURE_ROOT/usr/share/keyrings/tailscale-archive-keyring.gpg" ]
}

@test "repository publication failure and invalid suite cannot report success" {
  export CODENAME='../noble'
  run_repository
  [ "$status" -ne 0 ]
  [ ! -s "$EVENTS" ]
  unset CODENAME
  export INSTALL_FAIL=1
  run_repository
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_ROOT/etc/apt/sources.list.d/tailscale.list" ]
}

@test "repository failure propagates through normal package setup before APT" {
  run bash -c '
    INSTALL_SOURCE_ONLY=1 source "$1/bin/dot-install"
    OS=WSL PROFILE=personal
    ensure_wsl_ssh_closed() { return 0; }
    setup_wsl_tailscale_repository() { printf "repository\n" >>"$EVENTS"; return 43; }
    install_apt_packages
  ' _ "$REPO_ROOT"
  [ "$status" -eq 43 ]
  [ "$(<"$EVENTS")" = repository ]
}
