#!/usr/bin/env bats

load test_helper

# The installer runs from a fixture copy whose pins point at local payloads, so
# a fake curl can serve them with digests that match. A fake claude keeps the
# plugin state in files, as in claude_installer.bats. SYSTEM_BIN stands in for
# the system directories on a lane's PATH.
setup() {
  setup_dotfiles_test
  unset CLAUDE_CONFIG_DIR
  export ARTIFACT_ARCH=x86_64
  REAL_JQ=$(command -v jq)
  FIXTURE="$TEST_ROOT/repo"
  PAYLOADS="$TEST_ROOT/payloads"
  STATE="$TEST_ROOT/claude-state"
  SHARE="$XDG_DATA_HOME/lane-worker"
  SYSTEM_BIN="$TEST_ROOT/system-bin"
  export PAYLOADS STATE LANE_WORKER_SYSTEM_PATH="$SYSTEM_BIN"
  mkdir -p "$FIXTURE"/{tools/lane-worker,libexec/lib,config,ai/claude} "$PAYLOADS" "$STATE" "$HOME/.claude" "$SYSTEM_BIN"
  cp "$REPO_ROOT/tools/lane-worker/install.sh" "$FIXTURE/tools/lane-worker/"
  cp "$REPO_ROOT/libexec/lib/artifacts.sh" "$REPO_ROOT/libexec/lib/tool-path.sh" "$FIXTURE/libexec/lib/"
  cp "$REPO_ROOT/ai/claude/install.sh" "$FIXTURE/ai/claude/"
  INSTALLER="$FIXTURE/tools/lane-worker/install.sh"
  TAG=$(sed -n 's/^SKILLS_TAG=//p' "$FIXTURE/ai/claude/install.sh")

  local arch
  for arch in x86_64 aarch64; do
    mkdir -p "$TEST_ROOT/build-$arch/bin" "$TEST_ROOT/build-$arch/codex-resources"
    printf '#!/bin/sh\necho codex-cli %s\n' "$arch" >"$TEST_ROOT/build-$arch/bin/codex"
    printf 'bwrap\n' >"$TEST_ROOT/build-$arch/codex-resources/bwrap"
    chmod +x "$TEST_ROOT/build-$arch/bin/codex"
    tar -czf "$PAYLOADS/codex-package-$arch-unknown-linux-musl.tar.gz" -C "$TEST_ROOT/build-$arch" bin codex-resources
  done
  for arch in x64 arm64; do
    python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("coderabbit", "#!/bin/sh\necho coderabbit %s\n" % sys.argv[2])' "$PAYLOADS/coderabbit-linux-$arch.zip" "$arch"
  done
  for arch in amd64 arm64; do
    printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_JQ" >"$PAYLOADS/jq-linux-$arch"
  done
  local lfs_version
  lfs_version=$(sed -n 's/^GIT_LFS_VERSION=//p' "$REPO_ROOT/config/versions.env")
  for arch in amd64 arm64; do
    mkdir -p "$TEST_ROOT/lfs-$arch/git-lfs-$lfs_version"
    printf '#!/bin/sh\necho git-lfs %s\n' "$arch" >"$TEST_ROOT/lfs-$arch/git-lfs-$lfs_version/git-lfs"
    printf 'readme\n' >"$TEST_ROOT/lfs-$arch/git-lfs-$lfs_version/README.md"
    chmod +x "$TEST_ROOT/lfs-$arch/git-lfs-$lfs_version/git-lfs"
    tar -czf "$PAYLOADS/git-lfs-linux-$arch-v$lfs_version.tar.gz" -C "$TEST_ROOT/lfs-$arch" "git-lfs-$lfs_version"
  done
  write_pins

  stub_command curl '
    out="" url=""
    while (($#)); do
      case "$1" in
        --output) out=$2; shift ;;
        https://*) url=$1 ;;
      esac
      shift
    done
    echo "$url" >>"$PAYLOADS/downloads"
    cp "$PAYLOADS/${url##*/}" "$out"
  '
  stub_command claude '
    set -euo pipefail
    case "$*" in
      "plugin marketplace list --json")
        if [[ -f "$STATE/ref" ]]; then
          jq -n --arg ref "$(cat "$STATE/ref")" "[{name: \"gambtho-skills\", repo: \"gambtho/gambtho-skills\", ref: \$ref}]"
        else
          echo "[]"
        fi ;;
      "plugin list --json")
        if [[ -f "$STATE/version" ]]; then
          jq -n --arg v "$(cat "$STATE/version")" "[{id: \"gambtho-skills@gambtho-skills\", version: \$v, enabled: true, scope: \"user\"}]"
        else
          echo "[]"
        fi ;;
      "plugin marketplace add gambtho/gambtho-skills@"*" --scope user")
        echo "$*" >>"$STATE/calls"; echo "${4#*@}" >"$STATE/ref" ;;
      "plugin install gambtho-skills@gambtho-skills --scope user")
        echo "$*" >>"$STATE/calls"; ref=$(cat "$STATE/ref"); echo "${ref#v}" >"$STATE/version" ;;
      *) echo "unexpected claude $*" >&2; exit 97 ;;
    esac
  '
  # Anything that would touch the login shell, services, Herdr or lanes.
  local name
  for name in sudo chsh usermod systemctl systemd-run loginctl busctl dbus-send herdr lane; do
    stub_command "$name" "echo \"$name \$*\" >>\"$TEST_ROOT/forbidden\"; exit 1"
  done
}

digest() { sha256sum "$1" | awk '{print $1}'; }

write_pins() {
  cp "$REPO_ROOT/config/versions.env" "$FIXTURE/config/versions.env"
  cat >>"$FIXTURE/config/versions.env" <<EOF
CODEX_RELEASE_BASE=https://example.test/codex
CODEX_PACKAGE_LINUX_X86_64_SHA256=$(digest "$PAYLOADS/codex-package-x86_64-unknown-linux-musl.tar.gz")
CODEX_PACKAGE_LINUX_AARCH64_SHA256=$(digest "$PAYLOADS/codex-package-aarch64-unknown-linux-musl.tar.gz")
CODERABBIT_RELEASE_BASE=https://example.test/coderabbit
CODERABBIT_LINUX_X64_SHA256=$(digest "$PAYLOADS/coderabbit-linux-x64.zip")
CODERABBIT_LINUX_ARM64_SHA256=$(digest "$PAYLOADS/coderabbit-linux-arm64.zip")
JQ_RELEASE_BASE=https://example.test/jq
JQ_LINUX_AMD64_SHA256=$(digest "$PAYLOADS/jq-linux-amd64")
JQ_LINUX_ARM64_SHA256=$(digest "$PAYLOADS/jq-linux-arm64")
GIT_LFS_RELEASE_BASE=https://example.test/git-lfs
GIT_LFS_LINUX_AMD64_SHA256=$(digest "$PAYLOADS/git-lfs-linux-amd64-v$(sed -n 's/^GIT_LFS_VERSION=//p' "$REPO_ROOT/config/versions.env").tar.gz")
GIT_LFS_LINUX_ARM64_SHA256=$(digest "$PAYLOADS/git-lfs-linux-arm64-v$(sed -n 's/^GIT_LFS_VERSION=//p' "$REPO_ROOT/config/versions.env").tar.gz")
EOF
  source "$FIXTURE/config/versions.env"
}

# A lane PATH whose system part already has jq, as most workers do.
system_jq() {
  ln -s "$REAL_JQ" "$SYSTEM_BIN/jq"
}

# Every directory, file and link under HOME, with mode and content digest or
# link target.
snapshot_home() {
  (
    cd "$HOME"
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then
        printf '%s -> %s\n' "$path" "$(readlink "$path")"
      elif [[ -d "$path" ]]; then
        printf '%s/ %s\n' "$path" "$(stat -c %a "$path")"
      else
        printf '%s %s %s\n' "$path" "$(stat -c %a "$path")" "$(digest "$path")"
      fi
    done
  )
}

@test "usage: exactly one of --check or --apply" {
  run bash "$INSTALLER"
  [ "$status" -eq 2 ]
  run bash "$INSTALLER" --apply --check
  [ "$status" -eq 2 ]
  run bash "$INSTALLER" --force
  [ "$status" -eq 2 ]
}

@test "--check reports what it would do and changes nothing" {
  system_jq
  snapshot_home >"$TEST_ROOT/before"

  run bash "$INSTALLER" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] Would add the gambtho-skills marketplace at gambtho/gambtho-skills@$TAG"* ]]
  [[ "$output" == *"[dry-run] Would install codex $CODEX_VERSION."* ]]
  [[ "$output" == *"[dry-run] Would install coderabbit $CODERABBIT_CLI_VERSION."* ]]
  [[ "$output" == *"jq is already at $SYSTEM_BIN/jq; leaving it."* ]]
  [[ "$output" == *"codex login --device-auth"* ]]
  [[ "$output" == *"coderabbit auth login"* ]]
  [ ! -e "$PAYLOADS/downloads" ]
  [ ! -e "$STATE/calls" ]
  snapshot_home | diff "$TEST_ROOT/before" -
}

@test "--apply installs the plugin and both review CLIs, and a second run changes nothing" {
  system_jq
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/calls")" = "plugin marketplace add gambtho/gambtho-skills@$TAG --scope user
plugin install gambtho-skills@gambtho-skills --scope user" ]
  [ "$(readlink "$HOME/.local/bin/codex")" = "$SHARE/codex-$CODEX_VERSION/bin/codex" ]
  [ "$(readlink "$HOME/.local/bin/coderabbit")" = "$SHARE/coderabbit-$CODERABBIT_CLI_VERSION/coderabbit" ]
  [ "$("$HOME/.local/bin/codex")" = "codex-cli x86_64" ]
  [ "$("$HOME/.local/bin/coderabbit")" = "coderabbit x64" ]
  # Codex keeps its package layout, so it finds its bundled sandbox helper.
  [ -f "$SHARE/codex-$CODEX_VERSION/codex-resources/bwrap" ]
  [ ! -e "$HOME/.local/bin/jq" ]
  [ -z "$(find "$SHARE" "$HOME/.local/bin" -mindepth 1 -name '.*')" ]

  rm -f "$PAYLOADS/downloads" "$STATE/calls"
  snapshot_home >"$TEST_ROOT/before"
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex $CODEX_VERSION is installed."* ]]
  [[ "$output" == *"coderabbit $CODERABBIT_CLI_VERSION is installed."* ]]
  [ ! -e "$PAYLOADS/downloads" ]
  [ ! -e "$STATE/calls" ]
  snapshot_home | diff "$TEST_ROOT/before" -
}

@test "--apply leaves shell profiles, PATH files, user units, Herdr and lanes state alone" {
  mkdir -p "$HOME/.config/environment.d" "$HOME/.config/systemd/user" "$HOME/.config/herdr" \
    "$HOME/.developerlanes/project/reports" "$HOME/.local/bin" "$XDG_DATA_HOME"
  local file
  for file in .profile .bashrc .bash_profile .zshrc .zprofile .zshenv .pam_environment \
    .config/environment.d/10-path.conf .config/systemd/user/lanes-worker.service \
    .config/herdr/config.toml .developerlanes/project/reports/1-REPORT.md; do
    echo "original $file" >"$HOME/$file"
  done
  snapshot_home >"$TEST_ROOT/before"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/forbidden" ]
  # Nothing changed or disappeared; everything new is a tool link or lives
  # under the tool folder.
  run diff "$TEST_ROOT/before" <(snapshot_home)
  [[ "$output" == *"> ./.local/bin/codex -> "* ]]
  [ -z "$(grep '^<' <<<"$output")" ]
  [ -z "$(grep '^>' <<<"$output" | grep -v -e '^> ./.local/bin/codex -> ' -e '^> ./.local/bin/coderabbit -> ' \
    -e '^> ./.local/bin/jq -> ' -e '^> ./.local/bin/git-lfs -> ' -e '^> ./.local/bin/python -> ' \
    -e '^> ./.local/share/lane-worker[/ ]')" ]
}

@test "a file it did not link, or a tool lanes already find, is left alone" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho own codex\n' >"$HOME/.local/bin/codex"
  printf '#!/bin/sh\necho system coderabbit\n' >"$SYSTEM_BIN/coderabbit"
  chmod +x "$HOME/.local/bin/codex" "$SYSTEM_BIN/coderabbit"
  system_jq

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin/codex was not installed by this script; leaving it."* ]]
  [[ "$output" == *"coderabbit is already at $SYSTEM_BIN/coderabbit; leaving it."* ]]
  [ "$("$HOME/.local/bin/codex")" = "own codex" ]
  [ ! -e "$HOME/.local/bin/coderabbit" ]
  [ ! -e "$PAYLOADS/downloads" ] || ! grep -q -e codex -e coderabbit "$PAYLOADS/downloads"
}

@test "a tool only on the interactive PATH is still installed for lanes" {
  system_jq
  stub_command coderabbit 'echo interactive coderabbit'

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/coderabbit")" = "$SHARE/coderabbit-$CODERABBIT_CLI_VERSION/coderabbit" ]
}

@test "a new pin relinks a build it installed and keeps the old folder" {
  system_jq
  mkdir -p "$SHARE/codex-0.0.1/bin" "$HOME/.local/bin"
  printf '#!/bin/sh\necho old\n' >"$SHARE/codex-0.0.1/bin/codex"
  chmod +x "$SHARE/codex-0.0.1/bin/codex"
  ln -s "$SHARE/codex-0.0.1/bin/codex" "$HOME/.local/bin/codex"

  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would replace codex $CODEX_VERSION."* ]]
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/codex")" = "$SHARE/codex-$CODEX_VERSION/bin/codex" ]
  [ -x "$SHARE/codex-0.0.1/bin/codex" ]
}

@test "a broken folder for the pinned version is replaced, not reused" {
  system_jq
  mkdir -p "$SHARE/codex-$CODEX_VERSION/bin"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/codex")" = "codex-cli x86_64" ]
  [ -z "$(find "$SHARE" -mindepth 1 -maxdepth 1 -name '.staging-*')" ]
}

@test "a digest mismatch fails and links nothing" {
  system_jq
  printf 'tampered\n' >>"$PAYLOADS/codex-package-x86_64-unknown-linux-musl.tar.gz"

  run bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.local/bin/codex" ]
  [ ! -e "$SHARE/codex-$CODEX_VERSION" ]
  [ -z "$(find "$SHARE" -mindepth 1 -maxdepth 1 -name '.staging-*')" ]
}

@test "a run after an interrupted one clears its staging and installs" {
  system_jq
  mkdir -p "$SHARE/.staging-old/codex"
  printf 'partial\n' >"$SHARE/.staging-old/codex/partial"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ ! -e "$SHARE/.staging-old" ]
  [ "$("$HOME/.local/bin/codex")" = "codex-cli x86_64" ]
}

@test "aarch64 boxes get the arm64 builds" {
  ARTIFACT_ARCH=aarch64 run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$("$HOME/.local/bin/codex")" = "codex-cli aarch64" ]
  [ "$("$HOME/.local/bin/coderabbit")" = "coderabbit arm64" ]
  grep -qx 'https://example.test/jq/jq-linux-arm64' "$PAYLOADS/downloads"
}

@test "--apply stops before any change when claude is missing" {
  rm "$STUB_BIN/claude"

  run bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"claude is missing"* ]]
  [ ! -e "$PAYLOADS/downloads" ]
  [ ! -e "$HOME/.local/bin" ]
}

@test "python3 is needed only when coderabbit must be downloaded" {
  system_jq
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]

  # Everything current: no python3 needed.
  local tools="$TEST_ROOT/no-python-bin" tool
  mkdir -p "$tools"
  for tool in bash sh env cat cp mv rm ln mkdir mktemp chmod dirname uname awk sed tr \
    sha256sum tar gzip readlink grep jq; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  PATH="$STUB_BIN:$tools" run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]

  rm "$HOME/.local/bin/coderabbit"
  PATH="$STUB_BIN:$tools" run bash "$INSTALLER" --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"python3 is needed to install coderabbit"* ]]
}

@test "jq is installed first when lanes find none, and the plugin installer uses it" {
  # An interactive PATH without jq; the fake claude uses the real one directly.
  local tools="$TEST_ROOT/no-jq-bin" tool
  mkdir -p "$tools"
  for tool in bash sh env cat cp mv rm ln mkdir mktemp chmod dirname basename uname awk sed sort tr \
    sha256sum tar gzip python3 readlink grep wc ls find; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  sed -i "s|jq -n|$REAL_JQ -n|g" "$STUB_BIN/claude"

  PATH="$STUB_BIN:$tools" run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed jq $JQ_VERSION"* ]]
  [[ "$output" == *"Claude Code has gambtho-skills@gambtho-skills ${TAG#v}."* ]]
  [ "$(head -1 "$PAYLOADS/downloads")" = "https://example.test/jq/jq-linux-amd64" ]
  [ "$(readlink "$HOME/.local/bin/jq")" = "$SHARE/jq-$JQ_VERSION/jq" ]
}

@test "git-lfs is installed where lanes find none, and its pin follows mise" {
  system_jq
  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would install git-lfs $GIT_LFS_VERSION."* ]]

  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/git-lfs")" = "$SHARE/git-lfs-$GIT_LFS_VERSION/git-lfs-$GIT_LFS_VERSION/git-lfs" ]
  [ "$("$HOME/.local/bin/git-lfs")" = "git-lfs amd64" ]
  # Only the binary is unpacked.
  [ "$(find "$SHARE/git-lfs-$GIT_LFS_VERSION" -type f)" = "$SHARE/git-lfs-$GIT_LFS_VERSION/git-lfs-$GIT_LFS_VERSION/git-lfs" ]
  grep -Eq "^git-lfs = \"$GIT_LFS_VERSION\"$" "$REPO_ROOT/config/mise/config.toml"

  rm "$HOME/.local/bin/git-lfs"
  printf '#!/bin/sh\n' >"$SYSTEM_BIN/git-lfs"
  chmod +x "$SYSTEM_BIN/git-lfs"
  run bash "$INSTALLER" --apply
  [[ "$output" == *"git-lfs is already at $SYSTEM_BIN/git-lfs; leaving it."* ]]
  [ ! -e "$HOME/.local/bin/git-lfs" ]
}

@test "python links to the system python3 only when lanes find no python" {
  system_jq
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"No python3 where lanes look"* ]]
  [ ! -e "$HOME/.local/bin/python" ]

  printf '#!/bin/sh\necho system python3\n' >"$SYSTEM_BIN/python3"
  chmod +x "$SYSTEM_BIN/python3"
  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would link $HOME/.local/bin/python to $SYSTEM_BIN/python3."* ]]
  [ ! -e "$HOME/.local/bin/python" ]

  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/python")" = "$SYSTEM_BIN/python3" ]
  [ "$("$HOME/.local/bin/python")" = "system python3" ]
  run bash "$INSTALLER" --apply
  [[ "$output" == *"python links to $SYSTEM_BIN/python3."* ]]

  # A python lanes already find, or a file it did not make, is left alone.
  rm "$HOME/.local/bin/python"
  printf '#!/bin/sh\n' >"$SYSTEM_BIN/python"
  chmod +x "$SYSTEM_BIN/python"
  run bash "$INSTALLER" --apply
  [[ "$output" == *"python is already at $SYSTEM_BIN/python; leaving it."* ]]
  [ ! -e "$HOME/.local/bin/python" ]
  rm "$SYSTEM_BIN/python"
  printf '#!/bin/sh\necho own\n' >"$HOME/.local/bin/python"
  chmod +x "$HOME/.local/bin/python"
  run bash "$INSTALLER" --apply
  [[ "$output" == *"$HOME/.local/bin/python was not installed by this script; leaving it."* ]]
  [ "$("$HOME/.local/bin/python")" = own ]
}
