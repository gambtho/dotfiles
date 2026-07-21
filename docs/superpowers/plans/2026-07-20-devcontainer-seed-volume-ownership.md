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

Expected: all change-specific tests pass. Record the known unrelated
`shell loader configures healthy Vekil endpoints` isolation failure separately
if mise moves the real `curl` ahead of that test's stub.

- [ ] **Step 3: Run final AI validation**

Run: `bash bin/validate-ai --verbose`

Expected: `Errors: 0`, `Warnings: 0`, and `PASSED`.

### Task 4: Load the Vekil shell integration in container zsh sessions

**Files:**
- Modify: `tests/project_claude_setup_seed.bats`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`

- [ ] **Step 1: Add failing tests for sentinel recovery and shell behavior**

Extend the stale-sentinel test to run the extracted seed twice and assert this
exact line appears once in the container-local `~/.zshrc`:

```zsh
[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"
```

Add a test that seeds a minimal copy of the real `ai/vekil/env.zsh`, stubs the
readiness probe, launches zsh with `REMOTE_CONTAINERS=true`, and asserts:

```text
OPENAI_BASE_URL=http://host.docker.internal:1337/v1
ANTHROPIC_BASE_URL=http://host.docker.internal:1337
codex: function
```

- [ ] **Step 2: Run the focused test to verify RED**

Run: `bats tests/project_claude_setup_seed.bats`

Expected: the ownership/copy tests pass, while the new assertions fail because
the current seed template never writes `~/.zshrc`.

- [ ] **Step 3: Install the idempotent hook before the sentinel check**

After ownership repair and before the sentinel check, add:

```bash
VEKIL_ENV_HOOK='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
ZSHRC="$HOME/.zshrc"

touch "$ZSHRC"
if ! grep -Fqx "$VEKIL_ENV_HOOK" "$ZSHRC"; then
  printf '\n%s\n' "$VEKIL_ENV_HOOK" >>"$ZSHRC"
  echo "🌱 seed: configured Vekil shell integration"
fi
```

Document that the hook is container-local, loads both endpoint variables and
the `codex` function, and must be installed even when `.seeded` exists.

- [ ] **Step 4: Run focused and structural verification**

Run:

```bash
bats tests/project_claude_setup_seed.bats
shellcheck -x -S warning tests/project_claude_setup_seed.bats
bash bin/validate-ai --verbose
git diff --check
```

Expected: all commands exit 0; the focused suite reports all tests passing.

- [ ] **Step 5: Commit the Vekil integration**

```bash
git add tests/project_claude_setup_seed.bats \
  ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md
git commit -m "fix: load Vekil environment in devcontainers"
```

### Task 5: Isolate the existing Vekil shell-loader test from mise

**Files:**
- Modify: `tests/shell_loading.bats`

- [ ] **Step 1: Confirm the existing test is RED**

Run:

```bash
bats tests/shell_loading.bats \
  --filter "shell loader configures healthy Vekil endpoints" \
  --print-output-on-failure
```

Expected: FAIL with empty endpoint output because real mise activation moves
`/usr/local/bin/curl` ahead of the test's curl stub.

- [ ] **Step 2: Stub the unrelated runtime manager**

Immediately before the existing curl stub in that test, add:

```bash
stub_command mise 'exit 0'
stub_command curl 'exit 0'
```

This preserves the test's synthetic `PATH` while leaving production loader
ordering unchanged.

- [ ] **Step 3: Verify the isolated test and full suite**

Run:

```bash
bats tests/shell_loading.bats \
  --filter "shell loader configures healthy Vekil endpoints"
bats tests
```

Expected: the focused test passes and the full suite reports zero failures.

- [ ] **Step 4: Commit the test isolation fix**

```bash
git add tests/shell_loading.bats
git commit -m "test: isolate Vekil loader from mise activation"
```

### Task 6: Enforce the tracked devcontainer inspection-only boundary

**Files:**
- Modify: `tests/project_claude_setup_seed.bats`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`

- [ ] **Step 1: Add a failing policy regression test**

Add a Bats test that requires both skill documents to state that Dockerfiles,
`devcontainer.json`, and base Compose files are inspection-only, and requires
`SKILL.md` to contain both the local-write allowlist and the initial/final Git
status comparison.

- [ ] **Step 2: Run the focused test to verify RED**

Run: `bats tests/project_claude_setup_seed.bats`

Expected: the seed behavior tests pass and the new policy test fails because
the current sudo wording does not forbid Dockerfile edits.

- [ ] **Step 3: Tighten the skill boundary**

Replace wording that says the Dockerfile "must configure" sudo with wording
that permits only inspection of existing image/Dockerfile behavior. Add these
rules to `SKILL.md` and the reference:

- Never edit the Dockerfile, `devcontainer.json`, or base Compose files.
- Limit devcontainer writes to the ignored override, `local-seed.sh`, and
  `.git/info/exclude` entries for those files.
- Capture `git status --short` before writes and require the final status to
  match; report any new tracked devcontainer modification without reverting it.
- If passwordless sudo is absent, use only a local-override solution or report
  the setup as unsupported.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
bats tests/project_claude_setup_seed.bats
bats tests
bash bin/validate-ai --verbose
shellcheck -x -S warning tests/project_claude_setup_seed.bats tests/shell_loading.bats
git diff --check
```

Expected: all commands exit 0 and the full Bats suite has zero failures.

- [ ] **Step 5: Commit and push the PR update**

```bash
git add tests/project_claude_setup_seed.bats \
  ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md
git commit -m "fix: keep tracked devcontainer files inspection-only"
git push
```

### Task 7: Carry over safe login-shell troubleshooting from main

**Files:**
- Modify: `tests/project_claude_setup_seed.bats`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`

- [ ] **Step 1: Add a failing selective-copy policy test**

Require both skill documents to use `zsh -lic` for runtime verification and to
explain that empty endpoints or a raw Codex binary indicate a missing hook or
failed readiness probe. Assert that neither document contains the proposed
30-attempt readiness loop or a manual `$DOTFILES/**/*.zsh` glob loader.

- [ ] **Step 2: Run the focused test to verify RED**

Run: `bats tests/project_claude_setup_seed.bats`

Expected: FAIL because the reference currently uses `zsh -ic` and `SKILL.md`
does not include the runtime troubleshooting command.

- [ ] **Step 3: Add login-shell verification and bounded troubleshooting**

Use this command in both documents:

```bash
docker compose exec <service> zsh -lic 'print "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -v codex'
```

Explain that empty variables or a raw Codex binary mean the local zsh hook did
not load or Vekil's readiness probe failed. Direct diagnosis back to the local
seed hook and proxy `/readyz`; explicitly forbid editing a Dockerfile/baked rc,
loading all dotfiles by glob, or adding an unproven shell-startup retry loop.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
bats tests/project_claude_setup_seed.bats
bats tests
bash bin/validate-ai --verbose
shellcheck -x -S warning tests/project_claude_setup_seed.bats tests/shell_loading.bats
git diff --check
```

Expected: all commands exit 0 and main's uncommitted files remain unchanged.

- [ ] **Step 5: Commit and push the PR update**

```bash
git add tests/project_claude_setup_seed.bats \
  ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md
git commit -m "docs: add Vekil login-shell troubleshooting"
git push
```
