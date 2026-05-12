# Personal Claude overlay coexisting with tracked project config

**Status:** Design — approved 2026-05-11
**Affects:** `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`,
`bin/claude-link-project`, `bin/setup-agent-teams`,
`core/git/gitignore.symlink`

## Problem

The current `my:project-claude-setup` skill assumes the project worktree
is roughly empty of Claude config — it scaffolds an overlay in
`~/.dotfiles/projects/<slug>/` and symlinks `CLAUDE.md` + `.claude/`
into the project tree. When the project already tracks any of:

- `CLAUDE.md` / `AGENTS.md`
- `.claude/` (skills, commands, settings.json, settings.local.json)
- `.devcontainer/docker-compose.override.yml`

…the skill's only recourse is to bail or ask the user to rename the
project's tracked files. That's wrong: the project's tracked config is
*shared team config* and must stay untouched. Personal overlays should
live *alongside* it, using documented Claude Code mechanisms.

Three real-world examples drove this design (all from `~/workspace/`):

| Project | CLAUDE.md | AGENTS.md | `.claude/` tracked? |
|---|---|---|---|
| slabledger | tracked (11K) | tracked (616B) | skills/, overnight-config, devcontainer present |
| cronfoundry | none | none | only `.claude/commands/dogfood-*.md` tracked |
| headlamp | tracked (4.5K) | tracked (21K) | no tracked content |

## Invariants

1. **Tracked files are never renamed, replaced, or shadowed.** Personal
   overlays go alongside, using documented coexistence mechanisms.
2. **The dotfiles repo at `~/.dotfiles/projects/<slug>/` remains the
   master copy.** In-project artifacts are symlinks or 1-line import
   shims pointing at the overlay.
3. **`git status` in the project stays clean** — global gitignore
   patterns cover every artifact the skill creates in the project tree.

## CLAUDE.md / AGENTS.md coexistence

**Mechanism:** Claude Code's documented `CLAUDE.local.md` + `@~/` import.
`CLAUDE.local.md` is loaded alongside `CLAUDE.md` at every session
(documented at code.claude.com/docs/en/memory) and is the canonical
"personal project-specific notes that shouldn't be committed" channel.

**Layout:**

- Overlay (master): `~/.dotfiles/projects/<slug>/CLAUDE.md` — real
  content here. Empty at scaffold time; user fills in over time.
- Project (symlink target): `<project>/CLAUDE.local.md` — single line:
  `@~/.dotfiles/projects/<slug>/CLAUDE.md`
  Implemented as a regular file (not a symlink) since the content is a
  one-line import string and a real file survives `/init` runs and
  worktree-aware tooling more predictably.

**Why not symlink `CLAUDE.local.md` directly to the overlay?** Either
works, but a real file with `@~/` import is more portable (no broken
symlinks if dotfiles are reorganized; survives `find -L` traversals
inside CI).

**`AGENTS.md` analog:** symmetric. If a personal `AGENTS.md` overlay
exists in `~/.dotfiles/projects/<slug>/AGENTS.md`, create
`<project>/AGENTS.local.md` with `@~/.dotfiles/projects/<slug>/AGENTS.md`.
But: Claude Code reads CLAUDE.md, not AGENTS.md. AGENTS.local.md is
included primarily for tooling parity (other agents that read AGENTS.md
will see a personal layer if present). Default: don't create
AGENTS.local.md unless the user asks.

**Skip behavior:** if the project has no tracked CLAUDE.md, fall back to
the old behavior — symlink `<project>/CLAUDE.md` → overlay's CLAUDE.md
directly. The `.local.md` route is only needed when there's a tracked
file to coexist with.

## `.claude/` directory coexistence

**Mechanism:** per-file symlinks into the existing `.claude/` directory.
No directory-level symlink, ever.

**Rationale:** uniform mental model across all project shapes —
slabledger's rich tracked skills, cronfoundry's mixed mode, headlamp's
empty .claude/, and projects with no .claude/ at all. The skill never
has to flip between "directory symlink" and "per-file" based on what's
tracked today (which can change).

**Layout — overlay master:**

```text
~/.dotfiles/projects/<slug>/.claude/
├── settings.local.json          # personal allowlist additions
├── agents/<name>.md             # personal agents (scaffolded on request)
└── (commands/, rules/ — future)
```

**Layout — in project (all symlinks pointing into the overlay):**

```text
<project>/.claude/
├── settings.local.json          # symlink (if not tracked) — see below
├── agents/<name>.md             # one symlink per personal agent
└── (whatever else the project tracks, untouched)
```

**`.claude/settings.local.json` handling — three cases:**

1. **File does not exist in project:** symlink overlay's
   `settings.local.json` in. Standard case.
2. **File exists and is untracked** (the documented convention — the
   filename literally ends in `.local`): merge personal allowlist
   entries into the existing file using `jq` dedupe, show diff, write.
   Don't symlink (would clobber the user's existing local entries).
3. **File exists and is tracked** (rare; project author committed it by
   mistake or by deliberate convention): merge as in case 2, but warn
   "this will appear in `git diff` — decide whether to commit, stash,
   or revert after review." Don't refuse; the user owns the decision.

**`.claude/settings.json` handling:** never write to it. It's
project-shared. Personal allowlist entries always go to
`settings.local.json` per Claude Code's documented merge order.

**Agent collisions:** when offering to scaffold a personal agent, if the
proposed filename would collide with a tracked file (e.g., project
already has `.claude/agents/test-runner.md` checked in), the skill
refuses and asks the user to pick a different name. No auto-prefixing.

## docker-compose.override.yml coexistence

**Mechanism:** merge into the existing override file (when present)
using `yq`. The current skill's "write override file" path remains for
projects with no existing override.

**Logic:**

1. **No existing override at the base-compose-file dir:** write our
   template directly at the project override path. This is an in-place
   create — the file is a real file in the project worktree (gitignored
   or not depending on project convention), not a symlink to the
   overlay.
2. **Existing override (tracked or not):** parse with `yq` and perform
   an **in-place merge** into the project override file — append +
   dedupe `volumes`, deep-merge `environment` keys (set without
   overwriting unrelated keys). Show unified diff before writing.
3. If yq isn't installed, bail with install hint. `setup-agent-teams`
   gains a yq-install block (alongside tmux/win32yank).

**Comment loss:** `yq` does not preserve YAML comments. The diff makes
this visible; user accepts or aborts. This is the honest tradeoff for
having a tool that can structurally merge.

**Tracked override case:** merging into a tracked file means `git diff`
will show changes in the project after the skill runs. The skill warns
about this explicitly before writing. User decides whether to commit,
.gitignore the file, or revert.

**Why not a separate `.claude.override.yml` file via the
`dockerComposeFile` array?** Compose supports multi-file overrides via
an array in `devcontainer.json`, but `devcontainer.json` is itself
tracked. Editing it would create the same problem one level up. The
in-place merge keeps the modification scope to a single file the user
can clearly evaluate.

## Global gitignore additions

`~/.dotfiles/core/git/gitignore.symlink` must cover everything the skill
creates in project trees so `git status` stays clean:

- `CLAUDE.md` (already covered)
- `.claude/` (already covered — this also catches every file under it)
- `CLAUDE.local.md` (new — add)
- `AGENTS.local.md` (new — add)

`.devcontainer/docker-compose.override.yml` is project-specific (some
projects track it, some don't) — not adding it to the global ignore.

## Skill control flow (revised)

Replacing the current "stop and ask the user to rename files" prereqs:

1. **Verify environment** (WSL host, in a git repo, dotfiles present).
   Unchanged.
2. **Classify the devcontainer setup.** Unchanged (case a/b/c).
3. **Inspect the project.** Unchanged.
4. **Create the dotfiles overlay** via `claude-link-project --create`.
   Unchanged.
5. **Wire up CLAUDE.md/AGENTS.md:**
   - For each of CLAUDE.md, AGENTS.md:
     - Project has tracked file → create `<file>.local.md` with `@~/`
       import (skip if already exists).
     - No project file → symlink overlay's into project (legacy path).
6. **Wire up `.claude/` per-file:**
   - For each item in the overlay's `.claude/` (agents/*.md, future:
     commands/*.md, rules/*.md, settings.local.json):
     - Resolve target = `<project>/<relative-path>`.
     - If target does not exist → symlink overlay → target.
     - If target is a symlink into our overlay → already done, skip.
     - If target is a symlink elsewhere → warn, skip.
     - If target is a real file:
       - Is it tracked? → for `settings.local.json` specifically:
         merge + diff + warn-about-git-diff. For any other path that
         the overlay tries to symlink onto: refuse with a clear error
         ("the project tracks this file; rename your overlay item or
         skip this entry"). The user picks a new name for the overlay
         file and re-runs.
       - Not tracked? → for `settings.local.json`: merge + diff
         (standard case). For anything else: prompt
         move-aside-and-link / keep-and-skip.
7. **Compose override** (case a): if no existing override → write
   ours; symlink. If exists → yq-merge, diff, warn-about-git-diff.
8. **Starter agents (optional, ask)** — unchanged, with the collision
   rule from step 6 applied.
9. **Final verification.** Run `git status` inside the project; should
   show no new files.

## What this removes from the current skill

The Prerequisite 5 ("project tracks its own CLAUDE.md / AGENTS.md")
abort-or-rename gate goes away. So does Step 4's `/init` reminder
phrased as "the placeholder is empty by design" — now the overlay's
CLAUDE.md is supplementary, not a stand-in for the project's CLAUDE.md.

The `--no-claude-md` flag on `claude-link-project --create` becomes
redundant in the long run (it's a special-case for the now-removed
"shadow the project's CLAUDE.md" path) but staying backwards-compatible
is cheap — leave the flag in place, ignore it when `<file>.local.md`
mode is used.

## Out of scope

- Per-project `~/.claude/projects/<...>/memory/` (auto memory). That's
  machine-local and Claude Code manages it; the skill doesn't need to
  touch it.
- Centrally managed `.claude/rules/` symlinking patterns. Possible
  follow-up; not needed for current cases.
- Devcontainer cases (b) Dockerfile-only and (c) no devcontainer remain
  unchanged from the current skill.

## Verification on real projects

Design correctness check against the three surveyed projects:

- **slabledger**: tracked CLAUDE.md/AGENTS.md → both go via .local.md
  import. `.claude/` tracked content (skills/, overnight-config) is
  untouched. settings.local.json is untracked → symlink it.
  docker-compose.override.yml is tracked with the `~/.gh-guarzo` mount
  → yq-merge our mounts in, show diff, user reviews. ✓
- **cronfoundry**: no CLAUDE.md/AGENTS.md → legacy symlink path. Only
  `.claude/commands/dogfood-*.md` tracked; our personal items go in
  agents/, settings.local.json — no collisions. ✓
- **headlamp**: tracked CLAUDE.md/AGENTS.md → both via .local.md
  import. `.claude/` exists with no tracked content → still per-file
  pattern; settings.local.json is untracked → symlink. ✓
