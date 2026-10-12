# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages Pi as the coding-agent harness under `ai/`:

```text
ai/
  pi/
    settings.json             # First-install/reset baseline; package inventory is authoritative
    keybindings.json          # Global Pi shortcuts
    AGENTS.md                 # Global working agreement
    agents/                   # Named gotgenes subagent definitions
    config/
      modes.json              # Mutable main-session mode baseline
      permission-system.json  # Permissive attention-policy baseline
      subagents.json          # Child runtime defaults/exclusions
      file-context.json       # Mutable file picker/shortcut baseline
      web-search.json         # Keyless web routing baseline
    extensions/
      worktree-guard.ts       # Blocks direct writes in primary checkouts
    install.sh                # Managed Pi configuration and native extension update
  marketplace/plugins/my/    # Local personal Pi package
    prompts/                  # Slash-command prompt templates
    skills/                   # On-demand Agent Skills
    package.json              # Pi resource manifest
```

Stop Pi before changing resources. `make ai` or `bash ai/pi/install.sh` converges configuration and runs native `pi update --extensions --no-approve`; packages may advance and native reconciliation may replace cached files. Host self-update remains operator-owned through `pi update`. See `ai/README.md` for installed compatibility gates, selective refresh and per-file configuration backups. Do not deploy from an implementation worktree.

The installer links immutable authored resources, publishes runtime-mutated settings and security configuration as regular machine-local files, and leaves authentication, sessions, trust decisions, package caches, user plans, logs, and generated model catalogs machine-local. Tracked mutable baselines such as `ai/pi/config/modes.json`, `ai/pi/config/subagents.json`, `ai/pi/config/file-context.json`, and `ai/pi/config/web-search.json` remain first-install/reset inputs whose runtime drift is preserved, except exact owned child-exclusion normalization and explicit selective preference refresh. `ai/pi/config/permission-system.json` is different: its repository-owned permission map and stable fields are republished on `make ai` while valid runtime `yoloMode`, `debugLog`, and `permissionReviewLog` controls are preserved; active YOLO blocks normal publication.

Pi authenticates directly to the GitHub Copilot subscription through `/login`. Select any enabled Copilot model with `/model`; press Ctrl+S in the picker to save it as the startup default.

## The `my` Package

`ai/marketplace/plugins/my/` is the canonical source for personal prompts and skills.

### Prompt templates

- `/fix-pr` — collect unresolved PR review comments and failing CI, then write a plan under `~/.pi/pr-fix-plans/`.
- `/polish` — analyze changed code, auto-fix high-confidence issues, and report the rest.
- `/polish-pr` — polish a PR in an isolated worktree and prompt before pushing.
- `/review-prs` — batch-review open PRs and persist learnings under `~/.pi/pr-reviews/`.
- `/second-opinion` — review a spec or plan with a different GitHub Copilot model.

### Skills

- `improve` — holistic codebase audit with ranked findings.
- `overnight-improve` — autonomous iterative improvement using Pi Ralph tooling.
- `polish-core` — shared engine behind `/polish`, including per-language idiom rules.
- `blindspot-pass` — pre-implementation risk surface.
- `implementation-plan` — evidence-based implementation plan.
- `lane-coordinator` — coordinate manually started lanes (Pi or Claude Code): keep STATE.md current, verify reports, and gate outward publication.
- `change-explainer` — reviewer-facing completed-change write-up.
- `second-opinion-core` — cross-model spec/plan review; runs automatically after a spec or plan is written and backs `/second-opinion`.

## Conventions

- `bin/` is the exact public command surface: `dot-install`, `dot-update`, `gh`, `git-identity`, `git-worktree-gc`, and `tmux-copy-url`. `tests/repository_hygiene.bats` enforces this inventory; additions require explicit justification and test updates. Repository maintenance tools and sourced libraries belong in `libexec/`, which must never be added to PATH; use the existing Make targets for routine maintenance. Never add standard-command names or compatibility wrappers/symlinks for removed paths. Preserve PATH ordering and the intentional `gh` identity shim's precedence.
- Keep authored Pi baselines in this repository; use runtime commands for mutable machine-local files under `~/.pi/agent/`.
- Astra uses the tested Pi 1.1.0 native Responses catalog entry. The one-time runtime `models.json` retirement removes only Copilot `gpt-6-astra`, preserves other models/metadata, and records a private migration receipt; never manage the generated models store as a baseline.
- Superpowers planning is a process, not a read-only security/UI mode. Shitty (including clipboard/memory/planner) and caffeinate are retired; user plans remain untouched. Package caches follow native Pi reconciliation. Codemode nested tool calls use permission/worktree tripwires, while classifier/image models and extension-internal execution retain separate ambient authority.
- Selective refresh does not migrate turn-budget preferences: `wrapUpTurns` warns before the hard limit, unlike retired `graceTurns` after a soft limit. Choose existing subagent settings deliberately. File-context uses F8 without taking native copy keys; custom shortcuts survive.
- Never commit `auth.json`, sessions, trust decisions, generated model catalogs, or package caches.
- Language rules live in `ai/marketplace/plugins/my/skills/polish-core/rules/`.
- After changing Pi configuration or package resources, run `make validate` and the relevant tests.
- Prompt and skill edits take effect after `/reload` or in the next Pi session.

## Adding resources

For a skill, create `ai/marketplace/plugins/my/skills/<name>/SKILL.md` with valid `name` and `description` frontmatter, then add it to `package.json`.

For a prompt template, create `ai/marketplace/plugins/my/prompts/<name>.md` with `description` frontmatter, then add it to `package.json`.

For global guidance or settings, edit files under `ai/pi/` and run `make ai` to refresh links.
