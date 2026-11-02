# Tooling radar

2026-11-02: the floating permission and subagent packages have breaking changes worth checking against our runtime gates, not reasons to loosen policy. Herdr is already at the latest supplied stable release; no new extension or skill clears the replacement/value bar this week.

## What changed underneath us

This is the first report: `previous-prs.md` says there were no previous runs, and no previous report exists here. Version arrows below describe upstream release transitions, **not a measured change in this host since last week**. Evidence paths below are relative to the supplied read-only evidence directory.

- **Permission-system 40.3.0 → 41.0.0 → 42.0.0; installed/registry 42.0.0:** 41 changes delegation of certain Bash external-directory asks when extracted paths name nothing on disk; 42 rejects config arrays over 1,000 entries before traversal. Upstream also reports requiring Zod 4.6.7 to patch CVE-2023-54404. These are upstream claims, not a local dependency/security audit (`pi-packages.md`).
- **Subagents 24.0.1 → 25.0.0 → 25.0.5; installed/registry 25.0.5:** background resumes now enter through `maxConcurrent`; a second resume while one is queued is rejected. Later fixes clarify queued/wait-expired results, and 25.0.5 removes the whole skills section of a forced parent prompt from child identity (`pi-packages.md`).
- **Pi 1.3.0 → 1.4.0 installed; registry 1.5.0:** summaries now use the model output limit rather than `reserveTokens`; busy Codemode workers queue for up to 60 seconds instead of failing immediately. Resume/tree navigation can activate extension tools that an old branch never explicitly selected or deselected. The supplied changelog stops at 1.4.0: **1.5.0 behavior and compatibility are unknown**, so no upgrade endorsement follows (`versions.txt`, `pi-changelog.md`).
- **Web access 0.45.0 → 0.46.0; installed/registry 0.46.0:** PDF fetches return text rather than only a saved-file notice; proxy reload and curl redirect handling are fixed. New paid/remote search and fetch routes are opt-in. The tracked local-only fetch route and disabled environment-proxy trust should remain intact (`pi-packages.md`, `ai/pi/config/web-search.json`).
- **Powerline 0.21.0 → 0.22.0; installed/registry 0.22.0:** our `cache_read.format: "both"` now counts newly cached tokens as misses, so a lower displayed hit rate need not mean a performance regression. Version 0.21 also changed cost totals to include all branches and billed failures and removed double-counted subagent costs (`pi-packages.md`, `ai/pi/settings.json`).
- **Other floating resources:** the selected tmustier checkout includes session-recap 0.6.0/persistence and a usage-session-directory fix dated October 28. Superpowers history reaches 7.0.1, with brainstorming and compaction-survival changes. Agent-skills history reaches November 1, but only security/performance skills are selected here; review/router changes are not automatically loaded. The history snippets do not establish detailed recap persistence semantics or which selected skill bodies changed. Pi-amplike, LSP, worktree and file-context have **no changelog supplied**, so behavior deltas remain unchecked (`pi-packages.md`, `ai/pi/settings.json`).

## Applied in this PR

- Removed the misleading claim that subagents 23.4 is current. Preserved its documented historical turn-budget behavior, identified installed 25.0.5, and made current-runtime verification explicit rather than claiming the older test certifies it.

No packages, pins, permission rules or Herdr options were changed. No commands or tests were run; PR CI is the test of these documentation edits. The supplied evidence contains no lines starting `UNKNOWN`; missing changelogs and absent 1.5.0 release evidence are nevertheless unknowns, not successful checks.

## Recommendations

### 1. Requalify permission-system 42 without changing the policy

- Evidence: `pi-packages.md`, permission-system 41/42 release entries; affects `ai/pi/config/permission-system.json`, named-agent rules and the installed schema/evaluator gate described in `ai/README.md`. The tracked external-directory catch-alls already allow ambiguous external paths, so the 41 change is not by itself proof of a new effective allowance here.
- Change: on the next authorized stopped-session reconciliation, record the selected package/dependency identities and run the existing installed-schema/evaluator and `make pi-runtime-test` gates. Explicitly exercise absent-path commands, expansion/unknown-command cases and forwarded child decisions. Check actual config arrays against the new 1,000-entry limit; it is not a limit on JSON lines or all policy entries combined. Inspect the resolved Zod version rather than treating a package changelog as proof of the dependency graph.
- Risk: oversized machine-local arrays may stop config loading; delegation changes could alter which layer decides an ask. Fail the rollout on incompatibility—do not weaken rules, bypass the gate or describe the result as OS containment.

### 2. Test queued resumes and child prompt filtering on subagents 25

- Evidence: `pi-packages.md`, subagents 25.0.0–25.0.5; `ai/pi/config/subagents.json` sets `maxConcurrent: 4`, `defaultMaxTurns: 50`, `wrapUpTurns: 5`. `ai/pi/AGENTS.md` requires recording background IDs and polling, not treating a collection budget as cancellation.
- Change: extend the existing runtime exercise in `tests/pi_extension_runtime.test.mjs` as needed: occupy four slots, queue a background resume, confirm a duplicate resume is rejected, free a slot and collect the original ID. Verify a wait-expired queued response is not treated as completion. With the real Superpowers bootstrap, check that child identity has its own selected skill context rather than a copied parent skills section. Recheck the 50-turn ceiling/five-turn warning separately; do not reintroduce `graceTurns`.
- Risk: retrying a queued resume can now fail instead of starting another operation. Prompt-layer changes may alter skill routing even when the permission and tool allowlists are unchanged. No concurrency or permission edits are proposed.

### 3. Treat Pi 1.4 as a compatibility target, not a reason to enlarge budgets

- Evidence: `pi-changelog.md`, 1.4.0 Changed/Fixed; `pi-docs/settings.md`, Compaction. Affects the four `650000` reserve overrides in `ai/pi/settings.json` and the Pi 1.3.0 runtime-test characterization in `ai/README.md`.
- Change: rerun the installed-runtime gate on the actual 1.4 graph with deterministic providers. Cover `/compact` instructions on a split turn, two occupied Codemode workers plus a waiting script, and resume/tree navigation with a newly registered extension tool. In a separately authorized documentation update, clarify that the large reserve controls **when compaction starts**, not the summary's output cap. Keep the existing budgets unless measurements justify changing them. Obtain 1.5 release evidence before considering host self-update.
- Risk: longer summary output can change latency/usage; worker queuing adds wait time; resumed tool exposure may differ from an old session's apparent selection. The configured Copilot startup model already matches 1.4's new default, so no model migration is needed.

### 4. Let the existing search fallback handle empty answers

- Evidence: `pi-packages.md`, web-access 0.45.0 Added; `ai/pi/config/web-search.json` routes Exa → DuckDuckGo but `fallbackOn` lacks `"empty"` and `"domain-miss"`.
- Change: trial adding those two values to `searchRouting.fallbackOn` in a disposable configuration, preserving all other routing and privacy settings. Use controlled empty and domain-mismatch responses to prove DuckDuckGo is attempted, then compare a few representative repository-research queries. Promote only if it resolves missed searches without unacceptable extra requests. Existing runtime config is preserved by `make ai`, so any later rollout needs a deliberate merge, not a reset.
- Risk: more queries/IP metadata reach the fallback provider and searches may take longer. If every provider returns an empty/domain-miss response, upstream says the first passed-over answer is returned; this is not guaranteed discovery. Do not enable hosted fetching, Cloudflare extraction, browser cookies or a curl executable merely because the same release advertises them.

### 5. Use corrected cache numbers before tuning anything

- Evidence: `pi-packages.md`, Powerline 0.22.0; `ai/pi/settings.json` selects `"both"`, and `ai/README.md` documents cache observability preferences.
- Change: retain `"both"` initially and establish a new baseline. If it obscures per-request misses, briefly trial `powerline.cache_read.format: "session-request"` in machine-local settings, comparing one ordinary follow-up, one model switch and one compaction. Keep it only if the latest-request figure makes diagnosis clearer; do not change budgets in response to a display-formula correction.
- Risk: custom/minimal layouts may not display the segment, and provider reporting limits accuracy. Normal `make ai` preserves non-package preferences; editing the tracked setting alone would not migrate an existing host.

## Evaluated and passed on

- **Delete the Herdr bridges in favor of native Pi status:** Pi 1.1 added OSC 7501 status and Herdr 0.9.4 improved Pi detection, but the evidence does not establish equivalent session-path/ID reporting. `ai/pi/extensions/herdr-agent-state.ts` also reports that identity; `herdr-prompt-state.ts` bridges prompt labels. No proven complete replacement, so delete neither.
- **Additional Herdr options:** installed/pinned 0.9.5 is current in `herdr-releases.json` and `pins-check.txt`; the live config already matches the template's lane/sidebar/toast choices. No clear unused option justifies another default. New plugin-update support does not replace a repository-managed plugin updater here.
- **pi-herdsman / pi-dynamic-workflows:** overlap with gotgenes children and our explicit-launch `lane-coordinator` skill, also already installed for Claude Code. Discovery descriptions do not prove the same permission forwarding, nonrecursive child policy or session-identity guarantees. No trial recommended on this evidence.
- **pi-mcp-adapter / pi-mcp-extension and pi-lens:** native Pi already supplies MCP; pi-lens overlaps the selected LSP diagnostics/fix stack and repository checks. No demonstrated gap worth another in-process extension.
- **Ponytail, planning-with-files, broad engineering/marketing skill bundles:** scope/minimalism and planning overlap `ai/pi/AGENTS.md`, local implementation/review skills and Superpowers; Claude already has TDD, diagnosis, code review, extensive product/marketing skills and Impeccable. Popularity does not establish a missing capability or safety.
- **Memory/compaction replacements:** pi-blackhole, pi-posthorse and claude-mem would compete with native compaction, session-query and the explicitly curated private-knowledge workflow. No observed recovery/context failure justifies replacing those mechanisms or automatically capturing more session material.
- **Broad pin refresh:** `pins-check.txt` reports several newer language/tool versions, including Go/Python/Java advances and a tree-sitter 0.26 → 0.27 transition. There are no corresponding compatibility/security release notes in the supplied evidence; no blanket update or pin edit is justified by version distance alone.
