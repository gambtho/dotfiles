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

For substantial or unfamiliar work, examine: assumptions in the request,
assumptions you are making, constraints that could invalidate the obvious
solution, reference code that should be followed, architecture/ownership
boundaries, data lifecycle and migration, backward compatibility, security and
privacy, concurrency and failure behavior, deployment/operational effects,
observability needs, test limitations, UX edge cases, and accidental scope
expansion.

Separate findings into **confirmed facts**, **reasonable inferences**, and
**unresolved decisions**. For deliberate, on-demand analysis, use the
`blindspot-pass` skill.

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

Before substantial implementation, produce a concise, evidence-based plan
(use the `implementation-plan` skill for the full form). Lead with the decisions
most likely to need review, and keep routine mechanical edits last:

1. Observable behavior and UX.
2. Architecture and boundaries.
3. Data models and interfaces.
4. Compatibility and migration.
5. Security and failure handling.
6. Deployment and operations.
7. Testing and verification.

A plan covers: intended outcome, repository evidence and constraints, important
decisions and alternatives, ordered steps, verification strategy, assumptions
that may change, and explicit exclusions. Do not follow a plan mechanically once
repository evidence disproves its assumptions.

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
- Never claim a command passed unless you actually ran it. Never hide
  uncertainty behind confident wording.

## Verification before claiming completion

1. Inspect the final diff.
2. Compare the result against the original request.
3. Compare it against repository constraints.
4. Run relevant focused tests; run broader tests when justified.
5. Run applicable formatting, linting, type checking, static analysis, and build.
6. Check for accidental scope expansion.
7. Check for placeholders, dead code, debug output, and incomplete paths.
8. Review implementation notes and unresolved assumptions.

When a check cannot be run, state which one, why, and what uncertainty remains.

## Completion explanation

For non-trivial changes, explain: what changed, how the main path works,
important design decisions, discoveries and deviations from the plan, edge cases
and failure behavior, the exact verification performed, unresolved risks or
follow-up, and where reviewers should focus. The `change-explainer` skill
produces this form on demand.
