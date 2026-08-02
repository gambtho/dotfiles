# Personal slabledger workflow

## How I want features built

When the user asks for a non-trivial change ("build X", "add feature Y", anything
spanning >2 files or both backend and frontend), use the **agent-team flow**, not
single-agent execution in the main thread.

### The flow

1. **Brainstorm first.** Invoke `superpowers:brainstorming` to clarify intent,
   requirements, and design before any code or planning. Skip only for trivial
   single-file fixes.

2. **Write a plan.** Invoke `superpowers:writing-plans` to produce a step-by-step
   implementation plan with critical files identified. The plan goes into a file
   so the team can read it.

3. **Spawn a team.** Call `TeamCreate({ team_name: "<feature-slug>", description: "<short>" })`.
   The team gets a shared TaskList at `~/.claude/tasks/<feature-slug>/`.

4. **Seed the TaskList.** Break the plan into independent tasks via `TaskCreate`.
   Mark dependencies with `addBlockedBy`. Each task should be small enough for
   one teammate's turn (one file, one concern).

5. **Spawn teammates from the standing catalog.** Use the `.claude/agents/` files
   as `subagent_type` values:

   | When you need… | Spawn |
   |---|---|
   | Go backend implementation | `Agent({ team_name, name: "backend", subagent_type: "go-dev" })` |
   | React/TS implementation | `Agent({ team_name, name: "frontend", subagent_type: "frontend-dev" })` |
   | Data/analytics question | `Agent({ team_name, name: "analyst", subagent_type: "profit-analyst" })` |
   | Pre-commit diff review | `Agent({ team_name, name: "reviewer", subagent_type: "code-reviewer" })` |
   | UI polish pass | `Agent({ team_name, name: "polisher", subagent_type: "ux-polisher" })` |

   Spawn **independent** teammates in parallel (single message, multiple Agent
   tool calls). Sequential only when there's a real data dependency.

6. **Coordinate via TaskList and SendMessage.** I'm the team lead. I assign tasks
   by setting `owner` via `TaskUpdate`. Teammates send progress via `SendMessage`.
   I don't reach into their work — I read the task list and their messages.

7. **Review before claiming done.** After implementation tasks complete, dispatch
   `code-reviewer` against the diff. Then run `superpowers:verification-before-completion`
   — evidence (tests, build, screenshots) before any "it's done" claim.

8. **Tear down when shipped.** `TeamDelete` after the PR is merged or the feature
   is abandoned. Don't leave dead teams accumulating.

### When NOT to use the team flow

- Single-file typo or one-line bug fix — just do it
- Pure research / "where is X defined" — use `Explore` agent or grep directly
- Quick question about data — `profit-analyst` standalone is fine, no team

### Shortcut

`/new-feature <feature-slug>` runs steps 1–5 in one shot. Use it when you'd
otherwise type the ritual by hand.

## The standing agent catalog

These live in `.claude/agents/`. They serve two purposes: standalone subagents
(call `Agent` with `subagent_type`) and as templates when spawning team members
(same `subagent_type`, plus `team_name` and `name`).

- `go-dev` — backend implementation, hexagonal-arch aware
- `frontend-dev` — React/TS, knows the design system
- `profit-analyst` — read-only data access (Supabase + production API)
- `code-reviewer` — read-only diff review against slabledger conventions
- `ux-polisher` — drives `ui-screenshot-improve` and `impeccable`

## Personal preferences

- Cite output before declaring work done. No vibes.
- When in doubt, stop and ask. Manufactured certainty wastes more time than a question.
