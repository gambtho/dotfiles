#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/bin/common.sh"
  source "$REPO_ROOT/config/versions.env"
}

@test "required phase failure makes summary fail" {
  run bash -c 'source "$1/bin/common.sh"; run_phase required packages false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: packages"* ]]
}

@test "optional phase failure is reported without failing install" {
  run bash -c 'source "$1/bin/common.sh"; run_phase optional fonts false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: fonts"* ]]
}

@test "make ai keeps going past a failed installer and still exits nonzero" {
  # A plain recipe loop reports only the LAST installer's status: a failed
  # claude install followed by a successful vekil install exits 0 and `make ai`
  # announces success over a half-configured machine. The recipe must both
  # finish the loop (one broken installer must not block the rest) and fail.
  local fixture="$TEST_ROOT/make-ai"
  mkdir -p "$fixture/ai/aa" "$fixture/ai/bb"
  cp "$REPO_ROOT/Makefile" "$fixture/Makefile"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture/ai/aa/install.sh"
  printf '#!/usr/bin/env bash\ntouch "%s/ran-bb"\nexit 0\n' "$fixture" >"$fixture/ai/bb/install.sh"

  run make -C "$fixture" ai
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai/aa/install.sh"* ]]
  [ -f "$fixture/ran-bb" ]

  run make -C "$fixture" ai-check
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai/aa/install.sh"* ]]
}

@test "remote installer is denied without explicit consent" {
  run bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "remote installer is allowed with explicit consent" {
  run env ALLOW_REMOTE_INSTALLERS=1 bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
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
    bash -c 'source "$1/bin/common.sh"; run_remote_installer https://example.test/install.sh sh "{}" --yes' _ "$REPO_ROOT"
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
    bash -c 'source "$1/bin/common.sh"; run_remote_installer https://example.test/install.sh bash' _ "$REPO_ROOT"

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
    'source "$1/bin/common.sh"; download_verified_artifact https://example.test/tool deadbeef "$2" 0755' \
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
    'source "$1/bin/common.sh"; download_verified_artifact https://example.test/tool "$2" "$3" 0755' \
    _ "$REPO_ROOT" "$expected" "$HOME/tool"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/tool")" = new ]
  [ "$(stat -c '%a' "$HOME/tool")" = 755 ]
  grep -Fq -- '--connect-timeout 10 --max-time 120 --retry 3' "$TEST_ROOT/curl-args"
}

@test "publish_staged_file replaces a symlinked destination instead of following it" {
  # Without -T (GNU mv), a symlinked destination is followed and the staged
  # file lands inside the target directory; the link survives pointing at
  # stale content. Skipped on BSD mv, where the callers' validation is the guard.
  mv --version 2>/dev/null | grep -q 'GNU coreutils' || skip "requires GNU mv"

  mkdir -p "$TEST_ROOT/elsewhere"
  printf 'staged\n' >"$TEST_ROOT/staged"
  ln -s "$TEST_ROOT/elsewhere" "$TEST_ROOT/destination"

  run bash -c 'source "$1/bin/common.sh"; publish_staged_file "$2" "$3"' \
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

  run bash -c 'source "$1/bin/common.sh"; publish_staged_file "$2" "$3"' \
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
    'source "$1/bin/bootstrap"; parse_bootstrap_args --non-interactive; validate_bootstrap_options' _ "$REPO_ROOT"
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
    'source "$1/bin/bootstrap"; DOTFILES_ROOT="$2"; parse_bootstrap_args --non-interactive --profile personal; validate_bootstrap_options' \
    _ "$REPO_ROOT" "$unconfigured_root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git user.name and user.email are required"* ]]
}

@test "bootstrap flags enable remote installers without prompting" {
  git config --global user.name "Dotfiles Test"
  git config --global user.email "dotfiles@example.com"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; parse_bootstrap_args --non-interactive --profile work --allow-remote-installers; validate_bootstrap_options; printf "%s %s %s\n" "$NON_INTERACTIVE" "$BOOTSTRAP_PROFILE" "$ALLOW_REMOTE_INSTALLERS"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "true work 1" ]
}

@test "bootstrap preserves remote installer consent from environment" {
  run env ALLOW_REMOTE_INSTALLERS=1 BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; printf "%s\n" "$ALLOW_REMOTE_INSTALLERS"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "non-interactive bootstrap accepts existing local git config" {
  local configured_root="$TEST_ROOT/configured-dotfiles"
  mkdir -p "$configured_root/core/git"
  touch "$configured_root/core/git/gitconfig.local.symlink"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; DOTFILES_ROOT="$2"; parse_bootstrap_args --non-interactive --profile personal; validate_bootstrap_options' \
    _ "$REPO_ROOT" "$configured_root"
  [ "$status" -eq 0 ]
}

@test "pinned mise selects the reviewed artifact for each Linux architecture" {
  local arch expected_asset expected_digest
  while read -r arch expected_asset expected_digest; do
    run env ARTIFACT_ARCH="$arch" bash -c '
      source "$1/bin/common.sh"
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
      source "$1/bin/common.sh"
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
  run rg -n 'install_mise_ubuntu' "$REPO_ROOT/bin/bootstrap"

  [ "$status" -eq 1 ]
  run rg -n 'install_pinned_mise' "$REPO_ROOT/bin/bootstrap"
  [ "$status" -eq 0 ]
}

@test "bootstrap stops when pinned mise installation fails" {
  local original_path="$PATH"
  local path_result="$TEST_ROOT/path-after-mise-failure"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" PATH_RESULT="$path_result" bash -c '
    source "$1/bin/bootstrap"
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

@test "agent teams setup consumes verified yq and win32yank artifacts" {
  run rg -n 'install_pinned_yq' "$REPO_ROOT/bin/setup-agent-teams"
  [ "$status" -eq 0 ]

  run rg -n 'download_verified_artifact.*WIN32YANK_WINDOWS_X64_SHA256' "$REPO_ROOT/bin/setup-agent-teams"
  [ "$status" -eq 0 ]

  run rg -n 'curl[[:space:]].*github.com/(mikefarah/yq|equalsraf/win32yank)' "$REPO_ROOT/bin/setup-agent-teams"
  [ "$status" -eq 1 ]
}

@test "work kubectl shortcuts use maintained krew plugins" {
  run rg -n 'raw\.githubusercontent\.com/blendle/kns' "$REPO_ROOT/work"
  [ "$status" -eq 1 ]

  run rg -n 'kubectl krew install ctx ns' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 0 ]

  run rg -n "alias ktx='kubectl ctx'|alias kns='kubectl ns'" "$REPO_ROOT/work/k8s-aliases.zsh"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
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

#
# setup_projects_overlay clones the private overlay repo to ~/.dotfiles/projects.
# It must never be fatal: a machine without overlays is a working machine, so
# every failure path logs and returns 0 rather than aborting `set -e` bootstrap.

run_setup_projects_overlay() {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; setup_projects_overlay' _ "$REPO_ROOT"
}

@test "overlay attach skips when no remote is configured" {
  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"No project overlay repo configured"* ]]
  [ ! -e "$HOME/.dotfiles/projects" ]
}

@test "overlay attach clones the configured remote to the canonical path" {
  local source_repo="$TEST_ROOT/overlay-source"
  mkdir -p "$source_repo/myrepo"
  printf '%s\n' "# myrepo" >"$source_repo/myrepo/CLAUDE.md"
  git -C "$source_repo" init -q
  git -C "$source_repo" -c user.name=T -c user.email=t@e add -A
  git -C "$source_repo" -c user.name=T -c user.email=t@e commit -q -m seed
  printf '%s\n' "$source_repo" >"$HOME/.dotfiles-projects-remote"

  # Stand in for bootstrap being run out of a disposable linked worktree:
  # DOTFILES_ROOT is that worktree, but the overlays must land in the canonical
  # checkout, where bin/claude-link-project and the stable link root look.
  local worktree="$TEST_ROOT/worktrees/some-feature"
  mkdir -p "$worktree"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; DOTFILES_ROOT="$2"; setup_projects_overlay' \
    _ "$REPO_ROOT" "$worktree"

  [ "$status" -eq 0 ]
  [ -d "$HOME/.dotfiles/projects/.git" ]
  [ "$(cat "$HOME/.dotfiles/projects/myrepo/CLAUDE.md")" = "# myrepo" ]
  [ ! -e "$worktree/projects" ]
}

@test "overlay attach leaves an already-attached repo alone" {
  mkdir -p "$HOME/.dotfiles/projects/.git"
  printf '%s\n' "/nonexistent/remote.git" >"$HOME/.dotfiles-projects-remote"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"already attached"* ]]
}

@test "overlay attach refuses to touch a non-empty non-repo directory" {
  mkdir -p "$HOME/.dotfiles/projects/myrepo"
  printf '%s\n' "local work" >"$HOME/.dotfiles/projects/myrepo/CLAUDE.md"
  printf '%s\n' "/nonexistent/remote.git" >"$HOME/.dotfiles-projects-remote"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"leaving it alone"* ]]
  [ "$(cat "$HOME/.dotfiles/projects/myrepo/CLAUDE.md")" = "local work" ]
}

@test "overlay attach survives a failing clone" {
  printf '%s\n' "$TEST_ROOT/does-not-exist.git" >"$HOME/.dotfiles-projects-remote"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"continuing without overlays"* ]]
}

@test "overlay attach ignores an empty remote pointer" {
  printf '\n' >"$HOME/.dotfiles-projects-remote"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"is empty"* ]]
  [ ! -e "$HOME/.dotfiles/projects" ]
}

# Cloning a private https overlay repo authenticates through the gh credential
# helper, which needs ~/.gitconfig.<slug> -- a symlink only install_dotfiles
# creates. Attaching first made the clone prompt for a username on a fresh
# machine, and the ^C that answers that prompt kills bootstrap before any
# symlink is installed.
@test "bootstrap installs symlinks before attaching the overlay repo" {
  local install_line overlay_line
  install_line="$(grep -n '^  install_dotfiles$' "$REPO_ROOT/bin/bootstrap" | cut -d: -f1)"
  overlay_line="$(grep -n '^  setup_projects_overlay$' "$REPO_ROOT/bin/bootstrap" | cut -d: -f1)"
  [ -n "$install_line" ]
  [ -n "$overlay_line" ]
  [ "$install_line" -lt "$overlay_line" ]
}

# A clone that blocks on "Username for 'https://github.com':" turns a
# non-fatal attach step into a hung bootstrap.
@test "overlay attach fails fast instead of prompting for credentials" {
  printf '%s\n' "https://github.com/example/overlays.git" \
    >"$HOME/.dotfiles-projects-remote"
  stub_command git 'printf "clone GIT_TERMINAL_PROMPT=[${GIT_TERMINAL_PROMPT:-unset}]\n"; exit 128'

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT_TERMINAL_PROMPT=[0]"* ]]
  [[ "$output" == *"continuing without overlays"* ]]
}

# The clone that failed is the one the user has to repair, so the remaining
# step must be named for the REMOTE's owner -- not for whichever identity the
# directory bootstrap happens to be running from resolves to.
@test "a failed clone names the unprovisioned identity the remote needs" {
  printf '%s\n' "https://github.com/guarzo/overlays.git" \
    >"$HOME/.dotfiles-projects-remote"
  printf 'gambtho default\nguarzo guarzo\n' >"$TEST_ROOT/overlay-owner-map"
  stub_command git 'exit 128'

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" \
    IDENTITY_MAP_FILE="$TEST_ROOT/overlay-owner-map" \
    bash -c 'source "$1/bin/bootstrap"; setup_projects_overlay' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth login"* ]]
}
