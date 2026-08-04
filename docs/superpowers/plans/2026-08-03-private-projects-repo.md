# Private `projects/` Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `~/.dotfiles/projects/` out of the public dotfiles repo into a separate private repo cloned back to the same path, so per-project Claude overlays describing non-public codebases stop being published.

**Architecture:** A nested plain clone. The public repo ignores `projects/` outright; a private repo is cloned into that exact path. Because `bin/claude-link-project:39` is `OVERLAY_ROOT="$DOTFILES/projects"` and every downstream comparison keys off the home-independent `projects/<slug>/…` tail, keeping the path means the linker, the overlay-sync hook, the `/opt/dotfiles` stable link root, and the devcontainer seed need **no code changes**. `bin/bootstrap` gains one function that attaches the private repo from a machine-local config file.

**Tech Stack:** bash, git (`subtree split`, plain clone), bats + `setup_dotfiles_test` fixture harness, `make check` → `make test`.

**Design spec:** `docs/superpowers/specs/2026-08-03-private-projects-repo-design.md`

## Global Constraints

Every task's requirements implicitly include these. Copied verbatim from the spec.

- **The private repo's name and URL must never appear in a tracked file** in the public repo — the name is itself part of what must not be published. It lives in exactly two places, both untracked: `$HOME/.dotfiles-projects-remote`, and shell history. Referred to throughout as `$PRIVATE_REMOTE`.
- **Every migration command names the repository it runs in.** Ambiguous cwd is the failure mode this plan is structured against; do not collapse the annotations.
- **The clone target is written literally as `$HOME/.dotfiles/projects`** — never a relative `projects/`, never derived from `$DOTFILES_ROOT`. `bin/bootstrap:278-281` documents exactly this trap for `ensure_stable_link_root`: bootstrap supports invocation from a disposable linked worktree, and `$DOTFILES_ROOT` is wherever the script was run from.
- **`setup_projects_overlay` is never fatal in any branch.** It must `return 0` on every path. A fresh clone of the public dotfiles by anyone must bootstrap cleanly to an empty `projects/`.
- **`settings.local.json` stays gitignored in the private repo.** Private-on-GitHub is not a safe place for secrets.
- **The boundary assertion goes into the existing `tests/repository_hygiene.bats`.** Do not create a dedicated test file for it.
- **No behavior change** to `bin/claude-link-project`, `bin/common.sh`'s `ensure_stable_link_root`, `ai/claude/hooks/overlay-sync.sh`, or the devcontainer seed.
- Baseline before any change: `bats tests` → **323 passing, 0 failures**.

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` (public) | Ignore `projects/` outright; unignore `docs/guides/` |
| `bin/bootstrap` | `setup_projects_overlay` — attach the private repo at the canonical path |
| `tests/install_orchestration.bats` | **Modify.** Six new cases for the attach behavior, appended to the existing bootstrap suite |
| `tests/repository_hygiene.bats` | **One added assertion.** The public/private boundary invariant |
| `docs/guides/project-overlays.md` | **New.** The two-repo model, attach config, caveats |
| `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md` | Three edits: `:43`, `:206`, `:676` |
| `bin/claude-link-project` | Comment only at `:39` |
| `README.md` | Structure block + Repository Hygiene bullet |

---

## Task 1: Rotate the live token

**Files:**
- Modify: `projects/<slug>/.claude/settings.local.json` (untracked, on disk only). **This plan is tracked in the public repo**, so the affected overlay is not named here — it is recorded in `$HOME/.dotfiles-migration-record/`. Substitute `<slug>` from there before running any command below.

**Interfaces:**
- Consumes: nothing
- Produces: nothing consumed by later tasks. This is a security gate that must clear before Task 2 copies the file.

This is the one irreversible-in-the-wrong-direction step. The token was never committed — `git log --all -- 'projects/*/.claude/settings.local.json'` confirms it — but Task 2 copies that file, and the value has been sitting in a working-tree file for months.

- [ ] **Step 1: Record the test baseline before anything changes**

```bash
cd ~/.dotfiles
bats tests 2>&1 | tail -3
```

Expected: **323 passing, 0 failures.** If the baseline is already dirty, stop and resolve it — every later failure is ambiguous otherwise.

- [ ] **Step 2: Confirm the entry is still present**

```bash
grep -rl 'export [A-Z_]*TOKEN=' ~/.dotfiles/projects/*/.claude/settings.local.json
```

`-l` prints filenames only: the point is to locate the entry, and echoing the
matching line would put the token in your scrollback and this session's
transcript. Expected: one filename. If absent, it was already handled — skip to Step 5.

- [ ] **Step 3: Rotate the credential at its source**

Issue a new token in the service that owns it and revoke the old one. This is external to the repo; there is no command here. **Do not proceed until the old value is revoked** — deleting the line below removes the copy, not the credential.

- [ ] **Step 4: Delete the allowlist entry**

Edit `~/.dotfiles/projects/<slug>/.claude/settings.local.json` and remove the whole `"Bash(export …TOKEN=\"…\")"` array element, leaving the surrounding JSON valid.

- [ ] **Step 5: Verify the file is valid JSON and clean**

```bash
jq -e . ~/.dotfiles/projects/<slug>/.claude/settings.local.json >/dev/null && echo "valid JSON"
grep -rl 'export [A-Z_]*TOKEN=' ~/.dotfiles/projects/*/.claude/settings.local.json || echo "no matches — good"
```

Expected: `valid JSON`, then `no matches — good`.

- [ ] **Step 6: No commit**

Nothing to commit — this file is gitignored in both repos by design. Record in the session that rotation is done.

---

## Task 2: Create and seed the private repo

**Files:**
- Create: the private repo (remote), and `~/.dotfiles/projects/.gitignore`, `~/.dotfiles/projects/README.md` inside it
- Create: `$HOME/.dotfiles-projects-remote`
- Modify: nothing tracked in the public repo

**Interfaces:**
- Consumes: Task 1's rotation being complete
- Produces: `$HOME/.dotfiles-projects-remote` containing the clone URL, consumed by Task 5's `setup_projects_overlay`; a `~/.dotfiles/projects/` that is a git clone of the private repo, consumed by Task 3

**Runs in: the PUBLIC repo (`~/.dotfiles`) for Steps 1–3, the PRIVATE repo (`~/.dotfiles/projects`) for Steps 4–7.**

- [ ] **Step 1: Seed the private repo from history (PUBLIC repo)**

```bash
cd ~/.dotfiles
git subtree split -P projects -b projects-only
gh repo create <owner>/<name> --private     # choose now; do NOT record it in any tracked file
git push <clone-url> projects-only:main
printf '%s\n' '<clone-url>' > ~/.dotfiles-projects-remote
PRIVATE_REMOTE="$(cat ~/.dotfiles-projects-remote)"
```

`subtree split` preserves blame and authorship. The history is the same content already public, so carrying it adds no new exposure.

- [ ] **Step 2: Stash the working tree (PUBLIC repo)**

```bash
cd ~/.dotfiles
PRESWAP="$(mktemp -d)/projects"
mv projects "$PRESWAP"
echo "preswap: $PRESWAP"

# Manifest for verification item 9 -- every settings.local.json present before
# the migration must be present and byte-identical after.
(cd "$PRESWAP" && find . -name settings.local.json -exec sha256sum {} + | sort) \
  > "$(dirname "$PRESWAP")/locals.sha256"
cat "$(dirname "$PRESWAP")/locals.sha256"
```

`mktemp -d`, never a fixed `/tmp/projects-preswap`: if that path already exists — an aborted earlier run is the obvious way — `mv` moves the directory *inside* it and every later command silently addresses the wrong tree. **Keep `$PRESWAP` until Task 9 verifies**; it is the only copy of the ignored local settings.

- [ ] **Step 3: Clone the private repo into place and diff (PUBLIC repo)**

```bash
cd ~/.dotfiles
git clone "$PRIVATE_REMOTE" projects
diff -r --exclude=.git "$PRESWAP" projects
```

Expected: the only differences are `settings.local.json` files, present in `$PRESWAP` and absent from `projects/`. Any other difference means the split lost content — stop.

- [ ] **Step 4: Author the private repo's `.gitignore` (PRIVATE repo)**

```bash
cd ~/.dotfiles/projects          # the PRIVATE repo
printf '%s\n' '*/.claude/settings.local.json' > .gitignore
```

There is **no `projects/.gitignore` today** — the current protection lives entirely in the public repo's `.gitignore`, so `subtree split` cannot carry one and the private repo starts with **no ignore rule at all**. Restoring `settings.local.json` before this exists would leave those files untracked-but-not-ignored: visible in `git status`, one `git add -A` from committing a token.

- [ ] **Step 5: Replace the inherited README (PRIVATE repo)**

The split carried the old 110-line `projects/README.md` to the private repo's root, while its long-form content is moving to `docs/guides/project-overlays.md` in Task 6. Replace it with a short pointer so the two do not diverge:

```bash
cd ~/.dotfiles/projects
cat > README.md <<'EOF'
# Personal Claude project overlays

Private. Each directory is a per-project Claude overlay — `CLAUDE.md` and
`.claude/` — symlinked into that project's working tree by
`~/.dotfiles/bin/claude-link-project`.

This repo is cloned into `~/.dotfiles/projects/` by `bin/bootstrap`, which reads
the clone URL from `~/.dotfiles-projects-remote`. The public dotfiles repo
ignores this path entirely and does not name this repo anywhere.

These overlays describe the internals of non-public codebases. That is why they
live here rather than in the public dotfiles repo. Private on GitHub is still
not a place for secrets: `*/.claude/settings.local.json` is gitignored, and it
must stay that way — Claude appends whole command lines to those allowlists,
tokens included.

Full documentation: `~/.dotfiles/docs/guides/project-overlays.md`.
EOF
```

- [ ] **Step 6: Commit and push (PRIVATE repo)**

```bash
cd ~/.dotfiles/projects
git add .gitignore README.md
git commit -m "ignore per-project local settings; scope README to this repo"
git push
```

- [ ] **Step 7: Restore the ignored local settings (PRIVATE repo)**

Only after Step 6's `.gitignore` is committed.

```bash
cd ~/.dotfiles/projects
for f in "$PRESWAP"/*/.claude/settings.local.json; do
  [ -e "$f" ] || continue
  slug="$(basename "$(dirname "$(dirname "$f")")")"
  mkdir -p "$slug/.claude"
  cp "$f" "$slug/.claude/settings.local.json"
done
git status --short
```

Expected: **empty output.** A non-empty `git status` means the ignore rule did not match — stop and fix it, because the next `git add -A` in this repo would commit a token.

- [ ] **Step 8: Verify the ignore rule matches**

```bash
cd ~/.dotfiles/projects
git check-ignore -v <slug>/.claude/settings.local.json
```

Expected: a match on `.gitignore:1:*/.claude/settings.local.json`.

---

## Task 3: Detach `projects/` in the public repo

**Files:**
- Modify: `.gitignore` (public) — replace lines 31-41, add `docs/guides/` negation after line 16
- Create: `docs/guides/project-overlays.md` (copied here; rewritten in Task 6)
- Untrack: all 51 files under `projects/`

**Interfaces:**
- Consumes: Task 2's clone at `~/.dotfiles/projects`, and `$PRESWAP`
- Produces: `git ls-files projects/` → empty, the invariant Task 4 asserts; `docs/guides/` as a tracked location, consumed by Task 6

**Runs in: the PUBLIC repo (`~/.dotfiles`).**

- [ ] **Step 1: Record the pre-change tracked count**

```bash
cd ~/.dotfiles
git ls-files projects/ | wc -l
```

Expected: `51`. This is the number about to go to zero.

- [ ] **Step 2: Collapse the negation stack**

Replace `.gitignore` lines 31-41 (the block beginning `# The global ~/.gitignore also hides` and ending with `projects/*/.claude/settings.local.json`) with:

```gitignore
# projects/ is a separate PRIVATE repo cloned into this path by bin/bootstrap.
# Per-project overlays describe the internals of non-public codebases, so they
# must not be published here. See docs/guides/project-overlays.md.
projects/
```

Collapsing the stack is a safety gain independent of the split: the current three-deep negation only holds because the re-ignore line sits last. One reordering publishes `settings.local.json`.

- [ ] **Step 3: Unignore `docs/guides/`**

Insert after `.gitignore:16` (`!docs/superpowers/specs/*.md`):

```gitignore
!docs/guides/
!docs/guides/*.md
```

The parent directory must be re-included before the files — git will not descend into an excluded directory to reach a negated file inside it. `.gitignore:10` is `docs/*`, so without this the `git add` in Step 5 silently no-ops.

- [ ] **Step 4: Untrack `projects/`**

```bash
cd ~/.dotfiles
git rm -r --cached projects/     # untrack; leaves the clone on disk
git ls-files projects/ | wc -l
```

Expected: `0`. The working tree still holds the private clone — verify with `test -d projects/.git && echo "clone intact"`.

- [ ] **Step 5: Seed the public doc from the pre-swap README**

```bash
cd ~/.dotfiles
mkdir -p docs/guides
cp "$PRESWAP/README.md" docs/guides/project-overlays.md
git check-ignore -v docs/guides/project-overlays.md || echo "not ignored — good"
git add docs/guides/project-overlays.md
```

Expected: `not ignored — good`, then a successful add.

A plain `cp` from `$PRESWAP`, not `git mv` and not a copy from `projects/`: the clone's README was replaced in Task 2 Step 5, and `projects/` is now a *different* repo that `git mv` cannot reach into.

- [ ] **Step 6: Verify `git status` is clean of `projects/` noise**

```bash
cd ~/.dotfiles
git status --short | grep -c '^.. projects/' || echo "no projects/ noise — good"
```

Expected: `no projects/ noise — good`.

- [ ] **Step 7: Commit**

```bash
cd ~/.dotfiles
git add .gitignore docs/guides/project-overlays.md
git commit -m "feat: split projects/ overlays into a separate private repo

The public repo tracked 51 files describing the internals of six non-public
codebases. projects/ is now ignored outright and backed by a private repo
cloned into the same path, so the linker and stable-link-root paths are
unchanged. Also collapses a three-deep gitignore negation stack whose only
protection for settings.local.json was line ordering."
```

---

## Task 4: Assert the public/private repository boundary

**Files:**
- Modify: `tests/repository_hygiene.bats` (append after the existing `tracked blobs stay below five megabytes` test at `:73-87`)

**Interfaces:**
- Consumes: Task 3's untracking
- Produces: nothing consumed by later tasks

This asserts the central security invariant directly: **the public repository must never track anything under `projects/`.** It is not a resurrection guard — it holds permanently rather than during a migration window. It belongs in `repository_hygiene.bats` because that suite already asserts index-level invariants in exactly this shape (`:61-71` for editor backups and Python bytecode, both `git ls-files` against `$REPO_ROOT`).

- [ ] **Step 1: Write the assertion**

Append to `tests/repository_hygiene.bats`:

```bash
@test "the public repository tracks nothing under projects/" {
  # projects/ is a separate PRIVATE repo cloned into this path. Its per-project
  # overlays describe the internals of non-public codebases, so anything tracked
  # here is a publication of private content. Breakable by a stray `git add -f`,
  # a mistaken modify-vs-delete conflict resolution, or a .gitignore edit that
  # reopens the path — but the assertion earns its place as the only mechanical
  # check of the invariant, not because any of those is likely.
  run git -C "$REPO_ROOT" ls-files projects/
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run it — expect PASS**

Run: `bats tests/repository_hygiene.bats`
Expected: all tests pass, including the new one. Task 3 already made the invariant true.

- [ ] **Step 3: Negative control — prove the assertion can fail**

A test that passes trivially is worthless. Force-add a file the ignore rule would otherwise block, and confirm the assertion catches it:

```bash
cd ~/.dotfiles
mkdir -p projects/negative-control
echo leak > projects/negative-control/CLAUDE.md
git add -f projects/negative-control/CLAUDE.md
bats tests/repository_hygiene.bats
```

Expected: **FAIL** on `the public repository tracks nothing under projects/`, reporting the force-added path.

- [ ] **Step 4: Undo the control and re-run — expect PASS**

```bash
cd ~/.dotfiles
git rm --cached projects/negative-control/CLAUDE.md
rm -rf projects/negative-control
git ls-files projects/ | wc -l    # expect 0
bats tests/repository_hygiene.bats
```

Expected: `0`, then all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/repository_hygiene.bats
git commit -m "test: assert the public repo tracks nothing under projects/"
```

---

## Task 5: Attach the private repo from `bin/bootstrap`

**Files:**
- Modify: `bin/bootstrap` — add `setup_projects_overlay` after `install_dotfiles` (`:176-203`), call it from `main` after `install_dotfiles` (`:282`)
- Modify: `tests/install_orchestration.bats` (append; it already holds the `BOOTSTRAP_SOURCE_ONLY=1` sourcing pattern these cases reuse)

**Interfaces:**
- Consumes: `$HOME/.dotfiles-projects-remote` written in Task 2 Step 1; the `log_info` / `log_success` / `log_warning` helpers from `bin/log-helper` (already sourced via `bin/common.sh:3`)
- Produces: `setup_projects_overlay()` — takes no arguments, always returns 0, clones to `$HOME/.dotfiles/projects`

This is the only real code in the plan. TDD applies cleanly.

- [ ] **Step 1: Write the failing tests**

Append to `tests/install_orchestration.bats`:

```bash
#!/usr/bin/env bats

# Coverage for bin/bootstrap's setup_projects_overlay.
#
# projects/ is a separate PRIVATE repo cloned into ~/.dotfiles/projects. The
# clone URL is machine-local config at ~/.dotfiles-projects-remote, never
# tracked. This function attaches the repo during bootstrap.
#
# Two invariants dominate these tests:
#   1. NEVER FATAL. A fresh clone of the public dotfiles by anyone must
#      bootstrap cleanly to an empty projects/. Every branch returns 0.
#   2. The clone target is $HOME/.dotfiles/projects, written literally --
#      never derived from $DOTFILES_ROOT, which is wherever bootstrap was run
#      from and may be a disposable linked worktree.

load test_helper

setup() {
  setup_dotfiles_test
  CANONICAL="$HOME/.dotfiles"
  mkdir -p "$CANONICAL"
  REMOTE_FILE="$HOME/.dotfiles-projects-remote"
}

# Builds a real git repo to clone from. Real git, not a stub: the failure modes
# under test (clone into non-empty dir, unreachable remote) are git's, and a
# stub would only assert our own guesses about them.
make_overlay_remote() {
  local remote="$TEST_ROOT/overlay-remote"
  mkdir -p "$remote/demo/.claude"
  git init -q -b main "$remote"
  printf '%s\n' '*/.claude/settings.local.json' >"$remote/.gitignore"
  printf '# demo overlay\n' >"$remote/demo/CLAUDE.md"
  git -C "$remote" add -A
  git -C "$remote" -c user.name=T -c user.email=t@example.com commit -qm init
  printf '%s\n' "$remote"
}

run_setup_projects_overlay() {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; setup_projects_overlay' _ "$REPO_ROOT"
}

@test "absent config is non-fatal and prints the configuration hint" {
  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *".dotfiles-projects-remote"* ]]
  [ ! -e "$CANONICAL/projects" ]
}

@test "a configured remote is cloned to the canonical path" {
  printf '%s\n' "$(make_overlay_remote)" >"$REMOTE_FILE"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [ -d "$CANONICAL/projects/.git" ]
  [ -f "$CANONICAL/projects/demo/CLAUDE.md" ]
}

@test "an already-attached overlay repo is left alone" {
  printf '%s\n' "$(make_overlay_remote)" >"$REMOTE_FILE"
  run_setup_projects_overlay
  printf 'local edit\n' >"$CANONICAL/projects/demo/CLAUDE.md"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [ "$(cat "$CANONICAL/projects/demo/CLAUDE.md")" = "local edit" ]
}

@test "a pre-existing non-repo directory is preserved, not clobbered" {
  # The directory may hold ignored settings.local.json files carrying real
  # permission state. Destroying them to make room for a clone is the worst
  # available outcome, so this branch warns and stops.
  mkdir -p "$CANONICAL/projects/demo/.claude"
  printf '{"permissions":{}}\n' >"$CANONICAL/projects/demo/.claude/settings.local.json"
  printf '%s\n' "$(make_overlay_remote)" >"$REMOTE_FILE"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [ ! -d "$CANONICAL/projects/.git" ]
  [ -f "$CANONICAL/projects/demo/.claude/settings.local.json" ]
  [[ "$output" == *"not a git repo"* ]]
}

@test "an unreachable remote warns but does not fail bootstrap" {
  printf '%s\n' "$TEST_ROOT/no-such-repo" >"$REMOTE_FILE"

  run_setup_projects_overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not clone"* ]]
}

@test "the clone lands in the canonical checkout, not the invoking worktree" {
  # bootstrap deliberately supports invocation from a linked worktree, and
  # $DOTFILES_ROOT is wherever it was run from. Cloning relative to it would
  # attach the overlay to a directory that later gets deleted, while
  # /opt/dotfiles -- and every overlay symlink -- still points at ~/.dotfiles.
  local worktree="$TEST_ROOT/disposable-worktree"
  mkdir -p "$worktree"
  printf '%s\n' "$(make_overlay_remote)" >"$REMOTE_FILE"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; cd "$2"; DOTFILES_ROOT="$2"; setup_projects_overlay' \
    _ "$REPO_ROOT" "$worktree"
  [ "$status" -eq 0 ]
  [ -d "$CANONICAL/projects/.git" ]
  [ ! -e "$worktree/projects" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/install_orchestration.bats`
Expected: all six FAIL with `command not found: setup_projects_overlay` (or bash's equivalent).

- [ ] **Step 3: Write the implementation**

Insert into `bin/bootstrap` after `install_dotfiles` (which ends at `:203`), before `linux_prep`:

```bash
# projects/ is a separate PRIVATE repo cloned into this path. Its per-project
# overlays describe the internals of non-public codebases, so the public repo
# ignores the path outright and never names the private repo. The clone URL is
# machine-local config at $HOME/.dotfiles-projects-remote.
# See docs/guides/project-overlays.md.
setup_projects_overlay() {
  # $HOME/.dotfiles, not $DOTFILES_ROOT: the latter is wherever this script was
  # run from, which may be a disposable linked worktree. Same trap the stable
  # link root documents below -- the overlay must attach to the canonical
  # checkout that /opt/dotfiles points at, or every overlay symlink resolves
  # into a directory that is about to be deleted.
  local overlay_dir="$HOME/.dotfiles/projects"
  local remote_file="$HOME/.dotfiles-projects-remote"
  local remote

  if [ -d "$overlay_dir/.git" ]; then
    log_info "Project overlays already attached at $overlay_dir"
    return 0
  fi

  if [ -d "$overlay_dir" ] && [ -n "$(ls -A "$overlay_dir" 2>/dev/null)" ]; then
    # git clone refuses a non-empty target, so retrying every bootstrap is
    # pointless noise -- and the directory may hold ignored settings.local.json
    # files that must not be destroyed to make room.
    log_warning "$overlay_dir exists, is not a git repo, and is not empty -- leaving it alone"
    log_warning "Move it aside and re-run bootstrap to attach the private overlay repo"
    return 0
  fi

  if [ ! -f "$remote_file" ]; then
    log_info "No project overlay repo configured; skipping"
    log_info "To attach one: printf '%s\\n' '<clone-url>' > $remote_file"
    return 0
  fi

  remote="$(tr -d '[:space:]' <"$remote_file")"
  if [ -z "$remote" ]; then
    log_warning "$remote_file is empty; skipping project overlay clone"
    return 0
  fi

  if git clone "$remote" "$overlay_dir"; then
    log_success "Project overlays attached at $overlay_dir"
  else
    log_warning "Could not clone the project overlay repo; continuing without overlays"
  fi

  # Never fatal: a fresh clone of the public dotfiles by anyone must bootstrap
  # cleanly to an empty projects/, and every overlay path already degrades to
  # "no overlay for this project".
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/install_orchestration.bats`
Expected: 6 passing, 0 failures.

- [ ] **Step 5: Wire it into `main`**

Modify `bin/bootstrap:282`, immediately after `install_dotfiles`:

```bash
  ensure_stable_link_root "$HOME/.dotfiles"
  install_dotfiles
  setup_projects_overlay
```

- [ ] **Step 6: Run the full suite**

Run: `bats tests`
Expected: **330 passing, 0 failures** (323 baseline + 6 new + 1 from Task 4).

- [ ] **Step 7: Commit**

```bash
git add bin/bootstrap tests/install_orchestration.bats
git commit -m "feat(bootstrap): attach the private project-overlay repo

Clones \$HOME/.dotfiles-projects-remote into \$HOME/.dotfiles/projects. The
target is the canonical checkout, never \$DOTFILES_ROOT, which may be a
disposable linked worktree. Never fatal -- a public-repo clone with no
overlay config bootstraps cleanly to an empty projects/."
```

---

## Task 6: Write `docs/guides/project-overlays.md`

**Files:**
- Modify: `docs/guides/project-overlays.md` (created in Task 3 Step 5 as a copy of the old `projects/README.md`)

**Interfaces:**
- Consumes: the file seeded in Task 3
- Produces: the doc path referenced by `.gitignore`, `bin/bootstrap`, and Task 7's `SKILL.md` edits

The seeded copy is the old 110-line README. It documents the layout, the linker, the stable link root, and removal — all still accurate. Four changes make it correct for the two-repo world.

- [ ] **Step 1: Retitle and add the two-repo model**

Replace the opening heading and intro with:

```markdown
# Personal Claude project overlays

Each directory under `~/.dotfiles/projects/` is a per-project Claude overlay —
`CLAUDE.md` and `.claude/` — symlinked into that project's working tree.

**`projects/` is a separate private repo**, cloned into that path. This public
dotfiles repo ignores the path outright and does not name the private repo
anywhere. The overlays describe the module layout, security boundaries, and
operational details of non-public codebases; published together they are a
precise internal map, which is why they live behind a separate boundary.
```

- [ ] **Step 2: Document the attach config**

Add a new section after the intro:

````markdown
## Attaching the overlay repo on a new machine

`bin/bootstrap` reads one machine-local file — it is not in either repo:

```bash
printf '%s\n' '<clone-url>' > ~/.dotfiles-projects-remote
bin/bootstrap        # clones it to ~/.dotfiles/projects
```

Without that file, bootstrap logs the hint and continues. `projects/` stays
empty, every overlay path degrades to "no overlay for this project", and
nothing breaks.

The file lives at `$HOME`, not in the repo, because its content — the private
repo's URL — is exactly what must not be published. In-repo it would be
protected only by a gitignore rule, the same mechanism judged too thin for
`settings.local.json`. It would also be readable inside every seeded
devcontainer, which bind-mounts `~/.dotfiles` at `/host-seed/.dotfiles:ro`.
````

- [ ] **Step 3: Add the `git clean` warning**

Add to the Caveats section:

```markdown
- **`git clean -xdff` in `~/.dotfiles` destroys the overlay repo**, including
  uncommitted overlay edits and every ignored `settings.local.json`. Because
  `projects/` is now an ignored directory, `-x` targets it. Plain `git clean
  -xdf` is safe — git refuses to delete a directory containing `.git` without a
  second `-f` — but the double-force variant is not. Commit and push overlay
  work before running any `git clean` variant in the dotfiles repo.
```

- [ ] **Step 4: Rewrite the secrets caveat**

Replace the existing first Caveats bullet — currently "Don't put **secrets** here — this directory is committed to your dotfiles repo" — which is now both wrong about the repo and too narrow about the risk:

```markdown
- **Don't put secrets here.** The overlay repo is private, and private on GitHub
  is not a place for secrets: they stay in history, they are readable by anyone
  granted access, and "private" can be flipped. `*/.claude/settings.local.json`
  is gitignored in the overlay repo and must stay that way — Claude appends
  whole command lines to those permission allowlists, tokens included. Secrets
  belong in `.env` files or a secrets manager.
```

- [ ] **Step 5: Verify the doc is tracked and links resolve**

```bash
cd ~/.dotfiles
git ls-files docs/guides/project-overlays.md    # expect the path
grep -c 'dotfiles-projects-remote' docs/guides/project-overlays.md   # expect >= 2
```

- [ ] **Step 6: Commit**

```bash
git add docs/guides/project-overlays.md
git commit -m "docs: document the two-repo overlay split"
```

---

## Task 7: Update `project-claude-setup` SKILL.md

**Files:**
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md:43`, `:206`, `:676`

**Interfaces:**
- Consumes: `docs/guides/project-overlays.md` from Task 6
- Produces: nothing consumed by later tasks

The skill closes its flow by instructing `git add "projects/$SLUG" && git commit` in the dotfiles repo — the line that published each new overlay. Two other lines point at the moved README.

- [ ] **Step 1: Fix the prerequisite at `:43`**

Replace prerequisite 3 with:

```markdown
3. **Dotfiles repo present.** `~/.dotfiles/` exists with `core/git/gitignore.symlink` and a `projects/` subdir. If `~/.dotfiles/` itself is missing, point at `~/.dotfiles/docs/guides/project-overlays.md` for the setup story. If `~/.dotfiles/` exists but `projects/` is **empty or absent**, that is a different failure: `projects/` is a separate private repo that has not been attached on this machine. Tell the user to write the clone URL to `~/.dotfiles-projects-remote` and re-run `~/.dotfiles/bin/bootstrap`. Don't report it as a missing dotfiles install.
```

The distinction matters: an empty `projects/` is the expected state on a fresh machine, and diagnosing it as a broken dotfiles install sends the user to the wrong repair.

- [ ] **Step 2: Fix the generated comment at `:206`**

```
# See ~/.dotfiles/docs/guides/project-overlays.md.
```

- [ ] **Step 3: Fix the commit instructions at `:676`**

Replace the single command block with:

````markdown
- Commands to commit the overlay. **Two repos now** — the overlay content lives
  in the private `projects/` repo, and only that repo needs a commit here:
  ```bash
  cd ~/.dotfiles/projects && git add "$SLUG" && git commit -m "add project overlay for $SLUG" && git push
  ```
  The public dotfiles repo ignores `projects/` entirely, so it will show no
  change from this skill. If `git status` in `~/.dotfiles` shows overlay files,
  the ignore rule is broken — stop and report it rather than committing.
````

- [ ] **Step 4: Verify no stale references remain**

```bash
cd ~/.dotfiles
grep -n 'projects/README.md' ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md || echo "no stale README refs — good"
grep -n 'git add "projects/' ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md || echo "no public-repo overlay commit — good"
```

Expected: both "good" lines.

- [ ] **Step 5: Run the skill's tests**

Run: `bats tests/project_claude_setup_seed.bats`
Expected: all pass. This suite uses `setup_dotfiles_test`, so it builds a synthetic `$HOME` and should be unaffected — a failure here indicates a real regression.

- [ ] **Step 6: Commit**

```bash
git add ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md
git commit -m "docs(skill): commit overlays to the private repo, not the public one"
```

---

## Task 8: Annotate the linker and update the README

**Files:**
- Modify: `bin/claude-link-project:39` (comment only — no behavior change)
- Modify: `README.md` Structure block (`:34-48`) and Repository Hygiene (`:175-180`)

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Comment the overlay root**

At `bin/claude-link-project:39`, above `OVERLAY_ROOT="$DOTFILES/projects"`:

```bash
# This path is a separate PRIVATE repo cloned into the dotfiles checkout, not a
# tracked directory of it. Nothing here changes because of that -- every
# downstream comparison keys off the home-independent projects/<slug>/... tail
# -- but an empty projects/ now means "overlay repo not attached on this
# machine", not "dotfiles broken". See docs/guides/project-overlays.md.
OVERLAY_ROOT="$DOTFILES/projects"
```

- [ ] **Step 2: Add `projects/` to the README Structure block**

Insert into the code block at `README.md:34-48`, after the `ai/` line:

```
  projects/       # Per-project Claude overlays — SEPARATE PRIVATE REPO, ignored here
```

- [ ] **Step 3: Add a Repository Hygiene bullet**

Append to the list at `README.md:175-180`:

```markdown
- `projects/` is a separate private repository cloned into this checkout. The
  public repository must track nothing under that path; `tests/repository_hygiene.bats`
  asserts it. See `docs/guides/project-overlays.md`.
```

- [ ] **Step 4: Verify the linker still behaves identically**

Run: `bats tests/claude_link_project.bats tests/overlay_sync_hook.bats`
Expected: all pass, unchanged. These are comment-only edits; any failure means the comment was inserted into a code path.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-link-project README.md
git commit -m "docs: note the projects/ private-repo boundary in the linker and README"
```

---

## Task 9: Re-audit worktrees and verify

**Files:**
- No file changes. Verification only.

**Interfaces:**
- Consumes: everything above
- Produces: the completion evidence

- [ ] **Step 1: Re-run the worktree audit — do not trust any recorded count**

The inventory is live state: it went from 9 to 12 during spec authoring as concurrent sessions created worktrees. Any number written down is probably already wrong.

```bash
cd ~/.dotfiles
git worktree list
for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
  printf '%-45s added-by-branch: ' "$b"
  git diff --diff-filter=D --name-only "$b" main -- projects/ | wc -l
done
```

Expected: `0` in every second column. A non-zero value is a branch that **modifies** an overlay file — merge it and the modify-vs-delete conflict can restore content. Resolve those branches before merging this work.

- [ ] **Step 2: Full test suite**

Run: `bats tests`
Expected: **330 passing, 0 failures.**

- [ ] **Step 3: Full check target**

Run: `make check`
Expected: `syntax`, `lint`, `test`, `python-test`, `validate` all clean. This is the CI path.

- [ ] **Step 4: Confirm the boundary holds in the real checkout**

```bash
cd ~/.dotfiles
git ls-files projects/ | wc -l          # expect 0
git status --short                       # expect no projects/ entries
test -d projects/.git && echo "private clone attached"
git -C projects status --short           # expect empty (locals ignored)
```

- [ ] **Step 5: Confirm overlay symlinks still resolve**

The whole reason for keeping the path was that the linker needs no change. Prove it against every really linked project — find them rather than guessing a path:

```bash
# Every overlay symlink points through the stable root, so this finds them all.
find ~ -maxdepth 4 -lname '/opt/dotfiles/projects/*' 2>/dev/null | while read -r link; do
  printf '%-60s -> %s  ' "$link" "$(readlink "$link")"
  if [ -e "$link" ]; then echo "OK"; else echo "DANGLING"; fi
done
```

Expected: every line ends `OK`, and each target points through `/opt/dotfiles/projects/<slug>/`. A `DANGLING` line means the clone did not land in the canonical checkout — check `readlink /opt/dotfiles`.

- [ ] **Step 6: Confirm the stable link root is still correct**

```bash
cd ~/.dotfiles && bin/relink
```

Expected: reports the stable root correct, no repointing. `projects/` becoming a nested repo must not have disturbed `/opt/dotfiles`.

- [ ] **Step 7: Fresh-clone simulation — the anyone-else path**

The public repo has a fork. Someone cloning it has no overlay config and must not hit a fatal bootstrap:

```bash
tmp="$(mktemp -d)"
git clone ~/.dotfiles "$tmp/dotfiles"
env HOME="$tmp/fakehome" bash -c 'mkdir -p "$HOME" && cd "$1/dotfiles" && BOOTSTRAP_SOURCE_ONLY=1 source bin/bootstrap && setup_projects_overlay' _ "$tmp"
echo "exit: $?"
rm -rf "$tmp"
```

Expected: exit `0`, output contains the `.dotfiles-projects-remote` hint, no clone attempted.

- [ ] **Step 8: Confirm every local settings file survived byte-identical**

```bash
cd ~/.dotfiles/projects
find . -name settings.local.json -exec sha256sum {} + | sort > /tmp/locals-after.sha256
diff "$(dirname "$PRESWAP")/locals.sha256" /tmp/locals-after.sha256
```

Expected: the only difference is the hash of the one `settings.local.json` that changed in Task 1 when the token entry was removed. **Any missing path is a data loss** — restore it from `$PRESWAP` before continuing.

- [ ] **Step 9: Confirm nothing tracked names the private repo**

```bash
cd ~/.dotfiles
git grep -nI -e "$(basename "$(cat ~/.dotfiles-projects-remote)" .git)" -- . || echo "private repo name absent from tracked files — good"
```

Expected: `private repo name absent from tracked files — good`.

- [ ] **Step 10: Discard the preswap copy**

Only now, with everything verified:

```bash
ls "$PRESWAP"/*/.claude/settings.local.json      # confirm what is about to go
rm -rf "$(dirname "$PRESWAP")"
```

- [ ] **Step 11: Final diff review**

```bash
cd ~/.dotfiles
git diff main...HEAD --stat
```

Review that the surface matches the plan's File Structure table and nothing else changed.
