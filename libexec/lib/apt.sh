#!/usr/bin/env bash
# APT calls that wait for another package manager instead of failing. A fresh
# Ubuntu server runs unattended upgrades and its daily index refresh during the
# first minutes after boot, which is exactly when provisioning runs. Sourced,
# never executed; must not change the caller's shell options.

source "$(dirname "${BASH_SOURCE[0]}")/../log-helper"

# Seconds to wait for a lock before giving up.
APT_LOCK_TIMEOUT="${DOTFILES_APT_LOCK_TIMEOUT:-600}"

# sudo_apt TOOL SUBCOMMAND [ARG...]: run `sudo apt` or `sudo apt-get`.
# APT's own timeout covers the dpkg locks. It does not cover the package-index
# and download-cache locks, so retry here when a failure names one of those as
# held. stderr is shown once, for the last attempt.
sudo_apt() {
  local tool="$1" subcommand="$2"
  shift 2
  local deadline=$((SECONDS + APT_LOCK_TIMEOUT)) pause=5 errors status
  errors=$(mktemp "${TMPDIR:-/tmp}/apt-errors.XXXXXX") || return
  while :; do
    status=0
    sudo "$tool" "$subcommand" -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" "$@" 2>"$errors" || status=$?
    if ((status == 0 || SECONDS + pause > deadline)) ||
      ! grep -Eq 'Could not get lock .*/(lists|archives)/lock' "$errors"; then
      break
    fi
    log_info "Another process holds a package lock; waiting."
    sleep "$pause"
  done
  cat "$errors" >&2
  rm -f -- "$errors"
  return "$status"
}
