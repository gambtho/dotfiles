---
name: second-opinion-core
description: Get an independent review of a spec or implementation plan from a model in a different family, verified against the actual repository. Run proactively after writing or substantially revising a non-trivial spec or implementation plan, before implementation begins. Also use for explicit second-opinion, design-review, or plan-review requests.
---

# Second Opinion — Independent Pi Review

Review a design document or implementation plan against the actual repository using one isolated subagent running a different model.

**Invocation input:** Interpret text supplied with the skill invocation or the user's surrounding request: `[path] [--with-spec | --with-plan] [--model provider/model]`. Use the `/second-opinion` prompt wrapper for normal invocation, or `/skill:second-opinion-core` to load the skill directly.

## Workflow modes

- **Automatic workflow mode:** when a non-trivial spec or implementation plan was just written or substantially revised in this session, run this review before implementation begins. After a spec, review the spec alone. After a plan written from a spec in this session, review them as a pair. Review each document revision automatically at most once; rerun only on user request or after a rewrite prompted by a `RETHINK` verdict.
  - On `SHIP` with no Blocking findings, summarize the review and continue the workflow.
  - On `REVISE`, `RETHINK`, or any Blocking finding, present the review and pause for the user to choose which findings to fold in before implementation.
- **Standalone mode:** when the user asks only for a review, return the report and stop.

## Resolve the target

1. Use an explicit path from the invocation input when provided.
2. Otherwise use the document most recently written, edited, or discussed in this session.
3. Only if the session provides no target, choose the newest document under `docs/superpowers/specs/` or `docs/superpowers/plans/` and clearly label that choice as a guess.
4. Stop with usage guidance if no document can be identified.

Review one document by default. Pair a spec and plan only when two paths, `--with-spec` / `--with-plan`, or automatic plan review supplies both. Verify every selected path exists and is readable. Documents may live outside the repository tree, because workflow artifacts are kept out of version control; the repository root is what the reviewer verifies claims against.

## Select an independent model

Use the model supplied by `--model` when present. Otherwise choose a model from a different family than the current model:

- Current model is GPT/Gemini/Grok: use `subagent_type: review` (centrally mapped to Claude Opus 5.5).
- Current model is Claude: use `subagent_type: deep` (centrally mapped to GPT-6 Astra).

State the target document, repository root, current model, selected `subagent_type`, and reviewer model before dispatching.

## Dispatch

Issue one foreground `subagent` call with a self-contained `prompt`, a 3–5 word `description` such as `Review implementation plan`, the selected `subagent_type`, and an explicit `model` only when `--model` was supplied. Give it the repository root, selected document paths, repository instructions, and this role:

- Act only as a reviewer; do not modify files.
- Read the documents and repository code needed to verify claims.
- For a spec, check requirements, architecture, ownership, data lifecycle, compatibility, security, failure modes, observability, and contradictions with existing code.
- For a plan, check ordering, hidden dependencies, intermediate breakage, concrete verification, claimed existing paths/symbols, missing migration or cleanup steps, and blast radius.
- For a paired review, additionally map uncovered requirements, unsupported scope, and contradictions between spec and plan.
- Do not report proposed-to-be-created files as missing.
- Prefer a few evidence-backed findings over speculation and cite `file:line` for claims about existing code.

Require this output:

```text
VERDICT: SHIP | REVISE | RETHINK

FINDINGS:
- [Blocking|HIGH] document:section — finding
- [Concern|MEDIUM] document:section — finding
- [Nit|LOW] document:section — finding

COVERAGE GAPS:  # paired review only
- requirement or plan step — gap

SUMMARY:
3–5 sentences
```

If the subagent cannot read the repository or document, report the failure and draw no design conclusion.

## Report

Present the independent review without silently rewriting its findings. Then add a short, clearly separated **My take** section explaining agreements, disagreements, and any false positives using the current session context.

Do not edit source code. Offer to fold selected findings into the reviewed spec or plan; apply only findings the user explicitly accepts.
