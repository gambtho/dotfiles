#!/usr/bin/env bash
# seed-drift: template/doc parsing and block extraction — the scan awk that
# strips comments and tracks heredocs, anchor lookup, the parse-bounded
# extraction window, and the shared temp-file helper. Sourced by
# bin/seed-drift; never executed.

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

SD_SCAN_AWK=$(
  cat <<'SDAWK'
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
      push(substr(line, i + 1, j - 1), 1, d)
      i = i + j + 1
      continue
    }
    if (c == "\\") {
      w = delimword(line, i + 1, n)
      if (w == "") fail("unrecognized heredoc delimiter after <<")
      push(w, 1, d)
      i = wend
      continue
    }
    w = delimword(line, i, n)
    if (w == "") fail("unrecognized heredoc delimiter after <<")
    push(w, 0, d)
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
END {
  if (failed) exit 3
  if (hd) {
    printf("seed-drift: unterminated heredoc %s\n", hdelim) >"/dev/stderr"
    exit 3
  }
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

# Bounds the ERROR path, not the success path. A window that parses exits on
# its first successful parse, and on the real corpus every window but one
# parses at the very first pair the search tries — so this cap costs a passing
# anchor nothing. It is only ever reached by an anchor whose block never
# parses at all, where the search is O(paragraphs^2) `bash -n` invocations
# rather than O(paragraphs).
#
# 2000 is deliberate headroom, not a measurement. The worst plausible real
# shape was measured at ~280 attempts (the largest real window is 109 lines
# inside a 961-line template), so this sits roughly 7x above it. The margin is
# that wide on purpose, for two reasons:
#
#   1. The failure mode is asymmetric. Exceeding the cap turns a legitimate
#      block into a hard exit-2 ERROR — a false alarm on good input. Going
#      over costs only ~2000 `bash -n` invocations on a block that was going
#      to fail anyway.
#   2. The sweep below is NOT strictly smallest-window-first: the inner loop
#      always runs `hi` to `last`, so (para, last) is tried before
#      (para-1, para), and a backward-only case burns a full forward sweep per
#      step. The attempt count therefore does not track window size, which is
#      why the margin is set this wide rather than at a tight multiple of the
#      ~280 measurement.
#
# Do not "tune" this down to hug the measurement. The ordering it compensates
# for is deliberate — it was verified against the real corpus by exhaustive
# old-vs-new window comparison, and reordering the search would change which
# window an ambiguous anchor resolves to.
SD_MAX_PARSE_ATTEMPTS=2000

# Grows the window until the extracted fragment parses. The search is
# two-dimensional — every (lo, hi) paragraph pair, `lo` walking down from the
# anchor's paragraph and `hi` up from it — because the common real case is an
# anchor inside a multi-paragraph function body, which needs the window grown
# BACK to `funcname() {` and FORWARD to the closing `}` at the same time.
#
# A one-dimensional walk cannot express that pair. Worse, the previous
# forward-to-EOF-then-backward form left `end` pinned at EOF once forward
# growth exhausted, so ANY block needing backward growth extracted
# `[lo's start .. EOF]` and was diffed as if the whole tail of the file
# belonged to it — reporting other blocks' drift under this block's name.
#
# (para, para) is tried first, so a paragraph that already parses standalone
# costs exactly one `bash -n`, exactly as before. The fragment is read
# straight from FILE by line number, because the scan text is comment-stripped
# and would not parse the same way.
sd_window() {
  local file="$1" scan="$2" para="$3"
  local first last lo hi start end range tries=0

  first=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$scan")
  last=$(awk -F'\t' 'END { print $1 }' "$scan")
  range=$(sd_para_range "$scan" "$para")
  [ -n "$range" ] || return 3

  lo="$para"
  while [ "$lo" -ge "$first" ]; do
    range=$(sd_para_range "$scan" "$lo")
    start="${range% *}"
    hi="$para"
    while [ "$hi" -le "$last" ]; do
      range=$(sd_para_range "$scan" "$hi")
      end="${range#* }"
      tries=$((tries + 1))
      # Same status the exhaustion path below returns: sd_extract and
      # sd_check_seed already route 3 to "block could not be extracted".
      [ "$tries" -le "$SD_MAX_PARSE_ATTEMPTS" ] || return 3
      if sed -n "${start},${end}p" "$file" | bash -n 2>/dev/null; then
        printf '%s %s\n' "$start" "$end"
        return 0
      fi
      hi=$((hi + 1))
    done
    lo=$((lo - 1))
  done
  return 3
}

sd_extract() {
  local file="$1" scan="$2" anchor="$3" paras para window ranges="" keep

  paras=$(sd_paras_with_anchor "$scan" "$anchor")
  [ -n "$paras" ] || return 4

  for para in $paras; do
    window=$(sd_window "$file" "$scan" "$para") || return 3
    ranges+="$window"$'\n'
  done

  # Union the windows by source line number: `sort -n -u` puts them in file
  # order and collapses lines two overlapping windows both claim.
  keep=$(printf '%s' "$ranges" | awk '{ for (i = $1; i <= $2; i++) print i }' | sort -n -u)

  # SD_LAST_WINDOW_SIZE is deliberately a global, not local: both call sites in
  # sd_check_seed invoke sd_extract with a plain redirect (`sd_extract ... >"$f"`),
  # not a command substitution, so sd_extract runs in the caller's own shell and
  # this assignment survives the call — it does not need `printf -v` or a
  # separate accessor. It is the raw (pre-normalization) line count of the
  # unioned window, matching END-START+1 in the common single-paragraph case and
  # generalizing correctly when an anchor matches more than one paragraph.
  # shellcheck disable=SC2034  # read by lib/seed-drift/report.sh
  SD_LAST_WINDOW_SIZE=$(printf '%s\n' "$keep" | awk 'END { print NR }')

  printf '%s\n' "$keep" |
    awk -F'\t' 'NR == FNR { keep[$1] = 1; next } keep[$2]' - "$scan" |
    sd_normalize
}

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
#
# The EXIT trap REPLACES any the caller already had. That is an accepted side
# effect of sourcing, not an oversight: chaining would mean parsing `trap -p`
# output and re-evaluating the recovered handler string, which is a quoting and
# injection hazard well out of proportion to the exposure. Sourcing this script
# already sets `e`, `u`, and pipefail in the caller unconditionally, so a caller
# that sources it is already accepting that its shell state is not preserved.
sd_tmp() {
  local __sd_new
  if [ -z "$SD_TMPDIR" ]; then
    SD_TMPDIR="$(mktemp -d)" || return 3
    trap 'rm -rf -- "$SD_TMPDIR"' EXIT HUP INT TERM
  fi
  __sd_new="$(mktemp "$SD_TMPDIR/sd.XXXXXX")" || return 3
  printf -v "$1" '%s' "$__sd_new"
}
