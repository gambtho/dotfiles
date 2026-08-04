# Catching an existing `local-seed.sh` up to the template

A per-project `.devcontainer/local-seed.sh` is **gitignored and hand-owned**, so
it drifts from `templates/local-seed.sh` the moment the template gains a
block. This is the procedure for closing that gap on one project at a time.

Run it in a **separate session per project**, from that project's directory. Do
not batch it — the seeds are structurally different from one another (see
"Vocabulary differs per seed" below), so a block that pastes cleanly into one
aborts another under `set -euo pipefail`.

## Prompt

> Catch this project's `.devcontainer/local-seed.sh` up to the current template
> at `~/.dotfiles/ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh`,
> following `catch-up-local-seed.md` in that same directory. Audit first, show me
> what's missing and what you plan to port, then apply it.

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
f=.devcontainer/local-seed.sh
printf 'SEED_VERSION=%s\n' "$(sed -n 's/^SEED_VERSION=//p' "$f")"
for k in 'STABLE_LINK_ROOT' 'ensure_stable_link_root' 'NVIM_VERSION' \
         'TREE_SITTER_VERSION' 'load-custom.zsh' 'core.hooksPath' \
         'core.excludesFile' 'local/bin/codex' 'config/nvim'; do
  grep -q "$k" "$f" && printf '  %-24s present\n' "$k" || printf '  %-24s MISSING\n' "$k"
done
grep -o "lname '[^']*'" "$f" || echo "  overlay-gitignore matcher MISSING"
```

**`SEED_VERSION` does not tell you what's in the file.** Every block below is
always-run, and by the two-clause gating rule an always-run change must not bump
the version — so two seeds can both say `v8` and differ. Grep is the only check.

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
> checks for **every** project. A row must be a four-cell Markdown table row —
> `| Block name | ` + backticked anchor + ` | why |` — with the anchor wrapped in
> backticks; a row whose anchor is not backticked is silently skipped, and a row
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
