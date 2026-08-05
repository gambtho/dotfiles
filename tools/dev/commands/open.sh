# shellcheck shell=bash
# dev open — reconcile, ensure, attach. Never destroys anything.

dev_open_session_index_path() {
  printf '%s\n' "$DEV_STATE_ROOT/sessions/$1.json"
}

dev_open_session_index_write() {
  local workspace_id="$1" slug="$2" session_name="$3" worktree="$4"
  local path
  path=$(dev_open_session_index_path "$session_name")
  mkdir -p "$(dirname "$path")"
  jq -n --arg id "$workspace_id" --arg slug "$slug" --arg name "$session_name" \
    --arg tree "$worktree" \
    '{workspace_id: $id, slug: $slug, session_name: $name, worktree: $tree}' >"$path"
}

dev_open_boot_id() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    tr -d '\n' </proc/sys/kernel/random/boot_id
  else
    printf 'unknown'
  fi
}

# Every event this command writes goes through here, so the envelope is assembled
# once and picks up the post-guard session name automatically.
dev_open_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" \
    "$DEV_OPEN_SESSION" "$DEV_OPEN_WORKTREE" "$data")
  dev_event_append "$line"
}

# The shell command for one window, built exactly the way Task 12's
# `dev_backend_apply_layout` builds it: the container exec prefix (one argv
# element per line, per Task 10) quoted back into a single string, then the
# window's inner command. It must go through `dev_window_inner_command` for the
# same reason creation does -- that function is where `agent`, `command`, `cwd`
# and `environment` are applied. An earlier draft re-derived `.command` here and
# so respawned an agent window as a bare $SHELL in the worktree with no
# environment: the pane came back, silently not being what it was.
dev_open_window_command() {
  local record_json="$1" window_json="$2" env_json="${3:-{\}}"
  local prefix=() inner out
  mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$window_json") || return 1
  [[ ${#prefix[@]} -gt 0 ]] || return 1
  inner=$(dev_window_inner_command "$record_json" "$window_json" "$env_json") || return 1
  printf -v out '%q ' "${prefix[@]}"
  printf '%s%q\n' "$out" "$inner"
}

dev_open_attach() {
  local session_name="$1"
  if [[ -n "$DEV_TMUX_SOCKET" ]]; then
    exec tmux -L "$DEV_TMUX_SOCKET" attach-session -t "=$session_name"
  fi
  exec tmux attach-session -t "=$session_name"
}

# Brings the container up and returns the record with the new binding patched in.
# The on-disk record is not touched: it is reconcile's, and it catches up on the
# next pass by folding the container.ready this writes.
dev_open_container_up() {
  local config="$1" record="$2" repair="$3"
  local old_id up status ts

  old_id=$(jq -r '.container.id // ""' <<<"$record")
  if [[ -z "$old_id" ]]; then
    # reconcile's own fold already nulled .container.id the moment it detected
    # the loss (fold.sh: folding container.lost sets .container.id = null), so
    # by the time ensure runs the record no longer knows what was lost. The
    # container.lost event reconcile emitted still does -- it carries the
    # pre-loss id in data.old_id -- so fall back to the most recent one for
    # this workspace.
    old_id=$(dev_events_read_all | jq -rs --arg ws "$DEV_OPEN_WS_ID" '
      [.[] | select(.workspace_id == $ws and .event == "container.lost")]
      | last | .data.old_id // ""')
  fi
  dev_open_emit container.starting '{}'

  # Keep dev_container_up's own JSON even on failure: it carries the REAL exit
  # status (124 from timeout, a CLI-specific code) and stderr_tail, which are
  # exactly what container.failed exists to preserve (§4.4). Synthesize a
  # payload only when nothing parseable was printed, and then use the actual
  # return code rather than a flat 1.
  local up_rc=0
  up=$(dev_container_up "$DEV_OPEN_WORKTREE" "$config") || up_rc=$?
  if ! jq -e . >/dev/null 2>&1 <<<"$up"; then
    up=$(jq -nc --argjson s "${up_rc:-1}" '{exit_status: $s}')
  fi
  status=$(jq -r ".exit_status // ${up_rc:-1}" <<<"$up")
  if [[ "$status" != "0" ]]; then
    dev_open_emit container.failed \
      "$(jq -c --argjson s "$status" \
        '{reason: "devcontainer up failed", up_exit_status: $s}
         + (if (.stderr_tail // "") == "" then {} else {stderr_tail} end)' <<<"$up")"
    printf 'dev: devcontainer up failed for %s (exit %s)\n' "$DEV_OPEN_SESSION" "$status" >&2
    return 1
  fi

  local new_id kind user workdir ready
  new_id=$(jq -r '.containerId' <<<"$up")
  user=$(jq -r '.remoteUser' <<<"$up")
  workdir=$(jq -r '.remoteWorkspaceFolder' <<<"$up")
  kind=$(dev_runtime_kind "$DEV_OPEN_WORKTREE")

  if [[ "$repair" -eq 1 ]]; then
    dev_open_emit container.replaced \
      "$(jq -n --arg o "$old_id" --arg n "$new_id" \
        '{old_id: $o, new_id: $n, reason: "lost"}')"
  fi

  ready=$(jq -n --arg id "$new_id" --arg kind "$kind" --arg user "$user" \
    --arg workdir "$workdir" --argjson st "$status" --argjson res "$up" \
    '{id: $id, kind: $kind, user: $user, workdir: $workdir,
      up_exit_status: $st, up_result: $res}')
  dev_open_emit container.ready "$ready"

  ts=$(dev_now)
  jq --argjson d "$ready" --arg ts "$ts" \
    '.container = {status: "ready", kind: $d.kind, id: $d.id, user: $d.user,
                   workdir: $d.workdir, verified: false,
                   up_exit_status: $d.up_exit_status, up_result: $d.up_result,
                   observed_at: $ts}' <<<"$record"
}

# Only panes the backend reports dead are touched; a live pane is never
# respawned, so running this on every open is idempotent (spec §4 removed the
# old container-loss gate). Undeclared panes -- unstamped, or stamped with a
# name the config no longer declares -- are skipped: they are drift for
# `dev status` to report, not ours to touch. A single-pane window with extra
# manual panes is skipped for the same reason: the window target cannot say
# which pane is the declared one.
dev_open_respawn_dead() {
  local config="$1" record="$2"
  local query cid global_env win pname handle total wjson pjson env cmd
  query=$(dev_backend_query "$DEV_OPEN_SESSION")
  cid=$(jq -r '.container.id // ""' <<<"$record")
  global_env=$(jq -c '.environment // {}' <<<"$config")
  while IFS=$'\t' read -r win pname handle total; do
    [[ -n "$win" ]] || continue
    wjson=$(jq -c --arg w "$win" 'first(.windows[] | select(.name == $w)) // empty' <<<"$config")
    [[ -n "$wjson" ]] || continue
    if [[ "$(jq -r '.panes != null' <<<"$wjson")" == true ]]; then
      [[ "$pname" != "-" ]] || continue
      pjson=$(jq -c --arg p "$pname" 'first(.panes[] | select(.name == $p)) // empty' <<<"$wjson")
      [[ -n "$pjson" ]] || continue
      env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$wjson")
      env=$(jq -c --argjson w "$env" '$w * (.environment // {})' <<<"$pjson")
      cmd=$(dev_open_window_command "$record" "$pjson" "$env") || continue
      # `dev_backend_respawn_pane` is the sole emitter of pane.respawned
      # (Task 12), so the container id is handed to it rather than emitted
      # again here. Two events for one respawn would fold twice and double
      # the `restarts` counter.
      dev_backend_respawn_pane "$DEV_OPEN_SESSION" "$win" "$cmd" "$cid" "$handle" "$pname" || continue
    else
      [[ "$total" -eq 1 ]] || continue
      env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$wjson")
      cmd=$(dev_open_window_command "$record" "$wjson" "$env") || continue
      dev_backend_respawn_pane "$DEV_OPEN_SESSION" "$win" "$cmd" "$cid" "$handle" || continue
    fi
  done < <(jq -r '.windows[] | .name as $w | (.panes | length) as $n
    | .panes[] | select(.alive | not)
    | [$w, (.pane // "-"), .pane_id, ($n | tostring)] | @tsv' <<<"$query")
}

dev_open_ensure_locked() {
  local config="$1" record="$2"
  local repair=0 created=0 query live

  if [[ "$(jq -r '.container.status // "none"' <<<"$record")" == "lost" ]]; then
    repair=1
  fi

  if dev_container_enabled "$config" "$DEV_OPEN_WORKTREE"; then
    dev_runtime_detect >/dev/null || return $?
    record=$(dev_open_container_up "$config" "$record" "$repair") || return $?
  fi

  query=$(dev_backend_query "$DEV_OPEN_SESSION")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    live=$(jq -r '.worktree // ""' <<<"$query")
    if [[ "$live" != "$DEV_OPEN_WORKTREE" ]]; then
      # ADR-7: the name is taken by a different working tree. Use the hashed form
      # rather than attaching to someone else's session.
      DEV_OPEN_SESSION="$DEV_OPEN_SLUG--$(basename "$DEV_OPEN_WORKTREE")--${DEV_OPEN_WS_ID:0:6}"
      query=$(dev_backend_query "$DEV_OPEN_SESSION")
    fi
  fi

  if [[ "$(jq -r '.exists' <<<"$query")" != "true" ]]; then
    dev_backend_create "$DEV_OPEN_SESSION" "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" \
      "$DEV_OPEN_WORKTREE" || return $?
    created=1
  fi

  dev_open_session_index_write "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" "$DEV_OPEN_SESSION" \
    "$DEV_OPEN_WORKTREE"

  record=$(jq --arg n "$DEV_OPEN_SESSION" '.session_name = $n' <<<"$record")
  dev_backend_apply_layout "$DEV_OPEN_SESSION" "$config" "$record" || return $?

  dev_open_respawn_dead "$config" "$record"

  if [[ "$created" -eq 1 ]]; then
    dev_open_emit workspace.opened \
      "$(jq -n --arg b "$(dev_open_boot_id)" --arg d "$DEV_OPEN_DIGEST" \
        --arg n "$DEV_OPEN_SESSION" \
        '{boot_id: $b, config_digest: $d, session_name_actual: $n}')"
  fi
}

# The operation lock wraps ensure only. Reconcile ran before it, unlocked, because
# reconcile is read-only with respect to the workspace (ADR-1).
dev_open_ensure() {
  local config="$1" record="$2"
  local lock rc=0
  lock="$DEV_STATE_ROOT/locks/$DEV_OPEN_WS_ID.op"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if ! flock -n 9; then
    exec 9>&-
    printf 'dev: another dev is working on this workspace (%s)\n' "$DEV_OPEN_SESSION" >&2
    return 7
  fi
  # `9>&-` on the call itself, not on the surrounding shell: bash closes its own
  # copy of fd 9 for the duration of this one command substitution/call, so
  # every child it forks -- including `dev_backend_create`'s detached tmux
  # server -- starts with fd 9 already closed and can never inherit a
  # duplicate of it. Without this, the server's inherited copy of the lock's
  # open-file-description keeps the flock held for as long as the server lives
  # (flock is per open-file-description, not per fd), which is indefinitely,
  # since `open` never destroys anything.
  dev_open_ensure_locked "$config" "$record" 9>&- || rc=$?
  exec 9>&-
  return "$rc"
}

dev_open_usage() {
  cat <<'EOF'
usage: dev open [<name>] [--no-attach]

  <name>        workspace to open; defaults to the working tree containing $PWD
  --no-attach   reconcile, ensure and emit workspace.opened, then exit without
                attaching. Useful for autostart and scripting.
EOF
}

dev_cmd_open() {
  local arg="" no_attach=0 a
  for a in "$@"; do
    case "$a" in
      --no-attach)
        no_attach=1
        ;;
      -h | --help)
        dev_open_usage
        return 0
        ;;
      -*)
        dev_open_usage >&2
        return 2
        ;;
      *)
        if [[ -n "$arg" ]]; then
          dev_open_usage >&2
          return 2
        fi
        arg="$a"
        ;;
    esac
  done

  local resolved config record
  resolved=$(dev_resolve "$arg") || return $?

  DEV_OPEN_WS_ID=$(jq -r '.workspace_id' <<<"$resolved")
  DEV_OPEN_SLUG=$(jq -r '.slug' <<<"$resolved")
  DEV_OPEN_WORKTREE=$(jq -r '.worktree' <<<"$resolved")
  # Start from the recorded name so a workspace the ADR-7 guard already renamed
  # reuses its hashed session instead of re-testing the plain name and creating
  # a second session for the same working tree. The guard in
  # dev_open_ensure_locked still runs; on a renamed workspace it now finds its
  # own session and does nothing.
  DEV_OPEN_SESSION=$(dev_state_session_name "$DEV_OPEN_WS_ID" \
    "$(jq -r '.session_name' <<<"$resolved")")

  config=$(dev_config_merged "$DEV_OPEN_SLUG" "$DEV_OPEN_WORKTREE") || return $?
  dev_config_validate "$config" || return $?
  DEV_OPEN_DIGEST=$(dev_config_digest "$config")

  record=$(dev_reconcile "$resolved" "$DEV_OPEN_DIGEST") || return $?
  dev_open_ensure "$config" "$record" || return $?

  # The rename/repair facts (ADR-7's session name, container.replaced /
  # container.ready, pane.respawned) were only emitted as events while the
  # operation lock was held. This second, unlocked reconcile pass folds them
  # into the on-disk record through the sanctioned write path (ADR-1: only
  # reconcile writes records), so the rename and repair are durable in the
  # record before `open` returns rather than waiting for some later command
  # to observe them.
  record=$(dev_reconcile "$resolved" "$DEV_OPEN_DIGEST") || return $?

  if [[ "$no_attach" -eq 1 ]]; then
    printf '%s\n' "$DEV_OPEN_SESSION"
    return 0
  fi

  dev_open_attach "$DEV_OPEN_SESSION"
}
