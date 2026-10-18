#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/config/versions.env"
  cp "$REPO_ROOT/config/versions.env" "$TEST_ROOT/pins-before"
  local major="${HERDR_VERSION#v}"
  HERDR_NEWER_VERSION="v$((${major%%.*} + 1)).0.0"
  export HERDR_CHECK_RESPONSE="{\"tag_name\":\"$HERDR_NEWER_VERSION\"}" HERDR_CHECK_STATUS=0
  stub_command curl '
    connect= max= retry=
    while (($# > 1)); do
      case "$1" in
        --connect-timeout) connect=$2; shift ;;
        --max-time) max=$2; shift ;;
        --retry) retry=$2; shift ;;
      esac
      shift
    done
    [[ "$1" == https://api.github.com/repos/herdrdev/herdr/releases/latest ]] || exit 91
    printf "%s %s %s\n" "$connect" "$max" "$retry" >"$TEST_ROOT/curl-budget"
    printf "%s\n" "$HERDR_CHECK_RESPONSE"
    exit "$HERDR_CHECK_STATUS"
  '
  for tool in herdr mise git; do
    stub_command "$tool" 'printf "unexpected tool invocation\n" >&2; exit 91'
  done
}

@test "Herdr advisory compares only the pin and stable release without mutation" {
  run bash "$REPO_ROOT/libexec/versions" check-herdr
  [ "$status" -eq 0 ]
  [[ "$output" == *"Herdr pin differs from latest stable: $HERDR_VERSION -> $HERDR_NEWER_VERSION"* ]]
  [[ "$output" == *"tools/herdr/README.md"* ]]
  [[ "$output" != *"unexpected tool"* ]]
  [ "$(<"$TEST_ROOT/curl-budget")" = '3 10 0' ]
  cmp "$TEST_ROOT/pins-before" "$REPO_ROOT/config/versions.env"
  [ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]
}

@test "Herdr advisory reports a current pin without an update recommendation" {
  HERDR_CHECK_RESPONSE="{\"tag_name\":\"$HERDR_VERSION\"}" run bash "$REPO_ROOT/libexec/versions" check-herdr
  [ "$status" -eq 0 ]
  [[ "$output" == *"Herdr pin matches latest stable: $HERDR_VERSION"* ]]
  [[ "$output" != *"differs"* ]]
}

@test "Herdr advisory reports a different older release without recommending a downgrade" {
  HERDR_CHECK_RESPONSE='{"tag_name":"v0.0.1"}' run bash "$REPO_ROOT/libexec/versions" check-herdr
  [ "$status" -eq 0 ]
  [[ "$output" == *"pin differs from latest stable: $HERDR_VERSION -> v0.0.1"* ]]
  [[ "$output" != *"outdated"* ]]
}

@test "Herdr advisory rejects transport failures and malformed release responses" {
  local response
  for response in '{}' '{"tag_name":null}' '{"tag_name":"preview-123"}' '{"tag_name":"v0.9.5\nforged"}' '<html>rate limited</html>' '{"tag_name":"v0.9.5"} {"tag_name":"v1.0.0"}'; do
    HERDR_CHECK_RESPONSE="$response" run bash "$REPO_ROOT/libexec/versions" check-herdr
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unable to check Herdr updates"* ]]
    [[ "$output" != *"pin matches"* && "$output" != *"pin differs"* ]]
  done
  HERDR_CHECK_STATUS=22 run bash "$REPO_ROOT/libexec/versions" check-herdr
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unable to check Herdr updates"* ]]
  [[ "$output" != *"pin differs"* ]]
}

@test "Herdr advisory reports missing prerequisites without querying upstream" {
  local tool
  for tool in curl jq; do
    local tools="$TEST_ROOT/only-$tool"
    mkdir -p "$tools"
    local required
    for required in bash dirname; do ln -sf "$(command -v "$required")" "$tools/$required"; done
    if [[ "$tool" == curl ]]; then ln -sf "$(command -v jq)" "$tools/jq"; fi
    if [[ "$tool" == jq ]]; then ln -sf "$STUB_BIN/curl" "$tools/curl"; fi
    run /bin/bash -c 'PATH="$1" /bin/bash "$2/libexec/versions" check-herdr' _ "$tools" "$REPO_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unable to check Herdr updates"* && "$output" == *"$tool"* ]]
    [ ! -e "$TEST_ROOT/curl-budget" ]
  done
}
