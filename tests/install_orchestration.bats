#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/libexec/common.sh"
  source "$REPO_ROOT/config/versions.env"
}

run_installer() {
  local fixture="$TEST_ROOT/entrypoint"
  mkdir -p "$fixture/bin" "$fixture/libexec"
  cp "$REPO_ROOT/bin/dot-install" "$fixture/bin/dot-install"
  # Execute the real entrypoint, but stop at its first provisioning boundary.
  # Even dropping "$@" at that entrypoint must fail safely, not configure a host.
  cat >"$fixture/libexec/common.sh" <<'SCRIPT'
log_info() { :; }
detect_os() { printf 'PROVISIONING_STARTED\n'; exit 97; }
SCRIPT
  run bash "$fixture/bin/dot-install" "$@"
}

@test "installer rejects utility flags and unexpected arguments before provisioning" {
  local argument
  for argument in -d -m --check --unknown -- "" destination; do
    run_installer "$argument"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" != *"PROVISIONING_STARTED"* ]]
  done
  run_installer -m 0755 source destination
  [ "$status" -eq 2 ]
  [[ "$output" != *"PROVISIONING_STARTED"* ]]
}

@test "installer help never starts provisioning" {
  local argument
  for argument in --help -h; do
    run_installer "$argument"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" != *"PROVISIONING_STARTED"* ]]
  done
}

@test "installer help rejects additional arguments rather than ignoring them" {
  run_installer --help destination
  [ "$status" -eq 2 ]
  [[ "$output" != *"PROVISIONING_STARTED"* ]]
}

@test "installer with no arguments still reaches provisioning" {
  run_installer
  [ "$status" -eq 97 ]
  [[ "$output" == *"PROVISIONING_STARTED"* ]]
}

@test "installer validates arguments without reading the selected profile" {
  printf 'personal\n' >"$HOME/.dotfiles-profile"
  stub_command tr 'printf "PROFILE_READ_FAILED\n" >&2; exit 95'

  run_installer --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"PROFILE_READ_FAILED"* ]]
  run_installer --unknown
  [ "$status" -eq 2 ]
  [[ "$output" != *"PROFILE_READ_FAILED"* ]]

  run_installer
  [ "$status" -eq 95 ]
  [[ "$output" == *"PROFILE_READ_FAILED"* ]]
  [[ "$output" != *"PROVISIONING_STARTED"* ]]
}

@test "dot-update forwards exact arguments and the installer exit status" {
  local fixture="$TEST_ROOT/update"
  mkdir -p "$fixture"
  cp "$REPO_ROOT/bin/dot-update" "$fixture/dot-update"
  cat >"$fixture/dot-install" <<'SCRIPT'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
exit 37
SCRIPT
  chmod +x "$fixture/dot-install"

  run bash "$fixture/dot-update" --help "two words" "" -- -m
  [ "$status" -eq 37 ]
  [ "$output" = $'<--help>\n<two words>\n<>\n<-->\n<-m>' ]
}

@test "required phase failure makes summary fail" {
  run bash -c 'source "$1/libexec/common.sh"; run_phase required packages false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: packages"* ]]
}

@test "optional phase failure is reported without failing install" {
  run bash -c 'source "$1/libexec/common.sh"; run_phase optional fonts false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: fonts"* ]]
}

@test "make ai runs only the Pi installer and propagates failures" {
  local fixture="$TEST_ROOT/make-ai"
  mkdir -p "$fixture/ai/pi"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\ntouch "%s/pi-ran"\nexit 1\n' "$fixture" >"$fixture/ai/pi/install.sh"

  run make -C "$fixture" ai
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai/pi/install.sh"* ]]
  [ -f "$fixture/pi-ran" ]

  run make -C "$fixture" ai-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai/pi/install.sh"* ]]
}

@test "remote installer is denied without explicit consent" {
  run bash -c 'source "$1/libexec/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "remote installer is allowed with explicit consent" {
  run env ALLOW_REMOTE_INSTALLERS=1 bash -c 'source "$1/libexec/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "remote installer passes arguments after the downloaded script" {
  local fake_bin="$TEST_ROOT/fake-bin"
  local result="$TEST_ROOT/remote-installer-args"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
while (($# > 0)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >"$output" <<'INSTALLER'
printf '%s\n' "$*" >"$REMOTE_INSTALLER_RESULT"
INSTALLER
SCRIPT
  chmod +x "$fake_bin/curl"

  run env ALLOW_REMOTE_INSTALLERS=1 PATH="$fake_bin:$PATH" REMOTE_INSTALLER_RESULT="$result" \
    bash -c 'source "$1/libexec/common.sh"; run_remote_installer https://example.test/install.sh sh "{}" --yes' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(cat "$result")" = "--yes" ]
}

@test "remote installer downloads use bounded curl defaults" {
  local curl_log="$TEST_ROOT/curl-args"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CURL_LOG"
while (($# > 0)); do
  if [[ "$1" == --output ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"$2"
    exit 0
  fi
  shift
done
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env ALLOW_REMOTE_INSTALLERS=1 PATH="$PATH" CURL_LOG="$curl_log" \
    bash -c 'source "$1/libexec/common.sh"; run_remote_installer https://example.test/install.sh bash' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  grep -Fq -- '--connect-timeout 10 --max-time 120 --retry 3' "$curl_log"
}

@test "verified artifact mismatch preserves the destination" {
  printf 'old\n' >"$HOME/tool"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
while (($# > 0)); do
  if [[ "$1" == --output ]]; then printf 'new\n' >"$2"; exit 0; fi
  shift
done
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash -c \
    'source "$1/libexec/common.sh"; download_verified_artifact https://example.test/tool deadbeef "$2" 0755' \
    _ "$REPO_ROOT" "$HOME/tool"

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ "$(cat "$HOME/tool")" = old ]
}

@test "verified artifact atomically replaces a destination with requested mode" {
  printf 'old\n' >"$HOME/tool"
  local expected
  expected=$(printf 'new\n' | sha256sum | awk '{print $1}')
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CURL_LOG"
while (($# > 0)); do
  if [[ "$1" == --output ]]; then printf 'new\n' >"$2"; exit 0; fi
  shift
done
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" CURL_LOG="$TEST_ROOT/curl-args" bash -c \
    'source "$1/libexec/common.sh"; download_verified_artifact https://example.test/tool "$2" "$3" 0755' \
    _ "$REPO_ROOT" "$expected" "$HOME/tool"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/tool")" = new ]
  [ "$(stat -c '%a' "$HOME/tool")" = 755 ]
  grep -Fq -- '--connect-timeout 10 --max-time 120 --retry 3' "$TEST_ROOT/curl-args"
}

stub_artifact_bsd_publish() {
  stub_command curl '
    while (($# > 0)); do
      if [[ "$1" == --output ]]; then printf "new\n" >"$2"; exit 0; fi
      shift
    done
    exit 1'
  # Force the non-GNU branch. Without -T, the host mv also follows directory links.
  stub_command mv '
    [[ "${1:-}" == --version ]] && exit 1
    printf "%s\n" "$*" >>"$TEST_ROOT/artifact-moves"
    exec /bin/mv "$@"'
}

@test "verified artifact rejects directories and directory symlinks before BSD publication" {
  stub_artifact_bsd_publish
  local destination expected
  expected=$(printf 'new\n' | sha256sum | awk '{print $1}')
  mkdir -p "$HOME/directory"
  ln -s "$HOME/directory" "$HOME/directory-link"

  for destination in "$HOME/directory" "$HOME/directory-link"; do
    run bash -c '
      source "$1/libexec/common.sh"
      download_verified_artifact https://example.test/tool "$2" "$3" 0755 || exit
      printf "INSTALL_SUCCEEDED\n"
    ' _ "$REPO_ROOT" "$expected" "$destination"

    [ "$status" -eq 1 ]
    [[ "$output" == *"directory"* ]]
    [[ "$output" != *"INSTALL_SUCCEEDED"* ]]
    [ ! -e "$TEST_ROOT/artifact-moves" ]
    [ -d "$HOME/directory" ]
    [ -L "$HOME/directory-link" ]
    run find "$HOME" -name '*.download.*'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "verified artifact accepts files and non-directory symlinks with BSD publication" {
  stub_artifact_bsd_publish
  local destination expected
  expected=$(printf 'new\n' | sha256sum | awk '{print $1}')
  printf 'old\n' >"$HOME/file"
  printf 'referent\n' >"$HOME/referent"
  ln -s "$HOME/referent" "$HOME/file-link"
  ln -s "$HOME/missing-referent" "$HOME/dangling-link"

  for destination in "$HOME/new-file" "$HOME/file" "$HOME/file-link" "$HOME/dangling-link"; do
    run bash -c '
      source "$1/libexec/common.sh"
      download_verified_artifact https://example.test/tool "$2" "$3" 0755
    ' _ "$REPO_ROOT" "$expected" "$destination"

    [ "$status" -eq 0 ]
    [ -f "$destination" ]
    [ ! -L "$destination" ]
    [ -x "$destination" ]
    [ "$(cat "$destination")" = new ]
  done
  [ -s "$TEST_ROOT/artifact-moves" ]
  [ "$(cat "$HOME/referent")" = referent ]
  [ ! -e "$HOME/missing-referent" ]
  run find "$HOME" -name '*.download.*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "publish_staged_file replaces a symlinked destination instead of following it" {
  # Without -T (GNU mv), a symlinked destination is followed and the staged
  # file lands inside the target directory; the link survives pointing at
  # stale content. Skipped on BSD mv, where the callers' validation is the guard.
  mv --version 2>/dev/null | grep -q 'GNU coreutils' || skip "requires GNU mv"

  mkdir -p "$TEST_ROOT/elsewhere"
  printf 'staged\n' >"$TEST_ROOT/staged"
  ln -s "$TEST_ROOT/elsewhere" "$TEST_ROOT/destination"

  run bash -c 'source "$1/libexec/common.sh"; publish_staged_file "$2" "$3"' \
    _ "$REPO_ROOT" "$TEST_ROOT/staged" "$TEST_ROOT/destination"

  [ "$status" -eq 0 ]
  [ ! -L "$TEST_ROOT/destination" ]
  [ "$(cat "$TEST_ROOT/destination")" = staged ]
  run find "$TEST_ROOT/elsewhere" -mindepth 1
  [ -z "$output" ]
}

@test "publish_staged_file refuses a directory destination" {
  mkdir -p "$TEST_ROOT/destination-dir"
  printf 'staged\n' >"$TEST_ROOT/staged"

  run bash -c 'source "$1/libexec/common.sh"; publish_staged_file "$2" "$3"' \
    _ "$REPO_ROOT" "$TEST_ROOT/staged" "$TEST_ROOT/destination-dir"

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to publish over a directory"* ]]
  run find "$TEST_ROOT/destination-dir" -mindepth 1
  [ -z "$output" ]
}

@test "remote scripts are never piped directly to a shell" {
  run rg -n 'curl.*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh|/bin/bash[[:space:]]+-c[[:space:]]+"\$\(curl' "$REPO_ROOT" \
    --glob '*.sh' \
    --glob 'bootstrap'
  [ "$status" -eq 1 ]
}

@test "non-interactive bootstrap requires an explicit profile" {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/libexec/bootstrap"; parse_bootstrap_args --non-interactive; validate_bootstrap_options' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile is required"* ]]
}

@test "non-interactive bootstrap requires existing git identity" {
  # Point DOTFILES_ROOT at an empty sandbox. Against the real checkout this
  # assertion is unreliable: validate_bootstrap_options short-circuits when
  # core/git/gitconfig.local.symlink exists, and that file is gitignored — so
  # it is absent on CI's clean checkout but present on any machine that has
  # actually bootstrapped, making the test pass in CI and fail locally.
  local unconfigured_root="$TEST_ROOT/unconfigured-dotfiles"
  mkdir -p "$unconfigured_root/core/git"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/libexec/bootstrap"; DOTFILES_ROOT="$2"; parse_bootstrap_args --non-interactive --profile personal; validate_bootstrap_options' \
    _ "$REPO_ROOT" "$unconfigured_root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git user.name and user.email are required"* ]]
}

@test "bootstrap flags enable remote installers without prompting" {
  git config --global user.name "Dotfiles Test"
  git config --global user.email "dotfiles@example.com"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/libexec/bootstrap"; parse_bootstrap_args --non-interactive --profile work --allow-remote-installers; validate_bootstrap_options; printf "%s %s %s\n" "$NON_INTERACTIVE" "$BOOTSTRAP_PROFILE" "$ALLOW_REMOTE_INSTALLERS"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "true work 1" ]
}

@test "bootstrap preserves remote installer consent from environment" {
  run env ALLOW_REMOTE_INSTALLERS=1 BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/libexec/bootstrap"; printf "%s\n" "$ALLOW_REMOTE_INSTALLERS"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "non-interactive bootstrap accepts existing local git config" {
  local configured_root="$TEST_ROOT/configured-dotfiles"
  mkdir -p "$configured_root/core/git"
  touch "$configured_root/core/git/gitconfig.local.symlink"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/libexec/bootstrap"; DOTFILES_ROOT="$2"; parse_bootstrap_args --non-interactive --profile personal; validate_bootstrap_options' \
    _ "$REPO_ROOT" "$configured_root"
  [ "$status" -eq 0 ]
}

@test "pinned mise selects the reviewed artifact for each Linux architecture" {
  local arch expected_asset expected_digest
  while read -r arch expected_asset expected_digest; do
    run env ARTIFACT_ARCH="$arch" bash -c '
      source "$1/libexec/common.sh"
      download_verified_artifact() { printf "%s|%s|%s|%s\n" "$@"; }
      install_pinned_mise "$2"
    ' _ "$REPO_ROOT" "$HOME/mise"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/$expected_asset|$expected_digest|$HOME/mise|0755"* ]]
  done <<CASES
x86_64 mise-v2026.7.18-linux-x64 $MISE_LINUX_X64_SHA256
aarch64 mise-v2026.7.18-linux-arm64 $MISE_LINUX_ARM64_SHA256
CASES
}

@test "pinned yq selects the reviewed artifact for each Linux architecture" {
  local arch expected_asset expected_digest
  while read -r arch expected_asset expected_digest; do
    run env ARTIFACT_ARCH="$arch" bash -c '
      source "$1/libexec/common.sh"
      download_verified_artifact() { printf "%s|%s|%s|%s\n" "$@"; }
      install_pinned_yq "$2"
    ' _ "$REPO_ROOT" "$HOME/yq"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/$expected_asset|$expected_digest|$HOME/yq|0755"* ]]
  done <<CASES
x86_64 yq_linux_amd64 $YQ_LINUX_AMD64_SHA256
arm64 yq_linux_arm64 $YQ_LINUX_ARM64_SHA256
CASES
}

@test "bootstrap no longer calls an undefined mise installer" {
  run rg -n 'install_mise_ubuntu' "$REPO_ROOT/libexec/bootstrap"

  [ "$status" -eq 1 ]
  run rg -n 'install_pinned_mise' "$REPO_ROOT/libexec/bootstrap"
  [ "$status" -eq 0 ]
}

@test "bootstrap stops when pinned mise installation fails" {
  local original_path="$PATH"
  local path_result="$TEST_ROOT/path-after-mise-failure"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" PATH_RESULT="$path_result" bash -c '
    source "$1/libexec/bootstrap"
    sudo() { :; }
    command_exists() { [[ "$1" == zsh ]]; }
    install_pinned_mise() { return 42; }
    if linux_prep; then
      result=0
    else
      result=$?
    fi
    printf "%s\n" "$PATH" >"$PATH_RESULT"
    exit "$result"
  ' _ "$REPO_ROOT"

  [ "$status" -eq 42 ]
  [ "$(cat "$path_result")" = "$original_path" ]
}

# --- work profile Krew bootstrap --------------------------------------------
#
# The ctx/ns plugins are installed through Krew, and Linux/WSL has no package
# for Krew itself, so the work profile installs the pinned tarball first. These
# cover the artifact selection and the "already present" and "no artifact"
# paths without touching the network.

@test "work profile installs the reviewed Krew artifact for each Linux architecture" {
  local arch expected_asset expected_digest
  while read -r arch expected_asset expected_digest; do
    run env WORK_INSTALL_SOURCE_ONLY=1 ARTIFACT_ARCH="$arch" OS=WSL bash -c '
      source "$1/work/install.sh"
      kubectl() { return 1; }
      download_verified_artifact() { printf "%s|%s\n" "$1" "$2"; }
      # Stand in for the real extraction: place a fake krew where the installer
      # expects the unpacked binary, so the self-install step can run.
      tar() {
        local extracted="$4/${5#./}"
        printf "%s\n" "#!/usr/bin/env bash" "echo krew-self-install \$*" >"$extracted"
        chmod +x "$extracted"
      }
      install_krew
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/$expected_asset.tar.gz|$expected_digest"* ]]
    [[ "$output" == *"krew-self-install install krew"* ]]
  done <<CASES
x86_64 krew-linux_amd64 $KREW_LINUX_AMD64_SHA256
aarch64 krew-linux_arm64 $KREW_LINUX_ARM64_SHA256
CASES
}

@test "work profile leaves an existing Krew install alone" {
  run env WORK_INSTALL_SOURCE_ONLY=1 OS=WSL bash -c '
    source "$1/work/install.sh"
    kubectl() { return 0; }
    download_verified_artifact() { printf "downloaded\n"; }
    install_krew
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"downloaded"* ]]
}

@test "work profile warns instead of downloading a Krew artifact it has not reviewed" {
  run env WORK_INSTALL_SOURCE_ONLY=1 ARTIFACT_ARCH=ppc64le OS=WSL bash -c '
    source "$1/work/install.sh"
    kubectl() { return 1; }
    download_verified_artifact() { printf "downloaded\n"; }
    install_krew
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" != *"downloaded"* ]]
  [[ "$output" == *"No reviewed Krew artifact for ppc64le"* ]]
}

@test "work profile puts the Krew bin directory on PATH for interactive shells" {
  run rg -n 'KREW_ROOT:-\$HOME/\.krew' "$REPO_ROOT/work/path.zsh"
  [ "$status" -eq 0 ]
}
