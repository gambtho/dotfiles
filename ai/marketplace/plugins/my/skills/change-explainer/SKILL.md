---
name: change-explainer
description: Inspect the final diff, relevant code, tests, and implementation-notes.md, then produce a reviewer-facing explanation of a completed change — what changed, how it works, key decisions, deviations, edge cases, verification actually performed, and reviewer focus. Use proactively after polish and fresh verification for non-trivial work, before branch completion or a PR. Also use for explicit explanation, write-up, or review-summary requests. Include knowledge-check questions only for substantial changes.
---

# Change explainer

Deliberate, post-implementation write-up for a completed change. Base every
claim on evidence you can see; never assert a check ran unless it actually did.

## Steps

1. **Inspect the final diff** (e.g. `git diff` against the base) to see exactly
   what changed.
2. **Read the surrounding code and tests** the change touches, to explain how it
   fits and behaves.
3. **Read `implementation-notes.md`** if present, for decisions, deviations, and
   unresolved risks recorded during the work.
4. **Classify the change scope.** Treat work as substantial when it is
   architectural, cross-cutting, security-sensitive, migration-related, changes
   public interfaces or persisted data, affects deployment, or otherwise needs
   deeper reviewer understanding. Other meaningful completed work is routine
   non-trivial work.

## Output

- **What changed** — the concrete set of changes, grouped logically.
- **How it works** — the main execution path through the new/changed code.
- **Important decisions** — design choices and why they were made.
- **Deviations and discoveries** — where the result differs from the original
  plan or request, and what was learned mid-implementation.
- **Edge cases and failure behavior** — how the change behaves at the boundaries
  and when things go wrong.
- **Verification actually performed** — the exact commands/tests run and their
  results. For anything not run, state which check, why, and the remaining
  uncertainty.
- **Reviewer focus** — the areas most worth scrutiny.
- **Knowledge check** — For substantial changes, include exactly five questions
  about the change, without answers. For routine non-trivial changes, omit the
  knowledge check.

Keep it accurate and specific. Do not hide uncertainty behind confident wording.
