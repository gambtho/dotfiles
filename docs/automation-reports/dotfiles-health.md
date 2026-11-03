# Dotfiles health

The clearest portability problem in this 2026-11-02 review is a personal Linux pnpm path exported by shared zsh startup, including on macOS and other users' machines. The reviewed installer safeguards remain purposeful; the main cleanup opportunities are shell-startup duplication, retired browser documents, and tests tied to incidental wording.

## Applied in this PR
- Corrected four documentation files against the package manifest's nine prompts and fourteen skills (`ai/marketplace/plugins/my/package.json:9`): completed the inventories in `AGENTS.md:43` and `ai/marketplace/plugins/my/README.md:5`, replaced the incomplete list in `README.md:586` with a package-inventory link, and replaced stale resource counts in `ai/README.md:62` with that same reference. Also included the two missing Herdr bridges in `AGENTS.md:22`, matching the installer's three-extension list at `ai/pi/install.sh:31`. No resource selection or runtime behavior changed.

## Recommendations

### 1. Move the personal pnpm setup out of shared shell startup
- Evidence: `core/shell/zshrc.symlink:99` unconditionally sets `PNPM_HOME=/home/tng/.local/share/pnpm` and prepends it to PATH. This overrides an inherited setting and exports another user's Linux directory on macOS or a differently named account. `core/shell/load-custom.zsh:39` already provides a machine-local `~/.localrc` hook.
- Change: remove the seven-line pnpm block from the tracked zshrc and put any still-needed setup in the owner's `~/.localrc`. If pnpm is meant to be repository-managed, instead agree on a HOME-relative default that preserves an explicit override. Do not silently remove the neighboring Bun, Fly or OpenCode setup without checking usage.
- Risk: pnpm installed only in that directory would disappear from PATH. Before removal, confirm how pnpm resolves on each active host, migrate any required local setup, then check a fresh shell with a temporary HOME and a pre-set `PNPM_HOME`. Verify the intentional `gh` shim still wins command lookup.

### 2. Remove the obsolete browser custom-domain spec and plan
- Evidence: `docs/superpowers/specs/2026-09-04-pi-webui-custom-domain-design.md:5` describes Firstp1ck behind Caddy and GoDaddy DNS; `docs/superpowers/plans/2026-09-04-pi-webui-custom-domain.md:33` directs work on the old `ai/pi/webui/` implementation. The current supported replacement is native Herdr/Heeler access without a browser backend or reverse proxy (`tools/herdr/README.md:35`), and browser-retirement tests explicitly reject the retired Paseo targets and files (`tests/browser_retirement.bats:9`). These documents now describe a superseded architecture, not pending work.
- Change: remove those two historical documents, about 1,528 lines, retaining history in Git or release storage rather than another tracked archive. Leave current recovery instructions and migration code alone.
- Risk: an operator may still rely on historical configuration or recovery details. Confirm retirement is complete on all active hosts, no open work references these documents, and any needed old recovery instructions are retained outside the active checkout before deleting them. Repository search found no explicit references to either filename outside the ignored historical-document tree; that does not prove external references are absent.

### 3. Give kubectl completion generation one owner
- Evidence: `core/shell/zshrc.symlink:89` synchronously generates and sources kubectl completions. The normal custom loader also recursively sources `tools/` (`core/shell/load-custom.zsh:11`), reaching `tools/kubernetes/k8s.plugin.zsh:17`, which generates the same completions again into a cache in the background. The plugin also sets completion bindings and aliases, so deleting it wholesale would lose functionality.
- Change: consolidate on one completion path, removing roughly four to ten duplicate lines. Prefer dropping the direct zshrc generation only after verifying that the cached path is created and available to completion lookup on first launch; retain aliases and bindings.
- Risk: first-shell completion could fail if the cache directory or search path is missing. Check fresh and populated caches, both with and without zsh-defer, and completion for both `kubectl` and `k`. Use a stub that counts generation calls to confirm one invocation per startup. None of these runtime checks was performed here.

### 4. Stop testing the exact spelling of an illustrative decision record
- Evidence: `tests/lane_coordinator.bats:204` requires the exact sentence and example path `Full record: reports/decision.md`. The actual policy is to keep a short decision with a pointer to its full record, which may be a session file, lane report or archive (`ai/marketplace/plugins/my/skills/lane-coordinator/SKILL.md:93`). The broader test also checks many literal phrases (`tests/lane_coordinator.bats:186`), so harmless template rewrites can require synchronized test edits without changing that policy.
- Change: replace the exact example-sentence assertion with a check that a decision example contains a record pointer, regardless of illustrative filename; roughly one line removed and two to five added. Keep checks for substantive authority, budgets and required sections, and retain the actual launch-projection behavior test at `tests/lane_coordinator.bats:209`.
- Risk: weakening all prose assertions would hide policy loss. Limit this change to incidental wording, and verify that removing the record pointer fails the revised check while renaming its example file passes.

## Checked, nothing to do
- Public command inventory: `tests/repository_hygiene.bats:188` preserves the six-command surface and intentional `gh` override; no inventory change proposed.
- Pi installation: `ai/pi/install.sh:110` rejects production publication from a noncanonical checkout, and `ai/pi/install.sh:833` runs native extension reconciliation from an empty temporary directory. These safeguards should stay.
- Mutable Pi ownership: `ai/pi/install.sh:341` refuses normal permission publication with active YOLO; runtime-control preservation and the narrow legacy-sandbox exception are deliberate, not generic cleanup candidates.
- Validation is static only: no commands, tests, network checks or live rollout were run. The PR's CI must validate the four documentation fixes.
