# Pi configuration

This directory contains the repository-managed configuration for Pi, the sole coding-agent harness installed by these dotfiles.

## Decisions

### Provider and models

Pi connects directly to the GitHub Copilot subscription. No model proxy is required.

- Authenticate interactively with `/login` and choose **GitHub Copilot**.
- Select any Copilot model enabled for the subscription with `/model`.
- Press Ctrl+S in the model picker to save the highlighted model as the startup default.
- Keep OAuth credentials in `~/.pi/agent/auth.json`; never commit them.

### Prefer packaged mechanisms and custom workflows

Existing Pi packages own generic runtime mechanisms. The local `my` package remains responsible for workflows that encode personal policy or behavior.

| Capability | Decision | Implementation |
|---|---|---|
| Authentication, model selection, sessions, branching, compaction, and trust | Use native Pi | `@earendil-works/pi-coding-agent` |
| Subagents and cross-session handoff | Use existing | `pi-amplike` |
| Subagent model and thinking routing | Manage centrally | `ai/pi/modes.json` |
| Auto-allow, ask, or deny Bash commands | Use existing | `pi-amplike` permissions in enabled mode |
| Plan-mode enforcement and persistent plan state | Use existing | `shitty-extensions/extensions/plan-mode.ts` |
| Planning quality and blind-spot analysis | Keep custom | `implementation-plan`, `blindspot-pass` |
| Structured development methodology and skill bootstrap | Use existing | `obra/superpowers` Pi package |
| Long-running iteration runtime | Use existing | `pi-ralph-wiggum/index.ts` |
| Opinionated overnight improvement workflow | Keep custom | `overnight-improve` |
| Worktree creation guidance | Use existing | `obra/superpowers@using-git-worktrees` (loaded by the full package) |
| Primary-checkout write enforcement | Keep custom | `ai/pi/extensions/worktree-guard.ts` |
| Spec and plan second opinions | Keep custom | `/second-opinion` using a different Copilot model |
| General alternate-model Oracle | Remove | Duplicates the broad concept, lacks repository tools, and does not target Copilot models |
| Conservative code cleanup and language rules | Keep custom | `/polish` and `polish-core` |
| PR feedback planning, batch review, and isolated PR polishing | Keep custom | `/fix-pr`, `/review-prs`, `/polish-pr` |
| Session recap | Use existing | `session-recap` |
| Historical usage dashboard | Use existing | `usage-extension` |
| Live model, context, token, and cost display | Use existing | `pi-powerline-footer` |
| Separate historical cost tracker | Remove | Redundant with the usage dashboard and footer |
| Clipboard output and editable raw paste | Use existing | `clipboard.ts` and `raw-paste` |
| Web search and page extraction | Use existing | `pi-amplike` skills |
| Interactive browser automation | Add only when needed | No default dependency |
| Claude project overlays and devcontainer seeding | Remove without replacement | These workflows are not in active use |

### Subagent model routing

`ai/pi/modes.json` gives workflows stable task-oriented names without scattering model IDs through every prompt:

| Mode | Model | Thinking | Use |
|---|---|---|---|
| `rush` | GitHub Copilot GPT-5.4 Mini | low | Bounded searches, inventories, and mechanical checks |
| `smart` | GitHub Copilot GPT-5.6 Sol | medium | Normal code review and implementation subtasks |
| `deep` | GitHub Copilot GPT-5.6 Terra | high | Architecture, security, diagnosis, and broad analysis |
| `review` | GitHub Copilot Claude Opus 5 | high | Independent second opinions from another model family |

A subagent inherits the current session's model and thinking when neither `mode` nor `model` is supplied. An explicit `model` overrides the model selected by a mode. One `subagent` call applies the same mode/model to every task in that batch, so tasks requiring different models must use separate calls.

Project-local `.pi/modes.json` entries take precedence over these global modes. Use that only when a repository genuinely needs different routing.

### Permission mode

Pi's built-in tools run without Claude-style permission prompts. The `pi-amplike` permissions extension supplies the closest equivalent to Auto Mode for Bash: known low-risk commands are allowed, risky or unmatched commands ask, and explicit deny rules block. `/permissions` toggles between `enabled` and unrestricted `yolo`; keep `enabled` as the default. The choice persists in machine-local `~/.pi/agent/amplike.json`.

These rules cover Bash only. Direct file writes remain governed by the worktree guard described below.

The tracked `ai/pi/permissions.json` adds a conservative global allow policy for common inspection commands:

- `rg` and `fd` when they do not invoke preprocessors or executors;
- direct `jq`, non-in-place `yq`, and one-stage `... | jq ...` pipelines from file readers or approved read-only Git/GitHub commands, without redirection or additional shell control;
- read-only Git metadata (`rev-parse`, `merge-base`, remote display, and worktree listing);
- read-only GitHub views and lists;
- direct `bats` test-suite and trusted project `make` invocations;
- path and checksum utilities.

It deliberately does not blanket-allow `git`, `gh`, package managers, language runtimes, shells, or arbitrary project scripts. `make` is the explicit exception: a trusted repository's Makefile is treated as trusted executable workflow. Mutating and compound variants fall through to pi-amplike's built-in rules, which ask or deny. Project-specific rules can be added under `.agents/settings.json`.

### Second opinion versus Oracle

`/second-opinion` is not a generic chat query. It launches one isolated Pi subagent with a model from a different Copilot family, gives it repository access, and requires an evidence-backed review of a spec or implementation plan. The current agent then assesses the findings using conversation context.

Oracle sends conversation context and optional files to a fixed alternate-model list, without repository tools. It does not replace the document-review workflow and is unnecessary in the Copilot-only setup.

### Superpowers workflow

Load the complete pinned `obra/superpowers` Pi package without resource filters. Its Pi extension injects the `using-superpowers` bootstrap at session startup and after compaction, while its manifest exposes the full workflow skill set. Filtering the package down to `using-git-worktrees` disables that bootstrap and therefore does not provide the Superpowers flow.

The custom skills remain available alongside Superpowers. Repository and user instructions take precedence when their workflow requirements differ.

### Worktree policy

Use the established `using-git-worktrees` skill to create or reuse linked worktrees. The custom worktree guard enforces the local policy by blocking Pi's direct `write` and `edit` tools when their target belongs to a primary checkout. Linked worktrees and repositories listed in `~/.pi/worktree-guard-allow` are permitted.

The extension cannot reliably classify every possible shell command. Global guidance therefore explicitly forbids bypassing the guard through shell redirection, generators, or other mutating commands. Set `PI_WORKTREE_GUARD=off` only for a deliberate one-off exception.

### Removed Claude-era scope

The migration does not preserve or replace:

- `project-claude-setup`;
- private per-project Claude overlays;
- Claude devcontainer seeding and compose overrides;
- seed-drift tooling;
- Claude agent-team setup;
- Vekil proxy lifecycle;
- Claude Code or Codex CLI installation and configuration.

Existing machine-local Claude and Codex authentication, histories, and sessions are not deleted automatically.

## Managed layout

```text
ai/
  README.md
  pi/
    AGENTS.md
    settings.json
    permissions.json
    modes.json
    keybindings.json
    extensions/
      worktree-guard.ts
    install.sh
  marketplace/plugins/my/
    package.json
    prompts/
    skills/
```

`ai/pi/install.sh` installs the pinned Pi release, links authored configuration into `~/.pi/agent/`, and reconciles declared packages. Run it through:

```bash
make ai
```

Preview without changing the machine:

```bash
make ai-check
```

## Machine-local boundary

Do not add these to the repository:

- `~/.pi/agent/auth.json`;
- `~/.pi/agent/sessions/`;
- `~/.pi/agent/trust.json`;
- `~/.pi/agent/models-store.json`;
- installed package trees under `~/.pi/agent/git/` and `~/.pi/agent/npm/`;
- API keys, OAuth tokens, generated catalogs, or extension runtime state.

Only authored settings, guidance, keybindings, local extensions, prompts, and skills belong here.

## Validation

After changing Pi configuration or the personal package, run:

```bash
bash bin/validate-ai --verbose
bats tests/pi_worktree_guard.bats
```

Run the full repository suite before completing a migration change:

```bash
make check
```
