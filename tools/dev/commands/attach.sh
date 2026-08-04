# shellcheck shell=bash
# dev attach — attach only. Never creates, never repairs, takes no operation lock.

dev_cmd_attach() {
  local arg="${1:-}"
  if [[ $# -gt 1 || "$arg" == -* ]]; then
    printf 'usage: dev attach [<name>]\n' >&2
    return 2
  fi

  local resolved session worktree ws_id slug query live
  resolved=$(dev_resolve "$arg") || return $?
  ws_id=$(jq -r '.workspace_id' <<<"$resolved")
  slug=$(jq -r '.slug' <<<"$resolved")
  worktree=$(jq -r '.worktree' <<<"$resolved")
  # The record's name wins. A workspace the ADR-7 guard renamed keeps that name
  # for life; re-deriving the resolver's proposal here is what made such a
  # workspace unattachable once the session it originally collided with went
  # away — the plain name resolved to nothing while the hashed session ran on.
  session=$(dev_state_session_name "$ws_id" "$(jq -r '.session_name' <<<"$resolved")")

  query=$(dev_backend_query "$session")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    live=$(jq -r '.worktree // ""' <<<"$query")
    if [[ "$live" != "$worktree" ]]; then
      # Still reachable with no record: a first-ever `dev attach` against a name
      # another working tree already holds. Fall through to the hashed form.
      session="$slug--$(basename "$worktree")--${ws_id:0:6}"
      query=$(dev_backend_query "$session")
    fi
  fi

  if [[ "$(jq -r '.exists' <<<"$query")" != "true" ]]; then
    printf 'dev: no live session for %s; run `dev %s` to create it\n' "$session" "$slug" >&2
    return 4
  fi

  dev_open_attach "$session"
}
