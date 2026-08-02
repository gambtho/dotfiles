# Dotfiles Reliability Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unsafe and failure-prone dotfiles workflows with deny-by-default, ownership-aware, atomic, and fully gated implementations.

**Architecture:** Keep policy in executable units: repository-owned devcontainer templates rendered by one helper, one home-independent overlay ownership predicate, one atomic-output primitive for gallery files, and shared shell primitives for backup allocation and managed-link enumeration. Preserve callers' existing conflict policies while making every new behavior part of `make check`.

**Tech Stack:** Bash 3-compatible shell, Bats, Python 3 `unittest`, jq, mikefarah/yq, GitHub Actions.

---

## File map

- `project-claude-setup/templates/`: executable seed and Compose templates.
- `bin/claude-merge-compose-override`: safe rendering, merging, preview, backup, publish, rollback.
- `bin/claude-link-project`: suffix-owned unlinking.
- `build_gallery.py`: atomic derivatives and manifests.
- `setup-wt-claude-profiles.sh`: sourceable atomic settings publication.
- `bin/common.sh`: backup allocation and managed-link inventory.
- `bin/versions`: operator-owned Kubernetes policy.
- `Makefile`, CI, and discovery/tests: verification wiring.
- `implementation-notes.md`: temporary durable record; remove before completion.

### Task 1: Make the seed template executable source

**Files:**
- Create: `ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh`
- Modify: `tests/check_file_discovery.bats`
- Modify: `tests/project_claude_setup_seed.bats`
- Create: `implementation-notes.md`

- [x] **Step 1: Record approved constraints**

Create `implementation-notes.md` listing deny-by-default credentials, cross-home suffix ownership, operator-owned Kubernetes, and mandatory `make check` coverage.

- [x] **Step 2: Write failing template tests**

Add this discovery test:

```bash
@test "project seed template is covered by every bash source gate" {
  local expected="ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh"
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
  done
}
```

Change seed-test setup to copy the future template, retaining existing substitutions:

```bash
SEED_TEMPLATE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh"
cp "$SEED_TEMPLATE" "$SEED_SCRIPT"
```

Replace the brittle `total >= 10` assertion with per-document `count > 0` and `bash -n "$SEED_TEMPLATE"`.

- [x] **Step 3: Verify RED**

Run `bats tests/check_file_discovery.bats tests/project_claude_setup_seed.bats`.
Expected: failure because the template is absent.

- [x] **Step 4: Move the seed block and add command dispatch**

Move the exact Bash block following “Write the seed script at `{SEED_SCRIPT}`” into `templates/local-seed.sh`, preserving all lifecycle behavior. Append:

```bash
case "${1:-}" in
  --argv) shift; (($# > 0)) || exit 2; exec "$@" ;;
  --shell) shift; (($# == 1)) || exit 2; exec bash -lc -- "$1" ;;
  "") ;;
  *) printf 'seed: unknown command mode: %s\n' "$1" >&2; exit 2 ;;
esac
```

- [x] **Step 5: Verify GREEN and commit**

Run the focused Bats command, then:

```bash
git add implementation-notes.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh \
  tests/check_file_discovery.bats tests/project_claude_setup_seed.bats
git commit -m "refactor: make devcontainer seed executable source"
```

### Task 2: Replace the unsafe Compose helper

**Files:**
- Create: `ai/marketplace/plugins/my/skills/project-claude-setup/templates/compose-override.yml`
- Rewrite: `bin/claude-merge-compose-override`
- Create: `tests/claude_compose_override.bats`

- [x] **Step 1: Write failing default and opt-in policy tests**

Invoke the wished-for CLI in an isolated `HOME`:

```bash
run "$REPO_ROOT/bin/claude-merge-compose-override" \
  --service app --remote-user vscode --remote-home /home/vscode \
  --seed-file "$TEST_ROOT/local-seed.sh" \
  --seed-container-path /workspaces/demo/.devcontainer/local-seed.sh \
  --base-command-json '["sleep","infinity"]' --dry-run \
  "$TEST_ROOT/docker-compose.override.yml"
```

Assert read-only `/host-seed` sources; named `.claude`, `.dotfiles`, `.ssh`, gh, and OpenCode volumes; no host credentials by default; no whole-Claude/writable/dual-home binds; and an argv-safe command. With `--share-host-auth`, assert only SSH and gh become read-only host binds.

- [x] **Step 2: Write failing merge and validation tests**

Assert unrelated environment keys and `/cache:/cache` survive while old managed targets are replaced. Reject `null`, booleans, numbers, objects, `""`, `[]`, and mixed arrays as command JSON. Reject relative remote-home and seed-container paths before writes.

- [x] **Step 3: Write failing backup and rollback tests**

Precreate occupied `.backup` names and assert numeric/UTC fallback preservation. Put a one-shot `mv` stub on `PATH` that fails the first override publication, then assert both original files return and no stage remains.

- [x] **Step 4: Verify RED**

Run `bats tests/claude_compose_override.bats`.
Expected: legacy CLI rejection or unsafe mounts.

- [x] **Step 5: Implement renderer and transaction**

Validate command JSON with:

```bash
jq -e '(type == "string" and length > 0) or
  (type == "array" and length > 0 and all(.[]; type == "string"))' \
  <<<"$BASE_COMMAND_JSON" >/dev/null || die "invalid --base-command-json"
```

Use yq environment values, never shell interpolation. Remove existing entries by managed container target, preserve unrelated targets, then append one safe entry per target. Render array commands as `["bash", seed, "--argv", ...]` and scalar commands as `["bash", seed, "--shell", scalar]`. Source `common.sh`, use `next_backup_path`, stage both files beside destinations, publish seed then override, and rollback both on failure. Dry-run writes nothing.

- [x] **Step 6: Verify GREEN and commit**

```bash
bats tests/claude_compose_override.bats tests/project_claude_setup_seed.bats
bash -n bin/claude-merge-compose-override
shellcheck -x -S warning -e SC1091 bin/claude-merge-compose-override \
  ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh
git add bin/claude-merge-compose-override \
  ai/marketplace/plugins/my/skills/project-claude-setup/templates/compose-override.yml \
  tests/claude_compose_override.bats
git commit -m "feat: generate safe devcontainer seed mounts"
```

### Task 3: Rewire project-setup documentation

**Files:**
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`
- Modify: `tests/project_claude_setup_seed.bats`
- Modify: `tests/validate_ai.bats`

- [x] **Step 1: Write failing contracts**

Assert both helper bans are absent, Step 6 contains the full helper CLI and auth opt-in rule, the reference links both templates, remediation bullets occur once, and “Things to avoid” preserves the sanctioned `dockerComposeFile` exception.

- [x] **Step 2: Verify RED**

Run `bats tests/project_claude_setup_seed.bats tests/validate_ai.bats`.

- [x] **Step 3: Make the helper canonical**

Keep discovery, consent, repair detection, tracked-file exception, and verification in `SKILL.md`; replace manual generation with the CLI. Replace embedded YAML/seed blocks in the reference with exact template/helper links. Remove duplicate bullets and narrow the blanket prohibition to all `devcontainer.json` edits except the approved `dockerComposeFile` entry.

- [x] **Step 4: Verify GREEN and commit**

```bash
bats tests/project_claude_setup_seed.bats tests/validate_ai.bats
bash bin/validate-ai --verbose
git add ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
  ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md \
  tests/project_claude_setup_seed.bats tests/validate_ai.bats
git commit -m "docs: route devcontainer setup through safe generator"
```

### Task 4: Make overlay unlinking cross-home safe

**Files:**
- Modify: `bin/claude-link-project`
- Modify: `tests/claude_link_project.bats`

- [x] **Step 1: Write failing tests**

Cover owned same-home and cross-home top-level links; foreign slug preservation; cross-home `.claude`; dangling cross-home per-file links; exact cross-home shims; different-slug shims; and matching shims with a second line.

- [x] **Step 2: Verify RED**

Run `bats tests/claude_link_project.bats --filter 'unlink|cross-home'`.
Expected: absolute-prefix skips and foreign top-level removal.

- [x] **Step 3: Implement suffix ownership**

Reuse the migration invariant:

```bash
owned_overlay_target() {
  local target="$1" expected_suffix="$2"
  [[ "$target" == *"/$expected_suffix" ]]
}
```

Resolve with `readlink -m` when available; otherwise combine relative textual targets with the link directory without requiring existence. Match exact suffixes `projects/$NAME/CLAUDE.md`, `.claude`, or `.claude/$relative`. Shims require one line and the exact slug/path suffix.

- [x] **Step 4: Verify GREEN and commit**

```bash
bats tests/claude_link_project.bats
git add bin/claude-link-project tests/claude_link_project.bats
git commit -m "fix: unlink only owned project overlays"
```

### Task 5: Publish gallery outputs atomically

**Files:**
- Modify: `build_gallery.py`
- Create: `tests/python/test_build_gallery.py`
- Modify: `Makefile`, CI, `.gitignore`, `tests/repository_hygiene.bats`
- Delete: tracked `build_gallery.cpython-314.pyc`

- [ ] **Step 1: Write failing Python tests**

Load the module with minimal fake `PIL` modules. Test the wished-for API:

```python
def test_atomic_output_preserves_destination_when_writer_fails(self):
    destination = self.path / "video.mp4"
    destination.write_bytes(b"valid-old")
    def fail(stage):
        stage.write_bytes(b"partial")
        raise RuntimeError("transcode failed")
    with self.assertRaisesRegex(RuntimeError, "transcode failed"):
        gallery.publish_atomically(destination, fail)
    self.assertEqual(destination.read_bytes(), b"valid-old")
```

Add success, stage cleanup, empty ffmpeg rejection, retry, image writer, and manifest replacement tests.

- [ ] **Step 2: Wire RED tests into the real gate**

Add `python-test` to `.PHONY` and make `check: syntax lint test python-test validate`. Define:

```make
python-test:
	python3 -m unittest discover -s tests/python -p 'test_*.py'
```

Add `python3` to CI apt installation, ignore `*.py[cod]`/`__pycache__/`, and reject tracked bytecode in hygiene tests.

- [ ] **Step 3: Verify RED**

Run `make python-test`. Expected: `publish_atomically` absent.

- [ ] **Step 4: Implement atomic output**

Use same-directory `tempfile.mkstemp`, invoke a writer with the stage path, reject required empty output, `os.replace` on success, and unlink the stage in `finally`. Route photos, videos, thumbnails, and manifests through it.

- [ ] **Step 5: Verify GREEN and commit**

```bash
make python-test
bats tests/repository_hygiene.bats
make check
git add Makefile .github/workflows/check.yml .gitignore \
  ai/marketplace/plugins/my/skills/jekyll-media-gallery/scripts/build_gallery.py \
  tests/python/test_build_gallery.py tests/repository_hygiene.bats
git add -u ai/marketplace/plugins/my/skills/jekyll-media-gallery/scripts/__pycache__
git commit -m "fix: publish gallery outputs atomically"
```

### Task 6: Publish Windows Terminal settings collision-safely

**Files:**
- Modify: `platforms/windows/setup-wt-claude-profiles.sh`
- Create: `tests/windows_terminal_profiles.bats`

- [ ] **Step 1: Write failing source and publication tests**

Source the script with `WT_PROFILES_SOURCE_ONLY=1` outside WSL and assert that
no host discovery runs. Exercise a wished-for `publish_settings MERGED SETTINGS`
function with valid JSON fixtures. Precreate `settings.json.backup` and a fixed
UTC timestamp collision, then assert that the old settings survive at the next
`next_backup_path` name and the new settings replace the destination.

- [ ] **Step 2: Write failing preservation and fixture tests**

Stub `mv` to fail when publishing the staged settings file and assert that the
live destination and its backup remain valid and that no stage remains. Add a
full-flow fixture that supplies all three explicit overrides:

```bash
WT_SETTINGS_PATH="$TEST_ROOT/settings.json" \
WT_WINDOWS_USER=tester \
WT_WSL_DISTRO=Ubuntu \
bash "$REPO_ROOT/platforms/windows/setup-wt-claude-profiles.sh" \
  --project-root "$TEST_ROOT/projects" --yes
```

Assert that supplying only one or two overrides is rejected rather than mixed
with host discovery.

- [ ] **Step 3: Verify RED**

Run `bats tests/windows_terminal_profiles.bats`.
Expected: sourcing trips the WSL guard and `publish_settings` is unavailable.

- [ ] **Step 4: Extract main and implement atomic publication**

Source `bin/common.sh` relative to the script. Move argument parsing and all
executable workflow into `main`, ending the file with:

```bash
if [[ "${WT_PROFILES_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
```

When all three fixture variables are non-empty, bypass Windows-user, settings,
and distro discovery; reject a partial set. Implement `publish_settings` by
allocating a backup with `next_backup_path`, copying validated merged JSON to a
same-directory `mktemp` stage, moving the old destination to its backup, then
renaming the stage over the destination. On failure, restore the destination
and remove the stage. Preserve dry-run and confirmation behavior.

- [ ] **Step 5: Verify GREEN and commit**

```bash
bats tests/windows_terminal_profiles.bats
bash -n platforms/windows/setup-wt-claude-profiles.sh
shellcheck -x -S warning -e SC1091 platforms/windows/setup-wt-claude-profiles.sh
git add platforms/windows/setup-wt-claude-profiles.sh tests/windows_terminal_profiles.bats
git commit -m "fix: publish Windows Terminal settings atomically"
```

### Task 7: Make the Kubernetes channel operator-owned

**Files:**
- Modify: `bin/versions`
- Modify: `tests/dependency_pins.bats`

- [ ] **Step 1: Write the failing update-policy test**

Build an isolated fixture containing `bin/versions`, `bin/common.sh`,
`config/versions.env`, and `config/mise/config.toml`; stub `mise`, `git`, `curl`,
`make`, and `jq`. Make upstream report a different Kubernetes minor, run
`bin/versions update`, and assert:

```bash
[ "$(grep '^KUBERNETES_CHANNEL=' "$fixture/config/versions.env")" = \
  "KUBERNETES_CHANNEL=$KUBERNETES_CHANNEL" ]
[[ "$output" == *"operator-managed Kubernetes channel"* ]]
[[ "$output" == *"current: $KUBERNETES_CHANNEL"* ]]
[[ "$output" == *"upstream: v9.99"* ]]
```

Retain the existing check-mode assertion that reports channel drift.

- [ ] **Step 2: Verify RED**

Run `bats tests/dependency_pins.bats --filter 'Kubernetes|versions update'`.
Expected: `versions update` rewrites the fixture's channel.

- [ ] **Step 3: Remove automatic channel mutation**

In `update_pins`, query `latest_kubernetes_channel` only for the review message;
do not pass it to `update_pin`. Print current and upstream values with a concise
instruction to select a cluster-compatible minor deliberately. Leave mise,
Git-ref, artifact, check, full-gate, and diff behavior unchanged.

- [ ] **Step 4: Verify GREEN and commit**

```bash
bats tests/dependency_pins.bats
git diff -- config/versions.env
git add bin/versions tests/dependency_pins.bats
git commit -m "fix: keep Kubernetes channel operator-owned"
```

### Task 8: Centralize managed-link inventory

**Files:**
- Modify: `bin/common.sh`
- Modify: `bin/bootstrap`
- Modify: `bin/relink`
- Modify: `tests/link_reconciliation.bats`

- [ ] **Step 1: Write failing inventory tests**

Create fixture sources including `core/shell/zshrc.symlink`, a `*.symlink` path
containing spaces, `config/nvim/`, `config/tool with spaces/`, and excluded
copies beneath `archived/`, `.git/`, and `.claude/worktrees/`. Call the wished-for
API as paired NUL records:

```bash
while IFS= read -r -d '' source && IFS= read -r -d '' destination; do
  printf '%s\t%s\n' "$source" "$destination"
done < <(managed_link_pairs "$fixture" "$HOME")
```

Assert exact source/destination pairs and exclusions. Add integration assertions
that bootstrap and relink consume this function while their existing conflict
tests continue to prove their different policies.

- [ ] **Step 2: Verify RED**

Run `bats tests/link_reconciliation.bats`.
Expected: `managed_link_pairs` is not defined.

- [ ] **Step 3: Implement the shared NUL-delimited enumerator**

Add `managed_link_pairs DOTFILES_ROOT HOME_ROOT` to `bin/common.sh`. Emit each
managed source followed by its destination, both NUL-terminated. Own the
`archived`, `.git`, and `.claude/worktrees` exclusions and these mappings:

```text
<root>/**/<name>.symlink -> <home>/.<name>
<root>/config/<name>/   -> <home>/.config/<name>
```

Use the function in both callers without changing either `link_file` function,
prompting, backup, replacement, skip reporting, or stale-link cleanup.

- [ ] **Step 4: Verify GREEN and commit**

```bash
bats tests/link_reconciliation.bats tests/git_commit_msg_hook.bats
git add bin/common.sh bin/bootstrap bin/relink tests/link_reconciliation.bats
git commit -m "refactor: share managed dotfile inventory"
```

### Task 9: Correct operator documentation

**Files:**
- Modify: `README.md`
- Modify: `tests/repository_hygiene.bats`
- Modify: `tests/dependency_pins.bats`

- [ ] **Step 1: Write failing documentation contracts**

Assert Quick Start uses the repository's canonical `gambtho/dotfiles` owner and
explains that a pristine macOS bootstrap requires reviewing the Homebrew script
and running with `ALLOW_REMOTE_INSTALLERS=1`. Assert routine `dot-update` text
does not claim to advance Neovim plugins, and that the Neovim section documents
the explicit lockfile-update workflow. Assert dependency-pin text describes the
Kubernetes channel as operator-selected rather than automatically refreshed.

- [ ] **Step 2: Verify RED**

Run `bats tests/repository_hygiene.bats tests/dependency_pins.bats`.
Expected: stale clone owner, consent, Neovim, and Kubernetes wording fail.

- [ ] **Step 3: Update README**

Correct the clone URL, add the pristine-macOS consent command, describe
`dot-update` as convergence to the tracked Neovim lockfile, document the manual
lazy.nvim lockfile advancement and review flow, and state that `pins-update`
reports Kubernetes drift without changing the selected compatible channel.

- [ ] **Step 4: Verify GREEN and commit**

```bash
bats tests/repository_hygiene.bats tests/dependency_pins.bats
git add README.md tests/repository_hygiene.bats tests/dependency_pins.bats
git commit -m "docs: clarify bootstrap and update ownership"
```

### Task 10: Run changed-code polish

**Files:**
- Modify as needed: files changed by Tasks 1-9
- Modify: `implementation-notes.md`

- [ ] **Step 1: Run `my:polish-core --fix`**

Review all changes since `origin/main`, apply only high-confidence safe fixes,
inspect every resulting edit, and record any unresolved correctness or
maintainability findings in `implementation-notes.md`.

- [ ] **Step 2: Re-run affected verification**

Run the focused tests and linters for every file changed by polish. Do not keep
a polish edit whose relevant verification fails.

- [ ] **Step 3: Commit polish edits when present**

```bash
git add -- <only-files-changed-by-polish>
git commit -m "chore: polish reliability follow-ups"
```

If polish makes no changes, do not create an empty commit.

### Task 11: Final verification and reviewer handoff

**Files:**
- Delete: `implementation-notes.md`
- Modify if durable context warrants it: repository design/operations docs

- [ ] **Step 1: Review durable notes and remove the temporary file**

Fold any lasting operational or design facts into the normal documentation,
then delete `implementation-notes.md`. Confirm there are no placeholders,
debug output, staged temporary files, or accidental pin changes.

- [ ] **Step 2: Run complete fresh gates**

```bash
make check
make ai-check
git diff --check
```

Also inspect `git diff --stat origin/main...HEAD`, the complete diff, and
`git status --short --branch`. Confirm `python-test` is an actual prerequisite
of `check`, the seed template appears in bash/shellcheck/shfmt discovery, the
Compose rollback test covers failure after the first publish, and tracked
Python bytecode is absent.

- [ ] **Step 3: Run `my:change-explainer`**

Produce the reviewer-facing explanation from the final diff and verification
evidence. Include five knowledge-check questions because this cross-cutting
change is substantial.

- [ ] **Step 4: Commit final documentation cleanup**

```bash
git add -u implementation-notes.md
git add -- docs README.md
git diff --cached --check
git commit -m "docs: finalize reliability follow-ups"
```

Stage only paths actually changed; omit unchanged pathspecs. Then use
`superpowers:finishing-a-development-branch` to present integration options.
