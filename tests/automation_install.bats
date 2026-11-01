#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  CHECKOUT="$TEST_ROOT/checkout"
  SERVICE_BIN="$HOME/service-bin"
  mkdir -p "$CHECKOUT/tools/automations/systemd" "$SERVICE_BIN"
  cp "$REPO_ROOT/tools/automations/install.sh" "$CHECKOUT/tools/automations/"
  printf 'Environment=PATH=%%h/service-bin\n' >"$CHECKOUT/tools/automations/systemd/dotfiles-automation@.service"
  git init -q "$CHECKOUT"
  # Every tool is on the installer's own PATH, so only the service PATH can fail.
  local tool
  for tool in systemctl bwrap gh mise pi python3; do
    printf '#!/bin/sh\n' >"$STUB_BIN/$tool"
    chmod +x "$STUB_BIN/$tool"
  done
  PATH="$STUB_BIN:$PATH"
}

add_service_tools() {
  local tool
  for tool in "$@"; do
    ln -sf "$STUB_BIN/$tool" "$SERVICE_BIN/$tool"
  done
}

@test "automation install rejects a tool only the installer's PATH can find" {
  add_service_tools bwrap mise pi python3
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh is not on the PATH the timers use"* ]]
  [[ "$output" == *"$HOME/service-bin"* ]]
}

@test "automation install passes the host check when the service PATH has every tool" {
  add_service_tools bwrap gh mise pi python3
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" != *"not on the PATH"* ]]
  [[ "$output" == *"units expect the checkout"* ]]
}

@test "automation install fails clearly when the unit sets no PATH" {
  : >"$CHECKOUT/tools/automations/systemd/dotfiles-automation@.service"
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not set PATH"* ]]
}

@test "the shipped service unit sets the PATH the installer reads" {
  run grep -c '^Environment=PATH=' "$REPO_ROOT/tools/automations/systemd/dotfiles-automation@.service"
  [ "$output" = 1 ]
}
