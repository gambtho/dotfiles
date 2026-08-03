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
