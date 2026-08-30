---
description: Get an independent review of a spec or implementation plan from a different Pi model
argument-hint: "[path] [--with-spec | --with-plan] [--model provider/model]"
---

# Second Opinion — Independent Pi Review

Review a design document or implementation plan against the actual repository using one isolated subagent running a different model.

**Arguments:** $ARGUMENTS

## Resolve the target

1. Use an explicit path from the arguments when provided.
2. Otherwise use the document most recently written, edited, or discussed in this session.
3. Only if the session provides no target, choose the newest document under `docs/superpowers/specs/` or `docs/superpowers/plans/` and clearly label that choice as a guess.
4. Stop with usage guidance if no document can be identified.

Review one document by default. Pair a spec and plan only when two paths or `--with-spec` / `--with-plan` are supplied. Verify every selected path exists and belongs to the current repository root.

## Select an independent model

Use the model supplied by `--model` when present. Otherwise choose a GitHub Copilot model from a different family than the current model:

- Current model is Claude/Gemini/Grok: use `github-copilot/gpt-5.4`.
- Current model is GPT: use `github-copilot/claude-opus-4.7`.

State the target document, repository root, current model, and reviewer model before dispatching.

## Dispatch

Use the `subagent` tool once with mode `deep`. Give it the repository root, selected document paths, repository instructions, and this role:

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
