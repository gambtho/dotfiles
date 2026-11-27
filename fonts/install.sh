#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../libexec/common.sh"
# shellcheck source=config/versions.env
source "$(dirname "${BASH_SOURCE[0]}")/../config/versions.env"

FONT_DIR="${FONT_DIR:-$HOME/.local/share/fonts/NerdFonts}"
DEFAULT_FONT="CaskaydiaMono Nerd Font 10"

font_digest() {
  case "$1" in
    CascadiaMono.zip) printf '%s\n' "$NERD_FONT_CASCADIA_MONO_SHA256" ;;
    Hack.zip) printf '%s\n' "$NERD_FONT_HACK_SHA256" ;;
    Meslo.zip) printf '%s\n' "$NERD_FONT_MESLO_SHA256" ;;
    *) return 2 ;;
  esac
}

install_fonts() {
  local installed_version=""
  local parent staging archives staged_fonts previous asset
  local -a assets=(CascadiaMono.zip Hack.zip Meslo.zip)

  if [[ -f "$FONT_DIR/installed-version" ]]; then
    installed_version=$(<"$FONT_DIR/installed-version")
  fi
  if [[ "$installed_version" == "$NERD_FONTS_VERSION" ]]; then
    log_info "Nerd Fonts $NERD_FONTS_VERSION already installed."
    return 0
  fi

  parent=$(dirname "$FONT_DIR")
  mkdir -p "$parent"
  staging=$(mktemp -d "$parent/.NerdFonts.install.XXXXXX")
  archives="$staging/archives"
  staged_fonts="$staging/NerdFonts"
  previous="$staging/previous"
  mkdir -p "$archives" "$staged_fonts"

  for asset in "${assets[@]}"; do
    download_verified_artifact \
      "$NERD_FONTS_RELEASE_BASE/$asset" \
      "$(font_digest "$asset")" \
      "$archives/$asset" \
      0644 || {
      rm -rf -- "$staging"
      return 1
    }
  done

  # The archives share README.md and LICENSE.txt. Without -o, unzip stops at
  # an overwrite prompt (or fails with no terminal), the version is never
  # recorded, and every later run downloads the fonts again.
  for asset in "${assets[@]}"; do
    unzip -qo "$archives/$asset" -d "$staged_fonts" </dev/null || {
      rm -rf -- "$staging"
      return 1
    }
  done
  printf '%s\n' "$NERD_FONTS_VERSION" >"$staged_fonts/installed-version"

  if [[ -e "$FONT_DIR" || -L "$FONT_DIR" ]]; then
    mv -- "$FONT_DIR" "$previous"
  fi
  if ! mv -- "$staged_fonts" "$FONT_DIR"; then
    [[ -e "$previous" || -L "$previous" ]] && mv -- "$previous" "$FONT_DIR"
    rm -rf -- "$staging"
    return 1
  fi
  if command -v fc-cache >/dev/null 2>&1 && ! fc-cache -f "$FONT_DIR"; then
    rm -rf -- "$FONT_DIR"
    [[ -e "$previous" || -L "$previous" ]] && mv -- "$previous" "$FONT_DIR"
    rm -rf -- "$staging"
    return 1
  fi
  # Homebrew's glib puts gsettings on PATH on macOS, where no GNOME schema
  # exists; setting the key there fails, so set it only where the key exists
  # and is writable. `writable` prints true or false; it exits 0 for both.
  if command -v gsettings >/dev/null 2>&1 &&
    [[ "$(gsettings writable org.gnome.desktop.interface monospace-font-name 2>/dev/null)" == true ]]; then
    if ! gsettings set org.gnome.desktop.interface monospace-font-name "$DEFAULT_FONT"; then
      rm -rf -- "$FONT_DIR"
      [[ -e "$previous" || -L "$previous" ]] && mv -- "$previous" "$FONT_DIR"
      rm -rf -- "$staging"
      return 1
    fi
  fi
  rm -rf -- "$staging"
  log_success "Installed Nerd Fonts $NERD_FONTS_VERSION."
}

if [[ "${FONT_INSTALL_SOURCE_ONLY:-0}" != 1 ]]; then
  install_fonts
fi
