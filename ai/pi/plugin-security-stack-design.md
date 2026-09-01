# Pi Plugin and Security Stack Design

## Status

Revised after independent `/second-opinion` review and follow-up package analysis on 2026-09-01. The user accepted the review findings and selected a parent-only sandbox after verification showed that `pi-sandbox` is unsafe to bind into concurrent in-process child sessions.

This document is ready for user review before implementation planning.

## Context

The dotfiles repository manages Pi as its sole coding-agent harness. The current configuration already provides GitHub Copilot models, modes and subagents through `pi-amplike`, plan mode, Ralph loops, usage and status UI, clipboard support, custom review workflows, and a direct-tool worktree guard.

Three shortcomings motivate this change:

1. The installed Brave and Jina search skills are unusable without additional credentials in the current environment. Brave reports a missing `BRAVE_API_KEY`; unauthenticated Jina returns HTTP 401.
2. `pi-amplike` permissions inspect only the `bash` tool and produce enough false-positive prompts that YOLO mode is currently left enabled. They do not govern custom tools or general path access. The custom worktree guard separately protects only Pi's built-in `edit` and `write` tools.
3. `pi-amplike` subagents create child sessions with extensions disabled. Those children do not inherit the permission system, sandbox, or worktree guard, and their Bash policy independently reads Amp's permission files. Retaining that subagent runtime would leave a privileged escape around the new security layers.

The change adds three focused workflow capabilities, targeted LSP diagnostics, a permission-aware replacement subagent runtime, and a layered permission-plus-parent-sandbox security model.

## Goals

- Make steering and follow-up messages visible and editable during long-running work.
- Provide reliable web search and page extraction with keyless fallbacks and conservative defaults.
- Enable retrieval of code snippets from prior assistant messages.
- Add targeted, on-demand LSP diagnostics without adopting an invasive continuous-analysis suite.
- Replace Amp's Bash-only permission gate with deterministic policy covering built-in and custom tools.
- Replace Amp subagents with children that inherit the permission system and worktree guard.
- Preserve the `rush`, `smart`, `deep`, and `review` routing concepts while adopting the replacement subagent tool's schema.
- Add OS-level containment around the parent session's shell commands on Linux and WSL.
- Preserve reproducible repository-managed defaults while keeping mutable runtime state, credentials, grants, and sensitive logs outside Git.
- Retain the existing worktree workflow and hard block direct file-tool mutations in primary checkouts.
- Keep unattended workflows possible through a YOLO mode that preserves explicit denies.

## Non-goals

- Do not add another plan system, footer, usage dashboard, memory layer, MCP bridge, or interactive PTY extension.
- Do not adopt `pi-lens`.
- Do not preserve the old batched `subagent({ tasks, mode })` calling convention through a custom compatibility adapter.
- Do not claim that an in-process permission extension is an isolation boundary.
- Do not claim that `pi-sandbox` safely contains in-process subagents; it is deliberately parent-only.
- Do not maintain a security-critical local fork of `pi-sandbox`.
- Do not attempt to infer every filesystem mutation made indirectly by an arbitrary build script.
- Do not expose SSH keys, cloud credentials, browser cookies, Docker sockets, or unrestricted Unix sockets to sandboxed parent processes by default.
- Do not delete unrelated user-installed skills while retiring the broken Brave skill.

## Selected packages

New package sources are pinned because extension code executes with the user's full authority and because policy/configuration compatibility matters.

| Capability | Package | Pin | Rationale |
|---|---|---|---|
| Visible queued steering | `tmustier/pi-queue-steer` | `v0.2.0` | TUI-only queue editing with strong automated and real-TUI coverage; no model-facing tools |
| Web research | `pi-web-access` | `0.27.0` | Structured search/fetch tools, keyless Exa/DuckDuckGo fallback, local extraction, SSRF controls |
| Code snippet actions | Existing `tmustier/pi-extensions` checkout | existing package, enable `code-actions/index.ts` | Adds `/code` retrieval and insertion without another package checkout |
| Targeted diagnostics | `@narumitw/pi-lsp` | `0.49.6` | Two on-demand tools, no persistent server fleet, explicit Earendil Pi support |
| Subagents | `@gotgenes/pi-subagents` | `21.2.0` | In-process children inherit extensions; native permission-system integration and parent prompt forwarding |
| Permission policy | `@gotgenes/pi-permission-system` | `29.2.0` | Fail-closed Bash parsing, path and external-directory gates, custom-tool and child-session coverage |
| Parent shell containment | `carderne/pi-sandbox` | commit `53bd1d64d896d4a6bfab3769023201891e76ba72` | Includes the post-0.6.5 subprocess-hang fix; uses Bubblewrap on Linux |

`pi-amplike` remains installed in explicitly filtered object form. It retains only `extensions/modes.ts`, `extensions/handoff.ts`, `extensions/btw.ts`, `extensions/session-query.ts`, and `skills/session-query/SKILL.md`. It does not load `extensions/amp-skills.ts`, `extensions/permissions.ts`, `extensions/subagent.ts`, or the Jina web-search/page-visit skills. Prompt and theme filters are empty. Every resource category is explicit so future package resources do not begin autoloading silently.

## Architecture

### Layer 1: repository workflow and worktree guard

Repository guidance continues to require inspection in the primary checkout followed by implementation in a linked worktree. `ai/pi/extensions/worktree-guard.ts` remains the authoritative direct-tool enforcement layer.

The guard continues to block built-in `edit` and `write` calls targeting a primary checkout. It is extended to block `lsp_fix` when `write=true` and the requested path belongs to a primary checkout. Preview-only `lsp_fix` calls remain allowed.

The replacement subagent runtime binds the parent's extension set into each child, so the worktree guard runs against the child's `ctx.cwd` as well. The guard's recursion and symlink tests remain applicable to child calls because enforcement happens at each child tool boundary.

This layer cannot classify arbitrary shell commands or extension-internal process execution. Those limits remain explicit rather than being presented as complete mediation.

### Layer 2: deterministic permission decisions

`@gotgenes/pi-permission-system` replaces `pi-amplike` permissions. It decides whether model-facing tool calls are allowed, denied, or require a user decision. It is a policy and attention-routing layer, not process isolation.

The global baseline uses a balanced posture:

- universal fallback: `ask`;
- built-in read/search tools: `allow`;
- built-in `edit` and `write`: `allow`, subject to the worktree guard and path policy;
- known workflow tools (`subagent`, `get_subagent_result`, `steer_subagent`, `handoff`, `session_query`, `plan`, Ralph tools, clipboard, and web research): `allow`;
- `lsp_diagnostics`: `allow`;
- `lsp_fix`: `ask`;
- skills: `allow`;
- unknown extension tools and MCP operations: `ask`;
- paths outside the current working directory: `ask`, except Pi infrastructure reads handled by the package;
- sensitive files and credential roots: `deny` across path-aware tools;
- Bash: allow curated inspection, repository status, build, test, lint, type-check, and formatting commands; ask for unmatched commands, package installation, Git mutation, remote mutation, deployment, and opaque wrappers; deny catastrophic deletion patterns and explicitly forbidden credential paths.

Within a permission map, broad rules precede specific exceptions because the package uses last-match-wins semantics.

The policy starts with:

- `yoloMode: false`;
- `doublePressToConfirm: false`, reducing prompt friction while retaining explicit choices;
- `permissionReviewLog: true`;
- `debugLog: false`.

Session approvals are preferred for unfamiliar but legitimate command families. They disappear at session shutdown.

The permission system's YOLO mode remains available through `/permission-system`. It rewrites `ask` decisions to `allow` but preserves explicit `deny` decisions. This is the supported temporary mode for unattended improvement runs and is materially safer than Amp's unrestricted YOLO behavior.

### Layer 3: permission-aware subagents

`@gotgenes/pi-subagents` replaces `pi-amplike`'s `subagent.ts` extension. It preserves the public tool name `subagent` but changes the schema and execution model.

The old call accepted a batched `tasks` array plus a named `mode`. The replacement launches one agent per call:

```text
subagent({
  prompt,
  description,
  subagent_type,
  model?,
  thinking?,
  max_turns?,
  run_in_background?,
  resume?,
  inherit_context?
})
```

Parallel work uses multiple sibling `subagent` calls with `run_in_background: true`, followed by `get_subagent_result` calls for the returned agent IDs. `steer_subagent` provides mid-run steering. There is no `tasks` parameter, `mode` parameter, per-agent wall-clock timeout, or individual stop tool.

The migration updates every personal prompt, skill, test, and guidance file that describes the old batch/mode contract. Existing timeout wording becomes best-effort nonblocking collection: the parent may continue after a documented polling budget and ignore a late result, but the design does not claim the tool killed the agent.

#### Named routing agents

Four repository-authored global agent definitions preserve the routing vocabulary:

```text
ai/pi/agents/
  rush.md
  smart.md
  deep.md
  review.md
```

They are installed under the active Pi agent directory's `agents/` folder. Each definition provides an explicit GitHub Copilot model, thinking level, description, tool allowlist, and prompt mode.

| Agent type | Model | Thinking | Capability posture |
|---|---|---|---|
| `rush` | `github-copilot/gpt-5.4-mini` | low | read-only built-ins for bounded searches and inventories |
| `smart` | `github-copilot/gpt-5.6-sol` | medium | all seven built-ins for normal review and implementation subtasks |
| `deep` | `github-copilot/gpt-5.6-terra` | high | read-only built-ins for architecture, security, diagnosis, and broad analysis |
| `review` | `github-copilot/claude-opus-5` | high | read-only built-ins for independent second opinions |

Read-only agents list `read`, `bash`, `grep`, `find`, and `ls`; they omit `edit` and `write`. Their specialist instructions and permission frontmatter set `path_write`, `write`, and `edit` to `deny`, allow a curated read-only Bash set, and leave unmatched Bash at `ask` for parent forwarding. `smart` lists all seven built-ins and inherits the balanced global permission policy.

The tool allowlist is complete, not additive. Extension tools are absent from children unless deliberately named. The subagent package always removes its own three control tools in children, preventing recursive spawning.

`modes.json` remains the source used by the retained Amp main-session mode selector, while the four agent files are the source used by subagents. The replacement package does not consume `modes.json`, so the two representations cannot share runtime state. Repository tests enforce model/thinking parity. `/mode` changes affect the main-session mode file only and do not rewrite subagent definitions.

#### Child extension inheritance

Children inherit all parent package extensions not listed in `subagents.json` plus directly discovered global extensions. Therefore:

- `@gotgenes/pi-permission-system` must never be excluded. Its native lifecycle integration registers each child synchronously, applies per-agent policy, filters tools, and forwards child `ask` decisions to the parent UI.
- `worktree-guard.ts` remains inherited as a directly discovered global extension.
- Parent-only UI, recap, footer, mode, web, LSP, and similar package extensions are excluded when their tools are not in the child's complete allowlist. This avoids repeated initialization and child shutdown side effects.
- `pi-sandbox` is explicitly excluded using its exact configured package source string.

The global `subagents.json` baseline contains this reviewed `excludedExtensionPackages` list using exact settings-source strings:

- `git:github.com/tmustier/pi-extensions`;
- `npm:pi-powerline-footer`;
- `npm:shitty-extensions`;
- `npm:pi-amplike`;
- `git:github.com/tmustier/pi-queue-steer@v0.2.0`;
- `npm:pi-web-access@0.27.0`;
- `npm:@narumitw/pi-lsp@0.49.6`;
- `git:github.com/carderne/pi-sandbox@53bd1d64d896d4a6bfab3769023201891e76ba72`.

The list deliberately does not exclude `npm:@gotgenes/pi-permission-system@29.2.0`, `npm:@gotgenes/pi-subagents@21.2.0`, the full Superpowers package, or the local personal skill package. Tests assert the complete list and those non-exclusions.

### Layer 4: parent-only Bubblewrap containment

`pi-sandbox` wraps the parent session's built-in Bash implementation and user `!` commands with Bubblewrap on Linux/WSL. It also performs its own policy checks for parent `read`, `write`, and `edit` tool calls.

It is deliberately not loaded inside `@gotgenes/pi-subagents` children. The package uses a process-global static `SandboxManager`; each extension instance initializes or resets that singleton, and every child `session_shutdown` would reset containment still used by the parent or siblings. Child prompts also abort in non-UI contexts rather than forwarding. Binding it into concurrent in-process children would therefore weaken or destabilize containment.

The resulting security boundary is explicit:

- parent model-facing shell: permission system plus Bubblewrap;
- child model-facing tools and shell: permission system plus inherited worktree guard, without Bubblewrap;
- extension-internal code: neither model tool-call policy nor Bubblewrap unless the extension implements its own controls.

Filesystem policy for the parent:

- allow reads in the active project, Pi infrastructure required by extension operation, selected runtime/toolchain directories, and narrowly selected configuration roots needed by approved CLI tools;
- allow writes in the active project, `/tmp`, and selected build/language caches;
- deny writes for SSH keys, cloud credentials, Pi authentication, private key material, and `.env` variants;
- do not broadly allow all of `~/.config` or the home directory;
- recognize that sandbox `denyRead` is a default prompt posture rather than an unoverrideable hard deny, while `denyWrite` takes precedence.

Network policy for the parent:

- allow local development binding;
- allow established GitHub, npm, PyPI, Rust, Go, Ruby, and Maven registry domains required by normal development;
- prompt for unlisted domains;
- do not enable unrestricted Unix sockets, browser processes, Docker sockets, or unauthenticated SOCKS proxying by default.

The permission system's handler loads before the sandbox's secondary checks. Sandbox allowlists include ordinary project and Pi infrastructure paths so normal calls do not produce stacked prompts. Unexpected external paths or domains can still prompt once at the sandbox layer after permission approval.

The sandbox cannot distinguish a primary checkout from a linked worktree. Allowing the current working directory therefore does not replace the worktree guard.

### Explicit bypass boundaries

The following are intentionally documented residuals:

- Gotgenes subagent children do not receive OS-level Bubblewrap containment under this design. They do receive the permission system, per-agent tool allowlists, and worktree guard.
- `code-actions` `/code run` executes only after explicit user confirmation, but calls `pi.exec()` from an extension command. It does not pass through model tool-call permissions or Bubblewrap. The recommended use is `/code ... insert`, followed by a normal reviewed execution path.
- Extension factories, event handlers, and package code run with Pi's full user permissions.
- A permitted build/test/format command can mutate files inside the active working directory. Repository guidance and linked-worktree use remain necessary.
- A subprocess may access credentials from an explicitly allowed configuration directory even when the command line itself does not name that credential file. Only roots required by approved tools are allowed.
- Permission review logs redact values only when their input key is recognized as sensitive. Secrets embedded in Bash command strings are logged unredacted.

## Mutable configuration boundary

### Problem

The installer currently symlinks the entire tracked `ai/pi/extensions` directory to `~/.pi/agent/extensions` and also links `modes.json` directly.

That ownership model conflicts with the new stack:

- permission-system configuration and owner-only logs live below `~/.pi/agent/extensions/pi-permission-system/`, and `/permission-system` mutates runtime knobs there;
- `pi-sandbox` global grants mutate `sandbox.json`;
- `pi-web-access` may persist configuration and API-key references;
- `pi-amplike` mode configuration uses temporary-file replacement, which can replace a managed symlink;
- subagent runtime settings have global and project-local mutable files.

Runtime mutations and sensitive logs must not resolve into the Git checkout.

### Directory ownership decision

The installer replaces the whole-directory extension symlink with a real machine-local extension directory and individual links for authored extension entrypoints.

Tracked baselines live outside auto-discovered runtime directories:

```text
ai/pi/config/
  modes.json
  permission-system.json
  sandbox.json
  subagents.json
  web-search.json
```

Tracked global agent definitions live under `ai/pi/agents/` and are individually linked or published to the active agent directory.

Runtime destinations are resolved from `PI_CODING_AGENT_DIR` rather than hard-coded. Web configuration follows `pi-web-access`'s `PI_CODING_AGENT_DIR` and XDG/legacy resolution order so the installer writes the same path the extension reads.

### Mutable-file reconciliation

A new regular-file reconciliation helper has explicit behavior:

1. **Missing destination:** atomically install the tracked baseline with an appropriate mode.
2. **Identical destination:** do nothing and create no backup.
3. **Differing regular destination:** preserve it, report drift, and print the explicit reset command. Do not discard API keys, grants, YOLO state, mode selection, or runtime tuning during routine `make ai`.
4. **Managed symlink from the old layout:** migrate its current contents into a regular file, then remove only the managed link. This preserves current mode state while severing runtime writes from Git.
5. **Explicit reset:** `PI_AI_RESET_MUTABLE_CONFIG=1 make ai` backs up a differing regular file once, then atomically restores the tracked baseline.
6. **Check mode:** report every action or drift without creating directories, files, or backups.
7. **Invalid destination type:** fail rather than descending into or replacing an unexpected directory.

This policy gives tracked baselines a safe restore path without making routine installation destructive. Backups are created only for explicit resets or one-time ownership migration, so ordinary drift does not create an unbounded timestamped backup series.

File-specific notes:

- permission config and any credential-bearing web config are owner-readable/writable only;
- permission logs remain machine-local under a `0700` runtime directory and are never published from the repository;
- `subagents.json` global defaults are machine-local; `/subagents:settings` continues to write project-local `.pi/subagents.json` according to upstream behavior;
- project-local runtime files remain project-owned and are not swept into dotfiles management.

### Individual extension links and pruning

The installer owns a manifest of individual extension links. It creates or repairs those links while preserving unrelated files and third-party directories.

It prunes only stale symlinks that resolve into this repository's `ai/pi/extensions` tree and no longer correspond to a declared managed extension. It never removes arbitrary extension files, directories, package configuration, or logs.

Rollback does not recreate the old whole-directory symlink. It removes or disables package entries while retaining the real extension directory, individual authored links, and machine-local runtime state. This avoids moving third-party configuration/logs into a backup directory merely to restore the previous package set.

## Web access policy

The `pi-web-access` baseline is intentionally narrower than the package defaults:

- sequential search routing: zero-config Exa followed by keyless DuckDuckGo;
- fallback only for transient, quota, network, or invalid-response failures;
- raw result workflow (`workflow: "none"`), avoiding automatic summary-model calls and browser curator launch;
- direct local HTTP extraction only by default;
- remote hosted fetch providers disabled;
- browser-cookie access disabled;
- automatic repository cloning, YouTube processing, local video processing, and image features disabled;
- PDF extraction enabled with local `unpdf`;
- curator shortcut moved away from `Ctrl+Shift+S`, which belongs to retained Amp modes.

After installation, `pi-amplike`'s Jina `web-search` and `visit-webpage` skills are not loaded.

The independently installed `~/.pi/agent/skills/pi-skills/brave-search` directory is outside package filtering. The installer handles only that exact legacy skill:

1. verify the expected path and `name: brave-search` frontmatter;
2. if it matches, move the directory intact to a non-discovered machine-local quarantine location;
3. preserve local modifications and never delete the directory;
4. perform no action if already quarantined;
5. warn and leave it untouched if identity checks fail;
6. preserve all sibling `pi-skills` resources.

This removes duplicate broken guidance without treating the entire user skill directory as repository-owned.

## LSP policy

`@narumitw/pi-lsp` uses its built-in server catalog and starts matching servers only when called. It does not download servers.

The current machine already provides Ruff, rust-analyzer, gopls, and RuboCop. Missing language servers are reported rather than installed automatically.

`lsp_diagnostics` is available by default in the parent. `lsp_fix` remains available but always goes through the permission system; `write=false` is the expected default. A primary-checkout `write=true` request is blocked by the worktree guard even if approved at the permission layer.

The named child agent allowlists do not include LSP tools initially, so LSP initialization remains parent-only. LSP results are intermediate feedback; repository-native format, lint, type-check, build, and test commands remain authoritative.

## Amp state retirement

Once Amp permissions and Amp subagents are both filtered out, no retained feature consumes Amp permission state.

Migration is narrow and identity-aware:

- stop managing `~/.config/amp/settings.json`;
- unlink it only when it is the repository-owned symlink to the retiring `ai/pi/permissions.json`;
- preserve any real or foreign symlink at that path and report it;
- remove only the `.permissions` key from `~/.pi/agent/amplike.json`;
- delete `amplike.json` only when no keys remain after that removal;
- preserve unknown current or future keys;
- remove tracked `ai/pi/permissions.json` only after its safe-command intent is translated into the new permission baseline.

The current machine's persistent Amp YOLO flag is therefore removed rather than left as unreachable stale state.

## Installer and settings changes

`ai/pi/settings.json` will:

1. add `code-actions/index.ts` to the existing `tmustier/pi-extensions` filter;
2. add pinned queue-steer, web-access, LSP, gotgenes subagents, permission-system, and sandbox package entries;
3. replace the plain `pi-amplike` entry with explicit extension, skill, prompt, and theme filters that omit Amp permissions, Amp subagents, and old web skills;
4. order permission-system before sandbox so its `tool_call` decision runs first;
5. leave the full Superpowers package unfiltered.

`ai/pi/install.sh` will:

1. keep linking immutable authored settings, guidance, and keybindings;
2. migrate the mutable `modes.json` link to regular-file reconciliation;
3. migrate `~/.pi/agent/extensions` from the old managed directory symlink to a real directory;
4. link each tracked authored extension entrypoint individually and prune only stale repository-owned links;
5. install or preserve the five mutable runtime baselines according to the explicit drift/reset policy;
6. install the four global named agent definitions;
7. retire only positively identified Amp permission state;
8. quarantine only the positively identified broken Brave skill;
9. reconcile the pinned package set through `pi update --extensions` as before.

`make ai-check` reports all of these actions without writing.

## Package pin maintenance

The new pins are added to the repository's canonical pin inventory in `config/versions.env`, with tests asserting parity between that inventory and `settings.json`.

`bin/versions list` reports the installed Pi package pins. `bin/versions check` compares npm pins with the current npm versions and the pinned Git refs with their reviewed upstream refs. It reports drift but does not update security-sensitive package pins automatically.

The untagged sandbox commit receives a specific check against upstream default-branch HEAD so a later security or lifecycle fix cannot remain invisible. Pin advancement remains an explicit review followed by settings/config compatibility checks.

## Workflow migration

### Subagent calls

Every old batched call is rewritten:

- one sibling `subagent` call per task;
- `subagent_type: rush|smart|deep|review` instead of `mode`;
- required short `description` for each task;
- `run_in_background: true` for parallel fan-out;
- explicit `get_subagent_result` collection;
- no recursive dispatch instructions;
- best-effort polling language instead of unsupported kill/timeout claims.

Affected surfaces include:

- global subagent guidance in `ai/pi/AGENTS.md`;
- the capability/routing documentation in `ai/README.md`;
- `/second-opinion`;
- `/review-prs`;
- `/fix-pr` deep mode;
- `polish-core` subagent review;
- `improve` platform mechanics;
- tests that currently assert `mode` and batched task wording.

### Unattended improvement

`overnight-improve` and its preflight reference replace `/permissions` instructions with `/permission-system`:

1. open `/permission-system`;
2. temporarily enable YOLO mode;
3. verify the status reports YOLO;
4. verify `/sandbox` is enabled in the parent and that all expected filesystem roots/domains for configured gates are already allowed;
5. run the representative build/test command before leaving the loop unattended;
6. run work in a linked worktree;
7. restore permission-system YOLO mode to off during wrap-up.

Permission-system YOLO suppresses only its own `ask` decisions. It does not suppress sandbox prompts, and explicit permission denies remain active. A missing sandbox path/domain allowance in an unattended parent run blocks that tool; the workflow must report the run as blocked rather than waiting indefinitely or claiming success. The sandbox prompt timeout is set to a bounded reviewed value, and preflight is responsible for avoiding prompts during the unattended phase.

Gotgenes child agents remain permission-enforced but not Bubblewrap-contained. Unattended workflows that dispatch children must account for that documented boundary.

## Failure behavior

- Invalid permission-system project or agent policy fails closed according to the package's documented behavior. Invalid global policy falls back to prompting rather than silently broadening access.
- A gotgenes child missing its permission node emits the package's `child_node_absent` warning and fails smoke verification. The permission package is never excluded from child loading.
- `pi-sandbox` is excluded from children, avoiding process-global reset races. A missing Bubblewrap or ripgrep dependency prevents parent sandbox initialization and blocks rollout verification. Both are present on the current WSL host.
- A missing LSP command produces a diagnostic configuration result and does not trigger automatic installation.
- A failed web provider routes only through explicitly configured fallback conditions; exhausted providers report individual failures.
- A failed mutable-config publication preserves the previous regular file through atomic staging behavior.
- A differing mutable file is preserved during normal installation and reported as drift; it is replaced only through the explicit reset path.
- A package startup failure blocks completion and is not worked around by silently disabling the permission package.

## Testing strategy

Implementation follows test-driven development. Repository tests verify this repository's adapters, ownership, and declared configuration. They do not reimplement upstream Bash parsing, wildcard evaluation, concurrency, or sandbox internals.

### Settings and package selection

Add failing Bats assertions that verify:

- all new package versions/refs match the canonical pin inventory;
- `code-actions/index.ts` is enabled while `files-widget` remains disabled;
- `pi-amplike` retains only the explicitly approved resources;
- Amp permissions, Amp subagents, and old Amp web skills are absent;
- gotgenes subagents and permission-system are present;
- permission-system loads before sandbox;
- Superpowers remains unfiltered.

### Named agents and workflow calls

Add failing assertions that verify:

- all four named agent files exist and declare the expected model, thinking level, prompt mode, and complete tool allowlist;
- agent model/thinking values remain in parity with tracked `modes.json`;
- read-only agents omit edit/write and include an intentional restrictive policy;
- personal workflows contain no old `tasks:` or `mode`-based subagent instructions;
- fan-out instructions require one background call per task and explicit result collection;
- no workflow claims a wall-clock timeout kills an individual gotgenes agent.

These tests verify authored configuration and migration completeness, not gotgenes runtime internals.

### Installer ownership

Add failing installer tests that verify:

- check mode reports every new managed destination without modifying files;
- a former managed extension-directory symlink becomes a real directory;
- authored extension files are linked individually;
- mutable permission, sandbox, subagent, mode, and web configurations are regular files rather than symlinks;
- missing and identical files follow the defined reconciliation behavior;
- differing regular files are preserved and reported during normal installation;
- explicit reset backs up once and atomically publishes the baseline;
- existing unrelated extension files/directories are preserved;
- stale symlinks are pruned only when they resolve into the repository's managed extension tree;
- custom `PI_CODING_AGENT_DIR` and XDG web-config paths are honored;
- authentication and other machine-local Pi state remain untouched.

### Amp and Brave cleanup

Add failing tests that verify:

- only a repository-owned Amp settings symlink is removed;
- real/foreign Amp settings are preserved;
- only `.permissions` is removed from `amplike.json` and unknown keys survive;
- the exact matching Brave skill is moved intact and idempotently;
- a modified/mismatched Brave path is preserved with a warning;
- sibling user skills are never moved.

### Permission and sandbox configuration

Repository tests verify JSON validity, required secure knobs, declared tool actions, explicit child exclusions, and absence of credentials. They do not copy the permission package's matcher into Bats.

Focused verification validates the permission config against the exact pinned package's published JSON Schema. Host smoke tests exercise the actual extension for representative allow, ask, deny, child-forwarding, and YOLO-preserves-deny cases.

Sandbox configuration tests verify that the parent policy names required Pi infrastructure, cache, and registry allowances; omits dangerous broad socket/browser/credential access; and that `subagents.json` excludes the exact pinned sandbox source while retaining permission-system inheritance.

### Worktree guard

Extend the existing pure path-classification tests and add a handler-level harness that registers the extension against a fake `pi.on("tool_call")` API. Verify:

- `lsp_fix write=true` blocks in a primary checkout;
- `lsp_fix write=true` is allowed in a linked worktree;
- `lsp_fix write=false` remains allowed;
- existing `edit`/`write`, symlink, allow-file, and new-file behavior remains unchanged.

### Host smoke verification

After repository tests pass and `make ai` applies the configuration, use the real pinned packages to verify:

1. Pi starts and reports no extension-load errors.
2. The loaded command/tool inventory contains queue steering, web tools, gotgenes subagent tools, permission-system, sandbox, and LSP, while Amp permissions/subagents are absent.
3. Foreground and background `rush` agents run with the expected model and read-only tools.
4. A background result is collected with `get_subagent_result`.
5. A child permission `ask` forwards to the parent.
6. A child explicit deny is enforced and logged without `child_node_absent`.
7. A child direct write into a primary checkout is blocked by the inherited worktree guard.
8. The parent Bash process is Bubblewrap-contained.
9. A child does not load `pi-sandbox`, and child completion does not change the parent's sandbox state.
10. Permission logs and runtime toggles leave Git status clean.
11. The Brave skill is no longer discovered while its sibling skills remain available.
12. `/permission-system show`, `/sandbox`, `/lsp`, and `/subagents:sessions` operate.

### Verification commands

Run, in order:

```bash
bats tests/ai_installers.bats
bats tests/pi_permissions.bats
bats tests/pi_worktree_guard.bats
bats tests/pi_modes.bats
bash bin/validate-ai --verbose
make check
```

Then run `make ai` on the current host and perform the smoke matrix above. Completion requires both repository verification and host runtime evidence.

## Rollout and rollback

Rollout is one reviewed change because package filtering, subagent schema migration, policy replacement, mutable-config migration, documentation, and workflow updates must remain internally consistent.

Before activation:

- preserve any differing mutable runtime files;
- remove only positively identified stale Amp permission state;
- quarantine only the positively identified Brave skill;
- install the non-YOLO permission baseline;
- install the parent sandbox baseline;
- verify child package exclusions before spawning a child.

Rollback disables or removes the newly added package entries and restores the prior retained-package filters if necessary. It does not restore the old whole-directory extension symlink, re-enable Amp permissions concurrently, or delete machine-local logs/configuration. If Amp subagents are temporarily restored, their Amp settings and non-YOLO state must be restored together; a partial restoration is forbidden.

Machine-local package caches, backups, logs, and quarantined skill data may remain but are not loaded once their resources are disabled. The Brave skill can be restored by moving its intact quarantined directory back to its original location.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Prompt fatigue persists | Curated balanced allows, single-press decisions, and session-scoped approval patterns |
| YOLO becomes the permanent default again | Tracked baseline starts false; explicit reset restores it; docs require temporary use and restoration |
| Duplicate permission prompts | Filter out Amp permissions; load permission-system before sandbox; allow normal parent project/Pi paths in sandbox |
| Child bypasses policy | Replace Amp subagents; inherit permission-system and worktree guard; smoke-test ask forwarding and denies |
| Child sandbox resets parent containment | Exclude the exact sandbox package from child extension loading; verify parent state after child shutdown |
| Child lacks OS containment | Explicit boundary, restrictive named-agent tools/policy, inherited worktree guard, and no claim of complete isolation |
| Runtime logs/config dirty Git | Real runtime extension directory plus regular machine-local mutable files |
| Installer destroys keys or grants | Preserve drift by default; explicit backup-and-reset path only |
| Stale managed extension link breaks startup | Manifest-based pruning restricted to repository-owned symlinks |
| Sandbox blocks unattended work | Reviewed parent allowlists, bounded timeout, representative preflight command, blocked-state reporting |
| Sandbox gives false confidence | Document extension-process, child, and in-CWD mutation boundaries; retain worktrees and direct-tool guard |
| LSP fixer bypasses worktree policy | Permission ask plus explicit worktree-guard handling of `lsp_fix write=true` |
| Web extension leaks cookies or remote content | Cookies, hosted fetches, cloning, media, and curator automation disabled by baseline |
| Broken Brave guidance remains discoverable | Narrow identity-checked quarantine that preserves all sibling skills |
| Mode and agent routing drift | Canonical tracked pins plus parity tests; document runtime `/mode` limitation |
| Package security update is missed | Canonical version inventory and explicit npm/Git upstream drift checks |
| Tests accidentally duplicate upstream logic | Test repository adapters/configuration; use schema validation and real-package smoke tests for package behavior |
