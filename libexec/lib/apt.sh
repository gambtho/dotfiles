#!/usr/bin/env bash
# APT calls that wait for another package manager instead of failing. A fresh
# Ubuntu server runs unattended upgrades and its daily index refresh during the
# first minutes after boot, which is exactly when provisioning runs. Sourced,
# never executed; must not change the caller's shell options.

source "$(dirname "${BASH_SOURCE[0]}")/../log-helper"

# Seconds to wait for a lock before giving up.
APT_LOCK_TIMEOUT="${DOTFILES_APT_LOCK_TIMEOUT:-600}"

# sudo_apt TOOL SUBCOMMAND [ARG...]: run `sudo apt` or `sudo apt-get`.
# APT's own timeout covers the dpkg locks that install, upgrade and remove
# take. It does not cover the package-index lock that `update` takes, so retry
# that one here, and only when the failure names that lock.
sudo_apt() {
  local tool="$1" subcommand="$2"
  shift 2
  local -a command=(sudo "$tool" "$subcommand" -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" "$@")
  if [[ "$subcommand" != update ]]; then
    "${command[@]}"
    return
  fi

  local deadline=$((SECONDS + APT_LOCK_TIMEOUT)) errors status
  errors=$(mktemp "${TMPDIR:-/tmp}/apt-update.XXXXXX") || return
  while :; do
    status=0
    "${command[@]}" 2>"$errors" || status=$?
    if ((status == 0 || SECONDS >= deadline)) || ! grep -q 'lists/lock' "$errors"; then
      break
    fi
    log_info "Another process is refreshing the package index; waiting."
    sleep 5
  done
  cat "$errors" >&2
  rm -f -- "$errors"
  return "$status"
}
