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
