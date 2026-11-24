#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  PACKAGE_DIR="$REPO_ROOT/ai/marketplace/plugins/my"
  SKILL_DIR="$PACKAGE_DIR/skills/lane-coordinator"
}

@test "shared workflow projection retains nested rules and scoped review commands" {
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
for phrase in ("/second-opinion`", "/second-opinion --with-spec", "one independent review phase",
               "specialists only for a named uncovered risk or explicit request",
               "No timeout increases as a fix", "Never edit another lane's worktree",
               "only after the previous one merges", "No secrets in files"):
    assert phrase in workflow, phrase
assert "equivalent review" not in workflow
assert "run `/adversarial-review`" not in workflow
conflict_rule = "If instructions conflict, stop and ask the coordinator."
assert conflict_rule in " ".join(workflow.split()), "Projection omits conflict stop rule"
effort = text.split("## Rules for every lane\n", 1)[1].split("\n## Sequencing", 1)[0]
assert conflict_rule in " ".join(effort.split()), "Effort rules omit conflict stop rule"
for name in ("SKILL.md", "references/lane-template.md"):
    assert "lanes/COMMON-RULES.md" in (skill / name).read_text(), name
PY
  [ "$status" -eq 0 ]
}

@test "every lane defaults to local review after verified GitHub rate limits" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys
skill = Path(sys.argv[1])
common = " ".join((skill / "references/common-rules-template.md").read_text().split())
# The coordinator's PR check moved to pr-closeout; the CLI mechanics live in its fallback.
check = " ".join((skill.parent / "pr-closeout/references/coordinator-check.md").read_text().split())
closeout = " ".join((skill.parent / "pr-closeout/SKILL.md").read_text().split())
for text in (common, check):
    for clause in ("standing default", "explicit project opt-out", "Copilot",
                   "quota", "review bot", "current-head", "never stalls",
                   "different model family", "review round: local CodeRabbit CLI"):
        assert clause in text, clause
assert "local CodeRabbit fallback" in common
for clause in ("coderabbit review --agent", "Never post local output",
               "billing", "One local fallback per PR"):
    assert clause in closeout, clause
PY
  [ "$status" -eq 0 ]
}

@test "lane checkpoints reread changed prompts and distinguish evidence from inference" {
  run python3 - "$SKILL_DIR" "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys

skill, repo = map(Path, sys.argv[1:])
workflow = ' '.join((skill / 'references/common-rules-template.md').read_text().split())
for phrase in ('starting SHA256', 'each irreversible or outward step', 'push, PR opening',
               'setup/config mutation and final ready report', 'if changed', 'reread and reconcile', 'coordinator notes'):
    assert phrase in workflow, phrase
# The lane template points at the shared checkpoints instead of restating them.
lane = ' '.join((skill / 'references/lane-template.md').read_text().split())
assert "shared workflow's prompt-hash and addressed-note checkpoints" in lane
assert 'starting SHA256' not in lane
coordinator = ' '.join((skill / 'SKILL.md').read_text().split())
for text in (workflow, coordinator):
    for phrase in ('observed', 'command or source', 'inferred'):
        assert phrase in text, phrase
assert 'uniqueness or identity assumption stays inferred until tested by a lane' in coordinator
# Amendment delivery lives in the common-rules header; the disk routine in morning.md.
header = ' '.join((skill / 'references/common-rules-template.md').read_text().split('## Shared workflow', 1)[0].split())
for phrase in ('dated heading', 'prompt copy is observable', 'checkpoint is loaded',
               'explicit reread instruction', 'Mark delivery unknown until confirmed',
               'never rerun a start to deliver an amendment'):
    assert phrase in header, phrase
morning = ' '.join((skill / 'references/morning.md').read_text().split())
for phrase in ('shared-resource lead', 'exact cleanup list', 'never cleans up another project',
               'Needs the human'):
    assert phrase in morning, phrase
closeout = (skill.parent / 'pr-closeout/SKILL.md').read_text()
assert 'lane prompt checkpoint' in closeout
review = (repo / 'tools/automations/prompts/lane-review.md').read_text()
for phrase in ('prompts amended after launch', 'inferred claims relayed without re-observation',
               'helper reruns after a stopped launch', 'human corrections', 'lower bounds'):
    assert phrase in review, phrase
PY
  [ "$status" -eq 0 ]
}

@test "skill points at the bundled coordinator instead of describing lane commands" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import re
import sys

skill = Path(sys.argv[1])
raw = (skill / 'SKILL.md').read_text()
coordinator = ' '.join(raw.split())
pointer = ' '.join(raw.split('## Where things live\n', 1)[1].split('\n## ', 1)[0].split())
for phrase in ('`Worker: lane`', 'bundled with developerlanes',
               'resources/skills/lane-coordinator/SKILL.md', '`lane init` prints it',
               'the `lane` on PATH runs from', 'does not cover an operation or flag named here',
               'choose per Hosts row', 'stop and tell the human', 'wins on commands', 'ours wins on habits',
               'neither adds authority', 'references/legacy-herdr.md'):
    assert phrase in pointer, phrase
assert '**every user message**' in coordinator
attention = ' '.join(raw.split('## Every turn\n', 1)[1].split('\n## ', 1)[0].split())
for phrase in ('lane workers as the bundled skill describes', 'Herdr-only hosts and their notes',
               'legacy-herdr.md#attention-and-notes-on-every-turn'):
    assert phrase in attention, phrase
# The rewrite's budget: about 180 lines; a friction fix replaces lines rather than adding them.
assert len(raw.splitlines()) <= 200, 'The skill holds habits; mechanics belong to the bundled coordinator'
# Mechanics live in the bundled skill: the coordinator's own files carry no lane command lines.
commands = re.compile(r'`lane (?:--host \S+ )?(?:start|status|instruct|answer|report|retire|cleanup|launch-status|inbox)\b')
allowed = {'references/covered-answers.md': 1}
for name in ('SKILL.md', 'references/harness-notes.md',
             'references/coordination-template.md', 'references/covered-answers.md'):
    hits = commands.findall((skill / name).read_text())
    assert len(hits) <= allowed.get(name, 0), (name, hits)
for word in ('launch-status', '--creation-id', '--expected-hash', 'herdr-lane', 'send.py', 'reports/inbox/'):
    assert word not in coordinator, word
PY
  [ "$status" -eq 0 ]
}

@test "partner checks tie work to outcomes and hook into existing steps" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
refs = skill / "references"
read = lambda path: " ".join(path.read_text().split())
raw = (skill / "SKILL.md").read_text()
main = " ".join(raw.split())
partner = " ".join(raw.split("## Partner checks\n", 1)[1].split("\n## ", 1)[0].split())
for check in ("**Tie work to the goal.**", "**Step back at set points.**", "**Rehearsal first.**",
              "**Check before telling.**", "**Read back decisions first.**"):
    assert check in partner, check
# Off-goal work stops for the human rather than getting a one-line note.
assert "off-goal and **stop and ask**" in partner
for phrase in ("**3 merges in one area**", "overrides it in one word", "log the override",
               "`tried: <how>` or `guess`", "recorded environment limits", "`Decisions in force: D3, D7`"):
    assert phrase in partner, phrase
for phrase in ("only a try moves an outcome row, never a merge",
               "You propose outcome rows and status changes; the human confirms them",
               "If a row's wording or status is in question, ask",
               "agree with the human each time who tries it", "mark stale outcome rows by hand",
               "Done means tried", "`awaiting try`"):
    assert phrase in main, phrase
state = read(refs / "state-template.md")
for phrase in ("## Outcomes (required, 3–7 rows)", "works / partly / doesn't / untried",
               "A merge never sets `works`", "last try is over 7 days old", "`rehearsal`", "D1 ("):
    assert phrase in state, phrase
lane = (refs / "lane-template.md").read_text()
assert lane.splitlines()[1].startswith("<O<n>:") and "Maintenance:" in lane.splitlines()[1]
for phrase in ("Outcome: <who> can <do what> on <which setup>.", "Tried by:",
               "Maintenance (no user outcome): one green PR.", "`not tried (why)`", "**Notes for later**"):
    assert phrase in lane, phrase
assert "## Recorded environment limits\n" in (refs / "coordination-template.md").read_text()
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "direct pointers retain both-agent ownership and once-only delivery gates" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
assert (skill / 'scripts/send.py').is_file()
contract = ' '.join((skill / 'references/legacy-herdr.md').read_text().split())
for phrase in ('Claude Code and Pi', '--ownership', 'caller_agent', 'delivery/<id>.json',
               'no automatic fallback', 'never resend', 'single STATE writer'):
    assert phrase in contract, phrase
for name in ('references/common-rules-template.md', 'references/lane-template.md'):
    text = (skill / name).read_text()
    assert 'ready nudge' in text, name
    assert 'legacy-herdr.md' in text and 'messaging.md' not in text, name
PY
  [ "$status" -eq 0 ]
}

@test "ready reply template starts with the action and its owner, not a verdict" {
  run python3 - "$SKILL_DIR/SKILL.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
reports = text.split("## Handling a report\n", 1)[1].split("\n## ", 1)[0]
reply = reports.split("**Reply**", 1)[1].split("\n4.", 1)[0]
assert "action and its owner first" in reply
first_line = reply.split("```text\n", 1)[1].splitlines()[0].strip()
assert first_line == "W<n> needs <action> from <owner>."
assert "not a done/not-done verdict" in " ".join(reply.split())
PY
  [ "$status" -eq 0 ]
}

@test "human attention push is once per state change and harness scoped" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
reports = ' '.join((skill / 'SKILL.md').read_text().split('## Handling a report\n', 1)[1].split('\n## ', 1)[0].split())
for phrase in ('once per lane state change', 'record it in STATE', 'harness-notes.md'):
    assert phrase in reports, phrase
# The harness notes keep the push tool's limits: presence check, never an approval channel.
harness = (skill / 'references/harness-notes.md').read_text()
assert 'PushNotification' in harness and 'presence check' in harness
assert 'never an approval channel' in harness
assert 'No equivalent callable push tool' in harness
PY
  [ "$status" -eq 0 ]
}

@test "lane guidance checks real outcomes and resolves project Git policy" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
coordinator = " ".join((skill / "SKILL.md").read_text().split())
lane = " ".join((skill / "references/lane-template.md").read_text().split())
closeout = " ".join((skill.parent / "pr-closeout/SKILL.md").read_text().split())
check = " ".join((skill.parent / "pr-closeout/references/coordinator-check.md").read_text().split())
for text in (check, lane):
    for phrase in ("human's current workflow", "infrastructure-only", "unverified",
                   "what the change gives the human", "why existing mechanisms do not already cover it"):
        assert phrase in text, phrase
common = " ".join((skill / "references/common-rules-template.md").read_text().split())
for text in (coordinator, lane, closeout, common):
    for phrase in ("COORDINATION.md", "repo rules", "ask on conflict", "method", "authority"):
        assert phrase in text, phrase
assert "Merge the base, resolve" not in closeout
assert "required adversarial readiness evidence" not in coordinator
assert "`/adversarial-review` before a PR" not in lane
assert "named uncovered risk or explicit request" in lane
PY
  [ "$status" -eq 0 ]
}

@test "coordinator carries remote evidence lessons and queue-aware overlap guidance" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
coordinator = " ".join((skill / "SKILL.md").read_text().split())
common = " ".join((skill / "references/common-rules-template.md").read_text().split())
closeout = " ".join((skill.parent / "pr-closeout/SKILL.md").read_text().split())
check = " ".join((skill.parent / "pr-closeout/references/coordinator-check.md").read_text().split())

for phrase in ("deliver every named input to the target host", "host paths verified to exist"):
    assert phrase in coordinator, phrase
for phrase in ("uniqueness or identity assumption", "tested by a lane"):
    assert phrase in coordinator, phrase
for phrase in ("recorded environment limits", "recorded facts"):
    assert phrase in coordinator, phrase
for phrase in ("decisions in force", "explicit `no X`"):
    assert phrase in coordinator, phrase

for text in (check, common, closeout):
    for phrase in ("merge queue", "combined head", "queue-ready"):
        assert phrase in text, (phrase, text[:80])
assert "detect or record merge-queue status" in common
assert "only for a real conflict" in common
assert "do not assume it" in common
assert "local HEAD = remote PR head = tested revision = CI revision" in check
assert "without a merge queue" in closeout
PY
  [ "$status" -eq 0 ]
}

@test "closeout shares one cross-family report-only attack review with polish" {
  run python3 - "$PACKAGE_DIR/skills" <<'PY'
from pathlib import Path
import re
import sys

skills = Path(sys.argv[1])
contract = skills / "pr-closeout/references/project-review-contract.md"
phase = contract.read_text().split("### One independent review phase\n", 1)[1].split("\n### ", 1)[0]
phase = " ".join(phase.split())
for phrase in ("one fresh whole-change reviewer", "configured model", "different family from the author's",
               "verify the resolved model", "both identities/families", "incomplete independence",
               "report-only", "falsify claims", "unneeded code", "reproductions",
               "complete file:line arguments", "attempted/disproved attacks",
               "not its two-reviewer dispatch", "no automatic fan-out",
               "evidence of this method/independence"):
    assert phrase in phase, phrase
mandate = re.search(r"\[Reviewer mandate\]\(([^)#]+)#reviewer-mandate\)", phase)
assert mandate, "Missing section-only mandate link"
assert "## Reviewer mandate\n" in (contract.parent / mandate.group(1)).read_text()
polish = (skills / "polish-core/SKILL.md").read_text()
dispatch = polish.split("### 3i: Dispatch Subagents\n", 1)[1].split("\nEach subagent receives:", 1)[0]
assert "one fresh whole-change reviewer" in dispatch
assert "project-review-contract.md#one-independent-review-phase" in dispatch
assert "report-only even in fix mode" in dispatch
assert "contract's linked Reviewer mandate" in polish
assert "Independent review: author <model/family>; reviewer <resolved model/family>; attacks <ledger/evidence>" in polish
report = polish.split("## Phase 5: Report\n", 1)[1].split("\n### ", 1)[0]
assert "Recompute final content identity after Phase 4" in report
assert "review affected scope under the shared contract or mark independent coverage incomplete" in report
assert "only the parent's own eligible findings are auto-fixes" in polish
assert "derive initial invariants from code before reading author reports or prior reviews" in polish
assert "subagent_type:" not in dispatch, "Roles must be chosen by configured/resolved family"
assert "Reviewer mandate" not in dispatch, "Keep the mandate summary in the contract"
closeout = (skills / "pr-closeout/SKILL.md").read_text()
assert "do not add a second automatic review" in closeout
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
               "Never remove or swap them",
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

refs = Path(sys.argv[1]) / "references"
lane = (refs / "lane-template.md").read_text()
common = (refs / "common-rules-template.md").read_text()
assert "If none exist:" not in lane
# One home: the shared workflow carries the fallback; the lane template points to it.
assert "Git policy exists" not in lane and "no-policy Git fallback" in lane
fallback = " ".join(common.split("Without project or repo Git policy,", 1)[1].split())
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
routines = text.split("## Routines\n", 1)[1].split("\n## ", 1)[0]
start = routines.split("**Coordinate:**", 1)[1].split("**End of day:**", 1)[0]
for phrase in ("coordinate <project>", "end of day <project>", "weekly <project>"):
    assert phrase in text.split("\n---", 1)[0], phrase
    assert phrase in routines, phrase
for phrase in ("only one project folder", "Routines", "**unknown**", "grant no authority"):
    assert phrase in " ".join(routines.split()), phrase
for phrase in ("18 hours", "last STATE commit", "7 days", "missing", "stale outcome rows by hand"):
    assert phrase in " ".join(start.split()), phrase
assert start.index("pick-up test") < start.index("drift report") < start.index("morning") < start.index("status reply")
assert "don't run it unasked" in " ".join(start.split())
morning = (skill / "references/morning.md").read_text()
assert "--json state,headRefOid,statusCheckRollup" in morning
assert "## Disk routine (end of day and weekly)\n" in morning, "Missing disk routine"
disk = " ".join(morning.split("## Disk routine (end of day and weekly)\n", 1)[1].split("\n## ", 1)[0].split())
for phrase in ("five largest lane folders with sizes", "private reports only", "free-space threshold",
               "**Needs the human**", "unknown, not healthy", "never infer deletion approval from a disk warning",
               "If no disk-check command exists", "inspect only configured roots manually",
               "observation time", "missing commands, roots or measurements unknown",
               "Cleanup follows STATE's exact-list approval rules"):
    assert phrase in disk, phrase
eod = " ".join(routines.split("**End of day:**", 1)[1].split("**Weekly:**", 1)[0].split())
assert "disk check" in eod and "step-back paragraph" in eod
coordination = (skill / "references/coordination-template.md").read_text()
for phrase in ("## Routines", "Drift check", "Morning sweep", "Budget", "report",
               "Disk check (end of day + weekly)", "minimum free GiB", "explicit roots"):
    assert phrase in coordination, phrase
for stamp in ("Last end of day: <date time>", "Last weekly pass: <date>"):
    assert stamp in routines and stamp in (skill / "references/state-template.md").read_text(), stamp
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

@test "lane handoffs share the project's report location" {
  grep -Fq "same location as the lane's report" "$SKILL_DIR/references/lane-template.md"
  grep -Fq 'reports/W<n>-HANDOFF.md' "$SKILL_DIR/references/lane-template.md"
  run grep -Fq '<lanes>/W<n>-HANDOFF.md' "$SKILL_DIR/references/lane-template.md"
  [ "$status" -eq 1 ]
  grep -Fq 'handoffs alongside reports' "$SKILL_DIR/SKILL.md"
  grep -Fq 'including the handoff' "$SKILL_DIR/references/legacy-herdr.md"
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
# Review loading and size defaults have one home in pr-closeout; the lane template points there.
assert "Read only [Review evidence]" in closeout and "Only the coordinator writes profiles" in closeout
assert "`pr-closeout` for the one review phase" in lane
for phrase in ("~1k hand-written product lines", "~1.5× product", "~1k changed lines in total",
               "COORDINATION.md", "otherwise treat", "project's own rule wins"):
    assert phrase in closeout, phrase
    assert phrase == "COORDINATION.md" or phrase not in lane, phrase
assert "~1.5k" not in closeout
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

skill = Path(sys.argv[1])
text = (skill / "SKILL.md").read_text()
prompt = " ".join(text.split("## Partner checks\n", 1)[1].split("\n## Start only", 1)[0].split())
for phrase in ("Before advising action",
               "refresh the live PR/head/CI and session state it relies on",
               "an open lane is not a running session",
               "existing tool already covers it", "sibling projects' Routines and tools"):
    assert phrase in prompt, phrase
# A merge moves no outcome; merges are counted per area and the check lists what a PR unblocks.
flat = " ".join(text.split())
assert "only a try moves an outcome row, never a merge" in flat
assert "**3 merges in one area**" in flat
check = " ".join((skill.parent / "pr-closeout/references/coordinator-check.md").read_text().split())
assert "every lane the PR unblocks or conflicts with" in check
state = " ".join((skill / "references/state-template.md").read_text().split())
for phrase in ("respecting each decision's scope", "do not make route-specific dependencies global"):
    assert phrase in state, phrase
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
    if name != "SKILL.md":
        assert condition in text, name
assert "stop/resume lines for overnight lanes" in texts["SKILL.md"]
assert "Decisions in force carry IDs (`D1`…)" in texts["SKILL.md"]
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
for phrase in ("one home per fact", "one-word state", "PR numbers without heads or CI",
               "next actor and action", "report path", "## Needs the human", "ordered one-liners",
               "## Waiting on others", "not already a lane row's next actor", "at most about 10",
               "not already in the project's rule files", "dated or triggered items", "not already in a lane row",
               "Parked: <links to paused lane rows", "all current resume conditions and who decides"):
    assert phrase in " ".join(state.split()), phrase
text = (skill / "SKILL.md").read_text()
# Write-time steps live in the template's header; the skill keeps the rule and the pick-up test.
updates = " ".join(state.split("<!-- Writing it:", 1)[1].split("-->", 1)[0].split())
decisions = " ".join(state.split("## Decisions in force\n", 1)[1].split("\n## ", 1)[0].split())
for phrase in ("Closing a lane", "same update", "CLOSED-<month>.md", "archive", "Replace, don't add", "one home"):
    assert phrase in updates, phrase
for phrase in ("25 words", "full record", "Done or superseded", "rule files", "oldest", "archive", "D1 ("):
    assert phrase in decisions, phrase
for phrase in ("exact deletion list with sizes", "lane report/handoff",
               "**Needs the human** until decided", "only after the human approves that exact list",
               "Unknown safety or size is not deletion-ready", "refuse to overwrite a file changed since"):
    assert phrase in updates, phrase
flat = " ".join(text.split())
assert "**Replace, don't add**" in flat and "each outcome's status and the human's next decision" in flat
eod = " ".join(text.split("**End of day:**", 1)[1].split("**Weekly:**", 1)[0].split())
for phrase in ("drift check", "budget", "lane reports", "archive", "step-back paragraph",
               "tomorrow's first actions", "Last end of day"):
    assert phrase in eod, phrase
weekly = " ".join(text.split("**Weekly:**", 1)[1].split("**Human away", 1)[0].split())
for phrase in ("re-try each outcome row", "duplicate", "superseded", "intent check",
               "at most 3 notes", "reports/BACKLOG-NOTES.md", "reports/SKILL-FRICTION.md"):
    assert phrase in weekly, phrase
assert "Full record: `reports/decision.md`." in state
PY
  [ "$status" -eq 0 ]
}

@test "coordinator closes only a verified idle closed lane workspace" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
state = (skill / "references/state-template.md").read_text()
step = " ".join(state.split("<!-- Writing it:", 1)[1].split("-->", 1)[0].split())
for phrase in ("in the bundled skill's order", "report and handoff are saved", "it is a deletion",
               "legacy reference's \"Close a closed lane's workspace\""):
    assert phrase in step, phrase
legacy = (skill / "references/legacy-herdr.md").read_text()
closing = " ".join(legacy.split("## Close a closed lane's workspace\n", 1)[1].split("\n## ", 1)[0].split())
for phrase in ("launch receipt or its exactly one current workspace", "report and handoff are already in the project's report location",
               "idle or done", "working, blocked, unknown or ambiguous identity", "immediately before close",
               "herdr workspace close <id>", "status check and close are not atomic", "record success in the archive line", "inspect-only",
               "do not retry automatically or record closure until reconciled", "not a deletion",
               "do not close a coordinator's own workspace",
               "Worktree, branch, sandbox and file deletion rules are unchanged"):
    assert phrase in closing, phrase
remote = " ".join(legacy.split("### Close a closed remote lane workspace\n", 1)[1].lower().split())
for phrase in ("fetch first", "recorded ssh binding", "lane's own workspace", "launch receipt or exactly one",
               "idle or done", "immediately before close", "status check and close are not atomic",
               "working, blocked, unknown, ambiguous identity",
               "report and handoff", "record success", "inspect only", "do not retry automatically",
               "closure unknown until reconciled"):
    assert phrase in remote, phrase
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

text = (Path(sys.argv[1]).parent / "pr-closeout/references/coordinator-check.md").read_text()
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
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys
skill = Path(sys.argv[1])
assert "../pr-closeout/references/coordinator-check.md" in (skill / "SKILL.md").read_text()
text = " ".join((skill.parent / "pr-closeout/references/coordinator-check.md").read_text().split())
assert "../SKILL.md#bounded-waiting" in text
assert "../SKILL.md#snapshot-helper" in text
assert "unreadable final PR observation, refresh before recommending ready" in text
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

@test "lane templates require an explicit host choice and remote binding or reason" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

refs = Path(sys.argv[1]) / "references"
lane = (refs / "lane-template.md").read_text()
host_lines = [line for line in lane.splitlines() if line.startswith("Host:")]
assert len(host_lines) == 1, "Lane template needs one explicit Host field"
assert host_lines[0].startswith("Host: <") and "reason" in host_lines[0], "Host field needs a choice and reason"
assert "(default)" not in host_lines[0], "Host field must not silently preselect local"
coordination = (refs / "coordination-template.md").read_text()
assert "## Hosts\n" in coordination, "Missing host bindings table"
assert "Project root" in coordination and "Worktree root" in coordination
assert "Use for" in coordination and "Binding or reason" in coordination
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "lane workers are an explicit host choice with our habits and a frozen Herdr reference" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import re
import sys

skill = Path(sys.argv[1])
refs = skill / "references"
read = lambda path: " ".join(path.read_text().split())
main, lane = read(skill / "SKILL.md"), read(refs / "lane-template.md")
coordination, common, legacy = (read(refs / name) for name in
                                ("coordination-template.md", "common-rules-template.md", "legacy-herdr.md"))

for text in (main, lane):
    assert "`Worker: lane`" in text or "`Worker` is `lane`" in text
# lanes appends the task ID to the label, so the label carries only our lane number.
assert '--label "W<n>" --by <project>-coord' in main and "lanes appends the task ID" in main
assert '--label "<project> W<n>"' not in main
assert "`--input` files" in main
# The former hosts reference folded into the skill.
for phrase in ("saved host/worker enrollment", "STATE, other lanes' context and credentials stay home",
               "only to hosts its Hosts table allows", "a displayed remote path is not a local copy",
               "not a replacement", "(references/covered-answers.md)", "reuses the same prompt file"):
    assert phrase in main, phrase
assert "## Remote lanes on Herdr hosts" in (refs / "legacy-herdr.md").read_text()
assert "| Worker |" in coordination
assert "`lane`" in coordination and "opt in" in coordination.lower()
assert "without `lane` keeps" in lane

# One frozen legacy file holds every Herdr-only path; the old files only point at it.
raw_legacy = (refs / "legacy-herdr.md").read_text()
header = raw_legacy.split("## Attention and notes on every turn")[0]
assert "For hosts that are not lane workers; no new changes." in header
for heading in ("## Attention and notes on every turn", "## Handoff line and session names",
                "## Start a lane on a Herdr host", "## Close a closed lane's workspace",
                "## Explicit Herdr lane launch", "### Manual local handoff", "## Local messages and attention",
                "### Optional once-only local pointers", "### Explicit remote command", "#### Claude Code lanes",
                "### Fetch before judging readiness", "### Close a closed remote lane workspace"):
    assert heading + "\n" in raw_legacy, heading
for phrase in ("herdr-lane --host <binding>", "scripts/messages.py", "scripts/send.py", "scripts/launch.py",
               "reports/inbox/", "herdr workspace close <id>"):
    assert phrase in legacy, phrase
# The moved-file stubs and folded references are gone; the legacy file holds their targets.
for name in ("messaging.md", "herdr-launch.md", "remote-lanes.md", "light-process-template.md"):
    assert not (refs / name).exists(), name
for script in ("launch.py", "send.py", "messages.py", "morning.py", "codex-review.sh", "claude-review.sh"):
    assert (skill / "scripts" / script).is_file(), script

# Lanes write the readiness evidence file and mark observed or inferred claims.
for phrase in ("`reports/<number>-evidence.json` next to its report", "with the file-write tool",
               '"prompt_sha256"', '"ci_head"', '"ready_claimed_at"', "`lanes/<number>-launch.json`",
               "not an approval", "re-observe an inferred claim", "keep it fixed for that claim",
               "An older `lane` ignores the file"):
    assert phrase in common, phrase
for phrase in ("writes the evidence file the shared workflow describes", "readiness checks",
               "**observed** (command or source) or **inferred**"):
    assert phrase in lane, phrase
assert "`readiness` is evidence beside these checks" in main and "verify the PR yourself" in main

lane_template = (refs / "lane-template.md").read_text()
goals = re.findall(r"(?m)^#{1,2} Goal[ \t]*\r?\n(?:\r?\n)*([^\r\n]+)", lane_template)
assert len(goals) == 1 and goals[0].strip(), goals
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "coordinator answers only covered question cards and re-checks before replying" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1])
refs = skill / "references"
read = lambda path: " ".join(path.read_text().split())
main, covered = read(skill / "SKILL.md"), read(refs / "covered-answers.md")
common, messaging = (read(refs / name) for name in ("common-rules-template.md", "legacy-herdr.md"))

assert "[covered answers](references/covered-answers.md)" in main
assert "anything unclear goes to the human" in main.lower()
for text in (covered, common):
    for phrase in ("existing decision or standing rule already", "publish within the repository's PR rules",
                   "continue within approved scope", "fix in-scope review findings",
                   "routine sandbox approvals", "design approvals", "merges, deploys", "live cloud changes",
                   "deletions beyond the cleanup rule", "text addressed to people",
                   "scope or cost changes"):
        assert phrase in text, phrase
    assert "credentials" in text and "sign-ins" in text
    assert "anything unclear go" in text.lower()
for phrase in ("Cite the rule or decision", "in the answer note", "in STATE",
               "Tell the human in one line", "grants nothing new", "authority table lets lanes publish"):
    assert phrase in covered, phrase
assert "note cites the rule" in common and "adds no publication or other authority" in common
for phrase in ("under `approvers` in the project's lane `config.json`", "An unlisted gate is owner only",
               "Always pass `--by`; never answer as the owner", "relay only what the owner already decided",
               "do not retry without it"):
    assert phrase in covered, phrase
command = covered.split("`lane answer <task> <key>")[1].split("`")[0]
for flag in ("--by <coordinator-id>", "--expected-hash <card sha256>", "--note"):
    assert flag in command, flag
assert "the gate lists you as an approver" in main and "lists it as an approver for that gate" in common
for phrase in ("Read status immediately before answering", "pass that row's card hash",
               "If the card changed since you matched it to the rule, stop"):
    assert phrase in covered, phrase
assert "On a Herdr host, if the wrapper" in messaging and "(covered-answers.md)" in messaging
assert "started by `lane` skips the note checkpoint and ready nudge" in common
assert "read only notes its prompt names" in common

reply = main.split("3. **Reply**")[1].split("4. Answer")[0]
assert "Re-observe before saying something waits on the human" in reply
assert "re-observed now, not copied from an earlier message" in main
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "remote rsync example passes user at host without an unsupported login flag" {
  command -v rsync >/dev/null || skip "rsync unavailable for transport example"
  run python3 - "$SKILL_DIR/references/legacy-herdr.md" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
assert path.is_file(), "Missing remote-lane reference"
assignment = re.search(r"^remote_shell=.*$", path.read_text(), re.M)
assert assignment, "Missing runnable remote-shell example"
print(assignment.group())
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
  eval "$output"
  stub_command tailscale 'printf "%s\n" "$@" >"$TEST_ROOT/transport-argv"; exit 1'
  printf 'lane prompt\n' >"$TEST_ROOT/prompt.md"
  run rsync -a -e "$remote_shell" "$TEST_ROOT/prompt.md" build-host:/home/example/project-local/lanes/task.md
  [ "$status" -ne 0 ] # The transport observer deliberately is not an rsync server.
  run python3 - "$TEST_ROOT/transport-argv" <<'PY'
from pathlib import Path
import sys

args = Path(sys.argv[1]).read_text().splitlines()
assert args[:3] == ["ssh", "example@build-host", "rsync"], args
assert "-l" not in args, args
assert args[-1] == "/home/example/project-local/lanes/task.md", args
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "remote fetch example fails when only supplementary evidence exists" {
  python3 - "$SKILL_DIR/references/legacy-herdr.md" "$TEST_ROOT/fetch.sh" <<'PY'
from pathlib import Path
import fnmatch
import re
import sys

blocks = re.findall(r"```sh\n(.*?)\n```", Path(sys.argv[1]).read_text(), re.S)
assert fnmatch.fnmatch("W12-HANDOFF.md", re.search(r"/reports/([^']*\*)'", blocks[-1])[1])
Path(sys.argv[2]).write_text(blocks[-1])
PY
  # External transfer boundary: required report absent, matching evidence present.
  stub_command rsync 'case "${@: -2:1}" in *W12-REPORT.md) exit 23 ;; *W12-\**) exit 0 ;; *) exit 99 ;; esac'
  run bash "$TEST_ROOT/fetch.sh"
  [ "$status" -eq 23 ] || {
    echo "Expected missing-report exit 23; got $status"
    false
  }
}

@test "messaging protocol has one home and bundled skills name their SKILL.md path" {
  run python3 - "$PACKAGE_DIR/skills" <<'PY'
from pathlib import Path
import sys

skills = Path(sys.argv[1])
refs = skills / "lane-coordinator/references"
messaging = " ".join((refs / "legacy-herdr.md").read_text().split())
for phrase in ("disposition=<pending|applied", "tom-decision", "A stale prompt hash is rejected",
               "inspect-only", "it never writes STATE"):
    assert phrase in messaging, phrase
for name in ("lane-template.md", "common-rules-template.md"):
    text = " ".join((refs / name).read_text().split())
    for restated in ("tom-decision", "pending before action", "A stale prompt hash"):
        assert restated not in text, (name, restated)
    assert "`<resolved skills dir>/<name>/SKILL.md`" in text, name
    assert "`pr-text`" in text, name
common = " ".join((refs / "common-rules-template.md").read_text().split())
for phrase in ("never STATE", "source-verified human decision", "never permits a resend, fallback",
               "Unreadable prompt, notes or contract mean blocked"):
    assert phrase in common, phrase
opinion = " ".join((skills / "second-opinion-core/SKILL.md").read_text().split())
for phrase in ("explicitly delegates plan corrections within an already-approved design",
               "explain each rejection", "design, scope or authority still pauses",
               "Standalone mode returns findings only"):
    assert phrase in opinion, phrase
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

@test "claude lane settings template is generic JSON with placeholders and credential denies" {
  run python3 - "$SKILL_DIR" <<'PY'
from pathlib import Path
import json
import sys

skill = Path(sys.argv[1])
raw = (skill / "references/claude-lane-settings.json").read_text()
perms = json.loads(raw)["permissions"]
assert perms["defaultMode"] == "auto"
assert perms["additionalDirectories"] == ["<worktree-root>", "<canonical-checkout>", "<project-local>"]
assert "Edit(<canonical-checkout>/**)" in perms["deny"]
assert not [rule for rule in perms["deny"] if rule.startswith("Write(")]
for secret in ("~/.ssh/**", "~/.claude/.credentials.json", "~/.codex/auth.json", "~/.config/gh/hosts.yml"):
    assert f"Read({secret})" in perms["deny"], secret
assert "Bash(gh pr merge:*)" in perms["deny"]
assert "dotfiles" not in raw.lower()
notes = (skill / "references/harness-notes.md").read_text()
assert "## Subscription lanes (Claude Code, Codex)" in notes
for name in ("codex-review.sh", "claude-review.sh"):
    assert f"scripts/{name}" in notes, name
PY
  [ "$status" -eq 0 ] || {
    echo "$output"
    false
  }
}

# Only the stubs and the tools the review scripts use, so a host's real reviewer never runs.
review_path() {
  local tool
  mkdir -p "$TEST_ROOT/review-bin"
  for tool in bash cat dirname; do
    ln -sf "$(command -v "$tool")" "$TEST_ROOT/review-bin/$tool"
  done
  printf '%s' "$STUB_BIN:$TEST_ROOT/review-bin"
}

@test "review scripts reject bad arguments and missing reviewers without output files" {
  printf 'review\n' >"$TEST_ROOT/prompt.md"
  local reviewer_path
  reviewer_path=$(review_path)
  for script in codex-review.sh claude-review.sh; do
    run bash "$SKILL_DIR/scripts/$script"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: $script"* ]]
    run bash "$SKILL_DIR/scripts/$script" "$TEST_ROOT/missing.md" "$TEST_ROOT/out"
    [ "$status" -eq 2 ]
    [[ "$output" == *"prompt file not readable"* ]]
    run bash "$SKILL_DIR/scripts/$script" "$TEST_ROOT/prompt.md" "$TEST_ROOT/nodir/out"
    [ "$status" -eq 2 ]
    [[ "$output" == *"output directory missing"* ]]
    ln -sf "$TEST_ROOT/prompt.md" "$TEST_ROOT/alias.stderr"
    run bash "$SKILL_DIR/scripts/$script" "$TEST_ROOT/prompt.md" "$TEST_ROOT/alias"
    [ "$status" -eq 2 ]
    [[ "$output" == *"would overwrite the prompt"* ]]
    # Not `run`: it warns on 127, which is the intended "command not found" status.
    status=0
    output=$(PATH="$reviewer_path" bash "$SKILL_DIR/scripts/$script" "$TEST_ROOT/prompt.md" "$TEST_ROOT/out" 2>&1) || status=$?
    [ "$status" -eq 127 ]
    [[ "$output" == *"not found on PATH"* ]]
  done
  assert_file_absent "$TEST_ROOT/out.exit"
}

@test "codex review reads the prompt from stdin to EOF, runs read-only and records output and exit" {
  printf 'find bugs\n' >"$TEST_ROOT/prompt.md"
  local reviewer_path
  reviewer_path=$(review_path)
  stub_command codex 'printf "%s\n" "$@" >"$TEST_ROOT/args"; cat >"$TEST_ROOT/stdin"; echo findings; echo warn >&2; exit 3'
  PATH="$reviewer_path" run bash "$SKILL_DIR/scripts/codex-review.sh" "$TEST_ROOT/prompt.md" "$TEST_ROOT/out"
  [ "$status" -eq 3 ]
  [ "$output" = 3 ]
  [ "$(cat "$TEST_ROOT/out.md")" = findings ]
  [ "$(cat "$TEST_ROOT/out.stderr")" = warn ]
  [ "$(cat "$TEST_ROOT/out.exit")" = 3 ]
  [ "$(cat "$TEST_ROOT/stdin")" = "find bugs" ]
  [ "$(cat "$TEST_ROOT/args")" = "$(printf '%s\n' exec --skip-git-repo-check --sandbox read-only -- -)" ]

  rm "$STUB_BIN/codex"
  stub_command mise 'printf "%s\n" "$@" >"$TEST_ROOT/args"; exit 0'
  CODEX_REVIEW_MODEL=m1 PATH="$reviewer_path" run bash "$SKILL_DIR/scripts/codex-review.sh" "$TEST_ROOT/prompt.md" "$TEST_ROOT/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/out.exit")" = 0 ]
  [ "$(head -5 "$TEST_ROOT/args" | tr '\n' ' ')" = "exec -- codex exec --skip-git-repo-check " ]
  grep -Fxq m1 "$TEST_ROOT/args"
}

@test "claude review sends the prompt on stdin with edit and shell tools disallowed" {
  printf 'find bugs\n' >"$TEST_ROOT/prompt.md"
  local reviewer_path
  reviewer_path=$(review_path)
  stub_command claude 'printf "%s\n" "$@" >"$TEST_ROOT/args"; cat >"$TEST_ROOT/stdin"; echo findings'
  CLAUDE_REVIEW_MODEL=m2 PATH="$reviewer_path" run bash "$SKILL_DIR/scripts/claude-review.sh" "$TEST_ROOT/prompt.md" "$TEST_ROOT/out"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
  [ "$(cat "$TEST_ROOT/stdin")" = "find bugs" ]
  [ "$(cat "$TEST_ROOT/out.md")" = findings ]
  [ "$(cat "$TEST_ROOT/out.exit")" = 0 ]
  [ "$(tr '\n' ' ' <"$TEST_ROOT/args")" = "-p --model m2 --disallowedTools Edit Write Bash NotebookEdit " ]
}
