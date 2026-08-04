#!/usr/bin/env bash
# dev config - print the merged workspace configuration.
#
# This is the seam that makes the three-layer YAML merge testable without tmux
# or Docker: no other component reads YAML, so every consumer sees exactly the
# document printed here.

dev_cmd_config() {
  local compact=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compact)
        compact=1
        shift
        ;;
      -h | --help)
        printf 'usage: dev config [--compact] [<workspace>]\n'
        return 0
        ;;
      -*)
        printf 'dev config: unknown option: %s\n' "$1" >&2
        return 2
        ;;
      *)
        if [[ -n "$name" ]]; then
          printf 'dev config: too many arguments\n' >&2
          return 2
        fi
        name="$1"
        shift
        ;;
    esac
  done

  local resolved slug worktree config
  resolved=$(dev_resolve "$name") || return $?
  slug=$(printf '%s' "$resolved" | jq -r '.slug')
  worktree=$(printf '%s' "$resolved" | jq -r '.worktree')
  config=$(dev_config_merged "$slug" "$worktree") || return $?
  dev_config_validate "$config" || return 5

  if [[ "$compact" -eq 1 ]]; then
    printf '%s' "$config" | jq -c .
  else
    printf '%s' "$config" | jq .
  fi
}
