# Tooling radar

2026-11-23: the floating permission implementation has advanced to 42.2.0, adding security-relevant chained-command behavior that should be covered before the next reconciliation. The installed Herdr binary is unchanged, but the live lane shortcut still calls the retired `lane` executable; no new package earns a trial this week.

## What changed underneath us

Compared with the previous report on this checkout dated 2026-11-16. Upstream notes are evidence, not results of a local runtime test.

- **Permission-system 42.0.0 → 42.2.0 installed/registry.** Forwarded subagent Bash is now matched in its spellings on the parent (42.0.2); path rules include the on-disk spelling of macOS case/Unicode variants (42.0.3); chain prompts name and may grant all unresolved units (42.1.0); and a link-based authorizer can allow only part of a Bash chain, leaving the remainder to the prompt (42.2.0). The last two changes alter how grants are described and composed. The tracked rules and permission model did not change (`pi-packages.md`, `ai/pi/config/permission-system.json`).
- **Pi remains 1.5.2 installed; registry is 1.6.0.** The supplied installed changelog stops at 1.5.2, so all 1.5.2→1.6.0 behavior, compatibility and breaking changes are **UNKNOWN**. This registry version is not evidence that the managed host changed: host self-update remains operator-owned (`versions.txt`, `ai/README.md`).
- **Web Access 0.48.0, subagents 25.0.5, LSP 0.49.12, File Context 0.54.6, Powerline 0.22.0 and Superpowers 7.0.2 remain unchanged.** Worktree remains installed at 0.51.10 although the registry has 0.51.11; its candidate delta is not supplied and no update occurred in the evidence (`pi-packages.md`, `pi-list.txt`).
- **Selected agent-skills history advances to manifest 0.6.17.** The visible additions concern accessibility and infrastructure/review artifacts; whether either selected skill body (`security-and-hardening`, `performance-optimization`) changed remains **UNKNOWN** from commit titles alone (`pi-packages.md`, `ai/pi/settings.json`).
- **Herdr remains 0.9.5 installed/pinned.** The released config already has the intended row/sort/toast options, but `herdr-runtime-config.toml` still calls `~/.local/bin/lane`, while the repository template and installer now use `~/.local/bin/herdr-lane`. Normal installation deliberately does not overwrite that drift, so the shortcut can retain a broken old command path (`versions.txt`, `herdr-runtime-config.toml`, `tools/herdr/config.toml.template`, `tools/herdr/README.md`).

## Upstream changes that could break or help us

- **Unreleased on Herdr master:** [4898729, stop queuing stale screens for TUI clients that stop reading](https://github.com/herdrdev/herdr/commit/489872956bc894fed8d03661fff4146f63ace687) and [e8d7d97, retry interrupted handoff reads and reap pane shells in 500+ pane sessions](https://github.com/herdrdev/herdr/commit/e8d7d9705a7a2c89cef4dd42079379f05685af87) target reconnect/presentation and large-session recovery. Those are relied-on surfaces for persistent Pi panes, plugin reconnects and the dashboard's snapshot consumers, but commit titles do not prove a release, API compatibility or a locally reproduced defect. Carry them into the next Herdr release qualification; do not move the pin or runtime early.
- **Previously observed unreleased recovery fixes remain relevant:** [keep a slow server's socket](https://github.com/herdrdev/herdr/commit/ff5881ef45086ffef98a907f0009f37f36565681) and [preserve layout when panes die during host shutdown](https://github.com/herdrdev/herdr/commit/6b526626f66e22c08962a7f39a83fc9ac2ebda62) still bear on saved-machine availability and pane recovery. They are absent from the supplied released 0.9.5 notes, so treat them as master-side candidates only.

`herdr-commits.json` compares `v0.9.5...master`, reports `diverged`, **43 commits**, and explicitly covers only the latest page; omitted earlier commits are UNKNOWN. `herdr-unreleased.md` is empty, which is not proof that master has no post-0.9.5 changes. The bounded activity search since 2026-11-15 found **72 matching issues / 73 discussions**, fetched only 20 of each, with `hasNextPage: true` for both; omitted matches and title/state-only reports do not establish behavior changes.

## Tracked Herdr threads

The 2026-11-16 rows were complete enough for the fields below, so only the limited comparisons stated here are made. No maintainer comment was observed.

| Thread | Closed/state | updatedAt | Comments totalCount | latestObservedMaintainerReplyAt | Observed PR URLs | Comparison and coverage |
|---|---|---|---:|---|---|---|
| Discussion [#1953](https://github.com/herdrdev/herdr/discussions/1953), workspace folders | `closed: false` / open | `2026-11-18T00:37:44Z` | 16 | `null` | `[]` | Versus 2026-11-16: `updatedAt` advanced (previously 2026-11-16) while the count stayed 16; the newly fetched latest reply is by association `NONE`, not maintainer. Last 10 comments of 16, last 5 replies per fetched comment, 300-character excerpts; omitted history UNKNOWN. |
| Discussion [#4396](https://github.com/herdrdev/herdr/discussions/4396), client saved-machine selection | `closed: false` / open | `2026-11-20T12:47:51Z` | 18 | `null` | `[]` | Versus 2026-11-16: `updatedAt` advanced and the top-level count increased from 16 to 18. The two latest visible comments have association `NONE`; they do not establish an API or maintainer decision. Last 10 comments of 18, last 5 replies per fetched comment, 300-character excerpts; omitted history UNKNOWN. |

Explicit PR links in fetched text are none for both threads, but discussion backlink coverage is incomplete; omitted links and historical maintainer activity remain UNKNOWN. Both GraphQL files supplied data this run.

## Recommendations

### 1. Requalify chained-command grants after permission-system 42.2

- Evidence: permission-system 42.0.2–42.2.0 in `pi-packages.md`; the policy and installed-schema/evaluator gates described in `ai/README.md`; affected files are `ai/pi/config/permission-system.json` and the named-agent configuration.
- Change: before the next stopped-session `make ai`, run the existing security/native runtime gates on the selected package graph. Include a partially allowed chain, a pending unit, a session grant, a forwarded child command, and a denied unit later in the chain; verify the final prompt and audit output do not represent unapproved units as granted. Do not pin, patch the cache, or weaken policy.
- Risk: inaccurate grant composition could surprise the operator even if explicit denies remain intact. These are tripwires and not OS containment.

### 2. Repair the one known machine-local Herdr lane-command drift

- Evidence: `herdr-runtime-config.toml` calls the retired `~/.local/bin/lane`; `tools/herdr/config.toml.template` calls `~/.local/bin/herdr-lane`, as documented in `tools/herdr/README.md`.
- Change: inspect and back up the full live config, change only the popup executable from the old command to `herdr-lane`, then run `herdr config check` and `herdr server reload-config` only if validation succeeds. Do not blindly refresh the template or overwrite unrelated machine-local bindings.
- Risk: a malformed or incomplete TOML merge could disable other shortcuts; no server restart or binary update is needed.

### 3. Qualify Herdr reconnect and stale-stream fixes before a future pin move

- Evidence: the two unreleased master commits above plus [#5511](https://github.com/herdrdev/herdr/commit/ff5881ef45086ffef98a907f0009f37f36565681) and [#5510](https://github.com/herdrdev/herdr/commit/6b526626f66e22c08962a7f39a83fc9ac2ebda62); watched behaviors and consumers are documented in `tools/herdr/README.md` and used by the lane/dashboard tooling.
- Change: when a post-0.9.5 release exists, verify its actual diff and protocol, then use a disposable server to test slow/stalled clients, host shutdown, layout retention, plugin pane reconnect/reload, snapshot and agent-list responses, and restored focus. Keep the current explicit protocol allowlist until separately reviewed.
- Risk: a commit-title fix may not be in the chosen release or may accompany an incompatible response/protocol change. Never use live agent sessions as the upgrade fixture.

## Evaluated and passed on

- **New extension candidates:** no candidate demonstrably replaces an installed capability. For example, [carderne/pi-sandbox](https://github.com/carderne/pi-sandbox) advertises OS-level sandboxing (312 discovery stars; updated 2026-11-19), but the supplied evidence has no source audit or matching replacement trial; it would run agent-side and mediate broad filesystem/process activity. This is not a safety endorsement, and no overlap or migration case justifies a trial here yet.
- **New skill packs:** broad discovery entries overlap Superpowers, the selected security/performance resources, the local `my` review/lane skills and the installed Claude Code skills (`tdd`, `diagnose`, `intended-vs-implemented`, `impeccable`, product and review workflows). No repository-visible gap justifies importing another broad pack.
- **Tracked folders and machine-selection proposals:** #1953 and #4396 remain open proposals. The visible new non-maintainer comments show continued demand, not stock TUI/API availability; retain worktree anchoring and Ctrl-B w navigation.

Only this report was changed. No packages, pins, permission rules or Herdr options were modified, and no commands/tests were run; PR CI must validate the report. Supplied evidence did not contain a line beginning `UNKNOWN`, but the explicitly marked missing Pi 1.6 history, selected-skill bodies, Worktree 0.51.11 delta, bounded GraphQL coverage and absent live-runtime checks remain unknown rather than passes.
