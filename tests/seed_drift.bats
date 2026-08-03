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
