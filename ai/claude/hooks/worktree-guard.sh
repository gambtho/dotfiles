#!/usr/bin/env bash
# PreToolUse hook: deny Edit/Write/NotebookEdit when the target file's repo is
# the primary checkout, so implementation happens in a linked worktree.
# Fails open: any unexpected condition allows the edit.
set -u

allow() { exit 0; }

[ "${CLAUDE_WORKTREE_GUARD:-on}" = "off" ] && allow

input=$(cat 2>/dev/null) || allow
command -v jq >/dev/null 2>&1 || allow
path=$(printf '%s' "$input" |
  jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' \
    2>/dev/null) || allow
[ -n "$path" ] || allow

# Resolve symlinks (including a symlinked final component, e.g. the live
# ~/.claude/settings.json) so the write is attributed to the repo it lands in.
# GNU readlink -m tolerates missing components; realpath and Python provide
# portable fallbacks for macOS/BSD. On failure, keep the original path.
canonical=$(readlink -m -- "$path" 2>/dev/null) || canonical=""
if [ -z "$canonical" ] && command -v realpath >/dev/null 2>&1; then
  canonical=$(realpath "$path" 2>/dev/null) || canonical=""
fi
if [ -z "$canonical" ] && command -v python3 >/dev/null 2>&1; then
  canonical=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$path" 2>/dev/null) || canonical=""
fi
[ -n "$canonical" ] && path="$canonical"

# Nearest existing ancestor (the file or its directories may not exist yet).
dir="$path"
while [ ! -d "$dir" ]; do
  parent=$(dirname "$dir")
  [ "$parent" = "$dir" ] && allow
  dir="$parent"
done

command -v git >/dev/null 2>&1 || allow
repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || allow
repo_root=$(cd "$repo_root" && pwd -P) || allow

allowfile="$HOME/.claude/worktree-guard-allow"
if [ -f "$allowfile" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in "~"*) line="$HOME${line#\~}" ;; esac
    resolved=$(cd "$line" 2>/dev/null && pwd -P) || continue
    [ "$resolved" = "$repo_root" ] && allow
  done <"$allowfile"
fi

git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || allow
common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || allow
# A relative --git-common-dir is relative to the `git -C` directory, not the
# repo root (e.g. ../../.git from a subdirectory).
case "$common_dir" in
  /*) ;;
  *) common_dir="$dir/$common_dir" ;;
esac
git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || allow
common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || allow

[ "$git_dir" = "$common_dir" ] || allow

reason="Edits are blocked in the primary checkout of $repo_root. Create a \
linked worktree first (superpowers:using-git-worktrees skill). If this repo \
must exceptionally be edited in place, add its path to \
~/.claude/worktree-guard-allow."
jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
