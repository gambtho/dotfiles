# <project or effort>: shared lane rules

<Coordinator: project the Shared workflow section once into the project's
`lanes/COMMON-RULES.md`, with the heading "Shared lane workflow". It carries every rule
that holds for any lane. Keep project authority, repo-specific policies and stronger local
rules in AGENTS.md/COORDINATION.md. Every lane prompt and the project's AGENTS.md name the
shared file. For a parallel effort's separate rules file, include only Ownership, Open PRs
to stay off, the Rules for every lane pointer and Sequencing; don't copy the workflow.
Resolve the messaging.md link to a verified readable reference on each recipient host when projecting outside this skill.
Resolve paths and remove these instructions and unused placeholder sections before delivery.>

Every lane reads the project-level shared workflow, the project's AGENTS.md and its
own prompt. Parallel lanes also read their effort rules.

## Shared workflow

Read this file with your lane prompt and the project's AGENTS.md; record the prompt's starting SHA256 in your private
report/handoff (portable: Python `hashlib` or `shasum -a 256`). To catch observable amendments without a human relay,
recheck before each irreversible or outward step, including push, PR opening, review replies/resolutions or other posts,
setup/config mutation and final ready report; if changed, reread and reconcile the prompt before
acting, then record the new hash. At each checkpoint, including before ready, also read new or changed coordinator notes
addressed to you; the [local messaging contract](messaging.md) owns note pickup, acknowledgement, human-decision notes
and the optional ready nudge. Your report, never STATE, records pickup, effects and delivery. Only a source-verified
human decision satisfies a human gate. Uncertainty never permits a resend, fallback or human paste relay.
Unreadable prompt, notes or contract mean blocked, not ready. Project and repository instructions
and the human's explicit decisions take precedence. This file changes no publication, merge, cloud or desktop authority.
If instructions conflict, stop and ask the coordinator.

The review skills, including `pr-closeout`, `pr-text`, and `/second-opinion` and `/adversarial-review` wrappers ship with
the package. Outside Pi, read `<resolved harness-notes path>` and each skill's `<resolved skills dir>/<name>/SKILL.md`
(`second-opinion-core` and `adversarial-review` back the wrappers); resolve them to the skill's bundled
`references/harness-notes.md` and the package's `skills/` directory before delivery. Requirements are unchanged.
Claude Code lanes get cross-family review from `bash <resolved scripts dir>/codex-review.sh <prompt> <out-prefix>`,
Codex lanes from `claude-review.sh` there; on failure, stop and report.

### Standing review fallback

Local CodeRabbit is a standing default for every lane and coordinator unless the project
records an explicit project opt-out. Qualify it from observed evidence at the current-head:
a Copilot review request fails or reports exhausted quota, a GitHub CLI `gh` API request is
rate limited, or a review bot reports a rate-limit/skip notice. Record the response or URL;
do not infer it from an absent review. The lane never stalls asking a human to request
Copilot. Follow `pr-closeout`'s one local fallback per PR, billing/auth prechecks and
coverage checks: run `coderabbit review --agent` only with verified safe billing and no
sign-in, install, organization switch or paid-credit opt-in. Never post local output or fix
unverified findings. Record `review round: local CodeRabbit CLI (reason)` in the report and
PR body. If local prechecks or the run cannot complete, use one independent review by a
different model family and say so instead. Preserve mandatory-review blockers and final
thread/review-body reads.

### Design, then plan

- New product work starts with a short design, before any plan: the user value, which repo owns it, which existing
  mechanism it extends (or why none fits), and what new packages, rules or refusals it adds.
- Run `/second-opinion` on the design alone, revise, and stop for the human's approval. Then write the plan and run
  `/second-opinion --with-spec` on the plan with its design. A plan reviewed without its design doesn't count.
- Before reporting a PR ready, follow `pr-closeout`'s one independent review phase; add
  specialists only for a named uncovered risk or explicit request. Repository-required reviews remain.
  Complete its bounded bot opportunity and final thread and review-body read; report coverage and evidence.
- Work the human already approved continues under its approved design; don't re-gate it. Audit-only work stops at
  its assigned approval gate.
- Optional: for risky state transitions, consider the owning lane's bounded, human-approved check in
  `<resolved state-model-check path>` within its existing design stage; resolve that path to the
  skill's bundled `references/state-model-check.md` before delivery.

### Worktrees and pull requests

- Work in your own fresh worktree from a freshly fetched base. Never edit another lane's worktree.
- You own your PR end to end: keep it current under the repository's merge policy, answer its review threads, and keep CI green.
  Lanes detect or record merge-queue status from project or repository policy; do not assume it. With a
  merge queue, remain queue-ready (green PR-head checks, no conflicts, threads answered) and merge
  the base only for a real conflict. Without a merge queue, a later overlapping PR merges the base
  and passes CI on the combined head before merge.
- Small PRs, one theme each. Follow `pr-closeout` for scoped review/finalization, preserving publication approval
  and reusing valid review evidence.
- Load the `pr-text` skill when writing PR bodies, review comments/replies and issues.
- PR publication, replies and other public text follow the authority table in COORDINATION.md. Without permission
  there, draft exact text for the human. Production/provider approvals are unchanged.
- Follow the repo's changelog mechanism; never edit a shared file that every PR touches.
- Prefer sequential PRs over stacks: open the next PR only after the previous one merges, from a freshly fetched
  default branch. Never push branches to someone else's repo to make stacking work.
- Resolve Git policy from project AGENTS.md, the COORDINATION.md repo row and repo rules; ask on conflict.
  A method grants no push authority. Never force-push anyone else's branch.
  Without project or repo Git policy, never push to a default branch or merge a PR, never rewrite someone else's branch,
  and resolve conflicts by merging the base branch into yours.
- No timeout increases as a fix.
- No tag, release note or note to users until a person has walked the path the release claims to support, without
  workarounds.

### Reviews, delivery and reports

- Profiles/aliases come from COORDINATION.md; executable plan/task ownership comes from the lane prompt.
  Return feedback candidates to the coordinator; only that coordinator writes profiles and commits/pushes them with
  plain Git in the private store.
- Approved LOCAL delivery covers authorized setup/verification, safe in-scope corrections and exact restoration of
  tool-generated temporary changes. Save the pre-run bytes/hash; confirm no unrelated edits, restore only generated
  changes and verify the original hash. No arbitrary resource/config changes or test bypasses.
- Return one consolidated shared readiness report or ONE batched real blocker. The user can signal "W<n> ready"; the
  coordinator reads it directly. Manual sessions are not automatically monitored. Escalate new material choices,
  shared/destructive operations and actions outside authority, not routine authorized LOCAL steps.

### Scope and evidence

- Don't invent requirements beyond what the human decided; our own issue text isn't a requirement if the human says
  otherwise. In reports and handoffs, mark claims about another lane, host, person or project **observed** (command or source)
  or **inferred**, so a guess cannot silently become an instruction. Lanes add no prompts, confirmations, refusals or safety
  rules without the human's OK.
- Put code in the repo that will own it in production. Proof harnesses for unbuilt features don't get a home in a
  product repo just because the test infrastructure is there; ask the coordinator.
- Demos and proofs: build the smallest thing that shows the point. No general subsystems, setup layers or extra
  tooling around them, and label them clearly so they're easy to delete.

### Private information and writing

- No secrets in files, logs or command-line arguments.
- No lane numbers, local paths or customer names in anything public: branches, commits, PRs, comments, issues, labels,
  milestones, gists. Keep internal projects and private events out of public text. Follow any stronger project limits.
- Short sentences, plain words.

## Ownership

| Lane | Repo | Owns | Doesn't touch |
|---|---|---|---|
| W<n> | <owner/repo> | <paths/globs> | <paths other lanes own> |

If you need a change in another lane's area, write it in your report instead of making it.
Lanes own their source/test work and CI-fix loops. The coordinator prepares assignments,
starts authorized lanes, verifies reports, maintains state and publishes approved
material; start/publish authority does not authorize source takeover or a shadow worker.

## Open PRs to stay off

- <owner/repo#N (owner): files it touches. Re-check `gh pr list` before each PR.>

## Rules for every lane

Read the project's AGENTS.md, shared workflow and the repo's own rules for Git, PRs,
privacy, tests and reports. This effort file records ownership and exceptions, not
another copy of that workflow. If instructions conflict, stop and ask the coordinator.

## Sequencing

<Landing order and dependencies between lanes.>
