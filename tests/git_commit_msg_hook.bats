#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  HOOK="$REPO_ROOT/core/git/git-hooks.symlink/commit-msg"
  MESSAGE_FILE="$TEST_ROOT/COMMIT_EDITMSG"
  EXPECTED_FILE="$TEST_ROOT/expected"
}

@test "commit-msg removes co-author trailers case-insensitively" {
  cat >"$MESSAGE_FILE" <<'EOF'
Add global Git hook

Keep this body unchanged.

Co-authored-by: First Person <first@example.com>
  cO-AuThOrEd-By: Second Person <second@example.com>
Reviewed-by: Reviewer <reviewer@example.com>
CO-AUTHORED-BY: Third Person <third@example.com>
EOF

  cat >"$EXPECTED_FILE" <<'EOF'
Add global Git hook

Keep this body unchanged.

Reviewed-by: Reviewer <reviewer@example.com>
EOF

  run "$HOOK" "$MESSAGE_FILE"

  [ "$status" -eq 0 ]
  cmp "$EXPECTED_FILE" "$MESSAGE_FILE"
}

@test "commit-msg preserves non-trailer co-author text" {
  cat >"$MESSAGE_FILE" <<'EOF'
Document Co-authored-by: as ordinary prose

X-Co-authored-by: This is not the Git trailer
EOF

  cp "$MESSAGE_FILE" "$EXPECTED_FILE"

  run "$HOOK" "$MESSAGE_FILE"

  [ "$status" -eq 0 ]
  cmp "$EXPECTED_FILE" "$MESSAGE_FILE"
}

@test "gitconfig uses the managed global hooks directory" {
  run git config --file "$REPO_ROOT/core/git/gitconfig.symlink" --get core.hooksPath

  [ "$status" -eq 0 ]
  [ "$output" = "~/.git-hooks" ]
}
