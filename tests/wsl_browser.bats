#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export BROWSER_ARGS="$TEST_ROOT/browser-args"
  export WINDOWS_BROWSER="$TEST_ROOT/rundll32.exe"
  export WSL_INTEROP_MARKER="$TEST_ROOT/WSLInterop"
  printf 'enabled\ninterpreter /init\nflags: P\noffset 0\nmagic 4d5a\n' >"$WSL_INTEROP_MARKER"
  stub_command rundll32.exe 'printf "%s\n" "$@" >"$BROWSER_ARGS"'
  cp "$STUB_BIN/rundll32.exe" "$WINDOWS_BROWSER"

  # Relocate the two host filesystem probes; execute the actual environment
  # configuration without depending on the test host being Windows/WSL.
  sed -e "s|/proc/sys/fs/binfmt_misc/WSLInterop|$WSL_INTEROP_MARKER|g" \
    -e "s|/mnt/c/Windows/System32/rundll32.exe|$WINDOWS_BROWSER|g" \
    "$REPO_ROOT/core/env.zsh" >"$TEST_ROOT/env.zsh"
}

@test "WSL exports a Windows browser fallback when BROWSER is unset or empty" {
  local initial
  for initial in unset empty; do
    run zsh -dfc '
      unset BROWSER
      [[ $2 == empty ]] && BROWSER=""
      source "$1/env.zsh"
      /bin/sh -c '\''printf "%s\n" "$BROWSER"'\''
    ' _ "$TEST_ROOT" "$initial"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = "$WINDOWS_BROWSER url.dll,FileProtocolHandler %s" ]
  done
}

@test "WSL preserves a user-selected browser" {
  BROWSER='custom-browser --private' run zsh -dfc '
    source "$1/env.zsh"
    print -r -- "$BROWSER"
  ' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = 'custom-browser --private' ]
}

@test "non-WSL shells leave BROWSER unset" {
  rm "$WSL_INTEROP_MARKER"
  run zsh -dfc '
    unset BROWSER
    source "$1/env.zsh"
    print -r -- "${BROWSER-unset}"
  ' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = unset ]
}

@test "WSL with disabled interop leaves BROWSER unset" {
  printf 'disabled\ninterpreter /init\nflags: P\noffset 0\nmagic 4d5a\n' >"$WSL_INTEROP_MARKER"
  run zsh -dfc '
    unset BROWSER
    source "$1/env.zsh"
    print -r -- "${BROWSER-unset}"
  ' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = unset ]
}

@test "WSL uses enabled late interop when the regular entry is absent or disabled" {
  printf 'enabled\ninterpreter /init\nflags: P\noffset 0\nmagic 4d5a\n' >"$WSL_INTEROP_MARKER-late"
  local regular
  for regular in absent disabled; do
    rm -f "$WSL_INTEROP_MARKER"
    if [[ "$regular" == disabled ]]; then
      printf 'disabled\ninterpreter /init\nflags: P\noffset 0\nmagic 4d5a\n' >"$WSL_INTEROP_MARKER"
    fi
    run zsh -dfc '
      unset BROWSER
      source "$1/env.zsh"
      print -r -- "$BROWSER"
    ' _ "$TEST_ROOT"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = "$WINDOWS_BROWSER url.dll,FileProtocolHandler %s" ]
  done
}

@test "WSL without an executable Windows browser leaves BROWSER unset" {
  chmod -x "$WINDOWS_BROWSER"
  run zsh -dfc '
    unset BROWSER
    source "$1/env.zsh"
    print -r -- "${BROWSER-unset}"
  ' _ "$TEST_ROOT"
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = unset ]
}

@test "Python webbrowser forwards the URL with the Windows handler argument" {
  local url='https://example.com/?q=a&literal=$(not-a-command)&quoted="value"&encoded=%20'
  run zsh -dfc '
    unset BROWSER DISPLAY WAYLAND_DISPLAY
    source "$1/env.zsh"
    python3 -c '\''import sys, webbrowser; sys.exit(0 if webbrowser.get().open(sys.argv[1]) else 1)'\'' "$2"
  ' _ "$TEST_ROOT" "$url"
  [ "$status" -eq 0 ]
  [ "$(<"$BROWSER_ARGS")" = "$(printf 'url.dll,FileProtocolHandler\n%s' "$url")" ]
}

@test "headless xdg-open forwards the web URL as one literal Windows argument" {
  command -v xdg-open >/dev/null || skip 'xdg-open is not installed'
  local url='https://example.com/?q=a&literal=$(not-a-command)&quoted="value"&encoded=%20'
  run zsh -dfc '
    unset BROWSER DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP DESKTOP_SESSION DE
    source "$1/env.zsh"
    xdg-open "$2"
  ' _ "$TEST_ROOT" "$url"
  [ "$status" -eq 0 ]
  [ "$(<"$BROWSER_ARGS")" = "$(printf 'url.dll,FileProtocolHandler\n%s' "$url")" ]
}
