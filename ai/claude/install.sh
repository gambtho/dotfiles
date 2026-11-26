#!/usr/bin/env bash
# Install or re-pin the gambtho-skills plugin for Claude Code at the pinned tag.
#
# The same tag is pinned for Pi in ai/pi/settings.json; `make skills-pin`
# rewrites both and tests/dependency_pins.bats keeps them equal. Once
# `claude plugin list` shows the plugin at the pinned version, skill links in
# ~/.claude/skills that point into ~/.dotfiles are removed. Their names are
# appended to the legacy-links file first, so they can be recreated.
set -euo pipefail

SKILLS_TAG=v0.2.0
SKILLS_REPO=gambtho/gambtho-skills
MARKETPLACE=gambtho-skills
PLUGIN=gambtho-skills@gambtho-skills

MODE=apply
if (($# > 1)) || { (($# == 1)) && [[ "$1" != --check ]]; }; then
  echo "Usage: ${0##*/} [--check]" >&2
  exit 2
fi
[[ $# -eq 0 ]] || MODE=check

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
LEGACY_LOG=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/claude-legacy-links.txt
VERSION=${SKILLS_TAG#v}

# shellcheck source=libexec/lib/tool-path.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../libexec/lib/tool-path.sh"
prepend_managed_tool_path
check_claude_tool
if ! command -v claude >/dev/null 2>&1; then
  echo "Claude Code is not set up on this machine; skipping the $MARKETPLACE plugin."
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to install the $MARKETPLACE plugin for Claude Code." >&2
  exit 1
fi

# Prints "<repo> <ref>" for the marketplace, or nothing when it is absent.
marketplace_pin() {
  claude plugin marketplace list --json |
    jq -r --arg name "$MARKETPLACE" '.[] | select(.name == $name) | "\(.repo // "") \(.ref // "")"'
}

# Prints "<version> <enabled>" for the user-scope plugin, or nothing when it is
# absent. A project-scope install does not replace the global links.
plugin_state() {
  claude plugin list --json |
    jq -r --arg id "$PLUGIN" '.[] | select(.id == $id and .scope == "user") | "\(.version // "") \(.enabled)"'
}

# Lexically resolve . and .. so dangling links can be classified too.
normalize_path() {
  local part
  local -a parts=()
  set -f
  local IFS=/
  for part in $1; do
    case "$part" in
      '' | .) ;;
      ..) ((${#parts[@]} == 0)) || unset "parts[$((${#parts[@]} - 1))]" ;;
      *) parts+=("$part") ;;
    esac
  done
  set +f
  printf '/%s' ${parts[@]+"${parts[@]}"}
  echo
}

# Skill links that point into ~/.dotfiles, by name.
legacy_links() {
  local skills_dir="$CLAUDE_DIR/skills" link target physical_skills dotfiles physical_dotfiles=""
  [[ -d "$skills_dir" ]] || return 0
  physical_skills=$(cd -P "$skills_dir" && pwd)
  dotfiles=$(normalize_path "$HOME/.dotfiles")
  [[ ! -d "$HOME/.dotfiles" ]] || physical_dotfiles=$(cd -P "$HOME/.dotfiles" && pwd)
  for link in "$skills_dir"/*; do
    [[ -L "$link" ]] || continue
    target=$(readlink "$link")
    [[ "$target" == /* ]] || target="$physical_skills/$target"
    target=$(normalize_path "$target")
    if [[ "$target" == "$dotfiles" || "$target" == "$dotfiles"/* ]] ||
      [[ -n "$physical_dotfiles" && ("$target" == "$physical_dotfiles" || "$target" == "$physical_dotfiles"/*) ]]; then
      basename "$link"
    fi
  done
}

pin=$(marketplace_pin)
state=$(plugin_state)
repin=false
if [[ -n "$pin" && "$pin" != "$SKILLS_REPO $SKILLS_TAG" ]]; then
  repin=true
elif [[ -n "$state" && "${state%% *}" != "$VERSION" ]]; then
  repin=true
fi

if [[ "$MODE" == check ]]; then
  if [[ "$repin" == true ]]; then
    echo "[dry-run] Would re-pin the $MARKETPLACE marketplace (now: ${pin:-absent}) to $SKILLS_REPO@$SKILLS_TAG and reinstall $PLUGIN"
  elif [[ -z "$pin" ]]; then
    echo "[dry-run] Would add the $MARKETPLACE marketplace at $SKILLS_REPO@$SKILLS_TAG and install $PLUGIN"
  elif [[ -z "$state" ]]; then
    echo "[dry-run] Would install $PLUGIN $VERSION"
  else
    echo "$PLUGIN is at $VERSION."
  fi
  links=$(legacy_links)
  [[ -z "$links" ]] || echo "[dry-run] Would then remove skill links into ~/.dotfiles: ${links//$'\n'/ }"
  exit 0
fi

if [[ "$repin" == true ]]; then
  echo "Re-pinning the $MARKETPLACE marketplace from ${pin:-?} to $SKILLS_REPO@$SKILLS_TAG..."
  # Removing the marketplace also uninstalls its plugin. Only the user
  # declaration is ours to change; one in project settings is reported.
  if ! claude plugin marketplace remove "$MARKETPLACE" --scope user; then
    echo "The $MARKETPLACE marketplace at ${pin:-?} is not declared in user settings; change it where it is declared. Keeping the old skill links." >&2
    exit 1
  fi
  pin=""
fi
if [[ -z "$pin" ]]; then
  claude plugin marketplace add "$SKILLS_REPO@$SKILLS_TAG" --scope user
fi
state=$(plugin_state)
if [[ -z "$state" ]]; then
  claude plugin install "$PLUGIN" --scope user
  state=$(plugin_state)
fi

if [[ "$state" != "$VERSION true" ]]; then
  echo "Claude Code shows $PLUGIN as '${state:-absent}', not version $VERSION enabled; keeping the old skill links." >&2
  echo "If it is disabled, run: claude plugin enable $PLUGIN" >&2
  exit 1
fi
echo "Claude Code has $PLUGIN $VERSION."

links=$(legacy_links)
if [[ -n "$links" ]]; then
  mkdir -p "$(dirname "$LEGACY_LOG")"
  {
    [[ ! -f "$LEGACY_LOG" ]] || cat "$LEGACY_LOG"
    echo "$links"
  } | sort -u >"$LEGACY_LOG.tmp"
  mv "$LEGACY_LOG.tmp" "$LEGACY_LOG"
  while IFS= read -r name; do
    rm -- "$CLAUDE_DIR/skills/$name"
    echo "Removed legacy Claude skill link: $name"
  done <<<"$links"
  echo "Recorded the removed link names in $LEGACY_LOG."
fi
