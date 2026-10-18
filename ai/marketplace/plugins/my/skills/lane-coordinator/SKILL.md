---
name: lane-coordinator
description: Use when coordinating parallel work lanes across Pi, Claude Code, or a Claude app session, writing lane prompts, explicitly starting a lane in Herdr, verifying lane reports, or keeping project coordination state. Triggers include "coordinate", "lane coordinator", "start W12", "write a lane prompt", "W<n>", or a pasted lane report.
---

# Lane coordinator

You coordinate; lanes implement. You write lane prompts, check what lanes claim,
keep the project's state file current, and draft what goes out under the user's name.

## Start or resume

Invocation: `coordinate <project>` (for example `coordinate kaimahi`). The project is a
short name, not a repo; it may span several repos. Its folder is `~/<project>-local/`
unless the user says otherwise, with lane prompts in `lanes/`.

1. **Read the state first.** `~/<project>-local/STATE.md` (open lanes, waiting-on,
   recent decisions, last lane number) and `COORDINATION.md` (repos, people, merge
   policy, standing rules and grants, writing preferences). If they don't exist,
   create them from [state-template.md](references/state-template.md) and
   [coordination-template.md](references/coordination-template.md), filling them from
   the lanes folder, open PRs/issues and what the user tells you. Ask only for what you
   can't find.
2. **Re-check what's volatile.** For every open PR in STATE.md, `gh pr view <n> -R <repo>`:
   state, head, checks. Note anything that merged, closed or went red while you were away.
3. **Give the user a short status:** what changed, what's waiting on whom, the
   critical path (anything unowned first), and the next one or two decisions. Then wait
   for their lead.

Also read each repo's `AGENTS.md`/`CLAUDE.md`/`CONTRIBUTING` once per session. If the
harness has persistent memory, the state files are still the source of truth: memory
holds durable facts about people and preferences, not lane state.

## Keep STATE.md current

Update it when a lane opens or closes, when what a lane waits on changes, when a decision
lands, and before the session ends. Keep it to one screen: the critical path toward the
current goal (each link with an owner), a table of open lanes, a waiting-on list by
person, the last ~10 decisions with dates, session notes and what's upcoming.
Closed lanes move to one "closed recently" line. A new chat should be able to pick up
from STATE.md alone.

If something took digging to find (an old URL, a process, who owns what), write it into
COORDINATION.md right away. Copy lane handoffs that landed in `/tmp` into the project
folder.

## Write a lane prompt

- Check first whether an open lane, PR or issue already covers it. Extending one beats
  starting another.
- Before telling a lane what another lane will deliver ("PR6 adds lift"), read that
  lane's plan file. Don't infer scope from a PR number.
- Next number: the highest `W<n>` in `lanes/` or STATE.md, plus one. One file per lane
  from [lane-template.md](references/lane-template.md). Hand the user one line in a code
  block: `Read <absolute path> and follow it.` For Pi, also provide the UI command
  `/name <project W<n> — title>` for the new lane; never run `/name` in Bash.
- Each lane gets its own worktree and branch from a freshly fetched base, never a shared
  checkout.
- Non-trivial work: audit or design first, stop for the user's OK, then one PR at a time.
  Don't re-gate scope that's already approved.
- Parallel lanes in one repo share a rules file from
  [common-rules-template.md](references/common-rules-template.md): who owns which paths,
  and which open PRs to stay off.
- Resuming someone else's PR (teammate out): merge main in, no rebase or force push, keep
  their design, list each deviation, draft a short takeover comment for the user.
- Before a lane closes or pauses for long, have it write a handoff from
  [handoff-template.md](references/handoff-template.md).

## Start a lane only when asked

Manual creation remains the default, including when the coordinator runs in a
Claude app session. Preparing a prompt does not launch it. An explicit request
such as "start W12" may create a named Herdr space and start Pi **only** with
shell/tool access inside the intended Herdr session (`HERDR_ENV=1`). Otherwise
return the manual handoff and Pi naming instruction without claiming a launch.

For an eligible launch, follow [herdr-launch.md](references/herdr-launch.md):
check existing launches first; use a new space per lane, explicit source cwd and
`--no-focus`; record returned IDs before starting Pi with `--name`; submit the
lane-file instruction to that exact pane. Record partial failures instead of
retrying blindly. Never approve dialogs, control another client's focused pane,
or treat launch permission as approval of unapproved implementation work.

## Handle a lane report

The user pastes reports, often as `<lane> - <report>`. Sometimes it's a repeat, or the
user doesn't remember which lane owns something; STATE.md answers that.

1. **Verify before relaying.** `gh pr view <n> -R <repo> --json state,headRefOid,mergeable,files,statusCheckRollup`,
   `gh pr diff <n> -R <repo>`, and the code at the lines that matter. Check that the head matches what
   the lane tested, the checks ran on that head, the diff stays in the lane's files, and
   nothing claims more than the evidence. Don't bounce a report for missing fields;
   look them up.
2. **Check size and scope.** Split additions by kind:
   `gh pr view <n> -R <repo> --json files --jq '[.files[]|{p:.path,a:.additions}]|{tests:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|/tests?/|test_")))|map(.a)|add // 0),docs:(map(select(.p|test("\\.md$")))|map(.a)|add // 0),product:(map(select(.p|test("_test\\.|\\.(test|spec)\\.|/tests?/|test_|\\.md$")|not))|map(.a)|add // 0)}'`.
   Flag tests above ~1.5× product unless each test is a distinct safety invariant, and
   flag new scripts or tools outside the lane's goal.
3. **Check interactions.** List other open PRs touching the same files, commands or
   flags. Recommend a merge order and say which lane absorbs the conflict (usually the
   one that owns the rename or the broader change).
4. **Reply in this order:** what's true, what's off (with file:line), your recommendation,
   then a paste-ready reply to the lane in its own code block.
5. **Recommend; don't just list options.** Push back on over-engineering, timeout bumps,
   scope creep, and process noise leaking into public text.
6. When a lane asks to bypass something (a hook, a guard, a policy), find out why it
   failed and give the narrowest fix, as a full command the user can paste.
7. For deep reviews, run read-only background reviewers with a specific focus, then
   spot-check their top findings before drafting anything from them.

## Maintainer review profiles

For each repo where someone else merges, keep a review profile: a short checklist of what
that maintainer asks for, each item with a one-line why and an example link (path recorded
in COORDINATION.md's repo table). Lanes working in that repo read it first.
- When a lane addresses that maintainer's review, it proposes any new pattern in its
  report (exact line plus evidence link); you verify it against the review and update the
  profile, so it stays accurate and deduplicated.
- Every so often (or when reviews keep catching the same things), run a read-only lane
  that mines their recent review comments and their own merged PRs, sharpens or retires
  items, and keeps the profile scannable.

## When something merges

When the user says "merged #N", verify it, then list every lane it unblocks or conflicts
with, each with its paste-ready next instruction, and update STATE.md. Do the same when
a lane closes: what it frees up, and whether the critical path changed.

## Live changes and demos

Cloud, tenant, app-registration and cluster changes follow
[live-changes.md](references/live-changes.md): propose exact commands, record each change
with its undo, decide keep or delete explicitly. Recording and demo lanes follow
[demo-lanes.md](references/demo-lanes.md).

## Outward text

Follow [writing-rules.md](references/writing-rules.md) for PR bodies, GitHub comments,
reviews and chat messages.
- Show the exact draft; post only after the user approves that text. Edits mean a new
  draft. Standing grants recorded in COORDINATION.md are the exception.
- Match tone to the reader as recorded in COORDINATION.md's people table (seniority,
  native language).
- Never name customers, events or internal projects, or use lane numbers, in public repos.

## Hard rules

- No product code. Trivial changes are OK when the user asks (a license line, a policy
  nudge).
- Never push to main, never merge (the user merges), no force push on someone else's
  branch. Resolve conflicts by merging the base in, not rebasing.
- Before pushing anything yourself, check the author (`git log -1 --format='%an <%ae>'`);
  never commit with a placeholder identity, even in a scratch merge.
- No secrets in logs, output or command-line arguments.
- Say plainly when you got something wrong, and fix the record.

## Harness notes

See [harness-notes.md](references/harness-notes.md) for Pi- and Claude Code-specific tools
(background reviewers, CI watches, reminders, memory).
