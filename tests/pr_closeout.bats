#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  SKILL_DIR="$REPO_ROOT/ai/marketplace/plugins/my/skills/pr-closeout"
}

@test "pr-closeout is discoverable through the validated Pi package inventory" {
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:    pr-closeout/SKILL.md"* ]]
}

@test "pr-closeout snapshot helper is executable and prints usage" {
  [ -x "$SKILL_DIR/scripts/pr_snapshot.sh" ]
  run "$SKILL_DIR/scripts/pr_snapshot.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: pr_snapshot.sh"* ]]
}

@test "pr-closeout drafts human replies and keeps repo-specific commands out" {
  run grep -c "Human threads" "$SKILL_DIR/SKILL.md"
  [ "$output" -ge 1 ]
  run grep -E "make lint-fix|bun run" "$SKILL_DIR/SKILL.md"
  [ "$status" -ne 0 ]
}

@test "closeout publishes the bounded bot opportunity and evidence contract" {
  run python3 - "$SKILL_DIR/SKILL.md" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
waiting = " ".join(text.split("## Bounded waiting\n", 1)[1].split("## Final report", 1)[0].split())
for clause in ("installed", "required by repository policy", "active on this PR",
               "unknown", "verified absence", "roughly ten minutes", "not draft creation",
               "not a guessed push time", "completed current-head", "even when CI is green",
               "mandatory missing review remains a blocker", "Elapsed time is not completed review evidence",
               "every in-scope bot has completed", "only merges the base", "any carried-over head",
               "cannot wait or be resumed"):
    assert clause in waiting, clause
report = text.split("## Final report\n", 1)[1]
assert "Bot opportunity:" in report and "final thread-read time" in report
assert "review-body findings" in report
flat = " ".join(text.split())
assert "describe the `--repo` checkout" in flat
assert "then repeat `gh pr view`; a failed read or changed" in flat
PY
  [ "$status" -eq 0 ]
}

# Stub gh for a PR whose head is the test checkout's HEAD. Tests set CHECKS (gh pr
# checks JSON) and ROLLUP (status rollup nodes, one page per argument; unset fails the read).
stub_pr_snapshot() {
  git init -q -b topic "$TEST_ROOT/repo"
  git -C "$TEST_ROOT/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  HEAD_OID="$(git -C "$TEST_ROOT/repo" rev-parse HEAD)"
  OLD_OID="$(printf 'a%.0s' {1..40})"
  export HEAD_OID
  cat >"$STUB_BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") jq -n --arg h "$HEAD_OID" '{number:7,url:"https://github.com/o/r/pull/7",title:"t",state:"OPEN",isDraft:false,baseRefName:"main",headRefName:"topic",headRefOid:$h,mergeStateStatus:"CLEAN",reviewDecision:null,updatedAt:"2020-01-01T00:00:00Z"}' ;;
  "pr checks") printf '%s\n' "$CHECKS" ;;
  "api graphql")
    if [[ "$*" != *statusCheckRollup* ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
    elif [[ -n "${ROLLUP:-}" ]]; then
      for page in "$ROLLUP" ${ROLLUP_PAGE2:+"$ROLLUP_PAGE2"}; do
        jq -c "${@: -1}" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"commits\":{\"nodes\":[{\"commit\":{\"statusCheckRollup\":{\"contexts\":{\"nodes\":$page}}}}]}}}}}"
      done
    else
      exit 1
    fi ;;
esac
GH
  chmod +x "$STUB_BIN/gh"
}

run_snapshot() {
  run "$SKILL_DIR/scripts/pr_snapshot.sh" --repo "$TEST_ROOT/repo" --pr 7 --github-repo o/r --compact
  [ "$status" -eq 0 ]
  run jq -r '(.checks.items | map("\(.name)=\(.revision)") | join(" ")), .blockers.staleCheckRevision, .blockers.checkRevisionUnknown, .blockers.failingChecks, .blockers.pendingChecks' <<<"$output"
}

check_run() { # name workflow oid
  printf '{"__typename":"CheckRun","name":"%s","checkSuite":{"commit":{"oid":"%s"},"workflowRun":{"workflow":{"name":"%s"}}}}' "$1" "$3" "$2"
}

@test "snapshot blocks green checks read from a commit other than the head" {
  stub_pr_snapshot
  export CHECKS='[{"name":"test","bucket":"pass","workflow":"ci"},{"name":"bot","bucket":"pass","workflow":""}]'
  export ROLLUP="[$(check_run test ci "$OLD_OID"),{\"__typename\":\"StatusContext\",\"context\":\"bot\",\"commit\":{\"oid\":\"$OLD_OID\"}}]"
  run_snapshot
  [ "${lines[0]}" = "test=$OLD_OID bot=$OLD_OID" ]
  [ "${lines[1]}" = true ]
  [ "${lines[2]}" = false ]
  [ "${lines[3]}" = false ]
}

@test "snapshot records unknown for a pending check missing from the rollup" {
  stub_pr_snapshot
  export CHECKS='[{"name":"test","bucket":"pass","workflow":"ci"},{"name":"slow","bucket":"pending","workflow":"ci"}]'
  export ROLLUP="[$(check_run test ci "$HEAD_OID")]"
  run_snapshot
  [ "${lines[0]}" = "test=$HEAD_OID slow=unknown" ]
  [ "${lines[1]}" = false ]
  [ "${lines[2]}" = true ]
  [ "${lines[4]}" = true ]
}

@test "snapshot records unknown, not a pass, when revisions are unreadable" {
  stub_pr_snapshot
  export CHECKS='[{"name":"test","bucket":"pass","workflow":"ci"}]'
  unset ROLLUP
  run_snapshot
  [ "${lines[0]}" = "test=unknown" ]
  [ "${lines[1]}" = false ]
  [ "${lines[2]}" = true ]
}

@test "snapshot reads check revisions past the first rollup page" {
  stub_pr_snapshot
  export CHECKS='[{"name":"a","bucket":"pass","workflow":"ci"},{"name":"b","bucket":"pass","workflow":"ci"}]'
  export ROLLUP="[$(check_run a ci "$HEAD_OID")]" ROLLUP_PAGE2="[$(check_run b ci "$HEAD_OID")]"
  run_snapshot
  [ "${lines[0]}" = "a=$HEAD_OID b=$HEAD_OID" ]
  [ "${lines[1]}" = false ]
  [ "${lines[2]}" = false ]
}
