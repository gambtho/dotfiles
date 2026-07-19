# Vekil Shell Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically configure fresh zsh sessions for Vekil while providing `claude-direct` and `codex-direct` commands that bypass the proxy for one invocation.

**Architecture:** Explicitly source the focused Vekil environment file from the existing shell loader rather than recursively loading the entire `ai/` tree. Define direct-client functions inside that environment file so they are always available and use `env -u` to remove proxy variables only from the child process.

**Tech Stack:** zsh, Bash, Bats

---

### Task 1: Automatically Load the Vekil Environment

**Files:**
- Modify: `tests/shell_loading.bats`
- Modify: `core/shell/load-custom.zsh`

- [ ] **Step 1: Write the failing fresh-shell test**

Add a test that creates secure Vekil state files and a successful curl stub, then loads `core/shell/load-custom.zsh` and expects the managed endpoints:

```bash
@test "shell loader configures healthy Vekil endpoints" {
  local state_dir="$HOME/.local/state/vekil"
  mkdir -p "$state_dir"
  printf '127.0.0.1\n' >"$state_dir/proxy-host"
  : >"$state_dir/proxy-ready"
  chmod 0700 "$HOME/.local" "$HOME/.local/state" "$state_dir"
  chmod 0600 "$state_dir/proxy-host" "$state_dir/proxy-ready"
  stub_command curl 'exit 0'

  run env HOME="$HOME" DOTFILES="$REPO_ROOT" PATH="$PATH" zsh -dfc '
    source "$DOTFILES/core/shell/load-custom.zsh" || exit 1
    print -r -- "$OPENAI_BASE_URL|$ANTHROPIC_BASE_URL"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"http://127.0.0.1:1337/v1|http://127.0.0.1:1337"* ]]
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `bats tests/shell_loading.bats --filter 'shell loader configures healthy Vekil endpoints'`

Expected: FAIL because `load-custom.zsh` does not source `ai/vekil/env.zsh`.

- [ ] **Step 3: Source the focused environment file**

Add this after the core/language/tool loop and before platform/profile loading:

```zsh
[[ -r "$DOTFILES/ai/vekil/env.zsh" ]] && source "$DOTFILES/ai/vekil/env.zsh"
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `bats tests/shell_loading.bats --filter 'shell loader configures healthy Vekil endpoints'`

Expected: PASS.

### Task 2: Add Direct Client Commands

**Files:**
- Modify: `tests/ai_installers.bats`
- Modify: `ai/vekil/env.zsh`

- [ ] **Step 1: Write failing direct-command tests**

Add fake external clients that record arguments and relevant environment values, then prove the direct functions remove managed proxy values while preserving real credentials and custom model values:

```bash
@test "vekil environment provides direct client commands without proxy variables" {
  cat >"$STUB_BIN/claude" <<'SCRIPT'
#!/bin/bash
printf 'claude:%s|%s|%s|%s\n' "$*" "${ANTHROPIC_BASE_URL-unset}" "${ANTHROPIC_API_KEY-unset}" "${ANTHROPIC_MODEL-unset}"
SCRIPT
  cat >"$STUB_BIN/codex" <<'SCRIPT'
#!/bin/bash
printf 'codex:%s|%s|%s\n' "$*" "${OPENAI_BASE_URL-unset}" "${OPENAI_API_KEY-unset}"
SCRIPT
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"

  run env PATH="$PATH" /usr/bin/zsh -dfc '
    source "$1"
    export ANTHROPIC_BASE_URL=proxy ANTHROPIC_API_KEY=dummy ANTHROPIC_MODEL=proxy-model
    export VEKIL_MANAGED_ANTHROPIC_API_KEY=dummy VEKIL_MANAGED_ANTHROPIC_MODEL=proxy-model
    export OPENAI_BASE_URL=proxy OPENAI_API_KEY=dummy VEKIL_MANAGED_OPENAI_API_KEY=dummy
    claude-direct --model direct-model
    codex-direct exec prompt
    unset VEKIL_MANAGED_ANTHROPIC_API_KEY VEKIL_MANAGED_ANTHROPIC_MODEL VEKIL_MANAGED_OPENAI_API_KEY
    export ANTHROPIC_BASE_URL=proxy ANTHROPIC_API_KEY=real-anthropic ANTHROPIC_MODEL=direct-model
    export OPENAI_BASE_URL=proxy OPENAI_API_KEY=real-openai
    claude-direct direct-prompt
    codex-direct direct-prompt
  ' _ "$REPO_ROOT/ai/vekil/env.zsh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude:--model direct-model|unset|unset|unset"* ]]
  [[ "$output" == *"codex:exec prompt|unset|unset"* ]]
  [[ "$output" == *"claude:direct-prompt|unset|real-anthropic|direct-model"* ]]
  [[ "$output" == *"codex:direct-prompt|unset|real-openai"* ]]
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `bats tests/ai_installers.bats --filter 'vekil environment provides direct client commands'`

Expected: FAIL because `claude-direct` and `codex-direct` do not exist.

- [ ] **Step 3: Implement the two functions**

Define these functions before the readiness-dependent anonymous function so they exist even when Vekil is stopped:

```zsh
function claude-direct {
  emulate -L zsh
  local -a direct_env=(-u ANTHROPIC_BASE_URL)
  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_API_KEY:-} && ${ANTHROPIC_API_KEY:-} == $VEKIL_MANAGED_ANTHROPIC_API_KEY ]]; then
    direct_env+=(-u ANTHROPIC_API_KEY)
  fi
  if [[ -n ${VEKIL_MANAGED_ANTHROPIC_MODEL:-} && ${ANTHROPIC_MODEL:-} == $VEKIL_MANAGED_ANTHROPIC_MODEL ]]; then
    direct_env+=(-u ANTHROPIC_MODEL)
  fi
  command env "${direct_env[@]}" claude "$@"
}

function codex-direct {
  emulate -L zsh
  local -a direct_env=(-u OPENAI_BASE_URL)
  if [[ -n ${VEKIL_MANAGED_OPENAI_API_KEY:-} && ${OPENAI_API_KEY:-} == $VEKIL_MANAGED_OPENAI_API_KEY ]]; then
    direct_env+=(-u OPENAI_API_KEY)
  fi
  command env "${direct_env[@]}" codex "$@"
}
```

- [ ] **Step 4: Run the focused tests and verify they pass**

Run: `bats tests/ai_installers.bats --filter 'vekil environment provides direct client commands'`

Expected: PASS with both fake executables receiving unchanged arguments and unset proxy variables.

### Task 3: Document and Validate the Workflow

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document proxied and direct commands**

Add this usage block to the AI setup section:

````markdown
Fresh zsh sessions automatically configure both clients when Vekil is ready:

```bash
claude          # through Vekil
codex           # through Vekil
claude-direct   # bypass Vekil for this invocation
codex-direct    # bypass Vekil for this invocation
```
````

- [ ] **Step 2: Run focused shell validation**

Run:

```bash
zsh -n ai/vekil/env.zsh core/shell/load-custom.zsh
bats tests/shell_loading.bats tests/ai_installers.bats
```

Expected: syntax checks and all focused Bats tests pass.

- [ ] **Step 3: Run the complete repository gate**

Run: `make check`

Expected: ShellCheck, shfmt, all Bats tests, and AI validation pass.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git diff --check
git diff -- core/shell/load-custom.zsh ai/vekil/env.zsh tests/shell_loading.bats tests/ai_installers.bats README.md
```

Expected: only the approved loader, direct commands, tests, and usage documentation are changed.
