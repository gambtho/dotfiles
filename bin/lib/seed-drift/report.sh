#!/usr/bin/env bash
# seed-drift: per-seed checking, reporting, and candidate traversal — the run
# state and counters, block/sample/action reporting, thin-window handling,
# templated-variable problems, and the workspace walk. Sourced by
# bin/seed-drift; never executed.

# Below this many raw (pre-normalization) lines, a window has proven too
# little to trust a verdict on. Calibrated against the real five-seed corpus
# (Task 8 brief): the smallest window measured there is 9 lines, so 5 leaves
# headroom against ordinary variation while still catching a genuinely
# degenerate window. Do not raise this without re-measuring the corpus.
SD_THIN_WINDOW=5

SD_TEMPLATE="" SD_DOC="" SD_TEMPLATE_SCAN=""
# Pre-declared for the same reason as SD_TEMPLATE_SCAN above: only sd_main
# assigns these, but sd_visit_candidates reads the count, and a sourced caller
# reaching that function without going through sd_main would abort on `unbound
# variable` under `set -u`. The empty array is safe to declare on bash 3.2 —
# only expanding it is not, and the count guard already covers that.
SD_CANDIDATES=()
SD_CANDIDATE_COUNT=0
SD_CHECKED=0 SD_SKIPPED=0
SD_BEHIND=0 SD_AHEAD=0 SD_DIVERGED=0 SD_MISSING=0
SD_WORST=0

sd_worst() {
  # `if`, not `[ … ] && …`: the bare-`&&` form leaves the function's status at
  # 1 on every not-worse call, so it is correct only while a `return 0` stays
  # the immediately-following statement. All three call sites invoke this as a
  # bare statement under `set -e`, so a later insert between the two lines
  # would abort the run on every clean project. An `if` with no else exits 0
  # whether or not the branch is taken, which removes the dependency.
  if [ "$1" -gt "$SD_WORST" ]; then
    SD_WORST="$1"
  fi
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

# Informational only: a thin window proves little either way and must never
# affect the verdict or the exit code. $1 names the side ("template" or
# "seed"); $2 is the raw window size in lines.
sd_report_thin() {
  printf '             note: %s window is only %d lines (< %d) - check covers little\n' \
    "$1" "$2" "$SD_THIN_WINDOW"
}

# Names every per-project templated variable this seed gets WRONG, as
# `VAR<TAB>KIND` with KIND one of `undefined` or `derived`. Both are whole-file
# questions on purpose: block comparison cannot answer either one, and must not
# be relied on to.
#
#   undefined - the seed reads the variable but never declares it. This is the
#               compensating guard for the drop rule: once those declarations
#               are excluded from comparison, "hoisted into the variable block"
#               and "never defined at all" look identical to the diff. The
#               second is the failure mode catch-up-local-seed.md calls the main
#               way the task goes wrong - under `set -euo pipefail` the first
#               expansion aborts the whole seed and surfaces as an
#               unrelated-looking container start error.
#   derived   - the declaration exists but is computed. The doc forbids this for
#               WORKSPACE: the seed is mounted at an arbitrary container path
#               that need not sit inside the checkout, so `git rev-parse` from
#               there resolves to the wrong tree. Checked here rather than left
#               to a block verdict because a derived declaration hoisted into
#               the variable block never lands in a compared window at all - the
#               same placement blindness the drop rule was written to remove.
#
# Reads the scan, not the file: `C` records have already had trailing comments
# stripped, so a `$WORKSPACE` mentioned only in a comment is not a reference.
sd_templated_var_problems() {
  local scan="$1" var tag text cls assigned derived
  for var in WORKSPACE SEED_USER; do
    assigned=0
    derived=0
    # The declaration side goes through the shared grammar, in bash, so the
    # answer here cannot disagree with what sd_normalize_code_line dropped.
    while IFS=$'\t' read -r _ _ tag text; do
      [ "$tag" = C ] || continue
      cls=0
      sd_classify_templated_assignment "$text" "$var" || cls=$?
      case "$cls" in
        0) assigned=1 ;;
        2) assigned=1 derived=1 ;;
      esac
    done <"$scan"
    if [ "$derived" = 1 ]; then
      printf '%s\tderived\n' "$var"
    elif [ "$assigned" = 0 ] &&
      # The read side stays in awk, which is where the regex work belongs.
      # A braced expansion counts as a read unless its operator TOLERATES an
      # unset parameter - `:-` `:=` `:+` and their colonless forms substitute a
      # default and survive `set -u`. Everything else (`${v}`, `${v%...}`,
      # `${v#...}`, `${v/...}`, `${v:?...}`, `${v:0:3}`, `${#v}`) aborts, so it
      # is a read. The trailing word-character exclusions keep `${WORKSPACE_X}`
      # and `$WORKSPACE_X` from counting as uses of WORKSPACE.
      #
      # The text is reconstructed from $0 rather than read out of $4: a scan
      # record is para/lineno/tag/text, and a seed line containing its own tab
      # (an indented one, most of them) splits that text across $4, $5, ... so
      # matching $4 alone silently misses the reference and lets an undefined
      # variable through.
      awk -F'\t' -v v="$var" '
        $3 != "C" { next }
        {
          t = $0
          if (sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t) == 0) next
        }
        t ~ ("\\$" v "([^A-Za-z0-9_]|$)") { used = 1 }
        t ~ ("\\$\\{" v "\\}") { used = 1 }
        t ~ ("\\$\\{" v ":[^-=+]") { used = 1 }
        t ~ ("\\$\\{" v "[^:=+}A-Za-z0-9_-]") { used = 1 }
        t ~ ("\\$\\{#" v "[^A-Za-z0-9_]") { used = 1 }
        END { exit used ? 0 : 1 }
      ' "$scan"; then
      printf '%s\tundefined\n' "$var"
    fi
  done
  return 0
}

sd_check_seed() {
  local seed="$1" name rc=0 block anchor verdict tnorm snorm sscan
  local behind ahead nb na est tst tsize esize docrows problems pvar pkind
  name=$(basename -- "$(dirname -- "$(dirname -- "$seed")")")
  printf '%s  %s\n' "$name" "$seed"
  if ! bash -n "$seed" 2>/dev/null; then
    sd_report_block ERROR "$name" 'does not parse (bash -n)'
    return 2
  fi
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
  # rc, not `return 2`: the block verdicts are still worth printing, and this
  # is a whole-file finding that none of them depends on.
  problems=$(sd_templated_var_problems "$sscan")
  if [ -n "$problems" ]; then
    while IFS=$'\t' read -r pvar pkind; do
      [ -n "$pvar" ] || continue
      case "$pkind" in
        undefined)
          sd_report_block ERROR '(whole file)' "seed reads \$$pvar but never assigns it"
          sd_report_action 'define it in the seed variable block; see catch-up-local-seed.md'
          ;;
        derived)
          sd_report_block ERROR '(whole file)' "seed derives $pvar instead of assigning a literal"
          sd_report_action 'the container path need not sit inside the checkout; use a literal'
          ;;
      esac
    done <<<"$problems"
    rc=2
  fi
  sd_tmp tnorm || return 2
  sd_tmp snorm || return 2
  # Allocated once per seed, not once per block: the diff output is consumed
  # before the next iteration overwrites it, so N blocks do not need 2N
  # files. Same reuse as tnorm/snorm/sscan above.
  sd_tmp behind || return 2
  sd_tmp ahead || return 2
  # Parsed to a file, not piped into the loop through `< <(sd_parse_doc …)`: a
  # process substitution discards its command's exit status, which is invisible
  # to both `set -e` and pipefail. Were the doc to become unreadable — or awk to
  # die partway through it — between sd_main's parse and this one, the loop would
  # run over however many rows had already been emitted and report the seed on a
  # truncated block list, or report it clean having compared nothing. Capturing
  # the status separately from the rows is what sd_main already does with
  # `if ! blocks=$(sd_parse_doc "$doc")`; this is the same check on the same
  # input, at the point where the rows are actually consumed.
  sd_tmp docrows || return 2
  if ! sd_parse_doc "$SD_DOC" >"$docrows"; then
    sd_report_block ERROR '(whole file)' 'the doc table could not be parsed'
    sd_report_action 'check the Step 1 table in catch-up-local-seed.md'
    return 2
  fi
  # A successful parse emitting nothing is a separate case: sd_parse_doc's awk
  # already exits non-zero on zero rows, so this counter guards a shape that
  # cannot arise today. It stays because "compared nothing" must never read as
  # "clean" — same invariant, same reasoning as the empty-template guard below.
  local rows=0
  while IFS=$'\t' read -r block anchor; do
    rows=$((rows + 1))
    # Branch on the ORIGINAL status. sd_extract returns 4 for "anchor absent"
    # and 3 for "the block would not parse"; `if ! sd_extract` flattens both
    # into one branch, so a seed whose block is unextractable would be
    # reported as MISSING and exit 1 — a wrong verdict at the wrong severity.
    tst=0
    sd_extract "$SD_TEMPLATE" "$SD_TEMPLATE_SCAN" "$anchor" >"$tnorm" || tst=$?
    case "$tst" in
      0) tsize="$SD_LAST_WINDOW_SIZE" ;;
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
    # An empty template side must never reach the comparison:
    # sd_verdict_from_counts 0 0 is `ok`, so it would report a clean block
    # having compared nothing at all. sd_main's anchor validation makes this
    # unreachable today — the anchor must appear in a `C` record — but that
    # guarantee lives two functions away, and this is the invariant that
    # matters here, so it is enforced where it is relied on.
    if [ ! -s "$tnorm" ]; then
      sd_report_block ERROR "$block" 'template block extracted to nothing'
      rc=2
      continue
    fi
    est=0
    sd_extract "$seed" "$sscan" "$anchor" >"$snorm" || est=$?
    case "$est" in
      0) esize="$SD_LAST_WINDOW_SIZE" ;;
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
    # Informational only, fires regardless of verdict (including ok) and never
    # touches rc or the drift tallies above — a thin window means the check
    # covered too little to trust, not that the block itself is wrong.
    #
    # `if`, not `[ … ] && …`: the bare-`&&` form leaves the loop body's status
    # at 1 whenever the window is thick, so it is safe only while the explicit
    # `return "$rc"` below stays the very next statement. Appending a line
    # after it would make a clean seed return 1 — inventing drift inside the
    # public 0/1/2 contract.
    if [ "$tsize" -lt "$SD_THIN_WINDOW" ]; then
      sd_report_thin template "$tsize"
    fi
    if [ "$esize" -lt "$SD_THIN_WINDOW" ]; then
      sd_report_thin seed "$esize"
    fi
  done <"$docrows"
  if [ "$rows" -eq 0 ]; then
    sd_report_block ERROR '(whole file)' 'no blocks read from the doc table'
    sd_report_action 'check the Step 1 table in catch-up-local-seed.md'
    return 2
  fi
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
  local root="${SEED_DRIFT_ROOT:-$HOME/workspace}" cand rc=0 visited=0
  # The scalar, not `${#SD_CANDIDATES[@]}`: expanding an empty array under
  # `set -u` errors on bash 3.2, still the system bash on macOS
  # (bin/common.sh:392). The `"${SD_CANDIDATES[@]}"` below is reached only
  # when the count is non-zero, so it is safe.
  if [ "$SD_CANDIDATE_COUNT" -eq 0 ]; then
    # Saved and restored around discovery only. The script is designed to be
    # sourced (SEED_DRIFT_SOURCE_ONLY=1 — the whole test suite depends on it),
    # so setting nullglob and walking away would silently change globbing in
    # the caller's shell. The restore sits after the loop, ahead of both
    # returns below, so no exit path from here leaks it.
    #
    # Not a trap. A `set -e` abort from inside the loop would still leak, and
    # an ERR trap would not catch it without `set -E` — a larger change than
    # this justifies. More to the point, sourcing this script already sets
    # `e`, `u`, and pipefail in the caller unconditionally, on the success
    # path, so an abort-only nullglob edge is not the marginal exposure here.
    local had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for cand in "$root"/*/; do
      cand="${cand%/}"
      # A directory without .devcontainer/ is not a candidate: silent, not skipped.
      [ -d "$cand/.devcontainer" ] || continue
      sd_visit_dir "$cand"
      visited=$((visited + 1))
    done
    if [ "$had_nullglob" -eq 0 ]; then
      shopt -u nullglob
    fi
    if [ "$visited" -eq 0 ]; then
      # Scoped to discovery only: an explicitly-named absent project is
      # still a skip at exit 0 (the brief states this outright). But
      # discovery finding zero projects means the detector could not do its
      # job at all — 0 checked here is a broken gate, not a clean bill of
      # health, so this fails closed rather than reporting a quiet "clean".
      printf 'seed-drift: no projects found under %s\n' "$root" >&2
      return 2
    fi
    return 0
  fi
  for cand in "${SD_CANDIDATES[@]}"; do
    if [ -d "$cand" ]; then
      if [ ! -d "$cand/.devcontainer" ]; then
        # An explicitly-named project is a promise, not a glob match: a
        # renamed or removed .devcontainer/ must be visible in the count, not
        # silently absorbed the way an unrelated discovery-mode directory is.
        printf '%s  no .devcontainer/ - skipped\n' "$(basename -- "$cand")"
        SD_SKIPPED=$((SD_SKIPPED + 1))
        continue
      fi
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
