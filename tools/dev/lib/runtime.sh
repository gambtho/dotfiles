#!/usr/bin/env bash
# runtime.sh — detection, never hardcoding. Docker reachability, devcontainer
# kind, and the devcontainer CLI resolved to an *invocation* rather than a path.
#
# The CLI is never detected with `command -v`: on this machine the mise shim
# resolves, is executable, and fails on every call because the package lives
# under a node version that is no longer global (spec §0). Detection therefore
# executes `devcontainer --version` and requires exit 0 AND a parseable version.

DEV_RUNTIME_CACHE_TTL="${DEV_RUNTIME_CACHE_TTL:-86400}"

dev_runtime_mise_bin() {
  local candidate
  for candidate in "$HOME/.local/bin/mise" /usr/local/bin/mise; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate=$(command -v mise 2>/dev/null) || return 1
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

dev_runtime_cli_spec() {
  local toml="$DEV_DOTFILES_ROOT/config/mise/config.toml" version
  [[ -f "$toml" ]] || return 1
  version=$(sed -n \
    's/^"npm:@devcontainers\/cli"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$toml" | head -n 1)
  [[ -n "$version" ]] || return 1
  printf 'npm:@devcontainers/cli@%s\n' "$version"
}

dev_runtime_devcontainer_cli() {
  local mise_bin spec out
  mise_bin=$(dev_runtime_mise_bin) || {
    echo "dev: no mise binary found; the devcontainer CLI cannot be invoked" >&2
    return 6
  }
  spec=$(dev_runtime_cli_spec) || {
    echo "dev: no devcontainer CLI pin in config/mise/config.toml" >&2
    return 6
  }
  out=$("$mise_bin" exec "$spec" -- devcontainer --version 2>/dev/null) || {
    echo "dev: devcontainer CLI present but unrunnable ($mise_bin exec $spec)" >&2
    return 6
  }
  out=${out%%$'\n'*}
  [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || {
    echo "dev: 'devcontainer --version' printed no parseable version: $out" >&2
    return 6
  }
  printf '%s exec %s -- devcontainer\n' "$mise_bin" "$spec"
}

dev_runtime_docker_ok() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# devcontainer.json is JSONC. Strip // comments that are outside string
# literals, then trailing commas, so jq can parse it. A literal ", }" inside a
# string would be mangled; no devcontainer.json in ~/workspace contains one.
dev_runtime_jsonc_to_json() {
  awk '
    {
      out = ""; instr = 0; i = 1; n = length($0)
      while (i <= n) {
        c = substr($0, i, 1)
        if (instr) {
          out = out c
          if (c == "\\") { i++; out = out substr($0, i, 1) }
          else if (c == "\"") { instr = 0 }
        } else if (c == "\"") { instr = 1; out = out c }
        else if (c == "/" && substr($0, i + 1, 1) == "/") { break }
        else { out = out c }
        i++
      }
      print out
    }
  ' "$1" | tr '\n' ' ' | sed 's/,[[:space:]]*}/}/g; s/,[[:space:]]*]/]/g'
}

dev_runtime_kind() {
  local worktree="$1" cfg
  for cfg in "$worktree/.devcontainer/devcontainer.json" "$worktree/.devcontainer.json"; do
    if [[ -f "$cfg" ]]; then
      if dev_runtime_jsonc_to_json "$cfg" |
        jq -e 'has("dockerComposeFile")' >/dev/null 2>&1; then
        printf 'compose\n'
      else
        printf 'single\n'
      fi
      return 0
    fi
  done
  if [[ -d "$worktree/.devcontainer" ]]; then
    printf 'single\n'
    return 0
  fi
  printf 'none\n'
}

dev_runtime_detect() {
  local cache="$DEV_STATE_ROOT/runtime.json" now_epoch mtime
  if [[ -f "$cache" ]]; then
    now_epoch=$(date +%s)
    mtime=$(stat -c %Y "$cache" 2>/dev/null || printf '0\n')
    if ((now_epoch - mtime < DEV_RUNTIME_CACHE_TTL)); then
      cat "$cache"
      return 0
    fi
  fi

  local docker_ok=false mise_bin spec cli
  if dev_runtime_docker_ok; then docker_ok=true; fi
  mise_bin=$(dev_runtime_mise_bin) || mise_bin=""
  spec=$(dev_runtime_cli_spec) || spec=""
  cli=$(dev_runtime_devcontainer_cli 2>/dev/null) || cli=""

  mkdir -p "$DEV_STATE_ROOT"
  jq -nc --argjson d "$docker_ok" --arg m "$mise_bin" --arg s "$spec" --arg c "$cli" \
    '{docker: $d, mise: $m, cli_spec: $s, devcontainer: $c}' >"$cache.tmp"
  mv "$cache.tmp" "$cache"
  cat "$cache"
}
