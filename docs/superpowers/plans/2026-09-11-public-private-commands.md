# Public/private command separation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export only six deliberately public commands through `bin/`, with repository maintenance and shared implementation files under `libexec/`.

**Architecture:** Prepare private-file discovery and rooted Make repair hints while the current layout still works. Then move the private files and all coupled callers, fixtures, and documentation in one atomic migration commit. Keep filenames, directory depth, interpreter choices, and provisioning behavior unchanged.

**Tech Stack:** Bash, zsh, Make, Bats, Python, TypeScript/Node; existing ShellCheck and shfmt gates.

**Spec:** `docs/superpowers/specs/2026-09-11-public-private-commands-design.md`

## Global Constraints

- “It must not be added to PATH.” (`libexec/`)
- “Private executables retain their executable bits; sourced libraries retain their existing source-only behavior.”
- “The six public commands keep their names, argument contracts, and exit-status behavior.”
- “No shell PATH ordering changes are part of this work.”
- “Do not introduce `BOOTSTRAP_ARGS` or another Make argument-forwarding interface.”
- “Do not leave compatibility wrappers, symlinks, or inert copies of moved files in `bin/`.”
- “Keep existing Linux, macOS, and WSL portability constraints; do not add Bash-version requirements or GNU-only command options.”
- “Do not run live provisioning to validate this migration.”
- Preserve source-only controls, the phase-state include guard, remote-installer consent, and the PR #29 installer argument guard.
- Do not edit historical plans/specs, `implementation-notes.md`, ignored generated outputs, machine-local configuration, third-party executable paths, or retired-installation recognition signatures.

## Review-risk decisions and evidence

1. **Discovery must precede relocation.** `bin/list-check-files:41–55` recognizes `bin/` and its `lib/` subtree explicitly; merely moving files would make shell checks incomplete. Extend the existing classifier rather than invent a second parser.
2. **Hints are executable user interfaces.** `core/git/identity-lib.sh:246–270` and `bin/git-identity:114–131` print maintenance paths from other repositories. Print shell-escaped, rooted Make invocations; do not add a helper dependency that breaks the doctor's older-library fallback.
3. **The actual move is one coupled deliverable.** Make/CI, topic installers, validators, and test fixtures depend on these paths. Do not commit a moved executable separately from its callers or leave wrappers to make intermediate commits green.
4. **Private does not mean non-executable.** `bin/validate-pi-security-runtime:67–80` invokes other executables; `bin/versions:246` invokes `"$0" list`. Preserve modes and keep the TypeScript module pair together.
5. **Make is not a bootstrap prerequisite.** `bin/bootstrap:389–438` installs prerequisites after startup; `Makefile:8–9` currently forwards no bootstrap flags. Document the explicit Bash fallback rather than adding Make argument plumbing.
6. **Tests contain structural dependencies, not only string paths.** Examples: `tests/dependency_pins.bats:371,412,448` copies the whole `bin/` directory; `tests/python/test_validate_pi_permission_config.py:9` constructs a path component-by-component. Changing only strings beginning `bin/` is insufficient.

Chosen alternative: `libexec/` beside `bin/`, preserving all moved filenames. Rejected: language-suffix renames, generated symlink inventories, recursive Make calls from scripts, and per-topic redistribution, because they add independent migration or runtime concerns.

## Working state and file responsibilities

Use the existing linked worktree `.claude/worktrees/libexec-separation`, branch `refactor/libexec-separation`. The approved spec is committed as `53afdc7`; implementation baseline is `2b5256b`. Inspect status before writes and preserve any unrelated changes.

The final public inventory is:

```text
dot-install
dot-update
gh
git-identity
git-worktree-gc
tmux-copy-url
```

Private files move one-for-one, `bin/<path>` → `libexec/<path>`:

```text
bootstrap
relink
versions
list-check-files
validate-ai
validate-pi-permission-config
validate-pi-security-runtime
validate-pi-webui
validate-pi-security-runtime.ts
pi-permission-pipeline-checks.ts
common.sh
log-helper
lib/artifacts.sh
lib/links.sh
lib/phases.sh
lib/system.sh
```

`libexec/common.sh` remains the shared aggregator; `libexec/lib/` retains the existing concern split. Public `bin/dot-install` must source `../libexec/common.sh`. Other public scripts remain at their current paths. There is no new runtime manifest or installer step for `libexec/`.

---

## Task 1: Extend existing discovery to private files

**Files:** Modify `bin/list-check-files` and `tests/check_file_discovery.bats`. No files move yet.

**Interfaces:** Consume the existing `list-check-files {bash|zsh|shellcheck|shfmt}` CLI. Preserve NUL-separated relative paths, exit statuses, ignored-file policy, and existing interpreter handling. Produce identical classification for corresponding `bin/` and `libexec/` paths.

- [ ] **1. Add an isolated fixture regression.** Keep the existing public-bin tests. Add this test to `tests/check_file_discovery.bats`; its fixture lives under the Bats temporary directory, not in the exported repository bin directory:

```bash
@test "private command discovery includes shell sources but excludes other interpreters and ignored state" {
  local fixture="$TEST_ROOT/private-discovery" class file
  mkdir -p "$fixture/bin" "$fixture/libexec/lib" "$fixture/libexec/.opencode"
  git init -q "$fixture"
  cp "$REPO_ROOT/bin/list-check-files" "$fixture/list-check-files"
  printf '.opencode/\n' >"$fixture/.gitignore"
  printf '#!/usr/bin/env bash\ntrue\n' >"$fixture/bin/public-probe"
  printf '#!/bin/sh\ntrue\n' >"$fixture/libexec/tracked-shell"
  printf '#!/usr/bin/env -S bash -e\ntrue\n' >"$fixture/libexec/untracked-shell"
  printf 'slice() { :; }\n' >"$fixture/libexec/lib/slice.sh"
  chmod 0644 "$fixture/libexec/lib/slice.sh"
  printf '#!/usr/bin/env -S python3 -B\n' >"$fixture/libexec/python-probe"
  printf '#!/usr/bin/env node\n' >"$fixture/libexec/node-probe"
  printf 'export {};\n' >"$fixture/libexec/module.ts"
  printf 'unknown shell-like content\n' >"$fixture/libexec/ambiguous"
  : >"$fixture/libexec/empty"
  printf '#!/bin/sh\nfalse\n' >"$fixture/libexec/.opencode/ignored.sh"
  git -C "$fixture" add bin/public-probe libexec/tracked-shell

  for class in bash shellcheck shfmt; do
    run bash -o pipefail -c 'cd "$1"; bash ./list-check-files "$2" | tr "\0" "\n"' \
      _ "$fixture" "$class"
    [ "$status" -eq 0 ]
    for file in bin/public-probe libexec/tracked-shell libexec/untracked-shell \
      libexec/lib/slice.sh libexec/ambiguous libexec/empty; do
      printf '%s\n' "$output" | grep -Fxq "$file"
    done
    for file in libexec/python-probe libexec/node-probe libexec/module.ts \
      libexec/.opencode/ignored.sh; do
      ! printf '%s\n' "$output" | grep -Fxq "$file"
    done
  done
}
```

- [ ] **2. Observe RED.** Run `bats --print-output-on-failure --filter 'private command discovery' tests/check_file_discovery.bats`. Expected: the executable returns successfully but omits the expected private shell paths.

- [ ] **3. Extend the existing predicate without changing its shebang parser.** Rename `is_direct_bin_shell` to `is_command_shell`, including all three callers. Replace only the path-selection expressions:

```bash
# Directory admission:
[[ "$path" == bin/* || "$path" == libexec/* ]] || return 1
# Relative path dispatch:
case "${path#*/}" in
  */*) [[ "$path" == bin/lib/*.sh || "$path" == libexec/lib/*.sh ]] && return 0 ;;
# In the existing direct-entry branch:
name=${path#*/}
```

Update the accompanying comment to explain public/private command directories. Retain all existing branches for env options, incompatible interpreters, ambiguous extensionless files, and shell-library inclusion.

- [ ] **4. Verify GREEN and existing behavior.** Run `bats tests/check_file_discovery.bats`, `make syntax lint`, and `git diff --check`. Inspect fixture cleanup; the new fixture is temporary, and existing repository probes must still be removed by teardown.

- [ ] **5. Commit the independently working preparation.** Stage only `bin/list-check-files` and `tests/check_file_discovery.bats`; commit as `test: cover private command shell discovery`.

## Task 2: Make identity repair hints rooted and runnable

**Files:** Modify `core/git/identity-lib.sh`, `bin/git-identity`, and `tests/git_identity.bats`.

**Interfaces:** Preserve `identity_slug_provision_hint(slug, prefix)` output intent and status, `explain_not_routed(key)` override diagnosis, and all doctor exit statuses. Produce repair commands runnable in Bash/zsh from any CWD. Make targets still point to the existing bin scripts at this stage.

- [ ] **1. Add behavior tests for both provisioning hints and doctor fallbacks.** Add the following fixture helper and tests. Keep the existing local/worktree-override tests, default-identity silence, and missing-half distinctions.

```bash
prepare_make_hint_fixture() {
  setup_shim_repo "$TEST_ROOT/unrelated" https://github.com/guarzo/repo.git
  local root="$TEST_ROOT/dotfiles space's checkout"
  mv "$DOTFILES" "$root"
  export DOTFILES="$root"
  cat >"$DOTFILES/Makefile" <<'MAKE'
.PHONY: bootstrap relink
bootstrap relink:
	@printf '%s\n' "$@" > invoked-target
MAKE
  cd "$TEST_ROOT/unrelated"
}

@test "provision hints run the intended Make target outside a spaced dotfiles root" {
  prepare_make_hint_fixture
  mkdir -p "$HOME/.gh-guarzo"
  local target hint
  for target in bootstrap relink; do
    if [ "$target" = relink ]; then
      printf '[user]\n\temail = guarzo@example.invalid\n' \
        >"$DOTFILES/core/git/gitconfig.guarzo.symlink"
    fi
    run bash -c '. "$1/core/git/identity-lib.sh"; identity_slug_provision_hint guarzo' _ "$DOTFILES"
    [ "$status" -eq 0 ]
    hint=${output##*run: }
    [[ "$hint" == make\ -C\ *\ "$target" ]]
    run bash -c "$hint"
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES/invoked-target")" = "$target" ]
    [ ! -e "$TEST_ROOT/unrelated/invoked-target" ]
  done
}

@test "doctor repair commands run Make from unrelated CWD with current and older libraries" {
  prepare_make_hint_fixture
  provision_guarzo_files
  local mode hint
  for mode in current older; do
    if [ "$mode" = older ]; then
      printf 'unset -f identity_config_override_scope\n' \
        >>"$DOTFILES/core/git/identity-lib.sh"
    fi
    run "$REPO_ROOT/bin/git-identity"
    [ "$status" -eq 6 ]
    hint=$(printf '%s\n' "$output" | grep 'Run: make -C')
    hint=${hint##*Run: }
    run bash -c "$hint"
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES/invoked-target")" = relink ]
    [ ! -e "$TEST_ROOT/unrelated/invoked-target" ]
  done
}
```

The Makefile recipe requires an actual tab. These tests execute only controlled fixture Make targets, never real provisioning.

- [ ] **2. Observe RED.** Run `bats --print-output-on-failure --filter 'provision hints run|doctor repair commands' tests/git_identity.bats`. Expected: existing hints do not supply rooted Make commands.

- [ ] **3. Replace the provisioning hint branches with shell-escaped Make commands.** Bash `printf %q` is available at the existing Bash 3.2 floor. Keep the separate gh-login hint unchanged:

```bash
printf '%s%s is authored but not linked -- run: make -C %q relink\n' \
  "$prefix" "$authored" "$IDENTITY_DOTFILES_ROOT"
printf '%sno identity file authored yet (prompts for "%s") -- run: make -C %q bootstrap\n' \
  "$prefix" "$slug" "$IDENTITY_DOTFILES_ROOT"
```

In each of the two generic branches of `explain_not_routed`, use:

```bash
printf 'No conditional include is routing this repository. Run: make -C %q relink\n' \
  "$IDENTITY_DOTFILES_ROOT"
```

Do not route this through a newly added identity-library helper: the doctor explicitly supports a library that predates a helper, as covered by `tests/git_identity.bats:351–368`. Keep `git config --local/--worktree --unset` advice for overrides.

- [ ] **4. Update existing hint expectations and verify.** Replace positive old `bin/relink`/`bin/bootstrap` hint assertions with expectations for the corresponding `make -C` command and target. Replace negative assertions so they continue to reject inappropriate Make repair advice. Update nearby explanatory comments, not historical documents. Run `bats tests/git_identity.bats`, `make syntax lint`, and `git diff --check`.

- [ ] **5. Commit.** Stage the three task files; commit as `fix: root identity repair hints in dotfiles Make targets`.

## Task 3: Move private files and migrate the full dependency closure

**Files:** The 16 moves listed above, plus these active callers and validation resources:

- Root/CI/docs: `Makefile`, `.github/workflows/check.yml`, `AGENTS.md`, `README.md`, `ai/README.md`, `tools/herdr/README.md`.
- Public entrypoint: `bin/dot-install`; `bin/git-identity` already updated by Task 2.
- Git/shell: `core/git/identity-lib.sh`, `core/git/gitconfig.symlink`, `core/git/gitconfig.local.symlink.example`, `core/git/gitconfig.secondary.symlink.example`, `core/git/install.sh`, `core/shell/install.sh`.
- Topic scripts: `fonts/install.sh`, `languages/mise/install.sh`, `languages/ruby/install.sh`, `languages/rust/install.sh`, `platforms/linux/background.sh`, `platforms/macos/install.sh`, `platforms/macos/set-defaults.sh`, `platforms/windows/wt-color-scheme.sh`, `tools/herdr/install.sh`, `work/install.sh`.
- AI scripts: `ai/pi/install.sh`, `ai/pi/webui/install.sh`, `ai/pi/webui/tailscale.sh`, `ai/pi/webui/rollback.sh`, `ai/pi/webui/custom-domain.sh`.
- Active comments: `config/mise/config.toml`, `config/versions.env`.
- Tests: `tests/check_file_discovery.bats`, `tests/repository_hygiene.bats`, `tests/shell_loading.bats`, `tests/portability.bats`, `tests/install_orchestration.bats`, `tests/dependency_pins.bats`, `tests/git_identity.bats`, `tests/git_commit_msg_hook.bats`, `tests/link_reconciliation.bats`, `tests/ai_installers.bats`, `tests/pi_permissions.bats`, `tests/pi_webui.bats`, `tests/validate_ai.bats`, `tests/feature_workflow_policy.bats`, `tests/python/test_validate_pi_permission_config.py`.

**Interfaces:** Consume Task 1's dual-directory discovery and Task 2's rooted Make hints. Produce the final six-command public inventory and the existing private interfaces at new explicit paths, without changing any installed-package contract.

- [ ] **1. Write the failing public-boundary test.** Replace the permissive namespace test in `tests/repository_hygiene.bats` with an exact inventory test; retain the reserved-name and retired-wrapper checks:

```bash
@test "public bin contains only the six approved executable files" {
  run bash -c '
    shopt -s dotglob nullglob
    for file in "$1"/bin/*; do printf "%s\n" "${file##*/}"; done | LC_ALL=C sort
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = $'dot-install\ndot-update\ngh\ngit-identity\ngit-worktree-gc\ntmux-copy-url' ]
  local name
  for name in dot-install dot-update gh git-identity git-worktree-gc tmux-copy-url; do
    [ -f "$REPO_ROOT/bin/$name" ]
    [ -x "$REPO_ROOT/bin/$name" ]
    [ ! -L "$REPO_ROOT/bin/$name" ]
  done
}
```

Add actual-layout coverage to `tests/check_file_discovery.bats` (its `list_files` helper will be relocated in step 3):

```bash
@test "all shipped private shell sources remain in the shell gates" {
  local class file
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    for file in bootstrap relink versions list-check-files validate-ai \
      validate-pi-security-runtime validate-pi-webui common.sh log-helper \
      lib/artifacts.sh lib/links.sh lib/phases.sh lib/system.sh; do
      printf '%s\n' "$output" | grep -Fxq "libexec/$file"
    done
    ! printf '%s\n' "$output" | grep -Fxq libexec/validate-pi-permission-config
    ! printf '%s\n' "$output" | grep -Fxq libexec/validate-pi-security-runtime.ts
    ! printf '%s\n' "$output" | grep -Fxq libexec/pi-permission-pipeline-checks.ts
  done
}
```

In `tests/shell_loading.bats`, add this assertion inside `assert_install_lookup` after sourcing the real config:

```bash
case ":$PATH:" in
  *":$HOME/.dotfiles/libexec:"* | *":$REPO_ROOT/libexec:"*) exit 1 ;;
esac
```

- [ ] **2. Observe RED before moving files.** Run `bats --print-output-on-failure --filter 'public bin contains|all shipped private' tests/repository_hygiene.bats tests/check_file_discovery.bats`. Expected: extra public entries and absent shipped private paths. The PATH exclusion is a preservation assertion, not expected to fail initially.

- [ ] **3. Perform the move and caller migration as one uncommitted unit.** Use `git mv` to preserve modes:

```bash
mkdir -p libexec
for name in bootstrap relink versions list-check-files validate-ai \
  validate-pi-permission-config validate-pi-security-runtime validate-pi-webui \
  validate-pi-security-runtime.ts pi-permission-pipeline-checks.ts common.sh log-helper lib; do
  git mv "bin/$name" "libexec/$name"
done
```

Apply precise edits, not a repository-wide replacement of `bin`. The move mapping above is the authoritative old/new path map. Important concrete forms are:

```bash
# Public bin/dot-install:
source "$(dirname "${BASH_SOURCE[0]}")/../libexec/common.sh"
# A topic installer two directories below the repository root:
source "$(dirname "$0")/../../libexec/common.sh"
# Private validator-to-validator call:
"$ROOT/libexec/validate-pi-permission-config" \
  --schema "$schema_file" \
  --config "$config_file"
```

Keep the validator's existing `schema_file` and `config_file` assignments and failure handling unchanged.

Specific dependency traps to resolve in this same step:

| Surface | Required edit |
|---|---|
| `libexec/common.sh` and `libexec/lib/*` | Keep sibling-relative sources and the include guard; update explanatory path references only. |
| `libexec/versions` | Change `"$ROOT/bin/common.sh"` to `"$ROOT/libexec/common.sh"`; retain `"$0" list` and root calculation. |
| `libexec/validate-pi-security-runtime` | Change its Python entrypoint and TS runner paths; keep installed-package roots and arguments unchanged. |
| `libexec/pi-permission-pipeline-checks.ts` | Change both `bash bin/validate-ai --verbose` strings to `bash libexec/validate-ai --verbose`; do not replace them with Make. |
| `tests/check_file_discovery.bats` | Call/copy `libexec/list-check-files`, including Task 1's isolated fixture; change moved-source expectations, but retain public-bin probes. |
| `tests/repository_hygiene.bats` | Change library exemptions to `libexec/common.sh`, `libexec/log-helper`, `libexec/lib/*`; call the relocated discovery script. Keep public `gh`/`git-identity` status-branching exceptions. |
| `tests/portability.bats` | Add `"$REPO_ROOT/libexec"` to the existing Bash-version scan. |
| `tests/install_orchestration.bats` | Keep copied `bin/dot-install` public; create `fixture/libexec/common.sh` for its stub dependency. Keep the isolated dot-update sibling fixture unchanged. |
| `tests/dependency_pins.bats` | Copy `libexec/` into the three versions-update fixtures and invoke `fixture/libexec/versions`; keep configuration and runtime fixture trees intact. |
| `tests/validate_ai.bats` | Create/copy/stage the validator under fixture `libexec/`, including its fixture Git index. |
| `tests/pi_webui.bats` | Move only the fixture's repository-owned validator directory/calls to `libexec/`; preserve node_modules/.bin, package bin paths, and system executables. |
| `tests/python/test_validate_pi_permission_config.py` | Change the constructed `"bin"` path component to `"libexec"`; keep the loader/module interface intact. |
| Git provenance producers | Update tracked format strings and comments for generated routes/owner maps; do not rewrite existing ignored outputs. |

Make recipes use these concrete replacements, preserving their current flags:

```make
bootstrap:
	bash libexec/bootstrap
relink:
	bash libexec/relink
pins:
	bash libexec/versions list
pins-check:
	bash libexec/versions check
pins-update:
	bash libexec/versions update
validate:
	bash libexec/validate-ai --verbose
```

In every syntax/lint pipeline change only `bin/list-check-files` to `libexec/list-check-files`; preserve `bash -o pipefail`, NUL handling, and tool arguments. CI's installed-runtime check calls `libexec/validate-pi-security-runtime` with the same explicit package roots.

- [ ] **4. Finish user-facing documentation with the caller migration.** README Quick Start uses `make bootstrap`; document `bash libexec/bootstrap` when Make is absent and `bash libexec/bootstrap --non-interactive --profile server` for advanced flags. Preserve `ALLOW_REMOTE_INSTALLERS=1 make bootstrap` consent guidance. Replace routine relink/pin/validation instructions with existing Make targets; for execution outside the checkout use `make -C "${DOTFILES:-$HOME/.dotfiles}" relink` or `make -C "${DOTFILES:-$HOME/.dotfiles}" bootstrap`. Document the six-command public inventory, `libexec/` ownership, removed old paths, and shell-cache refresh. Update `AGENTS.md` from a grandfathered generic-command allowance to the explicit public boundary and `make validate` guidance. Runtime-validation docs retain the explicit private CLI where they demonstrate its package-root flags. No new Make targets or argument variables are required.

- [ ] **5. Run focused GREEN verification and inspect the exact migration.**

```bash
bats tests/check_file_discovery.bats tests/repository_hygiene.bats \
  tests/shell_loading.bats tests/portability.bats tests/install_orchestration.bats \
  tests/dependency_pins.bats tests/git_identity.bats tests/git_commit_msg_hook.bats \
  tests/link_reconciliation.bats tests/ai_installers.bats tests/pi_permissions.bats \
  tests/pi_webui.bats tests/validate_ai.bats tests/feature_workflow_policy.bats
python3 -B -m unittest discover -s tests/python -p test_validate_pi_permission_config.py
make -n bootstrap relink pins pins-check pins-update validate
make syntax lint
git diff HEAD --check
git diff HEAD --summary
```

All commands must pass, with no lost executable modes. Inspect remaining old-path hits with a tracked-file search; expected hits are historical documents, deliberate migration explanations, or unrelated package/system paths, not active callers:

```bash
git grep -n -E 'bin/(bootstrap|relink|versions|list-check-files|validate-[a-z-]+|common\.sh|log-helper|lib/)' \
  -- ':!docs/superpowers/**' ':!implementation-notes.md' ':!ai/pi/*design*' ':!ai/pi/*plan*'
```

Do not make this broad search a zero-hit assertion: `/usr/bin` and migration prose are legitimate. Inspect component-built paths and relative sibling sources as well as literal matches. Use `git diff HEAD` because `git mv` stages the renames before subsequent edits.

- [ ] **6. Verify guardrails reject reintroduction.** Temporarily create `bin/bootstrap` as a dangling symlink, then separately an unexpected `bin/internal-probe/` directory; the exact inventory test must fail for each. Remove only those known temporary paths with `rm bin/bootstrap` / `rmdir bin/internal-probe`, and rerun the test to confirm GREEN. Do not run provisioning or leave either mutation in the commit.

- [ ] **7. Run polish and fresh final gates.** Use `polish-core --fix` on this task's staged and unstaged diff, inspect all safe fixes, and resolve concrete correctness findings without broadening the design. Run:

```bash
make check
libexec/validate-pi-security-runtime
git diff HEAD --check
```

The runtime check uses already available pinned packages. If missing, report the exact prerequisite and limitation; do not silently install packages or claim the gate passed. Run safe `bin/dot-install --help`, `bin/dot-update --help`, and lookup-only probes from a clean PATH with the authored shell configuration. Retain all no-argument provisioning checks inside their stubbed test fixtures.

- [ ] **8. Commit the complete migration.** Stage only the reviewed moves and caller/doc/test edits; commit as `refactor: separate public commands from private dotfiles tooling`. Do not amend the already-merged PR #29. Use `change-explainer` to report actual verification, migration consequences, and any untested platform; ask before pushing or opening a new PR.

## Adaptation and stop conditions

- If an active tracked caller outside the inventory is found, add its precise path to Task 3 and migrate it in the same commit; do not reinterpret third-party or historical references as callers.
- If a required runtime package is unavailable, report the blocked gate without altering dependency pins or runtime state.
- If changing root calculations, Make argument handling, installed-service behavior, or the public command set appears necessary, stop and revisit the approved design rather than silently expand scope.
- If baseline checks or hooks fail for unrelated reasons, stop and ask; never bypass hooks or repair unrelated code as part of the migration.

## Plan self-review coverage

- Spec criteria 1–2: Task 3 exact public inventory, one-for-one moves/modes, and shell PATH exclusion.
- Spec criteria 3 and 5: Task 2 executable rooted-hint tests; Task 3 Make/caller/fixture closure and focused behavior suites.
- Spec criterion 4: Task 1 synthetic tracked/untracked/ignored/interpreter regressions and Task 3 actual-library coverage plus portability exemptions.
- Spec criterion 6: Existing parent/child install/gh assertions remain enabled; no PATH reordering.
- Spec criterion 7: Task 3 active reference audit, documentation changes, and explicit historical/generated exclusions.
- Bootstrap fallback, source-only behavior, installer argument guard, runtime pipeline command shape, failure propagation, polish, and final gates are covered in Task 3.
