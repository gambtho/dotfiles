#!/usr/bin/env bats

# Coverage for bin/claude-link-project's --claude-dir-per-file mode.
#
# The behavior under test: skills/ and agents/ are linked as whole
# directories (Claude Code documents directory-level symlinks for a
# <skill-name> entry, but not a symlinked SKILL.md inside a real
# directory), while everything else stays per-file so collisions with
# tracked project content are still caught.

load test_helper

setup() {
  setup_dotfiles_test

  LINKER="$REPO_ROOT/bin/claude-link-project"
  OVERLAY_ROOT="$HOME/.dotfiles/projects"
  export LINKER OVERLAY_ROOT

  # jq is a hard requirement of --claude-dir-per-file (settings merge).
  command -v jq >/dev/null || skip "jq not available"
  # The linker resolves the overlay from the project directory's basename.
  PROJECT="$TEST_ROOT/demo"
  OVERLAY="$OVERLAY_ROOT/demo"
  export PROJECT OVERLAY
}

# Build an overlay containing a skill with a non-SKILL.md payload
# (scripts/), an agent, and a command.
make_overlay() {
  mkdir -p "$OVERLAY/.claude/skills/foo/scripts" \
    "$OVERLAY/.claude/agents" \
    "$OVERLAY/.claude/commands"
  echo skill >"$OVERLAY/.claude/skills/foo/SKILL.md"
  echo helper >"$OVERLAY/.claude/skills/foo/scripts/run.sh"
  echo agent >"$OVERLAY/.claude/agents/bar.md"
  echo command >"$OVERLAY/.claude/commands/baz.md"
  echo '{"permissions":{"allow":[]}}' >"$OVERLAY/.claude/settings.local.json"
}

make_project() {
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q .
}

run_linker() {
  DOTFILES="$HOME/.dotfiles" run "$LINKER" \
    --claude-dir-per-file --no-claude-md "$PROJECT"
}

@test "skills and agents are linked as directories, not per-file" {
  make_overlay
  make_project
  run_linker
  [ "$status" -eq 0 ]

  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
  assert_symlink_target "$PROJECT/.claude/agents" "$OVERLAY/.claude/agents"
}

@test "non-SKILL.md payloads are reachable through the directory link" {
  # A per-file walk over regular files linked SKILL.md but silently
  # dropped scripts/, leaving skills that reference missing helpers.
  make_overlay
  make_project
  run_linker

  [ "$(cat "$PROJECT/.claude/skills/foo/scripts/run.sh")" = helper ]
}

@test "commands stay per-file so tracked-file collisions are still caught" {
  make_overlay
  make_project
  run_linker

  [ ! -L "$PROJECT/.claude/commands" ]
  assert_symlink_target "$PROJECT/.claude/commands/baz.md" \
    "$OVERLAY/.claude/commands/baz.md"
}

@test "settings.local.json is copied, never symlinked" {
  make_overlay
  make_project
  run_linker

  [ -f "$PROJECT/.claude/settings.local.json" ]
  [ ! -L "$PROJECT/.claude/settings.local.json" ]
}

@test "a skill added after linking needs no re-run" {
  make_overlay
  make_project
  run_linker

  mkdir -p "$OVERLAY/.claude/skills/brand-new"
  echo new >"$OVERLAY/.claude/skills/brand-new/SKILL.md"
  [ -f "$PROJECT/.claude/skills/brand-new/SKILL.md" ]
}

@test "re-running is idempotent" {
  make_overlay
  make_project
  run_linker
  run_linker

  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "re-running does not prompt over formatting-only settings differences" {
  # The overlay ships compact JSON; the merge emits jq's pretty-printed
  # form. Comparing bytes made every re-run offer a semantically empty
  # diff, and with no TTY the read prompt hit EOF and aborted under set -e.
  make_overlay
  make_project
  printf '{"permissions":{"allow":["Bash(ls)"]}}' \
    >"$OVERLAY/.claude/settings.local.json"

  run_linker
  run_linker </dev/null

  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  [[ "$output" != *"proposed diff"* ]]
}

@test "a hand-formatted project settings file is left alone when equivalent" {
  make_overlay
  make_project
  printf '{"permissions":{"allow":["Bash(ls)"]}}' \
    >"$OVERLAY/.claude/settings.local.json"
  run_linker

  # Same values, different indentation than jq's output.
  printf '{\n    "permissions": {\n        "allow": ["Bash(ls)"]\n    }\n}\n' \
    >"$PROJECT/.claude/settings.local.json"

  run_linker </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "a legacy per-file tree is migrated to a directory link" {
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills/foo"
  ln -s "$OVERLAY/.claude/skills/foo/SKILL.md" \
    "$PROJECT/.claude/skills/foo/SKILL.md"

  run_linker
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "a legacy tree of dangling foreign-home links is migrated" {
  # The reported breakage: links created under the host's $HOME while the
  # overlay is read from the container's. An absolute-prefix match would
  # refuse exactly this case, so the migration matches on the
  # projects/<slug>/... suffix instead.
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills/foo"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills/foo/SKILL.md \
    "$PROJECT/.claude/skills/foo/SKILL.md"

  run_linker
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
  [ -z "$(find "$PROJECT/.claude" -xtype l)" ]
}

@test "migration refuses when a real file is present" {
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills/mine"
  echo "user content" >"$PROJECT/.claude/skills/mine/SKILL.md"

  run_linker
  [ ! -L "$PROJECT/.claude/skills" ]
  [ "$(cat "$PROJECT/.claude/skills/mine/SKILL.md")" = "user content" ]
}

@test "migration refuses when a link points outside the overlay" {
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills/foo"
  ln -s /etc/hostname "$PROJECT/.claude/skills/foo/SKILL.md"

  run_linker
  [ ! -L "$PROJECT/.claude/skills" ]
  assert_symlink_target "$PROJECT/.claude/skills/foo/SKILL.md" /etc/hostname
}

@test "a dangling link from another home is repointed" {
  # Links created under a different $HOME (host vs container) resolve
  # nowhere here. A broken link cannot be a deliberate choice, so it is
  # repaired rather than preserved.
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills \
    "$PROJECT/.claude/skills"

  run_linker
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "a valid link pointing elsewhere is left alone" {
  # The counterpart to the repair above: a link that actually resolves is
  # someone's deliberate choice and must not be silently rewritten.
  make_overlay
  make_project
  mkdir -p "$TEST_ROOT/other-skills" "$PROJECT/.claude"
  ln -s "$TEST_ROOT/other-skills" "$PROJECT/.claude/skills"

  run_linker
  assert_symlink_target "$PROJECT/.claude/skills" "$TEST_ROOT/other-skills"
}

@test "no dangling symlinks are left in the project" {
  make_overlay
  make_project
  run_linker

  [ -z "$(find "$PROJECT/.claude" -xtype l)" ]
}
