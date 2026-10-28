# <project or effort>: shared lane rules

<Coordinator: project the Shared workflow section once into the project's
`lanes/COMMON-RULES.md`, with the heading "Shared lane workflow". Keep project authority,
repo-specific policies and stronger local rules in AGENTS.md/COORDINATION.md. Every
lane prompt and the project's AGENTS.md name the shared file. For a parallel effort's
separate rules file, include only Ownership, Open PRs to stay off, Rules for every lane
and Sequencing; point to the project-level workflow rather than copying it. Resolve
paths and remove these instructions and unused placeholder sections before delivery.>

Every lane reads the project-level shared workflow, the project's AGENTS.md and its
own prompt. Parallel lanes also read their effort rules.

## Shared workflow

Read this file with your lane prompt and the project's AGENTS.md. Project and repository instructions and the human's
explicit decisions take precedence. This file changes no publication, merge, cloud or desktop authority.
If instructions conflict, stop and ask the coordinator.

### Design, then plan

- New product work starts with a short design, before any plan: the user value, which repo owns it, which existing
  mechanism it extends (or why none fits), and what new packages, rules or refusals it adds.
- Run `/second-opinion` on the design alone, revise, and stop for the human's approval. Then write the plan and run
  `/second-opinion --with-spec` on the plan with its design. A plan reviewed without its design doesn't count.
- Before reporting a PR ready, run `/adversarial-review` on it and put its verdict in the report.
- Work the human already approved continues under its approved design.

### Worktrees and pull requests

- Work in your own fresh worktree from a freshly fetched base. Never edit another lane's worktree.
- You own your PR end to end: keep it current with its base, answer its review threads, and keep CI green.
- Write a short PR body yourself: what it does, what it doesn't, how verified; under ~10 lines. Publication and replies
  follow the project's authority table.
- Follow the repo's changelog mechanism; never edit a shared file that every PR touches.
- Prefer sequential PRs over stacks: open the next PR only after the previous one merges, from a freshly fetched
  default branch. Never push branches to someone else's repo to make stacking work.
- Resolve conflicts the way the repo's own AGENTS or CONTRIBUTING says. Never force-push anyone else's branch.
- No timeout increases as a fix.
- No tag, release note or note to users until a person has walked the path the release claims to support, without
  workarounds.

### Scope and evidence

- Don't invent requirements beyond what the human decided; our own issue text isn't a requirement if the human says
  otherwise. Lanes add no prompts, confirmations, refusals or safety rules without the human's OK.
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
another copy of that workflow. Without project or repo Git rules, never push to a
default branch or merge, never rewrite someone else's branch, and merge the base in
for conflicts. Project authority remains unchanged.
If instructions conflict, stop and ask the coordinator.

- Follow the project shared workflow's design/plan sequence for new product work.
  Audit-only work stops at its assigned approval gate. Don't re-gate approved work.
- Small PRs, one theme each, from a fresh base. Follow `pr-closeout` for scoped
  review/finalization, preserving publication approval and reusing valid review evidence.
- Profiles/aliases come from COORDINATION.md; executable plan/task ownership comes from the lane prompt.
  Return feedback candidates to the coordinator; only that coordinator writes profiles
  and commits/pushes them with plain Git in the private store.
- Approved LOCAL delivery covers authorized setup/verification, safe in-scope
  corrections and exact restoration of tool-generated temporary changes. Save the
  pre-run bytes/hash; confirm no unrelated edits, restore only generated changes and
  verify the original hash. No arbitrary resource/config changes or test bypasses.
- Return one consolidated shared readiness report or ONE batched real blocker. The
  user can signal "W<n> ready"; the coordinator reads it directly. Manual sessions
  are not automatically monitored. Escalate new material choices, shared/destructive
  operations and actions outside authority, not routine authorized LOCAL steps.
- PR publication and other public text follow the authority table in COORDINATION.md.
  Without permission there, draft exact text for the human. Production/provider
  approvals are unchanged.

## Sequencing

<Landing order and dependencies between lanes.>
