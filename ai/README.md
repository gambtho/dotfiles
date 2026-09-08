# Pi configuration

This directory contains the repository-managed configuration for Pi, the sole coding-agent harness installed by these dotfiles.

## Provider and models

Pi connects directly to the GitHub Copilot subscription; no model proxy is required.

- Authenticate interactively with `/login` and choose **GitHub Copilot**.
- Select an enabled model with `/model`; Ctrl+S saves the highlighted model as the startup default.
- Keep OAuth credentials in `~/.pi/agent/auth.json`. Never commit or link that file.

### Temporary GPT-6 Astra transport override

Pi 0.85.1's generated GitHub Copilot catalog assigns `gpt-6-astra` to `openai-completions`. Copilot exposes Astra only through its Responses endpoint, so the unmodified entry fails with `unsupported_api_for_model`. `ai/pi/config/models.json` replaces that one built-in entry with an `openai-responses` definition while leaving all other built-in Copilot models intact.

The override includes the IDE identity headers Copilot requires. Those header versions mirror the affected Pi release and may age, so this is a temporary compatibility baseline rather than a permanent custom model. Run `make ai`, reopen `/model`, and reselect `github-copilot/gpt-6-astra` after installation. The installer preserves an existing, differing `~/.pi/agent/models.json`; merge the Astra entry manually or use `PI_AI_RESET_MUTABLE_CONFIG=1 make ai` if replacing all mutable Pi baselines is acceptable. When upstream Pi corrects Astra's Copilot transport, remove the baseline, its installer reconciliation, and these notes. Also delete `~/.pi/agent/models.json` when it contains only this override, or remove its Astra entry while preserving other local models; deleting tracked files alone does not remove the copied runtime override.

## Capability stack

Generic runtime behavior comes from pinned packages. The local `my` package remains responsible for personal review and implementation workflows.

| Capability | Implementation | Notes |
|---|---|---|
| Queue and steer messages during a response | `pi-queue-steer` | Adds streaming-time queue/steer behavior without a model-facing tool |
| Keyless search and local content extraction | `pi-web-access` | Routes search through Exa then DuckDuckGo and fetches through the local HTTP provider |
| Code-block actions and `/code run` | `code-actions` from `tmustier/pi-extensions` | Enables reviewed code actions; see the containment exception below |
| Diagnostics and preview/apply fixes | `@narumitw/pi-lsp` | Provides `lsp_diagnostics` and `lsp_fix`; mutating fixes remain worktree-guarded |
| Named child agents | `@gotgenes/pi-subagents` | One `subagent` call starts one agent; background calls return IDs for later polling |
| Allow/ask/deny policy | `@gotgenes/pi-permission-system` | Gates model-facing tools, paths, shell commands, and forwarded child requests |
| Main-session modes, handoff, BTW, and session query | filtered `pi-amplike` | Amp permissions, subagents, prompts, themes, and legacy web skills are not loaded |
| Structured development methods | `obra/superpowers` | Full pinned package, including the session bootstrap |
| Long-running iterations | `pi-ralph-wiggum` | Used by the custom `overnight-improve` workflow |
| Model/context/cost UI | `pi-powerline-footer`, `usage-extension`, `session-recap` | Existing display and recap behavior |
| Primary-checkout write enforcement | `ai/pi/extensions/worktree-guard.ts` | Covers built-in writes and mutating `lsp_fix` with rooted path resolution |

Interactive browser automation remains opt-in rather than a default dependency.

## Named agents and routing

`ai/pi/config/modes.json` is the first-install/reset baseline for retained main-session modes. Gotgenes child routing is defined by the four files under `ai/pi/agents/`:

| `subagent_type` | Model | Thinking | Use |
|---|---|---|---|
| `rush` | GitHub Copilot GPT-5.4 Mini | low | Bounded searches, inventories, and mechanical checks |
| `smart` | GitHub Copilot GPT-5.6 Sol | medium | Normal review, investigation, and implementation subtasks |
| `deep` | GitHub Copilot GPT-5.6 Terra | high | Architecture, security, diagnosis, and broad analysis |
| `review` | GitHub Copilot Claude Opus 5 | high | Independent cross-family second opinions |

Each `subagent` invocation supplies one self-contained `prompt`, a 3–5 word `description`, and a `subagent_type`. Parallel work uses sibling calls with `run_in_background: true`; record each returned ID and poll with `get_subagent_result({ agent_id, wait: false })`. An explicit `model` is reserved for a user request or deliberate cross-family review.

`rush`, `deep`, and `review` omit write/edit tools and allow routine inspection and verification silently. Their explicit rules deny selected repository and remote mutations; other recognized risky operations follow the composed permission policy instead of an absolute read-only guarantee. `smart` otherwise inherits the permissive global attention policy. Every named child hard-denies Bash commands containing unresolved `$` expansion so a curated reader cannot hide a sensitive operand from path extraction. Children cannot recursively dispatch more children.

## Permission and containment model

`ai/pi/config/permission-system.json` is a permissive attention and tripwire layer, not a sandbox:

- routine tools, unmatched parent Bash commands, local Git subcommands, normal fetch/push, explicitly fast-forward-only pulls, PR/issue creation and editing, `lsp_fix`, ordinary `curl` GETs/downloads, and loopback HTTP probes are allowed;
- unknown extension tools and MCP targets, non-fast-forward pulls, selected destructive Git operations, PR merges and issue closure, recognizable remote shell/network commands, and recognizable deletion ask;
- bounded lexical `curl` tripwires ask for `--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, or separate-token `-d`; `--form`/`-F`; `--upload-file`/`-T`; explicit `POST`, `PUT`, `PATCH`, or `DELETE` through `--request`/`-X`; and recognized authorization, user, cookie, certificate, key, or netrc arguments; aliases, interpreters, generated arguments, and semantically equivalent requests are outside that coverage;
- policy denies recognized credential and browser-profile path access, catastrophic deletion, force operations, subprocess-capable search flags, and privilege escalation; worktree guard separately denies direct model-facing write, edit, and mutating LSP operations in primary checkouts;
- common reader/output commands containing unresolved `$` expansion and direct environment-dump commands ask, while named children hard-deny all unresolved shell-variable indirection; use `NAME=value command` rather than the opaque `env NAME=value command` wrapper so ordinary scoped commands remain inspectable and silent;
- external-directory read and write catch-alls allow ambiguous external paths to avoid false prompts; explicit protected-path denies remain later tripwires, not containment;
- `/permission-system` can enable temporary YOLO, which converts asks to allows but preserves explicit denies.

### Important containment boundaries

Allowed Bash processes are not OS-contained. They retain the invoking user's
ambient filesystem, environment, network, and subprocess authority. Path and
command rules reduce accidental access and route attention; they do not contain
hostile or interpreter-generated behavior.

Gotgenes children inherit permission-system and worktree-guard, with restrictive agent policy and complete tool allowlists providing additional controls. The variable-indirection deny closes the reviewed direct reader bypass, but neither parent nor child Bash is a safe execution boundary for untrusted commands. Path rules do not recursively constrain operations performed inside an allowed shell command or extension:

- `/code run` executes through extension-internal `pi.exec()`.
- LSP server subprocesses are extension-internal. Permission-system still gates the model-facing LSP call, and worktree-guard blocks a mutating fix targeting a primary checkout.
- `pi-web-access network calls` are extension-internal. The tracked config disables cookie use, remote hosted fetch providers, clone/media/image features, environment proxy trust, and SSRF range exceptions.

Do not put secrets in the agent environment, run Pi against untrusted code, enable YOLO for interactive work, or describe these controls as a security boundary. Keep extension selection and package pins under review.

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
      models.json
      permission-system.json
      subagents.json
      web-search.json
    extensions/
      herdr-agent-state.ts
      worktree-guard.ts
    install.sh
    migrate-security-stack.sh
  marketplace/plugins/my/
    package.json
    prompts/
    skills/
```

Immutable guidance, keybindings, named agents, and the two authored extensions are individual links. The installer owns these **six mutable runtime files** as regular machine-local files:

| Tracked baseline | Runtime destination | Routine install behavior |
|---|---|---|
| `ai/pi/settings.json` | `~/.pi/agent/settings.json` | merges only `.packages`; preserves every other runtime key |
| `ai/pi/config/modes.json` | `~/.pi/agent/modes.json` | installs when missing; preserves drift |
| `ai/pi/config/models.json` | `~/.pi/agent/models.json` | temporarily corrects Copilot Astra's API transport; installs when missing and preserves drift |
| `ai/pi/config/permission-system.json` | `~/.pi/agent/extensions/pi-permission-system/config.json` | repository-owned permission map is republished on `make ai`; valid runtime `yoloMode`, `debugLog`, and `permissionReviewLog` values are preserved; publication refuses active YOLO |
| `ai/pi/config/subagents.json` | `~/.pi/agent/subagents.json` | installs when missing; preserves drift |
| `ai/pi/config/web-search.json` | `$PI_CODING_AGENT_DIR/web-search.json`, `$XDG_CONFIG_HOME/pi/web-search.json`, or `~/.pi/web-search.json` | installs when missing; preserves drift |

Use runtime commands such as `/permission-system` and `/subagents:settings` for intentional machine-local changes. Runtime permission-map or stable-field edits are temporary and are replaced by the next `make ai`; the three `/permission-system` runtime controls survive publication. To back up differing files and reset the other runtime-owned mutable baselines explicitly:

```bash
PI_AI_RESET_MUTABLE_CONFIG=1 make ai
```

`PI_AI_RESET_MUTABLE_CONFIG=1` no longer replaces permission-system `yoloMode`, `debugLog`, or `permissionReviewLog`. During normal authoritative reconciliation, the same active-YOLO refusal applies with or without reset. Authentication, sessions, trust decisions, upstream-generated model catalogs, package caches, permission logs, grants, and runtime credentials remain machine-local and untracked. The tracked `models.json` is a narrow temporary override, not a copy of the generated catalog.

When retiring a legacy `pi-sandbox` installation, the installer backs up and resets the permission policy to the tracked non-YOLO, unmatched-Bash-allows baseline, then removes the retired `pi-sandbox` child exclusion before reconciling packages. This transitional retirement path is the only exception to normal authoritative publication: it safely resets active YOLO and publishes the tracked baseline before the package schema is available so a permission layer remains present while the old containment package is retired. Normal reconciliation refuses active YOLO and validates the candidate against the exact installed schema before publication. A previous `~/.pi/agent/sandbox.json` and cached package checkout are preserved as inactive machine-local state; neither is loaded once the package source is absent from `settings.json`. They may be deleted manually after restarting Pi if rollback is not needed.

## Installation and rollout

The composed Linux/WSL APT manifests install `ripgrep` for Pi search workflows. Pi does not install or require an OS sandbox runtime.

Preview without mutation:

```bash
make ai-check
```

Apply from the canonical checkout:

```bash
make ai
```

The installer refuses a production-agent-dir apply—including one reached through a resolved path alias—when invoked from a different linked implementation worktree while the canonical checkout exists. Before integration, use an **isolated pre-integration smoke** with an absolute temporary `PI_CODING_AGENT_DIR`, separate HOME and XDG paths, and `DOTFILES` pointed at the reviewed checkout so the local `my` package remains available. Package installation and the exact installed-runtime gate pipeline do not require Copilot authentication. An agent command must not read or copy production `auth.json`; defer interactive model-facing smoke to the canonical rollout unless the operator provisions isolated credentials outside the agent command. Delete the smoke directory afterward. After integration, run `make ai` again from the canonical checkout and inspect its identity-aware migration report.

The installer explicitly bootstraps any missing or mismatched version-pinned npm packages before running `pi update --extensions`. A matching permission-system version is accepted only when its schema and manager artifacts are also present; one incomplete installation attempt is retried and then fails clearly if it remains partial. Pi intentionally skips pinned npm sources during ordinary updates, so update alone is not a first-install mechanism. The installer verifies exact package versions and confirms that Pi preserved the tracked package inventory.

Permission publication uses best-effort compare-before-publish: it checks the runtime file identity before backup and again after backup immediately before the atomic rename. Because the permission-system UI writer shares no lock with the installer, an unavoidable race remains between the final check and rename; the extra check narrows but cannot eliminate it.

The migration converts the old whole-extension link to a real directory, preserves unrelated extension entries, and publishes only the two authored links. It removes only exact managed Amp settings links and only the `.permissions` key from valid Amp state. The exact legacy Brave `brave-search` directory is moved intact below `disabled-skills`; sibling skills, mismatches, and collisions are preserved.

The opt-in [Pi Web UI](pi/webui/README.md) has a separate installer and operations runbook.

## Unattended operation

Before `overnight-improve`:

1. Work in a clean linked worktree.
2. Open `/permission-system`, enable YOLO temporarily, and verify status.
3. Run a representative build/test gate and resolve every permission denial before leaving the workflow unattended.
4. Treat any permission denial or prompt timeout as blocked.
5. Disable permission-system YOLO and verify it is off during wrap-up.

YOLO never bypasses explicit denies. Parent and child commands are not OS-contained; direct write/edit and mutating LSP calls remain worktree-guarded, but approved Bash commands can mutate a primary checkout. Use unattended mode only for reviewed code and commands.

## Validation

Offline repository checks require no installed extension packages or network:

```bash
bash bin/validate-ai --verbose
make ai-check
make check
```

After isolated or production package installation, validate the tracked policy candidate against the selected installed permission schema and evaluator. This command does not validate whichever config is currently active in a running Pi session. Select isolated smoke roots explicitly, for example:

```bash
SMOKE_AGENT_DIR=/absolute/path/to/smoke-home/.pi/agent
SMOKE_PI_PACKAGE_ROOT=/absolute/path/to/smoke-home/.local/lib/node_modules/@earendil-works/pi-coding-agent
bin/validate-pi-security-runtime \
  --package-root "$SMOKE_AGENT_DIR/npm/node_modules/@gotgenes/pi-permission-system" \
  --pi-package-root "$SMOKE_PI_PACKAGE_ROOT"
```

For the normal installed roots, putting the intended `pi` first on `PATH` and setting `PI_CODING_AGENT_DIR` selects the same two dependencies implicitly.

## Emergency rollback

For a permission-policy-only rollback, stop Pi and restore the exact permission-config backup path printed by the publishing installer (a sibling of `~/.pi/agent/extensions/pi-permission-system/config.json` named `config.json.backup...`). Confirm the restored config has `yoloMode: false`, preserve the permission directory's `0700` mode and config file's `0644` mode, then restart Pi. Revert or amend the tracked policy before the next `make ai`, or authoritative reconciliation will republish it. If publication reported no backup, the installed policy was already identical or no prior runtime policy existed.

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
