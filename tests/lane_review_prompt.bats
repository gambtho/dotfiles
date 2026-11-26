#!/usr/bin/env bats

# The lane-coordinator skill and its tests live in gambtho/gambtho-skills. These
# checks cover the lane-review automation prompt, which stays here.

load test_helper

setup() {
  setup_dotfiles_test
  PROMPT="$REPO_ROOT/tools/automations/prompts/lane-review.md"
}

@test "lane review looks for amended prompts, relayed inferences and other checkpoint misses" {
  run python3 - "$PROMPT" <<'PY'
from pathlib import Path
import sys

review = Path(sys.argv[1]).read_text()
for phrase in ('prompts amended after launch', 'inferred claims relayed without re-observation',
               'helper reruns after a stopped launch', 'human corrections', 'lower bounds'):
    assert phrase in review, phrase
PY
  [ "$status" -eq 0 ]
}

@test "lane review uses friction evidence to promote repeated local rules" {
  grep -Fq 'reports/SKILL-FRICTION.md' "$PROMPT"
  grep -Fq 'rules repeated across projects' "$PROMPT"
  grep -Fq 'belong in the skill' "$PROMPT"
  grep -Fq 'clauses projects keep restating' "$PROMPT"
}
