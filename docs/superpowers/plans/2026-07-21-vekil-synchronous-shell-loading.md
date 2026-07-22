# Synchronous Vekil Shell Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every initialized interactive zsh has the Vekil-managed `codex` function before deferred customizations run.

**Architecture:** Source `ai/vekil/env.zsh` directly from `core/shell/zshrc.symlink` before `zsh-defer` queues `load_custom`. Retain the source in `load-custom.zsh` for direct callers and rely on the loader's existing idempotence.

**Tech Stack:** zsh, zsh-defer, Bats

---

### Task 1: Load Vekil before deferred customizations

**Files:**
- Modify: `tests/shell_loading.bats`
- Modify: `core/shell/zshrc.symlink`

- [ ] **Step 1: Write the failing regression test**

Add a Bats test that creates valid Vekil state, stubs a healthy readiness probe, and installs a `zsh-defer` stub that does not execute queued work:

```bash
@test "zshrc loads Vekil before deferred customizations run" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir" "$HOME/.zsh-defer"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command curl 'exit 0'
  cat >"$HOME/.zsh-defer/zsh-defer.plugin.zsh" <<'SCRIPT'
zsh-defer() { :; }
SCRIPT

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/zshrc.symlink" || exit 1
    print -r -- "VEKIL_CODEX_FUNCTION=${+functions[codex]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"VEKIL_CODEX_FUNCTION=1"* ]]
}
```

- [ ] **Step 2: Verify the test fails for the missing synchronous source**

Run: `bats tests/shell_loading.bats`

Expected: the new test fails because `zsh-defer` does not execute `load_custom`, leaving `${+functions[codex]}` equal to `0`.

- [ ] **Step 3: Add the minimal synchronous source**

Before the `load_custom` definition in `core/shell/zshrc.symlink`, add:

```zsh
# Codex needs the Vekil wrapper before deferred customizations can run.
[[ -r "${DOTFILES:-$HOME/.dotfiles}/ai/vekil/env.zsh" ]] && \
  source "${DOTFILES:-$HOME/.dotfiles}/ai/vekil/env.zsh"
```

- [ ] **Step 4: Verify focused behavior**

Run: `bats tests/shell_loading.bats`

Expected: all shell-loading tests pass, including the new deferred-work regression.

- [ ] **Step 5: Verify the repository**

Run:

```bash
bats tests
bash bin/validate-ai --verbose
shellcheck -x -S warning tests/shell_loading.bats
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 6: Commit the implementation**

```bash
git add core/shell/zshrc.symlink tests/shell_loading.bats docs/superpowers/plans/2026-07-21-vekil-synchronous-shell-loading.md
git commit -m "fix Vekil loading before deferred shell setup"
```
