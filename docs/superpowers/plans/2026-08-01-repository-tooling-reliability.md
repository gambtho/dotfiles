# Repository Tooling Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make checks hermetic, validate every published AI skill and tracked symlink, and consolidate symlink conflict behavior without changing caller-visible policy.

**Architecture:** Add one Git-aware file classifier for all Make verification targets and two shared link APIs in `bin/common.sh`: a non-mutating prompt resolver and a deterministic reconciler. Characterize all callers before migration, then strengthen `validate-ai` around consumer manifests and repository symlinks.

**Tech Stack:** Bash, GNU Make, Bats, Git, jq, ShellCheck, shfmt

---

### Task 1: Characterize existing link behavior

**Files:**
- Create: `tests/link_reconciliation.bats`
- Modify: `tests/ai_installers.bats`
- Test: `tests/link_reconciliation.bats`
- Test: `tests/ai_installers.bats`

- [ ] **Step 1: Write failing characterization tests for the shared contract**

Create `tests/link_reconciliation.bats` with setup that sources `bin/common.sh`, then add cases equivalent to:

```bash
@test "skip preserves a conflicting file" {
  printf 'local\n' >"$HOME/destination"
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config skip apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/destination")" = local ]
}

@test "replace changes a conflicting symlink" {
  printf 'managed\n' >"$TEST_ROOT/source"
  ln -s "$TEST_ROOT/old" "$HOME/destination"
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config replace apply
  [ "$status" -eq 0 ]
  assert_symlink_target "$HOME/destination" "$TEST_ROOT/source"
}

@test "backup never overwrites an existing backup" {
  printf 'local\n' >"$HOME/destination"
  printf 'older\n' >"$HOME/destination.backup"
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config backup apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/destination.backup")" = older ]
  run bash -c 'compgen -G "$1/destination.backup.*"' _ "$HOME"
  [ "$status" -eq 0 ]
}

@test "check mode describes replacement without mutation" {
  ln -s "$TEST_ROOT/old" "$HOME/destination"
  before="$(readlink "$HOME/destination")"
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config replace check
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/destination")" = "$before" ]
  [[ "$output" == *"Would replace"* ]]
}

@test "invalid policy and mode fail before mutation" {
  printf 'local\n' >"$HOME/destination"
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config prompt apply
  [ "$status" -eq 2 ]
  run reconcile_link "$TEST_ROOT/source" "$HOME/destination" config skip pretend
  [ "$status" -eq 2 ]
  [ "$(cat "$HOME/destination")" = local ]
}
```

Add focused installer cases to `tests/ai_installers.bats` proving Claude and Codex back up real-file conflicts, replace different symlinks, leave correct links unchanged, and keep `--check` immutable. Add bootstrap/relink characterization cases that source their scripts in source-only mode and prove noninteractive bootstrap skips while relink replaces only different symlinks.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
bats tests/link_reconciliation.bats tests/ai_installers.bats
```

Expected: new shared-helper tests fail because `reconcile_link` and `prompt_link_policy` do not exist; existing installer assertions pass.

- [ ] **Step 3: Commit characterization tests**

```bash
git add tests/link_reconciliation.bats tests/ai_installers.bats
git commit -m "test: characterize dotfile link reconciliation"
```

### Task 2: Implement the shared link APIs

**Files:**
- Modify: `bin/common.sh`
- Modify: `tests/link_reconciliation.bats`
- Test: `tests/link_reconciliation.bats`

- [ ] **Step 1: Implement minimal deterministic reconciliation**

Add these interfaces to `bin/common.sh`:

```bash
next_backup_path() {
  local destination="$1" candidate="${1}.backup" timestamp suffix=0
  [[ ! -e "$candidate" && ! -L "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  candidate="${destination}.backup.${timestamp}"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="${destination}.backup.${timestamp}.${suffix}"
  done
  printf '%s\n' "$candidate"
}

reconcile_link() {
  local source="$1" destination="$2" label="$3" policy="$4" mode="$5"
  [[ "$policy" == skip || "$policy" == replace || "$policy" == backup ]] || return 2
  [[ "$mode" == apply || "$mode" == check ]] || return 2
  if [[ -L "$destination" && "$(readlink "$destination")" == "$source" ]]; then
    log_info "$label already linked."
    return 0
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    case "$policy" in
      skip) log_info "Skipped $label at $destination"; return 0 ;;
      replace) [[ "$mode" == check ]] && { log_info "[dry-run] Would replace $label at $destination"; return; }; rm -rf -- "$destination" ;;
      backup)
        local backup
        backup=$(next_backup_path "$destination")
        [[ "$mode" == check ]] && { log_info "[dry-run] Would back up $label to $backup"; return; }
        mv -- "$destination" "$backup"
        ;;
    esac
  elif [[ "$mode" == check ]]; then
    log_info "[dry-run] Would link $source -> $destination"
    return 0
  fi
  ln -s -- "$source" "$destination"
  log_success "Linked $source to $destination"
}
```

Implement `prompt_link_policy` so it reads one character from `/dev/tty`, returns `skip`, `skip-all`, `replace`, `replace-all`, `backup`, or `backup-all` on stdout, and defaults to `skip` for any unknown response. Keep log output on stderr so command substitution captures only the policy.

- [ ] **Step 2: Run tests and verify GREEN**

```bash
bats tests/link_reconciliation.bats
shellcheck -x -S warning -e SC1091 bin/common.sh
```

Expected: all shared link tests pass and ShellCheck exits 0.

- [ ] **Step 3: Commit the shared primitive**

```bash
git add bin/common.sh tests/link_reconciliation.bats
git commit -m "refactor: centralize symlink reconciliation"
```

### Task 3: Migrate all four link callers

**Files:**
- Modify: `bin/bootstrap`
- Modify: `bin/relink`
- Modify: `ai/claude/install.sh`
- Modify: `ai/codex/install.sh`
- Modify: `tests/link_reconciliation.bats`
- Modify: `tests/ai_installers.bats`

- [ ] **Step 1: Replace caller-local helpers**

In bootstrap, retain `overwrite_all`, `backup_all`, and `skip_all`; translate them to `replace`, `backup`, or `skip`. When no global choice exists, call `prompt_link_policy`, cache `*-all`, strip the suffix, then call:

```bash
reconcile_link "$src" "$dst" "$(basename "$src")" "$policy" apply
```

In relink, select `replace` only for an existing symlink and `skip` for a real entry, then call the shared helper for both dotfiles and config directories. In Claude and Codex, use `backup` for any conflict and pass `check` or `apply` from their existing check-mode state.

- [ ] **Step 2: Run entry-point tests and verify GREEN**

```bash
bats tests/link_reconciliation.bats tests/ai_installers.bats tests/install_orchestration.bats
```

Expected: all caller compatibility tests pass.

- [ ] **Step 3: Commit caller migration**

```bash
git add bin/bootstrap bin/relink ai/claude/install.sh ai/codex/install.sh tests/link_reconciliation.bats tests/ai_installers.bats
git commit -m "refactor: share installer link policy"
```

### Task 4: Make verification file discovery hermetic

**Files:**
- Create: `bin/list-check-files`
- Create: `tests/check_file_discovery.bats`
- Modify: `Makefile`

- [ ] **Step 1: Write failing file-discovery tests**

Test that `bin/list-check-files bash`, `zsh`, `shellcheck`, and `shfmt` include tracked sources and a new untracked `bin/example-check-script`, exclude ignored `bin/.opencode/project.md`, and fail outside a Git checkout with `must run inside a Git checkout`.

- [ ] **Step 2: Verify RED**

```bash
bats tests/check_file_discovery.bats
```

Expected: FAIL because `bin/list-check-files` does not exist.

- [ ] **Step 3: Implement the NUL-delimited classifier and wire Make**

Implement a Bash script that verifies `git rev-parse --is-inside-work-tree`, combines:

```bash
{ git ls-files -z; git ls-files -z --others --exclude-standard; }
```

deduplicates with `sort -zu`, and filters the requested class. Preserve current roots and rules: extensionless files directly under `bin/` are Bash; `*.sh` under `ai core fonts languages platforms work` are Bash/ShellCheck/shfmt; `*.zsh` and `core/shell/*.symlink` are Zsh; `tests/test_helper.bash` is shfmt input. Update every Make target to consume `xargs -0` output from this helper.

- [ ] **Step 4: Verify GREEN and regression behavior**

```bash
bats tests/check_file_discovery.bats
make syntax lint
```

Expected: tests and both Make targets pass even with ignored fixture state present.

- [ ] **Step 5: Commit hermetic checks**

```bash
git add bin/list-check-files tests/check_file_discovery.bats Makefile
git commit -m "build: make repository checks hermetic"
```

### Task 5: Validate consumer manifests and tracked symlinks

**Files:**
- Modify: `bin/validate-ai`
- Modify: `tests/validate_ai.bats`
- Modify: `ai/marketplace/plugins/my/package.json`
- Delete: `ai/marketplace/plugins/my/skills/polish-core/references/rules`

- [ ] **Step 1: Write failing validator tests**

Create sandbox copies of the plugin and assert failure for a nonexistent Pi skill path, an omitted real skill, an escaping `../` path, and a broken tracked symlink. Assert the real repository passes after its manifest is complete.

- [ ] **Step 2: Verify RED**

```bash
bats tests/validate_ai.bats
```

Expected: new malformed-manifest and symlink cases pass through incorrectly or the real package fails because `new-api-client` is missing.

- [ ] **Step 3: Complete the Pi manifest and validator**

Replace the Pi list with all eight existing skill paths, sorted by skill name. Extend `validate-ai` to parse `.pi.skills[]` with jq, reject non-`./skills/*/SKILL.md` paths, compare declared and actual lists, and iterate `git ls-files -s -z` entries with mode `120000`, rejecting absolute or unresolved targets. Remove the obsolete compatibility symlink.

- [ ] **Step 4: Verify GREEN**

```bash
bats tests/validate_ai.bats tests/portability.bats
bash bin/validate-ai --verbose
```

Expected: all tests pass; validator reports 8 skills, valid manifests, and valid tracked symlinks.

- [ ] **Step 5: Commit validator hardening**

```bash
git add bin/validate-ai tests/validate_ai.bats ai/marketplace/plugins/my/package.json ai/marketplace/plugins/my/skills/polish-core/references/rules
git commit -m "fix: validate published AI skill inventory"
```

### Task 6: Verify tooling wave

**Files:**
- Modify: none

- [ ] **Step 1: Run complete verification**

```bash
make check
git diff --check HEAD~5..HEAD
git status --short
```

Expected: `make check` passes, diff check is clean, and only intentional implementation-notes state remains uncommitted if present.
