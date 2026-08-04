# Catching an existing `local-seed.sh` up to the template

A per-project `.devcontainer/local-seed.sh` is **gitignored and hand-owned**, so
it drifts from `templates/local-seed.sh` the moment the template gains a
block. This is the procedure for closing that gap on one project at a time.

Run it in a **separate session per project**, from that project's directory. Do
not batch it — the seeds are structurally different from one another (see
"Vocabulary differs per seed" below), so a block that pastes cleanly into one
aborts another under `set -euo pipefail`.

## Prompt

Run from the project's directory, one project per session:

> Catch this project's `.devcontainer/local-seed.sh` up to the current template
> at `~/.dotfiles/ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh`,
> following `catch-up-local-seed.md` in that same directory — read it first.
> Audit with `~/.dotfiles/bin/seed-drift "$PWD"`, then work block by block from
> its verdicts, honouring the direction each one implies: port a `BEHIND` down
> into the seed translated into this file's vocabulary, treat an `AHEAD` as a
> promotion candidate and leave the seed alone, and inspect a `DIVERGED` by hand
> rather than assuming the template wins. Show me what you plan to change and
> which verdicts you intend to leave standing, before you apply anything. Then
> stop after Step 3 so I can rebuild the container.

## Why not just regenerate from the template

Because the drift runs **both ways**. When wanderer was caught up, its local
seed was three blocks behind the template *and* carried two blocks the template
did not have — a pinned neovim install and the `load-custom.zsh` shell loader.
Regenerating would have silently deleted both, and neither was
wanderer-specific. Those two have since been promoted up, but the same shape
recurs every time someone fixes something locally first.

So: **port block by block, and diff before overwriting anything.** Treat a block
present locally but absent from the template as a candidate for promotion, not
as cruft.

## Step 1 — audit

From the project directory:

```bash
~/.dotfiles/bin/seed-drift "$PWD"
```

Or by name, from anywhere:

```bash
~/.dotfiles/bin/seed-drift ~/workspace/<project>
```

Exit `0` clean, `1` drift found, `2` usage / template / doc / extraction error or
no projects discovered. With no arguments it checks every project under
`~/workspace` (override with `SEED_DRIFT_ROOT`); a project that is not checked
out on this machine is a counted skip, not a failure. It is strictly read-only
with respect to the seeds.

**`SEED_VERSION` does not tell you what's in the file.** Every block below is
always-run, and by the two-clause gating rule an always-run change must not bump
the version — so two seeds can both say `v8` and differ.

**Nor does anchor presence.** Grepping for `TREE_SITTER_VERSION` proves only
that the string occurs somewhere; it says nothing about the block around it.
That is not hypothetical — all five seeds sat on the pre-#38 tree-sitter error
routing for weeks while a presence check reported them clean. `bin/seed-drift`
extracts the whole enclosing top-level statement around each anchor, normalizes
away the vocabulary differences below, and compares the result, which is why it
catches what the grep could not.

### Reading the verdicts

The direction of the fix depends on the verdict. It is not always "make the seed
match the template":

| Verdict | Meaning | What to do |
|---|---|---|
| `ok` | normalized blocks match | nothing |
| `BEHIND` | template has lines the seed lacks | port template → seed, translated into that seed's vocabulary — Step 2 |
| `AHEAD` | seed has lines the template lacks | **promotion candidate, not an error.** Do not overwrite the seed. Propose lifting the block into the template — a tracked change in `~/.dotfiles`, so it needs its own worktree and PR |
| `DIVERGED` | both sides have lines the other lacks | inspect by hand. On a seed whose vocabulary differs from the template's this is often spelling rather than stale logic — decide per block |
| `MISSING` | the anchor is absent from the seed entirely | port the whole block — Step 2 |
| `ERROR` | the block could not be extracted or parsed | the tool could not compare; investigate before treating the seed as clean |
| `ERROR` on `(whole file)` | the seed reads `$WORKSPACE` or `$SEED_USER` but never assigns it | fix before rebuilding. Under `set -euo pipefail` the first expansion aborts the whole seed, which surfaces as an unrelated-looking container start error rather than as a seed failure |
| `ERROR` on `(whole file)` | the seed *derives* `WORKSPACE`/`SEED_USER` instead of assigning a literal | fix before rebuilding. The seed is mounted at an arbitrary container path that need not sit inside the checkout, so `git rev-parse` and friends resolve against the wrong tree |

A `note: … window is only N lines` under a verdict means the extracted block was
small enough that the comparison covers little — worth an eye even when it says
`ok`.

The table above is prose, unlike the one in Step 2: the parser only takes a row
whose **second** cell is a backticked anchor, and these rows backtick the first.
Do not add a backticked second cell here — the parser would read the row as a
block and abort every project at exit 2 when the "anchor" turned up missing from
the template. `tests/seed_drift.bats` pins the count at nine and would catch it.

The blocks it compares are the rows of the Step 2 table below, so the two stay
in step by construction.

## Step 2 — port the missing blocks

Capture the baseline first, so Step 3 has something to compare against. The seed
is gitignored, but the tree is rarely *clean* — an in-flight branch has its own
modifications, so a bare `git status --porcelain` at the end proves nothing:

```bash
# Scoped to THIS repo's .git dir, not a shared /tmp path. Steps 2 and 3 run as
# separate shell invocations, so the location has to be stable rather than
# mktemp-random — but a fixed name under /tmp is worse than useless here: run
# this procedure on two projects at once (or leave a stale file from last week)
# and the second run silently overwrites the first's baseline, so Step 3 diffs
# against another repo's status and reports a violation that isn't one, or
# hides one that is. `git rev-parse --git-dir` is per-repo, never tracked, and
# resolves correctly inside a linked worktree.
SEED_BASELINE="$(git rev-parse --git-dir)/seed-baseline.status"
git status --porcelain >"$SEED_BASELINE"
```

Each entry gives the grep anchor to find it in the template. All of these live
in the **always-run block, above the sentinel gate** — keep them there. Moving
one below the gate means a container that is already stamped will never run it.

> **This table is executable input, not just prose.** `bin/seed-drift` parses it
> to decide which blocks to compare, so editing it changes what the detector
> checks for **every** project. A row must be a four-cell Markdown table row of
> the shape ``| Block name | `anchor` | why |`` — a row whose anchor is not
> wrapped in backticks is silently skipped, and a row
> whose anchor does not appear in the template's **code** (a match inside a
> comment does not count, and neither does a typo) aborts the whole run with
> exit 2 for every project, not just a per-block error. Adding a row is how you
> extend the detector; check `bin/seed-drift` still exits 0 or 1 afterwards.

| Block | Anchor in template | Why it matters |
|---|---|---|
| Stable link root | `ensure_stable_link_root` | Publishes `/opt/dotfiles`. Without it every personal overlay symlink dangles in the container — `.claude/skills`, `agents`, `references`, **and `CLAUDE.md`**, so the project instructions never load either. |
| Overlay-link gitignore | `lname '*dotfiles/projects/*'` | Adds overlay links to the container's `~/.gitignore`. If the seed has the **old narrow** `'*/.dotfiles/projects/*'`, it must be widened: that glob needs a literal dot-prefixed `.dotfiles` and misses every `/opt/dotfiles` link, so overlay files start appearing in container `git status`. |
| `core.excludesFile` | `core.excludesFile` | The host's global gitignore is not seeded; without this the container has no exclude file at all. |
| `core.hooksPath` | `core.hooksPath` | Same reason, for the dotfiles git hooks. |
| neovim install | `NVIM_VERSION` | The dotfiles set `EDITOR=nvim` but nothing in them installs the binary — on a host it arrives via the package lists, which no devcontainer image runs. An `EDITOR` naming a missing command breaks `git commit` with an error that blames git. Pinned and sha256-verified from `config/versions.env`; non-fatal. |
| `~/.config/nvim` link | `config/nvim` | Without it the binary starts bare and none of `config/nvim` applies. Must not clobber a real directory. |
| tree-sitter CLI | `TREE_SITTER_VERSION` | `config/nvim` pins nvim-treesitter to `main`, whose installer shells out to `tree-sitter build` per parser with no fallback to a bare `cc`. A container with gcc but no CLI still fails every parser at first launch (`ENOENT ... (cmd): 'tree-sitter'`). On a host it comes from mise, which the seed never runs. Pinned and sha256-verified from `config/versions.env`; non-fatal. |
| `load-custom.zsh` loader | `DOTFILES_LOAD_HOOK` | The supported entry point for the shell tree. Append it **before** the Vekil hook — `ai/vekil/env.zsh` exports `ANTHROPIC_MODEL`, which outranks `settings.json`, so it has to get the last word. |
| codex guard | `local/bin/codex` | Guard the reinstall on the **binary**, not `~/.codex/config.toml`. The installer writes config even when it fails to produce a binary, so a config-based guard latches shut and codex never reinstalls. |

## Vocabulary differs per seed — do not paste blindly

The template is written against `as_user`, `$SUDO`, `$SEED_HOME`,
`$DOTFILES_HOME`, and `$WORKSPACE`. Existing seeds do not all define those:

- Seeds for a **root** container user tend to have no `as_user` and no
  `$SEED_HOME`, and call `sudo` directly against `$HOME`.
- Some seeds define no `$WORKSPACE` at all — the overlay-gitignore block needs
  one, so add it (`WORKSPACE="/app"`, or wherever the compose file mounts the
  repo) rather than assuming it exists.
- `$DOTFILES_HOME` is frequently just `$HOME/.dotfiles` locally.

Read the target file's variable block first and translate each pasted block into
**that file's** vocabulary. An undefined variable under `set -u` aborts the whole
seed, and the failure surfaces as an unrelated-looking container start error.

Two substitutions are templated and must be replaced when pasting: `{USER}` and
`{WORKSPACE}`.

## Non-negotiable scope

- **Never edit the project's `Dockerfile` or its base compose file.** The only
  sanctioned tracked-file change is adding `docker-compose.override.yml` to
  `dockerComposeFile` in `devcontainer.json`, and only with explicit approval.
- `local-seed.sh` and `docker-compose.override.yml` are gitignored. Confirm with
  `git check-ignore -v` before writing, and confirm `git status --porcelain` is
  unchanged after.
- **Never mount all of `~/.claude`.** Read-only still exposes
  `.credentials.json`, `history.jsonl`, and `projects/` session transcripts.
  Mount only the authored allowlist the seed actually copies.
- Host SSH keys and `gh` auth are not shared unless the user explicitly opts in.

## Step 3 — verify

```bash
bash -n .devcontainer/local-seed.sh
shellcheck -x -S warning -e SC1091 .devcontainer/local-seed.sh
shfmt -d -i 2 -ci .devcontainer/local-seed.sh

# Re-run the Step 1 audit: the ported blocks must now read `ok`. Parsing clean
# is not the same as drifting clean — a block pasted without translating its
# vocabulary parses fine and still reports BEHIND or DIVERGED. Expect exit 0,
# or exit 1 with only the verdicts you consciously decided to leave (an AHEAD
# awaiting promotion, a DIVERGED ruled benign); anything else is unfinished.
#
# Invoked by absolute path, NOT as `(cd ~/.dotfiles && bin/seed-drift "$PWD")`
# — `$PWD` re-evaluates after the `cd`, so that form audits the dotfiles repo
# and reports a clean `0 checked, 1 skipped` at exit 0 without ever looking at
# this seed.
~/.dotfiles/bin/seed-drift "$PWD"

# Nothing tracked may have moved. Diffed against the Step 2 baseline rather than
# asserted empty: the seed and the override are gitignored, but any other
# in-flight work in the tree is not, and would otherwise read as a violation.
# Refuse to pass on a MISSING baseline — `diff` against /dev/null would compare
# the current status to nothing and report every in-flight change as new, while
# an accidental `touch` would make an empty file look like a clean baseline and
# quietly bless whatever the port touched.
SEED_BASELINE="$(git rev-parse --git-dir)/seed-baseline.status"
if [ ! -f "$SEED_BASELINE" ]; then
  echo "no Step 2 baseline at $SEED_BASELINE — cannot verify; re-run Step 2" >&2
elif diff "$SEED_BASELINE" <(git status --porcelain); then
  rm -f "$SEED_BASELINE"   # consumed; a stale one would mislead the next run
else
  echo "TRACKED FILES CHANGED — inspect the diff above before continuing" >&2
fi
```

Then rebuild the container and check, inside it:

```bash
readlink /opt/dotfiles                      # -> the container's own ~/.dotfiles
find .claude -xtype l                       # must print nothing
git status --porcelain | grep -i claude     # must print nothing
nvim --version | head -1
zsh -lic 'whence -v nvim; print $EDITOR'
tree-sitter --version                       # must print a version, not "not found"
# Compiles the bootstrap parser set — must end with no "tree-sitter build" errors
nvim --headless -c 'lua require("nvim-treesitter").install({"lua"}):wait(120000)' -c q
git config --global core.hooksPath
git config --global core.excludesFile
```

Back on the host afterwards, confirm the overlay links still resolve — the whole
point of the stable root is that neither side repairs at the other's expense:

```bash
# Prints every managed overlay link that no longer resolves, and exits non-zero
# if there are any. Match on -xtype l, not on `-exec test -e`: the older form
# printed the links that DID resolve, so a real break printed nothing — which is
# exactly what a reader scanning for "no output means fine" wants to see.
broken="$(find . -maxdepth 3 -lname '*dotfiles/projects/*' -xtype l)"
[ -z "$broken" ] || { printf 'dangling overlay link:\n%s\n' "$broken" >&2; false; }
```

If the root is missing on the host, publish it once per machine — it needs
`sudo`, because `/opt` is root-owned:

```bash
bash -c 'source ~/.dotfiles/bin/common.sh && ensure_stable_link_root "$HOME/.dotfiles"'
```
