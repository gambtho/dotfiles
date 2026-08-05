#!/usr/bin/env bash
# tmux execution backend.
#
# This is the ONLY file in the dev platform permitted to reference tmux. Every
# consumer above it reads the backend-neutral JSON dev_backend_query emits; no
# caller parses tmux output. Targets always use tmux's exact-match "=" prefix,
# because tmux otherwise prefix-matches names and a request for session "dev"
# would resolve to "dev-workspace".

DEV_TMUX_SOCKET="${DEV_TMUX_SOCKET:-}"

dev_tmux() {
  if [[ -n "$DEV_TMUX_SOCKET" ]]; then
    tmux -L "$DEV_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# dev_backend_create <session_name> <workspace_id> <slug> <worktree>
#
# The three user options are read by the tmux hooks in dev.tmux.conf so a hook
# can build a full event envelope without reading a record or taking a lock.
# session_name is deliberately NOT stored as a fourth option: hooks read tmux's
# own #{session_name}, which cannot go stale after a manual rename-session.
#
# The dev-holder window is a placeholder; new-session always creates a window
# and this function has no configuration to name it from. apply_layout removes
# it once it has created a real window.
dev_backend_create() {
  local session_name="$1" workspace_id="$2" slug="$3" worktree="$4"
  dev_tmux new-session -d -s "$session_name" -c "$worktree" -n dev-holder || return 1
  # The trailing colon is required, not cosmetic: set-option takes a target-pane, and
  # the bare exact-match form `-t "=name"` fails with "no such session" on tmux 3.4.
  # `=name:` parses and still pins the match exactly. Verified on this machine.
  dev_tmux set-option -t "=$session_name:" @dev_workspace_id "$workspace_id" || return 1
  dev_tmux set-option -t "=$session_name:" @dev_slug "$slug" || return 1
  dev_tmux set-option -t "=$session_name:" @dev_worktree "$worktree" || return 1
}

# dev_backend_ensure_pane_window <session_name> <window_json> <record_json> \
#   <global_env_json> <exists 0|1>
#
# Creates a panes-form window (first pane rides new-window) and/or the declared
# panes it is missing, stamps each with the pane-scoped @dev_pane user option,
# and applies the window's named layout when anything was created. Undeclared
# panes — unstamped, or stamped with a name the config no longer declares —
# are invisible here: never matched, never split into, never killed (§1.2).
#
# EVERY stamp is chained into the same tmux invocation as the pane's creation.
# For the first pane the chain rides new-window (the window target resolves to
# its active — sole — pane) alongside remain-on-exit, exactly like the
# single-pane path. For splits the window cannot be destroyed (remain-on-exit
# is already on, so a fast-exiting command leaves a dead, held pane), but a
# SECOND race remains: the pane-died hook can fire before a separate second
# invocation stamps @dev_pane, and an unstamped death event has no pane
# identity for the fold to route. So split-window runs WITHOUT -d — the new
# pane becomes the window's active pane — and the chained set-option's window
# target resolves to it inside one atomic server request. The active-pane
# side effect is corrected by the focus pass at the end of apply_layout.
dev_backend_ensure_pane_window() {
  local session_name="$1" window_json="$2" record_json="$3" global_env="$4" exists="$5"
  local workspace_id slug worktree wname layout stamped
  local pane_json pname pane_env location workdir inner pane_cmd created=0
  local -a prefix
  local ev_id ev_ts data line

  workspace_id=$(jq -r '.workspace_id' <<<"$record_json")
  slug=$(jq -r '.slug' <<<"$record_json")
  worktree=$(jq -r '.worktree' <<<"$record_json")
  wname=$(jq -r '.name' <<<"$window_json")
  layout=$(jq -r '.layout // "main-vertical"' <<<"$window_json")

  if [[ "$exists" -eq 1 ]]; then
    stamped=$(dev_tmux list-panes -t "=$session_name:=$wname" \
      -F '#{?#{@dev_pane},#{@dev_pane},}' 2>/dev/null || true)
  else
    stamped=""
  fi

  while IFS= read -r pane_json; do
    [[ -n "$pane_json" ]] || continue
    pname=$(jq -r '.name' <<<"$pane_json")
    if [[ -n "$stamped" ]] && printf '%s\n' "$stamped" | grep -Fxq -- "$pname"; then
      continue
    fi
    # global * pane.environment only: the exclusive schema forbids window-level
    # environment beside panes (validated in config), so there is no window
    # layer to merge here.
    pane_env=$(jq -c --argjson g "$global_env" '$g * (.environment // {})' <<<"$pane_json")
    location=$(dev_window_location "$record_json" "$pane_json") || return 1
    mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$pane_json") || return 1
    [[ ${#prefix[@]} -gt 0 ]] || return 1
    inner=$(dev_window_inner_command "$record_json" "$pane_json" "$pane_env") || return 1
    printf -v pane_cmd '%q ' "${prefix[@]}"
    printf -v pane_cmd '%s%q' "$pane_cmd" "$inner"
    if [[ "$location" == host ]]; then
      workdir=$(dev_window_workdir "$record_json" "$pane_json") || return 1
    else
      workdir="$worktree"
    fi

    if [[ "$exists" -eq 0 ]]; then
      dev_tmux new-window -d -t "=$session_name:" -n "$wname" -c "$workdir" "$pane_cmd" \
        ';' set-window-option -t "=$session_name:=$wname" remain-on-exit on \
        ';' set-option -p -t "=$session_name:=$wname" @dev_pane "$pname" || return 1
      exists=1
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      # §4.4 amendment: a panes-form window.created carries the pane roster and
      # neither location nor command — a mixed host/container window has no
      # window-level truth for either (absent means "not known").
      data=$(jq -c '{window: .name, panes: [.panes[].name]}' <<<"$window_json")
      line=$(dev_event_build "$ev_id" "$ev_ts" "window.created" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    else
      # A pre-existing, user-created window that name-collides with a declared
      # panes-form window never went through the new-window branch above, so it
      # never got remain-on-exit; set it here too (idempotent for dev-created
      # windows) or a fast-exiting pane closes the whole window silently.
      dev_tmux split-window -t "=$session_name:=$wname" -c "$workdir" "$pane_cmd" \
        ';' set-window-option -t "=$session_name:=$wname" remain-on-exit on \
        ';' set-option -p -t "=$session_name:=$wname" @dev_pane "$pname" || return 1
    fi
    created=$((created + 1))

    ev_id=$(dev_event_id_random)
    ev_ts=$(dev_now)
    # The DECLARED command, never the rendered one (secrets rule).
    data=$(jq -c --arg w "$wname" --arg loc "$location" \
      '{window: $w, pane: .name, location: $loc, command: (.command // .agent // null)}' \
      <<<"$pane_json")
    line=$(dev_event_build "$ev_id" "$ev_ts" "pane.created" \
      "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
    dev_event_append "$line"

    if [[ "$(jq -r '.agent // ""' <<<"$pane_json")" != "" ]]; then
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      data=$(jq -c --arg w "$wname" '{window: $w, pane: .name, command: .agent}' <<<"$pane_json")
      line=$(dev_event_build "$ev_id" "$ev_ts" "agent.started" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    fi
  done < <(jq -c '.panes[]' <<<"$window_json")

  if [[ "$created" -gt 0 ]]; then
    # Applied only when a pane was created: re-applying on a no-op open would
    # stomp the user's manual resizes (spec §4).
    dev_tmux select-layout -t "=$session_name:=$wname" "$layout" || return 1
  fi
  printf '%s\n' "$created"
}

# dev_backend_apply_layout <session_name> <config_json> <record_json>
#
# Creates only the windows that are missing, diffed by name. It never touches,
# respawns, renames, or reorders an existing window: "open never destroys"
# (§1.2) is enforced here, at the only layer that could violate it.
dev_backend_apply_layout() {
  local session_name="$1" config_json="$2" record_json="$3"
  local workspace_id slug worktree existing created=0 env_json focus_window
  local window_json name agent location workdir inner pane_cmd win_created win_env
  local fw fp pid
  local -a prefix
  local ev_id ev_ts data line

  workspace_id=$(printf '%s' "$record_json" | jq -r '.workspace_id')
  slug=$(printf '%s' "$record_json" | jq -r '.slug')
  worktree=$(printf '%s' "$record_json" | jq -r '.worktree')
  env_json=$(printf '%s' "$config_json" | jq -c '.environment // {}')
  existing=$(dev_tmux list-windows -t "=$session_name" -F '#{window_name}' 2>/dev/null || true)

  while IFS= read -r window_json; do
    [[ -n "$window_json" ]] || continue
    name=$(printf '%s' "$window_json" | jq -r '.name')
    win_created=0
    if [[ "$(jq -r '.panes != null' <<<"$window_json")" == true ]]; then
      if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
        win_created=$(dev_backend_ensure_pane_window "$session_name" "$window_json" \
          "$record_json" "$env_json" 1) || return 1
      else
        win_created=$(dev_backend_ensure_pane_window "$session_name" "$window_json" \
          "$record_json" "$env_json" 0) || return 1
      fi
      created=$((created + win_created))
      continue
    fi
    if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      continue
    fi
    agent=$(printf '%s' "$window_json" | jq -r '.agent // ""')

    # Container owns how a pane reaches its execution environment, resolves the
    # window's effective location against the record, and builds the single
    # command string that applies cwd and environment. Nothing about
    # containers, working directories or environment injection is decided here:
    # this layer only knows tmux. The prefix arrives one argv element per line
    # (Task 10) so a user or workdir containing a space cannot be resplit; read
    # it into an array and quote each element exactly once.
    location=$(dev_window_location "$record_json" "$window_json") || return 1
    mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$window_json") || return 1
    [[ ${#prefix[@]} -gt 0 ]] || return 1
    win_env=$(jq -c --argjson g "$env_json" '$g * (.environment // {})' <<<"$window_json")
    inner=$(dev_window_inner_command "$record_json" "$window_json" "$win_env") || return 1
    printf -v pane_cmd '%q ' "${prefix[@]}"
    printf -v pane_cmd '%s%q' "$pane_cmd" "$inner"

    # -c sets the directory tmux starts the pane process in. For a host window
    # dev_window_workdir already resolved `cwd` against the worktree; for a
    # container window the host has no such path, so the pane starts in the
    # worktree and the inner command cd's inside the container.
    if [[ "$location" == host ]]; then
      workdir=$(dev_window_workdir "$record_json" "$window_json") || return 1
    else
      workdir="$worktree"
    fi

    # Per window, never -g. pane-died fires only when remain-on-exit holds the
    # dead pane, so scenario 3's event fidelity depends on this; setting it
    # globally would leave every ordinary tmux pane the user has hanging dead.
    # new-window and set-window-option must reach the server as ONE tmux
    # invocation: as two separate calls, a pane_cmd fast enough to exit
    # between them (a failing container command, or a bats stub) races
    # tmux's default no-remain-on-exit behavior, which destroys the window
    # before the second call can protect it -- "no such window" on the
    # set-window-option that follows. The literal ';' argument is tmux's own
    # command separator, chaining both into a single atomic request.
    dev_tmux new-window -d -t "=$session_name:" -n "$name" -c "$workdir" "$pane_cmd" \
      ';' set-window-option -t "=$session_name:=$name" remain-on-exit on || return 1
    created=$((created + 1))

    ev_id=$(dev_event_id_random)
    ev_ts=$(dev_now)
    # The DECLARED command/agent, never the rendered inner command: the
    # rendering embeds every configured `environment` value as an export, so
    # recording it would persist secrets from workspace.local.yaml into the
    # event log.
    data=$(jq -c --arg w "$name" --arg loc "$location" \
      '{window: $w, location: $loc, command: (.command // .agent // null)}' \
      <<<"$window_json")
    line=$(dev_event_build "$ev_id" "$ev_ts" "window.created" \
      "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
    dev_event_append "$line"

    if [[ -n "$agent" ]]; then
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      data=$(jq -nc --arg w "$name" --arg cmd "$agent" '{window: $w, command: $cmd}')
      line=$(dev_event_build "$ev_id" "$ev_ts" "agent.started" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    fi
  done < <(printf '%s' "$config_json" | jq -c '.windows[]')

  if [[ "$created" -gt 0 ]] && printf '%s\n' "$existing" | grep -Fxq -- 'dev-holder'; then
    dev_tmux kill-window -t "=$session_name:=dev-holder" 2>/dev/null || true
  fi

  # `focus: true` selects the window the user lands on. Applied after the holder
  # is gone and unconditionally rather than only on creation, so that attaching
  # to a workspace whose selection drifted still puts the cursor where the
  # config says. Validation (Task 4) already guarantees at most one.
  focus_window=$(printf '%s' "$config_json" |
    jq -r 'first((.windows // [])[] | select(.focus == true) | .name) // ""')
  if [[ -n "$focus_window" ]]; then
    dev_tmux select-window -t "=$session_name:=$focus_window" 2>/dev/null || true
  fi

  # `panes[].focus: true` selects the pane the user lands on within its window,
  # same rationale as focus_window above: re-applied every open (not only on
  # creation), so drift self-heals. Validation guarantees at most one per window.
  while IFS=$'\t' read -r fw fp; do
    [[ -n "$fw" ]] || continue
    pid=$(dev_tmux list-panes -t "=$session_name:=$fw" \
      -F '#{pane_id} #{?#{@dev_pane},#{@dev_pane},-}' 2>/dev/null |
      awk -v p="$fp" '$2 == p {print $1; exit}')
    [[ -n "$pid" ]] || continue
    dev_tmux select-pane -t "$pid" 2>/dev/null || true
  done < <(printf '%s' "$config_json" | jq -r '
    (.windows // [])[] | select(.panes != null) | .name as $w
    | .panes[] | select(.focus == true) | [$w, .name] | @tsv')
}

# dev_backend_query <session_name>
#
# Backend-neutral snapshot. A session that does not exist, or no tmux server at
# all, is an observation and not an error: exists:false with exit 0. dev list
# after `pkill tmux` (scenario 4) depends on that.
#
# list-panes uses -s (all panes in the session), not -a: with -a tmux ignores
# -t and returns every pane on the server. Fields are ordered so window_name,
# which may contain spaces, is last and absorbs the remainder of the line.
#
# The trailing colon on the list-panes target is required for the same reason
# as show-options below, but the failure mode here is worse: has-session,
# list-clients and list-windows all correctly reject a bare `=name` when only
# a longer-named session exists ("can't find session"), but `list-panes -s`
# does not — it silently resolves `=name` to `name-longer` and returns exit 0,
# which is exactly the cross-workspace misattachment ADR-7 exists to prevent.
# That asymmetry between tmux's own commands is the whole reason this hid.
#
# `pane_id` is an opaque, ephemeral backend handle for targeting a live pane
# (respawn, select); it is never written to events or records — logical
# identity is `pane`.
dev_backend_query() {
  local session_name="$1" panes worktree clients
  if ! panes=$(dev_tmux list-panes -s -t "=$session_name:" \
    -F '#{pane_dead} #{window_index} #{pane_id} #{?#{@dev_pane},#{@dev_pane},-} #{window_name}' 2>/dev/null); then
    printf '{"exists":false,"worktree":null,"clients":0,"windows":[]}\n'
    return 0
  fi
  # The trailing colon is required here too: show-options resolves via
  # target-pane like set-option does, the bare exact-match form `-t "=name"`
  # does not resolve on tmux 3.4, and -q masks the failure by returning empty
  # with exit 0 instead of an error. Verified on this machine.
  worktree=$(dev_tmux show-options -qv -t "=$session_name:" @dev_worktree 2>/dev/null || true)
  clients=$(dev_tmux list-clients -t "=$session_name" -F 'x' 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "$panes" | jq -Rsc --arg wt "$worktree" --argjson clients "$clients" '
    (split("\n")
     | map(select(length > 0))
     | map(capture("^(?<dead>[01]) (?<idx>[0-9]+) (?<pid>%[0-9]+) (?<pn>[^ ]+) (?<name>.*)$")))
    | group_by(.idx | tonumber)
    | map({name: .[0].name,
           panes: map({alive: (.dead == "0"),
                       pane: (if .pn == "-" then null else .pn end),
                       pane_id: .pid})})
    | {exists: true,
       worktree: (if $wt == "" then null else $wt end),
       clients: $clients,
       windows: .}
  '
}

# dev_backend_respawn_pane <session_name> <window> <command> [container_id] \
#   [pane_handle] [pane_name]
#
# With a pane_handle (an id from dev_backend_query) the respawn targets exactly
# that pane; without one it falls back to the window target, which tmux
# resolves to the window's ACTIVE pane — correct only for single-pane windows,
# which is the only caller that omits it. pane_name, when non-empty, is the
# logical @dev_pane identity and is recorded on the event; the stamp itself
# survives respawn because the pane object does.
#
# The envelope identity is read back from the session's user options rather
# than passed in, which is the same path the tmux hooks take.
#
# This function is the SOLE emitter of pane.respawned. Callers must not emit it
# again: a respawn that produced two events would fold twice, and the fold's
# `restarts` counter would report double every recovery.
dev_backend_respawn_pane() {
  local session_name="$1" window="$2" pane_command="$3" container_id="${4:-}"
  local pane_handle="${5:-}" pane_name="${6:-}"
  local target workspace_id slug worktree ev_id ev_ts data line
  if [[ -n "$pane_handle" ]]; then
    target="$pane_handle"
  else
    target="=$session_name:=$window"
  fi
  dev_tmux respawn-pane -k -t "$target" "$pane_command" || return 1
  workspace_id=$(dev_tmux show-options -qv -t "=$session_name:" @dev_workspace_id 2>/dev/null || true)
  slug=$(dev_tmux show-options -qv -t "=$session_name:" @dev_slug 2>/dev/null || true)
  worktree=$(dev_tmux show-options -qv -t "=$session_name:" @dev_worktree 2>/dev/null || true)
  ev_id=$(dev_event_id_random)
  ev_ts=$(dev_now)
  data=$(jq -nc --arg w "$window" --arg p "$pane_name" --arg c "$container_id" \
    '{window: $w}
     + (if $p == "" then {} else {pane: $p} end)
     + (if $c == "" then {} else {container_id: $c} end)')
  line=$(dev_event_build "$ev_id" "$ev_ts" "pane.respawned" \
    "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
  dev_event_append "$line"
}

# dev_backend_kill <session_name>
#
# Reachable only from `dev stop`, the one destructive verb (§1.2). Note that
# tmux does NOT fire pane-died for kill-pane or kill-session, so explicit
# destruction produces no hook events: a session killed outside `dev stop` is a
# reconcile-discovered case (workspace.vanished), never a hook-reported one.
# Killing an already-absent session succeeds, so stop is idempotent.
dev_backend_kill() {
  local session_name="$1"
  if ! dev_tmux has-session -t "=$session_name" 2>/dev/null; then
    return 0
  fi
  dev_tmux kill-session -t "=$session_name"
}
