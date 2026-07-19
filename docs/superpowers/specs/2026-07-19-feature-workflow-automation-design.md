# Feature-Workflow Automation Overlay — Design

**Date:** 2026-07-19
**Status:** Approved with corrections

## Problem

Normal feature work repeatedly requires the same manual prompts: create a linked
git worktree before writing, run `my:blindspot-pass` during discovery, run
`my:polish-core --fix` after implementation, verify again, and finish with
`my:change-explainer`. The personal skill descriptions currently make those
steps mostly opt-in, and the global guidance does not define their exact place
in the Superpowers lifecycle.

## Goal

Keep Superpowers as the workflow spine while adding a shared personal policy:

```text
inspect and clarify
→ enter a linked worktree before the first feature-related write
→ run a risk-scaled blind-spot pass during discovery
→ use the normal Superpowers design, planning, TDD, and review flow
→ run my:polish-core --fix
→ re-run relevant verification
→ explain the completed change
→ finish the development branch
```

The overlay must work as guidance in both Claude Code and Codex. Claude Code
also gets a deterministic edit-tool guard. Superpowers plugin files remain
unchanged.

## Components

### 1. Shared Workflow Policy

Add matching feature-workflow sections to `ai/claude/CLAUDE.md` and
`ai/codex/AGENTS.md`.

The policy requires:

- Repository inspection and clarification may happen in the current checkout.
- Before writing a spec, plan, source, test, config, or documentation for new
  work, enter a linked worktree using `superpowers:using-git-worktrees`.
- If already inside a linked worktree, reuse it rather than nesting another.
- Run `my:blindspot-pass` after initial discovery and requirements clarification,
  but before presenting or locking in the design. This placement avoids
  conflicting with the Superpowers rule that `writing-plans` follows an
  approved brainstorming spec.
- For routine work, summarize blind-spot findings and continue. Pause only when
  unresolved architecture, public-interface, data, migration, security,
  compatibility, deployment, or similarly high-impact decisions could change
  the implementation materially.
- After implementation, run `my:polish-core --fix`, then re-run affected tests
  and other relevant verification before making completion claims.
- Run `my:change-explainer` for non-trivial completed work. Include its five
  knowledge-check questions only for substantial changes.

### 2. Personal Skill Trigger and Behavior Updates

Update the shared personal skills under `ai/marketplace/plugins/my/skills/`:

- `blindspot-pass`: trigger proactively during discovery for non-trivial work;
  distinguish automatic workflow use from a standalone read-only request; and
  encode the risk-scaled pause rule.
- `polish-core`: trigger proactively with `--fix` after non-trivial
  implementation and before final verification or branch completion.
- `change-explainer`: trigger proactively after polish and verification; make
  the knowledge check conditional on substantial scope.

These descriptions are shared by Claude Code and Codex through the `my` plugin.

### 3. Claude Linked-Worktree Guard

Add `ai/claude/hooks/worktree-guard.sh` as a Claude Code `PreToolUse` hook for
`Edit|Write|NotebookEdit`.

The guard determines whether the target repository checkout is a linked
worktree by comparing its resolved git directory and common git directory:

- Primary checkout: git directory equals common directory → deny.
- Linked worktree: git directory differs from common directory → allow,
  regardless of branch name or detached-HEAD state.
- Outside a git repository or on an unexpected detection error → allow.

This intentionally checks worktree topology rather than branch names. A feature
branch in the primary checkout is still denied, while a detached linked
worktree is allowed.

Escape hatches remain available for exceptional recovery:

- `CLAUDE_WORKTREE_GUARD=off` disables the guard for one process/session.
- `~/.claude/worktree-guard-allow` may list explicitly exempted repository
  roots, with `~` expansion and `#` comments.

The installer does not seed exemptions. In particular, `~/.dotfiles` is not
automatically exempted.

The hook is a strong Claude edit-tool guard, not a universal filesystem
sandbox: shell commands and Codex are governed by the shared workflow policy.
The implementation and documentation must not claim otherwise.

## Scaling Rules

- **Trivial:** typo-only or similarly mechanical edits still require a linked
  worktree before writing, but may skip blindspot-pass and change-explainer.
- **Routine non-trivial:** run all phases, continue automatically after a concise
  blind-spot summary, and omit knowledge-check questions.
- **Substantial or high-risk:** run all phases, pause on material unresolved
  decisions, and include exactly five knowledge-check questions in the final
  explanation.

## Verification

- Bats tests prove that primary checkouts are denied even on feature branches.
- Bats tests prove that linked worktrees are allowed on branches and detached
  HEADs.
- Existing allowlist, environment override, new-file, notebook, outside-repo,
  and fail-open cases remain covered.
- Tests verify the Claude hook registration and the presence of matching policy
  markers in both global guidance files.
- Run focused Bats tests, `bash bin/validate-ai --verbose`, formatting/linting,
  and the full `bats tests` suite.

## Out of Scope

- Modifying or forking the Superpowers plugin.
- Pretending Claude hooks can hard-enforce writes made through arbitrary shell
  commands or other tools.
- A `/feature` command or separate orchestrator that duplicates Superpowers.
- A Stop hook that prevents a session from ending.
