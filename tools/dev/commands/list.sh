#!/usr/bin/env bash
# dev list - reconciled listing of every known workspace.
#
# Takes no operation lock and repairs nothing: it reconciles (which writes
# records and events but never starts anything) and prints. Because reconcile
# re-observes the backend, list always costs one backend query and cannot be
# answered from disk. That is ADR-2's price for never lying.
#
# `dev list --json` is the public snapshot contract. workspaces/*.json is NOT:
# records are last-observed, so a consumer reading them directly renders stale
# `running` badges for sessions that are already gone.

dev_cmd_list() {
  local as_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        as_json=1
        shift
        ;;
      -h | --help)
        printf 'usage: dev list [--json]\n'
        return 0
        ;;
      *)
        printf 'dev list: unexpected argument: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local tmp
  tmp=$(mktemp)
  # Expanding $tmp now is deliberate; it never changes after mktemp.
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  local path record slug worktree is_primary resolved config digest updated entry stale

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    record=$(cat "$path") || continue
    # One corrupt record must not abort the listing of every other workspace;
    # skipping mirrors the unreadable-file branch above.
    printf '%s' "$record" | jq -e . >/dev/null 2>&1 || continue
    slug=$(printf '%s' "$record" | jq -r '.slug')
    worktree=$(printf '%s' "$record" | jq -r '.worktree')

    # A record may outlive its working tree (ADR-7); is_primary is re-derived
    # where the path still exists and is false where it does not, which is the
    # same answer a deleted primary would have given.
    if dev_resolve_is_primary "$worktree" 2>/dev/null; then
      is_primary=true
    else
      is_primary=false
    fi
    resolved=$(printf '%s' "$record" | jq -c --argjson p "$is_primary" \
      '{slug, worktree, workspace_id, session_name, is_primary: $p}')

    if config=$(dev_config_merged "$slug" "$worktree" 2>/dev/null); then
      digest=$(dev_config_digest "$config")
    else
      digest=$(printf '%s' "$record" | jq -r '.config_digest // ""')
    fi

    # A workspace whose reconcile fails is listed from its last record rather
    # than aborting the whole listing -- but it is listed as explicitly stale.
    # ADR-2 makes `dev list --json` the snapshot contract precisely because it
    # reports observed rather than remembered state; substituting the prior
    # record silently would print remembered state under that contract, which is
    # the "stale running badge" failure §5.1 names as the signal the ADR leaked.
    # `stale: true` says the entry is last-known, not current, and a consumer
    # that ignores the field is no worse off than before.
    stale=false
    updated=$(dev_reconcile "$resolved" "$digest" 2>/dev/null) || {
      updated="$record"
      stale=true
    }

    entry=$(printf '%s' "$updated" | jq -c --argjson stale "$stale" '{
      session_name, slug, worktree, status,
      container: {status: .container.status, id: .container.id},
      agents, last_seen, fold_gap, stopped_reason, stale: $stale
    }')
    printf '%s\n' "$entry" >>"$tmp"
  done < <(dev_state_list)

  if [[ "$as_json" -eq 1 ]]; then
    jq -s -c '{v: 1, workspaces: .}' <"$tmp"
  elif [[ ! -s "$tmp" ]]; then
    printf 'No workspaces recorded yet. Run `dev <repository>` to create one.\n'
  else
    dev_list_render_human <"$tmp"
  fi
}

# Groups by slug so the several working trees of one project read as a set, and
# marks any basename that appears more than once, since that is exactly the
# condition under which `dev <basename>` exits 3 (ADR-7).
dev_list_render_human() {
  jq -s -r '
    def base: (.worktree | split("/") | last);
    (map(base) | group_by(.) | map(select(length > 1) | .[0])) as $dupes
    | group_by(.slug)
    | map(sort_by(.session_name))
    | .[]
    | (.[0].slug),
      (.[] |
        "  " + .session_name
        + "\t" + (.status // "unknown")
        + "\tcontainer:" + (.container.status // "none")
        + "\t" + .worktree
        + (if .stale then "\t(stale: could not re-observe)" else "" end)
        + (if (base as $b | ($dupes | index($b))) then "\t(ambiguous basename)" else "" end))
  '
}
