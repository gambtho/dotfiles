# Dotfiles Repository

Personal dotfiles for Linux, macOS, and WSL. Built around zsh + Prezto + Powerlevel10k + mise.

## AI Tool Configuration

This repository manages Pi as the coding-agent harness under `ai/`, and installs the shared skills package for Pi and Claude Code:

```text
ai/
  claude/install.sh           # Install or re-pin the skills plugin for Claude Code
  copilot/install.sh          # Bootstrap standalone Copilot CLI when missing
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
      herdr-agent-state.ts    # Herdr agent lifecycle state bridge
      herdr-prompt-state.ts   # Herdr prompt state bridge
      lane-native-editor.ts   # Restores Pi's native frame for lane sessions
      worktree-guard.ts       # Blocks direct writes in primary checkouts
    install.sh                # Managed Pi configuration and native extension update
```

Stop Pi before changing resources. `make ai` converges Pi configuration, installs or re-pins the skills plugin for Claude Code, and bootstraps the standalone Copilot CLI when missing; first CLI installation requires reviewed remote-installer consent. `bash ai/pi/install.sh` handles Pi only. Pi convergence runs native `pi update --extensions --no-approve`; packages may advance and native reconciliation may replace cached files. Host self-update remains operator-owned through `pi update`. See `ai/README.md` for installed compatibility gates, selective refresh and per-file configuration backups. Do not deploy from an implementation worktree.

The installer links immutable authored resources, publishes runtime-mutated settings and security configuration as regular machine-local files, and leaves authentication, sessions, trust decisions, package caches, user plans, logs, and generated model catalogs machine-local. Tracked mutable baselines such as `ai/pi/config/modes.json`, `ai/pi/config/subagents.json`, `ai/pi/config/file-context.json`, and `ai/pi/config/web-search.json` remain first-install/reset inputs whose runtime drift is preserved, except removal of the ignored top-level `graceTurns` key, exact owned child-exclusion normalization, and explicit selective preference refresh. `ai/pi/config/permission-system.json` is different: its repository-owned permission map and stable fields are republished on `make ai` while valid runtime `yoloMode`, `debugLog`, and `permissionReviewLog` controls are preserved; active YOLO blocks normal publication.

Pi authenticates directly to the GitHub Copilot subscription through `/login`. Select any enabled Copilot model with `/model`; press Ctrl+S in the picker to save it as the startup default.

## The skills package

Personal prompts and skills live in [gambtho/gambtho-skills](https://github.com/gambtho/gambtho-skills), not here. Change them there; its README lists them. Both harnesses load one release tag, pinned twice: Pi's package source in `ai/pi/settings.json` and `SKILLS_TAG` in `ai/claude/install.sh`. `make skills-pin VERSION=vX.Y.Z` rewrites both, and `tests/dependency_pins.bats` keeps them equal. Pi loads the skills and prompts; Claude Code loads the skills as the `gambtho-skills` plugin. After Claude Code shows the plugin at the pinned version, `ai/claude/install.sh` removes `~/.claude/skills` links into `~/.dotfiles` and records their names in `~/.local/state/dotfiles/claude-legacy-links.txt`.

The package's prompts dispatch the named agents in `ai/pi/agents/`. Renaming or removing an agent breaks them; `tests/pi_modes.bats` checks the names against the pinned release.

`dot-update` fast-forwards `~/.dotfiles` on `main` (it stops on a dirty tree or another branch) and then runs the pulled `dot-install`, which runs every AI installer. `make skills-update` is a shorter path: `git pull --ff-only`, then `make ai`.

## Conventions

- `bin/` is the exact public command surface: `dot-install`, `dot-update`, `gh`, `git-identity`, `git-worktree-gc`, and `tmux-copy-url`. `tests/repository_hygiene.bats` enforces this inventory; additions require explicit justification and test updates. Repository maintenance tools and sourced libraries belong in `libexec/`, which must never be added to PATH; use the existing Make targets for routine maintenance. Never add standard-command names or compatibility wrappers/symlinks for removed paths. Preserve PATH ordering and the intentional `gh` identity shim's precedence.
- Keep authored Pi baselines in this repository; use runtime commands for mutable machine-local files under `~/.pi/agent/`.
- Astra uses the tested Pi 1.1.0 native Responses catalog entry. The one-time runtime `models.json` retirement removes only Copilot `gpt-6-astra`, preserves other models/metadata, and records a private migration receipt; never manage the generated models store as a baseline.
- Superpowers planning is a process, not a read-only security/UI mode. Shitty (including clipboard/memory/planner) and caffeinate are retired; user plans remain untouched. Package caches follow native Pi reconciliation. Codemode nested tool calls use permission/worktree tripwires, while classifier/image models and extension-internal execution retain separate ambient authority.
- Normal `make ai` removes the ignored top-level `graceTurns` key without setting `wrapUpTurns` or changing turn budgets. Selective refresh does not migrate turn-budget preferences: `wrapUpTurns` warns before the hard limit, unlike retired `graceTurns` after a soft limit. Choose existing subagent settings deliberately. File-context uses F8 without taking native copy keys; custom shortcuts survive.
- `@gotgenes/pi-permission-system` is pinned to an exact release in `ai/pi/settings.json`, and CI tests that pin. Move it only after `make pi-security-gate` passes on the new release; 44.0.0 changed how agent rules override global rules.
- Never commit `auth.json`, sessions, trust decisions, generated model catalogs, or package caches.
- After changing Pi configuration, run `make validate` and the relevant tests.
- After changing `platforms/macos/brewfile`, run `brew bundle check --verbose --file=platforms/macos/brewfile` on a Mac. Homebrew refuses casks from third-party taps until someone runs `brew trust`, so do not add such taps without that decision.

## Weekly Automations

`tools/automations/` holds three opt-in Monday reviews (`tooling-radar`, `dotfiles-health`, `lane-review`), run by `libexec/automation_run.py` from systemd user timers. Each opens a PR with a report and, where allowed, small fixes; none merges. The agent runs sandboxed with file tools only, and the runner does all publishing. `lane-review` reads private project data, so it publishes only to a verified private repository. See `tools/automations/README.md`. Keep the sandbox allowlist, per-automation fix lists, protected paths and secret scan in step with that README and the prompts.

## Lanes worker box

`tools/lane-worker/install.sh --check|--apply` (`make lane-worker[-check]`) gives a lanes worker (Linux or macOS) only the pinned skills plugin and pinned review CLIs (`codex`, `coderabbit`, `jq` when missing), unpacked under `~/.local/share/lane-worker` and linked from `~/.local/bin`. It must stay free of sudo, sign-in, shell-profile, PATH-file, systemd, Herdr and lanes changes; `tests/lane_worker_install.bats` checks that. Pins live in `config/versions.env`, one digest per OS and architecture; keep the installer runnable by macOS's bash 3.2. On a machine with `lane`, `dot-install` ends by naming `make lane-worker` when lanes cannot find `codex` or `coderabbit`; it never runs it.

## Coordinator VM

`tools/coordinator-vm/` holds the Azure template, cloud-init and first-boot runbook for one always-on VM that runs project coordinator sessions. `deploy.sh` previews with `what-if` by default; creating or changing Azure resources is the owner's decision. Keep secrets out of `cloud-init.yaml`, keep the VM without a public IP, inbound rule or role grant, and keep `tests/coordinator_vm.bats` in step.

## Adding resources

Skills and prompt templates go in gambtho/gambtho-skills; release a tag there, then run `make skills-pin VERSION=<tag>` here.

For global guidance or settings, edit files under `ai/pi/` and run `make ai` to refresh links.
