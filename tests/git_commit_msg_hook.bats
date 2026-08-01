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

@test "commit-msg preserves co-author text in the body" {
  cat >"$MESSAGE_FILE" <<'EOF'
Document attribution behavior

Co-authored-by: This body line documents the trailer format.
Keep this body line too.

Reviewed-by: Reviewer <reviewer@example.com>
Co-authored-by: Actual Author <author@example.com>
EOF

  cat >"$EXPECTED_FILE" <<'EOF'
Document attribution behavior

Co-authored-by: This body line documents the trailer format.
Keep this body line too.

Reviewed-by: Reviewer <reviewer@example.com>
EOF

  run "$HOOK" "$MESSAGE_FILE"

  [ "$status" -eq 0 ]
  cmp "$EXPECTED_FILE" "$MESSAGE_FILE"
}

@test "commit-msg atomically replaces the message file" {
  printf 'Commit subject\n' >"$MESSAGE_FILE"
  original_inode=$(ls -i "$MESSAGE_FILE" | awk '{print $1}')

  run "$HOOK" "$MESSAGE_FILE"

  [ "$status" -eq 0 ]
  replacement_inode=$(ls -i "$MESSAGE_FILE" | awk '{print $1}')
  [ "$replacement_inode" != "$original_inode" ]
}

@test "gitconfig uses the managed global hooks directory" {
  run git config --file "$REPO_ROOT/core/git/gitconfig.symlink" --get core.hooksPath

  [ "$status" -eq 0 ]
  [ "$output" = "~/.git-hooks" ]

  run bash "$REPO_ROOT/bin/relink"
  [ "$status" -eq 0 ]

  local repository="$TEST_ROOT/repository"
  run git init --quiet "$repository"
  [ "$status" -eq 0 ]

  run git -C "$repository" config --path --get core.hooksPath
  [ "$status" -eq 0 ]
  local hooks_path="$output"
  [ "$hooks_path" = "$HOME/.git-hooks" ]
  [ -x "$hooks_path/commit-msg" ]

  cat >"$MESSAGE_FILE" <<'EOF'
Verify installed hook

Co-authored-by: Installed Author <author@example.com>
EOF

  run "$hooks_path/commit-msg" "$MESSAGE_FILE"
  [ "$status" -eq 0 ]
  ! grep -qi '^[[:space:]]*co-authored-by:' "$MESSAGE_FILE"
}

@test "relink fails loudly when a real directory blocks a managed symlink" {
  # The regression that let this ship: ~/.git-hooks pre-existed as a real
  # directory (git-lfs creates hooks there), so link_file warned and moved on
  # while relink still exited 0. The commit-msg hook was never installed and
  # nothing in the output or exit status said so.
  mkdir -p "$HOME/.git-hooks"
  : >"$HOME/.git-hooks/pre-existing"

  run bash "$REPO_ROOT/bin/relink"

  [ "$status" -ne 0 ]
  [[ "$output" == *"left UNLINKED"* ]]
  [[ "$output" == *".git-hooks"* ]]
  # The blocking path is reported, not silently clobbered.
  [ -f "$HOME/.git-hooks/pre-existing" ]
}

@test "relink succeeds and reports nothing skipped on a clean home" {
  run bash "$REPO_ROOT/bin/relink"

  [ "$status" -eq 0 ]
  [[ "$output" != *"left UNLINKED"* ]]
  [ -x "$HOME/.git-hooks/commit-msg" ]
}
