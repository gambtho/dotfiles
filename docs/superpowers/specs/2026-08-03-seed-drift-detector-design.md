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

**Chosen: normalized per-block, order-preserving line-sequence diff.**

Extract the block around each documented anchor from both files, normalize both
sides, and diff the resulting line **sequences** — preserving order.

### Order is load-bearing; multisets discard it

An earlier draft compared *sorted* line multisets. That is a false-clean bug of
exactly the class this tool exists to eliminate, because statement order in
these seeds is behaviorally significant and sometimes explicitly specified.

`catch-up-local-seed.md:83` requires the `load-custom.zsh` loader to be appended
**before** the Vekil hook, because `ai/vekil/env.zsh` exports `ANTHROPIC_MODEL`,
which outranks `settings.json` and must get the last word. The template devotes a
long comment to this, including the instruction to *compare positions* rather
than merely detect presence, precisely because an already-seeded volume can carry
both hooks in the wrong order.

Under a sorted comparison, a seed with the two hooks inverted contains the same
lines as the template and reports clean — while the container silently runs on
the wrong model. Sorting is therefore abandoned: comparison is an ordered diff.

A pure reordering surfaces as differences in **both** directions, and so is
reported as `DIVERGED` — correctly, since the tool cannot know which order was
intended without reading the doc.

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

(The prototype used sorted comparison; the counts above are unaffected, since
these differences are insertions rather than reorderings. The order defect it
would have missed is a separate class, described above.)

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

**An anchor locates a block; it does not define its membership.**

A block is the **union of every blank-line-delimited paragraph whose non-comment
text contains the anchor**, matched as a **fixed string**. Paragraph detection is
**heredoc-aware**: a blank line inside a heredoc body does not end a paragraph.

### Why not "the enclosing top-level statement"

That was the first rule proposed, and it is wrong. `core.excludesFile` occurs in
code exactly once, at template line 236, as a standalone top-level command:

```sh
as_user git config --global core.excludesFile "$GITIGNORE"
```

The enclosing-statement rule captures that one line and nothing else. The
`GITIGNORE=` assignment and the entire `if ! as_user test -f "$GITIGNORE"` block
that writes the file — template lines 217-235, which is the whole substance of
the block — fall outside it. The seeded gitignore contents could be rewritten
wholesale and the detector would report clean. That is the same false-clean class
as the anchor grep this tool exists to replace, so the rule is disqualified.

The overlay-gitignore block fails the same way: its workspace and marker
assignments sit outside the statement holding the anchor.

### Why paragraphs work

The template separates blocks with a blank line and separates *comment*
paragraphs within a block using a bare `#` line rather than a blank. So the
blank-line paragraph is already the semantic unit. For `core.excludesFile` it
yields lines 204-236 — comment preamble, assignment, heredoc block, and the
`git config` line together.

Verified: blank line at 203, contiguous content 204-236, blank line at 237.

Heredoc awareness is required, not optional: lines 223 and 229 are blank lines
*inside* the `GITEOF` heredoc, and a naive splitter would cut the block in three.
The scanner tracks `<<TAG`, `<<'TAG'`, and `<<-TAG` to its closing delimiter.

### Why fixed-string matching, and why comments are excluded from matching

- Anchors are not unique. `config/nvim` occurs 9 times in the template (5 in
  code), `NVIM_VERSION` 5, `DOTFILES_LOAD_HOOK` 5, `core.hooksPath` 3. Hence the
  union over all matching paragraphs rather than a first-occurrence pick.
- `TREE_SITTER_VERSION`'s first occurrence is a *comment* (template line 530);
  its first code use is line 568. Matching that counted comments would anchor on
  prose.
- `lname '*dotfiles/projects/*'` contains `*` and quotes, so matching must be
  fixed-string, not regex.

Because the rule is applied identically to both sides, overlapping blocks are
symmetric. Overlap means a drifted region may be reported under more than one
block name: noise, not silence, which is the correct direction.

### Formatting independence

Paragraph boundaries depend on blank lines and heredoc structure, not on
indentation, so extraction does **not** assume `shfmt`-clean input. This is a
deliberate change from the first draft, which assumed column-0 boundaries and
then proposed to validate that assumption with `bash -n` — a check that passes
on syntactically valid but unformatted shell, so it would not have validated the
assumption at all.

All five live seeds and the template are in fact `shfmt -i 2 -ci` clean today
(verified), so an shfmt precondition would have been viable. It is not adopted,
because a formatting-independent extractor is strictly better than a formatting
dependency plus a gate enforcing it.

### Residual limitation

A semantic block that spans two paragraphs where only one contains the anchor is
compared only in part. This is far narrower than the enclosing-statement failure
above — the paragraph always carries the anchor's full statement group and its
comment preamble — but it is not zero, and it is not detectable from inside the
tool.

### Alternative considered and deferred: whole-file paragraph matching

Normalize both files into paragraphs, match them by similarity, name matched
paragraphs from the doc table, and report unmatched ones. This would eliminate
the residual limitation above *and* the novel-block limitation in Decision 5.

Deferred, not rejected: unmatched paragraphs include every legitimately
project-specific block, so the promotion-candidate report would be dominated by
noise — which constraint 3 rules out. Revisit if the anchored version proves too
narrow in practice.

## Decision 4 — normalization

Applied to both sides, narrowest first:

| Step | Rationale |
|---|---|
| Join `\` line continuations into logical lines | continuation style is a legitimate divergence |
| Strip full-line comments; strip trailing comments only when quotes balance before the `#` | naive stripping mangles `sed 's#...#g'` in the plugin-repair block |
| Collapse whitespace runs, trim | reindentation is noise |
| Drop `as_user`, `$SUDO`, `sudo [-n]`, `runuser -u X --` prefixes | privilege vocabulary |
| `$SEED_HOME` / `$HOME` -> `«HOME»`; `$DOTFILES_HOME` -> `«HOME»/.dotfiles`; `$WORKSPACE` -> `«WS»` | path vocabulary; substitute the token only, preserving surrounding quotes |
| Drop the two **exact** ownership-verification lines listed below | that idiom exists only in the non-root flavor |

The ownership rule is deliberately **not** "drop every `chown`/`chgrp` line".
An earlier draft said that, and it was too broad in exactly the direction this
design calls dangerous: it would hide a genuine change to the target path, the
recursion flag, the identity, or the failure handling of any ownership repair
anywhere in a block.

Instead the rule matches two literal normalized forms, and nothing else:

```
{ chown "$SEED_UID:$SEED_GID" <arg> 2>/dev/null ||
[ -z "$(find <arg> \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
```

`<arg>` is the only free element. Any other `chown` or `chgrp` line is compared
normally. Each form gets its own test, and a test asserts that an *unrelated*
`chown` line is **not** dropped.

Known residual false-positive source, accepted and documented rather than
normalized: **literal** workspace paths (`/app` vs `/workspace`). Only the
variable form is neutralized. Mapping literals would require per-project
configuration and risks over-broad matching.

## Decision 5 — drift direction

Per (project, block), on the ordered diff of normalized line sequences:

| Verdict | Condition | Reported action |
|---|---|---|
| `ok` | sequences identical | — |
| `MISSING` | anchor absent from seed | port the block (catch-up Step 2) |
| `BEHIND` | template-only lines | port the change |
| `AHEAD` | seed-only lines | promotion candidate — do **not** overwrite the seed |
| `DIVERGED` | lines in both directions, **including pure reordering** | inspect by hand; direction is genuinely unclear |

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

**Discovery.** A **candidate** is a directory containing `.devcontainer/`. A
candidate with no `.devcontainer/local-seed.sh` is a **skip**; a candidate with
one is **checked**.

- No arguments: candidates are `${SEED_DRIFT_ROOT:-$HOME/workspace}/*/`.
- With arguments: each argument is a candidate. A project directory and a direct
  path to a `local-seed.sh` are both accepted; the tool distinguishes them by
  testing whether the argument is a directory.

An earlier draft globbed `*/.devcontainer/local-seed.sh` directly. That is
inconsistent with the skip requirement: globbing seed files enumerates only
projects that *have* one, so a project missing its seed is invisible rather than
skipped — and the sample output claimed a skip that the discovery rule could not
have produced. Globbing candidate directories and then testing for the seed makes
the skip real.

Directories without `.devcontainer/` are not candidates at all, so unrelated
entries under `~/workspace` are silent rather than reported as skips.

A glob is self-maintaining as projects are added; a hand-maintained list goes
stale silently, which is the same failure class as the bug being fixed.

**Skips.** A candidate without a seed is reported with a note and does not affect
the exit code.

**Exit codes.** `0` clean (skips included); `1` any drift, in any direction; `2`
usage error, unreadable template, doc/template disagreement, or a seed whose
block boundaries cannot be resolved.

A run does not abort on the first bad seed. It reports every candidate, then
exits with the highest severity encountered (`2` outranks `1` outranks `0`), so
one malformed seed cannot hide drift in the other four.

**Extraction failure must never read as clean.** Paragraph extraction is
formatting-independent (Decision 3), so there is no `shfmt` precondition. Both
files are still checked with `bash -n` — the template as well as each seed, since
a broken template would otherwise silently produce empty blocks that compare
equal to everything. An anchor that the template does not contain, or a block
that extracts to nothing on the template side, is an error rather than an `ok`:
a silent pass here would reproduce the exact false-clean bug being fixed.

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
double-holo-ui  .devcontainer/ present, no local-seed.sh - skipped

4 checked, 1 skipped, 2 blocks drifted (1 behind, 1 ahead)
```

Counts are consistent by construction: `checked + skipped` equals the number of
candidates, and a skipped candidate contributes no verdicts.

Every finding names the project, the block, and the direction.

## Testing

`tests/seed_drift.bats`, fixtures only — no dependency on the real `~/workspace`,
so the suite is machine-independent. Follows `setup_dotfiles_test` and
`stub_command` from `tests/test_helper.bash`.

Required cases:

- **anchor present, surrounding block outdated -> `BEHIND`, exit 1.** The case
  that motivated the work. A detector that passes the current five without this
  test proves nothing.
- **reordered lines -> `DIVERGED`, exit 1, never `ok`.** Guards the order defect
  in Decision 1. Modelled on the real constraint: a seed with the
  `load-custom.zsh` hook placed *after* the Vekil hook must not report clean.
- **a change confined to a block's non-anchor lines -> reported.** Guards the
  extraction defect in Decision 3, using the `core.excludesFile` shape: edit the
  seeded gitignore heredoc, leave the `git config` line untouched, expect drift.
- **a blank line inside a heredoc does not split the block.** Guards heredoc
  awareness directly.
- anchor absent -> `MISSING`
- extra seed lines -> `AHEAD`, wording is promotion, not overwrite
- differences both directions -> `DIVERGED`
- false-positive guards, one test each: `as_user` vs direct invocation,
  `$SEED_HOME` vs `$HOME`, `$DOTFILES_HOME` vs `$HOME/.dotfiles`, restyled line
  continuations, reworded comments, the two exact ownership-idiom forms
- **an unrelated `chown` line is NOT dropped.** Guards against the over-broad
  ownership rule rejected in Decision 4.
- `sed 's#...#g'` survives comment stripping
- an anchor appearing only in a comment does not anchor a block
- candidate with `.devcontainer/` but no seed -> skipped, exit 0, counted as
  skipped; a directory with no `.devcontainer/` is not reported at all
- argument accepted both as a project directory and as a direct seed path
- unparseable seed (`bash -n` fails) -> exit 2, never `ok`
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
