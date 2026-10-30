#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  PACKAGE_DIR="$REPO_ROOT/ai/marketplace/plugins/my"
  SKILL_DIR="$PACKAGE_DIR/skills/lane-coordinator"
}

@test "shared workflow projection retains nested rules and unchanged review commands" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import re
import sys

skill = Path(sys.argv[1])
text = (skill / "references/common-rules-template.md").read_text()
match = re.search(r"^## Shared workflow\n(.*?)(?=^#{1,2} |\Z)", text, re.M | re.S)
assert match, "Missing shared workflow section"
workflow = match.group(1)
for title in ("Design, then plan", "Worktrees and pull requests", "Scope and evidence",
              "Private information and writing"):
    assert f"### {title}\n" in workflow, f"Rules escaped shared section: {title}"
for phrase in ("/second-opinion`", "/second-opinion --with-spec", "/adversarial-review",
               "No timeout increases as a fix", "Never edit another lane's worktree",
               "only after the previous one merges", "No secrets in files"):
    assert phrase in workflow, phrase
assert "equivalent review" not in workflow
conflict_rule = "If instructions conflict, stop and ask the coordinator."
assert conflict_rule in " ".join(workflow.split()), "Projection omits conflict stop rule"
effort = text.split("## Rules for every lane\n", 1)[1].split("\n## Sequencing", 1)[0]
assert conflict_rule in " ".join(effort.split()), "Effort rules omit conflict stop rule"
for name in ("SKILL.md", "references/lane-template.md"):
    assert "lanes/COMMON-RULES.md" in (skill / name).read_text(), name
PY
  [ "$status" -eq 0 ]
}

@test "coordinator checks bundled skills without replacing required lane tools" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
text = " ".join((skill / "SKILL.md").read_text().split())
for phrase in ("../<name>/SKILL.md", "not the current session's skill list or slash commands",
               "says nothing about what a lane has", "Never remove or swap these tools",
               "lane prompt, template or project's rules", "report it to the human and stop"):
    assert phrase in text, phrase
for name in ("pr-closeout", "polish-core", "second-opinion-core", "adversarial-review"):
    assert name in text and (skill.parent / name / "SKILL.md").is_file(), name
PY
  [ "$status" -eq 0 ]
}

@test "lane Git fallback depends on absent policy rather than absent rule files" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

lane = (Path(sys.argv[1]) / "references/lane-template.md").read_text()
assert "If none exist:" not in lane
fallback = " ".join(lane.split("If no project or repo Git policy exists:", 1)[1].split())
for phrase in ("merge the base in for conflicts", "never push to a default branch or merge",
               "never rewrite someone else's branch"):
    assert phrase in fallback, phrase
PY
  [ "$status" -eq 0 ]
}

@test "lane coordinator is discoverable through the validated Pi package inventory" {
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:    lane-coordinator/SKILL.md"* ]]
}

@test "lane coordinator bundled Markdown references resolve inside its package" {
  run python3 - "$SKILL_DIR" "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import re
import sys

skill = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
entry = skill / "SKILL.md"
assert entry.is_file(), f"Missing skill entry: {entry}"
visited = set()
people = skill / "references/people-template.md"
assert people.is_file(), "Missing people bootstrap template"
pending = [entry, root / "skills/pr-closeout/SKILL.md", root / "skills/polish-core/SKILL.md", root / "prompts/review-prs.md"]
while pending:
    source = pending.pop()
    if source in visited:
        continue
    visited.add(source)
    for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", source.read_text()):
        if "://" in target or target.startswith("#"):
            continue
        resolved = (source.parent / target.split("#", 1)[0]).resolve()
        assert root in resolved.parents, f"Reference escapes skill: {source}: {target}"
        assert resolved.is_file(), f"Broken reference: {source}: {target}"
        if resolved.suffix == ".md":
            pending.append(resolved)
assert people in visited, "People bootstrap template is not reachable through bundled links"
assert len(visited) > 1, "No bundled references reachable from the skill entry"
print(f"Resolved {len(visited)} bundled Markdown files")
PY
  [ "$status" -eq 0 ]
}

@test "coordinator routines expose catch-up rules and project-owned commands" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
text = (skill / "SKILL.md").read_text()
start = text.split("## Start or resume\n", 1)[1].split("\n## Keep STATE.md current", 1)[0]
maintenance = text.split("## Maintenance\n", 1)[1].split("\n## Live changes", 1)[0]
for phrase in ("coordinate <project>", "end of day <project>", "weekly <project>"):
    assert phrase in text.split("\n---", 1)[0], phrase
    assert phrase in maintenance, phrase
for phrase in ("only one project folder", "Routines", "18 hours", "last STATE commit", "7 days", "missing"):
    assert phrase in start, phrase
assert start.index("pick-up test") < start.index("drift report") < start.index("morning sweep") < start.index("Give the user a short status")
assert "Don't run it unasked" in start
assert "--json state,headRefOid,statusCheckRollup" in start
assert "manual" in maintenance and "budgets" in maintenance
coordination = (skill / "references/coordination-template.md").read_text()
for phrase in ("## Routines", "Drift check", "Morning sweep", "Budget", "report"):
    assert phrase in coordination, phrase
for stamp in ("Last end of day: <date time>", "Last weekly pass: <date>"):
    assert stamp in maintenance and stamp in (skill / "references/state-template.md").read_text(), stamp
PY
  [ "$status" -eq 0 ]
}

@test "routine prompt wrappers select the named routine with unchanged project arguments" {
  local name routine
  for name in eod weekly; do
    routine="weekly"
    [ "$name" != eod ] || routine="end of day"
    run grep -F "\"$routine\"" "$PACKAGE_DIR/prompts/$name.md"
    [ "$status" -eq 0 ]
    grep -Fq 'lane-coordinator' "$PACKAGE_DIR/prompts/$name.md"
    grep -Fq '$ARGUMENTS' "$PACKAGE_DIR/prompts/$name.md"
    jq -e --arg path "./prompts/$name.md" '.pi.prompts | index($path) != null' "$PACKAGE_DIR/package.json"
  done
}

@test "lane guidance scopes review loading, size defaults and live authority" {
  run python3 - "$SKILL_DIR" "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import sys

skill, package = map(Path, sys.argv[1:])
lane = (skill / "references/lane-template.md").read_text()
closeout = (package / "skills/pr-closeout/SKILL.md").read_text()
assert "Read only the **Review evidence** section" in lane
assert "including aliases" in lane and "coordinator alone writes profiles" in lane
for text in (lane, closeout):
    for phrase in ("~1k hand-written product lines", "~1.5× product", "~1k changed lines in total",
                   "COORDINATION.md", "otherwise treat", "project's own rule wins"):
        assert phrase in text, phrase
    assert "~1.5k" not in text
live = (skill / "references/live-changes.md").read_text()
for phrase in ("project's authority table", "approved plan with a cost cap", "lane's own resources",
               "propose the exact commands and wait", "Use short-lived tokens.",
               "only where the project's rules permit it", "Never print, log or pass secrets as arguments."):
    assert phrase in live, phrase
PY
  [ "$status" -eq 0 ]
}

@test "STATE stays small at write time and daily maintenance enforces its budget" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
state = (skill / "references/state-template.md").read_text()
for phrase in ("One home per fact", "one-word state", "PR numbers without heads or CI",
               "next actor and action", "report path", "## Needs the human", "ordered one-liners",
               "## Waiting on others", "not already a lane row's next actor", "at most about 10",
               "not already in the project's rule files", "dated or triggered items", "not already in a lane row",
               "Parked: <links to paused lane rows", "stop/resume condition in its row"):
    assert phrase in state, phrase
text = (skill / "SKILL.md").read_text()
updates = text.split("For every coherent update:", 1)[1].split("If something took digging", 1)[0]
for phrase in ("Closing a lane", "same update", "CLOSED-<month>.md", "25 words", "full record",
               "done, superseded", "rule files", "oldest", "archive", "Replace, don't add", "one home"):
    assert phrase in updates, phrase
eod = text.split("**End of day:**", 1)[1].split("**Next morning:**", 1)[0]
for phrase in ("Routines", "budget", "inspection", "lane reports", "archive", "current fact",
               "by section", "where", "human", "weekly pass"):
    assert phrase in eod, phrase
weekly = text.split("**Weekly, in the coordinator session:**", 1)[1].split("**Human away", 1)[0]
for phrase in ("daily", "duplicate", "superseded", "intent check", "budgets", "AGENTS", "COORDINATION", "PEOPLE"):
    assert phrase in weekly, phrase
assert "Full record: `reports/decision.md`." in state
PY
  [ "$status" -eq 0 ]
}

@test "state template remains consumable by the launch projection" {
  run python3 - "$SKILL_DIR" <<'PY'
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile

skill = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("lane_launch", skill / "scripts/launch.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
text = (skill / "references/state-template.md").read_text().replace("W<n>", "W12")
with tempfile.TemporaryDirectory() as directory:
    state = Path(directory) / "STATE.md"
    state.write_text(text)
    args = SimpleNamespace(state=state, lane="W12", prompt=Path(directory) / "W12-task.md")
    launch = module.Launch(args, {}, {})
    launch.record = {"name": "sample-12", "stage": "Submitted", "workspace": "ws-1", "pane": "pane-1"}
    launch.update_state()
    result = state.read_text().splitlines()
    row = module.state_row(state.read_text(), "W12")
    original = text.splitlines()[module.state_row(text, "W12")]
    assert result[row].split("|")[1:5] == original.split("|")[1:5]
    assert "Submitted" in result[row] and "ws-1" in result[row] and "pane-1" in result[row]
    assert result[:row] == text.splitlines()[:row]
    assert result[row + 1:] == text.splitlines()[row + 1:]
PY
  [ "$status" -eq 0 ]
}
