#!/usr/bin/env bats

# Coverage for the SessionStart overlay-sync hook.
#
# The hook re-links the personal overlay when a worktree lacks it, or when
# existing links point at a $HOME that does not exist in this environment
# (host-created links seen from inside a container, and vice versa).
#
# It must fail open: a broken hook must never stop a session from starting.

load test_helper

setup() {
  setup_dotfiles_test

  HOOK="$REPO_ROOT/ai/claude/hooks/overlay-sync.sh"
  export HOOK
  command -v jq >/dev/null || skip "jq not available"

  # The hook invokes the real linker out of $DOTFILES.
  export DOTFILES="$HOME/.dotfiles"
  mkdir -p "$DOTFILES/bin"
  cp "$REPO_ROOT/bin/claude-link-project" "$DOTFILES/bin/"
  chmod +x "$DOTFILES/bin/claude-link-project"

  PROJECT="$TEST_ROOT/demo"
  OVERLAY="$DOTFILES/projects/demo"
  export PROJECT OVERLAY

  mkdir -p "$OVERLAY/.claude/skills/foo"
  echo skill >"$OVERLAY/.claude/skills/foo/SKILL.md"
  echo '{"permissions":{"allow":[]}}' >"$OVERLAY/.claude/settings.local.json"

  mkdir -p "$PROJECT"
  git -C "$PROJECT" init --quiet --initial-branch=main
  git -C "$PROJECT" -c user.email=t@example.com -c user.name=t \
    commit --quiet --allow-empty -m init
}

run_hook() {
  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$1")"
}

@test "links the overlay into a fresh worktree" {
  linked="$TEST_ROOT/wt-feature"
  git -C "$PROJECT" worktree add --quiet -b feature "$linked"
  [ ! -e "$linked/.claude/skills" ]

  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$linked")"

  [ "$status" -eq 0 ]
  [ -e "$linked/.claude/skills/foo/SKILL.md" ]
}

@test "resolves the overlay slug from the main checkout, not the branch name" {
  # The worktree directory is named after the branch, so a naive
  # basename() would look for an overlay named 'wt-feature'.
  linked="$TEST_ROOT/wt-feature"
  git -C "$PROJECT" worktree add --quiet -b feature "$linked"

  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$linked")"

  [ "$status" -eq 0 ]
  assert_symlink_target "$linked/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "repairs a dangling link left by a foreign home" {
  mkdir -p "$PROJECT/.claude"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills \
    "$PROJECT/.claude/skills"
  [ ! -e "$PROJECT/.claude/skills" ] # dangling

  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT")"

  [ "$status" -eq 0 ]
  [ -e "$PROJECT/.claude/skills/foo/SKILL.md" ]
  [ -z "$(find "$PROJECT/.claude" -xtype l)" ]
}

@test "reports that a restart may be needed" {
  linked="$TEST_ROOT/wt-feature"
  git -C "$PROJECT" worktree add --quiet -b feature "$linked"

  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$linked")"

  [[ "$output" == *"SessionStart"* ]]
  [[ "$output" == *"restart"* ]]
}

@test "stays silent and writes nothing when links are already correct" {
  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]

  # Second run: overlay is linked, so there is nothing to do.
  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does not touch CLAUDE.md" {
  echo "project instructions" >"$PROJECT/CLAUDE.md"
  echo "personal notes" >"$OVERLAY/CLAUDE.md"

  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT")"

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/CLAUDE.md")" = "project instructions" ]
  [ ! -L "$PROJECT/CLAUDE.md" ]
}

@test "does nothing when no overlay exists for the project" {
  rm -rf "$OVERLAY"
  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$PROJECT/.claude/skills" ]
}

@test "does nothing outside a git repository" {
  mkdir -p "$TEST_ROOT/plain"
  run bash "$HOOK" <<<"$(printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$TEST_ROOT/plain")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "honors CLAUDE_OVERLAY_SYNC=off" {
  linked="$TEST_ROOT/wt-feature"
  git -C "$PROJECT" worktree add --quiet -b feature "$linked"

  CLAUDE_OVERLAY_SYNC=off run bash -c \
    "printf '{\"cwd\":\"$linked\"}' | bash '$HOOK'"

  [ "$status" -eq 0 ]
  [ ! -e "$linked/.claude/skills" ]
}

@test "fails open when jq is unavailable" {
  stub_command jq "exit 127"
  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]
}

@test "fails open on malformed input" {
  run bash "$HOOK" <<<"not json"
  [ "$status" -eq 0 ]
}

@test "fails open when the linker is missing" {
  rm -f "$DOTFILES/bin/claude-link-project"
  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]
}
