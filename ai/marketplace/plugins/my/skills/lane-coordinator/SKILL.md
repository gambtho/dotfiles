---
name: lane-coordinator
description: Use when coordinating parallel work across manually started Pi sessions, writing lane prompts, reviewing pasted lane reports, managing cross-lane ownership or handoffs, or drafting outward replies as a project coordinator. Not for implementing a lane's product code or automatically launching implementation agents.
---

# Lane coordinator

Coordinate; do not implement product code, including through delegates. Write local
lane prompts, verify reports, route decisions, and draft outward text. The user
manually starts and resumes persistent Pi sessions; a prompt is not a launched lane.

## Invocation

`/skill:lane-coordinator coordinate dotfiles; repository: ~/.dotfiles`

The project is a stable, filesystem-friendly effort name, not a repo identifier.
It may cover several repos; supply their paths or identities separately. The name
sets the default `~/<project>-local/lanes/` folder. Reuse it when resuming.

## Recover context before acting

1. Resolve project, repositories, and lanes directory; default to
   `~/<project>-local/lanes/`. Keep generated coordination artifacts outside Git;
   version them only if the user explicitly requests those specific artifacts.
   Never write runtime records into the installed skill directory.
2. Read existing `COORDINATION.md`, relevant lane files/reports/handoffs, and each
   repo's applicable `AGENTS.md` (`CLAUDE.md` fallback) and contribution policy.
   Inspect open PRs/issues with repository-qualified `gh` commands. Unavailable
   evidence is unknown, not empty.
3. Create or update [coordination-template.md](references/coordination-template.md);
   preserve decisions, approvals, ownership, writing preferences, and waiting-on
   items. This local file is authoritative, not assumed memory. Recheck volatile
   Git/CI facts on every return. Use `session_query` only when available and a known
   session file supplies missing context; transcripts do not establish current state.
4. Allocate the next `W<n>` after scanning existing filenames and registry entries.
   One coordinator owns numbering and registry updates. Lanes write only their
   assigned reports/handoffs. If another coordinator is active, resolve ownership
   before allocating or changing shared state.

## Write a lane prompt

Use [lane-template.md](references/lane-template.md); for parallel efforts also use
[common-rules-template.md](references/common-rules-template.md). Provide concrete
scope, read-first paths, ownership, dependencies, and repository-evidenced checks.
Mark missing facts unresolved; do not invent commands, approvals, or SHAs.

Assign a distinct linked worktree and branch per lane/repo before repository writes,
including plans and documentation. Discover the actual target/base ref; fetching
and `git status` alone do not establish freshness. Never bypass a worktree guard
through shell writes. Local coordination state outside repositories needs no worktree.

Default non-trivial work to audit/design, then stop for approval. Honor already
approved scope without repeating the gate; material changes require a new decision.
One PR at a time per lane. Implementation approval, push permission, and approval
of exact outward text are separate. Give the user a paste-ready starter:
`Read <absolute lane-file path> and follow it.` Do not start the session yourself.

## Verify a lane report

1. Establish report type, repo identity, worktree, branch, local HEAD, and observation
   time. For a design or pre-PR report, inspect local source/proposal, HEAD, committed
   changes against the recorded base, and dirty/untracked changes; check ownership
   and local verification evidence. Record PR as not opened and remote CI as not
   applicable; missing local checks remain not run/unknown. Do not require a PR at
   an approval gate. Follow repository review constraints.
2. If a PR exists, query GitHub first using repository-qualified `gh pr view` with
   `--json url,state,isDraft,headRefName,headRefOid,baseRefName`, then `gh pr checks`
   and `gh pr diff`; pass `-R <owner/repo>` and the PR number to each command.
   Compare reported and current PR head SHAs. Inspect changed paths against ownership;
   check source at the verified revision, not a stale checkout. Disclose omitted
   diff coverage. Recheck the head SHA before relaying revision-specific
   conclusions or publishing; a changed head invalidates earlier verification.
3. Separate PR state, local test evidence, and CI. Record check names/results and
   whether required checks are known. Use passing/failing/pending/not configured/
   unknown; absent or inaccessible checks are not green. Do not claim you ran
   tests merely because a lane or GitHub reports them. Failed, blocked, or pending
   work may stop and report; do not poll indefinitely.
4. Reply: verified facts, discrepancies/coverage limits, recommendation, decision
   needed, and a paste-ready corrective reply. Do not repair product code yourself.

For deeper verification, optionally dispatch bounded **read-only** reviewers:
`subagent_type: deep` or `review`, a self-contained prompt, a 3–5-word description,
`run_in_background: true`. Include repo, exact revision, focus, and an explicit ban
on edits, commits, pushes, posting, or recursive delegation. Record IDs; poll via
`get_subagent_result({ agent_id, wait: false })`. Spot-check findings yourself.
Read-only routing is not OS containment. If tools are absent, verify sequentially;
if a result is unfinished, report incomplete, not stopped. These children are not
persistent implementation lanes and must not substitute for manually started sessions.

## Publish, pause, and resume

Read [writing-rules.md](references/writing-rules.md) before outward drafts. Show the
exact action, destination, title/body/text; publish only after approval of that draft.
Changed text or destination needs fresh approval. A skill invocation is not approval.
Never push to default/protected branches; never merge (the user merges); no force
push without explicit approval. Keep secrets and private coordination names out of public text.

Persist waiting-on items and decisions. Before a lane pauses/closes, request
[handoff-template.md](references/handoff-template.md). This is a local document,
not a call to Pi's `handoff` tool, which requires an explicit user request.
No scheduling is assumed: do not promise reminders or automatic cross-session monitoring.
On return, recover local records and reverify external state before continuing.
