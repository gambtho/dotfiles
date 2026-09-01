# Pi Plugin and Security Stack Design

## Status

Approved in conversation on 2026-09-01. This document is the input to an independent `/second-opinion` review before implementation planning.

## Context

The dotfiles repository manages Pi as its sole coding-agent harness. The current configuration already provides GitHub Copilot models, modes and subagents through `pi-amplike`, plan mode, Ralph loops, usage and status UI, clipboard support, custom review workflows, and a direct-tool worktree guard.

Two shortcomings motivate this change:

1. The installed Brave and Jina search skills are unusable without additional credentials in the current environment. Brave reports a missing `BRAVE_API_KEY`; unauthenticated Jina returns HTTP 401.
2. `pi-amplike` permissions inspect only the `bash` tool and produce enough false-positive prompts that YOLO mode is currently left enabled. They do not govern custom tools, path access, or extension tools. The custom worktree guard separately protects only Pi's built-in `edit` and `write` tools.

The change adds three focused workflow capabilities, targeted LSP diagnostics, and a layered permission-plus-sandbox security model.

## Goals

- Make steering and follow-up messages visible and editable during long-running work.
- Provide reliable web search and page extraction with a keyless fallback and conservative defaults.
- Enable retrieval of code snippets from prior assistant messages.
- Add targeted, on-demand LSP diagnostics without adopting an invasive continuous-analysis suite.
- Replace Amp's Bash-only permission gate with deterministic policy covering built-in and custom tools.
- Add OS-level containment around shell commands on Linux and WSL.
- Preserve reproducible repository-managed defaults while keeping mutable runtime state and sensitive logs outside Git.
- Retain the existing worktree workflow and hard block direct file-tool mutations in primary checkouts.
- Keep unattended workflows possible through a YOLO mode that preserves explicit denies.

## Non-goals

- Do not add another all-in-one agent harness, subagent runtime, plan system, footer, usage dashboard, or memory layer.
- Do not adopt `pi-lens`, an MCP bridge, or an interactive PTY extension.
- Do not claim that an in-process permission extension is an isolation boundary.
- Do not claim that the sandbox contains extension factories or extension-internal `pi.exec()` calls.
- Do not attempt to infer every possible filesystem mutation made indirectly by an arbitrary build script.
- Do not expose SSH keys, cloud credentials, browser cookies, Docker sockets, or unrestricted Unix sockets to sandboxed processes by default.

## Selected packages

New package sources are pinned because extension code executes with the user's full authority and because policy/configuration compatibility matters.

| Capability | Package | Pin | Rationale |
|---|---|---|---|
| Visible queued steering | `tmustier/pi-queue-steer` | `v0.2.0` | TUI-only queue editing with strong automated and real-TUI coverage; no model-facing tools |
| Web research | `pi-web-access` | `0.27.0` | Structured search/fetch tools, keyless Exa/DuckDuckGo fallback, local extraction, SSRF controls |
| Code snippet actions | Existing `tmustier/pi-extensions` checkout | existing package, enable `code-actions/index.ts` | Adds `/code` retrieval and insertion without another package checkout |
| Targeted diagnostics | `@narumitw/pi-lsp` | `0.49.6` | Two on-demand tools, no persistent server fleet, explicit Earendil Pi support |
| Permission policy | `@gotgenes/pi-permission-system` | `29.2.0` | Fail-closed Bash parsing, path and external-directory gates, custom-tool coverage, session grants |
| Shell containment | `carderne/pi-sandbox` | commit `53bd1d64d896d4a6bfab3769023201891e76ba72` | Includes the post-0.6.5 subprocess-hang fix; uses Bubblewrap on Linux |

`pi-amplike` remains installed but is converted from unfiltered string form to an object filter. It retains its modes, handoff, side-question, session-query, and subagent resources. Its `permissions.ts` extension and the obsolete Jina web-search/page-visit skills are excluded.

## Architecture

### Layer 1: repository workflow and worktree guard

Repository guidance continues to require inspection in the primary checkout followed by implementation in a linked worktree. `ai/pi/extensions/worktree-guard.ts` remains the authoritative direct-tool enforcement layer.

The guard continues to block built-in `edit` and `write` calls targeting a primary checkout. It is extended to block `lsp_fix` when `write=true` and the requested path belongs to a primary checkout. Preview-only `lsp_fix` calls remain allowed.

This layer cannot classify arbitrary shell commands or extension-internal process execution. Those limits remain explicit rather than being presented as complete mediation.

### Layer 2: deterministic permission decisions

`@gotgenes/pi-permission-system` replaces `pi-amplike` permissions. It decides whether model-facing tool calls are allowed, denied, or require a user decision. It is a policy and attention-routing layer, not process isolation.

The global baseline uses a balanced posture:

- universal fallback: `ask`;
- built-in read/search tools: `allow`;
- built-in `edit` and `write`: `allow`, subject to the worktree guard and path policy;
- known workflow tools (`subagent`, `handoff`, `session_query`, `plan`, Ralph tools, clipboard, and web research): `allow`;
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

### Layer 3: Bubblewrap containment

`pi-sandbox` wraps the built-in Bash implementation and user `!` commands with Bubblewrap on Linux/WSL. The tracked baseline enables it by default.

Filesystem policy:

- allow reads in the active project, selected runtime/toolchain directories, and narrowly selected configuration roots needed by approved CLI tools;
- allow writes in the active project, `/tmp`, and selected build/language caches;
- deny reads and writes for SSH keys, cloud credentials, Pi authentication, private key material, and `.env` variants, subject to the package's documented read-rule limitations;
- do not broadly allow all of `~/.config` or the home directory.

Network policy:

- allow local development binding;
- allow established GitHub, npm, PyPI, Rust, Go, Ruby, and Maven registry domains required by normal development;
- prompt for unlisted domains;
- do not enable unrestricted Unix sockets, browser processes, or unauthenticated SOCKS proxying by default.

The permission policy should normally decide first; the sandbox should be quiet for ordinary in-project work and act as containment or a second prompt for unexpected external access.

The sandbox cannot distinguish a primary checkout from a linked worktree. Allowing the current working directory therefore does not replace the worktree guard. It also cannot contain code executed directly by an extension in Pi's Node process.

### Explicit bypass boundaries

The following are intentionally documented residuals:

- `code-actions` `/code run` executes only after an explicit user confirmation, but calls `pi.exec()` from an extension command. It does not pass through model tool-call permissions or Bubblewrap. The recommended use is `/code ... insert`, followed by a normal reviewed execution path.
- Extension factories, event handlers, and package code run with Pi's full user permissions.
- A permitted build/test/format command can mutate files inside the active working directory. Repository guidance and linked-worktree use remain necessary.
- A subprocess may access credentials from an explicitly allowed configuration directory even when the command line itself does not name that credential file. Allow only configuration roots required by approved tools.
- Permission review logs redact values only when their input key is recognized as sensitive. Secrets embedded in Bash command strings are logged unredacted.

## Mutable configuration boundary

### Problem

The installer currently symlinks the entire tracked `ai/pi/extensions` directory to `~/.pi/agent/extensions`.

The permission system stores its global `config.json` and owner-only logs below `~/.pi/agent/extensions/pi-permission-system/`. Its `/permission-system` command mutates that configuration. If the whole directory remains linked, runtime toggles and sensitive logs are written into the Git checkout.

`pi-sandbox` and `pi-web-access` also expose runtime configuration mechanisms that may update their global files. Linking those files directly to tracked baselines risks dirtying the repository.

### Decision

The installer will replace the whole-directory extension symlink with a real machine-local `~/.pi/agent/extensions/` directory and individual links for authored extension entrypoints.

Tracked baseline configuration will live under a non-autodiscovered repository directory, for example:

```text
ai/pi/config/
  permission-system.json
  sandbox.json
  web-search.json
```

`make ai` will atomically publish those baselines as ordinary machine-local files:

```text
~/.pi/agent/extensions/pi-permission-system/config.json
~/.pi/agent/sandbox.json
~/.pi/web-search.json
```

They are deliberately not symlinks. Runtime commands may mutate them without touching Git. Running `make ai` restores the reviewed tracked baseline; differing machine-local files are backed up according to the repository's existing reconciliation conventions before replacement. This reset behavior is documented.

Permission-system logs remain machine-local beneath its runtime configuration directory. They are never copied into the repository.

Existing third-party or machine-managed files in a real `~/.pi/agent/extensions` directory are preserved. Migrating the old managed symlink removes only the symlink itself before creating the directory and its individual managed links.

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
- curator shortcut moved away from `Ctrl+Shift+S`, which belongs to `pi-amplike` modes.

After installation, `pi-amplike`'s Jina `web-search` and `visit-webpage` skills are no longer loaded, preventing duplicate guidance from routing the agent to broken scripts.

## LSP policy

`@narumitw/pi-lsp` uses its built-in server catalog and starts matching servers only when called. It does not download servers.

The current machine already provides Ruff, rust-analyzer, gopls, and RuboCop. Missing language servers are reported rather than installed automatically.

`lsp_diagnostics` is available by default. `lsp_fix` remains available but always goes through the permission system; `write=false` is the expected default. A primary-checkout `write=true` request is blocked by the worktree guard even if approved at the permission layer.

LSP results are intermediate feedback. Repository-native format, lint, type-check, build, and test commands remain authoritative.

## Installer and settings changes

`ai/pi/settings.json` will:

1. add `code-actions/index.ts` to the existing `tmustier/pi-extensions` filter;
2. add pinned queue-steer, web-access, LSP, permission-system, and sandbox package entries;
3. replace the plain `pi-amplike` entry with explicit extension and skill filters that omit Amp permissions and its web skills;
4. order the new entries so web and LSP tools are registered before the permission system, and the permission system's `tool_call` decision handler runs before the sandbox's secondary checks;
5. leave the full Superpowers package unfiltered.

`ai/pi/install.sh` will:

1. keep linking immutable authored settings, guidance, keybindings, and modes;
2. migrate `~/.pi/agent/extensions` from the old managed directory symlink to a real directory;
3. link each tracked authored extension entrypoint individually;
4. publish the three mutable baseline configurations as machine-local regular files;
5. stop linking `ai/pi/permissions.json` into Amp configuration;
6. reconcile the pinned package set through `pi update --extensions` as before.

The obsolete `ai/pi/permissions.json` is removed after its relevant safe-command intent has been translated into the new policy.

## Workflow migration

`overnight-improve` and its preflight reference will replace `/permissions` instructions with `/permission-system`:

1. open `/permission-system`;
2. temporarily enable YOLO mode;
3. verify the status reports YOLO;
4. run unattended work in a linked worktree with sandboxing still enabled;
5. restore YOLO mode to off during wrap-up.

The documentation will emphasize that YOLO suppresses `ask` prompts but does not override explicit denies or disable Bubblewrap.

`ai/README.md` will update its capability matrix and security sections to describe:

- filtered `pi-amplike` ownership;
- permission-system policy ownership;
- sandbox containment;
- the worktree guard's narrower but hard direct-tool guarantee;
- mutable configuration installation and reset behavior;
- web and LSP package decisions;
- known bypass boundaries.

## Failure behavior

- Invalid permission-system project or agent policy fails closed according to the package's documented behavior. Invalid global policy defaults to prompting rather than silently broadening access.
- A missing Bubblewrap or ripgrep dependency prevents sandbox initialization and must be surfaced as an installation failure during smoke verification. Both are present on the current WSL host.
- A missing LSP command produces a diagnostic configuration result and does not trigger automatic installation.
- A failed web provider routes only through the explicitly configured fallback conditions; exhausted providers report their individual failures.
- A failed baseline publication must preserve the previous machine-local file through atomic staging/backup behavior.
- A package startup failure blocks completion and is not worked around by silently disabling the security package.

## Testing strategy

Implementation follows test-driven development.

### Settings and package selection

Add failing Bats assertions that verify:

- all five package additions are pinned as designed;
- `code-actions/index.ts` is enabled while `files-widget` remains disabled;
- `pi-amplike` retains required extensions and only the session-query skill;
- Amp permissions and old web skills are absent;
- Superpowers remains unfiltered.

### Installer ownership

Add failing installer tests that verify:

- check mode reports every new managed destination without modifying files;
- a former managed extension-directory symlink becomes a real directory;
- authored extension files are linked individually;
- mutable permission, sandbox, and web configurations are regular files rather than symlinks;
- existing unrelated extension files are preserved;
- differing mutable configuration is backed up before baseline restoration;
- authentication and other machine-local Pi state remain untouched.

### Permission policy

Replace Amp-specific tests with policy tests that verify:

- JSON validity and required secure runtime knobs;
- universal fallback is `ask` and YOLO starts off;
- known workflow/read-only tools are allowed;
- unknown tools and `lsp_fix` ask;
- sensitive path patterns deny and `.env.example` remains allowed;
- safe inspection and validation commands are allowed;
- mutating Git/GitHub, package installation, shell wrappers, and unknown commands do not auto-allow;
- explicit catastrophic patterns deny;
- Amp permissions are no longer installed or referenced.

Where practical, validate the policy against the permission package's published schema during focused verification.

### Worktree guard

Add a failing test showing that `lsp_fix` with `write=true` is blocked for a primary checkout and allowed for a linked worktree. Add a preview-mode test proving `write=false` is not blocked.

### Documentation and workflow checks

Update or add assertions that prevent reintroducing Amp `/permissions` instructions and require the new layered security decisions to remain documented.

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

Then run `make ai` on the current host and smoke-check:

```text
pi --help
/permission-system show
/sandbox
/lsp
```

Also verify that the loaded command/tool inventory contains the new capabilities, omits Amp permissions, and that neither Git status nor tracked files change when toggling permission settings or generating permission logs.

## Rollout and rollback

Rollout is one reviewed change because package filtering, policy replacement, mutable-config migration, documentation, and workflow updates must remain internally consistent.

Before activation, back up existing runtime configuration through installer reconciliation. Applying `make ai` resets the permission system to non-YOLO balanced mode and enables the sandbox.

If startup or ordinary development is blocked:

1. use Pi's explicit one-session sandbox-disable flag only for diagnosis;
2. inspect the permission and sandbox status/config paths;
3. restore the previous branch/configuration and rerun `make ai` rather than leaving a partially filtered package set;
4. do not re-enable the removed Amp permission extension concurrently, because duplicate Bash gates create ambiguous prompts.

Rollback restores the previous `settings.json`, whole-directory extension link, Amp permissions link, and workflow documentation. Machine-local logs and package caches may remain but are not loaded once their package is removed.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Prompt fatigue persists | Curated balanced allows, single-press decisions, and session-scoped approval patterns |
| YOLO becomes the permanent default again | Tracked baseline starts false; `make ai` restores it; docs require temporary use and restoration |
| Duplicate permission prompts | Filter out `pi-amplike` permissions; configure sandbox to be quiet for normal in-project work |
| Runtime logs/config dirty Git | Real runtime extension directory plus copied mutable configs |
| Sandbox blocks normal toolchains | Start with reviewed cache/registry allowances; use session grants; test representative commands |
| Sandbox gives false confidence | Document extension-process and in-CWD mutation boundaries; retain worktrees and direct-tool guard |
| LSP fixer bypasses worktree policy | Permission ask plus explicit worktree-guard handling of `lsp_fix write=true` |
| Web extension leaks cookies or remote content | Cookies, hosted fetches, cloning, media, and curator automation disabled by baseline |
| Package updates break policy contracts | Pin all newly added package versions/commits and update deliberately |
| Installer overwrites useful runtime grants | Back up differing runtime files and document that `make ai` restores reviewed defaults |
