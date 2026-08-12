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
    [ -L "$REPO_ROOT/$path" ]
    target="$(readlink "$REPO_ROOT/$path")"
    [[ "$target" != /* ]]
  done < <(git -C "$REPO_ROOT" ls-files -s -z)
}

@test "portable config contains no personal home paths" {
  # A personal path names a concrete user, so the segment after /home/ must start
  # with a plausible username character. Patterns that match *any* home --
  # `/home/*/.claude/*`, `/home/[^"/]+` -- are the opposite of a hardcoded path
  # and start with a metacharacter, which this class excludes. `/home/tng/...`
  # still fails, which is the case this test exists for.
  run rg -n '/(home|Users)/[A-Za-z0-9_.-]+' "$REPO_ROOT/ai" \
    --glob '!*.md' --glob '!*.example.*' --glob '!*backup*'
  [ "$status" -eq 1 ]
}

@test "the sandbox finds yq wherever it is installed" {
  # yq lands in /usr/local/bin when bin/setup-agent-teams installs it and in
  # /usr/bin on GitHub's runners, but a hand-installed one (mise, ~/.local/bin,
  # Homebrew) is in neither. Without the tool-bin symlink farm every test that
  # drives a yq-dependent script fails with "yq is required" on a machine that
  # has yq on PATH, which is a property of the machine rather than the code.
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq is not installed on this machine at all"
  fi
  run command -v yq
  [ "$status" -eq 0 ]
}

@test "the sandbox exposes only the named tools, not their neighbours" {
  # The tool-bin is a symlink farm rather than the directory yq was found in,
  # because that directory is typically ~/.local/bin -- which also holds
  # claude, codex, and herdr. Putting it on PATH wholesale un-hides binaries
  # that tests deliberately hide; project_claude_setup_seed.bats has a case
  # asserting behaviour when the claude CLI is *missing*, and it fails outright
  # when the sandbox leaks a real claude.
  run ls "$SANDBOX_TOOL_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"claude"* ]]
  [[ "$output" != *"codex"* ]]
  [[ "$output" != *"herdr"* ]]
}

@test "repository shell tooling avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin" \
    "$REPO_ROOT"/ai/*/install.sh "$REPO_ROOT/fonts/install.sh" "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}
