#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "tracked symlinks are relative" {
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    [[ "$mode" == 120000 ]] || continue
    path="${entry#*$'\t'}"
    [ -L "$REPO_ROOT/$path" ] || continue
    target="$(readlink "$REPO_ROOT/$path")"
    [[ "$target" != /* ]]
  done < <(git -C "$REPO_ROOT" ls-files -s -z)
}

@test "portable config contains no personal home paths" {
  # A personal path names a concrete user, so the segment after /home/ must start
  # with a plausible username character. Patterns that match any home begin with
  # a metacharacter and are excluded; `/home/tng/...` still fails.
  run rg -n '/(home|Users)/[A-Za-z0-9_.-]+' "$REPO_ROOT/ai" \
    --glob '!*.md' --glob '!*.example.*' --glob '!*backup*'
  [ "$status" -eq 1 ]
}

@test "the sandbox finds yq wherever it is installed" {
  # yq may live in /usr/bin on CI or in a mise/Homebrew user directory. Without the tool-bin symlink farm every test that
  # drives a yq-dependent script fails with "yq is required" on a machine that
  # has yq on PATH, which is a property of the machine rather than the code.
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq is not installed on this machine at all"
  fi
  run command -v yq
  [ "$status" -eq 0 ]
}

@test "the sandbox preserves selected yq over an incompatible system namesake" {
  local fixture="$TEST_ROOT/tool-order"
  mkdir -p "$fixture/bin" "$fixture/system"
  printf '#!/bin/sh\necho selected-yq\n' >"$fixture/bin/yq"
  printf '#!/bin/sh\necho incompatible-yq\n' >"$fixture/system/yq"
  chmod +x "$fixture/bin/yq" "$fixture/system/yq"

  run bash -c '
    PATH="$2/bin:$PATH"
    source "$1/tests/test_helper.bash"
    setup_dotfiles_test
    system_path="/usr/bin:/bin"
    PATH="${PATH/$system_path/$2/system:$system_path}"
    yq
  ' _ "$REPO_ROOT" "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = selected-yq ]
}

@test "the sandbox captures jq from a user-level directory" {
  local fixture="$TEST_ROOT/tool-order"
  mkdir -p "$fixture/bin"
  printf '#!/bin/sh\necho selected-jq\n' >"$fixture/bin/jq"
  chmod +x "$fixture/bin/jq"

  run bash -c '
    PATH="$2/bin:$PATH"
    source "$1/tests/test_helper.bash"
    setup_dotfiles_test
    jq
  ' _ "$REPO_ROOT" "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = selected-jq ]
}

@test "the sandbox keeps explicit stubs ahead of captured tools" {
  local fixture="$TEST_ROOT/tool-order"
  mkdir -p "$fixture/bin"
  printf '#!/bin/sh\necho selected-yq\n' >"$fixture/bin/yq"
  chmod +x "$fixture/bin/yq"

  run bash -c '
    PATH="$2/bin:$PATH"
    source "$1/tests/test_helper.bash"
    setup_dotfiles_test
    stub_command yq "echo stub-yq"
    yq
  ' _ "$REPO_ROOT" "$fixture"

  [ "$status" -eq 0 ]
  [ "$output" = stub-yq ]
}

@test "the sandbox exposes only the named tools, not their neighbours" {
  # The symlink farm exposes explicit test dependencies without leaking every
  # executable installed beside them in a user-level bin directory.
  run find "$SANDBOX_TOOL_BIN" -mindepth 1 -maxdepth 1 -printf '%f\n'
  [ "$status" -eq 0 ]
  run bash -c 'comm -23 <(printf "%s\n" "$@" | sort) <(printf "%s\n" jq node yq | sort)' _ "${lines[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A fake mise with the two behaviours that matter: every shim fails the way a real
# one does under a sandboxed HOME, and `which` only answers under the ambient HOME
# holding the trust state. A capture that runs too late or keeps the shim fails.
make_mise_fixture() {
  MISE_FIXTURE="$TEST_ROOT/mise-fixture"
  mkdir -p "$MISE_FIXTURE/home" "$MISE_FIXTURE/mise-bin" "$MISE_FIXTURE/shims" "$MISE_FIXTURE/installs"
  cat >"$MISE_FIXTURE/mise-bin/mise" <<EOF
#!/bin/sh
if [ "\${0##*/}" != mise ]; then
  echo "mise ERROR Config files are not trusted" >&2
  exit 1
fi
[ "\$1 \$HOME" = "which $MISE_FIXTURE/home" ] && [ "\$2" = node ] || exit 1
echo "$MISE_FIXTURE/installs/node"
EOF
  printf '#!/bin/sh\necho real-node\n' >"$MISE_FIXTURE/installs/node"
  chmod +x "$MISE_FIXTURE/mise-bin/mise" "$MISE_FIXTURE/installs/node"
  ln -s "$MISE_FIXTURE/mise-bin/mise" "$MISE_FIXTURE/shims/node"
  ln -s "$MISE_FIXTURE/mise-bin/mise" "$MISE_FIXTURE/shims/neighbour"
}

@test "the sandbox captures the real binary behind a mise shim" {
  make_mise_fixture

  run bash -c '
    HOME="$2/home" PATH="$2/shims:$PATH"
    source "$1/tests/test_helper.bash"
    setup_dotfiles_test
    readlink "$SANDBOX_TOOL_BIN/node"
    node
    [ ! -e "$SANDBOX_TOOL_BIN/neighbour" ] && echo no-neighbour
  ' _ "$REPO_ROOT" "$MISE_FIXTURE"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$MISE_FIXTURE/installs/node" ]
  [ "${lines[1]}" = real-node ]
  [ "${lines[2]}" = no-neighbour ]
}

@test "a mise shim that cannot resolve falls through to the next PATH entry" {
  make_mise_fixture
  mkdir -p "$MISE_FIXTURE/later"
  printf '#!/bin/sh\necho later-node\n' >"$MISE_FIXTURE/later/node"
  chmod +x "$MISE_FIXTURE/later/node"

  # An ambient HOME other than the fixture's makes `mise which` fail.
  run bash -c '
    PATH="$2/shims:$2/later:$PATH"
    source "$1/tests/test_helper.bash"
    resolve_host_tool node
    resolve_host_tool neighbour || echo unresolved
  ' _ "$REPO_ROOT" "$MISE_FIXTURE"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$MISE_FIXTURE/later/node" ]
  [ "${lines[1]}" = unresolved ]
}

@test "repository shell tooling avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin" "$REPO_ROOT/libexec" \
    "$REPO_ROOT"/ai/*/install.sh "$REPO_ROOT/fonts/install.sh" "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}
