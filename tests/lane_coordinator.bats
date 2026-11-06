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

@test "lane review uses friction evidence to promote repeated local rules" {
  local prompt="$REPO_ROOT/tools/automations/prompts/lane-review.md"
  grep -Fq 'reports/SKILL-FRICTION.md' "$prompt"
  grep -Fq 'rules repeated across projects' "$prompt"
  grep -Fq 'belong in the skill' "$prompt"
  grep -Fq 'clauses projects keep restating' "$prompt"
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
for name in ("lane-template.md", "common-rules-template.md"):
    template = (skill / "references" / name).read_text()
    assert "<resolved harness-notes path>" in template, name
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
for phrase in ("resolve conflicts by merging the base branch into yours",
               "never push to a default branch or merge a PR",
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
assert "**Disk, at end of day and weekly:**" in maintenance, "Missing disk routine"
disk = " ".join(maintenance.split("**Disk, at end of day and weekly:**", 1)[1].split("**End of day:**", 1)[0].split())
for phrase in ("five largest lane folders with sizes", "private reports only", "free-space threshold",
               "**Needs the human**", "unknown, not healthy", "never infer deletion approval from a disk warning",
               "If no disk-check command exists", "inspect only configured roots manually",
               "observation time", "missing commands, roots or measurements unknown",
               "Cleanup follows **Keep STATE.md current**, step 5's exact-list approval rules"):
    assert phrase in disk, phrase
coordination = (skill / "references/coordination-template.md").read_text()
for phrase in ("## Routines", "Drift check", "Morning sweep", "Budget", "report",
               "Disk check (end of day + weekly)", "minimum free GiB", "explicit roots"):
    assert phrase in coordination, phrase
for stamp in ("Last end of day: <date time>", "Last weekly pass: <date>"):
    assert stamp in maintenance and stamp in (skill / "references/state-template.md").read_text(), stamp
PY
  [ "$status" -eq 0 ]
}

@test "lane reports and handoffs declare bulky output disposal conditions" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
for name, anchor in (("handoff-template.md", "- Bulky outputs:"),
                     ("lane-template.md", "List bulky outputs:")):
    text = (skill / "references" / name).read_text()
    declaration = next((line for line in text.splitlines() if line.startswith(anchor)), "")
    assert declaration, f"Missing bulky output declaration: {name}"
    for phrase in ("path", "size", "safe to delete when", "none", "unknown"):
        assert phrase in declaration, (name, phrase)
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

@test "coordinator checks live state and phase readiness before action" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

text = (Path(sys.argv[1]) / "SKILL.md").read_text()
prompt = " ".join(text.split("## Write a lane prompt\n", 1)[1].split("\n## Start a lane", 1)[0].split())
for phrase in ("Before advising action or sending an instruction",
               "refresh live PR/head/CI and session state the advice relies on",
               "An open lane is not a running session", "current runtime/user observation or say unknown",
               "existing tool already covers it", "sibling projects' Routines and tools"):
    assert phrase in prompt, phrase
assert "approved tasks required for that phase" not in prompt
merged = " ".join(text.split("## When something merges\n", 1)[1].split("\n## Maintenance", 1)[0].split())
for phrase in ("approved tasks required for that phase with shipped implementation",
               "merged prerequisites alone do not complete its own tasks", "Mark unverified completion unknown",
               "every lane #N unblocks or conflicts with", "Respect each decision's scope",
               "do not make route-specific dependencies global"):
    assert phrase in merged, phrase
PY
  [ "$status" -eq 0 ]
}

@test "coordinator templates retain scoped conditions and authority" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
texts = {name: " ".join((skill / name).read_text().split()) for name in
         ("SKILL.md", "references/state-template.md", "references/handoff-template.md", "references/lane-template.md")}
condition = "all current resume conditions and who decides (a person, or none if automatic)"
for name, text in texts.items():
    assert condition in text, name
assert "**A decision** names its scope" in texts["SKILL.md"]
for phrase in ("name each decision's scope", "respecting each decision's scope",
               "do not make route-specific dependencies global"):
    assert phrase in texts["references/state-template.md"], phrase
for phrase in ("- Delivered inputs:", "delivery does not grant authority to run",
               "execution authority's scope/source or approval still needed"):
    assert phrase in texts["references/handoff-template.md"], phrase
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
               "Parked: <links to paused lane rows", "all current resume conditions and who decides"):
    assert phrase in state, phrase
text = (skill / "SKILL.md").read_text()
updates = text.split("For every coherent update:", 1)[1].split("If something took digging", 1)[0]
for phrase in ("Closing a lane", "same update", "CLOSED-<month>.md", "25 words", "full record",
               "done, superseded", "rule files", "oldest", "archive", "Replace, don't add", "one home"):
    assert phrase in updates, phrase
closing = " ".join(updates.split("5. **Closing a lane**", 1)[1].split("6. **A decision**", 1)[0].split())
for phrase in ("exact deletion list with sizes", "lane report/handoff", "archive",
               "**Needs the human** until decided", "only after the human approves that exact list",
               "project authority still applies", "Unknown safety or size is not deletion-ready"):
    assert phrase in closing, phrase
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

@test "lane report size filter counts tests at any depth without claiming product paths" {
  run python3 - "$SKILL_DIR" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

text = (Path(sys.argv[1]) / "SKILL.md").read_text()
filters = re.findall(r"--json files --jq '([^']+)'", text)
assert len(filters) == 1, filters
# Each kind's additions are distinct bits, so a miscounted path changes the exact total.
tests = ["tests/lane_coordinator.bats", "tests/python/pr_snapshot_stable.json", "test/run.sh",
         "pkg/tests/run.py", "pkg/test/run.py", "src/app_test.go", "src/app.spec.ts"]
docs = ["README.md", "docs/guide.md"]
product = ["bin/dot-install", "latests/run.sh", "src/tests.py", "libexec/testsuite/run.sh"]
paths = tests + docs + product
files = [{"path": path, "additions": 1 << bit} for bit, path in enumerate(paths)]
def total(group):
    return sum(item["additions"] for item in files if item["path"] in group)
result = subprocess.run(["jq", "-c", filters[0]], input=json.dumps({"files": files}),
                        capture_output=True, text=True, check=True)
assert json.loads(result.stdout) == {"tests": total(tests), "docs": total(docs),
                                     "product": total(product)}, result.stdout
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "coordinator delegates bot waiting and requires snapshot consistency" {
  run python3 - "$SKILL_DIR/SKILL.md" <<'PY'
from pathlib import Path
import sys
text = " ".join(Path(sys.argv[1]).read_text().split())
assert "../pr-closeout/SKILL.md#bounded-waiting" in text
assert "../pr-closeout/SKILL.md#snapshot-helper" in text
assert "unreadable final PR observation; refresh before recommending ready" in text
assert "do not make the human relay or babysit that wait" in text
assert "--repo <lane worktree> --github-repo <repo> --pr <n>" in text
assert "ignore only its local blockers" in text
PY
  [ "$status" -eq 0 ]
}

@test "lane contract and harness notes carry the bot opportunity" {
  run python3 - "$SKILL_DIR/references" <<'PY'
from pathlib import Path
import sys
references = Path(sys.argv[1])
def read(name):
    return " ".join((references / name).read_text().split())
lane = read("lane-template.md")
assert "Complete closeout's bounded bot opportunity" in lane
assert "bot-opportunity evidence" in lane
assert "bounded bot opportunity and final thread and review-body read" in read("common-rules-template.md")
harness = read("harness-notes.md")
assert "Wait for the bot-review budget" in harness
assert "remaining budget as the stop/resume line" in harness
PY
  [ "$status" -eq 0 ]
}

@test "pr text is registered and discoverable with a bounded skill entry" {
  run python3 - "$PACKAGE_DIR" "$REPO_ROOT" <<'PY'
import json
from pathlib import Path
import sys

package, repo = map(Path, sys.argv[1:])
entry = package / "skills/pr-text/SKILL.md"
assert entry.is_file(), "Missing pr-text skill"
text = entry.read_text()
assert text.startswith("---\nname: pr-text\ndescription: Use when ")
assert len(text.splitlines()) < 150, "Keep the skill below 150 lines"
assert "./skills/pr-text/SKILL.md" in json.loads((package / "package.json").read_text())["pi"]["skills"]
for inventory in (repo / "AGENTS.md", package / "README.md"):
    assert "`pr-text`" in inventory.read_text(), str(inventory)
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
  run bash "$REPO_ROOT/libexec/validate-ai" --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:    pr-text/SKILL.md"* ]]
}

@test "writing consumers load pr text without weakening existing contracts" {
  run python3 - "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import sys

package = Path(sys.argv[1])
closeout = (package / "skills/pr-closeout/SKILL.md").read_text()
references = package / "skills/lane-coordinator/references"
common = (references / "common-rules-template.md").read_text()
writing = (references / "writing-rules.md").read_text()
text = (package / "skills/pr-text/SKILL.md").read_text()
assert "[pr-text](../pr-text/SKILL.md)" in closeout
assert "[pr-text](../../pr-text/SKILL.md)" in writing
# Projected common rules live outside the package: name the skill, not a relative link.
assert "Load the `pr-text` skill" in common
assert "PR bodies, review comments/replies and issues" in common
assert "pr-text/SKILL.md" not in common
assert "under ~10 lines" not in common
assert "## PR body shape" not in writing and "Verification:" not in writing
assert 'stacked on #N — review after it lands' in closeout
assert "stay draft until the parent merges" in closeout
assert "9. **P1 record before merge.**" in closeout
assert "posting permission is not permission to resolve" in closeout
for heading in ("## Publishing", "## Privacy", "## Chat and commit voice"):
    assert heading in writing, heading
assert "Changed text or destination needs a new OK" in writing
assert "Implementation approval" in writing
assert "Keep bot-generated blocks" in text
assert "Required disposition records" in text and "labels, hashes" in text
assert "grants no permission" in text
assert "DCO" in text and "AI disclosure" in text and "co-author" in text
assert "never open with" in text and "I added" in text
assert "Picking this up." in text and "Refs" in text and "Fixes" in text
assert "exact versions" in text and "Pin source links" in text
assert "three to six short paragraphs" in text
# Existing-PR replies can enter the loop without the new-PR body checklist.
loop = closeout.split("## Workflow\n", 1)[1]
assert "[pr-text](../pr-text/SKILL.md)" in loop.split("4. **CI failures.**", 1)[0]
harness = (references / "harness-notes.md").read_text()
bundled = harness.split("## Bundled", 1)[1].split("## Shell pitfalls", 1)[0]
assert "`pr-text`" in bundled
assert "PR titles" in text and "No emoji" in text and "shortest draft" in text
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}
