#!/usr/bin/env bats

load test_helper

# The installer runs from a fixture copy whose pins point at local payloads, so
# a fake curl can serve them with digests that match. A fake claude keeps the
# plugin state in files, as in claude_installer.bats.
setup() {
  setup_dotfiles_test
  unset CLAUDE_CONFIG_DIR
  export ARTIFACT_ARCH=x86_64
  REAL_JQ=$(command -v jq)
  FIXTURE="$TEST_ROOT/repo"
  PAYLOADS="$TEST_ROOT/payloads"
  STATE="$TEST_ROOT/claude-state"
  export PAYLOADS STATE
  mkdir -p "$FIXTURE"/{tools/lane-worker,libexec/lib,config,ai/claude} "$PAYLOADS" "$STATE" "$HOME/.claude"
  cp "$REPO_ROOT/tools/lane-worker/install.sh" "$FIXTURE/tools/lane-worker/"
  cp "$REPO_ROOT/libexec/lib/artifacts.sh" "$REPO_ROOT/libexec/lib/tool-path.sh" "$FIXTURE/libexec/lib/"
  cp "$REPO_ROOT/ai/claude/install.sh" "$FIXTURE/ai/claude/"
  INSTALLER="$FIXTURE/tools/lane-worker/install.sh"
  TAG=$(sed -n 's/^SKILLS_TAG=//p' "$FIXTURE/ai/claude/install.sh")

  local work="$TEST_ROOT/build"
  mkdir -p "$work"
  printf '#!/bin/sh\necho codex-cli fake\n' >"$work/codex-x86_64-unknown-linux-musl"
  chmod +x "$work/codex-x86_64-unknown-linux-musl"
  tar -czf "$PAYLOADS/codex-x86_64-unknown-linux-musl.tar.gz" -C "$work" codex-x86_64-unknown-linux-musl
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("coderabbit", "#!/bin/sh\necho coderabbit fake\n")' "$PAYLOADS/coderabbit-linux-x64.zip"
  printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_JQ" >"$PAYLOADS/jq-linux-amd64"
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
  for name in sudo chsh systemctl loginctl herdr lane; do
    stub_command "$name" "echo \"$name \$*\" >>\"$TEST_ROOT/forbidden\"; exit 1"
  done
}

digest() { sha256sum "$1" | awk '{print $1}'; }

write_pins() {
  cp "$REPO_ROOT/config/versions.env" "$FIXTURE/config/versions.env"
  cat >>"$FIXTURE/config/versions.env" <<EOF
CODEX_RELEASE_BASE=https://example.test/codex
CODEX_LINUX_X86_64_SHA256=$(digest "$PAYLOADS/codex-x86_64-unknown-linux-musl.tar.gz")
CODERABBIT_RELEASE_BASE=https://example.test/coderabbit
CODERABBIT_LINUX_X64_SHA256=$(digest "$PAYLOADS/coderabbit-linux-x64.zip")
JQ_RELEASE_BASE=https://example.test/jq
JQ_LINUX_AMD64_SHA256=$(digest "$PAYLOADS/jq-linux-amd64")
EOF
  source "$FIXTURE/config/versions.env"
}

# Every file and link under HOME with its content digest or link target.
snapshot_home() {
  (
    cd "$HOME"
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s -> %s\n' "$path" "$(readlink "$path")"; else printf '%s %s\n' "$path" "$(digest "$path")"; fi
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
  snapshot_home >"$TEST_ROOT/before"

  run bash "$INSTALLER" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] Would add the gambtho-skills marketplace at gambtho/gambtho-skills@$TAG"* ]]
  [[ "$output" == *"[dry-run] Would install codex $CODEX_VERSION in $HOME/.local/bin."* ]]
  [[ "$output" == *"[dry-run] Would install coderabbit $CODERABBIT_CLI_VERSION in $HOME/.local/bin."* ]]
  [[ "$output" == *"jq is already on PATH"* ]]
  [[ "$output" == *"codex login --device-auth"* ]]
  [[ "$output" == *"coderabbit auth login"* ]]
  [ ! -e "$PAYLOADS/downloads" ]
  [ ! -e "$STATE/calls" ]
  snapshot_home | diff "$TEST_ROOT/before" -
}

@test "--apply installs the plugin and both review CLIs, and a second run changes nothing" {
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/calls")" = "plugin marketplace add gambtho/gambtho-skills@$TAG --scope user
plugin install gambtho-skills@gambtho-skills --scope user" ]
  [ "$("$HOME/.local/bin/codex")" = "codex-cli fake" ]
  [ "$("$HOME/.local/bin/coderabbit")" = "coderabbit fake" ]
  [ ! -e "$HOME/.local/bin/jq" ]
  [ "$(wc -l <"$PAYLOADS/downloads")" -eq 2 ]
  [ "$(awk '{print $1, $2}' "$XDG_STATE_HOME/dotfiles/lane-worker-tools" | sort | tr '\n' ' ')" = "coderabbit $CODERABBIT_CLI_VERSION codex $CODEX_VERSION " ]
  [ -z "$(find "$HOME/.local/bin" -name '.*')" ]

  rm "$PAYLOADS/downloads" "$STATE/calls"
  snapshot_home >"$TEST_ROOT/before"
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex $CODEX_VERSION is installed in $HOME/.local/bin."* ]]
  [[ "$output" == *"coderabbit $CODERABBIT_CLI_VERSION is installed in $HOME/.local/bin."* ]]
  [ ! -e "$PAYLOADS/downloads" ]
  [ ! -e "$STATE/calls" ]
  snapshot_home | diff "$TEST_ROOT/before" -
}

@test "--apply leaves shell profiles, PATH files, user units, Herdr and lanes state alone" {
  mkdir -p "$HOME/.config/environment.d" "$HOME/.config/systemd/user" "$HOME/.config/herdr" \
    "$HOME/.developerlanes/project/reports"
  local file
  for file in .profile .bashrc .bash_profile .zshrc .zprofile .config/environment.d/10-path.conf \
    .config/systemd/user/lanes-worker.service .config/herdr/config.toml .developerlanes/project/reports/1-REPORT.md; do
    echo "original $file" >"$HOME/$file"
  done
  snapshot_home >"$TEST_ROOT/before"

  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/forbidden" ]
  # Only the two binaries and the receipt are new; nothing else changed.
  run diff "$TEST_ROOT/before" <(snapshot_home)
  [ "$(grep -c '^[<>]' <<<"$output")" -eq 3 ]
  [ -z "$(grep '^[<>]' <<<"$output" | grep -v -e '^> ./.local/bin/codex ' -e '^> ./.local/bin/coderabbit ' -e '^> ./.local/state/dotfiles/lane-worker-tools ')" ]
}

@test "a binary it did not install, or one on PATH elsewhere, is left alone" {
  mkdir -p "$HOME/.local/bin" "$TEST_ROOT/other"
  printf '#!/bin/sh\necho own codex\n' >"$HOME/.local/bin/codex"
  printf '#!/bin/sh\necho other coderabbit\n' >"$TEST_ROOT/other/coderabbit"
  chmod +x "$HOME/.local/bin/codex" "$TEST_ROOT/other/coderabbit"

  PATH="$PATH:$TEST_ROOT/other" run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin/codex is not a build this script installed; leaving it."* ]]
  [[ "$output" == *"coderabbit is already on PATH at $TEST_ROOT/other/coderabbit; leaving it."* ]]
  [ "$("$HOME/.local/bin/codex")" = "own codex" ]
  [ ! -e "$HOME/.local/bin/coderabbit" ]
  [ ! -e "$PAYLOADS/downloads" ]
}

@test "a new pin replaces the older build it installed" {
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  sed -i "s/^codex $CODEX_VERSION /codex 0.0.1 /" "$XDG_STATE_HOME/dotfiles/lane-worker-tools"
  rm "$PAYLOADS/downloads"

  run bash "$INSTALLER" --check
  [[ "$output" == *"[dry-run] Would replace codex $CODEX_VERSION"* ]]
  run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [ "$(cat "$PAYLOADS/downloads")" = "https://example.test/codex/codex-x86_64-unknown-linux-musl.tar.gz" ]
  grep -qx "codex $CODEX_VERSION [0-9a-f]*" "$XDG_STATE_HOME/dotfiles/lane-worker-tools"
}

@test "a digest mismatch fails and installs nothing" {
  printf 'tampered\n' >>"$PAYLOADS/codex-x86_64-unknown-linux-musl.tar.gz"

  run bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ -z "$(ls -A "$HOME/.local/bin")" ]
  [ ! -e "$XDG_STATE_HOME/dotfiles/lane-worker-tools" ]
}

@test "--apply stops before any change when claude is missing" {
  rm "$STUB_BIN/claude"

  run bash "$INSTALLER" --apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing: claude"* ]]
  [ ! -e "$PAYLOADS/downloads" ]
}

@test "jq is installed first when none is on PATH, and the plugin installer uses it" {
  # A PATH with the tools the scripts need, but no jq.
  local tools="$TEST_ROOT/no-jq-bin" tool
  mkdir -p "$tools"
  for tool in bash sh env cat cp mv rm mkdir mktemp chmod dirname basename uname awk sed sort tr \
    sha256sum tar gzip python3 readlink grep wc ls find; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  # The fake claude reads JSON with jq too; pin it to the real one.
  sed -i "s|jq -n|$REAL_JQ -n|g" "$STUB_BIN/claude"

  PATH="$STUB_BIN:$tools" run bash "$INSTALLER" --apply

  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed jq $JQ_VERSION in $HOME/.local/bin."* ]]
  [[ "$output" == *"Claude Code has gambtho-skills@gambtho-skills ${TAG#v}."* ]]
  [ "$(head -1 "$PAYLOADS/downloads")" = "https://example.test/jq/jq-linux-amd64" ]
}
