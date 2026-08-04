#!/usr/bin/env bash
# container.sh — every devcontainer concern lives here, so that no layer above
# it is written twice for the two repository kinds. For a plain WSL repo the
# exec prefix is simply `bash -lc` and there is no container.

dev_container_enabled() {
  local config_json="$1" worktree="$2" enabled
  # jq's `//` treats a literal false as falsy and identically to null, so
  # `enabled: false` silently became `auto` and a repo could not opt out of its
  # devcontainer. Test null explicitly instead, and stringify the boolean so
  # the case statement below (which compares strings) matches it.
  enabled=$(jq -r '.devcontainer.enabled
                   | if . == null then "auto" else tostring end' <<<"$config_json")
  case "$enabled" in
    true) return 0 ;;
    false) return 1 ;;
    auto) [[ -d "$worktree/.devcontainer" || -f "$worktree/.devcontainer.json" ]] ;;
    *)
      echo "dev: devcontainer.enabled must be auto|true|false, got '$enabled'" >&2
      return 5
      ;;
  esac
}

# Runs `devcontainer up` and returns the binding it reported. The CLI prints
# banner and build noise followed by one JSON object, so the result is the LAST
# line that parses as a JSON object, not the last line.
dev_container_up() {
  local worktree="$1" config_json="$2"
  local prefix cfg_rel timeout_s
  prefix=$(dev_runtime_devcontainer_cli) || return 6
  cfg_rel=$(jq -r '.devcontainer.config // empty' <<<"$config_json")
  timeout_s=$(jq -r '.devcontainer.start_timeout // 300' <<<"$config_json")

  if [[ -z "$cfg_rel" && ! -d "$worktree/.devcontainer" && ! -f "$worktree/.devcontainer.json" ]]; then
    echo "dev: devcontainer requested but $worktree has no .devcontainer/" >&2
    return 5
  fi

  local -a argv
  read -r -a argv <<<"$prefix"
  argv+=(up --workspace-folder "$worktree")
  if [[ -n "$cfg_rel" ]]; then
    argv+=(--config "$worktree/$cfg_rel")
  fi

  local out_file err_file status=0
  out_file=$(mktemp)
  err_file=$(mktemp)
  # </dev/null is load-bearing: GNU timeout runs its child in a NEW process
  # group, which is a background group on the invoking terminal. If the CLI
  # then reads its inherited-tty stdin, the kernel stops it with SIGTTIN and
  # the whole `dev open` hangs silently forever — the timeout clock keeps
  # ticking against a process that is asleep, not slow. The up call is
  # non-interactive by design (dev-autostart runs it with no tty at all).
  timeout "$timeout_s" "${argv[@]}" </dev/null >"$out_file" 2>"$err_file" || status=$?

  local json="" line
  while IFS= read -r line; do
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      json="$line"
    fi
  done <"$out_file"

  local stderr_tail
  stderr_tail=$(tail -n 20 "$err_file")
  rm -f "$out_file" "$err_file"

  jq -nc --argjson s "$status" --arg t "$stderr_tail" --argjson j "${json:-null}" '
    {
      containerId: ($j.containerId // null),
      remoteUser: ($j.remoteUser // null),
      remoteWorkspaceFolder: ($j.remoteWorkspaceFolder // null),
      exit_status: $s,
      stderr_tail: $t,
      up_result: $j
    }'

  [[ "$status" -eq 0 ]]
}

dev_container_alive() {
  local id="$1" out
  [[ -n "$id" && "$id" != null ]] || return 1
  out=$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) || return 1
  [[ "$out" == true ]]
}

# Resolves a window's effective location against the workspace record.
#
# Spec §4.1 defines the default as "container when one exists", so an UNSET
# location (JSON null, per Task 4's normalization) is a question that only the
# record can answer. Three cases:
#
#   "host"      -> host, always.
#   "container" -> container, always. On a workspace with no binding this is an
#                  error rather than a silent downgrade: the config asked for a
#                  container explicitly, and quietly running the command on the
#                  host would put an agent in the wrong filesystem.
#   null        -> container iff the record carries a container id, else host.
#                  This is what makes a plain (non-devcontainer) repository
#                  openable at all: `devcontainer.enabled: auto` correctly
#                  starts nothing, so agent-1, agent-2 and shell land on the
#                  host instead of demanding a binding that will never exist.
dev_window_location() {
  local record_json="$1" window_json="$2" location id
  location=$(jq -r '.location // "auto"' <<<"$window_json")
  case "$location" in
    host | container)
      printf '%s\n' "$location"
      return 0
      ;;
  esac
  id=$(jq -r '.container.id // empty' <<<"$record_json")
  if [[ -n "$id" && "$id" != null ]]; then
    printf 'container\n'
  else
    printf 'host\n'
  fi
}

# The directory a window's command starts in. `cwd` is relative to the repo root
# (spec §4.1), which means a different absolute base on each side of the
# container boundary: the worktree on the host, remoteWorkspaceFolder inside.
dev_window_workdir() {
  local record_json="$1" window_json="$2" location base cwd
  location=$(dev_window_location "$record_json" "$window_json") || return 1
  if [[ "$location" == host ]]; then
    base=$(jq -r '.worktree' <<<"$record_json")
  else
    base=$(jq -r '.container.workdir // empty' <<<"$record_json")
    [[ -n "$base" && "$base" != null ]] || return 1
  fi
  cwd=$(jq -r '.cwd // ""' <<<"$window_json")
  if [[ -z "$cwd" ]]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "${base%/}/${cwd#/}"
  fi
}

# Prints the argv prefix for a pane's command, one element per line.
#
# `devcontainer exec` is broken on compose-based setups; bin/claude-devcontainer-up
# documents the workaround and uses `docker exec -it -u <user> -w <wd> <cid>`
# with the id from `devcontainer up`. So compose takes the docker path, and so
# does anything else once the CLI turns out to be unrunnable.
#
# Every prefix ends in a shell with `-c`, so the caller may always append the
# window's command as ONE further argv element. Without that, `docker exec ...
# <id> 'make test'` would look for a binary literally named "make test". The
# container side uses `sh` rather than `bash`, because a devcontainer image is
# frequently alpine-based and bash is not guaranteed to be installed.
dev_container_exec_prefix() {
  local record_json="$1" window_json="$2" location workdir
  location=$(dev_window_location "$record_json" "$window_json") || return 1
  if [[ "$location" == host ]]; then
    printf '%s\n' bash -lc
    return 0
  fi

  local id user kind worktree
  id=$(jq -r '.container.id // empty' <<<"$record_json")
  user=$(jq -r '.container.user // empty' <<<"$record_json")
  kind=$(jq -r '.container.kind // "single"' <<<"$record_json")
  worktree=$(jq -r '.worktree' <<<"$record_json")

  if [[ -z "$id" || "$id" == null ]]; then
    echo "dev: no live container binding for a container-located window" >&2
    return 1
  fi

  if [[ "$kind" != compose ]]; then
    local cli
    if cli=$(dev_runtime_devcontainer_cli 2>/dev/null); then
      local -a cliv
      read -r -a cliv <<<"$cli"
      # `devcontainer exec` has no -w. The working directory is applied by the
      # inner command instead (dev_window_inner_command), which is also how the
      # host and docker paths honor `cwd`, so all three agree.
      printf '%s\n' "${cliv[@]}" exec --workspace-folder "$worktree" sh -c
      return 0
    fi
  fi

  # No defaults here on purpose: user and workdir are written by the same
  # container.ready event that wrote the id (ADR-1), so a missing one means the
  # binding is stale, not that root and /workspace are a safe guess.
  workdir=$(dev_window_workdir "$record_json" "$window_json") || {
    echo "dev: no live container binding (workdir missing) for this window" >&2
    return 1
  }
  if [[ -z "$user" || "$user" == null ]]; then
    echo "dev: no live container binding (user missing) for this window" >&2
    return 1
  fi
  printf '%s\n' docker exec -i -t -u "$user" -w "$workdir" "$id" sh -c
}

# The single shell-command argv element that follows the prefix.
#
# This is where `environment`, `cwd`, and the agent-vs-command choice are all
# actually applied. They were validated in Task 4 and then, until this function
# existed, dropped on the floor: every window ran $SHELL in the worktree with no
# environment injected. Doing it here rather than through per-transport flags
# (`docker exec -e`, `--remote-env`, `new-window -c`) means one implementation
# covers the host path, the docker path and the devcontainer-CLI path
# identically, and the CLI path has no working-directory flag at all.
#
# `exec` replaces the wrapper shell so that the pane's process IS the agent or
# command; otherwise `pane-died` would report the wrapper's exit, not the
# agent's, and every agent would sit behind a stray shell.
dev_window_inner_command() {
  local record_json="$1" window_json="$2" env_json="${3:-{\}}"
  local location workdir agent command assignments inner

  location=$(dev_window_location "$record_json" "$window_json") || return 1
  workdir=$(dev_window_workdir "$record_json" "$window_json") || return 1
  agent=$(jq -r '.agent // ""' <<<"$window_json")
  command=$(jq -r '.command // ""' <<<"$window_json")

  # Agent windows exec their process directly, so shell init never wires the
  # vekil proxy env the way an interactive shell would (ai/vekil/env.zsh).
  # Merge the overlay UNDER the declared environment: explicit keys win, and
  # an unreachable proxy contributes {} so agents fall back to direct.
  if [[ -n "$agent" ]]; then
    local vekil_env
    vekil_env=$(dev_vekil_env_json "$location")
    env_json=$(jq -nc --argjson v "$vekil_env" --argjson e "$env_json" '$v + $e')
  fi

  # jq's @sh quotes each value for POSIX sh, so a value containing a space,
  # quote or newline survives intact.
  assignments=$(jq -r 'to_entries | map("\(.key)=" + (.value | tostring | @sh))
    | join(" ")' <<<"$env_json")

  if [[ -n "$agent" ]]; then
    inner="exec $agent"
  elif [[ -n "$command" ]]; then
    inner="exec $command"
  elif [[ "$location" == host ]]; then
    inner='exec "${SHELL:-/bin/bash}" -l'
  else
    # The host's $SHELL says nothing about what exists in the container.
    inner='exec bash -l 2>/dev/null || exec sh -l'
  fi

  # `export ...; exec ...` rather than `env ... exec ...`. `exec` is a shell
  # builtin, so `env FOO=1 exec cmd` asks env(1) to run a binary called `exec`,
  # which does not exist -- every window with an `environment` entry would have
  # died instantly. export also composes with the two-branch container fallback
  # above, which a single env(1) invocation cannot.
  if [[ -n "$assignments" ]]; then
    inner="export $assignments; $inner"
  fi
  printf 'cd %q || exit 1; %s\n' "$workdir" "$inner"
}
