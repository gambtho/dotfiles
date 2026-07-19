---
name: blindspot-pass
description: Inspect the relevant repository and surface hidden constraints and unknown unknowns before implementation — current understanding, confirmed constraints, likely blind spots, and the decisions that could materially change the approach. Use when the user explicitly asks for a blind-spot pass, a pre-implementation risk review, or "what am I missing" before building. Does not implement unless explicitly asked.
---

# Blind-spot pass

Deliberate, read-only analysis run **before** implementation to expose hidden
constraints and unknown unknowns. Do not implement the feature unless the user
explicitly asks you to after seeing the findings.

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
- **Recommended next step** — e.g. ask a specific high-impact question, run the
  `implementation-plan` skill, prototype a spike, or proceed.

Keep it evidence-based and concise. Separate confirmed facts from inferences.
