#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "tracked symlinks are relative" {
  while IFS= read -r path; do
    [ -L "$REPO_ROOT/$path" ] || continue
    target="$(readlink "$REPO_ROOT/$path")"
    [[ "$target" != /* ]]
  done < <(git -C "$REPO_ROOT" ls-files -s | awk '$1 == 120000 {print $4}')
}

@test "portable config contains no personal home paths" {
  run rg -n '/home/tng|/Users/tng' "$REPO_ROOT/ai" \
    --glob '!*.md' --glob '!*.example.*' --glob '!*backup*'
  [ "$status" -eq 1 ]
}
