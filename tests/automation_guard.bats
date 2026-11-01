#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  REPO="$TEST_ROOT/repo"
  EVIDENCE="$TEST_ROOT/evidence"
  AGENT="$TEST_ROOT/agent"
  mkdir -p "$REPO/.git" "$EVIDENCE" "$AGENT"
  printf 'token\n' >"$AGENT/auth.json"
  ln -s "$AGENT/auth.json" "$REPO/escape-link"
}

decide() {
  node - "$REPO_ROOT/tools/automations/guard.ts" "$1" "$2" "$REPO" "$EVIDENCE" <<'NODE'
const [modulePath, tool, path, repo, evidence] = process.argv.slice(2);
const { blockReason } = await import(modulePath);
console.log(blockReason(tool, { path }, repo, [repo, evidence], [repo]) ?? "allowed");
NODE
}

@test "automation guard allows reading evidence and writing the clone" {
  run decide read "$EVIDENCE/survey.md"
  [ "$output" = allowed ]
  run decide write report.md
  [ "$output" = allowed ]
}

@test "automation guard keeps the credential copy out of reach" {
  run decide read "$AGENT/auth.json"
  [[ "$output" == *"outside this review"* ]]
  run decide grep "$AGENT"
  [[ "$output" == *"outside this review"* ]]
}

@test "automation guard follows symlinks before deciding" {
  run decide read escape-link
  [[ "$output" == *"outside this review"* ]]
}

@test "automation guard makes evidence read-only and blocks git metadata" {
  run decide write "$EVIDENCE/planted.md"
  [[ "$output" == *"outside this review"* ]]
  run decide write .git/hooks/pre-commit
  [[ "$output" == *"under .git"* ]]
}

@test "automation guard rejects tools outside the review allowlist" {
  run decide bash ls
  [[ "$output" == *"not allowed"* ]]
  run decide fetch_content https://example.com
  [[ "$output" == *"not allowed"* ]]
}
