#!/usr/bin/env bash
# PreToolUse hook: deny Edit/Write/NotebookEdit when the target file's repo is
# checked out on its default branch, so implementation happens in a worktree.
# Fails open: any unexpected condition allows the edit.
set -u

allow() { exit 0; }

[ "${CLAUDE_WORKTREE_GUARD:-on}" = "off" ] && allow

input=$(cat 2>/dev/null) || allow
command -v jq >/dev/null 2>&1 || allow
path=$(printf '%s' "$input" \
  | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' \
    2>/dev/null) || allow
[ -n "$path" ] || allow

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

# Detached HEAD counts as "not on the default branch".
branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || allow

default=$(git -C "$dir" symbolic-ref --quiet --short \
  refs/remotes/origin/HEAD 2>/dev/null || true)
default=${default#origin/}
if [ -z "$default" ]; then
  if git -C "$dir" show-ref --verify --quiet refs/heads/main; then
    default=main
  elif git -C "$dir" show-ref --verify --quiet refs/heads/master; then
    default=master
  else
    allow
  fi
fi

[ "$branch" = "$default" ] || allow

reason="Edits are blocked on the default branch ($default) of $repo_root. \
Create a worktree first (superpowers:using-git-worktrees skill). If this repo \
is intentionally edited on its default branch, add its path to \
~/.claude/worktree-guard-allow."
jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
