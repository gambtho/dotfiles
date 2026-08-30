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

@test "the sandbox exposes only the named tools, not their neighbours" {
  # The symlink farm exposes explicit test dependencies without leaking every
  # executable installed beside them in a user-level bin directory.
  run find "$SANDBOX_TOOL_BIN" -mindepth 1 -maxdepth 1 -printf '%f\n'
  [ "$status" -eq 0 ]
  run bash -c 'comm -23 <(printf "%s\n" "$@" | sort) <(printf "%s\n" node yq | sort)' _ "${lines[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repository shell tooling avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin" \
    "$REPO_ROOT"/ai/*/install.sh "$REPO_ROOT/fonts/install.sh" "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}
