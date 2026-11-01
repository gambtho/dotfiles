# Optional bounded state-model check

## When it fits and who decides

Most lanes don't need this. Consider it when a design's risk is in state transitions:
retries, concurrency, ownership, crash recovery or multi-step external operations.
Check the risky mechanism, not the whole application. If nothing fits, say so;
don't force a candidate.

The coordinator recommends one candidate and a bounded scope. The human approves
before any lane starts or changes, through the existing lane-start/change approval,
not a new approval step. Ownership stays with the owning lane, which does the check
inside its existing design stage. Set total lane time and per-run time/resource and
state-space bounds up front; if they run out, report what remains unverified.

This also fits an approved design with code already written, provided the check runs
before the first push. Say explicitly that this checks the design and code rather
than shaping them; don't reopen approval unless findings change the design or slice.

## What the owning lane does

1. State the properties in plain English first: what **must never happen** (safety)
   and what **must eventually happen** (progress).
2. Write a small TLA+ model of the mechanism, including relevant failures and awkward
   orderings. Split external calls into **invoke, effect and return**: an effect can
   land while its result is lost. State which steps are atomic and why they match
   the design and, where present, the code; don't invent atomicity across systems.
3. Run TLC. Keep the exact executable spec and configuration for each run, with
   assumptions, atomic steps, bounds, command, tool versions, state counts, result
   and any counterexample that changed the design. Record generated, distinct and
   queued states and whether checking completed, so a stopped prefix isn't mistaken
   for complete coverage.
4. Put fairness assumptions in the open: which actions must keep getting a chance
   to run, and what successful completion or fault exclusions progress depends on.
   Run a separate configuration with failures on. Record expected stuck states as
   counterexamples, not passes; a stuck state beyond the design's accepted limits
   is a finding. Complete safety checks separately if a progress counterexample
   stopped the run before they finished.
5. Have a reviewer from a different model family challenge assumptions, atomic
   steps and properties, not just syntax. Record the actual model family and which
   challenges were accepted or rejected, with reasons.
6. Include findings in the existing design approval. If a counterexample changes
   the design or slice, stop for the human; otherwise carry on under the existing
   approval.
7. Map each property and transition to the code that obliges it and a regression
   test. Each test must fail without the code it protects; demonstrate that failure
   and the restored pass. Tests go in the PR. Mark unmapped or untested obligations
   as unverified, not covered by a green model run.

## Evidence and limits

- An unrun spec isn't verification, and an incomplete run isn't a pass. A discovered
  counterexample is evidence of that trace, not verification of the unexplored states.
- Don't weaken a property to get a green result. If a property changes, retain the
  original result and record what changed and why; distinguish the two claims.
- Reproduce a counterexample in the real code before calling it a bug. Until then,
  it is a model finding, not a confirmed code defect.
- Report tooling blockers and carry on with the lane's existing workflow, with the
  check visibly unverified. Don't build a verification subsystem or add models to CI.
- Tool downloads need the human's approval. Record the checksum of the file received;
  don't present a received-file checksum as upstream authentication.
- Artifacts stay local unless the human approves versioning those artifacts. Keep
  them outside the versioned tree or in verified Git-ignored scratch. PRs don't
  mention the model unless the human asks; only code changes and regression tests
  belong there by default.

## Closeout

Report what it caught, what remains unverified, the time it took and whether it was
worth it. Count modelling, review, revision and code reproduction as well as TLC
runtime: a fast check can still cost substantial lane time.

A checked model is evidence about the model, not proof the code is correct.
