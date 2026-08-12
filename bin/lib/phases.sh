#!/usr/bin/env bash
# Install-phase runner shared by bin/install and bin/bootstrap: run each phase,
# collect required failures and optional warnings, and summarize at the end.
# Sourced, never executed; must not change the caller's shell options.

source "$(dirname "${BASH_SOURCE[0]}")/../log-helper"

# Include guard — the one lib slice holding MUTABLE state. A script that
# sources bin/common.sh and later this file directly must not re-run the
# initializers below and silently discard already-recorded phase failures.
# (The other slices carry only functions and constants, where re-sourcing is
# harmless; an `if`, not `[ ] && return`, so a first source under the
# caller's `set -e` does not abort on the guard's own false status.)
if [ -n "${DOTFILES_LIB_PHASES_SOURCED:-}" ]; then
  return 0
fi
DOTFILES_LIB_PHASES_SOURCED=1

PHASE_FAILURES=()
PHASE_WARNINGS=()

run_phase() {
  local requirement="$1"
  local name="$2"
  shift 2

  log_info "Starting phase: $name"
  if "$@"; then
    log_success "Completed phase: $name"
    return 0
  fi

  if [[ "$requirement" == required ]]; then
    PHASE_FAILURES+=("$name")
    printf 'Required phase failed: %s\n' "$name" >&2
  else
    PHASE_WARNINGS+=("$name")
    log_warning "Optional phase failed: $name"
  fi
  return 0
}

finish_phases() {
  local name
  # The ${arr[@]+...} form matters: callers now run under set -u, and bash 3.2
  # (macOS) treats expanding an EMPTY array as an unbound-variable error.
  for name in ${PHASE_WARNINGS[@]+"${PHASE_WARNINGS[@]}"}; do
    printf 'WARNING: %s\n' "$name"
  done
  for name in ${PHASE_FAILURES[@]+"${PHASE_FAILURES[@]}"}; do
    printf 'FAILED: %s\n' "$name" >&2
  done
  ((${#PHASE_FAILURES[@]} == 0))
}
