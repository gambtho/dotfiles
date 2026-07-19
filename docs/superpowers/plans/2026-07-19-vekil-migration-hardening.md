# Vekil Migration Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject unsafe Vekil token entries and automatically stop only identity-verified legacy LiteLLM daemons during migration.

**Architecture:** Keep credential validation in `bin/vekil-proxy`, where all public lifecycle commands converge. Keep one-time legacy cleanup in `ai/vekil/install.sh`, using PID-file ownership plus exact process arguments rather than broad process-name matching. Exercise both behaviors through standalone shell regression harnesses that run against temporary homes and fake binaries.

**Tech Stack:** Bash, zsh syntax validation, POSIX process inspection (`kill`, `/proc`, `ps`), existing dotfiles installer helpers.

---

## Task 1: Record Implementation Context

**Files:**
- Create: `implementation-notes.md`

- [x] **Step 1: Create durable implementation notes**

Record the approved scope, the literal-versus-resolved LiteLLM config-path discovery, the no-broad-`pkill` rule, and the verification commands from this plan. Do not include transient command output.

## Task 2: Add Failing Token-Safety Harness

**Files:**
- Create: `tests/vekil-proxy-token-safety.sh`
- Modify: `bin/vekil-proxy`

- [x] **Step 1: Write the failing harness**

Create a Bash script that:

1. Builds a temporary fake `vekil` executable that records every invocation.
2. Creates `$VEKIL_TOKEN_DIR/access-token` as a symlink.
3. Runs `bin/vekil-proxy login`, `start`, and `logout` separately with temporary state.
4. Asserts each command exits non-zero and the fake Vekil invocation log remains empty.
5. Creates a regular token with mode `0644`, runs `login`, and asserts the token becomes `0600`.
6. Makes fake `login` create a symlink after invocation and asserts the command fails during post-validation.

The harness must use `trap` cleanup, print one success line, and fail with a descriptive message on the first broken assertion.

- [x] **Step 2: Run the harness to verify failure**

Run: `bash tests/vekil-proxy-token-safety.sh`

Expected: FAIL because the current public lifecycle commands invoke fake Vekil with a symlinked access token.

- [x] **Step 3: Add centralized access-token validation**

Add these semantics to `bin/vekil-proxy`:

```bash
ACCESS_TOKEN_FILE="$TOKEN_DIR/access-token"

validate_access_token() {
  [[ -e "$ACCESS_TOKEN_FILE" || -L "$ACCESS_TOKEN_FILE" ]] || return 0
  if [[ -L "$ACCESS_TOKEN_FILE" || ! -f "$ACCESS_TOKEN_FILE" ]]; then
    echo "unsafe Vekil access token: $ACCESS_TOKEN_FILE" >&2
    return 1
  fi
  chmod 600 -- "$ACCESS_TOKEN_FILE"
  [[ ! -L "$ACCESS_TOKEN_FILE" && -f "$ACCESS_TOKEN_FILE" ]] || {
    echo "unsafe Vekil access token: $ACCESS_TOKEN_FILE" >&2
    return 1
  }
}
```

Call `validate_access_token` after securing the token directory and:

- before `start` examines or launches a process;
- before and after `login` invokes Vekil;
- before and after `logout` invokes Vekil.

- [x] **Step 4: Run the harness to verify success**

Run: `bash tests/vekil-proxy-token-safety.sh`

Expected: PASS with no fake-Vekil invocation for unsafe pre-existing token entries.

## Task 3: Add Failing Legacy-Cleanup Harness

**Files:**
- Create: `tests/vekil-installer-legacy-cleanup.sh`
- Modify: `ai/vekil/install.sh`

- [x] **Step 1: Write the failing harness**

Create a Bash script that prepares a temporary home with an already-installed fake Vekil and runs the installer with `VEKIL_SKIP_AUTH=1` and `VEKIL_SKIP_START=1`. Cover these independent cases:

- a matching fake LiteLLM process with `--config "$HOME/.config/litellm/config.yaml" --port 4000` is terminated and its PID file is removed;
- the matching port-4001 process is terminated and its PID file is removed;
- a dead PID produces safe stale-PID-file removal;
- a malformed PID file is preserved and warns;
- a symlinked PID file is preserved and warns;
- a live process whose arguments do not match LiteLLM, config, or port remains alive and its PID file remains;
- a second installer run succeeds with no legacy process or PID file;
- `--check` leaves a matching fake process and PID file untouched.

Use real temporary background processes with controlled argv rather than mocking `kill`.

- [x] **Step 2: Run the harness to verify failure**

Run: `bash tests/vekil-installer-legacy-cleanup.sh`

Expected: FAIL because the installer currently performs no legacy daemon cleanup.

- [x] **Step 3: Implement identity-checked cleanup**

Add installer configuration:

```bash
LEGACY_LITELLM_DIR="${LITELLM_CONFIG_DIR:-$HOME/.config/litellm}"
LEGACY_LITELLM_CONFIG="$LEGACY_LITELLM_DIR/config.yaml"
LEGACY_STOP_TIMEOUT="${VEKIL_LEGACY_STOP_TIMEOUT:-15}"
```

Add helpers that:

- validate `LEGACY_STOP_TIMEOUT` as a bounded non-negative integer;
- safely read only non-symlink regular PID files containing one positive integer;
- obtain process arguments from `/proc/$pid/cmdline` on Linux and `ps -ww -p "$pid" -o command=` as a fallback;
- require a LiteLLM executable argument, `--config` followed by the literal config path or resolvable target, and `--port` followed by the expected port;
- send `TERM`, wait until exit, recheck identity before any `KILL`, and remove the PID file only after the matching process is gone;
- remove safe stale PID files;
- warn and preserve unsafe, malformed, or identity-mismatched PID files.

Add:

```bash
cleanup_legacy_litellm() {
  cleanup_legacy_litellm_process "$LEGACY_LITELLM_DIR/proxy.pid" 4000
  cleanup_legacy_litellm_process "$LEGACY_LITELLM_DIR/codex-proxy.pid" 4001
}
```

Call it after `install_vekil` and before authentication. In `--check`, print both cleanup targets without inspecting or mutating them.

- [x] **Step 4: Run the harness to verify success**

Run: `bash tests/vekil-installer-legacy-cleanup.sh`

Expected: PASS for matching, stale, unsafe, mismatched, idempotent, and dry-run cases.

## Task 4: Update Migration Status

**Files:**
- Modify: `VEKIL_MIGRATION_HANDOFF.md`
- Modify: `docs/superpowers/specs/2026-07-19-vekil-migration-hardening-design.md`
- Modify: `implementation-notes.md`

- [x] **Step 1: Update the handoff**

Move the token-symlink and legacy-daemon findings from unresolved to completed, state the exact conservative cleanup behavior, and retain the unrelated `make ai-check` and browser-launcher caveats.

- [x] **Step 2: Record verification and deviations**

Record the literal legacy config path requirement and all completed test commands in `implementation-notes.md`.

## Task 5: Verify the Complete Change

**Files:**
- Verify all changed files.

- [x] **Step 1: Run focused regression harnesses**

Run:

```bash
bash tests/vekil-proxy-token-safety.sh
bash tests/vekil-installer-legacy-cleanup.sh
```

Expected: both print PASS and exit zero.

- [x] **Step 2: Run static and installer checks**

Run:

```bash
bash -n ai/vekil/install.sh
bash -n bin/vekil-proxy
bash -n tests/vekil-proxy-token-safety.sh
bash -n tests/vekil-installer-legacy-cleanup.sh
zsh -n ai/vekil/env.zsh
git diff --check
VEKIL_OS=Linux VEKIL_ARCH=x86_64 bash ai/vekil/install.sh --check
VEKIL_OS=Darwin VEKIL_ARCH=arm64 bash ai/vekil/install.sh --check
bash ai/codex/install.sh --check
```

Expected: all commands exit zero. Run ShellCheck over the four Bash files when available and report when unavailable.

- [x] **Step 3: Inspect scope and final diff**

Run:

```bash
git status --short
git diff --stat
git diff -- bin/vekil-proxy ai/vekil/install.sh tests VEKIL_MIGRATION_HANDOFF.md docs/superpowers/specs/2026-07-19-vekil-migration-hardening-design.md
```

Expected: only approved hardening, tests, and migration documentation are present.

- [x] **Step 4: Preserve machine-dependent follow-up**

Do not claim host bridge, devcontainer, device authentication, model catalog, Claude, or Codex live smoke tests passed on this machine unless they are actually run. Keep them documented as final operational verification if unavailable.

## Task 6: Remove Temporary Notes

**Files:**
- Delete: `implementation-notes.md`

- [x] **Step 1: Fold durable context into normal docs**

Confirm all durable decisions and unresolved risks are present in the hardening design or handoff, then remove `implementation-notes.md` before final delivery.

---

No commits are included in this plan because the user did not request repository commits.
