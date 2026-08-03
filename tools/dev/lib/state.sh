#!/usr/bin/env bash
# Workspace records: one JSON file per working tree, keyed by the path digest.
#
# The state lock (locks/<workspace_id>.lock) is held across the read-compare-write
# in dev_state_commit and nothing else — no backend query, no container command,
# no event scan (ADR-1, ADR-3 trigger 4). Reconcile observes and computes with no
# lock held and calls in here only to commit.
#
# This file is sourced. It defines functions and does no work at source time.

dev_state_path() {
  printf '%s\n' "$DEV_STATE_ROOT/workspaces/$1.json"
}

dev_state_new() {
  local workspace_id=$1 slug=$2 session_name=$3 worktree=$4
  jq -c -n \
    --arg workspace_id "$workspace_id" \
    --arg slug "$slug" \
    --arg session_name "$session_name" \
    --arg worktree "$worktree" \
    '{
      v: 1,
      workspace_id: $workspace_id,
      session_name: $session_name,
      slug: $slug,
      worktree: $worktree,
      status: "unknown",
      boot_id: null,
      config_digest: null,
      applied_digest: null,
      container: {
        status: "none",
        kind: null,
        id: null,
        user: null,
        workdir: null,
        verified: false,
        up_exit_status: null,
        up_result: null,
        observed_at: null
      },
      agents: [],
      opened_at: null,
      last_seen: null,
      scanned_through: null,
      fold_gap: false,
      stopped_reason: null
    }'
}

dev_state_read() {
  local path
  path=$(dev_state_path "$1")
  [[ -f "$path" ]] || return 1
  cat "$path"
}

# Compare-and-swap. Exit 0 when new_json was written, 9 when the on-disk record
# no longer equals expected_json. An absent record equals an empty expectation.
dev_state_commit() {
  local workspace_id=$1 expected=$2 new=$3
  local path lock
  path=$(dev_state_path "$workspace_id")
  lock="$DEV_STATE_ROOT/locks/$workspace_id.lock"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/locks"
  {
    flock -x 9
    local current="" want="" tmp
    if [[ -f "$path" ]]; then
      # Canonical form on both sides: key order must not fake a mismatch.
      current=$(jq -S -c . <"$path")
    fi
    if [[ -n "$expected" ]]; then
      want=$(printf '%s' "$expected" | jq -S -c .)
    fi
    [[ "$current" == "$want" ]] || return 9
    tmp=$(mktemp "$path.XXXXXX")
    printf '%s\n' "$new" >"$tmp"
    mv -f "$tmp" "$path"
  } 9>"$lock"
}

dev_state_list() {
  local record
  for record in "$DEV_STATE_ROOT/workspaces"/*.json; do
    if [[ -f "$record" ]]; then
      printf '%s\n' "$record"
    fi
  done
  return 0
}

# dev_state_session_name <workspace_id> <fallback>
#
# The recorded session name wins over the resolver's proposal, always.
#
# `dev_resolve` derives a name from the slug and worktree basename, which is a
# GUESS: ADR-7's collision guard may have renamed this workspace to
# `<slug>--<basename>--<hash6>` when another working tree already held the
# plain name. That rename is durable — `workspace.opened` carries
# `session_name_actual` and the fold writes it into the record — so every later
# command must start from the record, not re-derive the guess.
#
# Re-deriving is what made a collided workspace unreachable: once the
# CONFLICTING session went away, `dev attach` looked up the plain name, found
# nothing, and reported no live session while the hashed one was still running;
# `dev open` then created a second session for the same working tree.
#
# The fallback is used only for a workspace with no record yet, i.e. the first
# `dev open`, which is exactly when the resolver's proposal is correct.
dev_state_session_name() {
  local workspace_id="$1" fallback="$2" record name
  if record=$(dev_state_read "$workspace_id" 2>/dev/null); then
    name=$(printf '%s' "$record" | jq -r '.session_name // ""')
    if [[ -n "$name" && "$name" != null ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}
