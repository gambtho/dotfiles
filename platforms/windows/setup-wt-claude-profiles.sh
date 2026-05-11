#!/usr/bin/env bash
# platforms/windows/setup-wt-claude-profiles.sh
#
# Add Windows Terminal profiles for the Claude + tmux workflow.
#
# Two profile flavors:
#   - devcontainer: project has .devcontainer/ → runs `claude-devcontainer-up`
#                   which brings the container up and attaches a tmux session
#                   inside it.
#   - plain:        project has no .devcontainer/ → runs `tmux new -A -s claude`
#                   directly in WSL at the project root.
#
# Plus one generic "🤖 Claude (attach VSCode)" profile that exec's into a
# running VSCode-launched devcontainer.
#
# Run from inside WSL. Auto-detects Windows username, settings.json path,
# and WSL distro name.
#
# Usage:
#   ./setup-wt-claude-profiles.sh                   # interactive, defaults
#   ./setup-wt-claude-profiles.sh -r ~/code         # different project root
#   ./setup-wt-claude-profiles.sh --flavors plain   # only emit plain profiles
#   ./setup-wt-claude-profiles.sh --include slab*   # auto-yes anything matching
#   ./setup-wt-claude-profiles.sh --exclude '*-old' # extra exclude pattern
#   ./setup-wt-claude-profiles.sh --include-all     # disable default skips
#   ./setup-wt-claude-profiles.sh --dry-run         # show diff, don't write
#   ./setup-wt-claude-profiles.sh --yes             # auto-yes every candidate
#
# Per-project prompt answers:
#   y = add this profile
#   N = skip (default)
#   a = yes to all remaining
#   s = skip all remaining; write what we have so far
#   q = quit; write nothing
#
# Idempotent: matches existing Claude profiles by name and reuses their guid,
# so re-runs don't churn settings.json.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
PROJECT_ROOT="${HOME}/workspace"
DRY_RUN=0
ASSUME_YES=0
INCLUDE_ALL=0
FLAVORS="devcontainer,plain"
declare -a EXTRA_EXCLUDES=()
declare -a INCLUDE_GLOBS=()
# Default skip patterns. Catches the user's `*-worktree*` convention.
# Dirs without a .git/ are also filtered later as a generic noise-filter.
declare -a DEFAULT_EXCLUDES=('*-worktree' '*-worktree[0-9]*' '*-worktree-*')

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--project-root) PROJECT_ROOT="$2"; shift 2 ;;
    -s|--shell)        LOGIN_SHELL="$2"; shift 2 ;;
    -n|--dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    --flavors)         FLAVORS="$2"; shift 2 ;;
    --include)         INCLUDE_GLOBS+=("$2"); shift 2 ;;
    --exclude)         EXTRA_EXCLUDES+=("$2"); shift 2 ;;
    --include-all)     INCLUDE_ALL=1; shift ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

WANT_DEVCONTAINER=0
WANT_PLAIN=0
for f in ${FLAVORS//,/ }; do
  case "$f" in
    devcontainer) WANT_DEVCONTAINER=1 ;;
    plain)        WANT_PLAIN=1 ;;
    *) echo "unknown flavor: $f (valid: devcontainer, plain)" >&2; exit 2 ;;
  esac
done
(( WANT_DEVCONTAINER || WANT_PLAIN )) || { echo "--flavors selected nothing" >&2; exit 2; }

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
info()  { printf '%s%s%s\n' "$C_INFO" "$*" "$C_OFF"; }
ok()    { printf '%s%s%s\n' "$C_OK"   "$*" "$C_OFF"; }
warn()  { printf '%s%s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()   { printf '%s%s%s\n' "$C_ERR"  "$*" "$C_OFF" >&2; exit 1; }
dim()   { printf '%s%s%s\n' "$C_DIM"  "$*" "$C_OFF"; }

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
info "Scanning $PROJECT_ROOT …"

# ── Discover candidates ──────────────────────────────────────────────────────
# A candidate is a direct subdirectory of $PROJECT_ROOT that:
#   - is a git repo (has .git, file or dir — supports worktrees too)
#   - doesn't match a default-skip pattern (unless --include-all)
#   - doesn't match a --exclude pattern
#
# Each candidate is classified as "devcontainer" or "plain" by presence of
# .devcontainer/devcontainer.json or .devcontainer.json. Flavors filtered
# out by --flavors are dropped here, not at prompt time.
matches_any() {
  local name="$1"; shift
  local pat
  for pat in "$@"; do
    # shellcheck disable=SC2053 — glob matching is intentional
    [[ "$name" == $pat ]] && return 0
  done
  return 1
}

declare -a PROJ_PATHS=()
declare -a PROJ_NAMES=()
declare -a PROJ_FLAVORS=()

for d in "$PROJECT_ROOT"/*/; do
  [[ -d "$d" ]] || continue
  proj="${d%/}"
  name="$(basename "$proj")"

  # Generic noise filter: must be a git repo (worktrees use a .git file).
  [[ -e "$proj/.git" ]] || continue

  # Default skip patterns (disabled with --include-all).
  if (( ! INCLUDE_ALL )) && matches_any "$name" "${DEFAULT_EXCLUDES[@]}"; then
    continue
  fi
  # Extra excludes from CLI always apply.
  if (( ${#EXTRA_EXCLUDES[@]} )) && matches_any "$name" "${EXTRA_EXCLUDES[@]}"; then
    continue
  fi

  if [[ -f "$proj/.devcontainer/devcontainer.json" || -f "$proj/.devcontainer.json" ]]; then
    flavor="devcontainer"
    (( WANT_DEVCONTAINER )) || continue
  else
    flavor="plain"
    (( WANT_PLAIN )) || continue
  fi

  PROJ_PATHS+=("$proj")
  PROJ_NAMES+=("$name")
  PROJ_FLAVORS+=("$flavor")
done

[[ ${#PROJ_PATHS[@]} -gt 0 ]] || die "No candidate projects found under $PROJECT_ROOT (after filters)."

echo
info "Found ${#PROJ_PATHS[@]} candidate project(s):"
for i in "${!PROJ_PATHS[@]}"; do
  printf "  %s (%s)\n" "${PROJ_NAMES[$i]}" "${PROJ_FLAVORS[$i]}"
done
echo

# ── Per-project prompt ───────────────────────────────────────────────────────
declare -a PICKED_PATHS=()
declare -a PICKED_NAMES=()
declare -a PICKED_FLAVORS=()

# State across the loop: a=accept-all, s=skip-rest, q=quit.
ALL_MODE=""

# A project auto-accepts (without prompt) if:
#   - --yes was passed, OR
#   - its name matches any --include glob.
auto_yes() {
  local name="$1"
  (( ASSUME_YES )) && return 0
  if (( ${#INCLUDE_GLOBS[@]} )) && matches_any "$name" "${INCLUDE_GLOBS[@]}"; then
    return 0
  fi
  return 1
}

for i in "${!PROJ_PATHS[@]}"; do
  name="${PROJ_NAMES[$i]}"
  flavor="${PROJ_FLAVORS[$i]}"

  if [[ "$ALL_MODE" == "a" ]] || auto_yes "$name"; then
    PICKED_PATHS+=("${PROJ_PATHS[$i]}")
    PICKED_NAMES+=("$name")
    PICKED_FLAVORS+=("$flavor")
    dim "  ✓ $name ($flavor) — auto"
    continue
  fi

  while true; do
    read -r -p "Add profile for \"$name\" ($flavor)? [y/N/a/s/q] " ans
    case "${ans:-N}" in
      y|Y)
        PICKED_PATHS+=("${PROJ_PATHS[$i]}")
        PICKED_NAMES+=("$name")
        PICKED_FLAVORS+=("$flavor")
        break ;;
      n|N|"") break ;;
      a|A)
        PICKED_PATHS+=("${PROJ_PATHS[$i]}")
        PICKED_NAMES+=("$name")
        PICKED_FLAVORS+=("$flavor")
        ALL_MODE="a"; break ;;
      s|S) ALL_MODE="s"; break ;;
      q|Q) ALL_MODE="q"; break ;;
      *) echo "  (y=yes, N=no [default], a=yes-to-all, s=skip-rest, q=quit)" ;;
    esac
  done

  [[ "$ALL_MODE" == "s" || "$ALL_MODE" == "q" ]] && break
done

if [[ "$ALL_MODE" == "q" ]]; then
  warn "Aborted by user; settings.json untouched."
  exit 0
fi

[[ ${#PICKED_PATHS[@]} -gt 0 ]] || { warn "Nothing selected; settings.json untouched."; exit 0; }

echo
info "Selected ${#PICKED_PATHS[@]} project(s) for profile generation."

# ── Build new profile JSON ───────────────────────────────────────────────────
# Use the distribution NAME (portable) instead of a hardcoded GUID.
# Use the user's login shell so PATH/mise activation (zshrc) is sourced.
# Override with --shell if needed (e.g. machines where bash has mise activation).
LOGIN_SHELL_DEFAULT="$(basename "$(getent passwd "$USER" | cut -d: -f7)")"
LOGIN_SHELL="${LOGIN_SHELL:-$LOGIN_SHELL_DEFAULT}"
info "Login shell for spawned commands: $LOGIN_SHELL"

# Literal backslashes; jq will JSON-encode them once to "\\" in the output.
WSLEXE='C:\WINDOWS\system32\wsl.exe'

# Index existing profile GUIDs by name so re-runs are stable (no churn in
# settings.json from regenerated GUIDs each invocation).
EXISTING_NAMES_JSON="$(mktemp)"
trap 'rm -f "$EXISTING_NAMES_JSON"' EXIT
jq '.profiles.list // [] | map({(.name): .guid}) | add // {}' "$SETTINGS" > "$EXISTING_NAMES_JSON"

guid_for_name() {
  local name="$1"
  local existing
  existing=$(jq -r --arg n "$name" '.[$n] // empty' "$EXISTING_NAMES_JSON")
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
  else
    printf '{%s}' "$(uuidgen)"
  fi
}

NEW_PROFILES_JSON="$(mktemp)"
trap 'rm -f "$EXISTING_NAMES_JSON" "$NEW_PROFILES_JSON"' EXIT

{
  echo "["
  first=1
  for i in "${!PICKED_PATHS[@]}"; do
    proj="${PICKED_PATHS[$i]}"
    name="${PICKED_NAMES[$i]}"
    flavor="${PICKED_FLAVORS[$i]}"
    profile_name="🤖 Claude ($name)"
    guid="$(guid_for_name "$profile_name")"

    if [[ "$flavor" == "devcontainer" ]]; then
      cmd="$WSLEXE --distribution $DISTRO_NAME --cd $proj -- $LOGIN_SHELL -lc claude-devcontainer-up"
    else
      # Plain: just open tmux in the project dir. Reattaches if a "claude"
      # session already exists.
      cmd="$WSLEXE --distribution $DISTRO_NAME --cd $proj -- $LOGIN_SHELL -lc 'tmux new -A -s claude'"
    fi

    [[ $first -eq 0 ]] && echo ","
    first=0
    jq -n \
      --arg guid "$guid" \
      --arg name "$profile_name" \
      --arg tab "$name" \
      --arg cmd "$cmd" '{
        guid: $guid,
        name: $name,
        tabTitle: $tab,
        icon: "🤖",
        commandline: $cmd,
        hidden: false,
        suppressApplicationTitle: true
      }'
  done

  # Generic attach profile — always emitted (it's the safety net for VSCode
  # launches). Re-uses existing GUID on re-run.
  attach_name="🤖 Claude (attach VSCode)"
  attach_guid="$(guid_for_name "$attach_name")"
  attach_cmd="$WSLEXE --distribution $DISTRO_NAME -- $LOGIN_SHELL -lc \"docker exec -it \$(docker ps --filter 'label=devcontainer.local_folder' --format '{{.Names}}' | head -1) bash\""
  echo ","
  jq -n --arg guid "$attach_guid" --arg name "$attach_name" --arg cmd "$attach_cmd" '{
    guid: $guid,
    name: $name,
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
# (idempotent re-run), then append new ones. GUIDs are preserved across runs
# because guid_for_name() looks them up from the live settings.json first.
MERGED="$(mktemp)"
trap 'rm -f "$EXISTING_NAMES_JSON" "$NEW_PROFILES_JSON" "$MERGED"' EXIT

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

if diff -q "$SETTINGS" "$MERGED" >/dev/null; then
  ok "settings.json already up to date — nothing to write."
  exit 0
fi

if (( DRY_RUN )); then
  warn "--dry-run set; not writing. Merged file at: $MERGED (will be cleaned up on exit)"
  exit 0
fi

if (( ! ASSUME_YES )); then
  read -r -p "Apply these changes? [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ── Backup + write ───────────────────────────────────────────────────────────
ts="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SETTINGS}.bak-${ts}"
cp "$SETTINGS" "$BACKUP"
ok "Backup: $BACKUP"

cp "$MERGED" "$SETTINGS"
ok "Updated: $SETTINGS"

echo
ok "Done. Close ALL Windows Terminal windows and reopen — the new profiles will appear in the dropdown."
