#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  REPO="$TEST_ROOT/repo"
  WORKTREE="$TEST_ROOT/worktree"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  printf 'initial\n' >"$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit -qm initial
  git -C "$REPO" worktree add -q -b feature "$WORKTREE"
}

check_root() {
  node - "$REPO_ROOT/ai/pi/extensions/worktree-guard.ts" "$1" "$2" "$HOME" <<'NODE'
const [modulePath, target, cwd, home] = process.argv.slice(2);
const { primaryCheckoutRoot } = await import(modulePath);
console.log(primaryCheckoutRoot(target, cwd, home) ?? "allowed");
NODE
}

@test "worktree guard identifies writes in a primary checkout" {
  run check_root file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard allows writes in a linked worktree" {
  run check_root file.txt "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$output" = allowed ]
}

@test "worktree guard attributes new files to their nearest repository" {
  run check_root new/missing/file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard follows file symlinks into a primary checkout" {
  ln -s "$REPO/file.txt" "$WORKTREE/primary-file.txt"

  run check_root primary-file.txt "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
}

@test "worktree guard honors the Pi allow file" {
  mkdir -p "$HOME/.pi"
  printf '%s # intentional exception\n' "$REPO" >"$HOME/.pi/worktree-guard-allow"

  run check_root file.txt "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = allowed ]
}
