# Pi configuration

This directory contains the repository-managed configuration for Pi, the sole coding-agent harness installed by these dotfiles.

## Provider and models

Pi connects directly to the GitHub Copilot subscription; no model proxy is required.

- Authenticate interactively with `/login` and choose **GitHub Copilot**.
- Select an enabled model with `/model`; Ctrl+S saves the highlighted model as the startup default.
- Keep OAuth credentials in `~/.pi/agent/auth.json`. Never commit or link that file.

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
| Parent command containment | `pi-sandbox` | Bubblewrap containment is parent-only because its manager is process-global |
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

`rush`, `deep`, and `review` omit write/edit tools and add restrictive permission frontmatter. `smart` inherits the balanced global policy. Children cannot recursively dispatch more children.

## Permission and containment model

`ai/pi/config/permission-system.json` is a balanced baseline:

- routine reads, linked-worktree edits, common builds/tests/lint, and configured web tools are allowed;
- unknown tools, mutation-capable commands, external paths, and `lsp_fix` ask;
- credentials, browser profiles, destructive commands, force operations, subprocess-capable search flags, and primary-checkout writes are denied;
- `/permission-system` can enable temporary YOLO, which converts asks to allows but preserves explicit denies.

The sandbox baseline in `ai/pi/config/sandbox.json` permits reviewed development registries and caches while denying credential and browser roots. It does not expose SSH/cloud credentials, browser cookies, Docker sockets, unrestricted Unix sockets, or blanket home-directory access.

### Important containment boundaries

Bubblewrap is **parent-only**. Gotgenes children inherit permission-system and worktree-guard, but intentionally exclude `pi-sandbox`; concurrent in-process children cannot safely share its process-global manager. Child safety therefore depends on complete tool allowlists, permission forwarding, restrictive agent policy, and the worktree guard.

Sandbox wrapping applies to the parent command paths integrated by `pi-sandbox`, not every operation performed inside another extension:

- `/code run` executes through extension-internal `pi.exec()` and is not Bubblewrap-contained.
- LSP server subprocesses are extension-internal and are not Bubblewrap-contained. Permission-system still gates the model-facing LSP call, and worktree-guard blocks a mutating fix targeting a primary checkout.
- `pi-web-access network calls` are extension-internal and are not Bubblewrap-contained. The tracked config disables cookie use, remote hosted fetch providers, clone/media/image features, environment proxy trust, and SSRF range exceptions.

Do not describe these layers as a complete security boundary for untrusted code. Keep extension selection and package pins under review.

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
      sandbox.json
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
| `ai/pi/config/permission-system.json` | `~/.pi/agent/extensions/pi-permission-system/config.json` | renders the active agent auth path; preserves drift |
| `ai/pi/config/sandbox.json` | `~/.pi/agent/sandbox.json` | renders the active agent auth path; preserves drift |
| `ai/pi/config/subagents.json` | `~/.pi/agent/subagents.json` | installs when missing; preserves drift |
| `ai/pi/config/web-search.json` | `$PI_CODING_AGENT_DIR/web-search.json`, `$XDG_CONFIG_HOME/pi/web-search.json`, or `~/.pi/web-search.json` | installs when missing; preserves drift |

Use runtime commands such as `/permission-system`, `/sandbox`, and `/subagents:settings` for intentional machine-local changes. To back up differing files and restore every tracked baseline explicitly:

```bash
PI_AI_RESET_MUTABLE_CONFIG=1 make ai
```

Authentication, sessions, trust decisions, generated model catalogs, package caches, permission logs, grants, and runtime credentials remain machine-local and untracked.

## Installation and rollout

Preview without mutation:

```bash
make ai-check
```

Apply from the canonical checkout:

```bash
make ai
```

The installer refuses a production-agent-dir apply when invoked from a different linked implementation worktree while the canonical checkout exists. Before integration, use an **isolated pre-integration smoke** with an absolute temporary `PI_CODING_AGENT_DIR`, separate XDG paths, and only a temporary owner-readable authentication copy. Delete the smoke directory afterward. After integration, run `make ai` again from the canonical checkout and inspect its identity-aware migration report.

The migration converts the old whole-extension link to a real directory, preserves unrelated extension entries, and publishes only the two authored links. It removes only exact managed Amp settings links and only the `.permissions` key from valid Amp state. The exact legacy Brave `brave-search` directory is moved intact below `disabled-skills`; sibling skills, mismatches, and collisions are preserved.

## Unattended operation

Before `overnight-improve`:

1. Work in a clean linked worktree.
2. Open `/permission-system`, enable YOLO temporarily, and verify status.
3. Open `/sandbox`, verify enabled, and pre-approve each reviewed parent path/domain.
4. Run a representative build/test gate through both layers.
5. Treat any sandbox prompt timeout or permission deny as blocked.
6. Disable permission-system YOLO and verify it is off during wrap-up.

YOLO never bypasses explicit denies or the sandbox. Children remain permission-enforced and worktree-guarded but are not Bubblewrap-contained.

## Validation

Offline repository checks require no installed extension packages or network:

```bash
bash bin/validate-ai --verbose
make ai-check
make check
```

After isolated or production package installation, validate against the exact installed permission schema and evaluator:

```bash
PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" \
  bin/validate-pi-security-runtime
```

## Emergency rollback

Rollback is coupled and non-YOLO. Choose the last commit before this rollout as `PRE_ROLLOUT`, revert the rollout commits, and **do not run the reverted old installer**, because it would recreate the whole-directory extension link.

1. Extract the reverted `ai/pi/permissions.json` and copy it to `${XDG_CONFIG_HOME:-$HOME/.config}/amp/settings.json` as a regular file.
2. Merge `.packages` from the reverted `ai/pi/settings.json` into the current regular `~/.pi/agent/settings.json`, preserving all other settings.
3. Update `~/.pi/agent/amplike.json` so the resulting state is explicitly `permissions.mode: enabled`, never YOLO.
4. Run `pi update --extensions` with the intended agent directory.
5. Preserve the real extensions directory, unrelated extensions, machine-local configuration, grants, and logs.

A concrete staging sequence, after reverting the implementation commits, is:

```bash
PRE_ROLLOUT=<last-commit-before-this-rollout>
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
AMP_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/amp/settings.json"
mkdir -p "$(dirname "$AMP_SETTINGS")"
[[ ! -L "$AMP_SETTINGS" ]] || { echo "refusing Amp settings symlink" >&2; exit 1; }
[[ -f "$AGENT_DIR/settings.json" && ! -L "$AGENT_DIR/settings.json" ]] || exit 1
[[ ! -e "$AGENT_DIR/amplike.json" || ( -f "$AGENT_DIR/amplike.json" && ! -L "$AGENT_DIR/amplike.json" ) ]] || exit 1

amp_stage=$(mktemp "$(dirname "$AMP_SETTINGS")/.amp-settings.XXXXXX")
git show "$PRE_ROLLOUT:ai/pi/permissions.json" >"$amp_stage"
chmod 0644 "$amp_stage"
mv -f "$amp_stage" "$AMP_SETTINGS"

settings_baseline=$(mktemp "$AGENT_DIR/.settings-baseline.XXXXXX")
settings_stage=$(mktemp "$AGENT_DIR/.settings.XXXXXX")
git show "$PRE_ROLLOUT:ai/pi/settings.json" >"$settings_baseline"
jq -s '.[0] as $runtime | .[1] as $old | $runtime + {packages: $old.packages}' \
  "$AGENT_DIR/settings.json" "$settings_baseline" >"$settings_stage"
chmod 0644 "$settings_stage"
mv -f "$settings_stage" "$AGENT_DIR/settings.json"
rm "$settings_baseline"

amplike_stage=$(mktemp "$AGENT_DIR/.amplike.XXXXXX")
if [[ -f "$AGENT_DIR/amplike.json" ]]; then
  jq '.permissions = ((.permissions // {}) + {mode: "enabled"})' \
    "$AGENT_DIR/amplike.json" >"$amplike_stage"
else
  printf '{}\n' | jq '.permissions.mode = "enabled"' >"$amplike_stage"
fi
chmod 0600 "$amplike_stage"
mv -f "$amplike_stage" "$AGENT_DIR/amplike.json"

PI_CODING_AGENT_DIR="$AGENT_DIR" pi update --extensions
```

Inspect each staged JSON file before its `install` command. Amp subagents, the reverted Amp package inventory, the Amp policy file, and enabled permission state **must be restored together** before launching Pi. Restoring Amp subagents with a missing policy file or YOLO state is forbidden.

## Removed scope

This migration does not restore Claude project overlays, Claude agent teams, devcontainer seeding, the Vekil proxy, or Claude Code/Codex CLI installation. Existing machine-local authentication, histories, and sessions outside positively identified retired links remain untouched.
