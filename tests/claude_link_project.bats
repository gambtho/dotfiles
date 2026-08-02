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

# Pin the stable link root at a path that does not exist, so links fall back to
# $HOME-absolute targets and the assertions below stay deterministic whether or
# not the machine running the suite has a real /opt/dotfiles.
run_linker() {
  DOTFILES="$HOME/.dotfiles" DOTFILES_LINK_ROOT="$TEST_ROOT/absent-root" \
    run "$LINKER" --claude-dir-per-file --no-claude-md "$PROJECT"
}

# Establish a stable root pointing at the test's dotfiles checkout, the way
# ensure_stable_link_root does on a real machine. Never touches real /opt.
setup_stable_root() {
  mkdir -p "$HOME/.dotfiles"
  STABLE_ROOT="$TEST_ROOT/opt-dotfiles"
  ln -sfn "$HOME/.dotfiles" "$STABLE_ROOT"
  export STABLE_ROOT
}

run_linker_stable() {
  DOTFILES="$HOME/.dotfiles" DOTFILES_LINK_ROOT="$STABLE_ROOT" \
    run "$LINKER" --claude-dir-per-file --no-claude-md "$PROJECT"
}

unlink_stable() {
  DOTFILES="$HOME/.dotfiles" DOTFILES_LINK_ROOT="$STABLE_ROOT" \
    run "$LINKER" --unlink "$PROJECT"
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

@test "an untracked skills dir is skipped without aborting the rest of the run" {
  # link_one dies on a real file/dir in the way, which is right for
  # CLAUDE.md. Applying it to skills/ meant one untracked directory
  # aborted everything after it: commands/ went unlinked and
  # settings.local.json was never written.
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills/mine"
  echo "user content" >"$PROJECT/.claude/skills/mine/SKILL.md"

  run_linker
  [ "$status" -eq 0 ]

  # The user's directory is untouched...
  [ ! -L "$PROJECT/.claude/skills" ]
  [ "$(cat "$PROJECT/.claude/skills/mine/SKILL.md")" = "user content" ]
  # ...and nothing was scattered inside it by the per-file walk.
  [ ! -e "$PROJECT/.claude/skills/foo" ]

  # Everything independent of skills/ still got linked.
  assert_symlink_target "$PROJECT/.claude/commands/baz.md" \
    "$OVERLAY/.claude/commands/baz.md"
  assert_symlink_target "$PROJECT/.claude/agents" "$OVERLAY/.claude/agents"
  [ -f "$PROJECT/.claude/settings.local.json" ]
}

@test "a tracked skills dir is still a hard collision" {
  make_overlay
  make_project
  mkdir -p "$PROJECT/.claude/skills"
  echo "tracked" >"$PROJECT/.claude/skills/SKILL.md"
  git -C "$PROJECT" add -f .claude/skills/SKILL.md
  git -C "$PROJECT" -c user.email=t@e.com -c user.name=t \
    commit -q -m add

  run_linker
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked in git"* ]]
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

# ── stable link root ─────────────────────────────────────────────────────────
#
# Overlay links stored an absolute, $HOME-derived target, so they resolved only
# on the machine that created them: a devcontainer bind-mounting the project at
# a different $HOME saw every one of them dangle — skills, agents, references,
# and CLAUDE.md alike. Links now go through a stable root that each environment
# points at its own checkout.

@test "links target the stable root when it resolves to the checkout" {
  make_overlay
  make_project
  setup_stable_root

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" \
    "$STABLE_ROOT/projects/demo/.claude/skills"
  assert_symlink_target "$PROJECT/.claude/commands/baz.md" \
    "$STABLE_ROOT/projects/demo/.claude/commands/baz.md"
  # Still resolves — indirection, not breakage.
  [ "$(cat "$PROJECT/.claude/skills/foo/SKILL.md")" = skill ]
}

@test "an absent stable root falls back to \$HOME-absolute targets with a warning" {
  make_overlay
  make_project

  run_linker
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
  [[ "$output" == *"Stable link root"* ]]
}

@test "a stable root pointing at a different checkout is not used" {
  # Guards the worktree hazard: a root aimed somewhere else must never become
  # the link target, or every overlay link resolves into the wrong tree.
  make_overlay
  make_project
  mkdir -p "$TEST_ROOT/other-dotfiles"
  STABLE_ROOT="$TEST_ROOT/opt-dotfiles"
  ln -sfn "$TEST_ROOT/other-dotfiles" "$STABLE_ROOT"
  export STABLE_ROOT

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" "$OVERLAY/.claude/skills"
}

@test "a host-absolute directory link is repointed at the stable root" {
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$PROJECT/.claude"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/skills \
    "$PROJECT/.claude/skills"

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/skills" \
    "$STABLE_ROOT/projects/demo/.claude/skills"
}

@test "a host-absolute nested per-file link is repointed at the stable root" {
  # commands/ stays per-file, so a link two levels deep is only reached by the
  # per-file path — the site a directory-link-only fix would have missed.
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$PROJECT/.claude/commands"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/commands/baz.md \
    "$PROJECT/.claude/commands/baz.md"

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/commands/baz.md" \
    "$STABLE_ROOT/projects/demo/.claude/commands/baz.md"
}

@test "overlay links inside a mixed directory are repointed in place" {
  # agents/ holding our links AND the project's own files can never become a
  # directory link (migration bails on the first real file), and the per-file
  # walk prunes the subtree — so nothing but the overlay-driven pre-pass ever
  # reaches these links. Without it they stay host-absolute forever, silently.
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$PROJECT/.claude/agents"
  ln -s /home/ghost/.dotfiles/projects/demo/.claude/agents/bar.md \
    "$PROJECT/.claude/agents/bar.md"
  echo "project agent" >"$PROJECT/.claude/agents/mine.md"

  run_linker_stable
  [ "$status" -eq 0 ]

  [ ! -L "$PROJECT/.claude/agents" ]
  assert_symlink_target "$PROJECT/.claude/agents/bar.md" \
    "$STABLE_ROOT/projects/demo/.claude/agents/bar.md"
  [ ! -L "$PROJECT/.claude/agents/mine.md" ]
  [ "$(cat "$PROJECT/.claude/agents/mine.md")" = "project agent" ]
}

@test "a foreign link at a managed destination is left alone with a warning" {
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$TEST_ROOT/other-skills" "$PROJECT/.claude"
  ln -s "$TEST_ROOT/other-skills" "$PROJECT/.claude/skills"

  run_linker_stable
  assert_symlink_target "$PROJECT/.claude/skills" "$TEST_ROOT/other-skills"
  [[ "$output" == *"leave it alone"* ]]
}

@test "unrelated links elsewhere in the project are untouched and unmentioned" {
  # Enumeration is overlay-driven, not a scan of <project>/.claude. wanderer
  # alone carries ~80 dependency links under .claude/worktrees/; a project-wide
  # scan would warn about every one of them on every run.
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$PROJECT/.claude/worktrees/wt" "$TEST_ROOT/dep"
  ln -s "$TEST_ROOT/dep" "$PROJECT/.claude/worktrees/wt/dep"

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/worktrees/wt/dep" "$TEST_ROOT/dep"
  [[ "$output" != *"worktrees"* ]]
}

@test "--unlink removes links made through the stable root" {
  make_overlay
  make_project
  setup_stable_root
  run_linker_stable
  [ "$status" -eq 0 ]

  unlink_stable
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/.claude/skills" ]
  [ ! -e "$PROJECT/.claude/commands/baz.md" ]
}

@test "references is linked as a directory" {
  # CLAUDE.md points at .claude/references; without a directory link the
  # per-file walk skips the existing one with a warning on every run.
  make_overlay
  make_project
  setup_stable_root
  mkdir -p "$OVERLAY/.claude/references"
  echo ref >"$OVERLAY/.claude/references/notes.md"

  run_linker_stable
  [ "$status" -eq 0 ]
  assert_symlink_target "$PROJECT/.claude/references" \
    "$STABLE_ROOT/projects/demo/.claude/references"
}

@test "re-running through the stable root is idempotent and quiet" {
  make_overlay
  make_project
  setup_stable_root
  run_linker_stable
  run_linker_stable </dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"repointed"* ]]
  [[ "$output" != *"leave it alone"* ]]
  [[ "$output" != *"leaving as-is"* ]]
  assert_symlink_target "$PROJECT/.claude/skills" \
    "$STABLE_ROOT/projects/demo/.claude/skills"
}
