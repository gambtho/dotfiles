#!/usr/bin/env bash
# platforms/windows/wt-color-scheme.sh
#
# Install the Tokyo Night color scheme into Windows Terminal and make it the
# default for every profile.
#
# Why this exists: Windows Terminal ships no Tokyo Night built-in, and an
# unconfigured install falls back to Campbell. Herdr's UI theme
# (tools/herdr/config.toml.template) and Neovim's tokyonight-night then look
# deliberate while the surrounding terminal does not. This closes that gap so
# the whole terminal reads as one palette.
#
# Run from inside WSL.
#
# Usage:
#   ./wt-color-scheme.sh              # install and set as default
#   ./wt-color-scheme.sh --dry-run    # print the diff, write nothing
#   ./wt-color-scheme.sh --check      # exit 0 if already applied, 1 if not
#
# Idempotent: the scheme is matched by name, so re-runs replace it in place
# rather than appending duplicates.
#
# Profiles that set their own "colorScheme" are left alone -- an explicit
# per-profile choice outranks the default. The "Tmux" profile is one of these.
#
# Testing hook: WT_SETTINGS_PATH overrides settings.json discovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Source the profiles script for its atomic publish_settings/next_backup_path
# helpers and log functions. Its documented source-only hook loads definitions
# without running main.
WT_PROFILES_SOURCE_ONLY=1 source "$SCRIPT_DIR/setup-wt-claude-profiles.sh"

SCHEME_FILE="$SCRIPT_DIR/tokyo-night.wt-scheme.json"
SCHEME_NAME="Tokyo Night"

DRY_RUN=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h | --help)
      sed -n '2,26p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

command -v jq >/dev/null || die "jq is required (sudo apt install jq)."
[[ -f "$SCHEME_FILE" ]] || die "Missing scheme file: $SCHEME_FILE"

# ── Locate settings.json ──────────────────────────────────────────────────────
# Only WT_SETTINGS_PATH is honored here. Unlike the profiles script this needs
# no Windows username or WSL distro, so there is no all-three rule to enforce.
if [[ -n "${WT_SETTINGS_PATH:-}" ]]; then
  SETTINGS="$WT_SETTINGS_PATH"
  [[ -f "$SETTINGS" ]] || die "WT_SETTINGS_PATH does not exist: $SETTINGS"
else
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || die "Not inside WSL (\$WSL_DISTRO_NAME unset). Run this from a WSL shell."

  declare -a CANDIDATES=()
  while IFS= read -r -d '' name; do
    CANDIDATES+=("$name")
  done < <(
    find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d \
      -not -iname Public -not -iname Default -not -iname 'Default User' -not -iname 'All Users' \
      -printf '%f\0' 2>/dev/null
  )
  [[ ${#CANDIDATES[@]} -gt 0 ]] || die "No Windows user directory found under /mnt/c/Users."
  if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    WIN_USER="${CANDIDATES[0]}"
  else
    echo "Multiple Windows users found:"
    select WIN_USER in "${CANDIDATES[@]}"; do [[ -n "$WIN_USER" ]] && break; done
  fi

  LOCAL_PKGS="/mnt/c/Users/$WIN_USER/AppData/Local/Packages"
  SETTINGS=""
  for candidate in \
    "$LOCAL_PKGS/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" \
    "$LOCAL_PKGS/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json" \
    "/mnt/c/Users/$WIN_USER/AppData/Local/Microsoft/Windows Terminal/settings.json"; do
    if [[ -f "$candidate" ]]; then
      SETTINGS="$candidate"
      break
    fi
  done
  [[ -n "$SETTINGS" ]] || die "Could not find Windows Terminal settings.json for user $WIN_USER."
fi

info "settings.json: $SETTINGS"

# ── Merge ────────────────────────────────────────────────────────────────────
# Windows Terminal tolerates JSONC, but a settings.json it has written itself is
# plain JSON. jq would reject comments, so a comment-bearing file is refused
# rather than silently mangled.
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  die "settings.json is not plain JSON (comments?). Refusing to rewrite it: $SETTINGS"
fi

MERGED="$(mktemp)"
trap 'rm -f -- "$MERGED"' EXIT

jq --slurpfile scheme "$SCHEME_FILE" --arg name "$SCHEME_NAME" '
  # Drop every entry carrying this name, then append exactly one. Replacing in
  # place would preserve duplicates: settings.json can already hold two entries
  # named "Tokyo Night" (hand-edited, or merged from two sources), and Windows
  # Terminal picking between them is not something to leave to chance. Other
  # schemes keep their order.
  .schemes = (((.schemes // []) | map(select(.name != $name))) + [$scheme[0]])
  # Default for every profile that has not chosen its own.
  | .profiles.defaults = ((.profiles.defaults // {}) + {colorScheme: $name})
' "$SETTINGS" >"$MERGED"

jq -e . "$MERGED" >/dev/null || die "Refusing to publish: merged settings are not valid JSON."

# Compare semantically, not byte-for-byte. jq reformats the whole document --
# indentation and key order -- so `cmp` against a hand-edited or
# Windows-Terminal-written settings.json reports a difference even when the
# scheme and the default are already exactly right, and the script would
# rewrite the file (and cut a backup) on every single run.
#
# `any` would also be wrong here for the duplicate case above: it reports
# "already applied" while a second entry of the same name is still present, so
# the normalisation would never run. Require exactly one.
already_applied() {
  jq -e --slurpfile scheme "$SCHEME_FILE" --arg name "$SCHEME_NAME" '
    (((.schemes // []) | map(select(.name == $name))) == [$scheme[0]])
    and (.profiles.defaults.colorScheme? == $name)
  ' "$SETTINGS" >/dev/null 2>&1
}

if already_applied; then
  ok "Already applied: \"$SCHEME_NAME\" is installed and is the profile default."
  exit 0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  warn "Not applied: \"$SCHEME_NAME\" is missing or is not the profile default."
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Dry run -- would write:"
  diff -u "$SETTINGS" "$MERGED" || true
  exit 0
fi

publish_settings "$MERGED" "$SETTINGS" || die "Failed to publish settings.json."
ok "Applied \"$SCHEME_NAME\" and set it as the default for all profiles."
dim "Windows Terminal reloads settings.json automatically."

# Profiles with an explicit colorScheme keep it. Name them so the result is not
# a surprise when one tab still looks different.
OVERRIDES="$(jq -r --arg name "$SCHEME_NAME" '
  [.profiles.list[]? | select(.colorScheme? and .colorScheme != $name) | .name] | join(", ")
' "$SETTINGS")"
if [[ -n "$OVERRIDES" ]]; then
  dim "Profiles keeping their own scheme: $OVERRIDES"
fi
