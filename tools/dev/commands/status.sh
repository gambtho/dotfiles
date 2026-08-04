#!/usr/bin/env bash
# dev status - detail for one workspace.
#
# Takes no operation lock and repairs nothing. It reconciles, re-queries the
# backend for per-pane detail, and prints. `status` and `container.status` are
# reported as two axes because they answer different questions: whether the
# workspace exists right now, and whether anything can be exec'd into it.

dev_cmd_status() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        printf 'usage: dev status [<workspace>]\n'
        return 0
        ;;
      -*)
        printf 'dev status: unknown option: %s\n' "$1" >&2
        return 2
        ;;
      *)
        if [[ -n "$name" ]]; then
          printf 'dev status: too many arguments\n' >&2
          return 2
        fi
        name="$1"
        shift
        ;;
    esac
  done

  local resolved slug worktree config digest record session query
  resolved=$(dev_resolve "$name") || return $?
  slug=$(printf '%s' "$resolved" | jq -r '.slug')
  worktree=$(printf '%s' "$resolved" | jq -r '.worktree')
  config=$(dev_config_merged "$slug" "$worktree") || return $?
  digest=$(dev_config_digest "$config")
  record=$(dev_reconcile "$resolved" "$digest") || return $?
  session=$(printf '%s' "$record" | jq -r '.session_name')
  query=$(dev_backend_query "$session")

  printf '%s\t%s\n' "$session" "$(printf '%s' "$record" | jq -r '.status')"
  printf '  worktree:   %s\n' "$worktree"
  printf '  session:    %s\n' \
    "$(printf '%s' "$query" | jq -r 'if .exists
        then "live, \(.clients) client(s) attached"
        else "not present on the tmux server" end')"
  printf '  container:  %s\n' \
    "$(printf '%s' "$record" | jq -r '.container.status // "none"')"

  printf '%s' "$query" | jq -r '.windows[]? |
    "  window \(.name): " + ([.panes[] | if .alive then "alive" else "dead" end] | join(", "))'
  printf '%s' "$record" | jq -r '.agents[]? |
    "  agent \(.window): \(.state) (\(.command // "?"))"'

  local current applied
  current=$(printf '%s' "$record" | jq -r '.config_digest // "none"')
  applied=$(printf '%s' "$record" | jq -r '.applied_digest // "none"')
  if [[ "$current" != "$applied" ]]; then
    printf '  config:     drift: this session was built from %s, but the merged configuration is now %s.\n' \
      "$applied" "$current"
    # Phase 1 does no additive reconciliation; saying "it will converge" would
    # be a promise nothing in this phase keeps.
    printf '              Run `dev stop %s` and then `dev %s` to apply it.\n' "$session" "$session"
  fi

  if [[ "$(printf '%s' "$record" | jq -r '.fold_gap')" == "true" ]]; then
    printf '  history:    incomplete: some transitions between then and now were not recorded.\n'
  fi
}
