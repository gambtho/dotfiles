# Split `projects/` into a private repo

**Date:** 2026-08-03
**Status:** approved, ready for planning

## Problem

`gambtho/dotfiles` is a **public** repo. 51 files under `projects/` are tracked
and published. Every project they overlay is non-public.

The public dotfiles repo is therefore the most detailed public description of
those codebases. Nothing published is a credential, but a Claude overlay is a
precise internal map *by design*: it exists to tell an agent where the module
boundaries and security boundaries are, which invariants matter and what breaks
when they are violated, which environment variables are load-bearing and which
cannot be rotated, how deploys and migrations run, and where the operational
secret inventory lives. That is useful to an agent working in the repo and
useful in a different way to anyone else who reads it.

The specifics — which projects, which files, which invariants — are deliberately
not reproduced here: this spec is itself tracked in the public repo, so quoting
the evidence would reproduce the exposure it argues against. The unredacted
audit is kept outside the repository; see Assumptions.

### Secondary problem: a live secret one gitignore line from publication

One overlay's `.claude/settings.local.json` contains a real API token, captured
verbatim inside a `Bash(export …)` permission-allowlist entry. Neither the value
nor the file is named here — see Step 0, which rotates it.

`git log --all -- 'projects/*/.claude/settings.local.json'` confirms it was
**never committed** — the ignore rule held. But it demonstrates the failure mode
live: Claude appends whole command lines to the permission allowlist, secrets
included, and the only thing between that and a public repo is one line at the
end of a three-deep negation stack in `.gitignore`
(`!projects/*/.claude/`, `!projects/*/CLAUDE.md`, then re-ignoring
`settings.local.json`). One reordering or one `git add -f` publishes it.

### Tertiary problem: the skill's threat model is internally inconsistent

`SKILL.md:320` reasons carefully about *not* mounting all of `~/.claude` into a
container, because read-only still means readable and it would expose
`.credentials.json` and session transcripts. The same care is not applied to the
git remote: `SKILL.md:676` closes the flow by instructing
`git add "projects/$SLUG" && git commit` — publishing each new overlay.
`projects/README.md:101` frames the risk as secrets-only, which is the narrower
half of the problem.

## Decisions taken

| Decision | Choice | Rationale |
|---|---|---|
| Already-published history | **Stop the bleeding only.** No rewrite. | 15 commits, first 2026-05-11 (~3 months). Exposure is architecture description, not credentials. Repo has 1 fork a rewrite could not clean, and GitHub keeps unreachable objects addressable until support GCs them. Force-push cost exceeds the benefit. |
| Does the public repo reference the private one? | **No. Local config only.** | The private repo's name is itself part of what should not be published. |
| Track `settings.local.json` in the private repo? | **No, stay gitignored.** | Private-on-GitHub is not a safe place for secrets: still in history, readable by anyone granted access, and "private" can be flipped. The file found in this audit proves Claude writes real tokens there unprompted. Accepted cost: permission allowlists do not sync across machines. |
| Split mechanism | **Nested plain clone at `~/.dotfiles/projects/`.** | See below. |
| Attach config location | **`$HOME/.dotfiles-projects-remote`**, outside the repo. | See below. |

### Why a nested plain clone, not a submodule or a sibling

`bin/claude-link-project:39` is `OVERLAY_ROOT="$DOTFILES/projects"`, and every
downstream comparison keys off the home-independent `projects/<slug>/…` tail —
the link-repair logic at `:180`, the suffix checks at `:265` and `:551`, and
`ai/claude/hooks/overlay-sync.sh:56-81`. Keeping the path means **none of that
code changes**. The `/opt/dotfiles` stable-link-root design, the devcontainer
seed, and the dangling-link fix all keep working untouched. The split becomes git
plumbing and docs, not a rework of the overlay system.

- **Submodule** — same path, but `.gitmodules` is tracked in the public repo, so
  it publishes the private repo's URL and name. Ruled out by the "leaks nothing"
  decision. Also adds detached-HEAD friction to a directory edited constantly.
- **Sibling `~/.dotfiles-private/projects/` + symlink** — `/opt/dotfiles`
  resolves to the dotfiles checkout, so `/opt/dotfiles/projects` would become a
  symlink crossing out of it. The container's `/opt/dotfiles` points at its own
  checkout where the sibling does not exist. This reintroduces exactly the
  dangling-link class the stable-link-root design was built to eliminate.

### Why the attach config lives at `$HOME`, not in the repo

1. **Its content is the thing we decided must not be published.** Putting it
   in-repo means a gitignore rule is again the only defense — the same mechanism
   judged too thin for `settings.local.json`, and whose fragile negation stack
   this change removes.
2. **`git clean -xdf` silently eats it.** Verified: `git clean -xdf` removes a
   plain ignored file but *skips* a nested repo (git refuses to delete a
   directory containing `.git` without a second `-f`). So the config would vanish
   while `projects/` survived — a quiet failure surfacing later as an empty
   overlay directory with no obvious cause.
3. **The devcontainer seed mounts `~/.dotfiles` at `/host-seed/.dotfiles:ro`**
   (`SKILL.md:320`), so an in-repo config becomes readable inside every seeded
   container. Nothing there needs it; the container never clones the overlay repo.

The precedent argument resolves the same way once the two existing patterns are
separated by what they hold: `core/git/gitconfig.local.symlink` is in-repo and
holds name/email — personal, not the asset under defense.
`$HOME/.dotfiles-profile` is outside the repo and holds a machine-identity
decision that should not travel with it. This file is the second kind.

Accepted cost: no in-place `.example` sibling. Mitigated by `bin/bootstrap`
printing the exact line to write, and by `docs/guides/project-overlays.md`.

## Design

### Repo boundary

Private repo — referred to throughout as `$PRIVATE_REMOTE`; its name is
deliberately not recorded here — cloned to `~/.dotfiles/projects/`:

```
<private repo>/             → cloned at ~/.dotfiles/projects/
  README.md                 # short: what this is, how it attaches
  .gitignore                # */.claude/settings.local.json
  <slug>/                   # one directory per overlaid project
```

Public repo `.gitignore` — one line replacing the three-deep negation stack:

```gitignore
# projects/ is a separate PRIVATE repo cloned into this path. Per-project
# overlays describe the internals of non-public codebases, so they must not
# be published here. See docs/guides/project-overlays.md.
projects/
```

Collapsing the negation stack is a safety gain independent of the split: the
current stack only holds because the re-ignore line sits last.

The outer repo ignores `projects/`, so the inner repo is invisible to it — no
gitlink, no `.gitmodules`. The inner repo needs no awareness of the outer.

### Attach flow

`$HOME/.dotfiles-projects-remote` — one line, the clone URL. No gitignore rule
anywhere.

`bin/bootstrap` gains `setup_projects_overlay`, called after `install_dotfiles`.

**The clone target is `$HOME/.dotfiles/projects`, written explicitly — never a
relative `projects/` or one derived from `$DOTFILES_ROOT`.** `bin/bootstrap:278`
documents exactly this trap for `ensure_stable_link_root`: bootstrap deliberately
supports invocation from a disposable linked worktree, and `$DOTFILES_ROOT` is
wherever the script was run from. Cloning relative to it would attach the overlay
to a worktree that later gets deleted, while `/opt/dotfiles` — and therefore
every overlay symlink — still points at the canonical checkout, leaving
`~/.dotfiles/projects` empty.

Branches, in order:

1. `$HOME/.dotfiles/projects/.git` exists → log and skip (idempotent re-bootstrap)
2. `$HOME/.dotfiles/projects` exists, is non-empty, and is **not** a git repo →
   warn and skip. `git clone` into a non-empty directory fails on every
   subsequent run, so retrying is pointless noise; and the directory may hold
   ignored `settings.local.json` files that must not be destroyed. Tell the user
   to move it aside, and stop.
3. `$HOME/.dotfiles-projects-remote` exists → `git clone <url>
   "$HOME/.dotfiles/projects"`; on failure, warn and continue
4. Absent → log at info level, print the exact line to write, continue

**Never fatal in any branch.** A fresh clone of the public dotfiles by anyone
(including the existing forker) must bootstrap cleanly to an empty `projects/`,
and every overlay path degrades to "no overlay for this project" — which the
linker already handles.

Tests for `setup_projects_overlay` (`tests/bootstrap_projects_overlay.bats`,
using the existing `setup_dotfiles_test` fixture harness):

- absent config → non-fatal, prints the configuration hint, `projects/` untouched
- config present, clone succeeds → repo attached at the canonical path
- already a git repo → skipped, existing clone not re-cloned or modified
- pre-existing non-repo directory with content → warns, skips, **content
  preserved** (specifically an ignored `settings.local.json`)
- clone failure (unreachable remote) → warns, bootstrap still exits 0
- invoked from a linked worktree → clones to `$HOME/.dotfiles/projects`, not to
  the worktree's `projects/`

Step 6's boundary assertion covers the public repo's index; it does **not**
exercise this function. These are separate concerns in separate suites —
`repository_hygiene.bats` for the invariant, a dedicated file for the attach
behavior.

### Migration

**Every step below names the repository it runs in.** An earlier draft of this
spec authored the private repo's `.gitignore` while the shell was still in the
public checkout — which would have rewritten the *public* root `.gitignore` and
never pushed anything private. Ambiguous cwd is the failure mode this section is
structured against; do not collapse the annotations.

`$PRIVATE_REMOTE` stands for the private repo's clone URL throughout. **It is
never written literally in this document** — see the note under Assumptions.
Export it once per shell:

```bash
PRIVATE_REMOTE="$(cat ~/.dotfiles-projects-remote)"   # after Step 1 creates it
```

**Step 0 — rotate the live token.** *(no repo; the credential itself.)*
It was never committed but is about to be copied by the migration. Rotate it at
its source, then delete the allowlist entry from the affected overlay's
`.claude/settings.local.json`. The affected overlay is named in the untracked
record, not here.

**Step 1 — seed the private repo from history.** *(runs in: **public** repo,
`~/.dotfiles`.)*

```bash
git subtree split -P projects -b projects-only
gh repo create <owner>/<name> --private        # name not recorded here
git push "$PRIVATE_REMOTE" projects-only:main
printf '%s\n' "$PRIVATE_REMOTE" > ~/.dotfiles-projects-remote
```

`subtree split` preserves blame and authorship. The history is private-only and
is the same content already public, so carrying it adds no new exposure.

**Step 2 — stash the working tree and clone.** *(runs in: **public** repo.)*

```bash
PRESWAP="$(mktemp -d)/projects"          # never a fixed path — see below
mv projects "$PRESWAP"
echo "preswap: $PRESWAP"                 # record it; keep until Step 7 verifies
git clone "$PRIVATE_REMOTE" projects
diff -r --exclude=.git "$PRESWAP" projects
# expect exactly: settings.local.json files, present only in $PRESWAP
```

`mktemp -d`, not a fixed `/tmp/projects-preswap`: if that path already exists —
an aborted earlier run is the obvious way — `mv` moves the directory *inside* it
as `/tmp/projects-preswap/projects`, and every later command silently addresses
the wrong tree while the diff compares nothing useful. **Keep `$PRESWAP` until every step below verifies**; it is the only copy of the ignored local settings.

**Step 3 — author the private repo's `.gitignore` and README.** *(runs in:
**private** repo, `~/.dotfiles/projects` — `cd` into it.)*

There is **no `projects/.gitignore` today**, tracked or untracked; the current
protection lives entirely in the public repo's `.gitignore`. `subtree split`
cannot carry one, so the private repo starts with **no ignore rule at all**.
Restoring `settings.local.json` before this exists would leave those files
untracked-but-not-ignored: visible in `git status`, one `git add -A` from
committing the token. This step is what implements the "keep it gitignored"
decision; without it that decision is not merely unimplemented but inverted.

```bash
cd ~/.dotfiles/projects                  # the PRIVATE repo
printf '*/.claude/settings.local.json\n' > .gitignore
# replace the inherited README with the short "what this is / how it attaches"
# version; its long-form content is moving to the public repo in Step 5
$EDITOR README.md
git add .gitignore README.md
git commit -m "ignore per-project local settings; scope README to this repo"
git push
```

**Step 4 — restore the ignored local settings.** *(runs in: **private** repo.)*
Only after Step 3's `.gitignore` is committed.

```bash
cd ~/.dotfiles/projects
for f in "$PRESWAP"/*/.claude/settings.local.json; do
  slug="$(basename "$(dirname "$(dirname "$f")")")"
  cp "$f" "$slug/.claude/settings.local.json"
done
git status --short                       # must be empty
```

A non-empty `git status` here means the ignore rule did not match — stop and fix
it before continuing, because the next `git add -A` in this repo would commit a
token.

**Step 5 — detach in the public repo.** *(runs in: **public** repo.)*

```bash
cd ~/.dotfiles
git rm -r --cached projects/     # untrack; leaves the clone on disk
mkdir -p docs/guides
cp "$PRESWAP/README.md" docs/guides/project-overlays.md
git add docs/guides/project-overlays.md
```

A plain `cp` from `$PRESWAP`, not `git mv` and not a copy from `projects/`: the
clone's README was replaced in Step 3, and `projects/` is now a *different*
repo that `git mv` cannot reach into.

`docs/guides/` must be unignored first, or the `git add` silently no-ops.
`.gitignore:10` is `docs/*`, so `docs/` today tracks only superpowers plans and
specs — verified with `git check-ignore -v docs/guides/project-overlays.md`. The
public `.gitignore` therefore takes **two** changes in this migration: the
`projects/` collapse, and

```gitignore
!docs/guides/
!docs/guides/*.md
```

which establishes a home for tracked prose documentation rather than a
one-file exemption, so the next doc added does not hit the same trap.

**Step 6 — guard the public/private repository boundary.** *(runs in: **public**
repo.)* Add an assertion to the existing `tests/repository_hygiene.bats` that
`git ls-files projects/` is empty in the real checkout. Runs in CI via the
existing `make check` → `make test` → `bats tests`.

This is not a resurrection guard. It asserts the central security invariant of
this design directly: **the public repository must never track anything under
`projects/`.** That invariant is the entire point of the split, it holds
permanently rather than during a migration window, and it is cheap and exactly
testable — three lines against the real index.

It belongs in `repository_hygiene.bats` rather than a dedicated file: that suite
already asserts index-level invariants in precisely this shape (no editor
backups, no Python bytecode, no oversized blobs, all via `git ls-files` against
`$REPO_ROOT`), and this is another instance of the same class, not a new one.

Ways the invariant could be broken — examples, not the rationale: a stray
`git add -f`, a mistaken conflict resolution that re-adds the path, or a future
`.gitignore` edit that reopens it. The assertion is worth keeping even if none
of these ever occurs, because it is what makes the invariant checkable at all.

**Step 7 — worktrees. Re-run this audit immediately before migrating; do not
trust the numbers below.** The inventory is live state, not a durable fact:
it went from 9 worktrees to **12** during the writing of this spec, as concurrent
sessions created `dev-workspace-platform-spec`, `seed-drift-detector`, and
`private-projects-repo`. Treat any count here as a snapshot that is probably
already wrong.

As audited on 2026-08-03 (7 under `.claude/worktrees/`, 4 under
`/tmp/dotfiles-worktrees/`, plus the primary checkout): **no action needed for
correctness, and no merge risk exists.** Verified with two-dot diffs against
main — every branch has *zero* `projects/` files that main lacks. They only lack
files main has, being stale relative to the overlay additions.
`guarzo/stable-link-root` is already squash-merged; `main..branch` lists commits
whose content is in main, and its `projects/README.md` is byte-identical.

The re-run checks for the one case that does reintroduce files: a branch that
**modifies** an overlay file. Merely being cut from a pre-split commit is not
enough — a normal merge leaves files deleted on main deleted, because the branch
side is unchanged there and contributes nothing to resolve. What would carry
content back is a branch that touched `projects/` after branching, where the
merge sees a real modify-vs-delete conflict and a mistaken resolution restores
the file. Re-audit with:

```bash
git worktree list
for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
  printf '%-45s added-by-branch: ' "$b"
  git diff --diff-filter=D --name-only "$b" main -- projects/ | wc -l
done
```

Any non-zero in the second column is a branch that would reintroduce overlays.

The residual item is physical, not git: each worktree directory holds an on-disk
copy of the private overlay content inside the public checkout. Harmless
locally, but they will not track the private repo and will drift. Worth pruning
opportunistically; not a blocker.

### Change surface

| File | Change |
|---|---|
| `.gitignore` (public) | Two changes: replace the `projects/` negation stack with `projects/`; add `!docs/guides/` + `!docs/guides/*.md` |
| `.gitignore` (private, **new**) | `*/.claude/settings.local.json` — does not exist today; authored in Step 3 |
| `projects/README.md` → `docs/guides/project-overlays.md` | Copy + rewrite (below) |
| `bin/bootstrap` | Add `setup_projects_overlay`, cloning to `$HOME/.dotfiles/projects` explicitly |
| `ai/.../project-claude-setup/SKILL.md:43` | Repoint fallback to `docs/guides/project-overlays.md`; add distinct message for *empty* `projects/` (private repo not attached ≠ dotfiles missing), pointing at `$HOME/.dotfiles-projects-remote` |
| `ai/.../project-claude-setup/SKILL.md:206` | Same README path fix in the generated comment |
| `ai/.../project-claude-setup/SKILL.md:676` | `cd ~/.dotfiles/projects && git add "$SLUG" && git commit …`; surrounding "commit dotfiles changes" wording now covers two repos |
| `bin/claude-link-project` | No code change. Add a comment at `:39` noting the path is a separate private repo |
| `tests/repository_hygiene.bats` | Add one boundary assertion (`git ls-files projects/` empty); no new test file |
| `tests/bootstrap_projects_overlay.bats` | New tests for `setup_projects_overlay` (six cases listed above) |
| `README.md` | Check for `projects/` mention; document the two-repo split |

`docs/guides/project-overlays.md` additionally gains: the two-repo model and why; the
`$HOME/.dotfiles-projects-remote` format with the exact line to write; the
`git clean -xdff` warning; and a rewritten Caveats bullet — the current "Don't
put secrets here — this directory is committed to your dotfiles repo" is now both
wrong about the repo and too narrow about the risk. It should say the overlays
describe non-public codebases (which is *why* they live in a private repo) and
that private-on-GitHub still is not a place for secrets.

**No behavior change** to the linker, the stable link root, the overlay-sync
hook, or the devcontainer seed.

### New sharp edge introduced

`projects/` becoming an ignored directory means **`git clean -xdff` in the
dotfiles repo destroys the private repo, including uncommitted overlay edits.**
Plain `-xdf` is safe — git's nested-repo guard skips it (verified). The
double-force variant is not. This must be documented explicitly in
`docs/guides/project-overlays.md`.

## Verification

Baseline before any change: `bats tests` → **323 passing, 0 failures**.

1. `bats tests` — full suite still passes, including the four fixture-isolated
   files that reference `projects` (`claude_link_project.bats`,
   `project_claude_setup_seed.bats`, `overlay_sync_hook.bats`,
   `windows_terminal_profiles.bats`). These use `setup_dotfiles_test`, which
   builds a synthetic `$HOME`, so **no existing test needs changing** — any
   failure indicates a real regression.
2. The `repository_hygiene.bats` boundary assertion fails when `projects/`
   content is force-added (`git add -f`), and passes otherwise.
3. `git ls-files projects/` → empty in the public repo.
4. `git status` in `~/.dotfiles` → clean, no `projects/` noise.
5. Overlay links still resolve: `ls -la ~/workspace/<project>/.claude` for a
   linked project; targets still point through `/opt/dotfiles/projects/<slug>/`.
6. `bin/relink` → still reports the stable root correct.
7. Fresh-clone simulation: clone the public repo to a temp dir with no
   `$HOME/.dotfiles-projects-remote`; `bin/bootstrap` completes non-fatally with
   an empty `projects/`.
8. `make check` (syntax, lint, test, python-test, validate) passes.
9. Every `settings.local.json` present before the migration is present after,
   byte-identical except the removed token entry from Step 0.
10. `git check-ignore -v docs/guides/project-overlays.md` → **no match**, and
    `git ls-files docs/guides/` lists it. Asserting the file is tracked, not just
    present, is the whole point of this check — the original failure was silent.
11. In the private repo: `git check-ignore -v <slug>/.claude/settings.local.json`
    → matches, and `git status --short` is clean after restoring them.

## Assumptions to confirm before implementing

- **Private repo name and host.** Choose them at Step 1. **This document is
  tracked in the public repo**, so the name is not written here — an earlier
  draft named it six times while simultaneously claiming it appeared "never in a
  tracked file." The name should live in exactly two places, both untracked:
  `$HOME/.dotfiles-projects-remote`, and your shell history for Step 1.
  Reviewers should treat any literal remote URL appearing in this file as a
  defect.
- **The unredacted audit lives outside the repository.** The evidence behind the
  Problem section — which projects, which files and line numbers, which
  invariants and environment variables, and which overlay held the live token —
  is recorded in `$HOME/.dotfiles-migration-record/` (untracked, local only).
  The same reasoning that moves `projects/` out of this repo applies to a spec
  that quotes it, so the public copy carries the argument without the evidence.
  Reviewers should treat a project name, internal path, or credential name
  appearing in this file as a defect.
- **Every existing overlay moves.** No per-project opt-out is designed in; they
  go to the private repo together.

## Out of scope

- Rewriting published history (decided against; revisitable separately).
- Scrubbing the existing fork.
- Cleaning up the eight stale worktrees.
- Any change to overlay *content* — this moves files, it does not edit what the
  overlays say.
- A secret-scanning pre-commit hook for the private repo (considered and
  declined with the "keep it gitignored" decision).
