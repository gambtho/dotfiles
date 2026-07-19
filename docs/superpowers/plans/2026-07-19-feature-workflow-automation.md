# Feature-Workflow Automation Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Automatically layer the personal blindspot, polish, and change-
explanation phases around the Superpowers workflow, with linked-worktree use
required before feature-related writes.

**Architecture:** Matching global guidance provides the cross-tool Claude/Codex
policy. Shared personal-skill metadata and bodies define phase triggers and
risk scaling. A Claude Code `PreToolUse` hook adds deterministic protection for
Claude edit tools by detecting linked-worktree topology rather than branch
names.

**Tech Stack:** Markdown skill/guidance files, Bash, `jq`, git, Bats, Claude Code
hooks.

**Spec:** `docs/superpowers/specs/2026-07-19-feature-workflow-automation-design.md`

## Constraints

- Do not modify Superpowers plugin files.
- Preserve the existing personal skill names and command wrappers.
- Do not seed a permanent exemption for `~/.dotfiles`.
- The hook must fail open on missing tools, invalid input, non-repositories, or
  unexpected git errors.
- Do not describe the Claude edit-tool hook as universal enforcement for shell
  commands or Codex.
- Preserve unrelated local changes in the primary checkout.

## Task 1: Correct Linked-Worktree Guard

**Files:**

- Modify: `tests/worktree_guard.bats`
- Modify: `ai/claude/hooks/worktree-guard.sh`

1. Replace the feature-branch allowance test with a regression test proving a
   feature branch in the primary checkout is denied.
2. Add real `git worktree add` fixtures proving linked branch and detached
   worktrees are allowed.
3. Run `bats tests/worktree_guard.bats` and confirm the new primary-feature
   regression fails against the existing branch-based implementation.
4. Replace default-branch detection with resolved git-directory versus
   common-directory comparison.
5. Update the denial message to say the checkout is the primary worktree and
   instruct the agent to use `superpowers:using-git-worktrees`.
6. Run the focused Bats file and confirm all cases pass.

## Task 2: Add Shared Workflow Policy

**Files:**

- Modify: `ai/claude/CLAUDE.md`
- Modify: `ai/codex/AGENTS.md`
- Create: `tests/feature_workflow_policy.bats`

1. Add a failing test that requires matching policy markers in both global
   guidance files: worktree before writes, blindspot during discovery,
   risk-scaled pause, polish with `--fix`, fresh verification, and conditional
   knowledge checks.
2. Run the focused test and confirm it fails before the guidance changes.
3. Add substantially matching `Feature workflow` sections to both files.
4. Run the focused test and `diff` the extracted sections to prevent drift.

## Task 3: Update Personal Skill Phases

**Files:**

- Modify: `ai/marketplace/plugins/my/skills/blindspot-pass/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/polish-core/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/change-explainer/SKILL.md`
- Extend: `tests/feature_workflow_policy.bats`

1. Add failing assertions for proactive phase triggers, the risk-scaled
   blindspot rule, automatic `--fix`, and substantial-only knowledge checks.
2. Run the focused test and confirm the new assertions fail.
3. Rewrite the three descriptions and the minimum necessary body text.
4. Keep standalone explicit invocations supported.
5. Run the focused test and `bash bin/validate-ai --verbose`.

## Task 4: Register the Claude Guard

**Files:**

- Modify: `ai/claude/settings.json`
- Extend: `tests/feature_workflow_policy.bats`

1. Add a failing test that validates the JSON and requires a `PreToolUse`
   `Edit|Write|NotebookEdit` hook pointing at
   `$HOME/.dotfiles/ai/claude/hooks/worktree-guard.sh`.
2. Run the focused test and confirm it fails.
3. Add only the hook registration to settings; do not add an installer-seeded
   allowlist or a redundant SessionStart contract.
4. Re-run the focused test and installer tests.

## Task 5: Refresh the Codex Plugin Cache

**Files:**

- Modify: `ai/codex/install.sh`
- Modify: `ai/marketplace/plugins/my/.codex-plugin/plugin.json`
- Extend: `tests/ai_installers.bats`

1. Add a failing installer test requiring `codex plugin add my@guarzo` after
   the local marketplace configuration is generated.
2. Add a best-effort installer step that refreshes the plugin when the Codex CLI
   is available and logs a warning when it is not.
3. Use the plugin-creator cachebuster helper rather than hand-editing the
   manifest version.
4. Run an isolated real install with a temporary `CODEX_HOME` and confirm all
   seven canonical skills, especially blindspot-pass, polish-core, and
   change-explainer, exist in the installed cache.

## Task 6: Polish and Verify

1. Inspect the complete diff against `main` and compare it to the corrected
   spec.
2. Run `my:polish-core --fix` over the branch changes and review any edits or
   deferred findings.
3. Re-run focused tests after polish.
4. Run `shfmt -d` for changed shell files, `bash bin/validate-ai --verbose`, and
   `bats tests`.
5. Check for accidental exemptions, stale branch-based language, placeholders,
   debug output, and unrelated changes.
6. Run `my:change-explainer`; this change is substantial, so include exactly
   five knowledge-check questions.
