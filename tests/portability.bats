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

@test "repository shell tooling avoids Bash-4-only mapfile" {
  run rg -n '(^|[[:space:]])mapfile([[:space:]]|$)' "$REPO_ROOT/bin" \
    "$REPO_ROOT"/ai/*/install.sh "$REPO_ROOT/fonts/install.sh" "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 1 ]
}
