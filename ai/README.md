# Pi configuration

This directory contains the repository-managed configuration for Pi, the sole coding-agent harness installed by these dotfiles.

## Provider and models

Pi connects directly to the GitHub Copilot subscription; no model proxy is required.

- Authenticate interactively with `/login` and choose **GitHub Copilot**.
- Select an enabled model with `/model`; Ctrl+S saves the highlighted model as the startup default.
- Keep OAuth credentials in `~/.pi/agent/auth.json`. Never commit or link that file.

### Astra override retirement

The tested Pi 1.1.0 catalog provides `github-copilot/gpt-6-astra` natively through `openai-responses` with a 1M context window. The old authored transport override is retired. On the first successful migration, the installer backs up runtime `models.json`, removes only the Copilot `gpt-6-astra` entry, and preserves other models, providers, and root metadata. It removes the file only if the result is empty. An owner-only `dotfiles-migrations.json` receipt prevents later deliberate overrides from being removed again. Invalid JSON, foreign links, and concurrent changes fail without claiming completion.

This migration does not read or rewrite the generated `models-store.json` catalog, credentials, or session history. Restore the matching receipt as well as model configuration during recovery; otherwise a retried migration could retire the restored override again.

## Capability stack

Generic runtime behavior comes from floating npm and Git declarations, reconciled by Pi's native package CLI. Normal installation may advance packages, including unreleased Git changes according to Pi's tracking/ref behavior. Resource filters remain repository-owned. The local `my` package remains responsible for personal review and implementation workflows.

| Capability | Implementation | Notes |
|---|---|---|
| Queue and steer messages during a response | `pi-queue-steer` | Adds streaming-time queue/steer behavior without a model-facing tool |
| Keyless search and local content extraction | `pi-web-access` | Routes search through Exa then DuckDuckGo and fetches through the local HTTP provider |
| Code-block actions and `/code run` | `code-actions` from `tmustier/pi-extensions` | Enables reviewed code actions; see the containment exception below |
| Diagnostics and preview/apply fixes | `@narumitw/pi-lsp` | Provides `lsp_diagnostics` and `lsp_fix`; mutating fixes remain worktree-guarded |
| Named child agents | `@gotgenes/pi-subagents` | One `subagent` call starts one agent; background calls return IDs for later polling |
| Allow/ask/deny policy | `@gotgenes/pi-permission-system` | Gates model-facing tools, paths, shell commands, and forwarded child requests |
| Main-session modes, handoff, BTW, and session query | filtered `pi-amplike` | Amp permissions, subagents, prompts, themes, and legacy web skills are not loaded |
| Structured development methods | `obra/superpowers` | Full package, including the session bootstrap and all 15 skills in the tested candidate |
| Security and performance checklists | filtered `addyosmani/agent-skills` | Only `security-and-hardening` and `performance-optimization`; its `using-agent-skills` router and commands are not loaded because they conflict with Superpowers routing |
| Long-running iterations | `pi-ralph-wiggum` | Used by the custom `overnight-improve` workflow |
| Model/context/cost UI | `pi-powerline-footer`, `usage-extension`, `session-recap` | Existing display and recap behavior |
| Worktree create/switch/remove UI | `@narumitw/pi-worktree` | Parent-only; uses normal Git worktrees and preserves the active conversation on switch |
| File selection and quotes | `@narumitw/pi-file-context` | Parent-only; F8 opens the file-context picker without taking native copy shortcuts |
| Click local files to edit | `gambtho/pi-file-editor@v0.1.0` | Parent-only; normal-click a local file link to open the configured external editor, then quit to return to Pi |
| Native tool orchestration | Pi Codemode | Additive `+codemode`, mode `on`; ordinary tools remain available |
| Primary-checkout write enforcement | `ai/pi/extensions/worktree-guard.ts` | Covers built-in writes and mutating `lsp_fix` with rooted path resolution |

`pi-file-editor` is pinned to the reviewed local-only release, verified with Pi 1.2.0. It has no preview, search, or SSH support; `/edit-file` is the keyboard fallback. It uses the machine-local `externalEditor` setting, then `$VISUAL` / `$EDITOR`. Only existing regular files are accepted, but the launched editor retains normal user authority rather than agent-tool/worktree containment. Line positioning requires metadata inside the link (`#L42` or `#L42-49`). File Context remains available for browsing and quoting.

Interactive browser automation remains opt-in rather than a default dependency.

## Named agents and routing

`ai/pi/config/modes.json` is the first-install/reset baseline for retained main-session modes. Gotgenes child routing is defined by the four files under `ai/pi/agents/`:

| `subagent_type` | Model | Thinking | Use |
|---|---|---|---|
| `rush` | GitHub Copilot GPT-6 Luna | low | Bounded searches, inventories, and mechanical checks |
| `smart` | GitHub Copilot GPT-6.1 Sol | medium | Normal review, investigation, and implementation subtasks; startup default |
| `deep` | GitHub Copilot GPT-6 Astra | high | Architecture, security, diagnosis, and broad analysis |
| `review` | GitHub Copilot Claude Opus 5.5 | high | Independent cross-family second opinions |

Each `subagent` invocation supplies one self-contained `prompt`, a 3–5 word `description`, and a `subagent_type`. Parallel work uses sibling calls with `run_in_background: true`; record each returned ID and poll with `get_subagent_result({ agent_id, wait: false })`. An explicit `model` is reserved for a user request or deliberate cross-family review.

`rush`, `deep`, and `review` omit write/edit tools and allow routine inspection and verification silently. Their explicit rules deny selected repository and remote mutations; other recognized risky operations follow the composed permission policy instead of an absolute read-only guarantee. `smart` otherwise inherits the permissive global attention policy. Every named child hard-denies Bash commands containing unresolved `$` expansion so a curated reader cannot hide a sensitive operand from path extraction. Children cannot recursively dispatch more children. Worktree and file-context UI packages are excluded from children; permission-system, worktree-guard, and the selected skills remain inherited. Full Superpowers is the process router; the filtered agent-skills router and commands are not loaded. The local `my` selection remains five prompts, ten skills, and no extensions.

### Context and turn budgets

The four exact chat model IDs are `github-copilot/gpt-6-luna`, `github-copilot/gpt-6.1-sol`, `github-copilot/gpt-6-astra`, and `github-copilot/claude-opus-5.5`. Each has a `650000` reserve / `60000` recent-token compaction override. Global fallback is `16384` / `20000`, so other models, including 200K/400K-context choices, do not inherit the large reserve. Selected SDK catalog and compaction behavior were checked without paid requests; catalog checks do not prove provider availability or response quality.

The fresh subagent baseline has a hard `defaultMaxTurns: 50` ceiling and `wrapUpTurns: 5`, warning five turns **before** that ceiling. This is not the old `graceTurns: 5` behavior, which allowed five turns **after** soft limit 50 (hard limit 55). Current subagents 23.4 ignores the deprecated `graceTurns`; its default wrap-up is two turns when `wrapUpTurns` is omitted. Normal `make ai` privately backs up and removes the ignored top-level `graceTurns` key to stop upstream warnings; `make ai-check` reports pending cleanup without writing. All other subagent settings are preserved: cleanup does not set `wrapUpTurns` or change the turn ceiling, and selective preference refresh does **not** migrate these turn knobs. Choose `wrapUpTurns` deliberately before starting a fresh session; do not assume an existing file acquired the new baseline.

Superpowers planning is a development process, not a read-only UI/security mode. The entire Shitty clipboard/memory/planner package and caffeinate are no longer selected. Old `--plan` and planning shortcuts are not part of this stack. User plans are untouched, not imported into a replacement planner. Package caches follow native Pi reconciliation. Start a fresh session after rollout rather than resuming legacy planning state.

## Permission and containment model

`ai/pi/config/permission-system.json` is a permissive attention and tripwire layer, not a sandbox:

- routine tools, unmatched parent Bash commands, local Git subcommands, normal fetch/push, explicitly fast-forward-only pulls, read-only GitHub API calls, PR/issue creation and editing, `lsp_fix`, ordinary `curl` GETs/downloads, and loopback HTTP probes are allowed;
- unknown extension tools and MCP targets, non-fast-forward pulls, selected destructive Git operations, PR merges and issue closure, recognizable remote shell/network commands, and recognizable deletion ask;
- bounded lexical `curl` tripwires ask for `--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, or separate-token `-d`; `--form`/`-F`; `--upload-file`/`-T`; explicit `POST`, `PUT`, `PATCH`, or `DELETE` through `--request`/`-X`; and recognized authorization, user, cookie, certificate, key, or netrc arguments; uppercase `Authorization:` and lowercase `authorization:` literals are covered, while arbitrary mixed-case header spellings, aliases, interpreters, generated arguments, attached short-option values, and semantically equivalent requests are outside that coverage;
- policy denies recognized credential and browser-profile path access, persistent Git config writes, Git options that execute subprocesses, catastrophic deletion, force operations, subprocess-capable search flags, and privilege escalation; worktree guard separately denies direct model-facing write, edit, and mutating LSP operations in primary checkouts;
- common reader/output commands containing unresolved `$` expansion and direct environment-dump commands ask, while named children hard-deny all unresolved shell-variable indirection; use `NAME=value command` rather than the opaque `env NAME=value command` wrapper so ordinary scoped commands remain inspectable and silent;
- optional metadata inspection allows only the literal `printenv PI_PROVIDER PI_MODEL PI_REASONING_LEVEL` and `printenv XDG_CONFIG_HOME PI_CODING_AGENT_DIR` commands, plus their `/usr/bin/printenv` spellings; it is not a startup requirement or permission to add secret operands/dump the environment;
- the parent allows twenty literal Git HEAD queries: bare and `/usr/bin/git ls-remote https://github.com/OWNER/REPO.git HEAD` for the ten repositories explicitly listed in the policy. Other Git remote queries still ask. Read-oriented children retain their Git-query deny and use existing `gh api` read permissions: query `.default_branch`, then the verified literal branch ref. API mutation flags still ask; selected destructive/DELETE operations and child variable indirection remain denied;
- only the canonical `~/.dotfiles/config/versions.env` dependency inventory has a narrow read exception, after operator verification; writes stay denied and worktree copies remain denied unless explicitly authorized for that exact temporary file;
- external-directory read and write catch-alls allow ambiguous external paths to avoid false prompts; explicit protected-path denies remain later tripwires, not containment;
- `/permission-system` can enable temporary YOLO, which converts asks to allows but preserves explicit denies.

### Important containment boundaries

Parent and child Bash processes are not OS-contained. They retain the invoking user's ambient filesystem, environment, network, and subprocess authority. Path and command rules reduce accidental access and route attention; they do not contain hostile or interpreter-generated behavior.

Gotgenes children inherit permission-system and worktree-guard, with restrictive agent policy and complete tool allowlists providing additional controls. Named children deny unresolved variable indirection, while common parent reader commands ask; neither parent nor child Bash is a safe execution boundary for untrusted commands. Path rules do not recursively constrain operations performed inside an allowed shell command or extension:

- Codemode scripts run in QuickJS without direct Node/filesystem/network APIs. Nested `tools.*` calls pass through actual tool-call permissions and the worktree guard, including forwarded child decisions. This does not mediate every capability: `models.classify()` and `models.generateImages()` use session credential/model authority separately, may incur cost, and are not nested tool calls. Extension-internal model/network APIs likewise retain ambient authority.
- `/code run` executes through extension-internal `pi.exec()`.
- LSP server subprocesses are extension-internal. Permission-system still gates the model-facing LSP call, and worktree-guard blocks a mutating fix targeting a primary checkout.
- `pi-web-access network calls` are extension-internal. The tracked config disables cookie use, remote hosted fetch providers, clone/media/image features, environment proxy trust, and SSRF range exceptions.

Do not put secrets in the agent environment, run Pi against untrusted code, enable YOLO for interactive work, or describe these controls as a security boundary. Keep extension selection and installed compatibility under review.

## Worktree policy

Use the `using-git-worktrees` skill to create or reuse linked worktrees before repository writes. The custom guard blocks direct `write`, `edit`, and mutating `lsp_fix` calls whose effective target belongs to a primary checkout. It resolves `lsp_fix.root + lsp_fix.path` using pi-lsp semantics, so changing `root` cannot bypass the guard.

The guard cannot classify arbitrary extension-internal execution. Do not bypass it through shell redirection, generators, `/code run`, or another mutating extension. Repositories listed in `~/.pi/worktree-guard-allow` and the explicit `PI_WORKTREE_GUARD=off` switch are deliberate operator exceptions.

## Managed layout and mutable ownership

```text
ai/
  README.md
  pi/
    AGENTS.md
    settings.json
    keybindings.json
    agents/{rush,smart,deep,review}.md
    config/
      modes.json
      permission-system.json
      subagents.json
      file-context.json
      web-search.json
    extensions/
      herdr-agent-state.ts
      herdr-prompt-state.ts
      worktree-guard.ts
    install.sh
    migrate-security-stack.sh
    migrate-runtime-config.sh
  marketplace/plugins/my/
    package.json
    prompts/
    skills/
```

Immutable guidance, keybindings, named agents, and the three authored extensions are individual links. The installer owns these **six mutable runtime files** as regular machine-local files:

| Tracked baseline | Runtime destination | Routine install behavior |
|---|---|---|
| `ai/pi/settings.json` | `~/.pi/agent/settings.json` | merges only `.packages`; preserves every other runtime key |
| `ai/pi/config/modes.json` | `~/.pi/agent/modes.json` | installs when missing; preserves drift |
| `ai/pi/config/permission-system.json` | `~/.pi/agent/extensions/pi-permission-system/config.json` | repository-owned permission map is republished on `make ai`; valid runtime `yoloMode`, `debugLog`, and `permissionReviewLog` values are preserved; publication refuses active YOLO |
| `ai/pi/config/subagents.json` | `~/.pi/agent/subagents.json` | installs when missing; removes ignored top-level `graceTurns`; preserves turn/concurrency preferences; normalizes exact owned child exclusions |
| `ai/pi/config/file-context.json` | `~/.pi/agent/pi-file-context.json` | installs when missing; preserves custom shortcuts; explicit refresh changes only the known old Ctrl+Shift+X to F8 |
| `ai/pi/config/web-search.json` | `$PI_CODING_AGENT_DIR/web-search.json`, `$XDG_CONFIG_HOME/pi/web-search.json`, or `~/.pi/web-search.json` | installs when missing; preserves drift |

Use runtime commands such as `/permission-system` and `/subagents:settings` for intentional machine-local changes. Runtime permission-map or stable-field edits are temporary and are replaced by the next `make ai`; the three `/permission-system` runtime controls survive publication. To back up differing files and reset the other runtime-owned mutable baselines explicitly:

```bash
PI_AI_RESET_MUTABLE_CONFIG=1 make ai
```

`PI_AI_RESET_MUTABLE_CONFIG=1` no longer replaces permission-system `yoloMode`, `debugLog`, or `permissionReviewLog`. During normal authoritative reconciliation, the same active-YOLO refusal applies with or without reset. Authentication, sessions, trust decisions, upstream-generated model catalogs, package caches, permission logs, grants, and runtime credentials remain machine-local and untracked. Runtime `models.json` is user-owned except for the one-time Astra retirement described above.

For selective preference refresh rather than a full reset, stop Pi and use `PI_AI_REFRESH_PREFERENCES=1` with `make ai`. It advances only known old Copilot role/startup IDs, moves the known old large global compaction values into missing selected-model overrides with safe global fallbacks, adds Codemode without replacing other tools/settings, sets its mode to `on`, and changes only the old file-context copy-key shortcut to F8. Other preferences, custom role choices, existing model overrides, and unrelated config fields survive. It does not translate `graceTurns` into `wrapUpTurns` or change `wrapUpTurns`, concurrency, or custom turn budgets; removal of the ignored `graceTurns` key is part of normal reconciliation, independent of this flag. F8 leaves native message copy on Ctrl+Shift+X and editor copy on Ctrl+C; no replacement clipboard extension is loaded.

When retiring a legacy `pi-sandbox` installation, the installer backs up and resets the permission policy to the tracked non-YOLO, unmatched-Bash-allows baseline before removing the package declaration. It removes the retired `pi-sandbox` child exclusion after native package reconciliation and installed-runtime validation. This transitional retirement path is the only exception to normal authoritative publication: it safely resets active YOLO and publishes the tracked baseline before the package schema is available so a permission layer remains present while the old containment package is retired. Normal reconciliation refuses active YOLO and validates the candidate against the exact installed schema before publication. A previous `~/.pi/agent/sandbox.json` and cached package checkout are preserved as inactive machine-local state; neither is loaded once the package source is absent from `settings.json`. They may be deleted manually after restarting Pi if rollback is not needed.

## Installation and rollout

Pi permission validation requires Python 3 with the `jsonschema` module. The composed Linux/WSL APT manifests install `python3-jsonschema`; mise-managed Python installations, including the macOS path, receive `jsonschema` through `languages/python/default-python-packages.symlink`. The manifests also install `ripgrep` for Pi search workflows. Pi does not install or require an OS sandbox runtime.

Preview without mutation:

```bash
make ai-check
```

Stop all Pi sessions before changing links/resources, including ordinary reconciliation. Apply from the canonical checkout:

```bash
make ai
```

The installer refuses a production-agent-dir apply—including one reached through a resolved path alias—when invoked from a different linked implementation worktree while the canonical checkout exists. Before integration, use an **isolated pre-integration smoke** with an absolute temporary `PI_CODING_AGENT_DIR`, separate HOME and XDG paths, and `DOTFILES` pointed at the reviewed checkout so the local `my` package remains available. Package installation and the installed-runtime gate pipeline do not require Copilot authentication. An agent command must not read or copy production `auth.json`; defer interactive model-facing smoke to canonical rollout unless the operator provisions isolated credentials outside the agent command. Canonical integration and rollout need separate authorization; do not apply from an implementation worktree or a running production Pi session.

### Native package convergence

`make ai` (or `bash ai/pi/install.sh`) validates arguments, the canonical source and owned destinations, installs or reuses managed Pi, performs positively identified legacy cleanup, and reconciles declarations. It then runs exactly one native `pi update --extensions --no-approve` with the selected agent directory from a private empty cwd. Project packages remain unapproved. The selected installed permission schema and evaluator must pass before authoritative policy and authored resources are published. The legacy sandbox reset remains the narrow pre-schema exception described above.

Packages may advance during ordinary installation. Pi owns npm installation, Git tracking/ref behavior, dependency locks and cache reconciliation; cached files may be replaced. There is no repository package-health manager, exact tested-graph promotion, custom default-branch tracking or automatic package recovery. Missing or incompatible permission artifacts fail nonzero with native `pi install npm:@gotgenes/pi-permission-system` repair advice. Never weaken a schema gate to make a new package compatible.

An existing managed Pi host is reused; host self-update stays operator-owned through `pi update`. First installation uses Pi's managed installer. The opt-in Paseo application has a separate pinned runtime, lockfile and service lifecycle, and uses this native Pi host rather than bundling another Pi version. It is never a dependency of ordinary AI reconciliation.

For standalone package updates, stop Pi sessions and use the supported native interface:

```bash
pi update --extensions --no-approve
```

This updates extensions, not Pi itself. Stop-session guidance is an operator responsibility, not automatic process detection. `--check` reports convergence without running package commands, downloading, generating settings locks or writing configuration. Normal apply and native package updates are **not atomic**: a failure can leave partial package/configuration changes. Per-file private configuration backups remain; they are not package rollback orchestration.

Before starting a fresh session, inspect declarations, preserved custom settings, Astra retirement/receipt, deliberately chosen turn knobs, model/compaction/Codemode preferences and F8. Selective refresh does not guarantee every existing preference matches a fresh baseline. Repeat installed schema/evaluator and relevant runtime verification after an update; isolated evidence does not guarantee an identical production package graph or provider availability.

Permission publication uses best-effort compare-before-publish: it checks the runtime file identity before backup and again after backup immediately before the atomic rename. Because the permission-system UI writer shares no lock with the installer, an unavoidable race remains between the final check and rename; the extra check narrows but cannot eliminate it.

The migration converts the old whole-extension link to a real directory, preserves unrelated extension entries, and publishes only the three authored links. It removes only exact managed Amp settings links and only the `.permissions` key from valid Amp state. The exact legacy Brave `brave-search` directory is moved intact below `disabled-skills`; sibling skills, mismatches, and collisions are preserved.

The opt-in [Paseo](pi/paseo/README.md) has a separate installer and operations runbook. Select a machine explicitly with `DOTFILES_PASEO_ENABLED=1 make ai-paseo`; there is no enabling default or hostname/fingerprint registry. Existing private-domain proxy identities remain unchanged.

## Unattended operation

Before `overnight-improve`:

1. Work in a clean linked worktree.
2. Open `/permission-system`, enable YOLO temporarily, and verify status.
3. Run a representative build/test gate and resolve every permission denial before leaving the workflow unattended.
4. Treat any permission denial or prompt timeout as blocked.
5. Disable permission-system YOLO and verify it is off during wrap-up.

YOLO never bypasses explicit denies. Parent and child commands are not OS-contained; direct write/edit and mutating LSP calls remain worktree-guarded, but approved Bash commands can mutate a primary checkout. Use unattended mode only for reviewed code and commands.

## Validation

Repository structure/check-mode checks do not fetch extension packages:

```bash
make validate
make ai-check
```

`make check` runs shell syntax, ShellCheck/shfmt, all Bats suites, Python tests, and AI validation. Installer/migration fixtures require the selected Pi 1.1+ public SDK (and its bundled Jiti) through `PI_TEST_HOST_ROOT` or an available `pi` executable; they do not download one automatically. Full checks also need a current Neovim for the existing `vim.system()`-based tree-sitter guard tests. Keep Git's global config fixture-owned under the isolated HOME, not an unwritable `/dev/null` override. Use an independent HOME/XDG/cache environment and remove shared candidate `PI_CODING_AGENT_DIR`, `DOTFILES`, and candidate `PI_TEST_*` selections before Bats/full checks. Fixtures must own their writable SDK/package roots; the original host SDK is a read-only prerequisite, not a fixture destination.

`make pi-runtime-test` is separate from `make check`. It requires the four explicitly selected `PI_TEST_HOST_ROOT`, `PI_TEST_PERMISSION_ROOT`, `PI_TEST_SUBAGENTS_ROOT`, and `PI_TEST_LSP_ROOT` roots. CI provisions current candidates, records their identities, runs `make check`, the installed schema/evaluator, and the native gate. The gate includes stock CLI missing npm/Git convergence and one bounded public-SDK resource-filter/local-my/retired-source proof with isolated transport and allowlisted environments; it does not modify the selected SDK or shared package graph.

The tested Pi 1.1.0 graph exercises real Codemode nested tool calls, all four named child sessions, permission forwarding, inherited worktree enforcement, and current-layout fail-closed behavior. Optional runtime probes use the public interactive frontend and actual upstream F8 picker/worktree commands with deterministic provider, terminal-transport and user-dialog boundaries. They verify file quote delivery, active branch entry/history preservation, cwd/service rebinding, primary-write denial and linked/switched relative writes, current/main exclusion, dirty-removal refusal before confirmation, and clean removal only after Yes (No preserves it; branch survives). This is native SDK/extension behavior, not paid model, human TTY or OS clipboard certification. macOS/Windows live behavior remains untested. Caffeinate 0.49.11 failed actual WSL default inhibition (systemd denied; ScreenSaver D-Bus service absent) and was removed by operator decision; that is not a supported-platform pass or a backend adaptation.

Use configured `lsp_diagnostics` for authored TypeScript when available; report missing server commands/configuration and install or change them only with operator approval. Standalone strict types and repository checks remain authoritative, not a substitute for unrun LSP diagnostics.

After isolated or production package installation, validate the tracked policy candidate against the selected installed permission schema and evaluator. This command does not validate whichever config is currently active in a running Pi session. Select isolated smoke roots explicitly, for example:

```bash
SMOKE_AGENT_DIR=/absolute/path/to/smoke-home/.pi/agent
SMOKE_PI_PACKAGE_ROOT=/absolute/path/to/selected/pi-coding-agent
libexec/validate-pi-security-runtime \
  --package-root "$SMOKE_AGENT_DIR/npm/node_modules/@gotgenes/pi-permission-system" \
  --pi-package-root "$SMOKE_PI_PACKAGE_ROOT"
```

For the normal installed roots, putting the intended `pi` first on `PATH` and setting `PI_CODING_AGENT_DIR` selects the same two dependencies implicitly.

## Configuration backups

Stop Pi before restoring configuration. Preserve failure output and the private per-file backups printed by the installer. Restore only the matching owned configuration and, for Astra retirement, the matching migration receipt. Keep the real extensions directory and unrelated user files intact. Repair packages separately using Pi's supported install commands, then validate the installed policy/schema/evaluator and relevant runtime behavior before starting a fresh session.

Permission and migration publication use compare-before-publish guards and per-file atomic replacement, not a shared transaction/lock with runtime writers. Restore order matters, particularly the Astra receipt; stop on partial failures rather than treating backups as automatic rollback.

## Historical security-stack rollback

This older procedure is for reverting the original Amp-to-gotgenes rollout, not recovering a current floating-extension update. For a permission-policy-only rollback, stop Pi and restore the exact permission-config backup path printed by the publishing installer (a sibling of `~/.pi/agent/extensions/pi-permission-system/config.json` named `config.json.backup...`). Confirm the restored config has `yoloMode: false`, preserve the permission directory's `0700` mode and config file's `0644` mode, then restart Pi. Revert or amend the tracked policy before the next `make ai`, or authoritative reconciliation will republish it. If publication reported no backup, the installed policy was already identical or no prior runtime policy existed.

The broader original security-stack rollback is coupled and non-YOLO. Choose the last commit before that rollout as `PRE_ROLLOUT`, revert the rollout commits, and **do not run the reverted old installer**, because it would recreate the whole-directory extension link.

1. Extract the reverted `ai/pi/permissions.json` and copy it to `${XDG_CONFIG_HOME:-$HOME/.config}/amp/settings.json` as a regular file.
2. Merge `.packages` from the reverted `ai/pi/settings.json` into the current regular `~/.pi/agent/settings.json`, preserving all other settings.
3. Update `~/.pi/agent/amplike.json` so the resulting state is explicitly `permissions.mode: enabled`, never YOLO.
4. Run `pi update --extensions` with the intended agent directory.
5. Preserve the real extensions directory, unrelated extensions, machine-local configuration, grants, and logs.

A concrete staging sequence, after reverting the implementation commits, is:

```bash
set -euo pipefail

PRE_ROLLOUT=<last-commit-before-this-rollout>
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
AMP_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/amp/settings.json"
mkdir -p "$(dirname "$AMP_SETTINGS")"
[[ ! -L "$AMP_SETTINGS" && ( ! -e "$AMP_SETTINGS" || -f "$AMP_SETTINGS" ) ]] || {
  echo "refusing non-file Amp settings destination" >&2
  exit 1
}
[[ -f "$AGENT_DIR/settings.json" && ! -L "$AGENT_DIR/settings.json" ]] || exit 1
[[ ! -e "$AGENT_DIR/amplike.json" || ( -f "$AGENT_DIR/amplike.json" && ! -L "$AGENT_DIR/amplike.json" ) ]] || exit 1

amp_stage=$(mktemp "$(dirname "$AMP_SETTINGS")/.amp-settings.XXXXXX")
settings_baseline=$(mktemp "$AGENT_DIR/.settings-baseline.XXXXXX")
settings_stage=$(mktemp "$AGENT_DIR/.settings.XXXXXX")
amplike_stage=$(mktemp "$AGENT_DIR/.amplike.XXXXXX")
cleanup_rollback_stages() {
  rm -f -- "$amp_stage" "$settings_baseline" "$settings_stage" "$amplike_stage"
}
trap cleanup_rollback_stages EXIT

git show "$PRE_ROLLOUT:ai/pi/permissions.json" >"$amp_stage"
jq -e 'type == "object"' "$amp_stage" >/dev/null

git show "$PRE_ROLLOUT:ai/pi/settings.json" >"$settings_baseline"
jq -e 'type == "object"' "$settings_baseline" >/dev/null
jq -s '.[0] as $runtime | .[1] as $old | $runtime + {packages: $old.packages}' \
  "$AGENT_DIR/settings.json" "$settings_baseline" >"$settings_stage"
jq -e 'type == "object"' "$settings_stage" >/dev/null

if [[ -f "$AGENT_DIR/amplike.json" ]]; then
  jq '.permissions = ((.permissions // {}) + {mode: "enabled"})' \
    "$AGENT_DIR/amplike.json" >"$amplike_stage"
else
  printf '{}\n' | jq '.permissions.mode = "enabled"' >"$amplike_stage"
fi
jq -e 'type == "object"' "$amplike_stage" >/dev/null
jq -e '.permissions.mode == "enabled"' "$amplike_stage" >/dev/null

chmod 0644 "$amp_stage" "$settings_stage"
chmod 0600 "$amplike_stage"
mv -f "$amp_stage" "$AMP_SETTINGS"
mv -f "$settings_stage" "$AGENT_DIR/settings.json"
mv -f "$amplike_stage" "$AGENT_DIR/amplike.json"
rm -f "$settings_baseline"
trap - EXIT

PI_CODING_AGENT_DIR="$AGENT_DIR" pi update --extensions
```

Every restored JSON file is staged and validated before the first destination changes, and each destination is replaced through a same-directory atomic rename. No portable filesystem operation can commit all three destinations as one transaction, so keep Pi stopped and rerun the complete sequence if any publication fails. Amp subagents, the reverted Amp package inventory, the Amp policy file, and enabled permission state **must be restored together** before launching Pi. Restoring Amp subagents with a missing policy file or YOLO state is forbidden.

## Removed scope

This migration does not restore Claude project overlays, Claude agent teams, devcontainer seeding, the Vekil proxy, or Claude Code/Codex CLI installation. Existing machine-local authentication, histories, and sessions outside positively identified retired links remain untouched.
