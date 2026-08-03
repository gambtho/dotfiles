#!/usr/bin/env bash

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_REPO_ROOT="${DEV_REPO_ROOT:-$HOME/workspace}"

if ! declare -F dev_slug_for_path >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$DEV_DOTFILES_ROOT/bin/common.sh"
fi

dev_resolve_workspace_id() {
  local path="$1" real
  real="$(cd "$path" 2>/dev/null && pwd -P)" || {
    printf 'no such directory: %s\n' "$path" >&2
    return 1
  }
  printf '%s' "$real" | sha256sum | cut -d' ' -f1
}

# git may report either path relative to the directory it ran in, so both are
# made absolute before they are compared. A non-git directory counts as primary.
dev_resolve_is_primary() {
  local path="$1" gitdir commondir
  gitdir="$(cd "$path" && git rev-parse --git-dir 2>/dev/null)" || return 0
  [[ -n "$gitdir" ]] || return 0
  commondir="$(cd "$path" && git rev-parse --git-common-dir 2>/dev/null)" || return 0
  gitdir="$(cd "$path" && cd "$gitdir" && pwd -P)" || return 0
  commondir="$(cd "$path" && cd "$commondir" && pwd -P)" || return 0
  [[ "$gitdir" == "$commondir" ]]
}

dev_resolve_session_name() {
  local slug="$1" worktree="$2"
  if dev_resolve_is_primary "$worktree"; then
    printf '%s\n' "$slug"
  else
    printf '%s--%s\n' "$slug" "$(basename "$worktree")"
  fi
}

# Unmatched globs stay literal under bash defaults; [[ -d ]] discards them.
dev_resolve_candidates() {
  local name="$1" dir
  for dir in "$DEV_REPO_ROOT/$name" \
    "$DEV_REPO_ROOT"/*/.worktrees/"$name" \
    "$DEV_REPO_ROOT"/*/.claude/worktrees/"$name"; do
    [[ -d "$dir" ]] && printf '%s\n' "$dir"
  done
  return 0
}

dev_resolve() {
  local name="${1:-}" worktree candidates count slug workspace_id session_name is_primary
  if [[ -z "$name" ]]; then
    worktree="$(git rev-parse --show-toplevel 2>/dev/null)" || worktree=""
    [[ -n "$worktree" ]] || worktree="$PWD"
  else
    candidates="$(dev_resolve_candidates "$name")"
    count="$(printf '%s' "$candidates" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
      printf 'unknown workspace: %s\n' "$name" >&2
      printf 'searched %s, %s/*/.worktrees and %s/*/.claude/worktrees\n' \
        "$DEV_REPO_ROOT" "$DEV_REPO_ROOT" "$DEV_REPO_ROOT" >&2
      return 4
    fi
    # ADR-7: ambiguity is an error, never a guess. Picking the first match is
    # how a user ends up running an agent against the wrong branch.
    if [[ "$count" -gt 1 ]]; then
      printf 'ambiguous workspace name: %s\n' "$name" >&2
      printf '%s\n' "$candidates" >&2
      printf 'disambiguate by cd-ing into the intended tree and running dev with no argument, or by renaming one tree\n' >&2
      return 3
    fi
    worktree="$candidates"
  fi
  worktree="$(cd "$worktree" 2>/dev/null && pwd -P)" || {
    printf 'no such directory: %s\n' "$worktree" >&2
    return 1
  }
  slug="$(dev_slug_for_path "$worktree")" || return 1
  workspace_id="$(dev_resolve_workspace_id "$worktree")" || return 1
  session_name="$(dev_resolve_session_name "$slug" "$worktree")"
  if dev_resolve_is_primary "$worktree"; then is_primary=true; else is_primary=false; fi
  jq -c -n --arg slug "$slug" --arg worktree "$worktree" \
    --arg workspace_id "$workspace_id" --arg session_name "$session_name" \
    --argjson is_primary "$is_primary" \
    '{slug: $slug, worktree: $worktree, workspace_id: $workspace_id,
      session_name: $session_name, is_primary: $is_primary}'
}
