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
  mkdir -p "$CHECKOUT/bin" "$HOME/.pi/agent/bin"
  printf '#!/bin/sh\n' | tee "$CHECKOUT/bin/gh" "$HOME/.pi/agent/bin/pi" >/dev/null
  chmod +x "$CHECKOUT/bin/gh" "$HOME/.pi/agent/bin/pi"
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

@test "automation install rejects a service PATH with only the gh shim" {
  add_service_tools bwrap mise pi python3
  ln -s "$CHECKOUT/bin/gh" "$SERVICE_BIN/gh"
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the bin/gh shim"* ]]
}

@test "automation install accepts a real gh after the shim without reordering PATH" {
  add_service_tools bwrap mise pi python3
  mkdir -p "$HOME/real-bin"
  ln -s "$STUB_BIN/gh" "$HOME/real-bin/gh"
  ln -s "$CHECKOUT/bin/gh" "$SERVICE_BIN/gh"
  printf 'Environment=PATH=%%h/service-bin:%%h/real-bin\n' >"$CHECKOUT/tools/automations/systemd/dotfiles-automation@.service"
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"units expect the checkout"* ]]
  grep -Fxq 'Environment=PATH=%h/service-bin:%h/real-bin' "$CHECKOUT/tools/automations/systemd/dotfiles-automation@.service"
}

@test "automation install requires Pi at the path the runner launches" {
  add_service_tools bwrap gh mise pi python3
  rm "$HOME/.pi/agent/bin/pi"
  run bash "$CHECKOUT/tools/automations/install.sh" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"runner needs Pi at $HOME/.pi/agent/bin/pi"* ]]
}

@test "the shipped service unit keeps the gh shim ahead of the real gh" {
  run grep -c '^Environment=PATH=%h/.dotfiles/bin:' "$REPO_ROOT/tools/automations/systemd/dotfiles-automation@.service"
  [ "$output" = 1 ]
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
