#!/usr/bin/env bats

load test_helper

# A fake `claude` keeps one marketplace pin and one installed plugin version in
# files, and logs every call that changes them.
setup() {
  setup_dotfiles_test
  unset CLAUDE_CONFIG_DIR
  INSTALLER="$REPO_ROOT/ai/claude/install.sh"
  TAG=$(sed -n 's/^SKILLS_TAG=//p' "$INSTALLER")
  STATE="$TEST_ROOT/claude-state"
  mkdir -p "$STATE" "$HOME/.claude/skills"
  export STATE
  stub_command claude '
    set -euo pipefail
    case "$*" in
      "plugin marketplace list --json")
        if [[ -f "$STATE/ref" ]]; then
          jq -n --arg ref "$(cat "$STATE/ref")" "[{name: \"gambtho-skills\", source: \"github\", repo: \"gambtho/gambtho-skills\", ref: \$ref}]"
        else
          echo "[]"
        fi ;;
      "plugin list --json")
        if [[ -f "$STATE/version" ]]; then
          jq -n --arg v "$(cat "$STATE/version")" --argjson e "$(cat "$STATE/enabled" 2>/dev/null || echo true)" \
            "[{id: \"gambtho-skills@gambtho-skills\", version: \$v, enabled: \$e, scope: \"$(cat "$STATE/scope" 2>/dev/null || echo user)\"}]"
        else
          echo "[]"
        fi ;;
      "plugin marketplace remove gambtho-skills --scope user")
        echo "$*" >>"$STATE/calls"
        [[ ! -f "$STATE/project-marketplace" ]] || exit 1
        rm -f "$STATE/ref" "$STATE/version" ;;
      "plugin marketplace add gambtho/gambtho-skills@"*" --scope user")
        echo "$*" >>"$STATE/calls"; echo "${4#*@}" >"$STATE/ref" ;;
      "plugin install gambtho-skills@gambtho-skills --scope user")
        echo "$*" >>"$STATE/calls"
        [[ -f "$STATE/broken" ]] && exit 0
        ref=$(cat "$STATE/ref"); echo "${ref#v}" >"$STATE/version" ;;
      *) echo "unexpected claude $*" >&2; exit 97 ;;
    esac
  '
}

installed_at() {
  echo "$1" >"$STATE/ref"
  echo "${1#v}" >"$STATE/version"
}

legacy_links() {
  mkdir -p "$HOME/.dotfiles/ai/marketplace/plugins/my/skills/pr-closeout" "$TEST_ROOT/elsewhere"
  ln -s "$HOME/.dotfiles/ai/marketplace/plugins/my/skills/pr-closeout" "$HOME/.claude/skills/pr-closeout"
  ln -s "$HOME/.dotfiles/ai/marketplace/plugins/my/skills/pr-text" "$HOME/.claude/skills/pr-text"
  ln -s ../../.dotfiles/ai/marketplace/plugins/my/skills/polish-core "$HOME/.claude/skills/polish-core"
  ln -s "$TEST_ROOT/elsewhere" "$HOME/.claude/skills/elsewhere"
  mkdir "$HOME/.claude/skills/own-skill"
}

assert_only_unrelated_skills_remain() {
  [ "$(ls "$HOME/.claude/skills" | tr '\n' ' ')" = "elsewhere own-skill " ]
  [ "$(cat "$XDG_STATE_HOME/dotfiles/claude-legacy-links.txt")" = $'polish-core\npr-closeout\npr-text' ]
}

@test "the pin is a release tag" {
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "first install adds the pinned marketplace, installs the plugin and then removes links into dotfiles" {
  legacy_links

  run bash "$INSTALLER"

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/calls")" = "plugin marketplace add gambtho/gambtho-skills@$TAG --scope user
plugin install gambtho-skills@gambtho-skills --scope user" ]
  [ "$(cat "$STATE/version")" = "${TAG#v}" ]
  [[ "$output" == *"Removed legacy Claude skill link: pr-closeout"* ]]
  [[ "$output" == *"Removed legacy Claude skill link: pr-text"* ]]
  [[ "$output" == *"Removed legacy Claude skill link: polish-core"* ]]
  assert_only_unrelated_skills_remain
}

@test "a repeat run changes nothing" {
  legacy_links
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  rm "$STATE/calls"
  cp "$XDG_STATE_HOME/dotfiles/claude-legacy-links.txt" "$TEST_ROOT/log-before"

  run bash "$INSTALLER"

  [ "$status" -eq 0 ]
  [ ! -e "$STATE/calls" ]
  [[ "$output" != *"Removed"* ]]
  cmp "$TEST_ROOT/log-before" "$XDG_STATE_HOME/dotfiles/claude-legacy-links.txt"
  assert_only_unrelated_skills_remain
}

@test "an upgrade and a rollback both re-pin through remove, add and install" {
  local from
  for from in v0.0.1 v99.0.0; do
    installed_at "$from"
    rm -f "$STATE/calls"

    run bash "$INSTALLER"

    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/calls")" = "plugin marketplace remove gambtho-skills --scope user
plugin marketplace add gambtho/gambtho-skills@$TAG --scope user
plugin install gambtho-skills@gambtho-skills --scope user" ]
    [ "$(cat "$STATE/ref")" = "$TAG" ]
    [ "$(cat "$STATE/version")" = "${TAG#v}" ]
  done
}

@test "the old links stay when Claude does not show the plugin at the pinned version" {
  legacy_links
  touch "$STATE/broken"

  run bash "$INSTALLER"

  [ "$status" -ne 0 ]
  [[ "$output" == *"keeping the old skill links"* ]]
  [ -L "$HOME/.claude/skills/pr-closeout" ]
  [ ! -e "$XDG_STATE_HOME/dotfiles/claude-legacy-links.txt" ]
}

@test "a disabled plugin keeps the old links and says how to enable it" {
  legacy_links
  installed_at "$TAG"
  echo false >"$STATE/enabled"

  run bash "$INSTALLER"

  [ "$status" -ne 0 ]
  [[ "$output" == *"claude plugin enable gambtho-skills@gambtho-skills"* ]]
  [ -L "$HOME/.claude/skills/pr-text" ]
}

@test "a project-scope plugin does not count; the user-scope install still runs first" {
  legacy_links
  installed_at "$TAG"
  echo project >"$STATE/scope"

  run bash "$INSTALLER"

  # The fake keeps one install, so after "installing" it still reports project
  # scope: the script must refuse to remove the global links.
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/calls")" = "plugin install gambtho-skills@gambtho-skills --scope user" ]
  [ -L "$HOME/.claude/skills/pr-closeout" ]
}

@test "a marketplace declared only outside user settings is reported, not removed" {
  legacy_links
  installed_at v0.0.1
  touch "$STATE/project-marketplace"

  run bash "$INSTALLER"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not declared in user settings"* ]]
  [ "$(cat "$STATE/calls")" = "plugin marketplace remove gambtho-skills --scope user" ]
  [ -L "$HOME/.claude/skills/pr-closeout" ]
}

@test "check mode reports the plan and changes nothing" {
  legacy_links
  installed_at v0.0.1

  run bash "$INSTALLER" --check

  [ "$status" -eq 0 ]
  [[ "$output" == *"Would re-pin"* ]]
  [[ "$output" == *"pr-closeout"* ]]
  [ ! -e "$STATE/calls" ]
  [ -L "$HOME/.claude/skills/pr-closeout" ]
}

@test "a machine without Claude Code is skipped with a notice" {
  rm "$STUB_BIN/claude"
  rm -r "$HOME/.claude"

  run bash "$INSTALLER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude Code is not set up on this machine; skipping"* ]]
}

@test "a machine that had Claude Code fails loudly when claude is missing, and keeps the old links" {
  if [[ -x /usr/bin/claude || -x /bin/claude ]]; then
    skip "this host has a system claude"
  fi
  legacy_links
  rm "$STUB_BIN/claude"

  run bash "$INSTALLER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: Claude Code is set up here"* ]]
  [[ "$output" == *"https://claude.ai/install.sh"* ]]
  [[ "$output" != *"skipping"* ]]
  [ -L "$HOME/.claude/skills/pr-closeout" ]
}

@test "with a bare environment, claude and jq are found in ~/.local/bin" {
  legacy_links
  mkdir -p "$HOME/.local/bin"
  mv "$STUB_BIN/claude" "$HOME/.local/bin/claude"
  ln -s "$(command -v jq)" "$HOME/.local/bin/jq"

  run env -i HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" STATE="$STATE" PATH=/usr/bin:/bin \
    bash "$INSTALLER"

  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/version")" = "${TAG#v}" ]
  assert_only_unrelated_skills_remain
}

@test "unsupported arguments are rejected" {
  run bash "$INSTALLER" --force
  [ "$status" -eq 2 ]
  [ ! -e "$STATE/calls" ]
}
