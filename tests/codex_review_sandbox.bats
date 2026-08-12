#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CODEX_REVIEW="$REPO_ROOT/ai/marketplace/plugins/my/commands/codex-review.md"
}

@test "codex-review may run the bubblewrap capability probe" {
  run grep -F 'Bash(bwrap --ro-bind / / --dev /dev true)' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Bash(bwrap:*)' "$CODEX_REVIEW"
  [ "$status" -ne 0 ]
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

@test "codex-review passes the selected sandbox mode to codex exec" {
  run grep -F 'codex exec --sandbox "$SANDBOX_MODE"' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'codex exec --sandbox read-only' "$CODEX_REVIEW"
  [ "$status" -ne 0 ]
}

@test "codex-review escalates only the container-without-bubblewrap row" {
  run grep -F '| yes       | non-zero or absent | `danger-full-access` |' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F '| yes       | exit 0        | `read-only` |' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F '| no        | not run       | `read-only` |' "$CODEX_REVIEW"
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
  run grep -F 'sha256sum {absolute path of each document resolved in Phase 1, quoted}' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  # -Fx: `git status --short` is also named in the surrounding prose, so a
  # substring match survives deletion of the capture command itself.
  run grep -Fx 'git status --short' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Store them as `PRE_STATUS`, `PRE_DIFF`, and `PRE_HASHES`.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review detects writes into an already-modified file" {
  # `git status --short` prints ` M path` both before and after a further edit,
  # so a status-only guard misses writes into a file that was already dirty --
  # the normal case when reviewing mid-feature. PRE_DIFF/POST_DIFF catch it.
  # -Fx, not -F: `git diff HEAD` also appears twice in the surrounding prose, so
  # a substring match stays green even if the capture command itself is deleted.
  run grep -Fx 'git diff HEAD' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'a file already modified before the run shows ` M path` both before and after' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'POST_STATUS`, `POST_DIFF`, and `POST_HASHES`' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Bash(git diff:*)' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review can cd to the reviewed tree without prompting" {
  # The captures must run from ROOT, and `cd` is the only way to set a Bash
  # call's working directory -- so the grant has to be there or the guard
  # stops for a permission prompt mid-preflight.
  # Pinned with a frontmatter neighbour: the prose below also names
  # `Bash(cd:*)`, so a bare substring match survives deleting the grant.
  run grep -F 'Bash(codex exec:*), Bash(cd:*),' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'as `cd "$ROOT" && {command}`' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review matches any bwrap namespace failure, not two exact strings" {
  # A third bwrap wording falling through to the generic `Non-zero exit` row
  # loses the re-entry -- the whole point of the branch.
  run grep -F 'Any `bwrap:` error, or any message about creating, entering, or having permission for a namespace' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'the two above are the observed forms, not the whole set' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review names the ignored-file gap in the integrity guard" {
  run grep -F 'A file matched by' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'is absent from all three captures entirely' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review anchors the integrity captures to the reviewed tree" {
  run grep -F 'Run all three from `ROOT`' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'reports on the wrong checkout, and the guard reports clean no matter what Codex wrote' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review re-enters Phase 2e instead of hand-editing the sandbox flag" {
  run grep -F '**Re-entry after a missed container.**' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Set `SANDBOX_MODE` to `danger-full-access`.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Re-enter at **Phase 2e** and take all three pre-run captures.' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Do **not** re-run with a hand-edited `--sandbox` flag' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  # Steps 4-5 are what make the re-entry safe rather than merely re-decided:
  # re-running unchanged is why the flag never gets hand-edited, and the post-run
  # captures are the half of the guard that detects a write.
  run grep -F 'Re-run the Phase 3 command **unchanged**' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'Take the matching post-run captures, and report any difference through' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
}

@test "codex-review treats any non-zero exit as a failed run" {
  run grep -F '| Non-zero exit | Run failed |' "$CODEX_REVIEW"
  [ "$status" -eq 0 ]
  run grep -F 'A non-zero exit means the output is not a review, whether or not `review.md` exists.' "$CODEX_REVIEW"
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
