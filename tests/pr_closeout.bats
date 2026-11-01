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
               "every in-scope bot has completed", "only merges the base", "current-head review bodies",
               "cannot wait or be resumed"):
    assert clause in waiting, clause
report = text.split("## Final report\n", 1)[1]
assert "Bot opportunity:" in report and "final thread-read time" in report
assert "review-body findings" in report
assert "describe the `--repo` checkout" in " ".join(text.split())
PY
  [ "$status" -eq 0 ]
}
