# Seed Drift Detector Implementation Plan

> **Historical record — superseded in part. Not a description of the shipped tool.**
> This plan is kept as written so the design history stays legible. Two things
> it specifies were changed during implementation, on evidence gathered after it
> was written:
>
> 1. **The ownership-verification special case (`SD_OWNERSHIP_DROP` and friends,
>    described around lines 1531 and 1899-1919) was removed entirely.** It was
>    measured to change no verdict on the real corpus, and it failed three ways:
>    per-file asymmetry, blindness to a seed that *replaces* rather than omits
>    the idiom, and `diff` hunk adjacency.
> 2. **A thin-window warning was added**, which this plan does not mention.
>
> For what the tool actually does, read
> `docs/superpowers/specs/2026-08-03-seed-drift-detector-design.md` — that spec
> is the live document and was amended as these decisions were taken.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bin/seed-drift`, which compares each project's gitignored `.devcontainer/local-seed.sh` against the `project-claude-setup` template at block granularity and exits non-zero when any block has drifted.

**Architecture:** A single self-contained Bash executable, following the repository's `bin/` convention. It parses the block table in `catch-up-local-seed.md` for anchors, so the documented model and the executable one cannot disagree. For each anchor it extracts the surrounding block from both files using a heredoc-aware paragraph scanner whose windows are grown until the extracted fragment parses under `bash -n`, normalizes away the known vocabulary differences between seeds while leaving heredoc payloads verbatim, and reports an order-preserving diff (Decision 1) as `ok` / `MISSING` / `BEHIND` / `AHEAD` / `DIVERGED`.

**Tech Stack:** Bash 3.2-compatible shell, awk (the scanner), `diff`, `bats` for
tests. No new dependencies.

**Design spec:** `docs/superpowers/specs/2026-08-03-seed-drift-detector-design.md`. Read it before starting; every decision below traces to a numbered Decision in that document.

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/seed-drift` (create) | The whole detector, sectioned: doc-table parsing, scanner, extraction, normalization, verdicts, discovery/reporting. Standalone, matching `bin/list-check-files`; the repo has no shared library for this and `bin/vekil-proxy` is 939 lines, so one file is idiomatic. |
| `tests/seed_drift.bats` (create) | The full suite, fixture-driven. Never reads the real `~/workspace`. |
| `bin/list-check-files` | **Unchanged.** Verified against a stub: `is_direct_bin_shell` already emits `bin/seed-drift` for both the `shellcheck` and `shfmt` classes. |

### Why one file

Each section has a clear boundary and the functions are pure filters with fixed
stdout formats (see the interface contract in each task), so the units are
independently testable even though they share a file. Splitting into a `lib/`
would be the only instance of that pattern in the repository.

---

## Interface Contract

Every task honors this. It is fixed; do not renegotiate it mid-implementation.

**Scan format** — the scanner is the single source of truth for structure. Every
consumer reads this 4-field, TAB-separated format, `text` last:

```
para <TAB> lineno <TAB> tag <TAB> text
```

- `para` — 1-based paragraph index (blank-line delimited, heredoc-aware)
- `lineno` — 1-based line number in the source file
- `tag` — `C` shell code (text is comment-stripped, may be empty) / `Hq` heredoc
  body with a quoted delimiter (literal) / `Hu` heredoc body with an unquoted
  delimiter (shell expands it). Heredoc delimiter lines themselves are `C`.
- `text` — comment-stripped for `C`; **verbatim** for `Hq` and `Hu`

**Functions**

| Signature | Returns |
|---|---|
| `sd_scan FILE` | scan format on stdout; exit 3 on unrecognized `<<` |
| `sd_parse_doc DOCFILE` | `blockname<TAB>anchor` per table row (Decision 2) |
| `sd_paras_with_anchor SCAN ANCHOR` | paragraph indices, one per line (fixed-string match, `C` text only) |
| `sd_para_range SCAN PARA` | `start end` file line numbers |
| `sd_window FILE SCAN PARA` | `start end`, grown until it parses; exit 3 if it never does |
| `sd_normalize` | filter: scan format on stdin -> normalized text lines on stdout |
| `sd_extract FILE SCAN ANCHOR` | normalized lines for the union of windows, file order, deduped; exit 4 if the anchor is absent |
| `sd_tmp VARNAME` | assigns a fresh temp-file path to VARNAME in the caller's scope; exit 3 if `mktemp` fails. **Never** call as `$(sd_tmp)` — see Task 5 |
| `sd_verdict_from_counts NB NA` | prints `ok` \| `BEHIND` \| `AHEAD` \| `DIVERGED` from two difference counts; cannot fail |
| `sd_verdict TPL_NORM SEED_NORM` | prints `ok` \| `BEHIND` \| `AHEAD` \| `DIVERGED`; exit 3 if `diff` fails |
| `sd_check_seed SEED` | per-block report; returns 0 clean / 1 drift / 2 error |

Exit codes 3 and 4 are internal to helpers so they never collide with the
program's own 0/1/2.

**CLI**

```
bin/seed-drift [--template PATH] [--doc PATH] [--help] [CANDIDATE...]
env SEED_DRIFT_ROOT   default "$HOME/workspace"
```

`--template` and `--doc` exist so the suite can point at fixtures.

**Sourcing guard.** Every test reaches the helper functions by sourcing
`bin/seed-drift`, so main must not run on source. Use the repository's existing
convention (`bin/bootstrap`, `bin/install`, `bin/vekil-proxy`, consumed by
`tests/link_reconciliation.bats` and `tests/font_install.bats`) rather than a
`BASH_SOURCE` comparison — the env-var form is what the suite already knows how
to drive. The bottom of the file is:

```bash
if [[ "${SEED_DRIFT_SOURCE_ONLY:-0}" != 1 ]]; then
  sd_main "$@"
fi
```

Every source site in the tests **must** set `SEED_DRIFT_SOURCE_ONLY=1`. Omitting
it runs the full detector before the function under test is even called.

**Paragraph indices** are contiguous and 1-based.

---

## Global Constraints

- **Bash 3.2 compatibility for `bin/seed-drift`.** macOS is a supported platform
  (`README.md:3`) and its system bash is still 3.2 — `bin/common.sh:394` says so
  in as many words. Do not introduce `declare -A`, `mapfile`/`readarray`,
  `${var,,}`/`${var^^}`, or negative array indices. Everything this plan
  specifies is already 3.2-clean; keep it that way.
  This constraint covers `bin/seed-drift` only. The **test suite** may use GNU
  `sed -i` and `stat -c`, matching `tests/project_claude_setup_seed.bats` and
  `tests/ai_installers.bats`, because CI is `ubuntu-latest` only
  (`.github/workflows/check.yml:13`).

- `bin/seed-drift` is `shfmt -i 2 -ci` clean — verified by `bin/list-check-files shfmt | xargs -0 shfmt -d -i 2 -ci` (the `lint` target).
- `bin/seed-drift` is `shellcheck -x -S warning -e SC1091` clean — verified by `bin/list-check-files shellcheck | xargs -0 shellcheck -x -S warning -e SC1091` (the `lint` target).
- `bin/seed-drift` is executable (`chmod +x`) and lives directly in `bin/` with no extension.
- Auto-discovery is already handled: `is_direct_bin_shell` in `bin/list-check-files:26-31` matches `bin/*` paths with no `/` after `bin/` and either no `.` or a `.sh` suffix, and it is applied by the `bash`, `shellcheck`, and `shfmt` cases (lines 54, 60, 63). `bin/seed-drift` matches, so **no `bin/list-check-files` change is required**.
- `.bats` files are emitted for neither linter (`shfmt` takes only `tests/test_helper.bash`), so `tests/seed_drift.bats` is unlinted. That gap is deliberate, consistent with all 22 existing suites, and is left alone.
- The detector is strictly **READ-ONLY**: seeds are gitignored, hand-owned files with no `git diff` and no revert path. Nothing in `bin/seed-drift` may open a seed for writing.
- `SEED_VERSION` must never be compared, and must never appear as an anchor or in a comparison path.
- `command make check` must pass — it runs `syntax lint test python-test validate`; baseline before this work is **330 passing bats tests** (measured on this branch
  after rebasing onto `origin/main` at #41, which added seven).
- All bats tests use fixture `--template` / `--doc` files and a fixture `SEED_DRIFT_ROOT`; no test may depend on the real `~/workspace`.
- `make` is shadowed by a zsh function in this environment; every make invocation is written `command make`.

---

---

### Task 1: CLI skeleton, doc table parsing, template anchor validation

**Files:**
- Create: `bin/seed-drift` (executable, `chmod +x`)
- Create: `tests/seed_drift.bats`

**Interfaces:**

*Consumes:* nothing — this is the first task.

*Produces:*
- `bin/seed-drift [--template PATH] [--doc PATH] [--help] [CANDIDATE...]` — `--help` prints usage on **stdout**, exit 0. Unknown flag, a flag missing its value, an unreadable `--template`, an unreadable `--doc`, a doc with no block table, or a doc anchor absent from the template all print to **stderr** and exit **2**.
- `sd_parse_doc DOCFILE` — stdout, one line per table row: `blockname<TAB>anchor`. Backticks are stripped from *both* fields; the anchor keeps its inner quotes and asterisks verbatim (row 2 is exactly `Overlay-link gitignore<TAB>lname '*dotfiles/projects/*'`). Returns 3 if `DOCFILE` is unreadable, 1 if the file holds no table rows.
- `SD_TEMPLATE_DEFAULT`, `SD_DOC_DEFAULT` — absolute paths resolved from `${BASH_SOURCE[0]}`, so the script works from any cwd.
- `SD_CANDIDATES` — global array holding the positional arguments after flag parsing. Task 6 (discovery) reads this. `SD_CANDIDATE_COUNT` — scalar count of the same, incremented alongside every push. Task 6 branches on the scalar: `${#SD_CANDIDATES[@]}` on an empty array is exactly the `set -u` / bash 3.2 hazard `bin/common.sh:392` documents.
- `SEED_DRIFT_SOURCE_ONLY=1` — sourcing guard (repo convention, mirrors `INSTALL_SOURCE_ONLY` in `bin/install`). When set, sourcing `bin/seed-drift` defines the functions without running `sd_main`. Every unit test in `tests/seed_drift.bats` uses the `sd_source` helper this task adds.

All commands run from the repo root `/home/tng/.dotfiles/.claude/worktrees/seed-drift-detector`.

---

- [ ] **Step 1: Write the failing CLI tests.**

Create `tests/seed_drift.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  SEED_DRIFT="$REPO_ROOT/bin/seed-drift"
  SKILL_DIR="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup"
  REAL_TEMPLATE="$SKILL_DIR/templates/local-seed.sh"
  REAL_DOC="$SKILL_DIR/catch-up-local-seed.md"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX"
}

sd_source() {
  run env SEED_DRIFT_SOURCE_ONLY=1 bash -c '
    source "$1"
    shift
    "$@"
  ' _ "$SEED_DRIFT" "$@"
}

@test "seed-drift --help prints usage and exits 0" {
  run "$SEED_DRIFT" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: bin/seed-drift"* ]]
}

@test "seed-drift rejects an unknown flag with usage on exit 2" {
  run "$SEED_DRIFT" --nope

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option --nope"* ]]
  [[ "$output" == *"Usage: bin/seed-drift"* ]]
}

@test "seed-drift rejects --template with no value" {
  run "$SEED_DRIFT" --template

  [ "$status" -eq 2 ]
  [[ "$output" == *"--template needs a PATH"* ]]
}

@test "seed-drift exits 2 when the template is unreadable" {
  run "$SEED_DRIFT" --template "$TEST_ROOT/missing.sh" --doc "$REAL_DOC"

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read template"* ]]
}

@test "seed-drift exits 2 when the doc is unreadable" {
  run "$SEED_DRIFT" --template "$REAL_TEMPLATE" --doc "$TEST_ROOT/missing.md"

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read doc"* ]]
}
```

- [ ] **Step 2: Run them and see them fail.**

```
bats tests/seed_drift.bats -f 'seed-drift'
```

Expected: `1..5`, all five `not ok`. `bin/seed-drift` does not exist, so `run` records status 127 and the first assertion in each test fails (`[ "$status" -eq 0 ]` / `-eq 2`).

- [ ] **Step 3: Implement the CLI skeleton.**

Create `bin/seed-drift` and `chmod +x bin/seed-drift`:

```bash
#!/usr/bin/env bash

set -euo pipefail

SD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SD_REPO_ROOT="${SD_SELF_DIR%/bin}"
SD_SKILL_DIR="$SD_REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup"
SD_TEMPLATE_DEFAULT="$SD_SKILL_DIR/templates/local-seed.sh"
SD_DOC_DEFAULT="$SD_SKILL_DIR/catch-up-local-seed.md"

sd_usage() {
  cat <<'SDUSAGE'
Usage: bin/seed-drift [--template PATH] [--doc PATH] [--help] [CANDIDATE...]

Reports, per project and per documented block, whether a project's
.devcontainer/local-seed.sh is behind, ahead of, or diverged from the
project-claude-setup template.

  --template PATH  template to compare against
  --doc PATH       catch-up doc holding the block table
  --help           show this message

With no CANDIDATE, candidates are ${SEED_DRIFT_ROOT:-$HOME/workspace}/*/.
Exit: 0 clean, 1 drift, 2 usage/template/doc/extraction error.
SDUSAGE
}

sd_main() {
  local template="$SD_TEMPLATE_DEFAULT" doc="$SD_DOC_DEFAULT"
  SD_CANDIDATES=()
  # Counted alongside the array because Task 6 must ask "were any candidates
  # given?" without expanding an empty array under `set -u` — the bash 3.2
  # pitfall bin/common.sh:392 calls out. macOS ships bash 3.2.
  SD_CANDIDATE_COUNT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --template | --doc)
        if [ $# -lt 2 ]; then
          printf 'seed-drift: %s needs a PATH\n' "$1" >&2
          sd_usage >&2
          return 2
        fi
        if [ "$1" = --template ]; then template="$2"; else doc="$2"; fi
        shift 2
        ;;
      --help | -h)
        sd_usage
        return 0
        ;;
      --)
        shift
        SD_CANDIDATES+=("$@")
        SD_CANDIDATE_COUNT=$((SD_CANDIDATE_COUNT + $#))
        break
        ;;
      -*)
        printf 'seed-drift: unknown option %s\n' "$1" >&2
        sd_usage >&2
        return 2
        ;;
      *)
        SD_CANDIDATES+=("$1")
        SD_CANDIDATE_COUNT=$((SD_CANDIDATE_COUNT + 1))
        shift
        ;;
    esac
  done

  if [ ! -r "$template" ]; then
    printf 'seed-drift: cannot read template %s\n' "$template" >&2
    return 2
  fi
  if [ ! -r "$doc" ]; then
    printf 'seed-drift: cannot read doc %s\n' "$doc" >&2
    return 2
  fi

  return 0
}

if [ "${SEED_DRIFT_SOURCE_ONLY:-0}" != 1 ]; then
  sd_main "$@"
fi
```

The two `-r` guards belong in this step, not a later one: without them `template` and `doc` are assigned and never read, and `shellcheck -S warning` reports SC2034 on both.

- [ ] **Step 4: Run them and see them pass.**

```
bats tests/seed_drift.bats -f 'seed-drift'
```

Expected: `1..5` with all five `ok` — `ok 1 seed-drift --help prints usage and exits 0` through `ok 5 seed-drift exits 2 when the doc is unreadable`.

Then confirm the linters, which discover `bin/seed-drift` automatically via `is_direct_bin_shell`:

```
shellcheck -x -S warning bin/seed-drift && shfmt -i 2 -ci -d bin/seed-drift
```

Expected: no output from either, exit 0.

- [ ] **Step 5: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: add bin/seed-drift CLI skeleton with flag and path validation"
```

- [ ] **Step 6: Write the failing `sd_parse_doc` tests.**

Append to `tests/seed_drift.bats`, keeping the helper block together — insert `write_fixture_doc` directly below `sd_source`, and the two `@test` blocks at the end of the file:

```bash
write_fixture_doc() {
  cat >"$1" <<'DOC'
| Block | Anchor in template | Why it matters |
|---|---|---|
| Overlay-link gitignore | `lname '*dotfiles/projects/*'` | Adds overlay links. |
| `core.excludesFile` | `core.excludesFile` | Points git at the seeded ignore file. |
DOC
}
```

```bash
@test "sd_parse_doc emits blockname TAB anchor and keeps quotes in the anchor" {
  local doc="$TEST_ROOT/doc.md"
  write_fixture_doc "$doc"

  sd_source sd_parse_doc "$doc"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'Overlay-link gitignore\tlname '"'"'*dotfiles/projects/*'"'"'')" ]
  [ "${lines[1]}" = "$(printf 'core.excludesFile\tcore.excludesFile')" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "sd_parse_doc reads all nine blocks from the real catch-up doc" {
  sd_source sd_parse_doc "$REAL_DOC"

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
  [[ "$output" == *"TREE_SITTER_VERSION"* ]]
  [[ "$output" == *"lname '*dotfiles/projects/*'"* ]]
}
```

- [ ] **Step 7: Run them and see them fail.**

```
bats tests/seed_drift.bats -f 'sd_parse_doc'
```

Expected: `1..2`, both `not ok`. `sd_parse_doc` is undefined, so the sourced subshell reports `sd_parse_doc: command not found` and `[ "$status" -eq 0 ]` fails at status 127.

- [ ] **Step 8: Implement `sd_parse_doc`.**

Insert into `bin/seed-drift` between `sd_usage()` and `sd_main()`:

```bash
SD_DOC_AWK=$(
  cat <<'SDAWK'
BEGIN { FS = "|" }
/^\|/ && NF >= 4 {
  name = $2
  anchor = $3
  gsub(/^[ \t]+|[ \t]+$/, "", name)
  gsub(/^[ \t]+|[ \t]+$/, "", anchor)
  if (name == "Block" || name ~ /^-+$/) next
  if (anchor !~ /^`.*`$/) next
  gsub(/`/, "", name)
  sub(/^`/, "", anchor)
  sub(/`$/, "", anchor)
  printf("%s\t%s\n", name, anchor)
  rows++
}
END { if (rows == 0) exit 1 }
SDAWK
)

sd_parse_doc() {
  local doc="$1"
  if [ ! -r "$doc" ]; then
    printf 'seed-drift: cannot read doc %s\n' "$doc" >&2
    return 3
  fi
  awk "$SD_DOC_AWK" <"$doc"
}
```

Three details are load-bearing. The guard requiring column 2 to be backtick-quoted skips the header and `|---|` separator rows without needing a row counter, and it also rejects any future table in the doc whose second column is not an anchor. The `gsub` on `name` removes *all* backticks rather than only a leading/trailing pair — three rows in the real doc (`core.excludesFile`, `~/.config/nvim` link, `load-custom.zsh` loader) would otherwise keep a stray backtick mid-name. The anchor uses `sub` for the outer pair only, so `lname '*dotfiles/projects/*'` survives with its single quotes and asterisks intact.

- [ ] **Step 9: Run them and see them pass.**

```
bats tests/seed_drift.bats -f 'sd_parse_doc'
```

Expected: `1..2`, `ok 1 sd_parse_doc emits blockname TAB anchor and keeps quotes in the anchor` and `ok 2 sd_parse_doc reads all nine blocks from the real catch-up doc`.

- [ ] **Step 10: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: parse the catch-up doc block table into blockname/anchor pairs"
```

- [ ] **Step 11: Write the failing anchor-validation tests.**

Append to `tests/seed_drift.bats`:

```bash
@test "every anchor in the real doc table is present in the real template" {
  run "$SEED_DRIFT" --template "$REAL_TEMPLATE" --doc "$REAL_DOC"

  [ "$status" -eq 0 ]
}

@test "a doc anchor the template lacks is a hard error" {
  local doc="$TEST_ROOT/doc.md" template="$TEST_ROOT/tpl.sh"
  write_fixture_doc "$doc"
  printf '#!/usr/bin/env bash\ntrue\n' >"$template"

  run "$SEED_DRIFT" --template "$template" --doc "$doc"

  [ "$status" -eq 2 ]
  [[ "$output" == *"is absent from"* ]]
  [[ "$output" == *"core.excludesFile"* ]]
}
```

- [ ] **Step 12: Run them and see them fail.**

```
bats tests/seed_drift.bats -f 'anchor'
```

Expected: `1..2` with `ok 1 every anchor in the real doc table is present in the real template` (it passes vacuously — `sd_main` returns 0 without validating anything yet) and `not ok 2 a doc anchor the template lacks is a hard error`, failing on `[ "$status" -eq 2 ]` because the run exits 0. Test 1 is the regression guard for the code added in Step 13; test 2 is the red one.

- [ ] **Step 13: Implement the anchor check in `sd_main`.**

In `bin/seed-drift`, replace the trailing `return 0` of `sd_main` (the last statement, after the two `-r` guards) with:

```bash
  local blocks
  if ! blocks=$(sd_parse_doc "$doc"); then
    printf 'seed-drift: no block table found in %s\n' "$doc" >&2
    return 2
  fi

  local name anchor absent=0
  while IFS=$'\t' read -r name anchor; do
    # Raw grep is deliberately the Task 1 form; Task 6 replaces it with a check
    # against the template scan's C records once the scanner exists, so that an
    # anchor appearing only in a comment fails validation.
    if ! grep -qF -- "$anchor" "$template"; then
      printf 'seed-drift: anchor %s (block: %s) is absent from %s\n' \
        "$anchor" "$name" "$template" >&2
      absent=1
    fi
  done <<<"$blocks"
  if [ "$absent" -ne 0 ]; then
    return 2
  fi

  return 0
```

`grep -qF --` is required, not optional: `-F` because `lname '*dotfiles/projects/*'` contains regex metacharacters, and `--` because an anchor could begin with `-`. The loop does not short-circuit on the first absent anchor, so one run reports every doc/template disagreement.

- [ ] **Step 14: Run them and see them pass.**

```
bats tests/seed_drift.bats
```

Expected: `1..9`, all `ok`, ending `ok 9 a doc anchor the template lacks is a hard error`.

```
shellcheck -x -S warning bin/seed-drift && shfmt -i 2 -ci -d bin/seed-drift
```

Expected: no output, exit 0.

- [ ] **Step 15: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: fail with exit 2 when a doc anchor is absent from the template"
```

---

### Task 2: heredoc-aware, quote-aware paragraph scanner (`sd_scan`)

**Files:**
- Modify: `bin/seed-drift`
- Modify: `tests/seed_drift.bats`

**Interfaces:**

*Consumes (from Task 1):* `bin/seed-drift` with `set -euo pipefail`, the `SEED_DRIFT_SOURCE_ONLY=1` sourcing guard, and the `sd_source` bats helper.

*Produces:*
- `sd_scan FILE` — writes the contract scan format to stdout, one record per source line:

  ```
  para <TAB> lineno <TAB> tag <TAB> text
  ```

  `para` is a 1-based, blank-line-delimited, heredoc-aware paragraph index; `lineno` is the 1-based line number in `FILE`; `tag` is `C` (shell code, `text` comment-stripped, possibly empty), `Hq` (heredoc body, quoted delimiter — literal payload) or `Hu` (heredoc body, unquoted delimiter — the shell would expand it). `text` is verbatim for `Hq`/`Hu`. Both heredoc *delimiter* lines — the opener, which is ordinary code, and the closer — are tagged `C`. Blank lines outside a heredoc emit no record; blank lines inside a heredoc body do, and do not end the paragraph.

  Returns **3** on any `<<` it cannot classify, on an unterminated heredoc-delimiter quote, on an unterminated heredoc body at EOF, and on an unreadable `FILE`. It never guesses.

- `SD_SCAN_AWK` — the awk program, as a shell variable. Later tasks call `sd_scan`, not awk directly.

Every consumer in Tasks 3-8 (`sd_paras_with_anchor`, `sd_para_range`,
`sd_window`, `sd_normalize`, `sd_extract`) reads this exact 4-field format.
`text` is last so it may contain tabs — but **neither obvious reader preserves
them**, and heredoc payloads are required to be verbatim:

- `IFS=$'\t' read -r para lineno tag text` strips *leading* tabs from `text`,
  because tab is IFS whitespace. That is exactly the `<<-` indented-body case.
- `awk -F'\t'`'s `$4` stops at the next tab, silently truncating the rest.

So consumers must split positionally instead: in shell, read the whole record
with `IFS= read -r rec` and peel three fields with `${rec%%$'\t'*}` /
`${rec#*$'\t'}`, leaving the remainder untouched; in awk, take the text as
everything after the third tab via `sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t)`.
Both are specified below and pinned by a tab-payload test in Task 7.

---

- [ ] **Step 1: Write the failing paragraph-splitting test.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan numbers every line and starts a new paragraph after a blank line" {
  local f="$TEST_ROOT/paras.sh"
  printf '%s\n' 'first=1' 'second=2' '' '   ' 'third=3' >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '1\t1\tC\tfirst=1')" ]
  [ "${lines[1]}" = "$(printf '1\t2\tC\tsecond=2')" ]
  [ "${lines[2]}" = "$(printf '2\t5\tC\tthird=3')" ]
  [ "${#lines[@]}" -eq 3 ]
}
```

The whitespace-only line 4 must count as blank, and two consecutive blank lines must advance the paragraph index by one, not two.

- [ ] **Step 2: Run it and see it fail.**

```
bats tests/seed_drift.bats -f 'numbers every line'
```

Expected: `1..1`, `not ok 1 sd_scan numbers every line and starts a new paragraph after a blank line`. `sd_scan` is undefined; the sourced subshell exits 127 and `[ "$status" -eq 0 ]` fails.

- [ ] **Step 3: Implement paragraph splitting.**

Insert into `bin/seed-drift`, between `sd_parse_doc` and `sd_main`:

```bash
SD_SCAN_AWK=$(
  cat <<'SDAWK'
function emit(tag, text) {
  if (para == 0 || brk) {
    para++
    brk = 0
  }
  printf("%d\t%d\t%s\t%s\n", para, NR, tag, text)
}
{
  if ($0 ~ /^[ \t]*$/) {
    brk = 1
    next
  }
  emit("C", $0)
}
SDAWK
)

sd_scan() {
  local file="$1"
  if [ ! -r "$file" ]; then
    printf 'seed-drift: cannot read %s\n' "$file" >&2
    return 3
  fi
  awk "$SD_SCAN_AWK" <"$file"
}
```

The redirect `<"$file"` rather than passing the path as an awk operand is deliberate: an operand containing `=` would be parsed by awk as a variable assignment instead of a filename. `NR` is still the file's line number because exactly one stream is read.

- [ ] **Step 4: Run it and see it pass.**

```
bats tests/seed_drift.bats -f 'numbers every line'
```

Expected: `1..1`, `ok 1 sd_scan numbers every line and starts a new paragraph after a blank line`.

- [ ] **Step 5: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: add sd_scan with blank-line paragraph splitting"
```

- [ ] **Step 6: Write the failing comment-stripping test.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan strips comments quote-aware so a sed s#...#g program survives" {
  local f="$TEST_ROOT/comments.sh"
  cat >"$f" <<'FIX'
# whole line comment
links="$(find . | sed 's#^\./##')" # trailing note
echo "kept # inside quotes"
FIX

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '1\t1\tC\t')" ]
  [ "${lines[1]}" = "$(printf '1\t2\tC\tlinks="$(find . | sed '"'"'s#^\\./##'"'"')" ')" ]
  [ "${lines[2]}" = "$(printf '1\t3\tC\techo "kept # inside quotes"')" ]
}
```

Line 2 is modelled on template line 261. Its `#` characters are inside a single-quoted `sed` program and must survive; the `# trailing note` after them must not. The expected text keeps the space before the stripped comment — trimming belongs to `sd_normalize`, not the scanner.

- [ ] **Step 7: Run it and see it fail.**

```
bats tests/seed_drift.bats -f 'quote-aware'
```

Expected: `1..1`, `not ok 1 sd_scan strips comments quote-aware so a sed s#...#g program survives`, failing at `[ "${lines[0]}" = "$(printf '1\t1\tC\t')" ]` — line 1 is currently emitted verbatim as `1<TAB>1<TAB>C<TAB># whole line comment`.

- [ ] **Step 8: Implement the quote-aware character scan.**

Replace the whole `SD_SCAN_AWK` heredoc body in `bin/seed-drift` with:

```awk
function emit(tag, text) {
  if (para == 0 || brk) {
    para++
    brk = 0
  }
  printf("%d\t%d\t%s\t%s\n", para, NR, tag, text)
}
function scan(line,   n, i, c) {
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (inq == "'") {
      if (c == "'") inq = ""
      i++
      continue
    }
    if (inq == "\"") {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") inq = ""
      i++
      continue
    }
    if (c == "\\") { i += 2; continue }
    if (c == "'") { inq = "'"; i++; continue }
    if (c == "\"") { inq = "\""; i++; continue }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) return substr(line, 1, i - 1)
    i++
  }
  return line
}
{
  if ($0 ~ /^[ \t]*$/ && inq == "") {
    brk = 1
    next
  }
  emit("C", scan($0))
}
```

`inq` is intentionally **not** a local of `scan()`: it is a file-scope global, so an unterminated quote carries into the next line. That is what makes template lines 260-261 — a double-quoted string continued across a `\` line break — track correctly, and it is why the blank-line rule now also requires `inq == ""`. Backslash outside quotes and inside double quotes consumes the next character; inside single quotes it does not, matching the shell. A `#` counts as a comment only at column 1 or after whitespace, which is what keeps `sed 's#^\./##'` intact even before quote state is consulted.

- [ ] **Step 9: Run it and see it pass.**

```
bats tests/seed_drift.bats -f 'quote-aware|numbers every line'
```

Expected: `1..2`, both `ok`.

- [ ] **Step 10: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: strip shell comments quote-aware in sd_scan"
```

- [ ] **Step 11: Write the failing heredoc-body tests.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan keeps a quoted heredoc body in one paragraph and tags it Hq" {
  local f="$TEST_ROOT/hd.sh"
  cat >"$f" <<'FIX'
GITIGNORE="$HOME/.gitignore"
tee "$GITIGNORE" <<'GITEOF'
.DS_Store

# Personal overlay shims.
CLAUDE.local.md
GITEOF
git config --global core.excludesFile "$GITIGNORE"
FIX

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "$(printf '1\t3\tHq\t.DS_Store')" ]
  [ "${lines[3]}" = "$(printf '1\t4\tHq\t')" ]
  [ "${lines[4]}" = "$(printf '1\t5\tHq\t# Personal overlay shims.')" ]
  [ "${lines[6]}" = "$(printf '1\t7\tC\tGITEOF')" ]
  [ "${lines[7]}" = "$(printf '1\t8\tC\tgit config --global core.excludesFile "$GITIGNORE"')" ]
}

@test "sd_scan does not treat << inside a double-quoted string as a heredoc" {
  local f="$TEST_ROOT/quoted.sh"
  cat >"$f" <<'FIX'
GI_MARK_END="# <<< overlay symlinks (auto) <<<"
echo done

echo after
FIX

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '1\t1\tC\tGI_MARK_END="# <<< overlay symlinks (auto) <<<"')" ]
  [ "${lines[1]}" = "$(printf '1\t2\tC\techo done')" ]
  [ "${lines[2]}" = "$(printf '2\t4\tC\techo after')" ]
}

@test "sd_scan fails closed on unrecognized heredoc syntax" {
  local f="$TEST_ROOT/bad.sh"
  printf 'cat << ;\n' >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 3 ]
  [[ "$output" == *"unrecognized heredoc delimiter"* ]]
}

@test "sd_scan puts the real template core.excludesFile block in one paragraph" {
  run env SEED_DRIFT_SOURCE_ONLY=1 bash -c '
    source "$1"
    scan=$(sd_scan "$2")
    para=$(printf "%s\n" "$scan" | awk -F"\t" "\$3 == \"C\" && index(\$4, \"core.excludesFile\") { print \$1 }")
    printf "%s\n" "$scan" | awk -F"\t" -v p="$para" "\$1 == p { print \$2 }" |
      awk "NR == 1 { first = \$0 } { last = \$0 } END { print first, last }"
  ' _ "$SEED_DRIFT" "$REAL_TEMPLATE"

  [ "$status" -eq 0 ]
  [ "$output" = "204 236" ]
}
```

The last test is the one Decision 3 turns on: the `core.excludesFile` code use at template line 236 must land in a paragraph running 204-236, spanning the comment preamble, the `GITIGNORE=` assignment, the whole `GITEOF` heredoc including its blank lines at 223 and 229, and the `git config` line. The third test pins the fail-closed rule. The second is the guard against a naive `<<` matcher: template line 255 sits inside the overlay-gitignore anchored block, and misreading it swallows the rest of the file — it passes already, and must keep passing.

- [ ] **Step 12: Run them and see them fail.**

```
bats tests/seed_drift.bats -f 'Hq|as a heredoc|fails closed on unrecognized|one paragraph'
```

Expected: `1..4` with

```
not ok 1 sd_scan keeps a quoted heredoc body in one paragraph and tags it Hq
ok 2 sd_scan does not treat << inside a double-quoted string as a heredoc
not ok 3 sd_scan fails closed on unrecognized heredoc syntax
not ok 4 sd_scan puts the real template core.excludesFile block in one paragraph
```

Test 1 fails at `[ "${lines[2]}" = "$(printf '1\t3\tHq\t.DS_Store')" ]` (the body is still tagged `C` and its blank line splits the paragraph); test 3 fails at `[ "$status" -eq 3 ]` (currently 0); test 4 fails at `[ "$output" = "204 236" ]`. Test 2 is green and is the regression guard for Step 13.

- [ ] **Step 13: Implement heredoc openers, body tracking, and fail-closed errors.**

Replace the whole `SD_SCAN_AWK` heredoc body with:

```awk
function fail(msg) {
  printf("seed-drift: %s (line %d)\n", msg, NR) >"/dev/stderr"
  failed = 1
  exit 3
}
function emit(tag, text) {
  if (para == 0 || brk) {
    para++
    brk = 0
  }
  printf("%d\t%d\t%s\t%s\n", para, NR, tag, text)
}
function delimword(line, i, n,   w, c) {
  w = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (c !~ /[A-Za-z0-9_.-]/) break
    w = w c
    i++
  }
  wend = i
  return w
}
function scan(line,   n, i, c, j, w) {
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (inq == "'") {
      if (c == "'") inq = ""
      i++
      continue
    }
    if (inq == "\"") {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") inq = ""
      i++
      continue
    }
    if (c == "\\") { i += 2; continue }
    if (c == "'") { inq = "'"; i++; continue }
    if (c == "\"") { inq = "\""; i++; continue }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) return substr(line, 1, i - 1)
    if (c != "<") { i++; continue }
    if (substr(line, i, 2) != "<<") { i++; continue }
    i += 2
    c = substr(line, i, 1)
    if (c == "'" || c == "\"") {
      j = index(substr(line, i + 1), c)
      if (j == 0) fail("unterminated heredoc delimiter quote")
      hdelim = substr(line, i + 1, j - 1)
      hquot = 1
      opened = 1
      i = i + j + 1
      continue
    }
    w = delimword(line, i, n)
    if (w == "") fail("unrecognized heredoc delimiter after <<")
    hdelim = w
    hquot = 0
    opened = 1
    i = wend
  }
  return line
}
{
  if (hd) {
    if ($0 == hdelim) {
      emit("C", $0)
      hd = 0
    } else {
      emit(hquot ? "Hq" : "Hu", $0)
    }
    next
  }
  if ($0 ~ /^[ \t]*$/ && inq == "") {
    brk = 1
    next
  }
  opened = 0
  emit("C", scan($0))
  if (opened) hd = 1
}
```

Heredoc detection lives *inside* the same quote-state loop that already drives comment stripping, which is precisely why `GI_MARK_END="# <<< overlay symlinks (auto) <<<"` is inert: by the time the scanner reaches those `<<` characters, `inq` is `"` and the code never reaches the `c != "<"` branch. `delimword` returning the empty string is the fail-closed path — `<<` followed by anything that is not a quote and not a delimiter word is an error, never a shrug. `wend` is a deliberate global out-parameter (awk has no other way to return two values). Note that `fail()` calls `exit 3`, which still runs `END`, so `failed` is set for the guard added in Step 28.

- [ ] **Step 14: Run them and see them pass.**

```
bats tests/seed_drift.bats -f 'sd_scan'
```

Expected: `1..6`, all `ok`, including `ok 4 sd_scan puts the real template core.excludesFile block in one paragraph`.

- [ ] **Step 15: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: track heredoc bodies in sd_scan and fail closed on unknown <<"
```

- [ ] **Step 16: Write the failing delimiter-form test.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan excludes herestrings and recognizes every delimiter form" {
  local f="$TEST_ROOT/forms.sh"
  printf '%s\n' \
    'grep q <<<"$v"' \
    'cat <<A' \
    'u1' \
    'A' \
    "cat <<'B'" \
    'q1' \
    'B' \
    'cat <<"C"' \
    'q2' \
    'C' \
    'cat <<\D' \
    'q3' \
    'D' \
    'cat <<-E' \
    $'\tu2' \
    $'\tE' >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf '1\t1\tC\tgrep q <<<"$v"')" ]
  [ "${lines[2]}" = "$(printf '1\t3\tHu\tu1')" ]
  [ "${lines[5]}" = "$(printf '1\t6\tHq\tq1')" ]
  [ "${lines[8]}" = "$(printf '1\t9\tHq\tq2')" ]
  [ "${lines[11]}" = "$(printf '1\t12\tHq\tq3')" ]
  [ "${lines[14]}" = "$(printf '1\t15\tHu\t\tu2')" ]
  [ "${lines[15]}" = "$(printf '1\t16\tC\t\tE')" ]
}
```

`$'\t'` quoting is required for the two `<<-E` lines — a real tab, since `<<-` strips tabs only. The last two assertions check that the `<<-` body keeps its leading tab in `text` while the *closer* is still recognized after tab-stripping and tagged `C`.

- [ ] **Step 17: Run it and see it fail.**

```
bats tests/seed_drift.bats -f 'delimiter form'
```

Expected: `1..1`, `not ok 1 sd_scan excludes herestrings and recognizes every delimiter form`, failing at `[ "${lines[2]}" = "$(printf '1\t3\tHu\tu1')" ]`. Line 1's `<<<` is currently read as `<<` followed by `<`, `delimword` returns empty, and the run dies with `unrecognized heredoc delimiter after <<` at status 3 — the fail-closed path doing exactly its job on a form it has not been taught yet.

- [ ] **Step 18: Implement `<<<`, `<<\TAG`, and the `<<-` variants.**

Replace the whole `SD_SCAN_AWK` heredoc body with:

```awk
function fail(msg) {
  printf("seed-drift: %s (line %d)\n", msg, NR) >"/dev/stderr"
  failed = 1
  exit 3
}
function emit(tag, text) {
  if (para == 0 || brk) {
    para++
    brk = 0
  }
  printf("%d\t%d\t%s\t%s\n", para, NR, tag, text)
}
function delimword(line, i, n,   w, c) {
  w = ""
  while (i <= n) {
    c = substr(line, i, 1)
    if (c !~ /[A-Za-z0-9_.-]/) break
    w = w c
    i++
  }
  wend = i
  return w
}
function scan(line,   n, i, c, j, d, w) {
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (inq == "'") {
      if (c == "'") inq = ""
      i++
      continue
    }
    if (inq == "\"") {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") inq = ""
      i++
      continue
    }
    if (c == "\\") { i += 2; continue }
    if (c == "'") { inq = "'"; i++; continue }
    if (c == "\"") { inq = "\""; i++; continue }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) return substr(line, 1, i - 1)
    if (c != "<") { i++; continue }
    if (substr(line, i, 3) == "<<<") { i += 3; continue }
    if (substr(line, i, 2) != "<<") { i++; continue }
    i += 2
    d = 0
    if (substr(line, i, 1) == "-") { d = 1; i++ }
    while (substr(line, i, 1) == " " || substr(line, i, 1) == "\t") i++
    c = substr(line, i, 1)
    if (c == "'" || c == "\"") {
      j = index(substr(line, i + 1), c)
      if (j == 0) fail("unterminated heredoc delimiter quote")
      hdelim = substr(line, i + 1, j - 1)
      hquot = 1
      hdash = d
      opened = 1
      i = i + j + 1
      continue
    }
    if (c == "\\") {
      w = delimword(line, i + 1, n)
      if (w == "") fail("unrecognized heredoc delimiter after <<")
      hdelim = w
      hquot = 1
      hdash = d
      opened = 1
      i = wend
      continue
    }
    w = delimword(line, i, n)
    if (w == "") fail("unrecognized heredoc delimiter after <<")
    hdelim = w
    hquot = 0
    hdash = d
    opened = 1
    i = wend
  }
  return line
}
{
  if (hd) {
    closer = $0
    if (hdash) sub(/^\t+/, "", closer)
    if (closer == hdelim) {
      emit("C", $0)
      hd = 0
    } else {
      emit(hquot ? "Hq" : "Hu", $0)
    }
    next
  }
  if ($0 ~ /^[ \t]*$/ && inq == "") {
    brk = 1
    next
  }
  opened = 0
  emit("C", scan($0))
  if (opened) hd = 1
}
```

The `<<<` test must come before the `<<` test, or a herestring is consumed as a heredoc opener. `<<\TAG` sets `hquot = 1` because a backslash-escaped delimiter suppresses expansion exactly as quotes do — that matters downstream, where Decision 4 neutralizes `$HOME` in `Hu` bodies but not `Hq` ones. Tab-stripping is applied to a *copy* of the line for the closer comparison only, so the emitted `text` still carries the body's original leading whitespace.

- [ ] **Step 19: Run it and see it pass.**

```
bats tests/seed_drift.bats -f 'sd_scan'
```

Expected: `1..7`, all `ok`, including `ok 3 sd_scan excludes herestrings and recognizes every delimiter form`.

- [ ] **Step 20: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: recognize herestrings, escaped delimiters, and <<- in sd_scan"
```

- [ ] **Step 21: Write the failing multiple-heredoc test.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan queues two heredocs opened on the same line" {
  local f="$TEST_ROOT/two.sh"
  printf '%s\n' 'cat <<A; cat <<-"B"' 'x' 'A' $'\ty' $'\tB' 'echo tail' >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "$(printf '1\t2\tHu\tx')" ]
  [ "${lines[2]}" = "$(printf '1\t3\tC\tA')" ]
  [ "${lines[3]}" = "$(printf '1\t4\tHq\t\ty')" ]
  [ "${lines[4]}" = "$(printf '1\t5\tC\t\tB')" ]
  [ "${lines[5]}" = "$(printf '1\t6\tC\techo tail')" ]
}
```

The two openers differ in every attribute — `A` is unquoted and undashed, `B` is quoted and dashed — so a queue that loses per-heredoc state, or pops in the wrong order, cannot pass.

- [ ] **Step 22: Run it and see it fail.**

```
bats tests/seed_drift.bats -f 'queues two'
```

Expected: `1..1`, `not ok 1 sd_scan queues two heredocs opened on the same line`, failing at `[ "${lines[1]}" = "$(printf '1\t2\tHu\tx')" ]`. The single-slot state is overwritten by the second opener, so `hdelim` is `B` and `hquot` is 1: line 2 is emitted as `Hq` and line 3 (`A`) is swallowed as body rather than closing the first heredoc.

- [ ] **Step 23: Replace the single-slot state with a FIFO queue.**

In the `SD_SCAN_AWK` body, add these two functions immediately after `emit()`:

```awk
function push(delim, quoted, dash) {
  nq++
  qd[nq] = delim
  qq[nq] = quoted
  qs[nq] = dash
}
function popq() {
  hdelim = qd[1]
  hquot = qq[1]
  hdash = qs[1]
  hd = 1
  for (k = 1; k < nq; k++) {
    qd[k] = qd[k + 1]
    qq[k] = qq[k + 1]
    qs[k] = qs[k + 1]
  }
  nq--
}
```

In `scan()`, replace each of the three four-line assignment groups

```awk
      hdelim = ...
      hquot = ...
      hdash = d
      opened = 1
```

with a single `push(...)` call — `push(substr(line, i + 1, j - 1), 1, d)` for the quoted-delimiter branch, `push(w, 1, d)` for the `<<\TAG` branch, and `push(w, 0, d)` for the bare-word branch — deleting the now-unused `opened` assignments.

Then replace the main rule with:

```awk
{
  if (hd) {
    closer = $0
    if (hdash) sub(/^\t+/, "", closer)
    if (closer == hdelim) {
      emit("C", $0)
      hd = 0
      if (nq > 0) popq()
    } else {
      emit(hquot ? "Hq" : "Hu", $0)
    }
    next
  }
  if ($0 ~ /^[ \t]*$/ && inq == "") {
    brk = 1
    next
  }
  nq = 0
  emit("C", scan($0))
  if (nq > 0) popq()
}
```

`nq = 0` before `scan()` replaces the `opened` flag: the queue is per-line, filled by `scan()` and drained as each body closes. Resetting it is safe because a code line is only reached when no heredoc is pending. Bash reads the bodies in opener order, which is what the FIFO shift in `popq()` reproduces.

- [ ] **Step 24: Run it and see it pass.**

```
bats tests/seed_drift.bats -f 'sd_scan'
```

Expected: `1..8`, all `ok`, including `ok 4 sd_scan queues two heredocs opened on the same line`.

- [ ] **Step 25: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: queue multiple heredocs opened on one line in sd_scan"
```

- [ ] **Step 26: Write the failing unterminated-heredoc test.**

Append to `tests/seed_drift.bats`:

```bash
@test "sd_scan fails closed on an unterminated heredoc" {
  local f="$TEST_ROOT/unterminated.sh"
  printf "cat <<'E'\nbody\n" >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 3 ]
  [[ "$output" == *"unterminated heredoc E"* ]]
}
```

A heredoc still open at EOF means the scanner's structural model of the file is wrong; per Decision 3 that is an extraction error, not a scan that happens to end.

- [ ] **Step 27: Run it and see it fail.**

```
bats tests/seed_drift.bats -f 'unterminated heredoc'
```

Expected: `1..1`, `not ok 1 sd_scan fails closed on an unterminated heredoc`, failing at `[ "$status" -eq 3 ]` — awk currently reaches EOF and exits 0 after emitting `body` as `Hq`.

- [ ] **Step 28: Add the `END` guard.**

Append to the `SD_SCAN_AWK` body, after the main rule:

```awk
END {
  if (failed) exit 3
  if (hd) {
    printf("seed-drift: unterminated heredoc %s\n", hdelim) >"/dev/stderr"
    exit 3
  }
}
```

`if (failed) exit 3` must come first and is not redundant: `fail()`'s `exit 3` still runs `END`, and without this line an `END` block that falls through would reset the status to 0 — silently converting the fail-closed path from Step 13 into a clean scan.

- [ ] **Step 29: Run the whole suite and see it pass.**

```
bats tests/seed_drift.bats
```

Expected: `1..18`, every line `ok`, ending `ok 18 seed-drift exits 2 when the doc is unreadable`.

```
shellcheck -x -S warning bin/seed-drift && shfmt -i 2 -ci -d bin/seed-drift
```

Expected: no output from either, exit 0.

- [ ] **Step 30: Commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m "feat: treat an unterminated heredoc as an sd_scan extraction error"
```

---

### Task 3: window growth — `sd_paras_with_anchor`, `sd_para_range`, `sd_window`

**Files:**

- modify `bin/seed-drift` (append the three functions after `sd_scan`)
- modify `tests/seed_drift.bats` (append two test helpers and 9 `@test` blocks)

**Interfaces:**

*Consumes* (from Task 2)

- `sd_scan FILE` -> stdout, one record per source line: `para<TAB>lineno<TAB>tag<TAB>text`, `tag` in `C|Hq|Hu`. Paragraph indices are 1-based and contiguous; `lineno` is strictly increasing.
- `bin/seed-drift` guards its entry point with `if [[ "${SEED_DRIFT_SOURCE_ONLY:-0}" != 1 ]]; then sd_main "$@"; fi` (Task 1), so `SEED_DRIFT_SOURCE_ONLY=1 source bin/seed-drift` defines the functions without running anything. Every test in this task relies on that, and on the `sd_source` helper Task 1 added — do not add a second sourcing helper.

*Produces*

- `sd_paras_with_anchor SCAN ANCHOR` -> stdout, one paragraph index per line, ascending, deduped. Empty output (exit 0) when the anchor matches nothing. Match is awk `index()` — fixed string — against the text after the third tab, on `$3 == "C"` rows only. Not `$4`: that stops at the next tab and would truncate a tab-bearing line.
- `sd_para_range SCAN PARA` -> stdout, one line, `start end` (space-separated source line numbers). Empty output when `PARA` does not exist.
- `sd_window FILE SCAN PARA` -> stdout, one line, `start end`. Exit 3 if no grown window ever parses.

Note for the implementer: the fenced blocks below are byte-exact. The multi-line
`[ "$output" = "..." ]` assertions contain literal newlines and unindented
continuation lines — copy them as written; adding indentation changes the
expected string and the test will fail.

---

- [ ] **Step 1: write the failing tests for `sd_paras_with_anchor` and `sd_para_range`.**

Append to `tests/seed_drift.bats`. `REPO_ROOT` is exported by `setup_dotfiles_test`; `SEED_DRIFT` and `FIX` are already set by the `setup()` Task 1 created.

```bash
# --- Task 3 helpers ---------------------------------------------------------
# Sourcing goes through Task 1's `sd_source`, which sets SEED_DRIFT_SOURCE_ONLY=1.
# make_scan needs its own form because it captures stdout to a file rather than
# going through bats' `run`, but it sets the same guard.
make_scan() {
  env SEED_DRIFT_SOURCE_ONLY=1 bash -c \
    'source "$1"; sd_scan "$2"' _ "$SEED_DRIFT" "$1" >"$1.scan"
}

@test "sd_paras_with_anchor matches C-tag text as a fixed string, every occurrence" {
  printf 'A="lname '"'"'*dotfiles/projects/*'"'"'"\n\necho other\n\nB="lname '"'"'*dotfiles/projects/*'"'"'"\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_paras_with_anchor "$FIX/f.sh.scan" "lname '*dotfiles/projects/*'"
  [ "$status" -eq 0 ]
  [ "$output" = "1
3" ]
}

@test "sd_paras_with_anchor ignores an anchor that appears only in a comment" {
  printf 'echo hi # TREE_SITTER_VERSION is pinned\n\nTS=1\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_paras_with_anchor "$FIX/f.sh.scan" TREE_SITTER_VERSION
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sd_para_range reports the first and last source line of a paragraph" {
  printf 'a\nb\n\nc\nd\ne\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_para_range "$FIX/f.sh.scan" 2
  [ "$status" -eq 0 ]
  [ "$output" = "4 6" ]
}
```

The first test pins two contract properties at once: `*` and `'` in the anchor are literal (fixed-string, not regex), and both matching paragraphs are returned. The second pins that comment-only occurrences do not anchor — `sd_scan` already comment-strips C text, so this is a regression test on *using* `$4` rather than the raw line.

- [ ] **Step 2: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'sd_paras_with_anchor|sd_para_range'
```

Expect 3 failures. Each reports `sd_paras_with_anchor: command not found` (or `sd_para_range`) in `$output`, with the `[ "$status" -eq 0 ]` assertion failing on exit 127.

- [ ] **Step 3: implement `sd_paras_with_anchor` and `sd_para_range`.**

Append to `bin/seed-drift` after `sd_scan`:

```bash
sd_paras_with_anchor() {
  # $4 would stop at the next tab; take everything after the third tab so a
  # tab-bearing line is matched in full.
  awk -F'\t' -v a="$2" '
    $3 == "C" {
      t = $0
      sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t)
      if (index(t, a) && !seen[$1]++) print $1
    }' "$1"
}

sd_para_range() {
  awk -F'\t' -v p="$2" '$1 == p { if (!s) s = $2; e = $2 } END { if (s) print s, e }' "$1"
}
```

`index()` is awk's fixed-string search, so no anchor character is ever interpreted. `-v a=` passes the anchor as data, never as program text.

- [ ] **Step 4: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'sd_paras_with_anchor|sd_para_range'
```

Expect `1..3` and three `ok` lines.

- [ ] **Step 5: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): locate anchored paragraphs and their line ranges'
```

- [ ] **Step 6: write the characterization test that pins the `bash -n` asymmetry.**

This is the empirical fact the entire growth rule rests on, so it gets its own test rather than living only in the spec. It is a characterization test of external behavior and is expected to pass on its first run — that is a deliberate departure from red-green, not an oversight.

```bash
@test "bash -n rejects a lone if header and accepts it split by a blank line" {
  printf 'if [ -n "$x" ]; then\n' >"$FIX/lone.sh"
  printf 'if [ -n "$x" ]; then\n\n  echo hi\nfi\n' >"$FIX/split.sh"
  run bash -n "$FIX/lone.sh"
  [ "$status" -eq 2 ]
  run bash -n "$FIX/split.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 7: run it and confirm it passes.**

```
bats tests/seed_drift.bats -f 'bash -n rejects a lone if header'
```

Expect `1..1` and `ok 1`. Verified directly: `bash -n` on the lone header prints `syntax error: unexpected end of file` and exits 2; the blank-line-split form exits 0. Truncation is therefore detectable, and a blank line between condition and body is legal input — both halves of the rule.

- [ ] **Step 8: commit.**

```
git add tests/seed_drift.bats
git commit -m 'test(seed-drift): pin the bash -n asymmetry that drives window growth'
```

- [ ] **Step 9: write the failing tests for `sd_window`.**

```bash
@test "sd_window grows forward past a blank line between an if condition and its body" {
  printf 'if [ -n "$ANCHOR" ]; then\n\n  echo hi\nfi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 1
  [ "$status" -eq 0 ]
  [ "$output" = "1 4" ]
}

@test "sd_window grows backward when the anchor is in the body and the header is above" {
  printf 'if [ -n "$x" ]; then\n\n  echo ANCHOR\nfi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 2
  [ "$status" -eq 0 ]
  [ "$output" = "1 4" ]
}

@test "sd_window returns a single paragraph unchanged when it already parses" {
  printf 'echo one\n\necho ANCHOR\n\necho three\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 2
  [ "$status" -eq 0 ]
  [ "$output" = "3 3" ]
}

@test "sd_window exits 3 when neither direction ever parses" {
  printf 'echo ok\n\nfi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 2
  [ "$status" -eq 3 ]
}

@test "sd_window reads the raw fragment from the file, not the comment-stripped scan" {
  printf 'if [ -n "$x" ]; then # start\n\n  echo hi\nfi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 1
  [ "$status" -eq 0 ]
  [ "$output" = "1 4" ]
}
```

The backward case is the one that forces the two-direction rule: paragraph 2 is `echo ANCHOR`, which parses on its own, but appending paragraph 3 (`fi`) does not parse, so growth must fall through to prepending paragraph 1. The third test pins the residual limitation in the spec — an already-parsing window is not grown — so a future change cannot silently widen it. The last test pins that the fragment comes from `FILE` by line number: the trailing comment is absent from the scan text, so this is asserted as an explicit contract rather than left to chance.

- [ ] **Step 10: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'sd_window'
```

Expect 5 failures, each with `sd_window: command not found` in `$output`.

- [ ] **Step 11: implement `sd_window`.**

```bash
# Grows the window until the extracted fragment parses: forward first, then
# backward once the end of file is reached. The fragment is read straight from
# FILE by line number, because the scan text is comment-stripped and would not
# parse the same way.
sd_window() {
  local file="$1" scan="$2" para="$3"
  local first last lo hi start end range

  first=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$scan")
  last=$(awk -F'\t' 'END { print $1 }' "$scan")
  range=$(sd_para_range "$scan" "$para")
  [ -n "$range" ] || return 3

  lo="$para" hi="$para"
  start="${range% *}" end="${range#* }"
  while ! sed -n "${start},${end}p" "$file" | bash -n 2>/dev/null; do
    if [ "$hi" -lt "$last" ]; then
      hi=$((hi + 1))
      range=$(sd_para_range "$scan" "$hi")
      end="${range#* }"
    elif [ "$lo" -gt "$first" ]; then
      lo=$((lo - 1))
      range=$(sd_para_range "$scan" "$lo")
      start="${range% *}"
    else
      return 3
    fi
  done
  printf '%s %s\n' "$start" "$end"
}
```

`first`/`last` are read from the scan rather than assumed to be `1` and the paragraph count, so the loop terminates on any scan the scanner can produce. `sed -n "start,endp" | bash -n` is the parse check; stderr is discarded because a failing parse is expected control flow here, not an error to report.

- [ ] **Step 12: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'sd_window'
```

Expect `1..5` and five `ok` lines.

- [ ] **Step 13: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): grow the extraction window until the fragment parses'
```

---

### Task 4: normalization — `sd_normalize`, then `sd_extract`

**Files:**

- modify `bin/seed-drift` (append `sd_neutralize_paths`, `sd_drop_priv_prefix`, `SD_OWNERSHIP_DROP`, `sd_normalize_code_line`, `sd_normalize`, `sd_extract`)
- modify `tests/seed_drift.bats` (append two helpers and 12 `@test` blocks)

**Interfaces:**

*Consumes*

- `sd_scan FILE` -> `para<TAB>lineno<TAB>tag<TAB>text` (Task 2); `sd_paras_with_anchor SCAN ANCHOR` -> paragraph indices one per line (Task 3); `sd_window FILE SCAN PARA` -> `start end` (Task 3).

*Produces*

- `sd_normalize` -> filter. Reads scan format (`para<TAB>lineno<TAB>tag<TAB>text`) on stdin, writes one normalized text line per surviving input line on stdout. C lines are joined/collapsed/trimmed/prefix-stripped/token-substituted and dropped when empty; `Hq` lines are copied byte-for-byte; `Hu` lines get path-token substitution and nothing else. Always exits 0.
- `sd_extract FILE SCAN ANCHOR` -> normalized lines on stdout for the union of every matching paragraph's window, in file order, deduped by source line. Exit 4 if the anchor matches no paragraph; exit 3 if any window fails to parse (propagated from `sd_window`).

---

- [ ] **Step 1: write the failing tests for the C-line normalization rules.**

Two more helpers, then four tests. `scan_line` builds the scan file one field at a time, which keeps every fixture readable and removes all tab-escaping ambiguity from the test source.

```bash
# --- Task 4 helpers ---------------------------------------------------------
scan_line() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$FIX/in.scan"
}

norm() {
  run env SEED_DRIFT_SOURCE_ONLY=1 bash -c \
    'source "$1"; sd_normalize <"$2"' _ "$SEED_DRIFT" "$FIX/in.scan"
}

@test "sd_normalize joins backslash continuations and collapses whitespace" {
  scan_line 1 1 C '  curl -fsSL   \'
  scan_line 1 2 C '      -o out   url'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = "curl -fsSL -o out url" ]
}

@test "sd_normalize drops privilege prefixes" {
  scan_line 1 1 C 'as_user mkdir -p a'
  scan_line 1 2 C '$SUDO mkdir -p b'
  scan_line 1 3 C 'sudo -n mkdir -p c'
  scan_line 1 4 C 'sudo mkdir -p d'
  scan_line 1 5 C 'runuser -u node -- mkdir -p e'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = "mkdir -p a
mkdir -p b
mkdir -p c
mkdir -p d
mkdir -p e" ]
}

@test "sd_normalize drops privilege words in command position, not just at line start" {
  # Template line 218 vs wanderer's root-flavor equivalent: these must
  # normalize identically or the spec's required "as_user vs direct
  # invocation" false-positive guard fails on the core.excludesFile block.
  scan_line 1 1 C 'if ! as_user test -f "$GITIGNORE"; then'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = 'if ! test -f "$GITIGNORE"; then' ]
}

@test "sd_normalize drops privilege words after && and ||" {
  # Template lines 390, 431 and 514 all stack privilege words mid-line.
  scan_line 1 1 C 'if as_user test -x "$A" || as_user bash -lc "c"; then'
  scan_line 1 2 C 'if as_user test -f "$N" && as_user test -x "$N"; then'
  scan_line 1 3 C 'if as_user test -L "$C" || ! as_user test -e "$C"; then'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = 'if test -x "$A" || bash -lc "c"; then
if test -f "$N" && test -x "$N"; then
if test -L "$C" || ! test -e "$C"; then' ]
}

@test "sd_normalize does not strip privilege words outside command position" {
  # Over-broad stripping is the silent direction, so this guard matters more
  # than the ones above: a genuine difference in an argument must survive.
  scan_line 1 1 C 'grep as_user "$f"'
  scan_line 1 2 C 'run_as_user_thing x'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = 'grep as_user "$f"
run_as_user_thing x' ]
}

@test "sd_normalize substitutes the path token only and preserves surrounding quotes" {
  scan_line 1 1 C '      TS_BIN="$SEED_HOME/.local/bin/tree-sitter"'
  scan_line 1 2 C 'X="$HOME/a"'
  scan_line 1 3 C 'Y="$DOTFILES_HOME/config"'
  scan_line 1 4 C 'Z="$WORKSPACE/p"'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = 'TS_BIN="«HOME»/.local/bin/tree-sitter"
X="«HOME»/a"
Y="«HOME»/.dotfiles/config"
Z="«WS»/p"' ]
}

@test "sd_normalize drops lines that normalize to empty" {
  scan_line 1 1 C ''
  scan_line 1 2 C '   '
  scan_line 1 3 C 'echo keep'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = "echo keep" ]
}
```

The third test is the regression guard for the quote-eating bug an earlier prototype had: it asserts the *opening* `"` survives, so `TS_BIN="«HOME»/…"` and never `TS_BIN=«HOME»/…"`. The fourth covers the real source of empty C text — the scanner emits an empty C record for a full-line comment.

- [ ] **Step 2: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'sd_normalize'
```

Expect 4 failures with `sd_normalize: command not found` in `$output`.

- [ ] **Step 3: implement the C-line half of `sd_normalize`.**

```bash
sd_neutralize_paths() {
  sed -e 's/\${SEED_HOME}/«HOME»/g' -e 's/\$SEED_HOME/«HOME»/g' \
    -e 's/\${DOTFILES_HOME}/«HOME»\/.dotfiles/g' \
    -e 's/\$DOTFILES_HOME/«HOME»\/.dotfiles/g' \
    -e 's/\${WORKSPACE}/«WS»/g' -e 's/\$WORKSPACE/«WS»/g' \
    -e 's/\${HOME}/«HOME»/g' -e 's/\$HOME/«HOME»/g'
}

sd_drop_priv_prefix() {
  # Privilege words are dropped in COMMAND POSITION only: at line start, or
  # right after an operator/keyword that begins a new command. `as_user` sits
  # mid-line 8 times in the template (`if as_user test -x ...`,
  # `... || as_user bash -lc ...`) and the live seeds split on it —
  # wanderer-kills writes `if ! as_user test -f "$GITIGNORE"; then` where
  # wanderer writes `if [ ! -f "$GITIGNORE" ]; then` — so a line-start-only
  # rule would report every one of those shapes as drift.
  #
  # No `\b`: that boundary is a GNU extension and this script must also run
  # under the BSD sed macOS ships. Operators are self-delimiting, so they need
  # no boundary; the keywords take an explicit `(^|[[:space:]])` left boundary
  # instead, which is why they are a separate expression. `sd_normalize_code_line`
  # has already collapsed runs of whitespace to single spaces before we get here.
  local line="$1" prev=""
  while [ "$line" != "$prev" ]; do
    prev="$line"
    line=$(printf '%s\n' "$line" | sed -E \
      -e 's/(^|[{(|;!]|&&|\|\|)([[:space:]]+)(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+/\1\2/g' \
      -e 's/(^|[[:space:]])(if|then|while|until|do|elif)([[:space:]]+)(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+/\1\2\3/g' \
      -e 's/^(as_user|\$SUDO|sudo -n|sudo)[[:space:]]+//' \
      -e 's/(^|[{(|;!]|&&|\|\|)([[:space:]]+)runuser -u [^[:space:]]+ --[[:space:]]+/\1\2/g' \
      -e 's/(^|[[:space:]])(if|then|while|until|do|elif)([[:space:]]+)runuser -u [^[:space:]]+ --[[:space:]]+/\1\2\3/g' \
      -e 's/^runuser -u [^[:space:]]+ --[[:space:]]+//')
  done
  printf '%s' "$line"
}

sd_normalize_code_line() {
  local line="$1"
  line="${line//$'\t'/ }"
  while [ "$line" != "${line//  / }" ]; do line="${line//  / }"; done
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || return 0
  line=$(sd_drop_priv_prefix "$line")
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | sd_neutralize_paths
}

sd_normalize() {
  local rec tag text rest pending="" joining=0
  # Positional split, not `IFS=$'\t' read`: that form strips leading tabs from
  # `text`, which would corrupt every `<<-` heredoc body. `para` and `lineno`
  # are skipped rather than bound — binding them trips SC2034 under
  # `shellcheck -S warning`, which this repo gates on.
  while IFS= read -r rec; do
    rest="${rec#*$'\t'}"
    rest="${rest#*$'\t'}"
    tag="${rest%%$'\t'*}"
    text="${rest#*$'\t'}"
    if [ "$joining" = 1 ]; then
      pending="$pending ${text#"${text%%[![:space:]]*}"}"
    else
      pending="$text"
    fi
    if [ "${pending%\\}" != "$pending" ]; then
      pending="${pending%\\}"
      joining=1
      continue
    fi
    sd_normalize_code_line "$pending"
    pending="" joining=0
  done
  [ "$joining" = 0 ] || sd_normalize_code_line "$pending"
}
```

`$SEED_HOME` and `$DOTFILES_HOME` are substituted before `$HOME` so the longer names win; because the earlier expressions have already consumed them, the trailing `$HOME` rule cannot re-match their remnants. Substitution targets the bare token, so the quotes on either side are untouched. `sd_drop_priv_prefix` loops because `$SUDO runuser -u node -- cmd` stacks in the live seeds.

`sd_drop_priv_prefix` matches in **command position** — line start, or after `{ ( | ; !`, `&&`, `||`, or one of `if then while until do elif`. Line-start-only matching was tried first and is wrong: the template puts `as_user` mid-line 8 times, and the seeds split on exactly those shapes.

**Documented residual:** the rule is not quote-aware, so a privilege word inside a string that itself follows one of those separators — `echo "x; as_user y"` — would be stripped. No such line exists in the template or the five seeds. This is the same class of accepted residual as the literal workspace paths in Decision 4: narrow, documented, and not worth a quote-aware pass over normalized text.

- [ ] **Step 4: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'sd_normalize'
```

Expect `1..4` and four `ok` lines.

- [ ] **Step 5: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): normalize shell-code lines to comparable form'
```

- [ ] **Step 6: write the failing tests for heredoc-body handling.**

```bash
@test "sd_normalize passes Hq heredoc payload through verbatim" {
  scan_line 1 1 Hq '# Personal docker-compose overrides.'
  scan_line 1 2 Hq ''
  scan_line 1 3 Hq '  keep   spacing'
  scan_line 1 4 Hq 'trailing \'
  scan_line 1 5 Hq '$HOME/literal'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = '# Personal docker-compose overrides.

  keep   spacing
trailing \
$HOME/literal' ]
}

@test "sd_normalize neutralizes paths in an Hu body but nothing else" {
  scan_line 1 1 Hu '  $HOME/x   # not a comment'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = '  «HOME»/x   # not a comment' ]
}
```

The `Hq` test covers all four ways the C rules would corrupt payload, in one fixture: the `#` line is gitignore content (this is the real `GITEOF` body, template line 230) and must not be stripped; the blank line and the leading whitespace must survive; and the trailing `\` must not join the next line. The `Hu` test pins the shell-semantics carve-out — an unquoted delimiter means the shell itself expands `$HOME`, so the tool must too, while the whitespace and the `#` still pass through untouched.

- [ ] **Step 7: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'heredoc payload|Hu body'
```

Expect 2 failures. Both currently take the C path, so the `#` line and `$HOME/literal` are deleted, whitespace is collapsed, and `trailing \` is joined onto the next line — the `[ "$output" = ... ]` assertions fail.

- [ ] **Step 8: implement the heredoc branches in `sd_normalize`.**

Replace the whole function:

```bash
sd_normalize() {
  local rec tag text rest pending="" joining=0
  # Positional split, not `IFS=$'\t' read`: that form strips leading tabs from
  # `text`, which would corrupt every `<<-` heredoc body. `para` and `lineno`
  # are skipped rather than bound — binding them trips SC2034 under
  # `shellcheck -S warning`, which this repo gates on.
  while IFS= read -r rec; do
    rest="${rec#*$'\t'}"
    rest="${rest#*$'\t'}"
    tag="${rest%%$'\t'*}"
    text="${rest#*$'\t'}"
    if [ "$tag" = C ]; then
      if [ "$joining" = 1 ]; then
        pending="$pending ${text#"${text%%[![:space:]]*}"}"
      else
        pending="$text"
      fi
      if [ "${pending%\\}" != "$pending" ]; then
        pending="${pending%\\}"
        joining=1
        continue
      fi
      sd_normalize_code_line "$pending"
      pending="" joining=0
      continue
    fi
    # A heredoc body ends any pending continuation: a payload line is data and
    # must never be folded into the shell line above it.
    if [ "$joining" = 1 ]; then
      sd_normalize_code_line "$pending"
      pending="" joining=0
    fi
    if [ "$tag" = Hu ]; then
      printf '%s\n' "$text" | sd_neutralize_paths
    else
      printf '%s\n' "$text"
    fi
  done
  [ "$joining" = 0 ] || sd_normalize_code_line "$pending"
}
```

- [ ] **Step 9: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'heredoc payload|Hu body'
```

Expect `1..2` and two `ok` lines. Then re-run `bats tests/seed_drift.bats -f 'sd_normalize'` and expect `1..6` with six `ok` lines — the C rules still hold.

- [ ] **Step 10: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): compare heredoc payload verbatim, expanding only unquoted bodies'
```

- [ ] **Step 11: write the failing tests for the ownership rule.**

The four literals below are the post-normalization form of template lines 491, 492, 594 and 595 — verified against the file, including the `-R` present on the neovim instance and absent on the tree-sitter one.

```bash
@test "sd_normalize drops the four exact ownership-verification lines" {
  scan_line 1 1 C '      { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||'
  scan_line 1 2 C '        [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&'
  scan_line 1 3 C '      { chown "$SEED_UID:$SEED_GID" "$TS_BIN.new" 2>/dev/null ||'
  scan_line 1 4 C '        [ -z "$(find "$TS_BIN.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&'
  scan_line 1 5 C 'echo after'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = "echo after" ]
}

@test "the ownership rule is exact: target, -R, identity, and unrelated chown all survive" {
  scan_line 1 1 C '{ chown -R "$SEED_UID:$SEED_GID" "$OTHER.new" 2>/dev/null ||'
  scan_line 1 2 C '{ chown "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||'
  scan_line 1 3 C '{ chown -R "$SEED_UID:0" "$NVIM_DIST.new" 2>/dev/null ||'
  scan_line 1 4 C 'chown -R node:node /app'
  norm
  [ "$status" -eq 0 ]
  [ "$output" = '{ chown -R "$SEED_UID:$SEED_GID" "$OTHER.new" 2>/dev/null ||
{ chown "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
{ chown -R "$SEED_UID:0" "$NVIM_DIST.new" 2>/dev/null ||
chown -R node:node /app' ]
}
```

The second test is the whole point of the "nothing is free" rule, one line per way a broader match would have leaked: a changed target, the `-R` swapped between the two idioms, a changed identity, and an unrelated `chown`. Note line 2 is the tree-sitter idiom carrying the neovim target — literal matching keeps it, whereas a target-free rule would have silently dropped it.

- [ ] **Step 12: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'ownership'
```

Expect 1 failure — the first test, whose `$output` is all five input lines rather than `echo after`. The second test passes already; it is the guard that the fix in Step 13 must not break.

- [ ] **Step 13: implement the ownership drop.**

Add the array beside the other constants:

```bash
# The non-root ownership-verification idiom, matched fully literally after
# normalization: template lines 491-492 (chown -R, "$NVIM_DIST.new") and
# 594-595 (plain chown, "$TS_BIN.new"). Two physical lines each, because the
# first ends in `||` and the second in `; } &&`. Nothing in the match is free —
# a changed flag, target or identity is drift, not vocabulary.
SD_OWNERSHIP_DROP=(
  '{ chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||'
  '[ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&'
  '{ chown "$SEED_UID:$SEED_GID" "$TS_BIN.new" 2>/dev/null ||'
  '[ -z "$(find "$TS_BIN.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&'
)
```

Then replace `sd_normalize_code_line` in full:

```bash
sd_normalize_code_line() {
  local line="$1" drop
  line="${line//$'\t'/ }"
  while [ "$line" != "${line//  / }" ]; do line="${line//  / }"; done
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || return 0
  line=$(sd_drop_priv_prefix "$line")
  [ -n "$line" ] || return 0
  for drop in "${SD_OWNERSHIP_DROP[@]}"; do
    [ "$line" = "$drop" ] && return 0
  done
  printf '%s\n' "$line" | sd_neutralize_paths
}
```

The comparison runs after trimming and prefix-dropping but before path neutralization, which is why the literals still carry `$NVIM_DIST` and `$TS_BIN` — neither is a neutralized token.

- [ ] **Step 14: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'ownership'
```

Expect `1..2` and two `ok` lines.

- [ ] **Step 15: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): drop the four exact ownership-verification lines'
```

- [ ] **Step 16: write the failing tests for `sd_extract`.**

```bash
@test "sd_extract unions windows in file order, deduped, and normalizes" {
  printf 'echo ANCHOR one\n\necho middle\n\nas_user echo ANCHOR two\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_extract "$FIX/f.sh" "$FIX/f.sh.scan" ANCHOR
  [ "$status" -eq 0 ]
  [ "$output" = "echo ANCHOR one
echo ANCHOR two" ]
}

@test "sd_extract deduplicates lines shared by two overlapping windows" {
  printf 'if [ -n "$ANCHOR" ]; then\n\n  echo ANCHOR body\nfi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_extract "$FIX/f.sh" "$FIX/f.sh.scan" ANCHOR
  [ "$status" -eq 0 ]
  [ "$output" = 'if [ -n "$ANCHOR" ]; then
echo ANCHOR body
fi' ]
}

@test "sd_extract drops comment-only lines and keeps the sed s#...#g idiom" {
  printf '# reworded prose about ANCHOR\nsed '"'"'s#/app#/workspace#g'"'"' ANCHOR.txt # trailing\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_extract "$FIX/f.sh" "$FIX/f.sh.scan" ANCHOR
  [ "$status" -eq 0 ]
  [ "$output" = "sed 's#/app#/workspace#g' ANCHOR.txt" ]
}

@test "sd_extract exits 4 when the anchor is absent" {
  printf 'echo hi\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_extract "$FIX/f.sh" "$FIX/f.sh.scan" NOPE
  [ "$status" -eq 4 ]
}
```

The first fixture proves the union skips the non-matching middle paragraph and that the second paragraph is still normalized (`as_user` gone). The second is the overlap case: both paragraphs match `ANCHOR`, both grow to the same window `1 4`, and each source line must appear once. The third pins that the anchor's comment occurrence contributes nothing while `s#...#g` survives comment stripping.

- [ ] **Step 17: run the tests and watch them fail.**

```
bats tests/seed_drift.bats -f 'sd_extract'
```

Expect 4 failures with `sd_extract: command not found` in `$output`.

- [ ] **Step 18: implement `sd_extract`.**

```bash
sd_extract() {
  local file="$1" scan="$2" anchor="$3" paras para window ranges=""

  paras=$(sd_paras_with_anchor "$scan" "$anchor")
  [ -n "$paras" ] || return 4

  for para in $paras; do
    window=$(sd_window "$file" "$scan" "$para") || return 3
    ranges+="$window"$'\n'
  done

  # Union the windows by source line number: `sort -n -u` puts them in file
  # order and collapses lines two overlapping windows both claim.
  printf '%s' "$ranges" |
    awk '{ for (i = $1; i <= $2; i++) print i }' | sort -n -u |
    awk -F'\t' 'NR == FNR { keep[$1] = 1; next } keep[$2]' - "$scan" |
    sd_normalize
}
```

Deduplication is by *source line*, not by normalized text, so a genuinely repeated line inside one block is still compared twice — order-preserving comparison in Decision 5 depends on that. `$paras` is deliberately unquoted for word splitting; it holds only awk-printed integers. A window boundary can never cut a `\` continuation in half, because a fragment ending in a dangling `\` does not parse and `sd_window` would have grown past it.

- [ ] **Step 19: run the tests and watch them pass.**

```
bats tests/seed_drift.bats -f 'sd_extract'
```

Expect `1..4` and four `ok` lines. Then run the full suite plus both linters:

```
bats tests/seed_drift.bats
shfmt -i 2 -ci -d bin/seed-drift
shellcheck -x -S warning bin/seed-drift
```

Expect every `@test` from Tasks 2-4 to pass, and both linters to produce no output.

- [ ] **Step 20: commit.**

```
git add bin/seed-drift tests/seed_drift.bats
git commit -m 'feat(seed-drift): extract normalized block text for every anchor match'
```

---

### Task 5: verdicts (`sd_verdict`)

Implements Decision 5. The comparison is an **order-preserving** `diff` of the two
normalized line sequences, never a sorted/multiset comparison: statement order is
behaviorally load-bearing (`catch-up-local-seed.md:83` requires the
`load-custom.zsh` hook *before* the Vekil hook, because `ai/vekil/env.zsh` exports
`ANTHROPIC_MODEL` and must get the last word). A pure reordering therefore
produces differences in both directions and is reported `DIVERGED`.

**Files:**
- modify `bin/seed-drift`
- modify `tests/seed_drift.bats`

**Interfaces:**

*Consumes*
- `sd_extract FILE SCAN ANCHOR` (Task 4) — writes normalized lines to a file;
  exits `4` when the anchor is absent. Task 5 consumes only its **output files**,
  never its exit code; `MISSING` is raised by `sd_check_seed` in Task 6, because
  the contract fixes `sd_verdict`'s signature at two file paths.
- `sd_source` (bats helper added by Task 1) — `run env SEED_DRIFT_SOURCE_ONLY=1
  bash -c 'source "$1"; shift; "$@"' _ "$SEED_DRIFT" "$@"`.

*Produces*
- `sd_diff_lines TPL_NORM SEED_NORM MARKER` → the differing lines, one per line,
  on stdout. `MARKER` is `<` for template-only lines and `>` for seed-only lines.
  Returns `3` if `diff` fails for a reason other than "files differ".
- `sd_tmp VARNAME` → assigns a fresh temp-file path to `VARNAME` in the caller's
  scope (via `printf -v`, not stdout), exit `3` if `mktemp` fails. The whole run
  shares one directory, removed by a single trap. Never call it inside a command
  substitution — the subshell would take the directory and the trap with it.
- `sd_count_lines FILE` → the number of records in `FILE`, on stdout, blank
  records included.
- `sd_verdict_from_counts NB NA` → exactly one of `ok`, `BEHIND`, `AHEAD`,
  `DIVERGED` on stdout, exit `0`. Pure: it cannot fail, which is why callers
  holding the counts use it instead of `sd_verdict`.
- `sd_verdict TPL_NORM SEED_NORM` → the same four tokens on stdout, exit `0`;
  exit `3` if `diff` fails.

---

- [ ] **Step 1: write the failing test for the diff primitive.**
  Append to `tests/seed_drift.bats`:

  ```bash
  write_lines() {
    local path="$1"
    shift
    printf '%s\n' "$@" >"$path"
  }

  @test "sd_diff_lines names the lines missing from each side" {
    write_lines "$TEST_ROOT/tpl" 'export A=1' 'run_old'
    write_lines "$TEST_ROOT/seed" 'export A=1' 'run_new'

    sd_source sd_diff_lines "$TEST_ROOT/tpl" "$TEST_ROOT/seed" '<'
    [ "$status" -eq 0 ]
    [ "$output" = "run_old" ]

    sd_source sd_diff_lines "$TEST_ROOT/tpl" "$TEST_ROOT/seed" '>'
    [ "$status" -eq 0 ]
    [ "$output" = "run_new" ]
  }
  ```

- [ ] **Step 2: run it and see it fail.**
  `bats tests/seed_drift.bats -f 'sd_diff_lines names the lines'`
  Expected: `not ok 1 sd_diff_lines names the lines missing from each side`, with
  bats reporting `exited with code 127` (`sd_diff_lines: command not found`).

- [ ] **Step 3: implement the diff primitive.**
  Insert into `bin/seed-drift`, immediately above `sd_main()`:

  ```bash
  # One temp dir for the whole run, removed by a single trap. Callers never
  # clean up individually, so no early `return` can leak a file.
  SD_TMPDIR=""

  # sd_tmp VARNAME — assigns a fresh temp file path to VARNAME in the CALLER's
  # scope, and must never be called inside a command substitution. `$(sd_tmp)`
  # runs in a subshell: the subshell creates the directory, installs the EXIT
  # trap, prints the path, and then — on subshell exit — fires that trap and
  # `rm -rf`s the directory before the caller can write a single byte. The
  # directory and its trap have to be established in the shell that will
  # actually use them, so the path comes back through `printf -v`, not stdout.
  sd_tmp() {
    local __sd_new
    if [ -z "$SD_TMPDIR" ]; then
      SD_TMPDIR="$(mktemp -d)" || return 3
      trap 'rm -rf -- "$SD_TMPDIR"' EXIT HUP INT TERM
    fi
    __sd_new="$(mktemp "$SD_TMPDIR/sd.XXXXXX")" || return 3
    printf -v "$1" '%s' "$__sd_new"
  }

  sd_diff_lines() {
    # TPL_NORM SEED_NORM MARKER; MARKER is '<' for template-only lines and '>'
    # for seed-only lines. The diff is ordered, so a pure reordering yields lines
    # under both markers rather than comparing equal.
    #
    # diff goes to a FILE, not a command substitution. A removed blank line is
    # emitted by diff as the record `< ` (marker, space, empty text); command
    # substitution would strip the trailing newline and sed, preserving the
    # absent final newline, would then emit zero bytes — making a deleted blank
    # line read as no difference at all. Via a file every record keeps its
    # newline and the blank one survives.
    local rc=0 raw
    sd_tmp raw || return 3
    diff -- "$1" "$2" >"$raw" || rc=$?
    if [ "$rc" -gt 1 ]; then
      printf 'seed-drift: diff failed comparing %s and %s\n' "$1" "$2" >&2
      return 3
    fi
    sed -n "s/^$3 //p" "$raw"
  }

  # Takes a FILE, and counts every record including empty ones. `grep -c .`
  # would skip exactly the blank lines this tool has to notice.
  sd_count_lines() {
    local n
    n=$(wc -l <"$1")
    printf '%s' "${n//[[:space:]]/}"
  }
  ```

- [ ] **Step 4: run it and see it pass.**
  `bats tests/seed_drift.bats -f 'sd_diff_lines names the lines'`
  Expected: `ok 1 sd_diff_lines names the lines missing from each side`.

- [ ] **Step 5: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: add ordered diff primitives for seed drift verdicts'`

- [ ] **Step 6: write the failing tests for the three single-direction verdicts.**
  Append to `tests/seed_drift.bats`:

  ```bash
  @test "sd_verdict reports ok for identical line sequences" {
    write_lines "$TEST_ROOT/tpl" 'export A=1' 'run_thing' 'export B=2'
    write_lines "$TEST_ROOT/seed" 'export A=1' 'run_thing' 'export B=2'

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
  }

  @test "sd_verdict reports ok for two empty extractions" {
    : >"$TEST_ROOT/tpl"
    : >"$TEST_ROOT/seed"

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
  }

  @test "sd_verdict reports BEHIND when only the template has extra lines" {
    write_lines "$TEST_ROOT/tpl" 'export A=1' 'run_thing' 'export B=2'
    write_lines "$TEST_ROOT/seed" 'export A=1' 'export B=2'

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "BEHIND" ]
  }

  @test "sd_verdict reports AHEAD when only the seed has extra lines" {
    write_lines "$TEST_ROOT/tpl" 'export A=1' 'export B=2'
    write_lines "$TEST_ROOT/seed" 'export A=1' 'run_thing' 'export B=2'

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "AHEAD" ]
  }
  ```

- [ ] **Step 7: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'sd_verdict reports'`
  Expected: all four `not ok`, each reporting `exited with code 127`
  (`sd_verdict: command not found`).

- [ ] **Step 8: implement the single-direction verdicts.**
  Insert into `bin/seed-drift`, immediately after `sd_count_lines`. The `else`
  branch deliberately fails loudly rather than guessing — Step 13 supplies the
  two-direction case, and an unclassified pair must never fall through to `ok`:

  ```bash
  # Pure classifier: given the two difference counts, name the direction. Split
  # out from sd_verdict so a caller that already holds the counts can name the
  # verdict without re-running diff — and, more importantly, without the
  # `verdict=$(sd_verdict ...)` form, whose non-zero status aborts the whole
  # program under `set -e` and skips every project after it.
  sd_verdict_from_counts() {
    # BEHIND_COUNT AHEAD_COUNT
    if [ "$1" -eq 0 ] && [ "$2" -eq 0 ]; then
      printf 'ok\n'
    elif [ "$2" -eq 0 ]; then
      printf 'BEHIND\n'
    elif [ "$1" -eq 0 ]; then
      printf 'AHEAD\n'
    else
      return 1
    fi
  }

  sd_verdict() {
    # Files, not nested command substitutions: substitution both loses blank
    # differing lines and swallows a non-zero status from sd_diff_lines, so a
    # broken diff would silently read as `ok`.
    local bf af behind ahead
    sd_tmp bf || return 3
    sd_tmp af || return 3
    sd_diff_lines "$1" "$2" '<' >"$bf" || return 3
    sd_diff_lines "$1" "$2" '>' >"$af" || return 3
    behind=$(sd_count_lines "$bf")
    ahead=$(sd_count_lines "$af")
    sd_verdict_from_counts "$behind" "$ahead"
  }
  ```

- [ ] **Step 9: run them and see them pass.**
  `bats tests/seed_drift.bats -f 'sd_verdict reports'`
  Expected: `ok` for all four (`ok for identical line sequences`,
  `ok for two empty extractions`, `BEHIND when only the template has extra
  lines`, `AHEAD when only the seed has extra lines`).

- [ ] **Step 10: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: classify single-direction seed drift as ok, BEHIND or AHEAD'`

- [ ] **Step 11: write the failing order test — mandatory, and a real fixture.**
  The first assertion is the point of the test: the two files are identical when
  sorted, so a multiset comparison would report `ok`. Append to
  `tests/seed_drift.bats`:

  ```bash
  @test "sd_verdict reports DIVERGED for a pure reordering, never ok" {
    write_lines "$TEST_ROOT/tpl" \
      'printf "source «HOME»/.dotfiles/load-custom.zsh" >>«HOME»/.zshrc' \
      'printf "source «HOME»/ai/vekil/env.zsh" >>«HOME»/.zshrc'
    write_lines "$TEST_ROOT/seed" \
      'printf "source «HOME»/ai/vekil/env.zsh" >>«HOME»/.zshrc' \
      'printf "source «HOME»/.dotfiles/load-custom.zsh" >>«HOME»/.zshrc'

    # Same lines, different order: a sorted comparison would call this clean.
    run diff <(sort "$TEST_ROOT/tpl") <(sort "$TEST_ROOT/seed")
    [ "$status" -eq 0 ]

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "DIVERGED" ]
  }

  @test "sd_verdict reports DIVERGED when lines differ in both directions" {
    write_lines "$TEST_ROOT/tpl" 'export A=1' 'run_old'
    write_lines "$TEST_ROOT/seed" 'export A=1' 'run_new'

    sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"

    [ "$status" -eq 0 ]
    [ "$output" = "DIVERGED" ]
  }
  ```

- [ ] **Step 12: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'DIVERGED'`
  Expected: both `not ok`, failing on `[ "$status" -eq 0 ]` — `sd_verdict`
  currently returns `1` with empty output for two-direction differences. The
  `run diff <(sort ...)` assertion passes, confirming the fixture really is a
  pure reordering.

- [ ] **Step 13: implement the DIVERGED branch.**
  In `bin/seed-drift`, replace the `else` branch of `sd_verdict_from_counts`:

  ```bash
    else
      printf 'DIVERGED\n'
    fi
  ```

- [ ] **Step 14: run the whole verdict group and see it pass.**
  `bats tests/seed_drift.bats -f 'sd_verdict'`
  Expected: six `ok` lines, including
  `ok N sd_verdict reports DIVERGED for a pure reordering, never ok`.

- [ ] **Step 15: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: report reordered seed blocks as DIVERGED rather than clean'`

---

### Task 6: discovery, reporting, exit codes (`sd_check_seed` and main)

Implements Decision 6 and the Output section. `sd_main` already exists from
Task 1 with option parsing, `SD_CANDIDATES`, the template-readable check, and the
doc/template anchor-agreement check (exit `2`); this task extends it rather than
replacing it.

**Files:**
- modify `bin/seed-drift`
- modify `tests/seed_drift.bats`

**Interfaces:**

*Consumes*
- `sd_parse_doc DOCFILE` (Task 1) → `blockname<TAB>anchor`, one row per line.
- `sd_extract FILE SCAN ANCHOR` (Task 4) → normalized lines on stdout; exit `4`
  when the anchor is absent, `3` when no window around it parses. Branch on the
  two separately: `4` is MISSING (exit 1), `3` is ERROR (exit 2).
- `sd_verdict_from_counts NB NA`, `sd_diff_lines`, `sd_count_lines`, `sd_tmp`
  (Task 5). Use `sd_verdict_from_counts` on counts you already hold rather than
  `verdict=$(sd_verdict ...)`, whose failure status would abort the run under
  `set -e`. Call `sd_tmp NAME`, never `$(sd_tmp)`.
- `SD_CANDIDATES` (bash array) and `SD_CANDIDATE_COUNT` (scalar), both set by
  Task 1's option parser; `SEED_DRIFT_ROOT` (default `$HOME/workspace`). Branch
  on the scalar — `${#SD_CANDIDATES[@]}` on an empty array is the bash 3.2
  `set -u` hazard documented at `bin/common.sh:392`.

*Produces*
- `sd_check_seed SEED` → per-block report on stdout; returns `0` clean, `1` any
  drift, `2` the seed does not parse or a block is unextractable.
- `sd_visit_dir DIR`, `sd_visit_candidates`, `sd_summary`, `sd_worst RC`,
  `sd_report_block VERDICT BLOCK DETAIL`, `sd_report_samples` (filter),
  `sd_report_action TEXT`.
- Counters `SD_CHECKED SD_SKIPPED SD_BEHIND SD_AHEAD SD_DIVERGED SD_MISSING`
  and `SD_WORST`. These are plain globals mutated in the caller's shell —
  `sd_check_seed` reads the doc via `done < <(sd_parse_doc "$SD_DOC")` process
  substitution, **not** a pipe, so the increments survive.
- `sd_main` exit status: `0` clean (skips included), `1` any drift, `2` usage /
  template / doc / extraction error — the maximum severity over all candidates.
- Summary line: `4 checked, 1 skipped, 2 blocks drifted (1 behind, 1 ahead)`.
  The parenthetical lists only non-zero categories in the order behind, ahead,
  diverged, missing, and is omitted entirely when nothing drifted.

---

- [ ] **Step 1: write the failing discovery tests.**
  Append to `tests/seed_drift.bats` (`write_drift_doc` is separate from Task 1's
  `write_fixture_doc` so the two fixture sets do not collide):

  ```bash
  write_drift_template() {
    cat >"$1" <<'TPL'
  #!/usr/bin/env bash
  set -euo pipefail

  TREE_SITTER_VERSION=0.25.10
  install_tree_sitter "$TREE_SITTER_VERSION"
  echo "seed: tree-sitter ready"

  GITIGNORE="$HOME/.gitignore_global"
  git config --global core.excludesFile "$GITIGNORE"
  TPL
  }

  write_drift_doc() {
    cat >"$1" <<'DOC'
  | Block | Anchor in template | Why it matters |
  |---|---|---|
  | tree-sitter CLI | `TREE_SITTER_VERSION` | pinned install |
  | global gitignore | `core.excludesFile` | git config |
  DOC
  }

  setup_drift_fixtures() {
    export SEED_DRIFT_ROOT="$TEST_ROOT/workspace"
    mkdir -p "$SEED_DRIFT_ROOT"
    FIXTURE_TEMPLATE="$TEST_ROOT/template.sh"
    FIXTURE_DOC="$TEST_ROOT/catch-up.md"
    write_drift_template "$FIXTURE_TEMPLATE"
    write_drift_doc "$FIXTURE_DOC"
  }

  make_project() { mkdir -p "$SEED_DRIFT_ROOT/$1/.devcontainer"; }
  seed_path() { printf '%s\n' "$SEED_DRIFT_ROOT/$1/.devcontainer/local-seed.sh"; }
  seed_from_template() { make_project "$1"; write_drift_template "$(seed_path "$1")"; }
  sd_drift() { run "$SEED_DRIFT" --template "$FIXTURE_TEMPLATE" --doc "$FIXTURE_DOC" "$@"; }

  @test "a clean seed exits 0 and is counted as checked" {
    setup_drift_fixtures
    seed_from_template clean

    sd_drift

    [ "$status" -eq 0 ]
    [[ "$output" == *"ok       tree-sitter CLI"* ]]
    [[ "$output" == *"1 checked, 0 skipped, 0 blocks drifted"* ]]
  }

  @test "a candidate with .devcontainer but no seed is skipped and a plain directory is silent" {
    setup_drift_fixtures
    seed_from_template clean
    make_project noseed
    mkdir -p "$SEED_DRIFT_ROOT/unrelated"

    sd_drift

    [ "$status" -eq 0 ]
    [[ "$output" == *"noseed  .devcontainer/ present, no local-seed.sh - skipped"* ]]
    [[ "$output" != *"unrelated"* ]]
    [[ "$output" == *"1 checked, 1 skipped, 0 blocks drifted"* ]]
  }

  @test "checked plus skipped equals the number of candidates" {
    setup_drift_fixtures
    seed_from_template one
    seed_from_template two
    make_project three
    mkdir -p "$SEED_DRIFT_ROOT/not-a-candidate"

    sd_drift

    [ "$status" -eq 0 ]
    [[ "$output" == *"2 checked, 1 skipped"* ]]
  }
  ```

- [ ] **Step 2: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'checked'`
  Expected: all three `not ok`. `sd_main` returns `0` but prints nothing after
  the anchor check, so each fails on its first `[[ "$output" == *...* ]]`
  assertion.

- [ ] **Step 3: implement the reporting primitives, the clean path, and discovery.**
  Insert into `bin/seed-drift` immediately above `sd_main()`. `sd_check_seed`
  handles only the `ok` verdict for now; Step 8 adds the drift branches:

  ```bash
  SD_TEMPLATE="" SD_DOC=""
  SD_CHECKED=0 SD_SKIPPED=0
  SD_BEHIND=0 SD_AHEAD=0 SD_DIVERGED=0 SD_MISSING=0
  SD_WORST=0

  sd_worst() {
    [ "$1" -gt "$SD_WORST" ] && SD_WORST="$1"
    return 0
  }

  sd_report_block() {
    if [ -n "$3" ]; then
      printf '  %-8s %-20s %s\n' "$1" "$2" "$3"
    else
      printf '  %-8s %s\n' "$1" "$2"
    fi
  }

  sd_report_samples() {
    local shown=0 line
    while IFS= read -r line; do
      [ "$shown" -lt 2 ] || break
      [ "${#line}" -le 56 ] || line="${line:0:53}..."
      printf '             - %s\n' "$line"
      shown=$((shown + 1))
    done
  }

  sd_report_action() {
    printf '             -> %s\n' "$1"
  }

  sd_check_seed() {
    local seed="$1" name rc=0 block anchor verdict tnorm snorm sscan
    name=$(basename -- "$(dirname -- "$(dirname -- "$seed")")")
    printf '%s  %s\n' "$name" "$seed"
    # Each file is scanned exactly once. The template scan is built by sd_main
    # and reused across every seed; the seed scan is built here, once, and
    # reused across every block. sd_extract needs a scan path — passing "" would
    # make awk fail to open its input on every call. `sd_tmp NAME`, never
    # `$(sd_tmp)`: the subshell form deletes the temp dir on subshell exit.
    sd_tmp sscan || return 2
    if ! sd_scan "$seed" >"$sscan"; then
      sd_report_block ERROR '(whole file)' 'seed could not be scanned'
      sd_report_action 'check the seed parses; see catch-up-local-seed.md Step 3'
      return 2
    fi
    sd_tmp tnorm || return 2
    sd_tmp snorm || return 2
    while IFS=$'\t' read -r block anchor; do
      sd_extract "$SD_TEMPLATE" "$SD_TEMPLATE_SCAN" "$anchor" >"$tnorm" || continue
      sd_extract "$seed" "$sscan" "$anchor" >"$snorm" || continue
      verdict=$(sd_verdict "$tnorm" "$snorm") || continue
      case "$verdict" in
        ok) sd_report_block ok "$block" '' ;;
      esac
    done < <(sd_parse_doc "$SD_DOC")
    return "$rc"
  }

  sd_summary() {
    local drifted=$((SD_BEHIND + SD_AHEAD + SD_DIVERGED + SD_MISSING)) parts="" pair
    for pair in "behind:$SD_BEHIND" "ahead:$SD_AHEAD" \
      "diverged:$SD_DIVERGED" "missing:$SD_MISSING"; do
      [ "${pair#*:}" -gt 0 ] || continue
      parts="${parts:+$parts, }${pair#*:} ${pair%%:*}"
    done
    printf '\n%d checked, %d skipped, %d blocks drifted%s\n' \
      "$SD_CHECKED" "$SD_SKIPPED" "$drifted" "${parts:+ ($parts)}"
  }

  sd_visit_dir() {
    local dir="$1" seed="$1/.devcontainer/local-seed.sh" rc=0
    if [ ! -f "$seed" ]; then
      printf '%s  .devcontainer/ present, no local-seed.sh - skipped\n' \
        "$(basename -- "$dir")"
      SD_SKIPPED=$((SD_SKIPPED + 1))
      return 0
    fi
    SD_CHECKED=$((SD_CHECKED + 1))
    sd_check_seed "$seed" || rc=$?
    sd_worst "$rc"
  }

  sd_visit_candidates() {
    local root="${SEED_DRIFT_ROOT:-$HOME/workspace}" cand
    shopt -s nullglob
    for cand in "$root"/*/; do
      cand="${cand%/}"
      # A directory without .devcontainer/ is not a candidate: silent, not skipped.
      [ -d "$cand/.devcontainer" ] || continue
      sd_visit_dir "$cand"
    done
  }
  ```

  Then replace the anchor-validation block Task 1 added to `sd_main` — from
  `local blocks` through its closing `return 0` — with the version below. Two
  changes: the template is scanned **once** here and reused by every seed, and
  anchor validation now runs against the scan's `C` records instead of raw
  `grep`.

  ```bash
    local blocks name anchor absent=0
    SD_TEMPLATE="$template"
    SD_DOC="$doc"
    SD_TEMPLATE_SCAN=""
    if ! sd_tmp SD_TEMPLATE_SCAN; then
      printf 'seed-drift: cannot create a temporary file\n' >&2
      return 2
    fi
    if ! sd_scan "$template" >"$SD_TEMPLATE_SCAN"; then
      printf 'seed-drift: cannot scan template %s\n' "$template" >&2
      return 2
    fi
    if ! blocks=$(sd_parse_doc "$doc"); then
      printf 'seed-drift: no block table found in %s\n' "$doc" >&2
      return 2
    fi
    while IFS=$'\t' read -r name anchor; do
      # Against the scan, not `grep -qF "$anchor" "$template"`. Anchors name
      # code, and the scan's C records are comment-stripped — so an anchor that
      # survives only inside a comment now fails validation instead of passing
      # and then extracting nothing.
      if [ -z "$(sd_paras_with_anchor "$SD_TEMPLATE_SCAN" "$anchor")" ]; then
        printf 'seed-drift: anchor %s (block: %s) is absent from %s\n' \
          "$anchor" "$name" "$template" >&2
        absent=1
      fi
    done <<<"$blocks"
    if [ "$absent" -ne 0 ]; then
      return 2
    fi
    sd_visit_candidates
    sd_summary
    return "$SD_WORST"
  }
  ```

- [ ] **Step 4: run them and see them pass.**
  `bats tests/seed_drift.bats -f 'checked'`
  Expected: `ok` for `a clean seed exits 0 and is counted as checked`,
  `a candidate with .devcontainer but no seed is skipped and a plain directory
  is silent`, and `checked plus skipped equals the number of candidates`.

- [ ] **Step 5: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: discover seed candidates and report clean projects with a summary'`

- [ ] **Step 6: write the failing drift-reporting tests.**
  Each asserts the project, the block, and the direction; the `AHEAD` and
  `DIVERGED` cases assert the promotion / inspect wording and assert the output
  never suggests overwriting. Append to `tests/seed_drift.bats`:

  ```bash
  @test "a behind seed exits 1 and the finding names project, block and direction" {
    setup_drift_fixtures
    seed_from_template behindp
    sed -i '/tree-sitter ready/d' "$(seed_path behindp)"

    sd_drift

    [ "$status" -eq 1 ]
    [[ "$output" == *"behindp  $(seed_path behindp)"* ]]
    [[ "$output" == *"BEHIND   tree-sitter CLI      1 template lines absent from seed"* ]]
    [[ "$output" == *'- echo "seed: tree-sitter ready"'* ]]
    [[ "$output" == *"port from template; see catch-up-local-seed.md Step 2"* ]]
    [[ "$output" == *"1 checked, 0 skipped, 1 blocks drifted (1 behind)"* ]]
  }

  @test "an ahead seed is a promotion candidate and never suggests overwriting" {
    setup_drift_fixtures
    seed_from_template aheadp
    sed -i '/tree-sitter ready/a echo "seed: project extra"' "$(seed_path aheadp)"

    sd_drift

    [ "$status" -eq 1 ]
    [[ "$output" == *"AHEAD    tree-sitter CLI      1 seed lines absent from template"* ]]
    [[ "$output" == *"promotion candidate; do NOT overwrite the seed"* ]]
    [[ "$output" != *"overwrite the seed with"* ]]
  }

  @test "a reordered seed is DIVERGED and told to inspect by hand" {
    setup_drift_fixtures
    seed_from_template reorder
    sed -i '5d' "$(seed_path reorder)"
    sed -i '/tree-sitter ready/a install_tree_sitter "$TREE_SITTER_VERSION"' \
      "$(seed_path reorder)"

    sd_drift

    [ "$status" -eq 1 ]
    [[ "$output" == *"DIVERGED tree-sitter CLI"* ]]
    [[ "$output" == *"inspect by hand; do NOT overwrite the seed"* ]]
  }

  @test "an anchor absent from the seed is MISSING" {
    setup_drift_fixtures
    seed_from_template gone
    sed -i '/core.excludesFile/d' "$(seed_path gone)"

    sd_drift

    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING  global gitignore     anchor absent from seed"* ]]
    [[ "$output" == *"1 blocks drifted (1 missing)"* ]]
  }
  ```

- [ ] **Step 7: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'seed is|seed exits 1|absent from the seed'`
  Expected: all four `not ok`. The `BEHIND`, `AHEAD` and `DIVERGED` cases fall
  through the `case` silently and exit `0`, so each fails on
  `[ "$status" -eq 1 ]`; the `MISSING` case fails on the unhandled exit `4` from
  `sd_extract`.

- [ ] **Step 8: implement the drift branches.**
  In `bin/seed-drift`, replace the body of `sd_check_seed` between the `tnorm`/
  `snorm` assignments and the `rm -f` line:

  ```bash
    while IFS=$'\t' read -r block anchor; do
      # Branch on the ORIGINAL status. sd_extract returns 4 for "anchor absent"
      # and 3 for "the block would not parse"; `if ! sd_extract` flattens both
      # into one branch, so a seed whose block is unextractable would be
      # reported as MISSING and exit 1 — a wrong verdict at the wrong severity.
      tst=0
      sd_extract "$SD_TEMPLATE" "$SD_TEMPLATE_SCAN" "$anchor" >"$tnorm" || tst=$?
      case "$tst" in
        0) ;;
        4)
          sd_report_block ERROR "$block" 'anchor absent from template'
          rc=2
          continue
          ;;
        *)
          sd_report_block ERROR "$block" 'template block could not be extracted'
          rc=2
          continue
          ;;
      esac
      est=0
      sd_extract "$seed" "$sscan" "$anchor" >"$snorm" || est=$?
      case "$est" in
        0) ;;
        4)
          sd_report_block MISSING "$block" 'anchor absent from seed'
          sd_report_action 'port the block; see catch-up-local-seed.md Step 2'
          SD_MISSING=$((SD_MISSING + 1))
          [ "$rc" -ge 1 ] || rc=1
          continue
          ;;
        *)
          sd_report_block ERROR "$block" 'seed block could not be extracted'
          rc=2
          continue
          ;;
      esac
      # Same file-not-substitution rule as sd_verdict: a removed blank line must
      # survive into the count and the samples.
      sd_tmp behind || return 2
      sd_tmp ahead || return 2
      if ! sd_diff_lines "$tnorm" "$snorm" '<' >"$behind" ||
        ! sd_diff_lines "$tnorm" "$snorm" '>' >"$ahead"; then
        sd_report_block ERROR "$block" 'diff failed'
        rc=2
        continue
      fi
      nb=$(sd_count_lines "$behind")
      na=$(sd_count_lines "$ahead")
      # From the counts just computed, not `verdict=$(sd_verdict ...)`: that
      # form re-runs the same two diffs, and its non-zero status on a diff
      # failure would abort the program under `set -e` — exiting 3 outside the
      # public 0/1/2 contract and skipping every remaining project.
      verdict=$(sd_verdict_from_counts "$nb" "$na")
      case "$verdict" in
        ok)
          sd_report_block ok "$block" ''
          ;;
        BEHIND)
          sd_report_block BEHIND "$block" "$nb template lines absent from seed"
          sd_report_samples <"$behind"
          sd_report_action 'port from template; see catch-up-local-seed.md Step 2'
          SD_BEHIND=$((SD_BEHIND + 1))
          [ "$rc" -ge 1 ] || rc=1
          ;;
        AHEAD)
          sd_report_block AHEAD "$block" "$na seed lines absent from template"
          sd_report_samples <"$ahead"
          sd_report_action 'promotion candidate; do NOT overwrite the seed'
          SD_AHEAD=$((SD_AHEAD + 1))
          [ "$rc" -ge 1 ] || rc=1
          ;;
        DIVERGED)
          sd_report_block DIVERGED "$block" \
            "$nb template lines absent from seed, $na seed lines absent from template"
          sd_report_action 'inspect by hand; do NOT overwrite the seed'
          SD_DIVERGED=$((SD_DIVERGED + 1))
          [ "$rc" -ge 1 ] || rc=1
          ;;
      esac
    done < <(sd_parse_doc "$SD_DOC")
  ```

  and widen the function's `local` line to declare the new variables:

  ```bash
    local seed="$1" name rc=0 block anchor verdict tnorm snorm sscan
    local behind ahead nb na est tst
  ```

- [ ] **Step 9: run them and see them pass.**
  `bats tests/seed_drift.bats -f 'seed is|seed exits 1|absent from the seed'`
  Expected: four `ok` lines, including `a reordered seed is DIVERGED and told to
  inspect by hand`.

- [ ] **Step 10: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: report BEHIND, AHEAD, DIVERGED and MISSING blocks per project'`

- [ ] **Step 11: write the failing argument-classification tests.**
  Append to `tests/seed_drift.bats`:

  ```bash
  @test "a nonexistent argument is skipped and named, exit 0" {
    setup_drift_fixtures

    sd_drift "$SEED_DRIFT_ROOT/absent-project"

    [ "$status" -eq 0 ]
    [[ "$output" == *"absent-project - not present on this machine - skipped"* ]]
    [[ "$output" == *"0 checked, 1 skipped, 0 blocks drifted"* ]]
  }

  @test "an argument is accepted as a project directory or as a direct seed path" {
    setup_drift_fixtures
    seed_from_template clean

    sd_drift "$SEED_DRIFT_ROOT/clean"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 checked, 0 skipped"* ]]

    sd_drift "$(seed_path clean)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 checked, 0 skipped"* ]]
  }
  ```

- [ ] **Step 12: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'argument'`
  Expected: both `not ok`. `sd_visit_candidates` ignores `SD_CANDIDATES` and
  globs `$SEED_DRIFT_ROOT` regardless, so both report `0 checked, 0 skipped` and
  fail their first `[[ "$output" == *...* ]]` assertion.

- [ ] **Step 13: honour explicit candidates.**
  In `bin/seed-drift`, replace `sd_visit_candidates` with:

  ```bash
  sd_visit_candidates() {
    local root="${SEED_DRIFT_ROOT:-$HOME/workspace}" cand rc=0
    # The scalar, not `${#SD_CANDIDATES[@]}`: expanding an empty array under
    # `set -u` errors on bash 3.2, still the system bash on macOS
    # (bin/common.sh:392). The `"${SD_CANDIDATES[@]}"` below is reached only
    # when the count is non-zero, so it is safe.
    if [ "$SD_CANDIDATE_COUNT" -eq 0 ]; then
      shopt -s nullglob
      for cand in "$root"/*/; do
        cand="${cand%/}"
        # A directory without .devcontainer/ is not a candidate: silent, not skipped.
        [ -d "$cand/.devcontainer" ] || continue
        sd_visit_dir "$cand"
      done
      return 0
    fi
    for cand in "${SD_CANDIDATES[@]}"; do
      if [ -d "$cand" ]; then
        [ -d "$cand/.devcontainer" ] || continue
        sd_visit_dir "$cand"
      elif [ -e "$cand" ]; then
        # An existing file is a direct local-seed.sh path.
        SD_CHECKED=$((SD_CHECKED + 1))
        rc=0
        sd_check_seed "$cand" || rc=$?
        sd_worst "$rc"
      else
        # Not checked out here. A skip, so the same project list works on every
        # machine; it names the path and is counted, so a typo stays visible.
        printf '%s - not present on this machine - skipped\n' "$cand"
        SD_SKIPPED=$((SD_SKIPPED + 1))
      fi
    done
  }
  ```

- [ ] **Step 14: run them and see them pass.**
  `bats tests/seed_drift.bats -f 'argument'`
  Expected: `ok N a nonexistent argument is skipped and named, exit 0` and
  `ok N an argument is accepted as a project directory or as a direct seed path`.

- [ ] **Step 15: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: classify seed-drift arguments as project, seed path or absent skip'`

- [ ] **Step 16: write the failing parse-failure and severity tests.**
  The malformed-seed test uses `aaa-`/`zzz-` prefixes so the broken seed is
  visited *first* under the glob's sort order — that is what makes it a real
  guard against aborting on the first bad seed. Append to
  `tests/seed_drift.bats`:

  ```bash
  @test "a malformed seed exits 2 without suppressing drift in the others" {
    setup_drift_fixtures
    seed_from_template aaa-broken
    printf 'if true; then\nTREE_SITTER_VERSION=1\n' >"$(seed_path aaa-broken)"
    seed_from_template zzz-behind
    sed -i '/tree-sitter ready/d' "$(seed_path zzz-behind)"

    sd_drift

    [ "$status" -eq 2 ]
    [[ "$output" == *"does not parse (bash -n)"* ]]
    [[ "$output" == *"BEHIND   tree-sitter CLI"* ]]
    [[ "$output" == *"2 checked, 0 skipped, 1 blocks drifted (1 behind)"* ]]
  }

  @test "an unparseable template is exit 2 before any verdict" {
    setup_drift_fixtures
    seed_from_template clean
    printf 'if true; then\n' >"$FIXTURE_TEMPLATE"

    sd_drift

    [ "$status" -eq 2 ]
    [[ "$output" == *"template does not parse"* ]]
    [[ "$output" != *"ok       tree-sitter CLI"* ]]
  }

  @test "the detector never writes to a seed" {
    setup_drift_fixtures
    seed_from_template clean
    local before after
    before=$(cksum <"$(seed_path clean)")

    sd_drift

    after=$(cksum <"$(seed_path clean)")
    [ "$before" = "$after" ]
  }
  ```

- [ ] **Step 17: run them and see them fail.**
  `bats tests/seed_drift.bats -f 'malformed|unparseable|never writes'`
  Expected: `a malformed seed exits 2 without suppressing drift in the others`
  and `an unparseable template is exit 2 before any verdict` both `not ok`,
  failing on `[ "$status" -eq 2 ]`; `the detector never writes to a seed` already
  passes and stays green as a regression guard.

- [ ] **Step 18: add the two `bash -n` gates.**
  In `bin/seed-drift`, insert at the top of `sd_check_seed`, directly after the
  `printf '%s  %s\n' "$name" "$seed"` line:

  ```bash
    if ! bash -n "$seed" 2>/dev/null; then
      sd_report_block ERROR "$name" 'does not parse (bash -n)'
      return 2
    fi
  ```

  In `sd_main`, insert immediately **before** the `local blocks` / `sd_parse_doc`
  block — ahead of the anchor-agreement check, because a template that does not
  parse makes every anchor verdict derived from it meaningless:

  ```bash
    if ! bash -n "$template" 2>/dev/null; then
      printf 'seed-drift: template does not parse: %s\n' "$template" >&2
      return 2
    fi
  ```

- [ ] **Step 19: run the full suite and see it pass.**
  `bats tests/seed_drift.bats`
  Expected: every test `ok`, including
  `a malformed seed exits 2 without suppressing drift in the others`,
  `an unparseable template is exit 2 before any verdict`, and
  `the detector never writes to a seed`. Then confirm the linters:
  `shfmt -i 2 -ci -d bin/seed-drift && shellcheck -x -S warning bin/seed-drift`
  Expected: no output from either, exit `0`.

- [ ] **Step 20: commit.**
  `git add bin/seed-drift tests/seed_drift.bats && git commit -m 'feat: fail closed on unparseable templates and seeds without hiding drift'`

---

### Task 7: full regression suite, read-only guarantee, and verification

**Files:**
- `tests/seed_drift.bats` (append; 25 new tests)
- No production file changes expected. If a test in this task fails, `bin/seed-drift` has a real gap and must be fixed before the task continues — these tests are the specification, not decoration.

**Interfaces:** (from CONTRACT.md, unchanged by this task)
- `bin/seed-drift [--template PATH] [--doc PATH] [--help] [CANDIDATE...]`
- exit `0` clean (skips included) | `1` any drift | `2` usage/template/doc/extraction error
- verdict tokens printed per block: `ok` | `MISSING` | `BEHIND` | `AHEAD` | `DIVERGED`
- doc table row shape: `| Block name | \`anchor\` | why |`

---

- [ ] **Step 1: add the Task-7 fixture helpers.**

Append to `tests/seed_drift.bats`. Names are `t7_`-prefixed so they cannot collide with helpers introduced in Tasks 1-6.

```bash
# ── Task 7 fixture helpers ───────────────────────────────────────────────────

t7_setup() {
  TPL="$BATS_TEST_TMPDIR/template.sh"
  DOC="$BATS_TEST_TMPDIR/catch-up.md"
  WS="$TEST_ROOT/ws"
  PROJ="$WS/demo"
  SEED="$PROJ/.devcontainer/local-seed.sh"
  mkdir -p "$PROJ/.devcontainer"
  export SEED_DRIFT_ROOT="$WS"
}

# t7_doc "Block name" anchor [ "Block name" anchor ... ]
t7_doc() {
  {
    printf '| Block | Anchor in template | Why it matters |\n'
    printf '|---|---|---|\n'
    while [ "$#" -gt 0 ]; do
      printf '| %s | `%s` | fixture row |\n' "$1" "$2"
      shift 2
    done
  } >"$DOC"
}

t7_run() {
  run "$REPO_ROOT/bin/seed-drift" --template "$TPL" --doc "$DOC" "$@"
}
```

- [ ] **Step 1b: regression tests for the six integration defects.**

These pin bugs that plan reviews caught before implementation. Most of them
fail *silently* if reintroduced — wrong verdict or false `ok`, never a crash —
so they are the tests most worth having. Append to `tests/seed_drift.bats`:

```bash
@test "a tab inside a heredoc payload survives extraction verbatim" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  printf '#!/usr/bin/env bash\n\ntee "$G" <<%s\n\tcol1\tcol2\nGITEOF\n\ngit config --global core.excludesFile "$G"\n' "'GITEOF'" >"$TPL"
  # Seed differs ONLY by collapsing the payload tabs to spaces.
  printf '#!/usr/bin/env bash\n\ntee "$G" <<%s\n  col1  col2\nGITEOF\n\ngit config --global core.excludesFile "$G"\n' "'GITEOF'" >"$SEED"

  t7_run
  # If the reader strips or truncates tabs, both sides normalize alike and this
  # reports ok — the exact false-clean the tool exists to prevent.
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "sd_count_lines counts blank records" {
  printf '\n\na\n' >"$BATS_TEST_TMPDIR/three"
  sd_source sd_count_lines "$BATS_TEST_TMPDIR/three"
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
}

@test "a temp file from sd_tmp is still writable after the call returns" {
  # `raw="$(sd_tmp)"` ran the whole thing in a subshell: the directory and its
  # EXIT trap were created there, so the trap fired the moment the substitution
  # closed and deleted the directory before the caller could write to the path
  # it had just been handed. Every diff in the tool wrote into thin air.
  run env SEED_DRIFT_SOURCE_ONLY=1 bash -c '
    source "$1"
    sd_tmp f || exit 9
    printf hello >"$f" || exit 8
    cat "$f"
  ' _ "$SEED_DRIFT"
  [ "$status" -eq 0 ]
  [ "$output" = hello ]
}

@test "a seed block that cannot be extracted is ERROR and exit 2, not MISSING" {
  t7_setup
  t7_doc "tree-sitter CLI" TREE_SITTER_VERSION
  printf '#!/usr/bin/env bash\n\ninstall_ts "$TREE_SITTER_VERSION"\n' >"$TPL"
  # Anchor present, but no window around it ever parses: the `do` is never
  # closed anywhere in the file, so sd_window exhausts both directions.
  printf '#!/usr/bin/env bash\n\nfor x in a b; do\n  install_ts "$TREE_SITTER_VERSION"\n' >"$SEED"

  t7_run
  [ "$status" -eq 2 ]
  [[ "$output" == *ERROR* ]]
  # The bug this pins: `if ! sd_extract` collapsed 3 and 4, reporting a seed
  # that will not parse as merely behind the template.
  [[ "$output" != *MISSING* ]]
}

@test "sd_extract returns 3, not 4, when no window around the anchor parses" {
  # The integration test above stops at sd_check_seed's whole-file `bash -n`
  # gate and never reaches sd_extract, so it cannot tell 3 from 4 at the
  # helper level. This does, by calling sd_extract directly. Since sd_window
  # grows to the whole file before giving up, only a file that itself fails to
  # parse can produce status 3 — hence the same unclosed `do`.
  printf '#!/usr/bin/env bash\n\nfor x in a b; do\n  install_ts "$TREE_SITTER_VERSION"\n' \
    >"$FIX/bad.sh"
  sd_source sd_scan "$FIX/bad.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$FIX/bad.scan"

  sd_source sd_extract "$FIX/bad.sh" "$FIX/bad.scan" TREE_SITTER_VERSION
  [ "$status" -eq 3 ]

  # And 4 really is reserved for the absent anchor, on the same inputs.
  sd_source sd_extract "$FIX/bad.sh" "$FIX/bad.scan" NVIM_VERSION
  [ "$status" -eq 4 ]
}

@test "privilege normalization is portable and keyword-boundary correct" {
  # `\b` is a GNU sed extension; BSD sed (macOS, which this script supports)
  # silently fails to match it, so every `if as_user ...` line would keep its
  # privilege word and report as drift on a Mac and clean on Linux.
  run grep -n '\\b' "$SEED_DRIFT"
  [ "$status" -ne 0 ]

  scan_line 1 1 C 'if as_user test -x /x; then'
  scan_line 1 2 C 'foo || $SUDO chmod 0755 /x'
  scan_line 1 3 C 'do runuser -u me -- npm i'
  # The boundary the `\b` used to provide: a word merely ENDING in a keyword
  # must not license the drop.
  scan_line 1 4 C 'notif as_user keepme'
  norm
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'if test -x /x; then' ]
  [ "${lines[1]}" = 'foo || chmod 0755 /x' ]
  [ "${lines[2]}" = 'do npm i' ]
  [ "${lines[3]}" = 'notif as_user keepme' ]
}

@test "an anchor present only in a template comment fails validation" {
  t7_setup
  t7_doc "codex guard" local/bin/codex
  printf '#!/usr/bin/env bash\n\n# once guarded local/bin/codex, now removed\necho hi\n' >"$TPL"
  printf '#!/usr/bin/env bash\n\necho hi\n' >"$SEED"

  t7_run
  [ "$status" -eq 2 ]
  [[ "$output" == *"is absent from"* ]]
}
```

- [ ] **Step 1c: run them and watch them fail for the right reason.**

`bats tests/seed_drift.bats -f 'tab inside|blank records|cannot be extracted|only in a template comment'`

Expected: four `not ok`. Confirm each fails on its assertion rather than on a
missing function — if `sd_count_lines` reports `command not found`, Task 5 was
not completed.

- [ ] **Step 2: the MOTIVATING test — anchor present, surrounding block outdated.**

This is the case the whole tool exists for: all five live seeds carried `TREE_SITTER_VERSION` while the block around it was the pre-#38 shape. A detector that passes the current five without this test proves nothing.

```bash
@test "anchor present but surrounding block outdated reports BEHIND with exit 1" {
  t7_setup
  t7_doc "tree-sitter CLI" TREE_SITTER_VERSION
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
  if curl -fsSL -o "$TS_TMP/tree-sitter.gz" "$TS_URL" &&
    gunzip -c "$TS_TMP/tree-sitter.gz" >"$TS_TMP/tree-sitter" &&
    chmod 0755 "$TS_BIN.new" &&
    as_user "$TS_BIN.new" --version >/dev/null 2>&1 &&
    as_user mv "$TS_BIN.new" "$TS_BIN"; then
    echo "seed: tree-sitter ready"
  elif [ -f "$TS_BIN.new" ] && ! TS_ERR="$(as_user "$TS_BIN.new" --version 2>&1 >/dev/null)"; then
    echo "seed: tree-sitter binary unusable: $TS_ERR" >&2
  elif sh -c 'command -v tree-sitter >/dev/null 2>&1'; then
    echo "seed: tree-sitter already present (image-provided)"
  else
    echo "seed: tree-sitter install failed" >&2
  fi
fi
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
  if curl -fsSL -o "$TS_TMP/tree-sitter.gz" "$TS_URL" &&
    gunzip -c "$TS_TMP/tree-sitter.gz" >"$TS_TMP/tree-sitter" &&
    chmod 0755 "$TS_BIN.new" &&
    as_user "$TS_BIN.new" --version >/dev/null 2>&1 &&
    as_user mv "$TS_BIN.new" "$TS_BIN"; then
    echo "seed: tree-sitter ready"
  else
    echo "seed: tree-sitter install failed" >&2
  fi
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *BEHIND* ]]
  [[ "$output" == *"tree-sitter CLI"* ]]
  [[ "$output" != *MISSING* ]]
}
```

- [ ] **Step 3: run the motivating test.**

From `/home/tng/.dotfiles/.claude/worktrees/seed-drift-detector`:

`bats tests/seed_drift.bats`

Expected: every test passes, including `ok ... anchor present but surrounding block outdated reports BEHIND with exit 1`. A `MISSING` verdict here means anchor matching is running against un-stripped text or against heredoc bodies; an `ok` verdict means extraction collapsed to the anchor line and the tool is reproducing the bug it exists to fix.

- [ ] **Step 4: a change confined to a block's NON-anchor lines is reported.**

Modelled on `core.excludesFile` (template lines 204-236): the anchor sits on the final `git config` line, and the substance of the block is the heredoc above it.

```bash
@test "change confined to non-anchor lines of the block is reported" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash
set -euo pipefail

GITIGNORE="$SEED_HOME/.gitignore"
if ! as_user test -f "$GITIGNORE"; then
  as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*~
*.swp

# Personal Claude Code overlay shims (symlinked in from ~/.dotfiles/projects/).
CLAUDE.local.md
AGENTS.local.md

# Personal docker-compose overrides.
docker-compose.override.yml
GITEOF
  echo "seed: wrote container-local ~/.gitignore"
fi
as_user git config --global core.excludesFile "$GITIGNORE"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash
set -euo pipefail

GITIGNORE="$SEED_HOME/.gitignore"
if ! as_user test -f "$GITIGNORE"; then
  as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*~

# Personal Claude Code overlay shims (symlinked in from ~/.dotfiles/projects/).
CLAUDE.local.md
AGENTS.local.md

# Personal docker-compose overrides.
docker-compose.override.yml
GITEOF
  echo "seed: wrote container-local ~/.gitignore"
fi
as_user git config --global core.excludesFile "$GITIGNORE"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *BEHIND* ]]
  [[ "$output" == *core.excludesFile* ]]
}
```

- [ ] **Step 5: heredoc payload is compared verbatim — four tests.**

Every normalization rule corrupts payload. These pin that none of them runs inside a body.

```bash
@test "changed # line inside a quoted heredoc body is drift, not stripped as a comment" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
# Personal Claude Code overlay shims (symlinked in from ~/.dotfiles/projects/).
CLAUDE.local.md
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
# Personal overlay shims.
CLAUDE.local.md
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "changed leading whitespace inside a heredoc body is drift" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*.swp
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
    *.swp
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "removed blank line inside a heredoc body is drift" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store

*.swp
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*.swp
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *BEHIND* ]]
}

@test "trailing backslash inside a heredoc body is not a line continuation" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
literal-backslash \
second-payload-line
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
literal-backslash second-payload-line
GITEOF
as_user git config --global core.excludesFile "$GITIGNORE"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}
```

- [ ] **Step 6: run the heredoc-payload tests.**

`bats tests/seed_drift.bats`

Expected: all pass. A clean verdict on the `#`-line test means comment stripping is leaking into `Hq` bodies; a clean verdict on the backslash test means continuation joining is.

- [ ] **Step 7: unquoted delimiters get path neutralization, quoted ones do not.**

```bash
@test "unquoted heredoc delimiter gets path neutralization" {
  t7_setup
  t7_doc "unquoted body" HEREDOC_ANCHOR
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

HEREDOC_ANCHOR=unquoted
tee "$OUT" >/dev/null <<UNQ
$SEED_HOME/.local/bin
UNQ
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

HEREDOC_ANCHOR=unquoted
tee "$OUT" >/dev/null <<UNQ
$HOME/.local/bin
UNQ
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "quoted heredoc delimiter does not get path neutralization" {
  t7_setup
  t7_doc "quoted body" HEREDOC_ANCHOR
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

HEREDOC_ANCHOR=quoted
tee "$OUT" >/dev/null <<'QUO'
$SEED_HOME/.local/bin
QUO
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

HEREDOC_ANCHOR=quoted
tee "$OUT" >/dev/null <<'QUO'
$HOME/.local/bin
QUO
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}
```

- [ ] **Step 8: heredoc opener recognition — four tests.**

A scanner keying on a bare `<<` swallows the rest of the file at template line 255, which sits inside the overlay-gitignore anchored block.

```bash
@test "<< inside a double-quoted string is not a heredoc opener" {
  t7_setup
  t7_doc "Overlay-link gitignore" "lname '*dotfiles/projects/*'"
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# << overlay symlinks (auto) <<"
overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*dotfiles/projects/*' -print)"
echo "$overlay_links"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# << overlay symlinks (auto) <<"
overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*/.dotfiles/projects/*' -print)"
echo "$overlay_links"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overlay-link gitignore"* ]]
  [[ "$output" != *MISSING* ]]
}

@test "<<< herestrings are not heredoc openers" {
  t7_setup
  t7_doc "herestring block" HERESTRING_ANCHOR
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

HERESTRING_ANCHOR=1
read -r first_word <<<"$SEED_HOME/.local/bin"
echo "template says $first_word"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

HERESTRING_ANCHOR=1
read -r first_word <<<"$SEED_HOME/.local/bin"
echo "seed says $first_word"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
  [[ "$output" != *MISSING* ]]
}

@test "each heredoc delimiter form is recognized and tracks its body" {
  t7_setup
  t7_doc "form block" FORM_ANCHOR
  local open
  for open in "<<TAG" "<<'TAG'" '<<"TAG"' '<<\TAG' "<<-TAG"; do
    {
      printf '#!/usr/bin/env bash\n\n'
      printf 'FORM_ANCHOR=1\n'
      printf 'tee "$OUT" >/dev/null %s\n' "$open"
      printf 'payload-one\n\npayload-two\nTAG\n'
    } >"$TPL"
    {
      printf '#!/usr/bin/env bash\n\n'
      printf 'FORM_ANCHOR=1\n'
      printf 'tee "$OUT" >/dev/null %s\n' "$open"
      printf 'payload-one\n\npayload-CHANGED\nTAG\n'
    } >"$SEED"
    t7_run "$SEED"
    [ "$status" -eq 1 ] || {
      echo "form $open: expected drift, got status $status: $output" >&2
      return 1
    }
    [[ "$output" == *DIVERGED* ]] || {
      echo "form $open: expected DIVERGED, got: $output" >&2
      return 1
    }
  done
}

@test "unrecognized heredoc syntax is an error, not a silent fallback" {
  t7_setup
  t7_doc "form block" FORM_ANCHOR
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

FORM_ANCHOR=1
TAG=EOFWORD
cat <<$TAG
payload
EOFWORD
TPLEOF
  cp "$TPL" "$SEED"
  t7_run "$SEED"
  [ "$status" -eq 2 ]
  [[ "$output" != *ok* ]]
}
```

- [ ] **Step 9: run the heredoc-recognition tests.**

`bats tests/seed_drift.bats`

Expected: all pass. A `MISSING` in the first two tests means a bare `<<` matched and the scanner ate the remainder of the file. A `0` or `1` in the last test means unrecognized syntax degraded to "probably not a heredoc" — the silent failure mode the spec forbids.

- [ ] **Step 10: the ownership rule is exact — four tests.**

The idiom is dropped only when matched fully literally post-normalization; nothing is free.

```bash
t7_own_tpl() {
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
TPLEOF
}

@test "ownership idiom with a changed target is drift, not dropped" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "$SEED_UID:$SEED_GID" "$NVIM_CACHE.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_CACHE.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "ownership idiom with -R removed is drift, not dropped" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "ownership idiom with a changed identity is drift, not dropped" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "0:0" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}

@test "an unrelated chown line is compared normally" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
  chown -R "$SEED_UID:$SEED_GID" "$SEED_HOME/.cache"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *AHEAD* ]]
  [[ "$output" != *overwrite* ]]
}
```

- [ ] **Step 11: false-positive guards — six tests, one per normalization rule.**

```bash
@test "false-positive guard: as_user prefix vs direct invocation" {
  t7_setup
  t7_doc "core.hooksPath" core.hooksPath
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

as_user git config --global core.hooksPath "$DOTFILES_HOME/git/hooks"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

git config --global core.hooksPath "$DOTFILES_HOME/git/hooks"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "false-positive guard: SEED_HOME vs HOME" {
  t7_setup
  t7_doc "core.hooksPath" core.hooksPath
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

git config --global core.hooksPath "$SEED_HOME/.dotfiles/git/hooks"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

git config --global core.hooksPath "$HOME/.dotfiles/git/hooks"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "false-positive guard: DOTFILES_HOME vs HOME/.dotfiles" {
  t7_setup
  t7_doc "core.hooksPath" core.hooksPath
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

git config --global core.hooksPath "$DOTFILES_HOME/git/hooks"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

git config --global core.hooksPath "$HOME/.dotfiles/git/hooks"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "false-positive guard: restyled line continuations" {
  t7_setup
  t7_doc "codex guard" local/bin/codex
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

if [ ! -x "$SEED_HOME/.local/bin/codex" ]; then
  as_user npm install -g \
    --prefix "$SEED_HOME/.local" \
    @openai/codex
fi
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

if [ ! -x "$SEED_HOME/.local/bin/codex" ]; then
  as_user npm install -g --prefix "$SEED_HOME/.local" @openai/codex
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "false-positive guard: reworded comments" {
  t7_setup
  t7_doc "codex guard" local/bin/codex
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

# Guard the reinstall on the binary, not ~/.codex/config.toml: the installer
# writes config even when it fails to produce a binary.
if [ ! -x "$SEED_HOME/.local/bin/codex" ]; then # binary, not config
  as_user npm install -g @openai/codex
fi
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

# Check for the codex binary itself; a config-based guard latches shut.
if [ ! -x "$SEED_HOME/.local/bin/codex" ]; then # check the binary
  as_user npm install -g @openai/codex
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "false-positive guard: both exact ownership idiom forms are dropped" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST "tree-sitter CLI" TS_BIN
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi

TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
if [ -f "$TS_BIN.new" ]; then
  { chown "$SEED_UID:$SEED_GID" "$TS_BIN.new" 2>/dev/null ||
    [ -z "$(find "$TS_BIN.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$TS_BIN.new" "$TS_BIN"
fi
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi

TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
if [ -f "$TS_BIN.new" ]; then
  as_user mv "$TS_BIN.new" "$TS_BIN"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" != *BEHIND* ]]
  [[ "$output" != *DIVERGED* ]]
}
```

- [ ] **Step 12: `sed 's#...#g'` survives comment stripping.**

Trailing-comment stripping must run only when quotes balance before the `#`.

```bash
@test "sed substitution with # delimiters survives comment stripping" {
  t7_setup
  t7_doc "plugin repair" PLUGIN_REPAIR
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

PLUGIN_REPAIR=1
sed -i 's#/opt/dotfiles#/home/seed/.dotfiles#g' "$f" # rewrite the stable root
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

PLUGIN_REPAIR=1
sed -i 's#/opt/dotfiles#/home/seed/.dotfiles#g' "$f" # fix up the link root
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]

  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

PLUGIN_REPAIR=1
sed -i 's#/opt/dotfiles#/home/seed/OTHER#g' "$f" # rewrite the stable root
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
}
```

- [ ] **Step 13: run the ownership, guard, and sed tests.**

`bats tests/seed_drift.bats`

Expected: all pass. A drift verdict in any of the six guards means a normalization rule is missing; a clean verdict in any ownership test means a rule is too broad — the silent direction, which must be fixed, not tolerated.

- [ ] **Step 14: READ-ONLY guarantee — seeds are byte-identical after a run.**

Safety-critical: seeds are gitignored with no revert path.

```bash
@test "seeds are byte-identical after a run (read-only)" {
  t7_setup
  t7_doc "tree-sitter CLI" TREE_SITTER_VERSION
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  echo "seed: installing tree-sitter $TREE_SITTER_VERSION"
  as_user mv "$TS_BIN.new" "$TS_BIN"
fi
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  echo "seed: installing tree-sitter $TREE_SITTER_VERSION"
fi
SEEDEOF
  # a drifted seed, a clean seed, and a candidate with no seed at all
  mkdir -p "$WS/clean/.devcontainer" "$WS/noseed/.devcontainer"
  cp "$TPL" "$WS/clean/.devcontainer/local-seed.sh"

  local before after
  before="$(find "$WS" -type f -exec sha256sum {} + | sort)"
  run "$REPO_ROOT/bin/seed-drift" --template "$TPL" --doc "$DOC"
  [ "$status" -eq 1 ]
  after="$(find "$WS" -type f -exec sha256sum {} + | sort)"
  [ "$before" = "$after" ]
}
```

- [ ] **Step 15: a malformed seed does not suppress drift reporting for the others.**

```bash
@test "a malformed seed does not suppress drift reporting for the others" {
  t7_setup
  t7_doc "tree-sitter CLI" TREE_SITTER_VERSION
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  echo "seed: installing tree-sitter $TREE_SITTER_VERSION"
  as_user mv "$TS_BIN.new" "$TS_BIN"
fi
TPLEOF
  mkdir -p "$WS/broken/.devcontainer"
  cat >"$WS/broken/.devcontainer/local-seed.sh" <<'BROKENEOF'
#!/usr/bin/env bash

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  echo "unterminated"
BROKENEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

if [ -n "${TREE_SITTER_VERSION:-}" ]; then
  echo "seed: installing tree-sitter $TREE_SITTER_VERSION"
fi
SEEDEOF
  run "$REPO_ROOT/bin/seed-drift" --template "$TPL" --doc "$DOC"
  [ "$status" -eq 2 ]
  [[ "$output" == *broken* ]]
  [[ "$output" == *demo* ]]
  [[ "$output" == *BEHIND* ]]
}
```

- [ ] **Step 16: run the whole suite file.**

`bats tests/seed_drift.bats`

Expected: 0 failures, and the 25 tests added in this task all report `ok` alongside everything from Tasks 1-6.

- [ ] **Step 17: real-world smoke against the five live seeds — read-only.**

Run from the repo root, capturing checksums so the read-only guarantee is confirmed on the real files as well as on fixtures:

```
before=$(sha256sum ~/workspace/*/.devcontainer/local-seed.sh)
bin/seed-drift; echo "exit=$?"
after=$(sha256sum ~/workspace/*/.devcontainer/local-seed.sh)
[ "$before" = "$after" ] && echo "READ-ONLY OK"
```

Expected: `exit=1`; a `BEHIND` line for the `tree-sitter CLI` block under each of `wanderer`, `wanderer-kills`, `wanderer-notifier`, `double-holo-ui`, and `slabledger` (the five seeds present at `~/workspace/*/.devcontainer/local-seed.sh`); a summary line reading `5 checked, 0 skipped` with at least 5 blocks drifted; and `READ-ONLY OK`. If any of the five reports `ok` on tree-sitter, the detector has reproduced the original false-clean bug and must not be committed.

- [ ] **Step 18: full verification.**

`command make check` from the repo root (`make` is shadowed by a zsh function here, so `command make` is required). This runs `syntax`, `lint`, `test`, `python-test`, `validate`.

Expected: `bin/list-check-files bash|shellcheck|shfmt` all include `bin/seed-drift` with no findings and no shfmt diff; `bats tests` reports the 323 baseline tests plus every test from Tasks 1-6 and the 25 from this task, 0 failures; `python-test` and `validate` unchanged.

- [ ] **Step 19: commit.**

```
git add tests/seed_drift.bats
git commit -m "test: pin seed-drift normalization, heredoc, and read-only behavior"
```

If Step 16 or 17 required a fix to `bin/seed-drift`, stage it in the same commit and use `fix(seed-drift):` instead. Confirm `git status` is clean afterwards.
