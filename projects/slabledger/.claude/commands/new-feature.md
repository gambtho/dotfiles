---
description: Start a new slabledger feature using the standing team-agent flow — brainstorm, plan, spawn team with role-typed members, seed TaskList.
argument-hint: "<feature-slug> [short description]"
---

# /new-feature $ARGUMENTS

You are starting a new slabledger feature. Follow this flow **strictly and in
order** — each step is a precondition for the next.

## Step 0 — Superpowers chain

Before responding to the user about the feature, you MUST go through the
`using-superpowers` decision flow. That means:

1. Recognize this is a creative/implementation task → invoke
   `superpowers:brainstorming` to clarify intent, requirements, design.
   Do NOT skip even if the user's request "seems clear" — the brainstorm is
   how you catch the gap between what they said and what they meant.
2. After brainstorm completion, invoke `superpowers:writing-plans` to produce
   a written plan file the team can read.

If the user typed `/new-feature` with no arguments, ask them for the feature
slug and a one-line description before proceeding.

## Step 1 — Spawn the team

Parse `$ARGUMENTS` as `<feature-slug> [description]`. Then:

```
TeamCreate({
  team_name: "<feature-slug>",
  description: "<description or feature-slug>"
})
```

## Step 2 — Seed TaskList from the plan

Walk the plan from Step 0. For each independent unit of work, call `TaskCreate`
with a sharp subject and a description that another agent could execute without
your conversation context. Set dependencies via `addBlockedBy` where they exist.

Each task description should include:
- The exact files to touch (or "explore and propose" if unknown)
- The acceptance criteria (test passes, build passes, UI matches screenshot)
- Pointers to relevant skills (`new-handler`, `new-migration`, `slabledger-design`, etc.)

## Step 3 — Spawn role-typed teammates in parallel

Pick from the catalog in `.claude/agents/`:

| Need | Spawn |
|---|---|
| Go backend | `Agent({ team_name: "<slug>", name: "backend", subagent_type: "go-dev", prompt: "Claim and execute backend tasks from the team TaskList. Read team config at ~/.claude/teams/<slug>/config.json to discover peers." })` |
| React/TS frontend | `Agent({ team_name: "<slug>", name: "frontend", subagent_type: "frontend-dev", prompt: "Claim and execute frontend tasks from the team TaskList." })` |
| Diff review (spawn later, blocked on implementation) | `Agent({ team_name: "<slug>", name: "reviewer", subagent_type: "code-reviewer", prompt: "Review the diff once implementation tasks complete." })` |
| UI polish (post-implementation) | `Agent({ team_name: "<slug>", name: "polisher", subagent_type: "ux-polisher", prompt: "Polish the new UI once frontend tasks complete." })` |

**Spawn independent members in a single message with multiple Agent tool calls**
so they run in parallel. Don't serialize without a real dependency reason.

For features touching both Go and React, spawn `backend` and `frontend`
together. Reviewer/polisher spawn later (or via `addBlockedBy` task gating).

## Step 4 — Hand control to the team

After spawning, your job becomes orchestration, not execution:
- Watch TaskList for completions and newly-unblocked tasks
- Reassign or unblock via `TaskUpdate`
- Relay user input to the relevant teammate via `SendMessage` (refer by name,
  never UUID)
- When all tasks complete, dispatch `code-reviewer` against the diff
- Invoke `superpowers:verification-before-completion` before any "done" claim

## Step 5 — Teardown

When the feature ships (PR merged) or is abandoned:
1. Gracefully shut down each teammate via
   `SendMessage({ to: "<name>", message: { type: "shutdown_request" } })`
2. After all members shut down, call `TeamDelete`.

## Don't

- Don't execute the feature in the main thread. Spawn the team.
- Don't skip brainstorm/plan — that's where scope discipline comes from.
- Don't spawn more members than the work calls for. A single-file backend tweak
  doesn't need a frontend agent.
- Don't claim done without verification (tests, build, screenshots).
