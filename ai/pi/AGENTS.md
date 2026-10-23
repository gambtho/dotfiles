# Global working agreement

These are default working principles. Repository-specific instructions take
precedence over defaults, but cannot waive the explicit user-consent requirement
for committing Superpowers artifacts below.

## Pi runtime boundaries

- Stop Pi before changing linked resources. Routine reconciliation runs native extension updates; packages may advance and cached files may be replaced. Host self-update remains operator-owned. Canonical rollout is not implied by isolated verification.
- Superpowers planning is a process, not a read-only UI/security mode. Retired planner state is not migrated; start a fresh session after rollout without rewriting old sessions.
- Codemode nested tool calls remain permission/worktree-guarded, but classifier/image models and extension-internal execution use separate ambient authority. These tripwires are not OS containment.
- Existing mutable preferences are preserved unless a documented selective refresh/reset is requested. Normal `make ai` removes the ignored top-level `graceTurns` key without setting `wrapUpTurns` or changing turn budgets. Old `graceTurns` is not migrated to `wrapUpTurns`: warnings before a hard limit are different from grace after a soft limit.

## Scope discipline

- Prefer the minimum complete change that solves the requested problem.
- Do not rename, restructure, or broaden scope without explicit approval.
- Trust internal framework guarantees; validate at user and external-system boundaries.
- Preserve existing behavior unless changing it is required.

## Superpowers artifacts stay local

- Never stage, commit, push, or include Superpowers artifacts in a PR unless the user explicitly requests versioning those specific artifacts.
- This includes generated specs, designs, plans, task ledgers, review reports, implementation notes, and other workflow scratch files, regardless of filename or location (including `docs/superpowers/` and `.superpowers/`).
- Skill, template, or repository workflow instructions to write or commit an artifact are not user permission. Requests to plan, implement, commit code, or create a PR do not implicitly authorize committing these artifacts.
- Keep artifacts outside the versioned project tree or in verified Git-ignored local scratch space. Prefer local Git excludes over changing a tracked `.gitignore` solely for agent artifacts.
- Check staged files before each commit and the complete PR diff before publishing. Exclude these artifacts and do not reference local workflow documents in PR descriptions unless explicitly requested.
- This policy overrides conflicting Superpowers workflows; it does not prohibit requested product documentation or CLI help changes.

## Verify before acting

- Inspect relevant source, tests, docs, configuration, and nearby patterns before substantial changes.
- Runtime metadata inspection is optional when useful, not a session-start requirement. Use `printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL` or `printenv XDG_CONFIG_HOME PI_CODING_AGENT_DIR` (or their `/usr/bin/printenv` spellings); do not dump the environment or append secret-variable operands.
- Before amending a commit or assuming merge state, run `gh pr view` and `git log`. Never amend an already-merged PR.
- Before reviewing an unnamed commit or branch, state its exact SHA and subject and wait for confirmation.
- Verify callers before describing code as unused, deprecated, or dead.
- Never claim success without running relevant tests, type checks, lint, or an equivalent exercise and citing the result.
- These are not verification: "the change is too small to break anything", "it passed earlier", "the test is flaky, so the failure doesn't count", and "the types check, so it works". Run the check and cite the output, or state plainly that it was not run.

## GitHub ref inspection

Read-oriented `rush`, `inspector`, `deep`, and `review` agents keep `git ls-remote` denied,
even for literal HEAD queries approved in the parent. Use existing `gh api`
read permissions instead. Inspect the repository's default branch first, then
make a separate literal ref query using the branch actually returned. For example:

```bash
gh api repos/gotgenes/pi-packages --jq .default_branch
```

If that response is `main`, query:

```bash
gh api repos/gotgenes/pi-packages/git/ref/heads/main --jq .object.sha
```

Do not assume other repositories use `main`; substitute a verified literal branch,
not a shell variable or command substitution. This is a transport choice, not a
new GitHub-only API permission boundary. Existing API mutation flags still ask,
selected destructive operations deny, and child variable/denied-chain restrictions
remain in force.

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

When subagents materially help, select the named `subagent_type` by task shape:

- `rush`: bounded searches, inventories, and mechanical checks.
- `inspector`: ordinary read-oriented review, focused analysis and routine specialist checks.
- `smart`: focused investigation and implementation subtasks that need writes.
- `deep`: architecture, security, difficult diagnosis, or broad cross-cutting analysis.
- `review`: an independent second opinion from a different model family. Verify the actual resolved model; omit unused optional overrides rather than passing blank strings.

Each `subagent` call launches exactly one agent and supplies a self-contained `prompt`, a 3–5 word `description`, and the selected `subagent_type`. Use an explicit `model` only when the user requests one or a workflow deliberately requires a different model family. For parallel work, issue sibling calls with `run_in_background: true`, record each returned agent ID, then poll with `get_subagent_result({ agent_id, wait: false })`; a collection budget does not stop unfinished agents.

## Worktree workflow

- Inspect and clarify in the current checkout, then create or reuse a linked worktree before the first repository write.
- Specs, plans, tests, source, configuration, and documentation all count as writes.
- The global worktree-guard extension blocks Pi's direct file-write tools in primary checkouts. Do not bypass it with shell redirection or generated-file commands.
- For non-trivial work, load `blindspot-pass` before implementation and `second-opinion-core` after writing or substantially revising a spec or plan. Use one finalization review phase: `pr-closeout` owns it for PR work and local/pre-PR readiness; `polish-core --fix` is its reusable review/cleanup engine, not an additional automatic reviewer loop. Reuse only matching base/scope/profile/working-content evidence (record HEAD as provenance); retain repository-required autoreview and risk-driven specialists. Inspect cleanup edits, rerun verification, and use `change-explainer` for the write-up. Follow the shared project-review contract bundled with `pr-closeout`: reviewers return evidence-linked feedback candidates; only the coordinator writes profile files and commits/pushes them with plain Git, retaining existing private-store sync. Do not silently edit tracked guidance or expand posting authority.

## Implementation

- Follow established repository patterns and avoid speculative abstractions.
- Add or update tests for meaningful behavior changes.
- Preserve useful error context and avoid unnecessary dependencies.
- Prefer `NAME=value command` over `env NAME=value command`; the permission parser can inspect assignment prefixes directly, while `env` is an opaque indirection wrapper that requires approval.
- Comment intent and tradeoffs rather than restating code.
- Never use `--no-verify` unless the user explicitly requests it. If a hook fails for unrelated reasons, stop and ask rather than fixing unrelated code.

## Local file references

- In interactive Pi responses, render references to existing local files as
  Markdown links, not bare paths or inline code.
- Use a readable project-relative label and an absolute, percent-encoded
  file:// URL as the destination.
- Put line positions inside the URL: #L42 or #L42-49.
- Link only files known to exist; do not invent paths.
- Keep repository documentation, PR descriptions, and other shared artifacts
  portable—do not put machine-local file:// URLs in them.

## Completion

Before finishing:

1. Inspect the final diff and compare it with the request and repository constraints.
2. Run focused verification and broader checks when justified.
3. Check for accidental scope expansion, placeholders, dead code, debug output, and incomplete paths.
4. Explain what changed, important decisions, exact verification, and remaining risks.
