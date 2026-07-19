# Dotfiles Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make shell startup profile-safe, installers honest and non-destructive, dependencies reproducible, configuration portable, and all critical behavior automatically verified.

**Architecture:** Replace repository-wide implicit discovery with explicit configuration boundaries. Put reusable installer behavior in `bin/common.sh`, keep platform manifests limited to system packages, and make mise the sole runtime owner. Build a Bats test harness around temporary homes and stubbed commands so shell startup and installers can be tested without changing the developer machine.

**Tech Stack:** Bash, Zsh, Bats Core, ShellCheck, shfmt, GNU Make, GitHub Actions, mise.

---

## File Map

**New files**

- `tests/test_helper.bash` — temporary-home setup, command stubs, and shared assertions.
- `tests/shell_loading.bats` — profile isolation, archive exclusion, and PATH safety tests.
- `tests/validate_ai.bats` — validator warning/error behavior tests.
- `tests/ai_installers.bats` — dry-run immutability and installer-linking tests.
- `tests/install_orchestration.bats` — required/optional phase result tests.
- `tests/dependency_pins.bats` — pin discovery, ownership, and command behavior tests.
- `tests/portability.bats` — tracked symlink and absolute-path checks.
- `tests/repository_hygiene.bats` — generated-file and archive-size policy checks.
- `core/shell/load-custom.zsh` — explicit core, platform, and selected-profile loader.
- `config/versions.env` — canonical non-mise repositories, refs, and release channels.
- `config/mise/config.toml` — canonical mise global tool configuration.
- `bin/versions` — list, check, and interactively update all dependency pins.
- `.github/workflows/check.yml` — Linux validation workflow.
- `ai/config-paths.example.toml` — documented template for machine-local Codex project trust entries.

**Modified files**

- `Makefile` — unified checks plus `pins`, `pins-check`, and `pins-update` targets.
- `core/shell/zshrc.symlink` — explicit loading and offline-safe plugin startup.
- `core/path.zsh` — remove current-directory command precedence.
- `profiles/work.zsh` — own work-only sourcing.
- `bin/validate-ai` — safe counters and deterministic exit behavior.
- `ai/opencode/install.sh` — make `--check` side-effect free.
- `ai/codex/install.sh` — align dry-run behavior.
- `ai/copilot/install.sh` — align dry-run behavior.
- `ai/claude/install.sh` — gate remote installation and preserve linking-only operation.
- `ai/litellm/install.sh` — gate remote installation and preserve linking-only operation.
- `bin/common.sh` — phase tracking and remote-installer policy helpers.
- `bin/install` — honest required/optional phase orchestration.
- `bin/dot-update` — install repository-declared pins without discovering or bumping versions.
- `bin/bootstrap` — non-interactive flags and explicit remote-install consent.
- `languages/mise/install.sh` — install mise itself, then delegate tool installation to native mise commands.
- `bin/common.sh` — stop sourcing custom mise version logic.
- `platforms/macos/brewfile` — remove mise-owned runtimes and stale duplicates.
- `platforms/linux/ubuntu_apt` — remove mise-owned runtimes.
- `platforms/linux/wsl_apt` — remove mise-owned runtimes.
- `platforms/linux/server_apt` — remove mise-owned runtimes.
- `work/install.sh` — remove mutable raw-script installs and stale Kubernetes pinning.
- `ai/codex/config.toml` — remove machine-specific project paths.
- `ai/claude/settings.json` — remove machine-specific marketplace path.
- `ai/marketplace/install.sh` — generate user-specific paths at install time.
- `README.md` — document profiles, safety flags, ownership, checks, and migration.
- `.gitignore` — ignore generated local config and preserve tracked plan documents.

**Removed files**

- `platforms/linux/aptfile` — obsolete duplicate of `ubuntu_apt`.
- `ai/claude/settings.json.backup-20260511T144808Z` — machine-specific backup.
- `archived/misc/tree_tunnel.jpeg` — large unrelated binary.
- `archived/misc/tree_tunnel_ai.jpg` — large unrelated binary.
- `archived/misc/dot-update.png` — obsolete screenshot.
- Tracked absolute symlinks `ai/opencode/agents/ux-react.md` and `ai/copilot/agents/ux-react.md`; installers recreate portable links.
- `bin/mise-helper` — redundant version parsing and latest-version comparison logic.
- `languages/mise/lang.sh` — redundant per-language dispatcher.
- `languages/mise/mise.local.toml.symlink` — nonstandard config location replaced by `config/mise/config.toml`.

---

### Task 1: Establish the Test and Validation Harness

**Files:**
- Create: `tests/test_helper.bash`
- Modify: `Makefile:1`
- Modify: `platforms/macos/brewfile:49`
- Modify: `platforms/linux/ubuntu_apt`
- Modify: `platforms/linux/wsl_apt`
- Modify: `platforms/linux/server_apt`

- [ ] **Step 1: Add Bats and formatting tools to system manifests**

Add `brew "bats-core"` and `brew "shfmt"` beside `shellcheck` in the Brewfile. Add sorted `bats`, `shellcheck`, and `shfmt` entries to each Linux manifest.

- [ ] **Step 2: Create the shared Bats helper**

```bash
setup_dotfiles_test() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  export TEST_ROOT="$BATS_TEST_TMPDIR/test-root"
  export HOME="$TEST_ROOT/home"
  export STUB_BIN="$TEST_ROOT/bin"
  mkdir -p "$HOME" "$STUB_BIN"
  export PATH="$STUB_BIN:/usr/bin:/bin"
}

stub_command() {
  local name="$1"
  shift
  cat >"$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$STUB_BIN/$name"
}

assert_file_absent() {
  [ ! -e "$1" ]
}

assert_symlink_target() {
  [ -L "$1" ]
  [ "$(readlink "$1")" = "$2" ]
}
```

- [ ] **Step 3: Add Make targets**

```make
.PHONY: check syntax lint test validate

check: syntax lint test validate

syntax:
	@{ find bin -type f -not -name '*.zsh' -print0; find ai core fonts languages platforms work -type f -name '*.sh' -print0; } | \
		bash -c 'while IFS= read -r -d "" file; do bash -n "$$file" || exit 1; done'
	@find core languages platforms profiles tools work -type f \( -name '*.zsh' -o -path 'core/shell/*.symlink' \) -print0 | \
		bash -c 'while IFS= read -r -d "" file; do zsh -n "$$file" || exit 1; done'

lint:
	shellcheck -x $$(find bin -type f -not -name '*.zsh'; find ai core fonts languages platforms work -type f -name '*.sh')
	shfmt -d -i 2 -ci $$(find bin ai core fonts languages platforms work -type f -name '*.sh') tests/test_helper.bash

test:
	bats tests
```

- [ ] **Step 4: Run the harness and record the expected initial failures**

Run: `make syntax`

Expected: PASS.

Run: `make lint`

Expected: FAIL until later tasks normalize existing shell scripts. Note: shfmt runs only over `*.sh` scripts and `tests/test_helper.bash`; `.bats` files are excluded because shfmt cannot parse the Bats `@test` construct.

Run: `make test`

Expected: PASS with zero tests discovered or the helper ignored as a non-`.bats` file.

- [ ] **Step 5: Commit the harness**

```bash
git add Makefile tests/test_helper.bash platforms/macos/brewfile platforms/linux/ubuntu_apt platforms/linux/wsl_apt platforms/linux/server_apt
git commit -m "test: add dotfiles validation harness"
```

---

### Task 2: Centralize Pin Discovery and Updates

**Files:**
- Create: `config/versions.env`
- Create: `bin/versions`
- Create: `tests/dependency_pins.bats`
- Modify: `Makefile:1`
- Modify: `README.md`

- [ ] **Step 1: Write failing pin ownership and listing tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "versions list shows mise and non-mise pins" {
  run bash "$REPO_ROOT/bin/versions" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise go 1.25.7"* ]]
  [[ "$output" == *"git prezto 9739c8bdc9c288ffc134c209225543180e32ff69"* ]]
  [[ "$output" == *"channel kubernetes v1.28"* ]]
}

@test "non-mise pins have one canonical manifest" {
  run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL)=' "$REPO_ROOT" \
    --glob '!docs/**' --glob '!tests/**'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/config/versions.env" ]
}

@test "versions rejects unknown commands" {
  run bash "$REPO_ROOT/bin/versions" unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/dependency_pins.bats`

Expected: FAIL because the manifest and command do not exist and mise still contains floating versions.

- [ ] **Step 3: Add the canonical non-mise pin manifest**

```bash
PREZTO_REPO=https://github.com/sorin-ionescu/prezto.git
PREZTO_REF=9739c8bdc9c288ffc134c209225543180e32ff69
ZSH_DEFER_REPO=https://github.com/romkatv/zsh-defer.git
ZSH_DEFER_REF=53a26e287fbbe2dcebb3aa1801546c6de32416fa
KUBERNETES_CHANNEL=v1.28
```

Keep runtime and CLI tool versions in `config/mise/config.toml`; do not copy those values into `config/versions.env`.

> **Ordering note:** Until Task 8 runs, `languages/mise/mise.local.toml.symlink` still contains floating `node = "latest"` and `"npm:tree-sitter-cli" = "latest"`. That is expected and correct at this point — `list_mise` will print those floating values, but this task's tests only assert `go`, `prezto`, and `kubernetes`, so they pass. Do not pin Node or tree-sitter here; Task 8 replaces the whole mise config and enforces concrete versions.

- [ ] **Step 4: Create the pin-management command**

```bash
#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PINS_FILE="$ROOT/config/versions.env"
MISE_FILE="$ROOT/languages/mise/mise.local.toml.symlink"

source "$PINS_FILE"

usage() {
  echo "Usage: bin/versions {list|check|update}" >&2
}

list_mise() {
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^\[tools\]$/ { in_tools=1; next }
    /^\[/ { in_tools=0 }
    in_tools && /^[[:space:]]*[^#].*=/ {
      key=$0
      value=$0
      sub(/=.*/, "", key)
      sub(/^[^=]+=[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      key=trim(key)
      value=trim(value)
      gsub(/^"|"$/, "", key)
      gsub(/^"|"$/, "", value)
      print "mise", key, value
    }
  ' "$MISE_FILE"
}

list_pins() {
  list_mise
  printf 'git prezto %s\n' "$PREZTO_REF"
  printf 'git zsh-defer %s\n' "$ZSH_DEFER_REF"
  printf 'channel kubernetes %s\n' "$KUBERNETES_CHANNEL"
}

check_git_ref() {
  local name="$1" repo="$2" current="$3" latest
  latest="$(git ls-remote "$repo" HEAD | awk 'NR == 1 { print $1 }')"
  if [[ "$current" == "$latest" ]]; then
    printf 'current git %s %s\n' "$name" "$current"
  else
    printf 'outdated git %s %s -> %s\n' "$name" "$current" "$latest"
  fi
}

latest_kubernetes_channel() {
  local stable
  stable="$(curl --fail --silent --show-error --location https://dl.k8s.io/release/stable.txt)"
  printf '%s\n' "${stable%.*}"
}

check_pins() {
  mise outdated --bump || true
  check_git_ref prezto "$PREZTO_REPO" "$PREZTO_REF"
  check_git_ref zsh-defer "$ZSH_DEFER_REPO" "$ZSH_DEFER_REF"
  local latest_channel
  latest_channel="$(latest_kubernetes_channel)"
  if [[ "$KUBERNETES_CHANNEL" == "$latest_channel" ]]; then
    printf 'current channel kubernetes %s\n' "$KUBERNETES_CHANNEL"
  else
    printf 'outdated channel kubernetes %s -> %s\n' "$KUBERNETES_CHANNEL" "$latest_channel"
  fi
}

update_pin() {
  local key="$1" value="$2" temporary
  temporary="$(mktemp)"
  awk -F= -v key="$key" -v value="$value" '
    $1 == key { print key "=" value; next }
    { print }
  ' "$PINS_FILE" >"$temporary"
  mv "$temporary" "$PINS_FILE"
}

update_pins() {
  mise upgrade --bump --interactive
  update_pin PREZTO_REF "$(git ls-remote "$PREZTO_REPO" HEAD | awk 'NR == 1 { print $1 }')"
  update_pin ZSH_DEFER_REF "$(git ls-remote "$ZSH_DEFER_REPO" HEAD | awk 'NR == 1 { print $1 }')"
  update_pin KUBERNETES_CHANNEL "$(latest_kubernetes_channel)"
  "$0" list
  make -C "$ROOT" check
  git -C "$ROOT" diff -- config/versions.env config/mise/config.toml
}

case "${1:-}" in
  list) list_pins ;;
  check) check_pins ;;
  update) update_pins ;;
  *) usage; exit 2 ;;
esac
```

- [ ] **Step 5: Add discoverable Make targets**

```make
.PHONY: pins pins-check pins-update

pins:
	bash bin/versions list

pins-check:
	bash bin/versions check

pins-update:
	bash bin/versions update
```

- [ ] **Step 6: Point later tasks at the canonical manifest**

When Tasks 8 and 9 move the mise config and introduce Kubernetes, Prezto, and zsh-defer pins, update `MISE_FILE` to `config/mise/config.toml`, export `MISE_CONFIG_DIR="$ROOT/config/mise"`, and source `config/versions.env` instead of defining refs in installer files. The enforcement test must fail if non-mise assignments appear anywhere else outside tests and documentation.

- [ ] **Step 7: Document the maintenance workflow**

Add this README section:

```markdown
## Dependency Pins

Run `make pins` to list every managed version and Git ref. Run `make pins-check`
to query upstreams without changing files. Run `make pins-update` to select mise
upgrades interactively, refresh Git refs and the Kubernetes channel, run the full
test suite, and display the resulting version diff for review.
```

- [ ] **Step 8: Run tests and commit**

Run: `bats tests/dependency_pins.bats && make pins`

Expected: all tests pass and every pin appears once in the command output.

```bash
git add config/versions.env bin/versions tests/dependency_pins.bats Makefile README.md
git commit -m "feat: centralize dependency pin maintenance"
```

---

### Task 3: Enforce Explicit Shell Loading and Profile Isolation

**Files:**
- Create: `tests/shell_loading.bats`
- Modify: `core/shell/zshrc.symlink:23`
- Modify: `profiles/work.zsh:1`

- [ ] **Step 1: Write failing profile-isolation tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

run_loader() {
  local profile="$1"
  printf '%s\n' "$profile" >"$HOME/.dotfiles-profile"
  run env HOME="$HOME" DOTFILES="$REPO_ROOT" zsh -fc '
    source "$DOTFILES/core/shell/load-custom.zsh"
    print "WORK_PROFILE=${WORK_PROFILE:-}"
    print "SERVER_PROFILE=${SERVER_PROFILE:-}"
    alias aks >/dev/null 2>&1 && print WORK_ALIAS_PRESENT
  '
}

@test "personal profile does not load work or server configuration" {
  run_loader personal
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORK_PROFILE="* ]]
  [[ "$output" == *"SERVER_PROFILE="* ]]
  [[ "$output" != *"WORK_ALIAS_PRESENT"* ]]
}

@test "work profile loads work configuration" {
  run_loader work
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORK_PROFILE=1"* ]]
  [[ "$output" == *"WORK_ALIAS_PRESENT"* ]]
}

@test "server profile does not load work configuration" {
  run_loader server
  [ "$status" -eq 0 ]
  [[ "$output" == *"SERVER_PROFILE=1"* ]]
  [[ "$output" != *"WORK_ALIAS_PRESENT"* ]]
}

@test "archived zsh files are never loaded" {
  run zsh -fc 'DOTFILES="$1"; source "$DOTFILES/core/shell/load-custom.zsh"; print ${GOPRIVATE:-}' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"goms.io"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/shell_loading.bats`

Expected: FAIL because `core/shell/load-custom.zsh` does not exist and current recursive loading does not isolate profiles.

- [ ] **Step 3: Extract an explicit loader**

Create `core/shell/load-custom.zsh` with explicit directory ownership:

```zsh
export ZSH="$HOME/.dotfiles"
export DOTFILES="${DOTFILES:-$HOME/.dotfiles}"

for file in "$DOTFILES"/core/path.zsh "$DOTFILES"/languages/*/path.zsh(N); do
  source "$file"
done

for directory in "$DOTFILES/core" "$DOTFILES/languages" "$DOTFILES/tools"; do
  for file in "$directory"/**/*.zsh(N); do
    [[ "$file" == "$DOTFILES/core/shell/load-custom.zsh" ]] && continue
    [[ "$file" == */path.zsh || "$file" == */completion.zsh ]] && continue
    source "$file"
  done
done

case "$(uname)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) platform=unknown ;;
esac
for file in "$DOTFILES/platforms/$platform"/*.zsh(N); do
  source "$file"
done

profile=personal
[[ -r "$HOME/.dotfiles-profile" ]] && profile="$(tr -d '[:space:]' <"$HOME/.dotfiles-profile")"
case "$profile" in
  personal) source "$DOTFILES/profiles/personal.zsh" ;;
  work) source "$DOTFILES/profiles/work.zsh" ;;
  server) source "$DOTFILES/profiles/server.zsh" ;;
  *) source "$DOTFILES/profiles/personal.zsh" ;;
esac

[[ -r "$HOME/.localrc" ]] && source "$HOME/.localrc"
```

Replace the `load_custom` body in `core/shell/zshrc.symlink` with:

```zsh
function load_custom() {
  source "$HOME/.dotfiles/core/shell/load-custom.zsh"
}
```

- [ ] **Step 4: Keep work sourcing owned by the work profile**

Keep `profiles/work.zsh` as the only entry point that exports `WORK_PROFILE=1` and sources `work/*.zsh`. Remove the self-guards from `work/*.zsh` only after tests prove they cannot be reached by other profiles; retaining them as defense in depth is acceptable and preferred.

- [ ] **Step 5: Run the focused and full tests**

Run: `bats tests/shell_loading.bats`

Expected: 4 tests, 0 failures.

Run: `make syntax test`

Expected: PASS.

- [ ] **Step 6: Commit explicit loading**

```bash
git add core/shell/zshrc.symlink core/shell/load-custom.zsh profiles/work.zsh tests/shell_loading.bats
git commit -m "fix: isolate shell profiles and archived config"
```

---

### Task 4: Remove Current-Directory PATH Precedence

**Files:**
- Modify: `tests/shell_loading.bats`
- Modify: `core/path.zsh:1`

- [ ] **Step 1: Write the failing PATH test**

```bash
@test "core path never places the current directory on PATH" {
  run zsh -fc 'PATH=/usr/bin:/bin; ZSH="$1"; HOME="$2"; source "$1/core/path.zsh"; print -r -- "$PATH"' _ "$REPO_ROOT" "$HOME"
  [ "$status" -eq 0 ]
  [[ ":$output:" != *":./bin:"* ]]
  [[ ":$output:" == *":$REPO_ROOT/bin:"* ]]
}
```

- [ ] **Step 2: Verify the test fails**

Run: `bats tests/shell_loading.bats --filter "current directory"`

Expected: FAIL because `./bin` is currently first.

- [ ] **Step 3: Replace the PATH definition**

```zsh
typeset -U path PATH
path=(
  "$HOME/.dotfiles/bin"
  "$HOME/.local/bin"
  "$HOME/bin"
  /usr/local/bin
  /usr/local/sbin
  $path
)
export PATH
export MANPATH="/usr/local/man:/usr/local/mysql/man:/usr/local/git/man:${MANPATH:-}"
```

- [ ] **Step 4: Run tests and commit**

Run: `bats tests/shell_loading.bats`

Expected: 5 tests, 0 failures.

```bash
git add core/path.zsh tests/shell_loading.bats
git commit -m "fix: remove current directory from PATH"
```

---

### Task 5: Repair Validators and Side-Effect-Free Dry Runs

**Files:**
- Create: `tests/validate_ai.bats`
- Create: `tests/ai_installers.bats`
- Modify: `bin/validate-ai:15`
- Modify: `ai/opencode/install.sh:21`
- Modify: `ai/codex/install.sh:9`
- Modify: `ai/copilot/install.sh:9`
- Modify: `Makefile:25`

- [ ] **Step 1: Write validator regression tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "warnings do not abort validate-ai" {
  run bash "$REPO_ROOT/bin/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warnings:"* ]]
  [[ "$output" == *"PASSED"* ]]
}
```

- [ ] **Step 2: Write dry-run immutability tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  mkdir -p "$HOME/.config/opencode/agents"
  printf 'sentinel\n' >"$HOME/.config/opencode/agents/keep.md"
}

@test "opencode check mode changes no files" {
  before="$(find "$HOME" -type f -o -type l | sort | xargs -r sha256sum)"
  run env HOME="$HOME" bash "$REPO_ROOT/ai/opencode/install.sh" --check
  after="$(find "$HOME" -type f -o -type l | sort | xargs -r sha256sum)"
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
  [ -f "$HOME/.config/opencode/agents/keep.md" ]
}
```

Add equivalent cases for Codex and Copilot.

- [ ] **Step 3: Verify both regressions fail**

Run: `bats tests/validate_ai.bats tests/ai_installers.bats`

Expected: validator aborts on the first warning; OpenCode check mode deletes or replaces existing paths.

- [ ] **Step 4: Make counters safe under `set -e`**

```bash
error() { echo "  ERROR: $1"; ERRORS=$((ERRORS + 1)); }
warn()  { echo "  WARN:  $1"; WARNINGS=$((WARNINGS + 1)); }
```

- [ ] **Step 5: Move dry-run guards before every mutation**

At the start of each `link_file` and `link_dir`, calculate the action, then return before `mkdir`, `cp`, `mv`, `rm`, or `ln`:

```bash
if [[ "$check_only" == true ]]; then
  log_info "[dry-run] Would replace $dst with link to $src"
  return 0
fi
```

Do not create destination parent directories in check mode.

- [ ] **Step 6: Expand `make ai-check` to every AI installer supporting `--check`**

```make
ai-check:
	@for installer in ai/*/install.sh; do \
		bash "$$installer" --check; \
	done
```

Add `--check` handling to installers that currently lack it before including them in the loop.

- [ ] **Step 7: Run tests and commit**

Run: `bats tests/validate_ai.bats tests/ai_installers.bats && make validate ai-check`

Expected: PASS with no changes beneath the temporary or real home directories.

```bash
git add bin/validate-ai ai/*/install.sh Makefile tests/validate_ai.bats tests/ai_installers.bats
git commit -m "fix: make validation and dry runs reliable"
```

---

### Task 6: Make Installation Results Honest

**Files:**
- Create: `tests/install_orchestration.bats`
- Modify: `bin/common.sh`
- Modify: `bin/install:18`

- [ ] **Step 1: Write failing phase-result tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/bin/common.sh"
}

@test "required phase failure makes summary fail" {
  run bash -c 'source "$1/bin/common.sh"; run_phase required packages false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: packages"* ]]
}

@test "optional phase failure is reported without failing install" {
  run bash -c 'source "$1/bin/common.sh"; run_phase optional fonts false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: fonts"* ]]
}
```

- [ ] **Step 2: Verify tests fail**

Run: `bats tests/install_orchestration.bats`

Expected: FAIL because phase helpers do not exist.

- [ ] **Step 3: Add phase tracking to `bin/common.sh`**

```bash
PHASE_FAILURES=()
PHASE_WARNINGS=()

run_phase() {
  local requirement="$1"
  local name="$2"
  shift 2

  log_info "Starting phase: $name"
  if "$@"; then
    log_success "Completed phase: $name"
    return 0
  fi

  if [[ "$requirement" == required ]]; then
    PHASE_FAILURES+=("$name")
    log_error "Required phase failed: $name"
  else
    PHASE_WARNINGS+=("$name")
    log_warning "Optional phase failed: $name"
  fi
  return 0
}

finish_phases() {
  local name
  for name in "${PHASE_WARNINGS[@]}"; do
    printf 'WARNING: %s\n' "$name"
  done
  for name in "${PHASE_FAILURES[@]}"; do
    printf 'FAILED: %s\n' "$name" >&2
  done
  ((${#PHASE_FAILURES[@]} == 0))
}
```

- [ ] **Step 4: Classify install phases**

Use required phases for OS packages, shell, Git, and mise runtimes. Use optional phases for Neovim plugin sync, fonts, work extras, and individual AI tools. Remove inner `|| log_warning` wrappers from required commands so their status reaches `run_phase`.

```bash
run_phase required packages install_platform_packages
run_phase required shell setup_shell
run_phase required git setup_git
run_phase required runtimes install_languages
run_phase optional neovim setup_neovim
run_phase optional fonts setup_fonts
run_phase optional work setup_work
run_phase optional ai setup_ai
finish_phases || exit 1
```

- [ ] **Step 5: Run tests and commit**

Run: `bats tests/install_orchestration.bats`

Expected: 2 tests, 0 failures.

```bash
git add bin/common.sh bin/install tests/install_orchestration.bats
git commit -m "fix: report installer failures accurately"
```

---

### Task 7: Require Consent for Remote Installers

**Files:**
- Modify: `tests/install_orchestration.bats`
- Modify: `bin/common.sh`
- Modify: `bin/bootstrap`
- Modify: `ai/opencode/install.sh`
- Modify: `ai/claude/install.sh`
- Modify: `ai/litellm/install.sh`
- Modify: `work/install.sh`

- [ ] **Step 1: Write remote-installer policy tests**

```bash
@test "remote installer is denied without explicit consent" {
  run bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "remote installer is allowed with explicit consent" {
  run env ALLOW_REMOTE_INSTALLERS=1 bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Verify tests fail**

Run: `bats tests/install_orchestration.bats --filter "remote installer"`

Expected: FAIL because the policy helper does not exist.

- [ ] **Step 3: Add an explicit consent helper**

```bash
require_remote_installers() {
  if [[ "${ALLOW_REMOTE_INSTALLERS:-0}" != 1 ]]; then
    log_error "Remote installer execution is disabled. Re-run with ALLOW_REMOTE_INSTALLERS=1 after reviewing the installer source."
    return 1
  fi
}

run_remote_installer() {
  local url="$1"
  local shell_name="$2"
  local script
  require_remote_installers || return 1
  script="$(mktemp)"
  trap 'rm -f "$script"' RETURN
  curl --fail --show-error --location "$url" --output "$script"
  "$shell_name" "$script"
}
```

- [ ] **Step 4: Replace direct pipelines**

Replace each `curl ... | bash` or `curl ... | sh` with `run_remote_installer URL bash` or `run_remote_installer URL sh`. Keep configuration linking available even when installation is skipped because the executable already exists.

- [ ] **Step 5: Add bootstrap flags**

Parse `--allow-remote-installers`, `--profile personal|work|server`, and `--non-interactive`. Export `ALLOW_REMOTE_INSTALLERS=1` only when the flag is present. In non-interactive mode, require both profile and pre-existing Git identity values instead of reading from `/dev/tty`.

- [ ] **Step 6: Remove mutable raw binary downloads in work setup**

Remove the two `install_tool` calls that download `ktx` and `kns` from `raw.githubusercontent.com`. Install the maintained Krew plugins with `kubectl krew install ctx ns`, then preserve the existing command names with `alias ktx='kubectl ctx'` and `alias kns='kubectl ns'` in `work/k8s-aliases.zsh`.

- [ ] **Step 7: Run tests and commit**

Run: `bats tests/install_orchestration.bats tests/ai_installers.bats`

Expected: PASS.

```bash
git add bin/common.sh bin/bootstrap ai/opencode/install.sh ai/claude/install.sh ai/litellm/install.sh work/install.sh tests/install_orchestration.bats tests/ai_installers.bats
git commit -m "feat: require consent for remote installers"
```

---

### Task 8: Make Mise the Runtime Source of Truth

**Files:**
- Create: `config/mise/config.toml`
- Modify: `languages/mise/install.sh`
- Modify: `bin/versions`
- Modify: `bin/common.sh`
- Modify: `bin/install`
- Modify: `bin/dot-update`
- Modify: `platforms/macos/brewfile`
- Modify: `platforms/linux/ubuntu_apt`
- Modify: `platforms/linux/wsl_apt`
- Modify: `platforms/linux/server_apt`
- Remove: `languages/mise/mise.local.toml.symlink`
- Remove: `languages/mise/lang.sh`
- Remove: `bin/mise-helper`
- Remove: `platforms/linux/aptfile`

- [ ] **Step 1: Add a manifest ownership test**

Add to `tests/repository_hygiene.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "system package manifests do not install mise-owned runtimes" {
  run rg -n '^(go|node|ruby|python(@.*)?|openjdk(@.*)?|openjdk-[0-9].*|neovim)$' \
    "$REPO_ROOT/platforms/macos/brewfile" \
    "$REPO_ROOT/platforms/linux/ubuntu_apt" \
    "$REPO_ROOT/platforms/linux/wsl_apt" \
    "$REPO_ROOT/platforms/linux/server_apt"
  [ "$status" -eq 1 ]
}

@test "mise versions are concrete" {
  run rg -n '= "(latest|stable)"' "$REPO_ROOT/config/mise/config.toml"
  [ "$status" -eq 1 ]
}

@test "custom mise version dispatchers are removed" {
  [ ! -e "$REPO_ROOT/bin/mise-helper" ]
  [ ! -e "$REPO_ROOT/languages/mise/lang.sh" ]
  run rg -n 'mise-helper|install_or_update|get_version_from_mise|languages/mise/lang.sh' \
    "$REPO_ROOT/bin" "$REPO_ROOT/languages" --glob '!docs/**'
  [ "$status" -eq 1 ]
}

@test "dot-update delegates without manipulating mise versions" {
  run rg -n 'mise (upgrade|outdated|latest|use)' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 1 ]
  run rg -n 'exec .*bin/install|exec .*dirname.*install' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Verify tests fail**

Run: `bats tests/repository_hygiene.bats`

Expected: FAIL because package manifests overlap, mise uses a nonstandard tracked config location, custom dispatchers still exist, and Node/tree-sitter use floating versions.

- [ ] **Step 3: Move the tracked config to mise's native global location**

Create `config/mise/config.toml` with the tracked tool definitions:

```toml
[tools]
go = "1.25.7"
python = "3.14.3"
java = "25.0.2"
node = "26.5.0"
ruby = "4.0.1"
neovim = "0.11.7"
"npm:tree-sitter-cli" = "0.26.11"
```

Delete `languages/mise/mise.local.toml.symlink`. The existing `bin/bootstrap` config-directory loop will link `config/mise/` to `~/.config/mise`, which `mise config ls` recognizes globally from every working directory.

Update `bin/versions` to use the new tracked location regardless of the caller's current home. Set and export these near the top of the script (before `source "$PINS_FILE"` and before any `check`/`update` code path invokes `mise`), replacing the old `MISE_FILE` assignment:

```bash
MISE_FILE="$ROOT/config/mise/config.toml"
export MISE_CONFIG_DIR="$ROOT/config/mise"
```

- [ ] **Step 4: Remove runtime overlap**

Remove Go, Node, Python, JDK, Ruby, and Neovim packages from the Brewfile and Linux manifests. Retain `mise` itself as the runtime manager. Delete `platforms/linux/aptfile`, which duplicates `ubuntu_apt`.

- [ ] **Step 5: Delete custom mise parsing and dispatch**

Delete `bin/mise-helper` and `languages/mise/lang.sh`. Remove the `mise-helper` source line from `bin/common.sh`; generic logging and OS detection remain there.

- [ ] **Step 6: Reduce the mise installer to native commands**

After ensuring mise itself is installed, make `languages/mise/install.sh` converge to the active config without parsing versions:

```bash
install_tools() {
  local profile="${DOTFILES_PROFILE:-personal}"
  if [[ "$profile" == server ]]; then
    mise install --yes node python
  else
    mise install --yes
  fi
}
```

Do not call `mise outdated`, `mise latest`, `mise use`, or `mise upgrade` during installation. `mise install` reads the tracked global config and installs exactly those declared versions.

- [ ] **Step 7: Simplify install while preserving update semantics**

Replace `bin/install`'s `languages/mise/lang.sh` calls with:

```bash
DOTFILES_PROFILE="$PROFILE" bash "$DOTFILES_ROOT/languages/mise/install.sh"
```

Keep `bin/dot-update` as the full update entrypoint, but make it a strict, transparent delegation to `bin/install`:

```bash
#!/usr/bin/env bash

set -euo pipefail

exec "$(dirname "$0")/install" "$@"
```

`bin/install` continues to own OS packages, runtimes, shell, editor, and AI setup. Its runtime phase now uses native `mise install --yes`, so `bin/dot-update` installs repository-declared pins without parsing versions or silently rewriting the repository. Version discovery and mutation belong only to `make pins-check` and `make pins-update`.

- [ ] **Step 8: Verify mise sees the canonical config**

Run: `MISE_CONFIG_DIR="$PWD/config/mise" mise config ls`

Expected: output includes `config/mise/config.toml` and lists the managed tools.

Run: `MISE_CONFIG_DIR="$PWD/config/mise" mise install --dry-run`

Expected: mise reports only missing versions from `config/mise/config.toml` and does not modify the config.

- [ ] **Step 9: Run tests and commit**

Run: `bats tests/dependency_pins.bats tests/repository_hygiene.bats && make syntax && make pins`

Expected: PASS.

```bash
git add config/mise languages/mise bin/common.sh bin/install bin/dot-update platforms/macos/brewfile platforms/linux tests
git add -u bin/mise-helper languages/mise/mise.local.toml.symlink languages/mise/lang.sh platforms/linux/aptfile
git commit -m "refactor: delegate runtime management to mise"
```

---

### Task 9: Make Shell Startup Offline and Pinned

**Files:**
- Modify: `tests/shell_loading.bats`
- Modify: `core/shell/install.sh`
- Modify: `core/shell/zshrc.symlink:8`
- Read: `config/versions.env` (source pins; do not redeclare)

- [ ] **Step 1: Write an offline-startup test**

```bash
@test "zshrc performs no network or git operations" {
  stub_command git 'echo git-called >&2; exit 99'
  stub_command curl 'echo curl-called >&2; exit 99'
  mkdir -p "$HOME/.zprezto" "$HOME/.zsh-defer"
  : >"$HOME/.zprezto/init.zsh"
  : >"$HOME/.zsh-defer/zsh-defer.plugin.zsh"
  run env HOME="$HOME" PATH="$PATH" zsh -dfc 'source "$1/core/shell/zshrc.symlink"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"called"* ]]
}
```

- [ ] **Step 2: Verify the test fails when dependencies are absent**

Run: `bats tests/shell_loading.bats --filter "network"`

Expected: FAIL because the current zshrc clones dependencies.

- [ ] **Step 3: Move dependency installation to `core/shell/install.sh`**

Source the canonical pins from `config/versions.env` — do **not** redeclare `PREZTO_REF`/`ZSH_DEFER_REF` here, or the Task 2 enforcement test (`non-mise pins have one canonical manifest`) will fail and break `make check`:

```bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "$ROOT/config/versions.env"
# $PREZTO_REPO, $PREZTO_REF, $ZSH_DEFER_REPO, $ZSH_DEFER_REF now available
```

Verify the recorded commits still match the currently tested repositories with:

```bash
prezto_head=$(git -C "$HOME/.zprezto" rev-parse HEAD)
[[ "$prezto_head" == "$PREZTO_REF" ]] || {
  printf 'Prezto revision mismatch: expected %s, got %s\n' "$PREZTO_REF" "$prezto_head" >&2
  exit 1
}

zsh_defer_head=$(git -C "$HOME/.zsh-defer" rev-parse HEAD)
[[ "$zsh_defer_head" == "$ZSH_DEFER_REF" ]] || {
  printf 'zsh-defer revision mismatch: expected %s, got %s\n' "$ZSH_DEFER_REF" "$zsh_defer_head" >&2
  exit 1
}
```

Clone only during install (using `$PREZTO_REPO`/`$ZSH_DEFER_REPO`), then `git checkout --detach "$PREZTO_REF"` / `"$ZSH_DEFER_REF"`. Do not replace the concrete hashes with symbolic branches, and do not hardcode them in this installer.

- [ ] **Step 4: Make startup conditional and offline**

```zsh
if [[ -r "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
fi

if [[ -r "$HOME/.zsh-defer/zsh-defer.plugin.zsh" ]]; then
  source "$HOME/.zsh-defer/zsh-defer.plugin.zsh"
  zsh-defer load_custom
else
  load_custom
fi
```

- [ ] **Step 5: Run tests and commit**

Run: `bats tests/shell_loading.bats`

Expected: all shell-loading tests pass without network access.

```bash
git add core/shell/install.sh core/shell/zshrc.symlink tests/shell_loading.bats
git commit -m "refactor: keep shell startup offline"
```

---

### Task 10: Remove Machine-Specific Tracked Paths

**Files:**
- Create: `tests/portability.bats`
- Create: `ai/config-paths.example.toml`
- Modify: `ai/codex/config.toml`
- Modify: `ai/claude/settings.json`
- Modify: `ai/marketplace/install.sh`
- Modify: `ai/opencode/install.sh`
- Modify: `ai/copilot/install.sh`
- Remove: `ai/opencode/agents/ux-react.md`
- Remove: `ai/copilot/agents/ux-react.md`

- [ ] **Step 1: Write portability tests**

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "tracked symlinks are relative" {
  while IFS= read -r path; do
    target="$(readlink "$REPO_ROOT/$path")"
    [[ "$target" != /* ]]
  done < <(git -C "$REPO_ROOT" ls-files -s | awk '$1 == 120000 {print $4}')
}

@test "portable config contains no personal home paths" {
  run rg -n '/home/tng|/Users/tng' "$REPO_ROOT/ai" --glob '!*.md' --glob '!*.example.*'
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Verify tests fail**

Run: `bats tests/portability.bats`

Expected: FAIL on two absolute tracked symlinks and AI config paths.

- [ ] **Step 3: Remove tracked bridge symlinks**

Delete the two absolute symlinks. Update OpenCode and Copilot installers to create links from the canonical plugin agent at install time using the active repository root.

- [ ] **Step 4: Separate portable and machine-local Codex config**

Keep provider, model, and general options in `ai/codex/config.toml`. Move `[projects."..."]` entries into ignored `ai/codex/projects.local.toml`, generated from `ai/config-paths.example.toml` or merged by the installer into `$HOME/.codex/config.toml`.

- [ ] **Step 5: Generate marketplace paths during install**

Remove the hard-coded `/home/tng/.dotfiles/ai/marketplace` value from tracked JSON. Have `ai/marketplace/install.sh` write the resolved `$DOTFILES_ROOT/marketplace` path into Claude's user-local marketplace registry.

- [ ] **Step 6: Run tests and commit**

Run: `bats tests/portability.bats tests/ai_installers.bats`

Expected: PASS.

```bash
git add ai tests/portability.bats .gitignore
git commit -m "refactor: generate machine-specific AI paths"
```

---

### Task 11: Clean Repository History Artifacts

**Files:**
- Modify: `tests/repository_hygiene.bats`
- Remove: `ai/claude/settings.json.backup-20260511T144808Z`
- Remove: `archived/misc/tree_tunnel.jpeg`
- Remove: `archived/misc/tree_tunnel_ai.jpg`
- Remove: `archived/misc/dot-update.png`
- Modify: `README.md`

- [ ] **Step 1: Add hygiene policy tests**

```bash
@test "tracked files do not contain editor or generated backups" {
  run git -C "$REPO_ROOT" ls-files '*backup*' '*.bak' '*.orig'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tracked blobs stay below five megabytes" {
  run bash -c '
    git -C "$1" ls-files -z |
      xargs -0 -I{} sh -c '\''size=$(wc -c <"$1/{}"); [ "$size" -gt 5242880 ] && echo "$size {}"'\'' _ "$1"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Verify tests fail**

Run: `bats tests/repository_hygiene.bats`

Expected: FAIL on the Claude backup and 15 MiB archived image.

- [ ] **Step 3: Remove unrelated large binaries and backup files**

Use `git rm` for the listed files. Do not rewrite Git history in this feature branch; document `git filter-repo` as a separate optional maintenance operation because history rewriting affects every clone.

- [ ] **Step 4: Document archive policy**

Add to `README.md`:

```markdown
## Repository Hygiene

- Active configuration must not discover files under `archived/`.
- Machine-local files use a `.local` suffix and remain ignored.
- Generated backups and binaries larger than 5 MiB are not tracked.
- Historical artifacts belong in release storage or a dedicated archive repository.
```

- [ ] **Step 5: Run tests and commit**

Run: `bats tests/repository_hygiene.bats`

Expected: PASS.

```bash
git add README.md tests/repository_hygiene.bats
git add -u archived ai/claude
git commit -m "chore: remove stale generated and binary artifacts"
```

---

### Task 12: Add Continuous Integration

**Files:**
- Create: `.github/workflows/check.yml`
- Modify: `README.md`

- [ ] **Step 1: Create the workflow**

```yaml
name: check

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shell tooling
        run: sudo apt-get update && sudo apt-get install -y bats shellcheck shfmt zsh
      - name: Run checks
        run: make check
```

- [ ] **Step 2: Run the same command locally**

Run: `make check`

Expected: syntax, ShellCheck, shfmt, Bats, and AI validation all pass.

- [ ] **Step 3: Document contributor verification**

Add `make check` to the README routine workflow and explain that installers are tested with temporary homes and stubbed commands rather than against the developer machine.

- [ ] **Step 4: Commit CI**

```bash
git add .github/workflows/check.yml README.md
git commit -m "ci: validate dotfiles on pull requests"
```

---

### Task 13: Final Migration and End-to-End Verification

**Files:**
- Modify: `README.md`
- Modify: any shell file still reported by `shellcheck` or `shfmt`

- [ ] **Step 1: Document the migration sequence**

Add commands for existing installations:

```bash
git pull
make check
bin/relink
bin/install
exec zsh
```

Document `ALLOW_REMOTE_INSTALLERS=1 bin/install` as an explicit opt-in, not the default command.

- [ ] **Step 2: Run focused verification**

```bash
bats tests/shell_loading.bats
bats tests/validate_ai.bats tests/ai_installers.bats
bats tests/install_orchestration.bats
bats tests/portability.bats tests/repository_hygiene.bats
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run full verification**

Run: `make check`

Expected: exit 0.

- [ ] **Step 4: Verify repository state**

```bash
git status --short
git diff --check main...HEAD
git log --oneline main..HEAD
```

Expected: no uncommitted changes, no whitespace errors, and one focused commit per completed task.

- [ ] **Step 5: Commit final documentation or formatting fixes**

```bash
git add README.md .github/ ai/ bin/ config/ core/ docs/ fonts/ languages/ platforms/ profiles/ tests/ tools/ work/
git commit -m "docs: add dotfiles modernization migration guide"
```

Skip this commit when Step 4 shows there are no final changes.
