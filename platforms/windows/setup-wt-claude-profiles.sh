#!/usr/bin/env bash
# platforms/windows/setup-wt-claude-profiles.sh
#
# Add Windows Terminal profiles for the devcontainer + tmux + Claude workflow:
#   - one "🤖 Claude (<project>)" profile per project under <root> with .devcontainer/
#   - one generic "🤖 Claude (attach VSCode)" profile that exec's into a running
#     VSCode-launched devcontainer
#
# Run from inside WSL. Auto-detects:
#   - Windows username (under /mnt/c/Users)
#   - Windows Terminal settings.json (stable / Preview / unpackaged)
#   - WSL distro name (from $WSL_DISTRO_NAME)
#
# Usage:
#   ./setup-wt-claude-profiles.sh                  # interactive, default root ~/workspace
#   ./setup-wt-claude-profiles.sh -r ~/code        # different project root
#   ./setup-wt-claude-profiles.sh --dry-run        # show diff, don't write
#   ./setup-wt-claude-profiles.sh --yes            # skip confirmations
#
# Idempotent: matches existing Claude profiles by name and overwrites them
# (preserving their guid) instead of duplicating.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PROJECT_ROOT="${HOME}/workspace"
DRY_RUN=0
ASSUME_YES=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root) PROJECT_ROOT="$2"; shift 2 ;;
    -s|--shell)        LOGIN_SHELL="$2"; shift 2 ;;
    -n|--dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
info()  { printf '%s%s%s\n' "$C_INFO" "$*" "$C_OFF"; }
ok()    { printf '%s%s%s\n' "$C_OK"   "$*" "$C_OFF"; }
warn()  { printf '%s%s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()   { printf '%s%s%s\n' "$C_ERR"  "$*" "$C_OFF" >&2; exit 1; }

confirm() {
  (( ASSUME_YES )) && return 0
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Sanity checks ────────────────────────────────────────────────────────────
[[ -n "${WSL_DISTRO_NAME:-}" ]] || die "Not inside WSL (\$WSL_DISTRO_NAME unset). Run this from a WSL shell."
command -v jq      >/dev/null || die "jq is required (sudo apt install jq)."
command -v python3 >/dev/null || die "python3 is required."
command -v uuidgen >/dev/null || die "uuidgen is required (util-linux)."

# ── Detect Windows username ──────────────────────────────────────────────────
mapfile -t CANDIDATES < <(
  find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d \
    -not -iname Public -not -iname Default -not -iname 'Default User' -not -iname 'All Users' \
    -printf '%f\n' 2>/dev/null
)
if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
  WIN_USER="${CANDIDATES[0]}"
elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  die "No Windows user directory found under /mnt/c/Users."
else
  echo "Multiple Windows users found:"
  select WIN_USER in "${CANDIDATES[@]}"; do [[ -n "$WIN_USER" ]] && break; done
fi
info "Windows user: $WIN_USER"

# ── Locate settings.json ─────────────────────────────────────────────────────
LOCAL_PKGS="/mnt/c/Users/$WIN_USER/AppData/Local/Packages"
STABLE="$LOCAL_PKGS/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
PREVIEW="$LOCAL_PKGS/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json"
UNPACKAGED="/mnt/c/Users/$WIN_USER/AppData/Local/Microsoft/Windows Terminal/settings.json"

SETTINGS=""
for p in "$STABLE" "$PREVIEW" "$UNPACKAGED"; do
  [[ -f "$p" ]] && { SETTINGS="$p"; break; }
done
[[ -n "$SETTINGS" ]] || die "Couldn't find Windows Terminal settings.json. Checked stable, Preview, and unpackaged paths."
info "settings.json: $SETTINGS"

# ── Detect WSL distro ────────────────────────────────────────────────────────
DISTRO_NAME="$WSL_DISTRO_NAME"
info "WSL distro: $DISTRO_NAME"

# ── Resolve project root ─────────────────────────────────────────────────────
PROJECT_ROOT="${PROJECT_ROOT/#\~/$HOME}"
[[ -d "$PROJECT_ROOT" ]] || die "Project root does not exist: $PROJECT_ROOT"
info "Scanning $PROJECT_ROOT for .devcontainer/ …"

mapfile -t PROJECTS < <(
  for d in "$PROJECT_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/.devcontainer/devcontainer.json" || -f "$d/.devcontainer.json" ]]; then
      printf '%s\n' "${d%/}"
    fi
  done
)

[[ ${#PROJECTS[@]} -gt 0 ]] || die "No devcontainer projects found under $PROJECT_ROOT."

echo
echo "Found ${#PROJECTS[@]} devcontainer project(s):"
for i in "${!PROJECTS[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "$(basename "${PROJECTS[$i]}")"
done
echo

if (( ! ASSUME_YES )); then
  read -r -p "Numbers to EXCLUDE (space-separated, blank for none): " EXCLUDE
  if [[ -n "$EXCLUDE" ]]; then
    declare -A excl
    for n in $EXCLUDE; do excl[$((n-1))]=1; done
    KEEP=()
    for i in "${!PROJECTS[@]}"; do
      [[ -z "${excl[$i]:-}" ]] && KEEP+=("${PROJECTS[$i]}")
    done
    PROJECTS=("${KEEP[@]}")
  fi
fi
[[ ${#PROJECTS[@]} -gt 0 ]] || die "Nothing to do (all projects excluded)."

# ── Build new profile JSON ───────────────────────────────────────────────────
# Use the distribution NAME (portable) instead of a hardcoded GUID.
# Use the user's login shell so PATH/mise activation (zshrc) is sourced.
# Override with --shell if needed (e.g. machines where bash has mise activation).
LOGIN_SHELL_DEFAULT="$(basename "$(getent passwd "$USER" | cut -d: -f7)")"
LOGIN_SHELL="${LOGIN_SHELL:-$LOGIN_SHELL_DEFAULT}"
info "Login shell for spawned commands: $LOGIN_SHELL"

# Literal backslashes; jq will JSON-encode them once to "\\" in the output.
WSLEXE='C:\WINDOWS\system32\wsl.exe'
NEW_PROFILES_JSON="$(mktemp)"
trap 'rm -f "$NEW_PROFILES_JSON"' EXIT

{
  echo "["
  first=1
  for proj in "${PROJECTS[@]}"; do
    name="$(basename "$proj")"
    guid="$(uuidgen)"
    cmd="$WSLEXE --distribution $DISTRO_NAME --cd $proj -- $LOGIN_SHELL -lc claude-devcontainer-up"
    [[ $first -eq 0 ]] && echo ","
    first=0
    jq -n --arg guid "{$guid}" --arg name "🤖 Claude ($name)" --arg tab "$name" --arg cmd "$cmd" '{
      guid: $guid,
      name: $name,
      tabTitle: $tab,
      icon: "🤖",
      commandline: $cmd,
      hidden: false,
      suppressApplicationTitle: true
    }'
  done
  # Generic attach profile
  attach_guid="$(uuidgen)"
  attach_cmd="$WSLEXE --distribution $DISTRO_NAME -- $LOGIN_SHELL -lc \"cid=\\\$(docker ps --filter 'label=devcontainer.local_folder' --format '{{.Names}}' | head -1); if [ -z \\\"\\\$cid\\\" ]; then echo 'No running devcontainer found' >&2; exit 1; fi; docker exec -it \\\$cid bash\""
  echo ","
  jq -n --arg guid "{$attach_guid}" --arg cmd "$attach_cmd" '{
    guid: $guid,
    name: "🤖 Claude (attach VSCode)",
    icon: "🤖",
    commandline: $cmd,
    hidden: false,
    suppressApplicationTitle: true
  }'
  echo "]"
} > "$NEW_PROFILES_JSON"

jq empty "$NEW_PROFILES_JSON" || die "Generated profile JSON is invalid (bug)."

# ── Merge into settings.json ─────────────────────────────────────────────────
# Strategy: drop any existing profile whose name matches one of the new names
# (idempotent re-run), then append new ones.
MERGED="$(mktemp)"
trap 'rm -f "$NEW_PROFILES_JSON" "$MERGED"' EXIT

# Detect existing indent (WT defaults to 4 spaces); fall back to 4.
INDENT=4
if head -5 "$SETTINGS" | grep -q '^  "'; then INDENT=2; fi

jq --indent "$INDENT" --slurpfile new "$NEW_PROFILES_JSON" '
  .profiles.list = (
    (.profiles.list // [])
    | map(select(.name as $n | ($new[0] | map(.name) | index($n)) | not))
  ) + $new[0]
' "$SETTINGS" > "$MERGED"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MERGED" \
  || die "Merged settings.json failed JSON validation."

# ── Diff + confirm ───────────────────────────────────────────────────────────
echo
info "──── diff ────"
diff -u "$SETTINGS" "$MERGED" || true
echo

if (( DRY_RUN )); then
  warn "--dry-run set; not writing. Merged file at: $MERGED (will be cleaned up on exit)"
  exit 0
fi

confirm "Apply these changes?" || die "Aborted."

# ── Backup + write ───────────────────────────────────────────────────────────
ts="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SETTINGS}.bak-${ts}"
cp "$SETTINGS" "$BACKUP"
ok "Backup: $BACKUP"

cp "$MERGED" "$SETTINGS"
ok "Updated: $SETTINGS"

echo
ok "Done. Close ALL Windows Terminal windows and reopen — the new profiles will appear in the dropdown."
