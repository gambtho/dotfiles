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

  # The hook invokes the real linker out of $DOTFILES. It sources common.sh and
  # log-helper as siblings — the same unguarded pattern every other bin/ script
  # uses — so a bin/ holding the linker alone aborts it under `set -e`, and the
  # hook then fails open with no overlay and nothing to explain why.
  export DOTFILES="$HOME/.dotfiles"
  mkdir -p "$DOTFILES/bin"
  cp "$REPO_ROOT/bin/claude-link-project" "$REPO_ROOT/bin/common.sh" \
    "$REPO_ROOT/bin/log-helper" "$DOTFILES/bin/"
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
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
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

@test "recovers the slug when the checkout directory is not the project name" {
  # A devcontainer bind-mounts the repo wherever its compose file says — /app,
  # /workspace — so the checkout that is 'demo' on the host is 'app' inside the
  # container, and basename() looks for a projects/app that will never exist.
  # The main checkout's own links name the real project; use them.
  mounted="$TEST_ROOT/app"
  git clone --quiet "$PROJECT" "$mounted"
  mkdir -p "$mounted/.claude"
  ln -s "$OVERLAY/.claude/skills" "$mounted/.claude/skills"
  linked="$TEST_ROOT/wt-mounted"
  git -C "$mounted" worktree add --quiet -b feature "$linked"
  [ ! -e "$linked/.claude/skills" ]

  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$linked")"

  [ "$status" -eq 0 ]
  assert_symlink_target "$linked/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "recovers the slug from a link that dangles in this environment" {
  # Both breakages at once: the mount path hides the project name AND the
  # links were made under a $HOME that does not exist here. readlink reads the
  # target text without resolving it, so the slug is still recoverable — which
  # is the only reason a container can repair host-made links at all.
  mounted="$TEST_ROOT/app"
  git clone --quiet "$PROJECT" "$mounted"
  mkdir -p "$mounted/.claude"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills \
    "$mounted/.claude/skills"

  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$mounted")"

  [ "$status" -eq 0 ]
  assert_symlink_target "$mounted/.claude/skills" "$OVERLAY/.claude/skills"
  [ -z "$(find "$mounted/.claude" -xtype l)" ]
}

@test "does not adopt a slug with no overlay behind it" {
  # Recovery must confirm the projects/ directory exists. Trusting the link
  # text alone would hand the linker a slug for an overlay that is not there,
  # turning a silent no-op into a failing linker run on every session start.
  mounted="$TEST_ROOT/app"
  git clone --quiet "$PROJECT" "$mounted"
  mkdir -p "$mounted/.claude"
  ln -s /home/ghost/.dotfiles/projects/gone/.claude/skills \
    "$mounted/.claude/skills"

  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$mounted")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink "$mounted/.claude/skills")" = \
    /home/ghost/.dotfiles/projects/gone/.claude/skills ]
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

@test "repairs a dangling per-file tree, then a worktree of it" {
  # The exact reported shape: the main checkout holds a per-file tree of
  # links into a $HOME that does not exist here, and a worktree taken
  # from it has no overlay at all. Both were broken at once.
  mkdir -p "$PROJECT/.claude/skills/foo"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills/foo/SKILL.md \
    "$PROJECT/.claude/skills/foo/SKILL.md"
  [ ! -e "$PROJECT/.claude/skills/foo/SKILL.md" ] # dangling

  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$PROJECT")"
  [ "$status" -eq 0 ]
  # Assert the directory link itself, not just readable content: a copy
  # would satisfy a content check while losing the whole point of the
  # change (new skills appearing with no re-run, payloads carried along).
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
  [ "$(cat "$PROJECT/.claude/skills/foo/SKILL.md")" = skill ]
  [ -z "$(find "$PROJECT/.claude" -xtype l)" ]

  git -C "$PROJECT" worktree add --quiet -b feature "$TEST_ROOT/wt-feature"
  run bash "$HOOK" <<<"$(printf '{"cwd":"%s"}' "$TEST_ROOT/wt-feature")"
  [ "$status" -eq 0 ]
  assert_symlink_target "$TEST_ROOT/wt-feature/.claude/skills" \
    "$OVERLAY/.claude/skills"
  [ "$(cat "$TEST_ROOT/wt-feature/.claude/skills/foo/SKILL.md")" = skill ]
}
