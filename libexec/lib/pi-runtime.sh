#!/usr/bin/env bash
# Read-only discovery of the selected Pi runtime. Sourcing preserves shell options.

_pi_runtime_real_path() {
  local path=$1 directory target links=0
  [[ "$path" == /* ]] || path="$PWD/$path"
  while :; do
    directory=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || {
      printf 'error: missing Pi runtime path %s\n' "$path" >&2
      return 1
    }
    path="$directory/${path##*/}"
    [[ -L "$path" ]] || break
    links=$((links + 1))
    if ((links > 40)); then
      printf 'error: Pi runtime symlink loop at %s\n' "$path" >&2
      return 1
    fi
    target=$(readlink "$path") || return 1
    if [[ "$target" == /* ]]; then
      path=$target
    else
      path="$directory/$target"
    fi
  done
  [[ -e "$path" ]] || {
    printf 'error: missing Pi runtime path %s\n' "$path" >&2
    return 1
  }
  printf '%s\n' "$path"
}

# resolve_pi_runtime PI_EXECUTABLE [EXPLICIT_PACKAGE_ROOT]
# Results are published only after validating the core entry and Jiti CLI.
resolve_pi_runtime() {
  local executable=${1:-} package_root=${2:-} resolved directory marker version_file version
  local search boundary="" modules="" jiti=""
  PI_RUNTIME_PACKAGE_ROOT=""
  PI_RUNTIME_JITI_CLI=""
  PI_RUNTIME_NODE_MODULES=""

  if [[ -z "$package_root" ]]; then
    [[ -n "$executable" ]] || {
      printf 'error: Pi executable not found on PATH\n' >&2
      return 1
    }
    resolved=$(_pi_runtime_real_path "$executable") || return 1
    [[ -f "$resolved" && -x "$resolved" ]] || {
      printf 'error: invalid Pi executable %s\n' "$resolved" >&2
      return 1
    }
    directory=${resolved%/*}
    if [[ "$directory" == */bin && "${resolved##*/}" == pi ]]; then
      marker="${directory%/bin}/install/managed-install.json"
      [[ -f "$marker" && ! -L "$marker" ]] &&
        jq -e '.kind == "pi-managed-install" and .schemaVersion == 1 and .layout == "releases-v1"' \
          "$marker" >/dev/null 2>&1 || {
        printf 'error: missing or invalid Pi managed marker %s\n' "$marker" >&2
        return 1
      }
      version_file="${directory%/bin}/install/current-version"
      [[ -f "$version_file" && ! -L "$version_file" ]] || {
        printf 'error: missing or invalid Pi managed version %s\n' "$version_file" >&2
        return 1
      }
      # Read the whole file: reject traversal, extra lines, whitespace and NULs.
      version=$(jq -Rers 'if test("^[0-9][A-Za-z0-9._+-]*\\n?\\z") then rtrimstr("\n") else error("invalid version") end' \
        "$version_file" 2>/dev/null) || {
        printf 'error: invalid Pi managed version in %s\n' "$version_file" >&2
        return 1
      }
      package_root="${directory%/bin}/install/releases/$version/node_modules/@earendil-works/pi-coding-agent"
    else
      case "$resolved" in
        */dist/cli.js) package_root=${resolved%/dist/cli.js} ;;
        */dist/bundle/cli.js) package_root=${resolved%/dist/bundle/cli.js} ;;
        *)
          printf 'error: unrecognized Pi executable %s\n' "$resolved" >&2
          return 1
          ;;
      esac
    fi
  fi

  [[ -f "$package_root/dist/index.js" ]] || {
    printf 'error: Pi extension API entry not installed at %s/dist/index.js\n' "$package_root" >&2
    return 1
  }
  package_root=$(cd -P "$package_root" && pwd -P) || return 1

  # Stop at the nearest enclosing node_modules (the selected release/npm tree),
  # never borrowing Jiti from another runtime or an ambient global installation.
  search=$package_root
  while [[ "$search" != / ]]; do
    if [[ "${search##*/}" == node_modules ]]; then
      boundary=$search
      break
    fi
    search=${search%/*}
    [[ -n "$search" ]] || search=/
  done
  search=$package_root
  while :; do
    if [[ "${search##*/}" == node_modules ]]; then
      modules=$search
    else
      modules="$search/node_modules"
    fi
    if [[ -f "$modules/jiti/lib/jiti-cli.mjs" ]]; then
      jiti=$(_pi_runtime_real_path "$modules/jiti/lib/jiti-cli.mjs") || return 1
      modules=$(cd -P "$modules" && pwd -P) || return 1
      break
    fi
    [[ -n "$boundary" && "$search" != "$boundary" ]] || {
      printf 'error: Pi bundled jiti not installed in selected package ancestry at %s\n' "$package_root" >&2
      return 1
    }
    search=${search%/*}
  done

  # shellcheck disable=SC2034 # Results consumed by callers sourcing this helper.
  PI_RUNTIME_PACKAGE_ROOT=$package_root
  # shellcheck disable=SC2034
  PI_RUNTIME_JITI_CLI=$jiti
  # shellcheck disable=SC2034
  PI_RUNTIME_NODE_MODULES=$modules
}
