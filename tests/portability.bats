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
  run rg -n '/(home|Users)/[^/[:space:]\"]+' "$REPO_ROOT/ai" \
    --glob '!*.md' --glob '!*.example.*' --glob '!*backup*'
  [ "$status" -eq 1 ]
}
