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

@test "failed post-install verification restores a dangling font symlink" {
  local original_target="$TEST_ROOT/missing-managed-fonts"
  mkdir -p "$(dirname "$FONT_DIR")"
  ln -s "$original_target" "$FONT_DIR"

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
  [ -L "$FONT_DIR" ]
  [ "$(readlink "$FONT_DIR")" = "$original_target" ]
}

@test "archives that share files unpack without an overwrite prompt" {
  local zips="$TEST_ROOT/zips" name
  mkdir -p "$zips"
  for name in CascadiaMono Hack Meslo; do
    python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("README.md", "shared\n")
    z.writestr("LICENSE.txt", "shared\n")
    z.writestr(sys.argv[2] + ".ttf", "font\n")
' "$zips/$name.zip" "$name"
  done

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" ZIPS="$zips" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { cp "$ZIPS/${1##*/}" "$3"; }
    fc-cache() { :; }
    gsettings() { :; }
    install_fonts
  ' _ "$REPO_ROOT" </dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"replace"* ]]
  [ -f "$FONT_DIR/Hack.ttf" ]
  [ -f "$FONT_DIR/README.md" ]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.4.0 ]
}

@test "a locked GNOME font key does not fail the install" {
  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { printf archive >"$3"; }
    unzip() {
      local archive="$2" destination="$4"
      printf font >"$destination/${archive##*/}.ttf"
    }
    fc-cache() { :; }
    gsettings() {
      [[ "$1" == writable ]] || { printf "gsettings set was called\n" >&2; return 1; }
      printf "false\n"
    }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"gsettings set was called"* ]]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.4.0 ]
}

@test "a writable GNOME font key is set" {
  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { printf archive >"$3"; }
    unzip() {
      local archive="$2" destination="$4"
      printf font >"$destination/${archive##*/}.ttf"
    }
    fc-cache() { :; }
    gsettings() {
      if [[ "$1" == writable ]]; then printf "true\n"; else printf "set %s\n" "$*"; fi
    }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"set set org.gnome.desktop.interface monospace-font-name CaskaydiaMono Nerd Font 10"* ]]
}

@test "gsettings without the GNOME interface schema does not fail the install" {
  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$FONT_DIR" bash -c '
    source "$1/fonts/install.sh"
    download_verified_artifact() { printf archive >"$3"; }
    unzip() {
      local archive="$2" destination="$4"
      printf font >"$destination/${archive##*/}.ttf"
    }
    fc-cache() { :; }
    gsettings() {
      [[ "$1" == writable ]] || { printf "gsettings set was called\n" >&2; return 1; }
      printf "No schemas installed\n" >&2
      return 1
    }
    install_fonts
  ' _ "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"gsettings set was called"* ]]
  [ "$(cat "$FONT_DIR/installed-version")" = v3.4.0 ]
}

@test "macOS installs fonts where macOS reads them, elsewhere the XDG directory" {
  run env -u FONT_DIR FONT_INSTALL_SOURCE_ONLY=1 bash -c '
    uname() { printf "Darwin\n"; }
    source "$1/fonts/install.sh"
    printf "%s\n" "$FONT_DIR"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/Library/Fonts/NerdFonts" ]

  run env -u FONT_DIR FONT_INSTALL_SOURCE_ONLY=1 bash -c '
    uname() { printf "Linux\n"; }
    source "$1/fonts/install.sh"
    printf "%s\n" "$FONT_DIR"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/share/fonts/NerdFonts" ]
}

@test "the old macOS font copy is removed only when this installer made it" {
  local legacy="$HOME/.local/share/fonts/NerdFonts"
  mkdir -p "$legacy"
  printf 'font\n' >"$legacy/old.ttf"

  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$HOME/Library/Fonts/NerdFonts" bash -c '
    source "$1/fonts/install.sh"
    remove_legacy_fonts
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$legacy/old.ttf" ]

  printf 'v3.4.0\n' >"$legacy/installed-version"
  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$HOME/Library/Fonts/NerdFonts" bash -c '
    source "$1/fonts/install.sh"
    remove_legacy_fonts
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$legacy" ]

  mkdir -p "$legacy"
  printf 'v3.4.0\n' >"$legacy/installed-version"
  run env FONT_INSTALL_SOURCE_ONLY=1 FONT_DIR="$legacy" bash -c '
    source "$1/fonts/install.sh"
    remove_legacy_fonts
  ' _ "$REPO_ROOT"
  [ -f "$legacy/installed-version" ]
}
