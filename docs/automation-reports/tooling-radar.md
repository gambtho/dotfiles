# Tooling radar

2026-11-09: Pi is now 1.5.0, with breaking argument validation and important trust/security fixes. Newly supplied LSP history exposes a working-directory mismatch in our local guard that deserves attention before further mutating LSP use; no new extension or skill earns a trial this week.

## What changed underneath us

Compared with merged report #83 (2026-11-02). Evidence filenames below are relative to the supplied read-only evidence directory; upstream release claims are not local runtime certification.

- **Pi 1.4.0 → 1.5.0 installed; registry 1.5.0:** tool validation moves to `@earendil-works/pi-schema`. Non-JSON-Schema TypeBox refinements/custom formats no longer enforce constraints; plain JSON Schema tools now also receive coercion. Saved project distrust takes precedence over auto-trust, SDK summaries correctly use stored OAuth, and OAuth/login URL handling, terminal control-character handling and amplified glob matching are hardened. Configured-package installation failures at startup now warn and skip resources rather than aborting; explicit update commands still fail nonzero (`versions.txt`, `pi-changelog.md`, `pi-docs/extensions.md`, `pi-docs/packages.md`).
- **Pi 1.5.0 operational defaults:** native extension-update notices appear on a fresh launch; first observation only records the version. Notices require a loaded extension and a package version increase, so skill-only selections and unversioned Git changes remain blind spots. Unpinned invocation-only `-e` packages now check for updates on every start/reload; failed/offline checks retain cache. This is distinct from the configured floating packages advanced by `make ai`. MCP OAuth registration defaults to `auto`; the explicit Copilot startup choice in `ai/pi/settings.json` needs no change (`pi-changelog.md`, `pi-docs/packages.md`).
- **Web access 0.46.0 → 0.47.0 installed/registry:** GitHub README capture increases from 8K to 100K characters, still bounded by the inline reply setting. Sofya/Outcrawl remain explicit opt-ins; `lockProxy` rejects attempts to override a configured proxy and fails every call if no proxy is configured. Our local fetch/no-environment-proxy setup does not justify enabling it (`pi-packages.md`, `ai/pi/config/web-search.json`).
- **Newly visible Narumitw histories; previous report did not record installed versions:** LSP 0.49.12 includes the 0.49.10 active-session-root change and earlier cancellation/draining fixes. Worktree 0.51.9 rejects incomplete Git output before creation/removal/pruning decisions. File-context 0.54.6 includes paging capture fixes; earlier entries sanitize displayed values and prevent extension-started turns consuming queued quotes. These are newly available facts, not measured weekly version arrows (`pi-packages.md`).
- **Selected Git resources:** tmustier history advances to November 3/root bundle 0.1.77, including Ralph 0.2.5 retry/cancellation and stop-banner changes plus quieter startup notes. Superpowers 7.0.1 → 7.0.2 history names brainstorming tuning, harness bootstrap and SDD helper fixes; supplied subjects do not establish exact skill-body or bootstrap deltas. Agent-skills history is unchanged (`pi-packages.md`).
- **Unchanged:** permission-system 42.0.0, subagents 25.0.5, Powerline 0.22.0 and Herdr 0.9.5. Last week's breaking permission/subagent findings are not new incidents. Herdr remains the supplied latest stable; live config retains the template's lane/toast preferences, with an additional machine-local Agents row layout (`pi-packages.md`, `herdr-releases.json`, `herdr-runtime-config.toml`, `pins-check.txt`). Pi-amplike still has no changelog.

## Applied in this PR

- Corrected `ai/README.md`'s unconditional claim that the guard resolves LSP targets using current pi-lsp semantics. The local implementation uses process cwd, while the installed package's history specifies active-session cwd; documented the ambiguity and the limited value of explicit absolute roots without claiming a demonstrated exploit or complete mitigation.

No packages, pins, permissions or Herdr options were changed. No commands/tests were run; PR CI is the test of this documentation edit. No other automation PRs are open. No supplied evidence line starts with `UNKNOWN`; missing histories and unperformed runtime checks remain unchecked, not passes.

## Recommendations

### 1. Reconcile LSP target resolution before trusting switched-session fixes

- Evidence: `pi-packages.md`, LSP 0.49.10/0.49.12; `ai/pi/extensions/worktree-guard.ts` resolves `lspFixPath` against process cwd and captures that base when registering its permission extractor. Built-in write/edit instead use `ctx.cwd`. `libexec/pi-extension-runtime-checks.ts` exercises an absolute-root LSP denial, which does not settle divergent bases.
- Change: in an authorized isolated fixture, keep process cwd in a linked worktree and activate a session in the primary checkout. Exercise omitted, relative and absolute LSP roots, including nested Codemode calls and reload/switch. Compare the actual LSP target with both guard and permission-extractor targets. If they diverge, make a separately reviewed implementation change to use current session semantics and refresh extractor ownership/base on rebinding. Until resolved, avoid mutating LSP calls with omitted/relative roots in switched sessions; use guarded built-in edits instead.
- Risk: a mismatch could check the wrong checkout or produce false denials. The evidence shows differing resolution contracts, not whether every live switch leaves process cwd different. Neither a passing fixture nor absolute-root use creates OS containment; no permission-rule edit or guard bypass is proposed.

### 2. Qualify Pi 1.5's schema and startup behavior on the selected graph

- Evidence: `pi-changelog.md` 1.5.0 Breaking/Fixed; `pi-docs/extensions.md` “Tool parameter schemas and TypeBox”; `pi-docs/packages.md` startup failure behavior. Affects the installed-runtime gates described in `ai/README.md`, gotgenes forwarding and the local guard's `write === true` mutation test. The README's Pi 1.3.0 characterization is historical, not certification of 1.5.
- Change: rerun existing installed-schema/evaluator and native runtime gates with recorded 1.5/package identities. Add focused cases for a mutating LSP call with `write: "true"`, optional nulls, invalid paths and numeric/array coercion, verifying the guard and forwarded decisions see the effective arguments. Audit selected third-party schemas for TypeBox-only constraints. In a disposable agent directory, simulate an unavailable configured permission package and prove startup warnings/missing resources stop operator readiness—not silently approve unattended work. Verify saved distrust in an AGENTS-only project without relaxing the policy.
- Risk: validation may accept/coerce inputs differently or omit custom checks; changed error strings can break fixtures. Startup continuing without a required extension is degraded operation, not readiness. Unavailable tools/packages, schema failures and skipped checks must remain rollout blockers.

### 3. Exercise Worktree's new incomplete-output refusal

- Evidence: `pi-packages.md`, Worktree 0.51.9, and `pi-changelog.md`, Pi 1.5 `pi.exec({ maxBuffer })`/`truncated`. Affects the parent-only worktree UI selected in `ai/pi/settings.json` and existing create/switch/remove runtime coverage documented in `ai/README.md`.
- Change: extend the existing isolated worktree exercise with deliberately oversized Git output. Verify overflow is distinguished from timeout, partial worktree/status listings cannot approve removal or pruning, and creation does not report success from incomplete results. Retain ordinary dirty-removal/confirmation and conversation-preservation checks on the selected 0.51.9 graph.
- Risk: large repositories may now refuse an operation that previously appeared to succeed. Treat refusal as protective, not a reason to increase buffers blindly or fall back to destructive shell cleanup. Native output caps do not replace the local guard.

### 4. Prove Ralph's final-iteration retry cannot duplicate wrap-up

- Evidence: `pi-packages.md`, November 3 Ralph 0.2.5 history: final-iteration retry fix, cancellation detection via skipped settle boundary, and stop banner becoming a message rather than a model prompt. `ai/marketplace/plugins/my/skills/overnight-improve/SKILL.md` maintains its own iteration counter and final-phase push/PR workflow.
- Change: before another unattended run, use a disposable linked worktree, deterministic provider and fake push/PR endpoints. Retry/abort at the last iteration, test completion and max-iteration exit, and inject a denied gate. Verify counters, one wrap-up/publication attempt, no model turn triggered solely by the stop banner, and YOLO-off verification on every exit. Inspect the selected upstream source to determine exact retry semantics; commit subjects alone are insufficient.
- Risk: duplicate wrap-up can publish twice; a lost cleanup turn can leave temporary YOLO active. Do not assume a stop notification performs the skill's cleanup or change permission settings automatically in this PR.

### 5. Treat Pi exports as full-context disclosures

- Evidence: `pi-changelog.md`, 1.5.0 HTML-export fix: exports now include system prompt, tools and later system-section updates. Affects the private-project-knowledge and local-artifact guidance in `ai/README.md` and `ai/pi/AGENTS.md`.
- Change: separately add an export/share warning to operator documentation. In an isolated session containing dummy private-profile text and a tool/rules update, export locally and inspect what is included before approving any sharing. Review exports as sensitive documents; do not attach raw ones to public PRs or support reports by default.
- Risk: exports can expose private context, rules, tool schemas and workflow material previously absent from HTML. This is a behavior change, not evidence that any existing export leaked; `/share` destination policy is not changed here.

## Evaluated and passed on

- **Native status as a bridge replacement:** Pi 1.5 fixes regular-mode OSC status and adds inline-dialog `blocked`, but neither establishes replacement of the session ID/path and prompt-label bridges. Retain both; no proven deletion this week.
- **Additional update/changelog settings:** keep default `collapseChangelog: false` for visibility into floating extensions. Native notices are useful but cannot replace Git/skill history review. No custom self-update wrapper is needed for this operator-owned managed install; no new Herdr option clearly improves the already matching live preferences.
- **billion-context / context-mode / Molio / OpenWiki:** compression/knowledge claims do not demonstrate a failure in native compaction, session-query or curated private knowledge worth adding automatic capture/execution. No source audit or measured compression quality is supplied.
- **skillshare / broad skill packs / diagram and design skills:** resource ownership is already explicit in the installer and local package; no demonstrated synchronization gap. Local review/planning skills and Superpowers cover engineering process, while Claude already has Impeccable, TDD, diagnosis and extensive product skills. No repository need for scientific, reverse-engineering or presentation bundles is evidenced.
- **pi-deltabox / pi-dispatch / pi-automode:** these would substantially change containment, delegation or approval behavior deliberately chosen here. Discovery descriptions alone do not establish compatible enforcement or an authorized problem to solve. No new extension trial proposed; adoption/activity is not proof of safety.
- **Previously passed candidates and broad pin refresh:** no changed capability evidence overturns last week's decisions on MCP/LSP duplicates, fleet managers, memory replacements or blanket dependency upgrades. Newer version numbers alone do not justify pin changes.
