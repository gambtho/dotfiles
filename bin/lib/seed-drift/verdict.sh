#!/usr/bin/env bash
# seed-drift: verdict logic — ordered diffs between normalized template and
# seed blocks, and the mapping from behind/ahead counts to a verdict.
# Sourced by bin/seed-drift; never executed.

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
    printf 'DIVERGED\n'
  fi
}

# TEST-ONLY. Nothing in the production path calls this: sd_check_seed runs the
# same four steps inline, because capturing this function's output with
# `verdict=$(sd_verdict ...)` would swallow a diff failure's non-zero status
# and, under `set -e`, abort the whole run outside the public 0/1/2 contract
# (see the comment above that call site). Do NOT "remove the duplication" by
# wiring this in — the duplication is the fix, not the defect. It survives
# because the tests exercise the composition of sd_diff_lines, sd_count_lines,
# and sd_verdict_from_counts in one place; keep it in sync with sd_check_seed
# if either changes.
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
