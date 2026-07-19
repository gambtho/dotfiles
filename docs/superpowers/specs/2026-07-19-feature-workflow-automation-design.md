# Feature-workflow automation overlay — design

**Date:** 2026-07-19
**Status:** Approved

## Problem

In a normal feature session the user must manually ask for the same steps every
time: `my:blindspot-pass` before implementation, `my:polish-core` and
`my:change-explainer` after, and creating a git worktree before edits. The
skills never auto-fire because their descriptions restrict them to "when the
user explicitly asks", and nothing enforces worktree use.

## Goal

Superpowers keeps providing the spine (brainstorming → writing-plans →
implementation → finishing-a-development-branch). This overlay makes the three
personal skills fire at the correct phases without being asked, and makes
worktree use a hard guarantee rather than a convention.

Superpowers is not replaced or modified. `/using-superpowers` remains
auto-injected at SessionStart by the plugin; typing it stays optional.

## Components

### 1. Worktree guard (hard enforcement)

- New executable `ai/claude/hooks/worktree-guard.sh`.
- Wired in `ai/claude/settings.json` (symlinked to `~/.claude/settings.json`)
  as a **PreToolUse** hook matching `Edit|Write|NotebookEdit`.
- Behavior per invocation:
  1. Resolve the target file path from the tool input; find the git repository
     containing it (or the cwd when no file path applies).
  2. If the path is not inside a git work tree → **allow** (scratchpad,
     `~/.claude` memory, etc.).
  3. Determine the repo's default branch: `git symbolic-ref
     refs/remotes/origin/HEAD` (strip `origin/`), falling back to `main` if it
     exists, else `master`.
  4. If the currently checked-out branch equals the default branch → **deny**
     (PreToolUse `permissionDecision: deny`) with a message instructing Claude
     to create a worktree first via `superpowers:using-git-worktrees`.
  5. Otherwise → allow.
- Escape hatches:
  - `~/.claude/worktree-guard-allow`: one repo path per line; listed repos are
    always allowed. Seeded with `~/.dotfiles` (edited directly on main by
    design).
  - `CLAUDE_WORKTREE_GUARD=off` disables the guard for a session.
- Tested with bats in `tests/` following existing test conventions
  (`tests/*.bats`).

### 2. Skill description rewrites (auto-triggering)

Rewrite the `description:` frontmatter of three skills under
`ai/marketplace/plugins/my/skills/` so they trigger on workflow phase instead
of explicit request:

- **blindspot-pass** — trigger after requirements are understood (e.g. after
  brainstorming) and before writing an implementation plan or starting
  substantial implementation; run proactively without being asked. Explicit
  requests still trigger it.
- **polish-core** — additionally trigger proactively with `--fix` after
  completing implementation, before change-explainer or a PR.
- **change-explainer** — trigger after completing a non-trivial change, before
  finishing the branch or opening a PR; run proactively.

Skill bodies are unchanged except where a sentence assumes explicit invocation.

### 3. Injected workflow contract

- New `ai/claude/hooks/feature-workflow-contract.sh` wired as a **SessionStart**
  hook in `ai/claude/settings.json`, emitting a ~10-line contract as
  additional context (same mechanism superpowers uses):

  > For non-trivial feature work: worktree before edits (hook-enforced) →
  > `my:blindspot-pass` between brainstorming and writing-plans → implement →
  > `my:polish-core --fix` → `my:change-explainer` →
  > `superpowers:finishing-a-development-branch`. Trivial changes (typos,
  > small fixes) skip blindspot-pass and change-explainer.

- Contract text lives in `ai/claude/feature-workflow.md` so it can be edited
  without touching the script.

## Decisions

- **Polish runs with `--fix`** in the pipeline (matches `my:polish-pr`
  behavior), not report-only.
- **Scaling rule:** trivial changes skip blindspot-pass and change-explainer,
  mirroring the global CLAUDE.md "scale the workflow to the task" principle.
- **Extend superpowers, don't wrap it:** no `/feature` orchestrator command; the
  overlay hooks into phases superpowers already sequences.
- **Two reinforcing soft signals** (descriptions + injected contract) for skill
  triggering; hard enforcement only for the worktree rule, where a
  deterministic hook is possible.

## Error handling

- The guard fails **open** on unexpected errors (e.g. git not available,
  detached HEAD): a broken hook must not lock the user out of editing. Detached
  HEAD counts as "not on the default branch" → allow.
- Deny messages must name the exact remedy (create a worktree; or add the repo
  to `~/.claude/worktree-guard-allow` if it is intentionally edited on its
  default branch).

## Testing / verification

- Bats tests for `worktree-guard.sh`: deny on default branch, allow on feature
  branch, allow outside a repo, allow via allowlist, allow via env var,
  fail-open on git errors.
- Manual: start a new session, confirm the contract appears; attempt an edit on
  a main-branch repo, confirm denial message; confirm ~/.dotfiles is exempt.

## Out of scope

- No Stop-gate hook forcing polish/change-explainer before ending a turn.
- No changes to superpowers plugin files or its SessionStart injection.
- No changes to the `/polish`, `/polish-pr`, `/fix-pr`, `/review-prs` commands.
