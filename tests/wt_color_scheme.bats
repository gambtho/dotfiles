#!/usr/bin/env bats

load test_helper

SCRIPT_PATH() { printf '%s\n' "$REPO_ROOT/platforms/windows/wt-color-scheme.sh"; }

setup() {
  setup_dotfiles_test
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin"
  SETTINGS="$TEST_ROOT/settings.json"
}

# A settings.json with no schemes and no profile default -- the shape Windows
# Terminal ships, and the one this repo's own machine started from.
write_bare_settings() {
  cat >"$SETTINGS" <<'JSON'
{"profiles":{"defaults":{},"list":[{"name":"Ubuntu"}]},"schemes":[]}
JSON
}

@test "the scheme is installed and made the profile default" {
  write_bare_settings

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)"
  [ "$status" -eq 0 ]

  run jq -r '.profiles.defaults.colorScheme' "$SETTINGS"
  [[ "$output" == "Tokyo Night" ]]
  run jq -r '[.schemes[] | select(.name == "Tokyo Night")] | length' "$SETTINGS"
  [[ "$output" == "1" ]]
}

@test "re-running is idempotent and rewrites nothing" {
  write_bare_settings
  env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" >/dev/null

  # jq reformats the whole document, so a byte-wise idempotence check would
  # report drift forever and cut a backup on every run. Assert the file is not
  # touched at all on the second pass.
  local before after
  before="$(md5sum <"$SETTINGS")"
  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already applied"* ]]
  after="$(md5sum <"$SETTINGS")"
  [[ "$before" == "$after" ]]
}

@test "--check reports state without writing" {
  write_bare_settings
  local before
  before="$(md5sum <"$SETTINGS")"

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not applied"* ]]
  [[ "$(md5sum <"$SETTINGS")" == "$before" ]]

  env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" >/dev/null
  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already applied"* ]]
}

@test "duplicate entries of the same name collapse to exactly one" {
  # Windows Terminal does not write duplicates itself, but a hand-edited or
  # merged settings.json can hold two entries with the same name, and which one
  # wins is not something to leave to chance. Replacing in place would keep
  # both; `any`-based detection would then call it applied and never normalise.
  cat >"$SETTINGS" <<'JSON'
{"profiles":{"defaults":{},"list":[{"name":"Ubuntu"}]},
 "schemes":[{"name":"Keepme","background":"#000000"},
            {"name":"Tokyo Night","background":"#BADBAD"},
            {"name":"Tokyo Night","background":"#0FF1CE"}]}
JSON

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --check
  [ "$status" -eq 1 ]

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)"
  [ "$status" -eq 0 ]

  run jq -r '[.schemes[] | select(.name == "Tokyo Night")] | length' "$SETTINGS"
  [[ "$output" == "1" ]]
  run jq -r '.schemes[] | select(.name == "Tokyo Night") | .background' "$SETTINGS"
  [[ "$output" == "#1A1B26" ]]

  # Unrelated schemes survive.
  run jq -r '[.schemes[] | select(.name == "Keepme")] | length' "$SETTINGS"
  [[ "$output" == "1" ]]

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --check
  [ "$status" -eq 0 ]
}

@test "profiles with an explicit colorScheme keep it" {
  cat >"$SETTINGS" <<'JSON'
{"profiles":{"defaults":{},"list":[{"name":"Ubuntu"},{"name":"Tmux","colorScheme":"Ubuntu"}]},"schemes":[]}
JSON

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tmux"* ]]

  run jq -r '.profiles.list[] | select(.name == "Tmux") | .colorScheme' "$SETTINGS"
  [[ "$output" == "Ubuntu" ]]
}

@test "a settings.json containing comments is refused rather than mangled" {
  # jq cannot parse JSONC. Rewriting such a file would silently drop every
  # comment the user wrote.
  cat >"$SETTINGS" <<'JSON'
{
  // keep me
  "profiles": {"defaults": {}, "list": []},
  "schemes": []
}
JSON
  local before
  before="$(md5sum <"$SETTINGS")"

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not plain JSON"* ]]
  [[ "$(md5sum <"$SETTINGS")" == "$before" ]]
}

@test "a missing WT_SETTINGS_PATH is refused" {
  run env WT_SETTINGS_PATH="$TEST_ROOT/nope.json" bash "$(SCRIPT_PATH)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}
