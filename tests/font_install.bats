#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  export FONT_DIR="$HOME/.local/share/fonts/NerdFonts"
}

@test "matching Nerd Fonts version performs no downloads" {
  mkdir -p "$FONT_DIR"
  printf 'v3.4.0\n' >"$FONT_DIR/installed-version"

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { return 99; }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
}

@test "failed Nerd Font verification preserves the installed directory" {
  mkdir -p "$FONT_DIR"
  printf 'old-font\n' >"$FONT_DIR/old.ttf"
  printf 'v3.3.0\n' >"$FONT_DIR/installed-version"

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() {
      if [[ "$1" == */Hack.zip ]]; then
        printf 'verification failed\n' >&2
        return 1
      fi
      printf archive >"$3"
    }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(cat "$FONT_DIR/old.ttf")" = old-font ]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.3.0 ]
}

@test "successful Nerd Font staging replaces managed fonts and records version" {
  mkdir -p "$FONT_DIR"
  printf 'old-font\n' >"$FONT_DIR/old.ttf"
  printf 'v3.3.0\n' >"$FONT_DIR/installed-version"

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { printf archive >"$3"; }
    unzip() {
      local archive="$2" destination="$4"
      printf font >"$destination/${archive##*/}.ttf"
    }
    fc-cache() { :; }
    gsettings() { :; }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ ! -e "$FONT_DIR/old.ttf" ]
  [ -f "$FONT_DIR/CascadiaMono.zip.ttf" ]
  [ -f "$FONT_DIR/Hack.zip.ttf" ]
  [ -f "$FONT_DIR/Meslo.zip.ttf" ]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.4.0 ]
}

@test "failed post-install verification restores the previous font directory" {
  mkdir -p "$FONT_DIR"
  printf 'old-font\n' >"$FONT_DIR/old.ttf"
  printf 'v3.3.0\n' >"$FONT_DIR/installed-version"

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { printf archive >"$3"; }
    unzip() {
      local archive="$2" destination="$4"
      printf font >"$destination/${archive##*/}.ttf"
    }
    fc-cache() { return 1; }
    gsettings() { :; }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [ "$(cat "$FONT_DIR/old.ttf")" = old-font ]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.3.0 ]
}
