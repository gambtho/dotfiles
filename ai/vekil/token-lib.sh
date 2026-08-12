#!/usr/bin/env bash
# Vekil access-token safety checks, shared by bin/vekil-proxy and
# ai/vekil/install.sh. Lives beside the rest of the Vekil tooling rather than
# in bin/common.sh so unrelated installers stop transitively loading Vekil
# auth logic. Sourced, never executed; must not change the caller's shell
# options.

validate_vekil_access_token() {
  local access_token_file="$1"
  [[ -e "$access_token_file" || -L "$access_token_file" ]] || return 0
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be absent or a regular file: %s\n' "$access_token_file" >&2
    return 1
  }

  chmod 0600 "$access_token_file" || return 1
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be a regular file: %s\n' "$access_token_file" >&2
    return 1
  }
}
