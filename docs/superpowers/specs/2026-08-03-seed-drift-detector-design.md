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

A block is the **union of every parse-complete window containing the anchor**,
matched as a **fixed string**.

A window starts as one blank-line-delimited paragraph — heredoc-aware, so a blank
line inside a heredoc body does not end a paragraph — and is then **grown until
the extracted text parses on its own**:

1. Take the paragraph whose non-comment text contains the anchor.
2. While `bash -n` on the extracted fragment fails, append the next paragraph;
   if that reaches end of file, prepend the preceding paragraph instead.
3. If both directions are exhausted without parsing, the block is an
   **extraction error** (exit 2), never `ok`.

### Blank lines are formatting; the parse check is what makes extraction sound

An earlier draft claimed paragraph extraction was formatting-independent. That
was wrong: blank lines *are* formatting. Valid Bash permits a blank line between
a condition and its body, and `bash -n` accepts it:

```sh
if [ -n "$x" ]; then

  echo hi        # <- a separate paragraph
fi
```

An anchor in the condition would have extracted the condition alone. Verified:
`bash -n` exits 2 on `if [ -n "$x" ]; then` by itself and 0 on the full form
above. So the split is legal input, the truncation was real, and the assertion
that a paragraph always carries the full statement group did not hold.

The same asymmetry supplies the remedy. A truncated window is *detectable* —
that is exactly what `bash -n` reports — so the window is grown until it parses.
Extraction is now **formatting-tolerant and verified**, rather than
formatting-independent by assertion.

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

### Heredoc recognition must be complete and must fail closed

The scanner recognizes every Bash heredoc delimiter form — `<<TAG`, `<<'TAG'`,
`<<"TAG"`, `<<\TAG`, and each with the `<<-` tab-stripping variant — and tracks
it to its closing delimiter. Two constructs must be excluded rather than
misread:

- **Herestrings.** `<<<` is not a heredoc.
- **`<<` inside quotes.** Template line 255 is
  `GI_MARK_END="# <<< overlay symlinks (auto) <<<"` — and it sits inside the
  overlay-gitignore anchored block. A scanner keying on a bare `<<` would look
  for a heredoc delimiter here and swallow the rest of the file. Quote tracking
  is required, and is shared with the trailing-comment rule in Decision 4.

Any `<<` that is neither excluded nor matched by a recognized form is an
**extraction error** (exit 2). Unrecognized heredoc syntax must never degrade to
"probably not a heredoc" — that failure mode is silent, and silence is the class
of bug this tool exists to remove.

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

### Formatting tolerance

Extraction does not assume `shfmt`-clean input: window growth is driven by
`bash -n`, not by indentation or blank-line placement. All five live seeds and
the template are in fact `shfmt -i 2 -ci` clean today (verified), so an shfmt
precondition would also have been viable — but a parse-verified extractor is
strictly better than a formatting dependency plus a gate enforcing it, because
it stays correct on input the gate never sees.

The first draft proposed to validate its column-0 boundary assumption with
`bash -n` on the *whole file*, which passes on syntactically valid but
unformatted shell and therefore validated nothing. The check is only meaningful
applied to the extracted fragment, which is what the rule above does.

### Residual limitation

A window that already parses is not grown further, so a syntactically complete
command sitting inside a larger conditional is extracted without that
conditional. If the anchor is in the body and the guarding condition lives in a
separate paragraph, a change to the condition alone is missed.

This is narrower than it sounds — several anchors (`TREE_SITTER_VERSION`,
`NVIM_VERSION`, `core.hooksPath`) appear in the conditions themselves, so those
paragraphs are covered from the other side — but it is real, and it is not
detectable from inside the tool.

### Thin-window warning (informational, Task 8)

A window that already parses is not grown further (see above), so a genuinely
small paragraph — one that happens to parse standalone — yields a small window,
and a small window compares very little. A "clean" verdict on a two-line window
is close to meaningless: the tool would be silently wrong in exactly the one
place everything else here is designed to be loud instead.

Measured on the real five-seed corpus: 95 windows, 94 of which never grew past
their starting paragraph (growth is near-inert), sizes ranging from **9 to 138
lines**, median ~30. None fell at or below 8 lines. An earlier design proposed
warning whenever the growth loop did not iterate; that was rejected because it
would fire on 94 of the 95 windows — including a 109-line one — training the
reader to ignore it. The concern (a window that proves too little) is real; the
proxy (did it grow) was not measuring that. Warn on **size**, directly.

The tool now emits a note whenever an extracted window — template or seed,
independently — is fewer than **`SD_THIN_WINDOW` (5) raw, pre-normalization
lines**. Calibrated against the corpus above: the smallest window measured
there is 9 lines, so 5 leaves headroom against ordinary variation while still
catching a window degenerate enough to matter.

The note:

- Names which side is thin (`template` or `seed`) — a thin template window
  means the anchor is weakly defined for *every* project; a thin seed window
  means *this* seed's block is degenerate. Different problems, so the reader
  is told which.
- Fires regardless of verdict, including `ok` — an `ok` block is exactly the
  case a thin window makes untrustworthy, so suppressing the note there would
  defeat the point.
- Never affects the exit code or the drift tallies. The tool does not know the
  thin block is wrong, only that it checked very little of it; turning that
  uncertainty into a drift signal would be a false positive by construction.
- Is not counted in the summary line. It fired zero times across the real
  corpus; if that changes, it is a signal to revisit the design, not to add a
  tally.

### Alternative considered and deferred: whole-file paragraph matching

Normalize both files into paragraphs, match them by similarity, name matched
paragraphs from the doc table, and report unmatched ones. This would eliminate
the residual limitation above *and* the novel-block limitation in Decision 5.

Deferred, not rejected: unmatched paragraphs include every legitimately
project-specific block, so the promotion-candidate report would be dominated by
noise — which constraint 3 rules out. Revisit if the anchored version proves too
narrow in practice.

## Decision 4 — normalization

Applied to **shell code only**, narrowest first:

| Step | Rationale |
|---|---|
| Join `\` line continuations into logical lines | continuation style is a legitimate divergence |
| Strip full-line comments; strip trailing comments only when quotes balance before the `#` | naive stripping mangles `sed 's#...#g'` in the plugin-repair block |
| Collapse whitespace runs, trim | reindentation is noise |
| Drop `as_user`, `$SUDO`, `sudo [-n]`, `runuser -u X --` prefixes | privilege vocabulary |
| `$SEED_HOME` / `$HOME` -> `«HOME»`; `$DOTFILES_HOME` -> `«HOME»/.dotfiles`; `$WORKSPACE` -> `«WS»` | path vocabulary; substitute the token only, preserving surrounding quotes |

### Heredoc bodies are payload and are compared verbatim

None of the above applies inside a heredoc body. A heredoc body is output data,
not shell code, and every rule in the table corrupts data:

- The `GITEOF` body (template 219-233) contains **two `#` lines that are
  gitignore payload**, not shell comments — `# Personal Claude Code overlay
  shims...` and `# Personal docker-compose overrides.`. Comment stripping would
  delete real content from the seeded file, in the very block the
  non-anchor-line regression test targets.
- That body also contains blank lines and leading-whitespace-sensitive patterns.
- A trailing `\` in a payload line is literal text, not a continuation.

So heredoc bodies are carried through **verbatim**, with one exception, which
follows shell semantics rather than adding a rule: path-token neutralization is
applied only when the delimiter is **unquoted** (`<<TAG`), because that is
exactly when the shell itself expands the variable. A quoted delimiter
(`<<'GITEOF'`, `<<"TAG"`, `<<\TAG`) means the body is literal, so neutralizing
`$HOME` there would rewrite text the container will see. Both template heredocs
are quoted, so both are compared byte-for-byte after extraction.

### The ownership-verification idiom is not special-cased (removed)

Three fix rounds tried to special-case the non-root ownership-verification
idiom — `{ chown ... || find ... -uid ... -gid ... }` — so that a root-flavored
seed which skips it entirely would not report the idiom's template lines as
drift. Each version failed a different way:

- **Per-file asymmetry** (Task 6 draft): dropped the idiom during
  normalization, one file at a time, which could not tell "seed omits it" from
  "seed relocated it" — a seed that moved the check elsewhere would silently
  lose both copies.
- **Blindness to a rewritten idiom half** (Task 7 review, I-1): a guard keyed
  on `chown`/`chgrp` tokens in the seed-only lines missed a seed that left the
  chown half untouched and rewrote only the find half's identity check — the
  guard saw no token, dropped the idiom anyway, and reported AHEAD
  ("promotion candidate") for a seed whose check no longer verified what it
  claimed to.
- **Diff hunk adjacency** (fix round 2): a hunk-aware rewrite tried to drop a
  template line only when GNU diff's own hunk header marked it as a pure
  delete (never a change), so a rewrite could no longer be mistaken for an
  omission. This failed on a real seed: a genuinely-omitted idiom sitting
  immediately next to an unrelated, independently-edited line left diff with
  no unchanged anchor line between them, so diff merged both into a single
  change hunk. The rule then refused to drop lines that really had been
  omitted, and the general case is worse than a count discrepancy — a seed
  that cleanly omits the idiom and edits anything on the adjacent line would
  flip a correct AHEAD into a false DIVERGED, the exact failure mode round 2
  was meant to retire.

Before committing to a fourth attempt, the cost of removing the rule entirely
was measured against the real five-project corpus (`8c780a0` baseline vs. the
rule disabled): every DIVERGED block stayed DIVERGED, **no verdict changed
anywhere in the corpus**, and the summary line
(`5 checked, 2 skipped, 28 blocks drifted (4 behind, 1 ahead, 23 diverged)`)
was identical either way. The only effect was inflated BEHIND counts on the
two root-flavored seeds that omit the idiom (`slabledger`, `wanderer`), 2 extra
lines each on both idiom-bearing blocks (neovim install, tree-sitter CLI) — a
cosmetic reporting difference, not a wrong verdict, on already-DIVERGED
blocks.

Given three independent failure modes and a measured cost of "some inflated
line counts on already-drifted blocks, zero verdict changes," the rule was
removed rather than attempted a fourth time. `BEHIND` now reports whatever the
plain diff produces for these lines, same as any other template content a
seed happens not to carry. A root-flavored seed that verifies no ownership at
all correctly reports the idiom's template lines as `BEHIND` — this is the
documented, intended output now, not a bug to fix.

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
- With arguments: each argument is a candidate, classified by what it is on
  disk:
  - a **directory** -> a project directory;
  - an **existing file** -> a direct path to a `local-seed.sh`;
  - **nonexistent** -> a **skip**, noted as "not present on this machine".

The nonexistent case was undefined in an earlier draft, which distinguished
arguments solely by `test -d`. That silently conflated "this project is not
checked out here" with "this seed path does not exist", and contradicted the
skip requirement, which is not qualified to auto-discovery: the intended use is
a gate that names the same project list on every machine.

The cost is that a typo'd path skips instead of failing. That is mitigated, not
ignored: a skip prints the path it skipped and is counted in the summary line,
so `5 checked` silently becoming `4 checked, 1 skipped` is visible in the output
a gate captures. The alternative — erroring on a missing project — would make
the tool unusable on any machine that does not have all five checked out, which
is the case the requirement exists to cover.

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

**Skips.** A candidate without a seed, and an argument naming a path that does
not exist, are both reported with a note and do not affect the exit code.

**Exit codes.** `0` clean (skips included); `1` any drift, in any direction; `2`
usage error, unreadable template, doc/template disagreement, or a block that
cannot be extracted — a window that never parses, or unrecognized heredoc
syntax.

A run does not abort on the first bad seed. It reports every candidate, then
exits with the highest severity encountered (`2` outranks `1` outranks `0`), so
one malformed seed cannot hide drift in the other four.

**Extraction failure must never read as clean.** Extraction is verified by
parsing the extracted fragment (Decision 3), so there is no `shfmt`
precondition. Both files are additionally checked with `bash -n` as a whole —
the template as well as each seed, since a broken template would otherwise
silently produce empty blocks that compare equal to everything. An anchor the
template does not contain, a block that extracts to nothing on the template
side, a window that never parses, and unrecognized heredoc syntax are all errors
rather than `ok`: a silent pass in any of them reproduces the exact false-clean
bug being fixed.

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
- **a blank line between an `if` condition and its body does not truncate the
  block.** Guards the window-growth rule in Decision 3; a change in the body
  must still be reported when the anchor is in the condition.
- **a window that never parses -> exit 2**, and a block requiring *upward*
  growth (anchor in the body, `if` header in the preceding paragraph) is
  extracted whole.
- **heredoc payload is compared verbatim**, three cases: a changed `#` line
  inside the `GITEOF` body is drift (not stripped as a comment); a changed blank
  line or leading whitespace inside a body is drift; a trailing `\` in a body is
  not treated as a continuation.
- **an unquoted-delimiter heredoc gets path neutralization, a quoted one does
  not.** Pins the shell-semantics rule in Decision 4.
- **`<<` inside a double-quoted string is not a heredoc opener.** Modelled on
  template line 255 (`GI_MARK_END="# <<< overlay symlinks (auto) <<<"`); a
  regression here swallows the rest of the file.
- **`<<<` herestrings are not heredoc openers**, and each of `<<TAG`,
  `<<'TAG'`, `<<"TAG"`, `<<\TAG`, `<<-TAG` is recognized.
- **unrecognized heredoc syntax -> exit 2**, never a silent fallback.
- anchor absent -> `MISSING`
- extra seed lines -> `AHEAD`, wording is promotion, not overwrite
- differences both directions -> `DIVERGED`
- false-positive guards, one test each: `as_user` vs direct invocation,
  `$SEED_HOME` vs `$HOME`, `$DOTFILES_HOME` vs `$HOME/.dotfiles`, restyled line
  continuations, reworded comments
- **the ownership-verification idiom is not special-cased**: a changed target,
  a changed `-R`, a changed `$SEED_UID:$SEED_GID` identity (on either physical
  half of the idiom), and an unrelated `chown` line each produce ordinary
  drift, the same as any other differing line; a root-flavored seed that
  carries no ownership check at all correctly reports the idiom's two
  template lines as `BEHIND`
- `sed 's#...#g'` survives comment stripping
- an anchor appearing only in a comment does not anchor a block
- candidate with `.devcontainer/` but no seed -> skipped, exit 0, counted as
  skipped; a directory with no `.devcontainer/` is not reported at all
- **a nonexistent argument -> skipped, exit 0**, and the skip names the path
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
