# Vekil Runtime Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make failed Vekil shutdowns visible and durable, and reduce normal interactive shell initialization to one readiness probe.

**Architecture:** Extend the existing PID-plus-start-identity lifecycle model with one mode-0600 stop-failure record and a separately bounded SIGKILL confirmation interval. Keep early `.zshrc` initialization authoritative and remove only the redundant deferred source, preserving `env.zsh` convergence semantics for deliberate re-sourcing.

**Tech Stack:** Bash, Zsh, process signals, filesystem state records, curl, Bats/shell integration tests

---

## Task 1: Add lifecycle failure tests

**Files:**
- Create: `tests/vekil_proxy_lifecycle.bats`
- Modify: `tests/test_helper.bash`

- [ ] **Step 1: Build a sourceable lifecycle harness**

Add test helpers that source `bin/vekil-proxy` with `VEKIL_PROXY_SOURCE_ONLY=1`, override `process_matches_record`, `kill`, and `sleep` through functions, and create a safe state directory containing `proxy.pid`, `proxy-host`, and `proxy-ready` at modes 0600/0700.

- [ ] **Step 2: Add failing stop tests**

Cover: graceful exit after TERM; forced exit after SIGKILL; process surviving SIGKILL; start identity changing during wait; zero-second kill confirmation still checking once; failure-marker mode/content; PID preservation on failure; and cleanup after a later successful stop.

The surviving-process assertion must include:

```bash
run env VEKIL_STOP_TIMEOUT=0 VEKIL_KILL_CONFIRM_TIMEOUT=0 \
  bash "$REPO_ROOT/bin/vekil-proxy" stop
[ "$status" -ne 0 ]
[ -f "$STATE_DIR/proxy.pid" ]
[ -f "$STATE_DIR/proxy-stop-failed" ]
[ ! -e "$STATE_DIR/proxy-ready" ]
[[ "$output" == *"unable to stop Vekil pid"* ]]
```

- [ ] **Step 3: Verify RED**

Run: `bats tests/vekil_proxy_lifecycle.bats`

Expected: FAIL because stop always deletes the PID record and reports `STOPPED` after SIGKILL without confirmation.

- [ ] **Step 4: Commit tests**

```bash
git add tests/vekil_proxy_lifecycle.bats tests/test_helper.bash
git commit -m "test: cover Vekil shutdown outcomes"
```

## Task 2: Validate kill-confirm configuration and state entry

**Files:**
- Modify: `bin/vekil-proxy`
- Modify: `tests/vekil_proxy_lifecycle.bats`

- [ ] **Step 1: Add configuration assertions**

Assert default `VEKIL_KILL_CONFIRM_TIMEOUT` is 2, accepted values are integers 0–30, and `-1`, `31`, and nonnumeric input exit 2 before mutation. Assert a symlink at `proxy-stop-failed` is rejected by state validation.

- [ ] **Step 2: Verify RED**

Run: `bats tests/vekil_proxy_lifecycle.bats`

Expected: FAIL because the variable and state entry are unknown.

- [ ] **Step 3: Implement configuration and safe marker plumbing**

Add:

```bash
KILL_CONFIRM_TIMEOUT="${VEKIL_KILL_CONFIRM_TIMEOUT:-2}"
STOP_FAILED_FILE="$STATE_DIR/proxy-stop-failed"
```

Validate with `normalize_uint KILL_CONFIRM_TIMEOUT VEKIL_KILL_CONFIRM_TIMEOUT 0 30`, include the marker in `validate_state_entries`, and add:

```bash
write_stop_failed() { atomic_write "$STOP_FAILED_FILE" "$1"; }
clear_stop_failed() { require_safe_regular "$STOP_FAILED_FILE" && rm -f -- "$STOP_FAILED_FILE"; }
```

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/vekil_proxy_lifecycle.bats`

Expected: configuration and unsafe-state cases pass; outcome tests remain RED until Task 3.

- [ ] **Step 5: Commit**

```bash
git add bin/vekil-proxy tests/vekil_proxy_lifecycle.bats
git commit -m "feat: track Vekil stop failures safely"
```

## Task 3: Confirm shutdown before deleting ownership state

**Files:**
- Modify: `bin/vekil-proxy`
- Modify: `tests/vekil_proxy_lifecycle.bats`

- [ ] **Step 1: Implement a bounded identity wait**

Add a helper that performs one immediate check even when timeout is zero:

```bash
wait_until_process_changes() {
  local record="$1" timeout="$2" deadline=$((SECONDS + timeout))
  while process_matches_record "$record"; do
    (( SECONDS < deadline )) || return 1
    sleep 1
  done
}
```

- [ ] **Step 2: Rewrite stop around verified outcomes**

Keep the original `record` for every identity check. Remove the ready marker first. Send TERM only while the record still matches; wait `STOP_TIMEOUT`; send SIGKILL only while it still matches; then wait `KILL_CONFIRM_TIMEOUT`. On success, remove PID and stop-failure records and print `STOPPED`. On failure, preserve PID, call `write_stop_failed "$record"`, emit an actionable error, and return nonzero.

The final branch must be equivalent to:

```bash
if process_matches_record "$record"; then
  write_stop_failed "$record"
  echo "FAILED"
  echo "unable to stop Vekil pid $pid; ownership state preserved in $STOP_FAILED_FILE" >&2
  return 1
fi
rm -f -- "$PIDFILE"
clear_stop_failed
echo " STOPPED"
```

- [ ] **Step 3: Verify GREEN**

Run: `bats tests/vekil_proxy_lifecycle.bats`

Expected: all stop outcome tests pass, including PID reuse without signalling the replacement process.

- [ ] **Step 4: Commit**

```bash
git add bin/vekil-proxy tests/vekil_proxy_lifecycle.bats
git commit -m "fix: verify Vekil process termination"
```

## Task 4: Surface and clear STOP_FAILED status

**Files:**
- Modify: `bin/vekil-proxy`
- Modify: `tests/vekil_proxy_lifecycle.bats`
- Modify: `ai/vekil/README.md`

- [ ] **Step 1: Add failing status and recovery tests**

Assert `status` reports `STOP_FAILED host=127.0.0.1 port=1337 pid=<pid>` before probing readiness while the marker's exact identity remains alive; a stale/malformed marker is removed and normal classification resumes; successful `start` and `stop` remove the marker; and a healthy endpoint cannot mask `STOP_FAILED`.

- [ ] **Step 2: Verify RED**

Run: `bats tests/vekil_proxy_lifecycle.bats`

Expected: FAIL because status ignores the marker and start does not clear it.

- [ ] **Step 3: Implement marker-first classification**

Read the marker with the same record parser rules used for the PID file. At the top of `status`, if the marker record matches the same process identity, print `STOP_FAILED ...` and return 1 before `is_ready`. Remove stale or malformed markers. Clear the marker only after a successful start outcome or verified stop. Document `VEKIL_KILL_CONFIRM_TIMEOUT` and `STOP_FAILED` recovery in `ai/vekil/README.md`.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/vekil_proxy_lifecycle.bats tests/ai_installers.bats`

Expected: all lifecycle and installer tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/vekil-proxy tests/vekil_proxy_lifecycle.bats ai/vekil/README.md
git commit -m "fix: report failed Vekil shutdowns"
```

## Task 5: Prove one readiness probe per shell

**Files:**
- Modify: `tests/shell_loading.bats`
- Modify: `core/shell/load-custom.zsh`

- [ ] **Step 1: Add failing probe-count tests**

Create a curl stub that appends to `$VEKIL_CURL_LOG`, build valid Vekil state, source normal `.zshrc`, force deferred `load_custom` to execute, and assert exactly one `/readyz` invocation. Add deliberate repeated-source coverage expecting one additional probe per explicit `source env.zsh`, plus cases for local `.localrc` override precedence and managed-variable cleanup after readiness changes from success to failure.

```bash
[ "$(grep -c '/readyz' "$VEKIL_CURL_LOG")" -eq 1 ]
```

- [ ] **Step 2: Verify RED**

Run: `bats tests/shell_loading.bats`

Expected: the normal initialization count is 2 because both `.zshrc` and `load-custom.zsh` source `env.zsh`.

- [ ] **Step 3: Remove only the redundant deferred source**

Delete:

```zsh
[[ -r "$DOTFILES/ai/vekil/env.zsh" ]] && source "$DOTFILES/ai/vekil/env.zsh"
```

from `core/shell/load-custom.zsh`. Do not add an inherited sentinel and do not change the early `.zshrc` source or `env.zsh` convergence logic.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/shell_loading.bats tests/project_claude_setup_seed.bats`

Expected: one probe during normal initialization, explicit sourcing probes again, local overrides win, and managed variables are removed when unavailable.

- [ ] **Step 5: Commit**

```bash
git add core/shell/load-custom.zsh tests/shell_loading.bats
git commit -m "fix: probe Vekil once during shell startup"
```

## Task 6: Verify Vekil wave

**Files:**
- Modify: none

- [ ] **Step 1: Run focused lifecycle verification**

```bash
bats tests/vekil_proxy_lifecycle.bats tests/shell_loading.bats tests/ai_installers.bats
bash tests/vekil-proxy-token-safety.sh
bash tests/vekil-installer-legacy-cleanup.sh
```

Expected: every command exits 0.

- [ ] **Step 2: Run complete verification**

```bash
make check
git diff --check HEAD~5..HEAD
git status --short
```

Expected: `make check` passes, diff check is clean, and only intentional implementation-notes state remains uncommitted if present.
