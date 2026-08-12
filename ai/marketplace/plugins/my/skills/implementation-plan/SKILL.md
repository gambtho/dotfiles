---
name: implementation-plan
description: Inspect the repository and produce a concise, evidence-based implementation plan that leads with the highest-review-risk decisions (behavior, architecture, interfaces, compatibility, data, security) and keeps mechanical edits brief. Use when the user explicitly asks for an implementation plan, a design proposal, or a plan before substantial work. Does not implement unless explicitly asked.
---

# Implementation plan

Deliberate, evidence-based planning run **before** substantial implementation.
Inspect the repository first; base the plan on what the code actually shows, not
on generic convention. Do not start implementing unless the user asks.

## Steps

1. **Inspect** the relevant source, tests, docs, config, interfaces, data
   models, dependencies, and analogous implementations. Collect the evidence and
   constraints the plan will rest on.
2. **Draft the plan** using the structure below, leading with the decisions most
   likely to need review and keeping routine edits last.

## Output structure

- **Intended outcome** — the observable end state.
- **Evidence and constraints** — what the repository shows, each tied to a
  file/test/doc. Flag conflicts between sources rather than silently resolving.
- **Decisions for review** — ordered by review risk:
  1. observable behavior and UX,
  2. architecture and boundaries,
  3. data models and interfaces,
  4. compatibility and migration,
  5. security and failure handling,
  6. deployment and operations,
  7. testing and verification.
- **Alternatives and tradeoffs** — for each significant decision, the option
  chosen and what was rejected and why.
- **Ordered implementation steps** — the sequence of changes; keep mechanical
  edits concise and grouped.
- **Testing and verification strategy** — what will be run to prove correctness.
- **Adaptation points** — assumptions that may change during implementation and
  what would trigger revisiting the plan.
- **Explicit exclusions** — what is deliberately out of scope.

Keep it concise. Do not pad mechanical work; spend the detail on the decisions a
reviewer would challenge.
