# Feature-Workflow Automation Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the user's three personal skills (blindspot-pass, polish-core, change-explainer) fire automatically at the right phases of the superpowers workflow, and hard-enforce git-worktree use before any file edits.

**Architecture:** A PreToolUse hook script denies Edit/Write/NotebookEdit when the target file's repo is on its default branch (fail-open on errors, with allowlist + env-var escape hatches). A SessionStart hook injects a short workflow contract. Both are wired in the dotfiles-managed `ai/claude/settings.json` (already symlinked to `~/.claude/settings.json`). Skill `description:` frontmatter is rewritten from "when the user explicitly asks" to phase-based triggers.

**Tech Stack:** POSIX-ish bash, `jq`, git, Bats (existing `tests/` conventions via `test_helper.bash`), Claude Code hooks (PreToolUse JSON `permissionDecision`, SessionStart stdout-as-context).

**Spec:** `docs/superpowers/specs/2026-07-19-feature-workflow-automation-design.md`

## Global Constraints

- The guard must **fail open**: any unexpected condition (no jq, no git, unparsable input, detached HEAD, not a repo) allows the edit. A broken hook must never lock the user out of editing.
- Escape hatches (exact names): file `~/.claude/worktree-guard-allow` (one repo path per line, `~` allowed, `#` comments), and env `CLAUDE_WORKTREE_GUARD=off`.
- Deny messages must name the remedy: create a worktree via `superpowers:using-git-worktrees`, or add the repo to `~/.claude/worktree-guard-allow`.
- Do not modify any superpowers plugin file, nor the `/polish`, `/polish-pr`, `/fix-pr`, `/review-prs` commands.
- No Stop-gate hook (explicitly out of scope).
- Tests follow existing conventions: `#!/usr/bin/env bats`, `load test_helper`, `setup_dotfiles_test` (which sandboxes `$HOME` and sets `PATH="$STUB_BIN:/usr/bin:/bin"`). Run with `bats tests` (see `Makefile`).

---

### Task 1: Worktree guard hook

**Files:**
- Create: `ai/claude/hooks/worktree-guard.sh` (executable)
- Test: `tests/worktree_guard.bats`

**Interfaces:**
- Consumes: PreToolUse stdin JSON: `{"tool_name": "...", "tool_input": {"file_path": "..."}}` (NotebookEdit uses `notebook_path`).
- Produces: on deny, stdout JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}` and exit 0; on allow, no output and exit 0. Task 3 wires this script's path into settings.json.

- [ ] **Step 1: Write the failing tests**

Create `tests/worktree_guard.bats` with exactly this content:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  GUARD="$REPO_ROOT/ai/claude/hooks/worktree-guard.sh"
  REPO="$TEST_ROOT/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=t \
    commit --quiet --allow-empty -m init
  INPUT_FILE="$TEST_ROOT/input.json"
}

write_input() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" >"$INPUT_FILE"
}

@test "denies edit on the default branch" {
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision"'* ]]
  [[ "$output" == *'"deny"'* ]]
  [[ "$output" == *'worktree'* ]]
}

@test "allows edit on a feature branch" {
  git -C "$REPO" checkout --quiet -b feature
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows edit outside any git repo" {
  mkdir -p "$TEST_ROOT/plain"
  write_input "$TEST_ROOT/plain/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows repo listed in the allowlist" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' "$REPO" >"$HOME/.claude/worktree-guard-allow"
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allowlist supports tilde paths and comments" {
  mkdir -p "$HOME/.claude" "$HOME/repo2"
  git -C "$HOME/repo2" init --quiet --initial-branch=main
  git -C "$HOME/repo2" -c user.email=t@example.com -c user.name=t \
    commit --quiet --allow-empty -m init
  printf '# comment\n~/repo2\n' >"$HOME/.claude/worktree-guard-allow"
  write_input "$HOME/repo2/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows when CLAUDE_WORKTREE_GUARD=off" {
  write_input "$REPO/file.txt"
  run env CLAUDE_WORKTREE_GUARD=off bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows on detached HEAD" {
  git -C "$REPO" checkout --quiet --detach
  write_input "$REPO/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fails open when jq is unavailable" {
  write_input "$REPO/file.txt"
  run env PATH="$STUB_BIN" bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denies via notebook_path for NotebookEdit" {
  printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' \
    "$REPO/nb.ipynb" >"$INPUT_FILE"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "denies for a new file in a not-yet-created subdirectory" {
  write_input "$REPO/newdir/sub/file.txt"
  run bash "$GUARD" <"$INPUT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/worktree_guard.bats`
Expected: all tests FAIL (guard script does not exist yet; `bash: .../worktree-guard.sh: No such file or directory`).

- [ ] **Step 3: Implement the guard**

Create `ai/claude/hooks/worktree-guard.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook: deny Edit/Write/NotebookEdit when the target file's repo is
# checked out on its default branch, so implementation happens in a worktree.
# Fails open: any unexpected condition allows the edit.
set -u

allow() { exit 0; }

[ "${CLAUDE_WORKTREE_GUARD:-on}" = "off" ] && allow

input=$(cat 2>/dev/null) || allow
command -v jq >/dev/null 2>&1 || allow
path=$(printf '%s' "$input" \
  | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' \
    2>/dev/null) || allow
[ -n "$path" ] || allow

# Nearest existing ancestor (the file or its directories may not exist yet).
dir="$path"
while [ ! -d "$dir" ]; do
  parent=$(dirname "$dir")
  [ "$parent" = "$dir" ] && allow
  dir="$parent"
done

command -v git >/dev/null 2>&1 || allow
repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || allow
repo_root=$(cd "$repo_root" && pwd -P) || allow

allowfile="$HOME/.claude/worktree-guard-allow"
if [ -f "$allowfile" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in "~"*) line="$HOME${line#\~}" ;; esac
    resolved=$(cd "$line" 2>/dev/null && pwd -P) || continue
    [ "$resolved" = "$repo_root" ] && allow
  done <"$allowfile"
fi

# Detached HEAD counts as "not on the default branch".
branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || allow

default=$(git -C "$dir" symbolic-ref --quiet --short \
  refs/remotes/origin/HEAD 2>/dev/null || true)
default=${default#origin/}
if [ -z "$default" ]; then
  if git -C "$dir" show-ref --verify --quiet refs/heads/main; then
    default=main
  elif git -C "$dir" show-ref --verify --quiet refs/heads/master; then
    default=master
  else
    allow
  fi
fi

[ "$branch" = "$default" ] || allow

reason="Edits are blocked on the default branch ($default) of $repo_root. \
Create a worktree first (superpowers:using-git-worktrees skill). If this repo \
is intentionally edited on its default branch, add its path to \
~/.claude/worktree-guard-allow."
jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
```

Then: `chmod +x ai/claude/hooks/worktree-guard.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/worktree_guard.bats`
Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ai/claude/hooks/worktree-guard.sh tests/worktree_guard.bats
git commit -m "feat: add worktree-guard PreToolUse hook"
```

---

### Task 2: Workflow-contract SessionStart hook

**Files:**
- Create: `ai/claude/feature-workflow.md`
- Create: `ai/claude/hooks/feature-workflow-contract.sh` (executable)
- Test: `tests/worktree_guard.bats` → add contract tests to a new file `tests/feature_workflow_contract.bats`

**Interfaces:**
- Consumes: nothing (SessionStart hook; stdin ignored).
- Produces: contract markdown on stdout, exit 0. Claude Code adds SessionStart stdout to session context. Task 3 wires the script path into settings.json.

- [ ] **Step 1: Write the failing test**

Create `tests/feature_workflow_contract.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  HOOK="$REPO_ROOT/ai/claude/hooks/feature-workflow-contract.sh"
}

@test "prints the feature workflow contract" {
  run bash "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"my:blindspot-pass"* ]]
  [[ "$output" == *"my:polish-core --fix"* ]]
  [[ "$output" == *"my:change-explainer"* ]]
  [[ "$output" == *"worktree"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/feature_workflow_contract.bats`
Expected: FAIL (hook script does not exist).

- [ ] **Step 3: Write the contract and the hook**

Create `ai/claude/feature-workflow.md`:

```markdown
## Feature workflow contract (user-defined, always applies)

For non-trivial feature work, follow this pipeline without being asked:

1. **Worktree before edits** — create one via superpowers:using-git-worktrees.
   A PreToolUse hook hard-blocks Edit/Write on a repo's default branch.
2. **my:blindspot-pass** — after brainstorming/requirements, before
   superpowers:writing-plans or any substantial implementation.
3. Implement per the superpowers workflow (plans, TDD, review).
4. **my:polish-core --fix** — after implementation is complete, before any PR.
5. **my:change-explainer** — after polish, before
   superpowers:finishing-a-development-branch / opening a PR.

Trivial changes (typos, one-line fixes, config tweaks) skip steps 2 and 5.
These personal skills complement superpowers; do not skip them because a
superpowers phase feels equivalent.
```

Create `ai/claude/hooks/feature-workflow-contract.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: inject the user's feature-workflow contract as context.
set -u
cat "$(cd "$(dirname "$0")/.." && pwd -P)/feature-workflow.md"
```

Then: `chmod +x ai/claude/hooks/feature-workflow-contract.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/feature_workflow_contract.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai/claude/feature-workflow.md ai/claude/hooks/feature-workflow-contract.sh tests/feature_workflow_contract.bats
git commit -m "feat: add SessionStart feature-workflow contract hook"
```

---

### Task 3: Wire hooks into settings.json and seed the allowlist

**Files:**
- Modify: `ai/claude/settings.json` (add top-level `"hooks"` key)
- Modify: `ai/claude/install.sh` (seed `~/.claude/worktree-guard-allow`)
- Test: `tests/ai_installers.bats` conventions apply; add seeding test to `tests/feature_workflow_contract.bats`

**Interfaces:**
- Consumes: script paths from Tasks 1–2 (`$HOME/.dotfiles/ai/claude/hooks/worktree-guard.sh`, `$HOME/.dotfiles/ai/claude/hooks/feature-workflow-contract.sh`).
- Produces: active hooks in every new Claude Code session; seeded allowlist exempting `~/.dotfiles`.

- [ ] **Step 1: Seed the live allowlist FIRST (ordering matters)**

The settings symlink is live; once committed, new sessions enforce the guard. Seed the allowlist before wiring so future sessions in `~/.dotfiles` (edited on main by design) are never blocked:

```bash
mkdir -p "$HOME/.claude"
grep -qxF "$HOME/.dotfiles" "$HOME/.claude/worktree-guard-allow" 2>/dev/null \
  || printf '%s\n' "$HOME/.dotfiles" >>"$HOME/.claude/worktree-guard-allow"
cat "$HOME/.claude/worktree-guard-allow"
```

Expected output includes: `/home/tng/.dotfiles`

- [ ] **Step 2: Write the failing installer-seeding test**

Append to `tests/feature_workflow_contract.bats`:

```bash
@test "install.sh seeds the worktree-guard allowlist with ~/.dotfiles" {
  stub_command claude 'exit 0'
  stub_command curl 'exit 0'
  run env HOME="$HOME" bash "$REPO_ROOT/ai/claude/install.sh"
  [ -f "$HOME/.claude/worktree-guard-allow" ]
  grep -qxF "$HOME/.dotfiles" "$HOME/.claude/worktree-guard-allow"
}

@test "install.sh does not duplicate an existing allowlist entry" {
  stub_command claude 'exit 0'
  stub_command curl 'exit 0'
  mkdir -p "$HOME/.claude"
  printf '%s\n' "$HOME/.dotfiles" >"$HOME/.claude/worktree-guard-allow"
  run env HOME="$HOME" bash "$REPO_ROOT/ai/claude/install.sh"
  [ "$(grep -cxF "$HOME/.dotfiles" "$HOME/.claude/worktree-guard-allow")" -eq 1 ]
}
```

Run: `bats tests/feature_workflow_contract.bats`
Expected: the two new tests FAIL (no seeding logic in install.sh yet).

- [ ] **Step 3: Add seeding to install.sh**

In `ai/claude/install.sh`, add this function after `link_file()`:

```bash
seed_worktree_guard_allowlist() {
  local allowfile="$HOME/.claude/worktree-guard-allow"
  local entry="$HOME/.dotfiles"
  if [[ "$check_only" == true ]]; then
    log_info "[dry-run] Would ensure $entry is in $allowfile"
    return 0
  fi
  mkdir -p "$HOME/.claude"
  if ! grep -qxF "$entry" "$allowfile" 2>/dev/null; then
    printf '%s\n' "$entry" >>"$allowfile"
    log_success "Added $entry to worktree-guard allowlist."
  fi
}
```

And call it in `main()` immediately after the two existing `link_file` calls (both the normal path and, as a dry-run log line, it is already handled by the `check_only` branch inside the function — also add `seed_worktree_guard_allowlist` to the `--check` branch after the `link_file` dry-run call):

```bash
  link_file "$DOTFILES_ROOT/claude/settings.json" "$HOME/.claude/settings.json" "settings"
  link_file "$DOTFILES_ROOT/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md" "global CLAUDE.md"
  seed_worktree_guard_allowlist
```

- [ ] **Step 4: Add the hooks key to settings.json**

In `ai/claude/settings.json`, add this top-level key (sibling of `"permissions"`):

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Edit|Write|NotebookEdit",
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.dotfiles/ai/claude/hooks/worktree-guard.sh"
        }
      ]
    }
  ],
  "SessionStart": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "$HOME/.dotfiles/ai/claude/hooks/feature-workflow-contract.sh"
        }
      ]
    }
  ]
}
```

Validate: `jq . ai/claude/settings.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 5: Run the full test suite**

Run: `bats tests`
Expected: all tests PASS (new tests plus no regressions in `ai_installers.bats`, which snapshots `$HOME` — the seeding function writes under `$HOME/.claude`, so re-check `assert_check_is_immutable` still passes because the `--check` branch only logs).

- [ ] **Step 6: Commit**

```bash
git add ai/claude/settings.json ai/claude/install.sh tests/feature_workflow_contract.bats
git commit -m "feat: wire worktree-guard and workflow-contract hooks into settings"
```

---

### Task 4: Rewrite skill trigger descriptions

**Files:**
- Modify: `ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md:3`
- Modify: `ai/marketplace/plugins/my/skills/polish-core/SKILL.md:3`
- Modify: `ai/marketplace/plugins/my/skills/change-explainer/SKILL.md:3`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: phase-triggered descriptions matching the contract injected in Task 2 (skill names `my:blindspot-pass`, `my:polish-core`, `my:change-explainer` must stay unchanged).

- [ ] **Step 1: Rewrite blindspot-pass description**

Replace the `description:` line in `ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md` with:

```yaml
description: Inspect the relevant repository and surface hidden constraints and unknown unknowns before implementation — current understanding, confirmed constraints, likely blind spots, and the decisions that could materially change the approach. Use proactively for any non-trivial feature: after requirements are understood (e.g. after brainstorming) and BEFORE writing an implementation plan or starting substantial implementation — do not wait to be asked. Also use when the user asks for a blind-spot pass, a pre-implementation risk review, or "what am I missing". Does not implement unless explicitly asked.
```

- [ ] **Step 2: Rewrite polish-core description**

Replace the `description:` line in `ai/marketplace/plugins/my/skills/polish-core/SKILL.md` with:

```yaml
description: Review code changes since a commit, classify correctness and maintainability findings, optionally apply only high-confidence safe fixes, and report remaining issues. Run proactively with --fix after completing non-trivial implementation work, before change-explainer or opening a PR — do not wait to be asked. Also use when the user asks to polish changed code, review a commit range, run a pre-PR quality pass, or invokes $my:polish-core.
```

- [ ] **Step 3: Rewrite change-explainer description**

Replace the `description:` line in `ai/marketplace/plugins/my/skills/change-explainer/SKILL.md` with:

```yaml
description: Inspect the final diff, relevant code, tests, and implementation-notes.md, then produce a reviewer-facing explanation of a completed change — what changed, how it works, key decisions, deviations, edge cases, verification actually performed, where reviewers should focus, plus five knowledge-check questions. Use proactively after completing a non-trivial change, after polish and before finishing the branch or opening a PR — do not wait to be asked. Also use when the user asks to explain, write up, or summarize a completed change for review.
```

- [ ] **Step 4: Verify frontmatter still parses**

Run: `head -5 ai/marketplace/plugins/my/skills/*/SKILL.md | grep -c 'description:'`
Expected: `7` (all seven skills still have exactly one description line; the three edited files each remain valid single-line YAML).

- [ ] **Step 5: Commit**

```bash
git add ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md ai/marketplace/plugins/my/skills/polish-core/SKILL.md ai/marketplace/plugins/my/skills/change-explainer/SKILL.md
git commit -m "feat: phase-based auto-triggering for blindspot/polish/change-explainer skills"
```

---

### Task 5: Manual end-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Verify the guard against the live repo state**

```bash
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
  "$HOME/.dotfiles/README.md" | bash ai/claude/hooks/worktree-guard.sh
```

Expected: no output (allowed — `~/.dotfiles` is in the seeded allowlist).

```bash
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
  "$HOME/some-other-main-branch-repo/file" | bash ai/claude/hooks/worktree-guard.sh
```

Use any real repo checked out on main; expected: deny JSON naming the worktree remedy. If no second repo exists, create a throwaway one under `/tmp` per the bats setup and test against it.

- [ ] **Step 2: Verify hooks register in a new session**

Ask the user to start a fresh `claude` session and run `/hooks` (or check that the contract text appears in context). Expected: PreToolUse and SessionStart entries listed; contract visible at session start. This cannot be verified from inside the current session (hooks snapshot at session start).

- [ ] **Step 3: Final suite + review**

Run: `bats tests` → all PASS. Inspect `git log --oneline` for the four commits; inspect `git diff` vs the branch base against the spec's component list.
