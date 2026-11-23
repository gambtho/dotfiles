# Dotfiles health

The repository is structurally healthy, with current command and package inventories, but one completed migration plan remains as active documentation and some tests duplicate prose instead of testing behavior. This review corrected three stale AI-documentation statements; the remaining cleanup is bounded and does not require changing dependency pins or installer behavior now.

## Applied in this PR
- Corrected `README.md:602` and `ai/README.md:406` to document all four linked Pi extensions, matching the installer-owned list at `ai/pi/install.sh:31`.
- Clarified `ai/README.md:243`: `make ai` reconciles Pi and bootstraps Copilot CLI, but does not run the separate agent-knowledge ensure phase, matching `Makefile:57` and `Makefile:71`.

## Recommendations

### 1. Remove the finished public/private command migration plan
- Evidence: `docs/superpowers/plans/2026-09-11-public-private-commands.md:5` still presents the `libexec/` migration as a 410-line unchecked implementation plan. The stated goal is already the documented and enforced layout: private tooling is under `libexec/` (`README.md:417`), and the exact six-command public inventory is asserted by `tests/repository_hygiene.bats:188`. The plan also names a spec path at `docs/superpowers/plans/2026-09-11-public-private-commands.md:11`, but that spec is absent, and no other tracked file references this plan.
- Change: delete the plan, removing about 410 lines. Search external private runbooks for this exact filename first; if one still needs the historical implementation, keep it in Git history rather than the active checkout.
- Risk: an operator could still be using the unchecked tasks as a reference, even though the repository no longer has the pre-migration layout. Confirm no open implementation task, active host migration, or private runbook depends on it; then verify `make check` still treats only the current layout as authoritative.

### 2. Test lane-coordinator behavior instead of required wording
- Evidence: `tests/lane_coordinator.bats:498` requires dozens of literal phrases such as “One home per fact,” “Replace, don't add,” and an exact illustrative `reports/decision.md` path at `tests/lane_coordinator.bats:526`. Nearby tests repeat this pattern for closing, daily maintenance and weekly maintenance. The actual rule is behavior: retain a compact single source of truth (`ai/marketplace/plugins/my/skills/lane-coordinator/references/state-template.md:16`) and put one scoped decision record where the coordinator points (`ai/marketplace/plugins/my/skills/lane-coordinator/references/state-template.md:62`).
- Change: replace incidental sentence and filename assertions with structured checks for required sections, scope, owners, resume conditions and record pointers. Keep the existing executable projection test at `tests/lane_coordinator.bats:535`; remove roughly 50 brittle phrase assertions and add a smaller table-driven policy check, about 30–50 lines net smaller.
- Risk: an overly broad rewrite could let a safety rule disappear. Preserve explicit checks for approval, authority, budgets, unambiguous identity and non-atomic closeout; demonstrate that deleting a required policy fails the revised test while harmless wording and example-path changes pass.

### 3. Retire the pi-sandbox compatibility path after a final host audit
- Evidence: the authored package set has no pi-sandbox (`ai/pi/settings.json:35`), and the active policy test requires its complete absence from package and child-exclusion inventories (`tests/pi_permissions.bats:820`). The installer still carries a special reset of an active YOLO policy (`ai/pi/install.sh:494`) and a separate exclusion cleanup (`ai/pi/install.sh:543`) solely for that retired package.
- Change: audit the selected active Pi runtime directories on supported personal, work, and WSL hosts. If none contains that exact package source, remove the two compatibility functions, their installer call sites, focused migration tests and the transitional paragraph in `ai/README.md`; roughly 70–100 product lines and 100–150 test lines can be removed. If one host still needs migration, run the explicit one-time cleanup there, record completion, and then perform the removal in a later review.
- Risk: an old host could retain the sandbox package with YOLO policy and lose the intended safe handoff. Before deletion, require a read-only host inventory and successful normal `make ai-check` for each host; preserve the normal authoritative policy publication and its active-YOLO refusal independently of this compatibility removal.

## Checked, nothing to do
- Prompt and skill inventories: the 9 prompts and 15 skills in `ai/marketplace/plugins/my/package.json:9` match the package inventory in `ai/marketplace/plugins/my/README.md:5`; `AGENTS.md:47` describes the same resources.
- Public command boundary: `tests/repository_hygiene.bats:188` enforces the exact six executable files and rejects extras.
- Dependency pins: the supplied check completed rather than reporting `UNKNOWN`; current-version drift is routine and belongs in `make pins-update`, so no pin bump is proposed here.
- Shell-startup findings from review #84 and the two Herdr recommendations from review #138 remain known findings, not newly duplicated ones; the accepted permission/upstream items in the open tooling-radar PR are outside this review.
- Verification was static as required. No commands, tests, network checks or live host audits were run; PR CI must validate the documentation edits.
