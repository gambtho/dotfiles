# Global working agreement

These are default working principles. Repository-specific instructions always
take precedence.

## Scope discipline

- Prefer the minimum complete change that solves the requested problem.
- Do not rename, restructure, or broaden scope without explicit approval.
- Trust internal framework guarantees; validate at user and external-system boundaries.
- Preserve existing behavior unless changing it is required.

## Verify before acting

- Inspect relevant source, tests, docs, configuration, and nearby patterns before substantial changes.
- Before amending a commit or assuming merge state, run `gh pr view` and `git log`. Never amend an already-merged PR.
- Before reviewing an unnamed commit or branch, state its exact SHA and subject and wait for confirmation.
- Verify callers before describing code as unused, deprecated, or dead.
- Never claim success without running relevant tests, type checks, lint, or an equivalent exercise and citing the result.

## Stop instead of guessing

- Do not invent file contents, UI paths, API fields, or library behavior.
- For third-party platforms, inspect current docs, API output, or supplied screenshots before giving procedural guidance.
- Ask only when the answer could materially change architecture, public interfaces, persisted data, security, compatibility, deployment, or irreversible behavior.
- For local, reversible decisions supported by repository evidence, proceed with the conservative option.

## Run investigations directly

- Use available shell and API tools instead of asking the user to gather output, except for interactive authentication, private secrets, or destructive operations requiring confirmation.
- When investigating an API, call the endpoint before tracing implementation code.
- For reviews or audits spanning more than five files, scope with search first, then delegate deep reading to one structured subagent pass.

## Subagent model routing

When subagents materially help and the user has not requested a specific model, choose the named mode by task shape:

- `rush`: bounded searches, inventories, and mechanical checks.
- `smart`: normal code review, focused investigation, and implementation subtasks.
- `deep`: architecture, security, difficult diagnosis, or broad cross-cutting analysis.
- `review`: an independent second opinion from a different model family.

Omit `mode` and `model` when the subagent should intentionally inherit the current session. Use an explicit `model` only when the user requests one or a workflow requires a different model family. A single `subagent` call applies one mode/model to every task in its batch; use separate calls when tasks need different models.

## Worktree workflow

- Inspect and clarify in the current checkout, then create or reuse a linked worktree before the first repository write.
- Specs, plans, tests, source, configuration, and documentation all count as writes.
- The global worktree-guard extension blocks Pi's direct file-write tools in primary checkouts. Do not bypass it with shell redirection or generated-file commands.
- For non-trivial work, load `blindspot-pass` before implementation, run `polish-core --fix` after implementation, inspect its edits, rerun verification, and use `change-explainer` for the completion write-up.

## Implementation

- Follow established repository patterns and avoid speculative abstractions.
- Add or update tests for meaningful behavior changes.
- Preserve useful error context and avoid unnecessary dependencies.
- Comment intent and tradeoffs rather than restating code.
- Never use `--no-verify` unless the user explicitly requests it. If a hook fails for unrelated reasons, stop and ask rather than fixing unrelated code.

## Completion

Before finishing:

1. Inspect the final diff and compare it with the request and repository constraints.
2. Run focused verification and broader checks when justified.
3. Check for accidental scope expansion, placeholders, dead code, debug output, and incomplete paths.
4. Explain what changed, important decisions, exact verification, and remaining risks.
