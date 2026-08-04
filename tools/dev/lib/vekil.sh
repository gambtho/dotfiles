#!/usr/bin/env bash
# vekil.sh — route agent windows through the vekil proxy when it is up.
#
# ai/vekil/env.zsh wires ANTHROPIC_*/OPENAI_* into INTERACTIVE zsh, which is
# how agents reached the proxy before this platform: the old flow ended in a
# login shell. dev's agent panes exec the agent directly through `sh -c`
# (deliberately: the pane's process IS the agent, and alpine images have no
# zsh), so shell init never runs and the agent silently connected straight to
# the provider. This is the bash port of env.zsh's core decision, evaluated
# host-side at open/respawn time.
#
# Semantics kept from env.zsh:
#   - proxy not ready -> inject NOTHING, the agent falls back to direct.
#   - inside a container the proxy is reachable as host.docker.internal;
#     readiness is still probed host-side, where dev always runs.
#   - injected values are defaults: an explicit `environment:` key in the
#     merged workspace config wins (jq `$vekil + $declared`).
#
# The env is baked into the pane command at creation, so a proxy that dies
# later leaves existing panes pointed at it until the next open/respawn —
# unlike the zsh hook, which re-evaluates per new shell. Accepted trade.

# Probes once per process; later calls reuse the verdict.
DEV_VEKIL_PROBE=""
DEV_VEKIL_HOST=""
DEV_VEKIL_PORT=""

dev_vekil_probe() {
  if [[ -n "$DEV_VEKIL_PROBE" ]]; then
    [[ "$DEV_VEKIL_PROBE" == ok ]]
    return
  fi
  DEV_VEKIL_PROBE=fail

  local port host state_dir
  port="${VEKIL_PORT:-1337}"
  [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1

  state_dir="${VEKIL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vekil}"
  [[ -f "$state_dir/proxy-host" && -r "$state_dir/proxy-host" ]] || return 1
  [[ -f "$state_dir/proxy-ready" ]] || return 1
  host=$(<"$state_dir/proxy-host")
  [[ -n "$host" && "$host" != *[[:space:]]* ]] || return 1

  command -v curl >/dev/null 2>&1 || return 1
  curl --fail --silent --connect-timeout 0.5 --max-time 1 \
    "http://${host}:${port}/readyz" >/dev/null 2>&1 || return 1

  DEV_VEKIL_PROBE=ok
  DEV_VEKIL_HOST="$host"
  DEV_VEKIL_PORT="$port"
}

# Prints the env overlay for one window location as a JSON object; {} when the
# proxy is not ready, so callers can merge unconditionally.
dev_vekil_env_json() {
  local location="$1" host
  if ! dev_vekil_probe; then
    printf '{}\n'
    return 0
  fi
  # dev runs on the host, but a container-located pane reaches the host's
  # proxy through Docker's gateway alias, exactly as env.zsh decides when it
  # finds itself inside a container.
  if [[ "$location" == host ]]; then
    host="$DEV_VEKIL_HOST"
  else
    host=host.docker.internal
  fi
  jq -nc --arg h "$host" --arg p "$DEV_VEKIL_PORT" '{
    ANTHROPIC_BASE_URL: "http://\($h):\($p)",
    ANTHROPIC_API_KEY: "dummy",
    ANTHROPIC_MODEL: "claude-opus-5",
    CLAUDE_CODE_DISABLE_ADVISOR_TOOL: "1",
    OPENAI_BASE_URL: "http://\($h):\($p)/v1",
    OPENAI_API_KEY: "dummy"
  }'
}
