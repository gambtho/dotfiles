#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CHECKOUT="$HOME/.dotfiles"
  INSTALLER="$CHECKOUT/tools/cache-maintenance/install.sh"
  UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"
  export CALLS="$TEST_ROOT/systemctl.calls"
  mkdir -p "$CHECKOUT/tools/cache-maintenance/systemd"
  git init -q "$CHECKOUT"
  if [[ -d "$REPO_ROOT/tools/cache-maintenance" ]]; then
    cp -R "$REPO_ROOT/tools/cache-maintenance/." "$CHECKOUT/tools/cache-maintenance/"
  fi
  # Installation must never execute even this harmless stand-in for the helper.
  mkdir -p "$CHECKOUT/libexec"
  printf '#!/bin/sh\necho unexpected-cleanup >>"$CALLS"\nexit 99\n' >"$CHECKOUT/libexec/cache-prune"
  stub_command systemctl '
printf "%s\n" "$*" >>"$CALLS"
if [[ ${MANAGER_FAIL:-0} == 1 ]]; then echo "user manager unavailable" >&2; exit 1; fi
case "$*" in
  *--property=LoadState*) echo "${UNIT_STATE:-not-found}" ;;
  *--property=ExecMainStartTimestamp*) echo "${LAST_START:-}" ;;
  *--property=Result*) printf "Result=success\nExecMainStatus=0\n" ;;
esac'
  stub_command loginctl 'printf "loginctl %s\n" "$*" >>"$CALLS"; echo no'
  local tool
  for tool in go uv npm; do
    stub_command "$tool" 'echo unexpected-optional-tool >>"$CALLS"; exit 99'
  done
}

@test "cache timer installation copies units and enables only the timer" {
  export UNIT_STATE=loaded
  run bash "$INSTALLER" --apply
  [ "$status" -eq 0 ]
  cmp "$CHECKOUT/tools/cache-maintenance/systemd/dotfiles-cache-prune.service" "$UNIT_DIR/dotfiles-cache-prune.service"
  cmp "$CHECKOUT/tools/cache-maintenance/systemd/dotfiles-cache-prune.timer" "$UNIT_DIR/dotfiles-cache-prune.timer"
  grep -Fxq -- '--user daemon-reload' "$CALLS"
  grep -Fxq -- '--user enable --now dotfiles-cache-prune.timer' "$CALLS"
  if grep -Eq 'unexpected-cleanup|unexpected-optional-tool|enable.*\.service|--user start|enable-linger' "$CALLS"; then return 1; fi
  [[ "$output" == *"linger is off"* ]]
}

@test "cache timer check reports not installed without writes" {
  run bash "$INSTALLER" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
  [ ! -e "$UNIT_DIR" ]
  if grep -Eq 'daemon-reload|enable|start|unexpected-cleanup' "$CALLS"; then return 1; fi
}

@test "cache timer check distinguishes never run and last result" {
  export UNIT_STATE=loaded
  run bash "$INSTALLER" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"never run"* ]]
  export LAST_START='Thu 2026-01-01 04:00:00 UTC'
  run bash "$INSTALLER" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Result=success"* ]]
  [[ "$output" == *"journalctl --user"* ]]
  [ ! -e "$UNIT_DIR" ]
  if grep -Eq 'daemon-reload|enable|--user start|unexpected-cleanup' "$CALLS"; then return 1; fi
}

@test "cache timer check does not hide an unavailable user manager" {
  export MANAGER_FAIL=1
  run bash "$INSTALLER" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *"user manager unavailable"* ]]
  [ ! -e "$UNIT_DIR" ]
}

@test "cache timer installer rejects unknown or extra arguments before side effects" {
  local args
  for args in '' '--bad' '--apply extra' '--check extra'; do
    # Intentional word splitting supplies the literal argument variants above.
    # shellcheck disable=SC2086
    run bash "$INSTALLER" $args
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
    [ ! -e "$CALLS" ]
    [ ! -e "$UNIT_DIR" ]
  done
}

@test "cache timer refuses a noncanonical checkout before unit writes" {
  mv "$CHECKOUT" "$HOME/other-checkout"
  run bash "$HOME/other-checkout/tools/cache-maintenance/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"units expect the checkout"* ]]
  [ ! -e "$UNIT_DIR" ]
  [ ! -e "$CALLS" ]
}

@test "cache timer refuses a linked worktree before unit writes" {
  git -C "$CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
  git -C "$CHECKOUT" add tools libexec
  git -C "$CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm sources
  git -C "$CHECKOUT" worktree add -q -b fixture-linked "$HOME/linked"
  run bash "$HOME/linked/tools/cache-maintenance/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a linked worktree"* ]]
  [ ! -e "$UNIT_DIR" ]
  [ ! -e "$CALLS" ]
}

@test "cache timer host preflight uses service PATH without requiring optional tools" {
  printf 'Environment=PATH=%%h/empty-bin\n' >"$CHECKOUT/tools/cache-maintenance/systemd/dotfiles-cache-prune.service"
  run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on the service PATH"* ]]
  [ ! -e "$UNIT_DIR" ]
  [ ! -e "$CALLS" ]
}

@test "cache timer install refuses non Linux hosts" {
  stub_command uname 'echo Darwin'
  run bash "$INSTALLER" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"Linux"* ]]
  [ ! -e "$UNIT_DIR" ]
  [ ! -e "$CALLS" ]
}

@test "cache timer schedule has no catch up and remains separate opt in" {
  local units="$REPO_ROOT/tools/cache-maintenance/systemd"
  grep -Fxq 'OnCalendar=Sun *-*-* 04:00:00' "$units/dotfiles-cache-prune.timer"
  grep -Fxq 'Persistent=false' "$units/dotfiles-cache-prune.timer"
  grep -Fxq 'RandomizedDelaySec=30m' "$units/dotfiles-cache-prune.timer"
  grep -Fxq 'TimeoutStartSec=15min' "$units/dotfiles-cache-prune.service"
  grep -Fxq 'ExecStart=/bin/bash %h/.dotfiles/libexec/cache-prune' "$units/dotfiles-cache-prune.service"
  run make -s -n -C "$REPO_ROOT" cache-maintenance
  [ "$status" -eq 0 ]
  [[ "$output" == *'bash tools/cache-maintenance/install.sh --apply'* ]]
  run make -s -n -C "$REPO_ROOT" cache-maintenance-check
  [ "$status" -eq 0 ]
  [[ "$output" == *'bash tools/cache-maintenance/install.sh --check'* ]]
  run make -s -n -C "$REPO_ROOT" install update ai automations
  [ "$status" -eq 0 ]
  [[ "$output" != *cache-maintenance* ]]
}
