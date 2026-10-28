---
name: adversarial-review
description: Use when asked for an adversarial code review of a PR or diff, to try to break a change's claims, or to investigate counterexamples involving failures, retries, concurrency, upgrades or misuse, including whether the change carries code or names it does not need.
---

# Adversarial Review — Independent Pi Attackers

Try to break the change: falsify its behavioral claims and challenge whether it needs all its code. Zero findings is valid.
Standalone and explicitly requested only; return a report and stop.

**Input:** `[PR URL | OWNER/REPO#N | diff-path] [--focus text] [--model provider/model]`.
Example: `/adversarial-review https://github.com/example/service/pull/42 --focus "retry after lost response"`.
Use the `adversarial-review` prompt wrapper or `/skill:adversarial-review` directly.

## Scope and neighboring workflows

Use `second-opinion-core` for specs/plans and `blindspot-pass` for discovery before implementation.
Use `pr-closeout` for finalization, fixes, CI, threads and readiness, not this skill.
Read its shared project-review contract's Review evidence section for profile provenance and identities.
This requested two-reviewer attack is one review phase, not an automatic extra gate.
Reuse matching prior coverage; retain repository-required reviews. Never edit profiles.

## Resolve and pin

1. Resolve an explicit target, or the PR/diff clearly identified in the conversation. Ask if ambiguous; never select an unnamed commit to review without confirmation.
2. For a PR, query metadata first: verified base repository, base/head SHAs and changed files; obtain source in an isolated detached checkout. Never alter another session's checkout.
3. For a diff, identify its repository, comparison base, applied content and working-content identity. Read actual callers/consumers, not just hunks. When context is unavailable, state the limited scope; do not invent source or infer complete coverage.
4. Read applicable repository instructions and cumulative profiles per the shared contract. Separate approved requirements from author claims; respect documented trusted boundaries. State the time budget/focus before dispatch; use the user's cap when given.

## Select two isolated reviewers

Record current provider/model and known author model. Reviewer A must use a different model family from the current model; prefer a family different from the author too.
Default routing: current GPT/Gemini/Grok → `review`; current Claude → `deep`. These are configured roles, not proof of their models.
An explicit `--model` selects A; pass that override only when supplied. If it is same-family or cannot resolve, report the conflict rather than silently relaxing independence.
Reviewer B uses `deep` for a named failure/concurrency/state risk, otherwise `inspector` for a named consumer/representation risk.
Verify **actual resolved models**, and A's different family, in tool receipts before accepting coverage; replace a mismatched selection if available. If tools/models/context are unavailable, return INCOMPLETE with any limited evidence; do not simulate independent reviewers in one conversation.

Issue sibling `subagent` calls with `run_in_background: true`, `inherit_context: false`, self-contained prompts and 3–5 word descriptions. Record IDs; collect with `get_subagent_result` without tight polling.
A covers whole-change behavioral claims and seams. B independently attacks the highest-risk boundary you name before dispatch; it is not another full maintainability pass.
Give both the pinned repository/content, instructions, approved scope, focus, budget and mandate below. Do not send author verdicts, prior findings or sibling conclusions during their initial search.

## Reviewer mandate

- Read code/callers/formats and write initial invariants/hypotheses before author reports or prior reviews. Then compare PR/documentation claims and approved decisions; try to make each important promise false.
- Trace input → authority/state transition → observable effect, including unchanged consumers and alternate entries. Attack cancellation/commit windows, retry/restart/uncertain outcomes, competing actors with barriers, supported upgrades/old writers and valid workflows repeated/reordered/misused by a user or agent.
- For a foundation, exercise its current API and a concrete planned consumer sequence. Missing later integration is not a defect; storage consuming verified identities need not authenticate them.
- Use minimal local reproductions, focused failing tests, fault injection, properties/models or differential comparisons where useful. Compare only promised-equivalent behavior. Assert exact state and forbidden-effect counts, not merely an error; verify test selectors selected real tests.
- Work report-only. Keep the reviewed checkout unchanged; probes/mutations belong in separate disposable scratch/overlays. Do not fix source, commit, push, post, install dependencies, change profiles, or perform live/provider actions without separate authority. Tests must stay within the lane's permissions.
- Every finding needs a violated claim/source, reachable preconditions, exact sequence, expected/observed effect, head-relative file:line and impact/severity separate from confidence. Provide a reproduction/test command and result, **or** a complete file:line control/data-flow argument labeled static-only.
- Try to disprove candidates against guards, actual callers, approved exclusions and base behavior. Separate pre-existing issues, duplicates, test gaps and unsupported inputs. A surviving mutant alone is not a product bug. Unproved suspicions are open questions, not confirmed blockers.
- Return ranked candidates, a ledger of attempted/disproved attacks with evidence and limits, exact checks, NOT RUN items and resolved model. Never invent attempts or require a bug quota. Report unneeded code, excess size and misleading names as findings too: what the change doesn't need, what it costs (more paths to break, more to review) and the smaller version. Rank them by impact beside behavioral findings.

## Validate and report

The lead verifies/reproduces candidates against pinned content, challenges false positives and deduplicates; model agreement is not proof. Retain reviewer disagreements and explain dispositions. Do not silently rewrite an independent finding as if the reviewer agreed.
Recheck PR head and relevant content/profile identities at handoff. If they changed, report the reviewed revision and stale/affected scope; do not claim readiness for new bytes.
Return this report; no automatic fix loop or publication:

```text
VERDICT: COUNTEREXAMPLE FOUND | NO CONFIRMED COUNTEREXAMPLE | INCOMPLETE
SUMMARY: <=5 lines: target/base/head/content, actual reviewer models, impact/recommendation, limits
FINDINGS: ranked; violated claim, preconditions, file:line, evidence/result, severity/confidence
ATTACKS: attempted | disproved | not run; method, evidence, scope limits (no invented entries)
DISPOSITIONS: accepted/rejected/duplicate/open; reason and reviewer disagreement
VERIFICATION: exact commands/results, identity/profile provenance, skipped scope
NEXT: one batched owner instruction, or none
```

INCOMPLETE takes precedence when required independence or material coverage is missing; still list any confirmed findings.
NO CONFIRMED COUNTEREXAMPLE means none in the exercised scope, not safe-to-merge or end-to-end qualification.
