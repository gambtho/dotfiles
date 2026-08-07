#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CODEX_REVIEW="$REPO_ROOT/ai/marketplace/plugins/my/commands/codex-review.md"
}

@test "codex-review may run the bubblewrap capability probe" {
  run grep -F 'Bash(bwrap:*)' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review detects containers before choosing a sandbox" {
  run grep -F '### 0e: Select the Sandbox Mode' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'REMOTE_CONTAINERS' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F '/run/.containerenv' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review probes bwrap rather than assuming containers block it" {
  run grep -F 'bwrap --ro-bind / / --dev /dev true' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'A missing `bwrap` binary counts as a failed probe, not an error.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review keeps read-only outside containers" {
  run grep -F 'Outside a container the probe never runs and `SANDBOX_MODE` is `read-only`.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review states the sandbox mode in its confirmation" {
  run grep -F 'sandbox: {SANDBOX_MODE} ({why})' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review documents the bwrap namespace failure" {
  run grep -F 'bwrap: No permissions to create a new namespace' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review keys the sandbox choice off the probe exit status" {
  run grep -F 'never the message text' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review guards document integrity only when unsandboxed" {
  run grep -F '## Phase 2e: Integrity Guard (danger-full-access only)' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Skip this phase entirely when `SANDBOX_MODE` is `read-only`' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review hashes reviewed docs around an unsandboxed run" {
  run grep -F 'sha256sum' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'git status --short' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review explains why git checkout is not the safety net" {
  run grep -F 'cannot restore an uncommitted document' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review leads the report with any detected write" {
  run grep -F 'lead the report with it — above the verdict, above the findings' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review offers a non-verdict outcome for blocked runs" {
  run grep -F 'STATUS: INCOMPLETE' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'do NOT return a VERDICT line' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'A verdict you cannot support by reading the code is worse than no verdict.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review never reports an incomplete run as a design signal" {
  run grep -F 'no design conclusion follows' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}
