# Devcontainer Seed-Volume Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the project-setup skill's generated seed script initialize and recover root-owned Docker named volumes without skipping dotfiles seeding.

**Architecture:** Keep the existing Compose read-only seed mounts and container-local named volumes. Change only the documented `local-seed.sh` template and its surrounding prerequisites, with a Bats regression test that extracts and executes the real fenced template so documentation and tested behavior cannot drift.

**Tech Stack:** Bash, Bats, Markdown skill reference

---

### Task 1: Add executable regression coverage for the documented seed template

**Files:**
- Create: `tests/project_claude_setup_seed.bats`
- Test: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`

- [ ] **Step 1: Write a helper that extracts the `local-seed.sh` fenced block**

Create a Bats test file that loads `test_helper`, locates the reference document, and uses `awk` to copy the Bash fence immediately following `Write {WORKSPACE}/.devcontainer/local-seed.sh with:` into `$TEST_ROOT/local-seed.sh`. Rewrite only the two `/host-seed` assignments to point at `$TEST_ROOT/host-seed`, leaving the tested control flow unchanged.

- [ ] **Step 2: Add the fresh-volume regression test**

Create seed sources and pre-existing `$HOME/.claude` and `$HOME/.dotfiles` mountpoints, make both destinations non-writable, and install a `sudo` stub that records `chown` and restores user writability. Run the extracted script and assert:

```bash
[ "$status" -eq 0 ]
grep -F "chown -R $(id -u):$(id -g)" "$SUDO_LOG"
[ -f "$HOME/.claude/settings.json" ]
[ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
[ -f "$HOME/.claude/.seeded" ]
```

- [ ] **Step 3: Add the stale-sentinel recovery test**

Create `.seeded` before making both destinations non-writable, add source markers that must not be copied, run the extracted script, and assert that `sudo chown` ran while both source markers remain absent from the destinations.

- [ ] **Step 4: Run the focused test to verify RED**

Run: `bats tests/project_claude_setup_seed.bats`

Expected: FAIL because the current template never invokes `sudo chown`; the fresh-volume case also cannot copy into the non-writable Claude destination.

- [ ] **Step 5: Commit the failing regression test**

```bash
git add tests/project_claude_setup_seed.bats
git commit -m "test: cover devcontainer seed volume initialization"
```

### Task 2: Repair ownership before the sentinel and seed an empty mountpoint

**Files:**
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Test: `tests/project_claude_setup_seed.bats`

- [ ] **Step 1: Add the minimal ownership repair before the sentinel**

Insert this logic after the template variables and before the sentinel check:

```bash
echo "🌱 seed: repairing container-local volume ownership"
if [ "$(id -u)" -ne 0 ]; then
  sudo chown -R "$(id -u):$(id -g)" "$HOME/.claude" "$HOME/.dotfiles"
fi
```

This keeps root containers independent of `sudo`, while non-root devcontainer users repair both volume trees before any early exit.

- [ ] **Step 2: Replace the dead dotfiles guard**

Replace the existence check and whole-directory copy with an emptiness check and contents copy:

```bash
if [ -d "$SEED_DOTFILES" ] &&
   [ -z "$(find "$HOME/.dotfiles" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  cp -a "$SEED_DOTFILES/." "$HOME/.dotfiles/"
  echo "🌱 seed: copied ~/.dotfiles ($(du -sh "$HOME/.dotfiles" | cut -f1))"
fi
```

- [ ] **Step 3: Document the non-root privilege prerequisite and recovery invariant**

In `SKILL.md` Step 2 and the reference's user-discovery section, require evidence that a non-root container user has passwordless `sudo` (standard devcontainer images or an explicit Dockerfile provision). If absent, stop and offer a root-run Compose init service rather than emitting a seed script that cannot repair volumes. State that ownership repair always precedes the sentinel.

- [ ] **Step 4: Run the focused test to verify GREEN**

Run: `bats tests/project_claude_setup_seed.bats`

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Run structure and shell verification**

Run:

```bash
bash bin/validate-ai --verbose
shellcheck -x -S warning tests/project_claude_setup_seed.bats
git diff --check
```

Expected: each command exits 0; `validate-ai` prints `PASSED`.

- [ ] **Step 6: Commit the implementation**

```bash
git add ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md \
  tests/project_claude_setup_seed.bats
git commit -m "fix: initialize devcontainer seed volumes"
```

### Task 3: Review and verify the completed change

**Files:**
- Review: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Review: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`
- Review: `tests/project_claude_setup_seed.bats`

- [ ] **Step 1: Inspect the complete branch diff against the approved design**

Run: `git diff ec1aee306b6cb15295a705feceab164cb60a07ac..HEAD --check` and `git diff ec1aee306b6cb15295a705feceab164cb60a07ac..HEAD`

Expected: only the design, plan, focused test, and two skill documents change; no writable host mounts or unrelated behavior appear.

- [ ] **Step 2: Run the full repository test suite**

Run: `bats tests`

Expected: all Bats tests pass with zero failures.

- [ ] **Step 3: Run final AI validation**

Run: `bash bin/validate-ai --verbose`

Expected: `Errors: 0`, `Warnings: 0`, and `PASSED`.
