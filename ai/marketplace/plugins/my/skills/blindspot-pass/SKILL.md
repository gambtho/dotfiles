---
name: blindspot-pass
description: Inspect the relevant repository and surface hidden constraints and unknown unknowns before implementation — current understanding, confirmed constraints, likely blind spots, and decisions that could materially change the approach. Use proactively during discovery for non-trivial work, after initial requirements are understood and before the design is locked in. Also use for explicit blind-spot, pre-implementation risk, or "what am I missing" requests.
---

# Blind-spot pass

Read-only analysis run **during discovery**, before the design is locked in, to
expose hidden constraints and unknown unknowns. The skill itself does not edit
files or implement the feature.

## Workflow modes

- **Automatic workflow mode:** when the user has already requested the feature
  or change, treat this analysis as a phase of that request. Summarize material
  findings and continue into design for routine work. Pause only when an
  unresolved high-impact decision involving architecture, public interfaces,
  persisted data, migration, security, compatibility, deployment, or similarly
  consequential behavior could materially change the implementation.
- **Standalone mode:** when the user asks only for analysis, return the report
  and stop without moving into design or implementation.

## Steps

1. **Restate the request** in your own words, including what you believe the
   intended outcome is.
2. **Inspect the relevant repository surface** — source, tests, docs, config,
   public interfaces, data models, dependencies, analogous implementations, and
   operational/deployment behavior. Gather evidence; do not guess.
3. **Run the blind-spot checklist.** For each, note whether it applies:
   assumptions in the request, assumptions you are making, constraints that
   could invalidate the obvious solution, reference code to follow,
   architecture/ownership boundaries, data lifecycle and migration, backward
   compatibility, security and privacy, concurrency and failure behavior,
   deployment/operational effects, observability needs, test limitations, UX
   edge cases, and accidental scope expansion.

## Output

Produce these sections:

- **Current understanding** — the goal and intended outcome as you read it.
- **Confirmed constraints** — facts established from repository evidence, each
  with a pointer to the file/test/doc it came from.
- **Likely blind spots** — reasonable inferences and risks not yet confirmed.
- **Decisions that could materially change the implementation** — for each
  high-impact unresolved decision, give:
  - why it matters,
  - the available evidence,
  - the likely options,
  - the consequence of choosing incorrectly.
- **Recommended next step** — ask a specific high-impact question only when the
  risk-scaled pause rule applies; otherwise recommend proceeding into the normal
  design workflow.

Keep it evidence-based and concise. Separate confirmed facts from inferences.
