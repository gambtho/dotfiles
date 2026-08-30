# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages Pi as the coding-agent harness under `ai/`:

```text
ai/
  pi/
    settings.json             # GitHub Copilot provider and package inventory
    permissions.json          # Conservative pi-amplike Bash allow policy
    modes.json                # Central subagent model/thinking routing
    keybindings.json          # Global Pi shortcuts
    AGENTS.md                 # Global working agreement
    extensions/
      worktree-guard.ts       # Blocks direct writes in primary checkouts
    install.sh                # Pinned Pi install and config linking
  marketplace/plugins/my/    # Local personal Pi package
    prompts/                  # Slash-command prompt templates
    skills/                   # On-demand Agent Skills
    package.json              # Pi resource manifest
```

Run `make ai` or `bash ai/pi/install.sh`. The installer links authored configuration into `~/.pi/agent/`, reconciles packages, and leaves authentication, sessions, trust decisions, package caches, and generated model catalogs machine-local.

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
- `change-explainer` — reviewer-facing completed-change write-up.

## Conventions

- Keep Pi configuration in this repository, not directly under `~/.pi/agent/`.
- Never commit `auth.json`, sessions, trust decisions, generated model catalogs, or package caches.
- Language rules live in `ai/marketplace/plugins/my/skills/polish-core/rules/`.
- After changing Pi configuration or package resources, run `bash bin/validate-ai` and the relevant tests.
- Prompt and skill edits take effect after `/reload` or in the next Pi session.

## Adding resources

For a skill, create `ai/marketplace/plugins/my/skills/<name>/SKILL.md` with valid `name` and `description` frontmatter, then add it to `package.json`.

For a prompt template, create `ai/marketplace/plugins/my/prompts/<name>.md` with `description` frontmatter, then add it to `package.json`.

For global guidance or settings, edit files under `ai/pi/` and run `make ai` to refresh links.
