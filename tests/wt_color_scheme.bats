#!/usr/bin/env bats

load test_helper

SCRIPT_PATH() { printf '%s\n' "$REPO_ROOT/platforms/windows/wt-color-scheme.sh"; }

setup() {
  setup_dotfiles_test
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin:$SANDBOX_TOOL_BIN"
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

# ── Argument handling ────────────────────────────────────────────────────────
# The Windows-user selection itself resolves against the real /mnt/c/Users, so
# it cannot be faked here. What these cover is the parsing around it: the flag
# is accepted in both spellings, a missing value is caught rather than
# swallowing the next flag, and the help text stays in sync with the header.

@test "--win-user is accepted in both spellings" {
  write_bare_settings

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user someone --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not applied"* ]]

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user=someone --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Not applied"* ]]
}

@test "--win-user without a value is rejected" {
  # Without the arity check the following flag becomes the username, and the
  # script goes looking for /mnt/c/Users/--check.
  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "--win-user rejects an empty value rather than ignoring the flag" {
  # An empty username silently fell through to host discovery, behaving as if
  # the flag had never been passed.
  write_bare_settings

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user "" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user= --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "--win-user rejects an option-like value instead of swallowing the flag" {
  # The sharp case: `--win-user --check` consumed --check as the username, so
  # the run lost its read-only flag and wrote settings.json instead. Assert the
  # file is untouched, not merely that the exit status is non-zero.
  write_bare_settings
  local before
  before="$(md5sum <"$SETTINGS")"

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
  [[ "$(md5sum <"$SETTINGS")" == "$before" ]]

  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --win-user=--dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a value"* ]]
  [[ "$(md5sum <"$SETTINGS")" == "$before" ]]
}

@test "an unknown argument is still rejected" {
  run env WT_SETTINGS_PATH="$SETTINGS" bash "$(SCRIPT_PATH)" --nonsense
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "--help documents --win-user" {
  # The help text is derived from the leading comment block rather than a fixed
  # line range, so a header edit cannot silently truncate it.
  run bash "$(SCRIPT_PATH)" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--win-user"* ]]
  [[ "$output" == *"WT_SETTINGS_PATH"* ]]
}
