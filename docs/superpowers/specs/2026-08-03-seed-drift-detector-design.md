# Seed drift detector — design

Date: 2026-08-03
Status: approved for planning

## Problem

`.devcontainer/local-seed.sh` is gitignored and hand-owned in every project, so
it drifts from
`ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh`
the moment the template changes. The only existing detector is the Step 1 audit
in `catch-up-local-seed.md`, which someone has to remember to run, per project,
by hand.

It has already failed. All five seeds sat on the pre-#38 tree-sitter error
routing for weeks while the audit reported them clean, because the audit only
checks that `TREE_SITTER_VERSION` *appears* — not that the block around it
matches. Anchor presence is necessary and nowhere near sufficient.

## Goal

`bin/seed-drift` reports, per project and per documented block, whether a seed is
behind, ahead of, or diverged from the template, and exits non-zero on any drift
so it can gate.

Non-goal: fixing drift. Porting stays the human, one-project-per-session
procedure in `catch-up-local-seed.md`, for the reasons that document already
gives.

## Constraints from the request

1. `SEED_VERSION` is not a drift signal and must not be compared. Always-run
   blocks correctly do not bump it, so two seeds can report the same version and
   differ. Confirmed live: versions are 7/8/8/8/9 and all five are behind on the
   same block.
2. Anchor presence is too coarse — it is the bug being fixed.
3. Whole-file diffing is too noisy — seeds legitimately diverge in vocabulary,
   line-continuation style, and project-specific blocks.
4. Drift runs both ways. A block present in a seed but absent from the template
   is a promotion candidate, not an error, and the output must never imply the
   fix is always to overwrite the seed.
5. A project absent on a given machine is a skip, not a failure.

## Decision 1 — representation

**Chosen: normalized per-block line-multiset diff.**

Extract the block around each documented anchor from both files, normalize both
sides, and compare as sorted line multisets.

### Evidence

Prototyped against the real template and all five live seeds, on the
tree-sitter block:

```
template normalized lines: 47
wanderer           behind=7  ahead=0
wanderer-kills     behind=5  ahead=0
wanderer-notifier  behind=5  ahead=0
double-holo-ui     behind=5  ahead=0
slabledger         behind=7  ahead=0
```

It finds the motivating drift on all five. `ahead=0` confirms the vocabulary
neutralization is not manufacturing phantom differences. The reported lines are
the genuine #38 change — the two-guard `--version` probe and the image-provided
branch.

### Alternative considered and rejected: per-block fingerprints

Record a hash per block in the template; stamp each seed with the hash it was
ported from; compare stamps. Exact, vocabulary-blind, and cheap.

Rejected on two grounds:

- **Structurally blind to the "ahead" direction.** A stamp is a provenance
  claim, not a fact about content. This document's own premise is that seeds get
  hand-fixed locally first — wanderer carried a pinned neovim install and the
  `load-custom.zsh` loader before the template did. A block written directly
  into a seed has no stamp to compare, and a block hand-edited *after* porting
  still carries its old stamp and reads clean. That is the same false-clean
  failure as the anchor grep, relocated.
- **Bootstrap cost.** Five seeds x nine blocks = 45 unstamped blocks on day one,
  all reporting "unknown" until a manual pass that this tool exists to replace.

The bootstrap cost alone would be tolerable; the ahead-blindness is not,
because constraint 4 is a hard requirement.

### Alternative considered and rejected: aligning separator style across seeds

The five seeds use three different comment-separator styles. Normalizing them
would enable marker-based block boundaries.

Rejected: the design deliberately does not need it (comments are stripped;
boundaries come from shell structure). It would require a mechanical sweep
across five gitignored files with no `git diff` to review and no revert, and
`catch-up-local-seed.md` explicitly warns against batching operations across
seeds. If alignment ever happens it should be incremental, inside a single
project's catch-up session.

### Accepted tradeoff

Normalization rules are a maintained allowlist, and the two error directions are
not symmetric:

- a **missing** rule yields a false positive — noise, annoying, self-announcing;
- a **too-broad** rule yields a false negative — silent, and it recreates
  exactly the bug being fixed.

Therefore: normalize narrowly, prefer noise over silence, and pin every rule
with a test. No rule gets added without one.

## Decision 2 — the block list lives in the doc

`bin/seed-drift` parses the Step 1 table in `catch-up-local-seed.md`, taking the
Block name from column 1 and the backtick-quoted anchor from column 2. The
documented model becomes the executable one: adding a table row extends the
detector, and the two cannot disagree.

A test asserts every parsed anchor is present in the template. An anchor in the
table that the template lacks means doc and template have diverged — that is a
hard error (exit 2), not a per-block verdict.

## Decision 3 — block extraction

A block is the **union of every top-level statement whose non-comment text
contains the anchor**, matched as a **fixed string**.

Three findings drove this:

- Anchors are not unique. `config/nvim` occurs 9 times in the template (5 in
  code), `NVIM_VERSION` 5, `DOTFILES_LOAD_HOOK` 5, `core.hooksPath` 3. "First
  occurrence" is arbitrary.
- `TREE_SITTER_VERSION`'s first occurrence is a *comment* (template line 530);
  its first code use is line 568. Matching must ignore comments.
- One anchor, `lname '*dotfiles/projects/*'`, contains `*` and quotes, so
  matching must be fixed-string, not regex.

Boundaries: walk up from the matched line to the nearest column-0 statement
start, down to its matching column-0 `fi` / `done` / `esac` / `}`. Valid because
template and seeds are `shfmt -i 2 -ci` clean. Comment separators are ignored
entirely — they are inconsistent across seeds and unusable as boundaries.

Because the rule is applied identically to both sides, overlapping blocks are
symmetric. Overlap means a drifted region may be reported under more than one
block name: noise, not silence, which is the correct direction.

## Decision 4 — normalization

Applied to both sides, narrowest first:

| Step | Rationale |
|---|---|
| Join `\` line continuations into logical lines | continuation style is a legitimate divergence |
| Strip full-line comments; strip trailing comments only when quotes balance before the `#` | naive stripping mangles `sed 's#...#g'` in the plugin-repair block |
| Collapse whitespace runs, trim | reindentation is noise |
| Drop `as_user`, `$SUDO`, `sudo [-n]`, `runuser -u X --` prefixes | privilege vocabulary |
| `$SEED_HOME` / `$HOME` -> `«HOME»`; `$DOTFILES_HOME` -> `«HOME»/.dotfiles`; `$WORKSPACE` -> `«WS»` | path vocabulary; substitute the token only, preserving surrounding quotes |
| Drop `chown` / `chgrp` lines and the `{ chown ... \|\| [ -z "$(find ... -uid ...)" ]; }` idiom | ownership verification exists only in the non-root flavor |

The ownership rule is not ad hoc: that idiom exists solely because the template
targets a non-root remoteUser. A root-user seed correctly omits it, and the
prototype showed it as the single largest source of false "behind" lines.

Known residual false-positive source, accepted and documented rather than
normalized: **literal** workspace paths (`/app` vs `/workspace`). Only the
variable form is neutralized. Mapping literals would require per-project
configuration and risks over-broad matching.

## Decision 5 — drift direction

Per (project, block), on normalized line multisets:

| Verdict | Condition | Reported action |
|---|---|---|
| `ok` | equal | — |
| `MISSING` | anchor absent from seed | port the block (catch-up Step 2) |
| `BEHIND` | template-only lines | port the change |
| `AHEAD` | seed-only lines | promotion candidate — do **not** overwrite the seed |
| `DIVERGED` | lines in both directions | inspect by hand; direction is genuinely unclear |

`AHEAD` and `DIVERGED` messages never suggest overwriting.

### Stated limitation

A wholly novel block in a seed, for which the template has no anchor, is not
auto-discoverable — anchor iteration is template-rooted. **`AHEAD` is therefore
line-level only: additions inside a block the doc already lists.**

Note this is a genuine limit, not a gap to be patched by widening `AHEAD`. The
adjacent case — a seed carrying an anchor the *template* has dropped — is not
reachable as `AHEAD` either, because Decision 2 classifies a doc/template
mismatch as a hard error (exit 2) before any per-block verdict is computed. That
ordering is deliberate: if the doc and the template disagree, every verdict
derived from them is untrustworthy, so the run must stop rather than emit
verdicts that look authoritative.

Discovering entirely new blocks remains the human step in catch-up Step 2. The
tool states this in its output rather than implying full coverage.

## Decision 6 — discovery, exit codes, safety

**Discovery.** No arguments: glob `${SEED_DRIFT_ROOT:-$HOME/workspace}/*/.devcontainer/local-seed.sh`.
With arguments: check exactly those paths. A glob is self-maintaining as
projects are added; a hand-maintained list goes stale silently, which is the
same failure class as the bug being fixed.

**Skips.** A project without a seed is skipped with a note and does not affect
the exit code.

**Exit codes.** `0` clean (skips included); `1` any drift, in any direction; `2`
usage error, unreadable template, doc/template disagreement, or a seed whose
block boundaries cannot be resolved.

A run does not abort on the first bad seed. It reports every project, then exits
with the highest severity encountered (`2` outranks `1` outranks `0`), so one
malformed seed cannot hide drift in the other four.

**Extraction failure must never read as clean.** The column-0 boundary rule
assumes a `shfmt`-clean file. A seed hand-edited since its last catch-up may not
be. Both sides are checked with `bash -n` — the template as well as each seed,
since a broken template would otherwise silently produce empty blocks that
compare equal to everything. If a block's enclosing statement cannot be
resolved, or either file fails `bash -n`, the tool errors rather than falling
through to `ok`: a silent pass here would reproduce the exact false-clean bug
being fixed.

**Read-only.** The detector never writes to a seed. These are gitignored,
hand-owned files with no revert path. Asserted by test.

## Output

```
slabledger  /home/tng/workspace/slabledger/.devcontainer/local-seed.sh
  BEHIND   tree-sitter CLI      7 template lines absent from seed
             - elif sh -c 'command -v tree-sitter >/dev/null 2>&1 && ...
             - echo "seed: tree-sitter already present (image-provided)"
             -> port from template; see catch-up-local-seed.md Step 2
  AHEAD    codex guard          2 seed lines absent from template
             -> promotion candidate; do NOT overwrite the seed
  ok       neovim install
double-holo-ui  no seed - skipped

5 checked, 0 skipped, 2 blocks drifted (1 behind, 1 ahead)
```

Every finding names the project, the block, and the direction.

## Testing

`tests/seed_drift.bats`, fixtures only — no dependency on the real `~/workspace`,
so the suite is machine-independent. Follows `setup_dotfiles_test` and
`stub_command` from `tests/test_helper.bash`.

Required cases:

- **anchor present, surrounding block outdated -> `BEHIND`, exit 1.** The case
  that motivated the work. A detector that passes the current five without this
  test proves nothing.
- anchor absent -> `MISSING`
- extra seed lines -> `AHEAD`, wording is promotion, not overwrite
- differences both directions -> `DIVERGED`
- false-positive guards, one test each: `as_user` vs direct invocation,
  `$SEED_HOME` vs `$HOME`, `$DOTFILES_HOME` vs `$HOME/.dotfiles`, restyled line
  continuations, reworded comments, ownership idiom present vs absent
- `sed 's#...#g'` survives comment stripping
- absent project -> skipped, exit 0
- malformed / non-`shfmt` seed -> exit 2, never `ok`
- a malformed seed does not suppress drift reporting for the others
- doc table anchor missing from template -> exit 2
- seeds unmodified after a run (read-only)
- exit codes: 0 clean, 1 drift, 2 error

## Repository integration

- `bin/seed-drift`, executable. Auto-discovered by both linter targets via
  `is_direct_bin_shell` in `bin/list-check-files` — verified against a stub, so
  **no `list-check-files` change is required**.
- Must be `shfmt -i 2 -ci` and `shellcheck -x -S warning` clean.

### Deliberate exclusion

`bin/list-check-files` does not emit `.bats` files for either linter, so
`tests/seed_drift.bats` will be unlinted. This is consistent with all 20 existing
suites and is left as-is. Closing the gap would surface roughly 6 shellcheck
findings and shfmt reformatting requests across files unrelated to this change;
it deserves its own evaluation against all 20 suites rather than being smuggled
in here.
