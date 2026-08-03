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
