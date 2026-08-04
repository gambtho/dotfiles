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

write_fixture_doc() {
  cat >"$1" <<'DOC'
| Block | Anchor in template | Why it matters |
|---|---|---|
| Overlay-link gitignore | `lname '*dotfiles/projects/*'` | Adds overlay links. |
| `core.excludesFile` | `core.excludesFile` | Points git at the seeded ignore file. |
DOC
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

@test "every anchor in the real doc table is present in the real template" {
  # Discovery finding zero projects is now a hard error (fix round 2, I-3);
  # give it one skip-only candidate so this test still exercises only what
  # it is meant to check: real-doc/real-template anchor agreement, exit 0.
  export SEED_DRIFT_ROOT="$TEST_ROOT/workspace"
  mkdir -p "$SEED_DRIFT_ROOT/placeholder/.devcontainer"

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
  [[ "$output" == *"lname '*dotfiles/projects/*'"* ]]
}

@test "a doc with no parseable block table is a hard error" {
  local doc="$TEST_ROOT/doc.md" template="$TEST_ROOT/tpl.sh"
  printf 'Just some prose, no table here.\n' >"$doc"
  printf '#!/usr/bin/env bash\ntrue\n' >"$template"

  run "$SEED_DRIFT" --template "$template" --doc "$doc"

  [ "$status" -eq 2 ]
  [[ "$output" == *"no block table found in $doc"* ]]
}

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

@test "sd_scan fails closed on an unterminated heredoc" {
  local f="$TEST_ROOT/unterminated.sh"
  printf "cat <<'E'\nbody\n" >"$f"

  sd_source sd_scan "$f"

  [ "$status" -eq 3 ]
  [[ "$output" == *"unterminated heredoc E"* ]]
}

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

@test "bash -n rejects a lone if header and accepts it split by a blank line" {
  printf 'if [ -n "$x" ]; then\n' >"$FIX/lone.sh"
  printf 'if [ -n "$x" ]; then\n\n  echo hi\nfi\n' >"$FIX/split.sh"
  run bash -n "$FIX/lone.sh"
  [ "$status" -eq 2 ]
  run bash -n "$FIX/split.sh"
  [ "$status" -eq 0 ]
}

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

@test "sd_window stops at the enclosing statement when growing backward, not at EOF" {
  # The test above cannot detect the bug this one is for: its anchor sits in
  # the file's LAST paragraph, so the window end is already EOF and a correct
  # implementation and one that never rolls the end back agree. Here there is
  # a trailing paragraph after the enclosing `fi`, so the two disagree — the
  # old forward-to-EOF-then-backward walk returned "1 6", swallowing
  # UNRELATED=2 into a block that has nothing to do with it.
  printf 'if [ -n "$x" ]; then\n\n  echo ANCHOR\nfi\n\nUNRELATED=2\n' >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 2
  [ "$status" -eq 0 ]
  [ "$output" = "1 4" ]
}

@test "sd_window grows in both directions at once for an anchor inside a function body" {
  # The common real shape: the anchor's paragraph needs the window grown BACK
  # to `setup() {` and FORWARD to its closing `}` simultaneously. No
  # one-dimensional walk can reach this pair; only the (lo, hi) search can.
  printf 'setup() {\n  local a=1\n\n  if [ -n "$x" ]; then\n    echo ANCHOR\n\n    echo more\n  fi\n}\n\nUNRELATED=2\n' \
    >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 2
  [ "$status" -eq 0 ]
  [ "$output" = "1 9" ]
}

# sd_cap_fixture BEFORE AFTER — a file whose anchor paragraph is extractable
# only at the very last (lo, hi) pair the search tries.
#
# The anchor's paragraph carries the closing `fi` of an `if` opened in
# paragraph 1, so no pair starting below paragraph 1 can ever parse: the
# stray `fi` is unmatched in every one of them. The search therefore walks
# every `hi` for every `lo` down to 1 before it succeeds, which is
# (BEFORE + 1) * (AFTER + 1) + 1 parse attempts — the knob these two tests
# turn to sit either side of SD_MAX_PARSE_ATTEMPTS.
sd_cap_fixture() {
  local n
  {
    printf 'if true; then\n\n'
    for n in $(seq "$1"); do printf '  echo p%s\n\n' "$n"; done
    printf '  ANCHOR=1\nfi\n\n'
    for n in $(seq "$2"); do printf '  echo q%s\n\n' "$n"; done
  } >"$FIX/f.sh"
  make_scan "$FIX/f.sh"
}

@test "sd_window finds a far window while the search stays under the parse-attempt cap" {
  # 9 * 9 + 1 = 82 attempts, well under the cap: the window is found.
  sd_cap_fixture 8 8
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 10
  [ "$status" -eq 0 ]
  [ "$output" = "1 20" ]
}

@test "sd_window gives up with status 3 once the parse-attempt cap is reached" {
  # Identical shape, only bigger: 21 * 21 + 1 = 442 attempts, so the winning
  # pair sits past SD_MAX_PARSE_ATTEMPTS=400 and is never reached. The cap —
  # not exhaustion — is what ends this search, and it reports the same
  # status 3 the exhaustion path already uses, so it needs no new handling in
  # sd_extract or sd_check_seed.
  sd_cap_fixture 20 20
  sd_source sd_window "$FIX/f.sh" "$FIX/f.sh.scan" 22
  [ "$status" -eq 3 ]
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

@test "sd_verdict reports BEHIND when the only difference is a removed blank line" {
  printf 'export A=1\n\nexport B=2\n' >"$TEST_ROOT/tpl"
  printf 'export A=1\nexport B=2\n' >"$TEST_ROOT/seed"
  sd_source sd_verdict "$TEST_ROOT/tpl" "$TEST_ROOT/seed"
  [ "$status" -eq 0 ]
  [ "$output" = "BEHIND" ]
}

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
seed_from_template() {
  make_project "$1"
  write_drift_template "$(seed_path "$1")"
}
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

# Fix round 1 (Task 7 review, M-3): a t7_-style duplicate of this test ("a
# malformed seed does not suppress drift reporting for the others") was
# folded in here rather than kept alongside it — same intent, weaker
# assertions (no "does not parse" text, no exact summary count).
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
  # A hypothetical auto-fixer has nothing to write against a zero-drift seed,
  # so that fixture cannot tell a read-only tool from a broken one. Checksum a
  # DRIFTED seed instead, across a run that exits 1 — plus the template and
  # doc, since either could tempt a "helpfully" self-updating implementation —
  # and require both content and mtime to be untouched. Seeds are gitignored
  # and hand-owned with no revert path, so this is the guarantee that matters.
  setup_drift_fixtures
  seed_from_template behindp
  sed -i '/tree-sitter ready/d' "$(seed_path behindp)"
  local seed_before seed_after doc_before doc_after tpl_before tpl_after
  local seed_mtime_before seed_mtime_after doc_mtime_before doc_mtime_after
  local tpl_mtime_before tpl_mtime_after
  seed_before=$(sha256sum <"$(seed_path behindp)")
  tpl_before=$(sha256sum <"$FIXTURE_TEMPLATE")
  doc_before=$(sha256sum <"$FIXTURE_DOC")
  seed_mtime_before=$(stat -c %Y "$(seed_path behindp)")
  tpl_mtime_before=$(stat -c %Y "$FIXTURE_TEMPLATE")
  doc_mtime_before=$(stat -c %Y "$FIXTURE_DOC")

  sd_drift

  [ "$status" -eq 1 ]
  seed_after=$(sha256sum <"$(seed_path behindp)")
  tpl_after=$(sha256sum <"$FIXTURE_TEMPLATE")
  doc_after=$(sha256sum <"$FIXTURE_DOC")
  seed_mtime_after=$(stat -c %Y "$(seed_path behindp)")
  tpl_mtime_after=$(stat -c %Y "$FIXTURE_TEMPLATE")
  doc_mtime_after=$(stat -c %Y "$FIXTURE_DOC")
  [ "$seed_before" = "$seed_after" ]
  [ "$tpl_before" = "$tpl_after" ]
  [ "$doc_before" = "$doc_after" ]
  [ "$seed_mtime_before" = "$seed_mtime_after" ]
  [ "$tpl_mtime_before" = "$tpl_mtime_after" ]
  [ "$doc_mtime_before" = "$doc_mtime_after" ]
}

@test "sd_check_seed can be called directly without sd_main having run" {
  setup_drift_fixtures
  seed_from_template clean

  # Mirrors the review's exact repro: source the script (never call sd_main,
  # so SD_TEMPLATE_SCAN is never built by anything), then set only SD_TEMPLATE
  # and SD_DOC before calling sd_check_seed directly. A bare `source` must
  # leave every global sd_check_seed touches in a defined, empty state under
  # `set -u` — if SD_TEMPLATE_SCAN is left undeclared, this dies with
  # "unbound variable" (exit 1) before it ever reaches the anchor check,
  # which misreports a shell crash as "drift" under the public 0/1/2
  # contract. With SD_TEMPLATE_SCAN declared empty, an unscanned template
  # correctly reports an extraction ERROR (exit 2) instead of crashing.
  run env SEED_DRIFT_SOURCE_ONLY=1 bash -c '
    source "$1"
    SD_TEMPLATE="$2"
    SD_DOC="$3"
    sd_check_seed "$4"
  ' _ "$SEED_DRIFT" "$FIXTURE_TEMPLATE" "$FIXTURE_DOC" "$(seed_path clean)"

  [ "$status" -eq 2 ]
  [[ "$output" != *"unbound variable"* ]]
}

@test "an explicit candidate directory with no .devcontainer is named and skipped, exit 0" {
  setup_drift_fixtures
  mkdir -p "$SEED_DRIFT_ROOT/nodev"

  sd_drift "$SEED_DRIFT_ROOT/nodev"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nodev"*"no .devcontainer/ - skipped"* ]]
  [[ "$output" == *"0 checked, 1 skipped, 0 blocks drifted"* ]]
}

@test "discovery that finds nothing is an error, exit 2" {
  setup_drift_fixtures

  sd_drift

  [ "$status" -eq 2 ]
  [[ "$output" == *"no projects found under $SEED_DRIFT_ROOT"* ]]
  [[ "$output" == *"0 checked, 0 skipped, 0 blocks drifted"* ]]
}

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

# t7_run_tool TOOL [CANDIDATE...] — run an explicit seed-drift executable
# against the current fixture template and doc. t7_run is the ordinary form,
# running the repository's own copy; the sabotage probes pass a private copy.
t7_run_tool() {
  local tool="$1"
  shift
  run "$tool" --template "$TPL" --doc "$DOC" "$@"
}

t7_run() {
  t7_run_tool "$REPO_ROOT/bin/seed-drift" "$@"
}

# Takes a private copy of bin/seed-drift in the test's own temp dir and sets
# T7_TOOL to it, along with T7_TOOL_PRISTINE, a byte snapshot of the repository
# file as it stood before the test ran.
#
# Sabotage probes must edit the COPY, never $REPO_ROOT/bin/seed-drift. Editing
# the repository file in place has three failure modes, all of which this
# removes at once: bats aborts a test at the first failing assertion, so a
# failure between sabotage and restore leaves the real tool broken; restoring
# with `git checkout --` restores to HEAD and so destroys any uncommitted work
# a developer has in the file under test (this already bit an earlier round of
# this project); and restoring with `cp` is worse still, because `cp` in this
# environment is interactive and silently declines. Working on a copy also
# makes the suite parallel-safe.
t7_copy_tool() {
  T7_TOOL="$BATS_TEST_TMPDIR/seed-drift"
  T7_TOOL_PRISTINE="$BATS_TEST_TMPDIR/seed-drift.pristine"
  cp "$REPO_ROOT/bin/seed-drift" "$T7_TOOL"
  cp "$REPO_ROOT/bin/seed-drift" "$T7_TOOL_PRISTINE"
  # Verify rather than trust: see the `cp` note above. Both copies land on
  # fresh paths, where cp does not prompt, but the whole point of this helper
  # is that a silently-skipped copy must not become a green test.
  cmp -s "$REPO_ROOT/bin/seed-drift" "$T7_TOOL"
  cmp -s "$REPO_ROOT/bin/seed-drift" "$T7_TOOL_PRISTINE"
  chmod +x "$T7_TOOL"
}

# The property the copy-based sabotage buys us, asserted directly: the suite
# never writes the repository's own bin/seed-drift. Compared against the
# snapshot taken by t7_copy_tool rather than against HEAD, so the assertion
# still holds — and still means exactly this — while a developer has
# uncommitted edits in the file.
t7_assert_repo_tool_untouched() {
  cmp -s "$T7_TOOL_PRISTINE" "$REPO_ROOT/bin/seed-drift"
  [ ! -e "$REPO_ROOT/bin/seed-drift.orig" ]
}

@test "a tab inside a heredoc payload survives extraction verbatim" {
  t7_setup
  t7_doc "core.excludesFile" core.excludesFile
  # No blank line between the heredoc closer and the git-config line: that gap
  # is load-bearing (team-lead ruling, fix round 3). With it present, the
  # anchor's own paragraph (just the git-config line) already parses standalone
  # via `bash -n`, so sd_window never grows to include the heredoc paragraph
  # and the payload — the very thing this test is named for — is never
  # extracted at all. This mirrors the real template, where the closing `fi`
  # of the `if ! as_user test -f "$GITIGNORE"` guard and the trailing
  # `as_user git config --global core.excludesFile "$GITIGNORE"` sit in one
  # paragraph with no blank line, so don't "tidy" this back in.
  printf '#!/usr/bin/env bash\n\ntee "$G" <<%s\n\tcol1\tcol2\nGITEOF\ngit config --global core.excludesFile "$G"\n' "'GITEOF'" >"$TPL"
  # Seed differs ONLY by collapsing the payload tabs to spaces.
  printf '#!/usr/bin/env bash\n\ntee "$G" <<%s\n  col1  col2\nGITEOF\ngit config --global core.excludesFile "$G"\n' "'GITEOF'" >"$SEED"

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
  # privilege word and report as drift on a Mac and clean on Linux. Fix
  # round 1 (Task 7 review, M-4): scoped to sd_drop_priv_prefix's own body —
  # the only function that runs `sed -E` — rather than the whole file, so
  # unrelated prose elsewhere (this comment included) is free to name the
  # token without tripping the check.
  run bash -c "sed -n '/^sd_drop_priv_prefix()/,/^}/p' '$SEED_DRIFT' | grep -n '\\\\b'"
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
  # The anchor is kept verbatim so this test exercises only the heredoc-opener
  # question (does the literal `<<` inside GI_MARK_END's double-quoted string
  # get mistaken for a heredoc start, corrupting the scan?). The drift lives
  # in the unrelated echo line instead — a seed whose anchor genuinely drifted
  # to the old-narrow glob is a different, documented case; see the dedicated
  # "old-narrow overlay glob" test below.
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# << overlay symlinks (auto) <<"
overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*dotfiles/projects/*' -print)"
echo "$overlay_links" >&2
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overlay-link gitignore"* ]]
  [[ "$output" != *MISSING* ]]
}

# The doc's own prose for this row (catch-up-local-seed.md:77) says: "If the
# seed has the old narrow '*/.dotfiles/projects/*', it must be widened." The
# anchor is deliberately the WIDENED (desired) glob, so a seed still on the
# old-narrow form genuinely lacks that literal substring — MISSING is the
# correct, honest, actionable verdict here (not a defect): exit 1, block
# named, and the action points at the doc's own remedy step. Anchor text must
# be chosen from the stable part of a block; if the anchor string itself is
# what's drifting, the verdict is MISSING rather than DIVERGED.
@test "a seed on the documented old-narrow overlay glob is reported MISSING, not ok" {
  t7_setup
  t7_doc "Overlay-link gitignore" "lname '*dotfiles/projects/*'"
  cat >"$TPL" <<'TPLEOF'
#!/usr/bin/env bash

overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*dotfiles/projects/*' -print)"
echo "$overlay_links"
TPLEOF
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*/.dotfiles/projects/*' -print)"
echo "$overlay_links"
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *MISSING* ]]
  [[ "$output" == *"Overlay-link gitignore"* ]]
  [[ "$output" == *"Step 2"* ]]
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

@test "ownership idiom with only the find-half identity changed is drift, not dropped" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  # The chown half is byte-identical to the template on both sides here, so
  # it cancels in the diff; only the find-half (`! -uid`) differs. There is
  # no ownership-specific rule left to fool, but this still stresses that a
  # single changed line inside a two-line idiom instance is reported as
  # ordinary drift — DIVERGED, never AHEAD/"promotion candidate" — the same
  # way any other single-line change inside a multi-line block would be.
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
    [ -z "$(find "$NVIM_DIST.new" \( ! -uid "0" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
    as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIVERGED* ]]
  [[ "$output" != *"promotion candidate"* ]]
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
  # This line has nothing to do with the ownership idiom (a different target
  # entirely, no matching template counterpart), so per Decision 5 (design
  # doc :521-522, "extra seed lines -> AHEAD") it is a promotion candidate,
  # not a divergence. There is no ownership-specific rule anymore to risk
  # over-matching it; this pins the ordinary case — an unrelated added line
  # is compared and reported like any other, not swallowed by anything.
  [[ "$output" == *AHEAD* ]]
  [[ "$output" == *'chown -R "$SEED_UID:$SEED_GID" "«HOME»/.cache"'* ]]
  [[ "$output" != *"overwrite the seed with"* ]]
}

# Fix round 2 (Task 7 review): the ownership rule was removed entirely (per
# the human's ruling after measurement showed it changed no verdict on the
# real corpus, and it had failed three separate ways — per-file asymmetry,
# blindness to a rewritten idiom half, and diff hunk adjacency). A root-
# flavored seed that verifies nothing about ownership now correctly reports
# the template's two idiom lines as BEHIND, same as any other omitted
# template content. This is the documented, intended behavior — pin it so it
# is not mistaken for a regression and "fixed" back into a drop later.
@test "a root-flavored seed with no ownership check reports the idiom lines as BEHIND" {
  t7_setup
  t7_doc "neovim install" NVIM_DIST
  t7_own_tpl
  cat >"$SEED" <<'SEEDEOF'
#!/usr/bin/env bash

NVIM_DIST="$SEED_HOME/.local/nvim"
if [ -d "$NVIM_DIST.new" ]; then
  as_user mv "$NVIM_DIST.new" "$NVIM_DIST"
fi
SEEDEOF
  t7_run "$SEED"
  [ "$status" -eq 1 ]
  [[ "$output" == *BEHIND* ]]
  [[ "$output" == *'2 template lines absent from seed'* ]]
  [[ "$output" == *'chown -R "$SEED_UID:$SEED_GID"'* ]]
}

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

# ── Task 8 fixture helpers ───────────────────────────────────────────────────
#
# A comment-only line strips to empty text in sd_scan and contributes nothing
# to sd_normalize's output, but it is still a non-blank physical line and so
# still counts toward sd_window's raw (pre-normalization) line count. That
# lets these fixtures pad one side's window past the thin-window threshold
# without changing what actually gets compared: `# pad 1` through `# pad 4`
# below add four lines to the raw window and zero lines to the normalized
# diff, while `ANCHOR_VAR=1` (and `FOO=2`, where present) are the only lines
# that ever reach the diff.

t8_pad() {
  printf '# pad 1\n# pad 2\n# pad 3\n# pad 4\n'
}

@test "a thin SEED window emits the note, names the seed side, and stays exit 0 when ok" {
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\n'
  } >"$TPL"
  printf '#!/usr/bin/env bash\n\nANCHOR_VAR=1\n' >"$SEED"

  t7_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"seed window is only 1 lines"* ]]
  [[ "$output" != *"template window is only"* ]]
  [[ "$output" == *"  ok"*"anchor block"* ]]
}

@test "a thin TEMPLATE window emits the note and names the template side" {
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  printf '#!/usr/bin/env bash\n\nANCHOR_VAR=1\n' >"$TPL"
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\n'
  } >"$SEED"

  t7_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"template window is only 1 lines"* ]]
  [[ "$output" != *"seed window is only"* ]]
}

@test "a normal-sized window on both sides emits no thin-window note" {
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\n'
  } >"$TPL"
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\n'
  } >"$SEED"

  t7_run
  [ "$status" -eq 0 ]
  [[ "$output" != *"window is only"* ]]
  [[ "$output" == *"  ok"*"anchor block"* ]]
}

@test "a thin AND drifted block reports both the real verdict and the note" {
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\nFOO=2\n'
  } >"$TPL"
  printf '#!/usr/bin/env bash\n\nANCHOR_VAR=1\n' >"$SEED"

  t7_run
  [ "$status" -eq 1 ]
  [[ "$output" == *BEHIND* ]]
  [[ "$output" == *"seed window is only 1 lines"* ]]
}

@test "a multi-paragraph anchor is judged by the UNION of its windows, not the last one alone" {
  # Pins SD_LAST_WINDOW_SIZE to the union computation in sd_extract rather than
  # a naive `sd_window`-per-call formula (Task 8 review). An anchor can match
  # more than one paragraph (the design doc's own example: TREE_SITTER_VERSION,
  # core.hooksPath). Two disjoint 3-line paragraphs here each fall under the
  # 5-line threshold on their own, but their union (6 raw lines) does not. A
  # formula that only remembers the LAST paragraph's window (the loop
  # overwrites a per-call global on every iteration) would see just that one
  # 3-line window and wrongly call the seed side thin; the union formula sees
  # 6 and correctly does not.
  t7_setup
  t7_doc "multi block" MULTI_ANCHOR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'MULTI_ANCHOR=1\n'
  } >"$TPL"
  # Two separate 3-line paragraphs, both matched by the fixed-string anchor
  # (MULTI_ANCHOR is a substring of MULTI_ANCHOR_TWO too) — mirrors the real
  # template's own multi-occurrence anchors. Each already parses standalone,
  # so sd_window never grows either one past its own 3 lines.
  printf '#!/usr/bin/env bash\n\n# s1\n# s2\nMULTI_ANCHOR=1\n\n# s3\n# s4\nMULTI_ANCHOR_TWO=2\n' >"$SEED"

  t7_run
  [ "$status" -eq 1 ]
  [[ "$output" == *AHEAD* ]]
  [[ "$output" != *"window is only"* ]]
}

@test "sabotage: reverting to a per-call (non-union) window size wrongly flags the multi-paragraph seed as thin" {
  # Same intent as the other sabotage-probe: confirm the test above actually
  # exercises the union math rather than passing under both formulas. The
  # naive replacement here is exactly the brief's original suggestion —
  # END - START + 1 off the single `sd_window` result, i.e. the last one the
  # loop ran (the loop overwrites `window` every iteration) — which is what a
  # regression back to it would look like.
  #
  # A plain `sed`/string substitution on this line is fragile (nested single
  # quotes, `$` sigils), so the swap goes through python3 doing an exact,
  # asserted-unique literal replacement instead.
  #
  # The sabotage lands on a private copy of the tool (t7_copy_tool), so there
  # is no restore step to get wrong and no window in which the repository's
  # own bin/seed-drift is broken.
  t7_copy_tool

  t7_setup
  t7_doc "multi block" MULTI_ANCHOR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'MULTI_ANCHOR=1\n'
  } >"$TPL"
  printf '#!/usr/bin/env bash\n\n# s1\n# s2\nMULTI_ANCHOR=1\n\n# s3\n# s4\nMULTI_ANCHOR_TWO=2\n' >"$SEED"

  # Unsabotaged first, so the probe shows the flip in both directions from a
  # single run rather than relying on the sibling test above.
  t7_run_tool "$T7_TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *AHEAD* ]]
  [[ "$output" != *"window is only"* ]]

  python3 - "$T7_TOOL" <<'PYEOF'
import sys
path = sys.argv[1]
old = '''  SD_LAST_WINDOW_SIZE=$(printf '%s\\n' "$keep" | awk 'END { print NR }')'''
new = '''  SD_LAST_WINDOW_SIZE=$(printf '%s\\n' "$window" | awk '{ print $2 - $1 + 1 }')'''
text = open(path).read()
assert text.count(old) == 1, "sabotage target line not found or not unique"
open(path, "w").write(text.replace(old, new))
PYEOF

  t7_run_tool "$T7_TOOL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"seed window is only 3 lines"* ]]

  t7_assert_repo_tool_untouched
}

@test "sabotage: raising SD_THIN_WINDOW past the seed's window size hides the note" {
  # Pins the load-bearing test above to the actual threshold constant, not to
  # a hardcoded string it happens to match. The edit goes to a private copy of
  # the tool, never to $REPO_ROOT/bin/seed-drift — see t7_copy_tool for why.
  t7_copy_tool

  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR_VAR=1\n'
  } >"$TPL"
  printf '#!/usr/bin/env bash\n\nANCHOR_VAR=1\n' >"$SEED"

  t7_run_tool "$T7_TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"seed window is only 1 lines"* ]]

  sed -i 's/^SD_THIN_WINDOW=5$/SD_THIN_WINDOW=1/' "$T7_TOOL"
  t7_run_tool "$T7_TOOL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"window is only"* ]]

  t7_assert_repo_tool_untouched
}

# ── Window-growth regressions, end to end (final review I-1) ─────────────────

@test "a block needing backward growth is not merged with the paragraphs after it" {
  # The final review's reproduction. Template and seed are identical inside the
  # anchor's own `if` block and differ only in a trailing paragraph that has
  # nothing to do with it. The old forward-to-EOF-then-backward walk left the
  # window end pinned at EOF, so UNRELATED was extracted as part of the block
  # and reported as a DIVERGED verdict under the wrong block's name. The
  # correct window stops at `fi`, so this is `ok` at exit 0.
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  printf '#!/usr/bin/env bash\n\nif [ -n "$x" ]; then\n\n  # pad\n  # pad\n  ANCHOR_VAR=1\nfi\n\nUNRELATED=2\n' \
    >"$TPL"
  printf '#!/usr/bin/env bash\n\nif [ -n "$x" ]; then\n\n  # pad\n  # pad\n  ANCHOR_VAR=1\nfi\n\nUNRELATED=999\n' \
    >"$SEED"

  t7_run
  [ "$status" -eq 0 ]
  [[ "$output" != *DIVERGED* ]]
  [[ "$output" != *UNRELATED* ]]
  [[ "$output" != *"window is only"* ]]
}

@test "a block needing growth in both directions gets the verdict of that block alone" {
  # The anchor sits mid-function with blank lines on both sides, so the window
  # must reach back to `setup() {` and forward to its closing `}`. The seed is
  # missing one line from inside the function and also differs in a trailing
  # paragraph outside it. The correct verdict is BEHIND by exactly that one
  # line; a window that ran to EOF would pull UNRELATED in on both sides and
  # report DIVERGED instead.
  t7_setup
  t7_doc "anchor block" ANCHOR_VAR
  printf '#!/usr/bin/env bash\n\nsetup() {\n  local a=1\n\n  if [ -n "$x" ]; then\n    ANCHOR_VAR=1\n\n    echo more\n  fi\n}\n\nUNRELATED=2\n' \
    >"$TPL"
  printf '#!/usr/bin/env bash\n\nsetup() {\n  local a=1\n\n  if [ -n "$x" ]; then\n    ANCHOR_VAR=1\n\n  fi\n}\n\nUNRELATED=999\n' \
    >"$SEED"

  t7_run
  [ "$status" -eq 1 ]
  [[ "$output" == *"BEHIND"* ]]
  [[ "$output" == *"1 template lines absent from seed"* ]]
  [[ "$output" != *DIVERGED* ]]
  [[ "$output" != *UNRELATED* ]]
  [[ "$output" != *"window is only"* ]]
}

@test "a seed block whose search exceeds the parse-attempt cap is an ERROR at exit 2, never 3" {
  # sd_window's new cap returns 3, the same status its exhaustion path already
  # returned. 3 is internal: the public contract is 0/1/2 only. This pins that
  # sd_extract -> sd_check_seed still converts it, on the error path I-1
  # changed rather than on the one that existed before.
  t7_setup
  t7_doc "anchor block" ANCHOR
  {
    printf '#!/usr/bin/env bash\n\n'
    t8_pad
    printf 'ANCHOR=1\n'
  } >"$TPL"
  {
    printf 'if true; then\n\n'
    for n in $(seq 20); do printf '  echo p%s\n\n' "$n"; done
    printf '  ANCHOR=1\nfi\n\n'
    for n in $(seq 20); do printf '  echo q%s\n\n' "$n"; done
  } >"$SEED"

  t7_run
  [ "$status" -eq 2 ]
  [[ "$output" == *"seed block could not be extracted"* ]]
  [[ "$output" != *MISSING* ]]
}
