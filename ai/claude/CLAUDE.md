# Global working agreement

These are default working principles. Repository-specific instructions (a
project's own CLAUDE.md / AGENTS.md, README, or maintainer guidance) always take
precedence over anything here.

## Core principle: the map is not the territory

Treat the prompt as a map and the codebase as the territory. A detailed request
does not remove the need to inspect the repository and adapt.

For non-trivial work, actively distinguish:

- **Known knowns** — requirements the user stated explicitly.
- **Known unknowns** — decisions already recognized as open.
- **Unknown knowns** — preferences or constraints the user will recognize only
  once they see concrete options.
- **Unknown unknowns** — important issues neither side considered yet.

Your job is largely to surface the last two before they become rework.

## Scale the workflow to the task

**Small, local, low-risk changes:** inspect the relevant code, make the change,
run focused verification. No ceremony.

**Architectural, ambiguous, unfamiliar, cross-cutting, user-facing,
security-sensitive, or compatibility-sensitive work:** inspect broadly, do a
blind-spot pass, clarify high-impact ambiguities, propose a plan before
implementing, track discoveries and deviations, and verify comprehensively.

Match the effort to the risk. Do not impose heavy process on trivial tasks, and
do not skip it on consequential ones.

## Automatic feature workflow

For repository-changing work, inspect and clarify in the current checkout, then
enter a linked worktree before the first feature-related write. Use
`superpowers:using-git-worktrees` when available, and reuse an existing linked
worktree rather than nesting another. Specs, plans, tests, source, configuration,
and documentation all count as writes.

- During discovery, before the design is locked in, run `my:blindspot-pass` for
  non-trivial work. Summarize material findings and continue automatically for
  routine work. Pause only when unresolved high-impact decisions involving
  architecture, public interfaces, persisted data, migrations, security,
  compatibility, deployment, or similarly consequential behavior could
  materially change the implementation.
- Continue with the normal Superpowers brainstorming, planning, TDD, review, and
  verification workflow. The personal skills complement rather than replace
  those phases.
- After implementation, run `my:polish-core --fix`, inspect the resulting edits,
  and re-run the affected verification before making completion claims.
- Then run `my:change-explainer` for non-trivial completed work. Include its five
  knowledge-check questions only for substantial changes; omit them for routine
  non-trivial changes.

Trivial edits may skip blindspot-pass and change-explainer, but they do not skip
the linked-worktree-before-writing rule.

This rule is enforced, not advisory: a PreToolUse hook
(`ai/claude/hooks/worktree-guard.sh`) denies Edit/Write/NotebookEdit whose
target resolves into a primary checkout. A denial there means "move to a
worktree", not "find another way to write the file". Repos listed in
`~/.claude/worktree-guard-allow` are exempt, and `CLAUDE_WORKTREE_GUARD=off`
disables the guard entirely — both are my call to make, not yours to assume.

## Repository inspection

Before substantial implementation, inspect what is relevant: source, tests,
docs, configuration, public interfaces, data models, dependencies, analogous
implementations, and operational/deployment behavior.

Prefer repository-specific evidence over generic industry convention. When
sources conflict, prioritize in this order and call out the conflict rather than
silently choosing:

1. Tests expressing intended behavior.
2. Documented public interfaces and compatibility guarantees.
3. Established production behavior and nearby patterns.
4. Current project documentation.
5. Generic best practices.

## Blind-spot analysis

For substantial or unfamiliar work, run `my:blindspot-pass` — it carries the
checklist and the report format. However the analysis happens, keep **confirmed
facts**, **reasonable inferences**, and **unresolved decisions** separate;
collapsing them is the failure this phase exists to prevent.

## When to ask vs. proceed

Ask only when the answer could materially change: architecture, component
boundaries, data models, public APIs, persisted data, migration behavior,
security/privacy, backward compatibility, user-visible behavior, deployment,
major dependencies, irreversible actions, or fundamental scope.

Proceed autonomously — choosing the most conservative compatible option — when a
decision is local, reversible, low-risk, strongly implied by repository
conventions, or safely discoverable through more inspection. Record significant
autonomous choices. Never silently broaden scope.

When you do ask, lead with the questions whose answers change the implementation
the most.

## References and prototypes

Prefer concrete references over abstract description: find analogous repo code,
read tests for exact semantics, follow provided reference implementations,
inspect vendored/local libraries. Create a small spike before committing to
uncertain architecture, and prototype subjective UI with fake data before wiring
real state or backends. Do not build production infrastructure just to
demonstrate an uncertain idea. These are optional tools for exposing
uncertainty, not required steps.

## Planning

Before substantial implementation, produce a concise, evidence-based plan;
`my:implementation-plan` carries the full form and the review-risk ordering.
Do not follow a plan mechanically once repository evidence disproves its
assumptions.

Run the project's formatter over every code block a plan embeds, and paste back
the formatted result. Implementers transcribe plan blocks verbatim, so an
unformatted block becomes an unformatted commit in every task that copies it —
and the formatter check usually sits at the final gate, long after the last
transcription.

## Implementation notes

For substantial work, keep a temporary `implementation-notes.md` (unless repo
instructions specify elsewhere). Record only durable context: confirmed facts,
meaningful assumptions, important decisions, edge cases, deviations from the
plan, alternatives considered, verification performed, and unresolved risks. It
is not a stream-of-consciousness log.

At completion, remove it if it has no lasting value, or fold durable information
into the repository's normal design doc / ADR / PR format.

## Implementation standards

- Prefer the smallest complete solution; reuse established repo patterns.
- Avoid speculative abstractions and unrelated refactoring.
- Preserve existing behavior unless a change is required; don't silently fix
  unrelated issues.
- Add or update tests for meaningful behavior changes.
- Preserve useful error context; follow existing observability conventions.
- Avoid unnecessary dependencies.
- Comment intent and tradeoffs, not a restatement of the code.
- Never hide uncertainty behind confident wording.

## Verification before claiming completion

`superpowers:verification-before-completion` governs the core rule: never claim
a command passed unless you actually ran it, and no completion claim without
fresh evidence. Beyond running the tests, linting, type checking, static
analysis, and build that apply:

1. Inspect the final diff, and compare it against both the original request and
   the repository's own constraints.
2. Check for accidental scope expansion.
3. Check for placeholders, dead code, debug output, and incomplete paths.
4. Review implementation notes and unresolved assumptions.

When a check cannot be run, state which one, why, and what uncertainty remains.

## Completion explanation

For non-trivial changes, run `my:change-explainer` — it produces the
reviewer-facing write-up: what changed, how the main path works, important
decisions, deviations, edge cases, the verification actually performed, and
where reviewers should focus.

## Standing authorization: subagents, workflows, research tools

I authorize subagent dispatch, multi-agent workflows, and research tooling as a
**standing request**, for every session and every project. This file is that
request. When a skill's own procedure calls for dispatching subagents — for
example the parallel review phase of `my:polish-core`, or
`superpowers:dispatching-parallel-agents` — dispatch them. Do not skip the
phase, do not degrade to a local check, and do not ask again or narrate the
permission question back to me.

This is authorization, not instruction: normal judgment about cost and scope
still applies, and a one-file lookup does not need a subagent. It means the
question of whether you *may* is already answered.
