# shellcheck shell=bash
# dev stop — the only destructive verb in Phase 1.

# The dispatcher sources exactly one command file per verb (bin/dev), but
# removing the session index before the kill delegates to open.sh's
# dev_open_session_index_path. Guarded so a double-source (the test helper
# sources both files) stays harmless -- open.sh only defines functions.
if ! declare -F dev_open_session_index_path >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$DEV_DOTFILES_ROOT/tools/dev/commands/open.sh"
fi

dev_stop_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$DEV_STOP_WS_ID" "$DEV_STOP_SLUG" \
    "$DEV_STOP_SESSION" "$DEV_STOP_WORKTREE" "$data")
  dev_event_append "$line"
}

dev_stop_locked() {
  local record="$1" stop_container="$2"
  local query cid index saved

  query=$(dev_backend_query "$DEV_STOP_SESSION")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    # Delete the hook's envelope lookup first, so the session-closed hook that
    # fires a moment from now exits silently and does not double-emit. Keep the
    # contents: if the kill fails there is no stop to suppress, and leaving the
    # index deleted would silently disarm the hook for the rest of the session's
    # life -- the eventual close would then be observed only by a later reconcile.
    index=$(dev_open_session_index_path "$DEV_STOP_SESSION")
    saved=$(cat "$index" 2>/dev/null || true)
    rm -f "$index"

    if ! dev_backend_kill "$DEV_STOP_SESSION"; then
      if [[ -n "$saved" ]]; then
        printf '%s\n' "$saved" >"$index"
      fi
      printf 'dev: could not end session %s; it is still running\n' "$DEV_STOP_SESSION" >&2
      return 1
    fi
    # Emitted only now. The fold assigns status=stopped absolutely and reconcile
    # treats a stopped record as terminal, so emitting before a kill that failed
    # would leave a live workspace permanently recorded as stopped.
    dev_stop_emit workspace.stopped '{"reason":"user"}'
  else
    printf 'dev: %s is already stopped\n' "$DEV_STOP_SESSION" >&2
  fi

  if [[ "$stop_container" -eq 1 ]]; then
    cid=$(jq -r '.container.id // ""' <<<"$record")
    if [[ -n "$cid" && "$cid" != "null" ]]; then
      if ! docker stop "$cid" >/dev/null 2>&1; then
        printf 'dev: could not stop container %s\n' "$cid" >&2
      fi
    else
      printf 'dev: %s has no container to stop\n' "$DEV_STOP_SESSION" >&2
    fi
  fi
}

dev_cmd_stop() {
  local arg="" stop_container=0 a
  for a in "$@"; do
    case "$a" in
      --container)
        stop_container=1
        ;;
      -h | --help)
        printf 'usage: dev stop [<name>] [--container]\n'
        return 0
        ;;
      -*)
        printf 'usage: dev stop [<name>] [--container]\n' >&2
        return 2
        ;;
      *)
        if [[ -n "$arg" ]]; then
          printf 'usage: dev stop [<name>] [--container]\n' >&2
          return 2
        fi
        arg="$a"
        ;;
    esac
  done

  local resolved config digest record
  resolved=$(dev_resolve "$arg") || return $?

  DEV_STOP_WS_ID=$(jq -r '.workspace_id' <<<"$resolved")
  DEV_STOP_SLUG=$(jq -r '.slug' <<<"$resolved")
  DEV_STOP_WORKTREE=$(jq -r '.worktree' <<<"$resolved")
  DEV_STOP_SESSION=$(jq -r '.session_name' <<<"$resolved")

  config=$(dev_config_merged "$DEV_STOP_SLUG" "$DEV_STOP_WORKTREE") || return $?
  digest=$(dev_config_digest "$config")
  record=$(dev_reconcile "$resolved" "$digest") || return $?
  DEV_STOP_SESSION=$(jq -r '.session_name' <<<"$record")

  local lock rc=0
  lock="$DEV_STATE_ROOT/locks/$DEV_STOP_WS_ID.op"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if ! flock -n 9; then
    exec 9>&-
    printf 'dev: another dev is working on this workspace (%s)\n' "$DEV_STOP_SESSION" >&2
    return 7
  fi
  dev_stop_locked "$record" "$stop_container" || rc=$?
  exec 9>&-
  # Project the record forward. The reconcile above ran before the kill, so
  # without this `stop` returns with the record still reading `running` and
  # anything reading state between commands sees a workspace the user has
  # already stopped as live. Reconcile takes no operation lock (ADR-1), so this
  # runs after the release.
  if [[ "$rc" -eq 0 ]]; then
    dev_reconcile "$resolved" "$digest" >/dev/null || true
  fi
  return "$rc"
}
