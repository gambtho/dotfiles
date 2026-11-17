#!/usr/bin/env bats

load test_helper

# Probes go into a private copy of the current working tree, never the real
# checkout, so parallel suites cannot see them. The copy keeps current bytes and
# ignore rules: tracked files stay tracked, untracked ones stay untracked.
make_discovery_checkout() {
  CHECKOUT="$TEST_ROOT/checkout"
  mkdir -p "$CHECKOUT"
  git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard |
    (cd "$REPO_ROOT" && while IFS= read -r -d '' path; do
      [[ -f "$path" || -L "$path" ]] && printf '%s\0' "$path"
    done) |
    (cd "$REPO_ROOT" && tar --null -T - -cf -) | tar -xf - -C "$CHECKOUT"
  git -C "$CHECKOUT" init -q
  git -C "$REPO_ROOT" ls-files -z --cached |
    (cd "$CHECKOUT" && while IFS= read -r -d '' path; do
      [[ -f "$path" || -L "$path" ]] && printf '%s\0' "$path"
    done) | git -C "$CHECKOUT" add -f --pathspec-from-file=- --pathspec-file-nul
}

setup() {
  setup_dotfiles_test
  make_discovery_checkout
  UNTRACKED_FILE="$CHECKOUT/bin/example-check-script-$BATS_TEST_NUMBER"
  IGNORED_DIR="$CHECKOUT/bin/.opencode"
  IGNORED_FILE="$IGNORED_DIR/project-$BATS_TEST_NUMBER.sh"
  mkdir -p "$IGNORED_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$UNTRACKED_FILE"
  printf '#!/usr/bin/env bash\nfalse\n' >"$IGNORED_FILE"

  DIRECT_SH_FILE="$CHECKOUT/bin/probe-direct-sh-$BATS_TEST_NUMBER"
  SPACED_SHELL_FILE="$CHECKOUT/bin/probe-spaced-shell-$BATS_TEST_NUMBER"
  ENV_SPLIT_SHELL_FILE="$CHECKOUT/bin/probe-env-split-shell-$BATS_TEST_NUMBER"
  CUSTOM_SHELL_FILE="$CHECKOUT/bin/probe-custom-shell-$BATS_TEST_NUMBER"
  ENV_CUSTOM_SHELL_FILE="$CHECKOUT/bin/probe-env-custom-shell-$BATS_TEST_NUMBER"
  PYTHON_FILE="$CHECKOUT/bin/probe-python-$BATS_TEST_NUMBER"
  ENV_SEPARATOR_PYTHON_FILE="$CHECKOUT/bin/probe-env-separator-python-$BATS_TEST_NUMBER"
  ENV_IGNORE_PYTHON_FILE="$CHECKOUT/bin/probe-env-ignore-python-$BATS_TEST_NUMBER"
  ENV_ASSIGN_PYTHON_FILE="$CHECKOUT/bin/probe-env-assign-python-$BATS_TEST_NUMBER"
  FISH_FILE="$CHECKOUT/bin/probe-fish-$BATS_TEST_NUMBER"
  UNKNOWN_FILE="$CHECKOUT/bin/probe-unknown-$BATS_TEST_NUMBER"
  EMPTY_FILE="$CHECKOUT/bin/probe-empty-$BATS_TEST_NUMBER"
  printf '#!/bin/sh\ntrue\n' >"$DIRECT_SH_FILE"
  printf '#!  /usr/bin/zsh -f\ntrue\n' >"$SPACED_SHELL_FILE"
  printf '#!/usr/bin/env -S bash -e\ntrue\n' >"$ENV_SPLIT_SHELL_FILE"
  printf '#!/usr/bin/custom-shell\n' >"$CUSTOM_SHELL_FILE"
  printf '#!/usr/bin/env custom-shell\n' >"$ENV_CUSTOM_SHELL_FILE"
  printf '#!/usr/bin/env python3\n' >"$PYTHON_FILE"
  printf '#!/usr/bin/env -- python3\n' >"$ENV_SEPARATOR_PYTHON_FILE"
  printf '#!/usr/bin/env -i python3\n' >"$ENV_IGNORE_PYTHON_FILE"
  printf '#!/usr/bin/env MODE=check python3\n' >"$ENV_ASSIGN_PYTHON_FILE"
  printf '#!/usr/bin/fish\n' >"$FISH_FILE"
  printf 'unrecognized extensionless content\n' >"$UNKNOWN_FILE"
  : >"$EMPTY_FILE"

  # Probes for a tools/ subdirectory. tools/herdr hosts the real Herdr
  # installer, but this fixture writes its own probe files there rather than
  # relying on that installer's actual layout — that keeps the gate honest if
  # the installer is later renamed or moved.
  #
  # These probes previously lived in tools/dev/ as a second, parallel set.
  # tools/dev/ is gone (design §13 step 8) and the discovery rules were never
  # keyed on it (libexec/list-check-files matches tools/*), so one set covers
  # the same predicate.
  TOOL_PROBE_DIR="$CHECKOUT/tools/herdr"
  TOOL_SUB_DIR="$TOOL_PROBE_DIR/probe-lib-$BATS_TEST_NUMBER"
  TOOL_INSTALL_FILE="$TOOL_PROBE_DIR/probe-install-$BATS_TEST_NUMBER.sh"
  TOOL_EXEC_FILE="$TOOL_PROBE_DIR/probe-exec-$BATS_TEST_NUMBER"
  TOOL_SUB_FILE="$TOOL_SUB_DIR/probe-$BATS_TEST_NUMBER.sh"
  TOOL_ZSH_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.zsh"
  TOOL_YAML_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.yaml"
  TOOL_CONF_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.tmux.conf"
  TOOL_UNIT_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.service"
  mkdir -p "$TOOL_PROBE_DIR" "$TOOL_SUB_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_INSTALL_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_EXEC_FILE"
  printf 'probe_lib() { :; }\n' >"$TOOL_SUB_FILE"
  printf 'export PROBE=1\n' >"$TOOL_ZSH_FILE"
  printf 'defaults: {}\n' >"$TOOL_YAML_FILE"
  printf 'set -g status on\n' >"$TOOL_CONF_FILE"
  printf '[Unit]\nDescription=probe\n' >"$TOOL_UNIT_FILE"
}

list_files() {
  local class="$1"
  run bash -c 'cd "$3" && "$1/libexec/list-check-files" "$2" | tr "\0" "\n"' _ "$REPO_ROOT" "$class" "$CHECKOUT"
}

@test "bash discovery includes tracked and untracked source but excludes ignored state" {
  list_files bash

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/dot-install"* ]]
  [[ "$output" == *"libexec/common.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$CHECKOUT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$CHECKOUT/"}"* ]]
  [[ "$output" != *"core/shell/zshrc.symlink"* ]]
}

@test "all shipped private shell sources remain in the shell gates" {
  local class file
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    for file in bootstrap relink versions list-check-files validate-ai \
      validate-pi-security-runtime common.sh log-helper \
      lib/artifacts.sh lib/links.sh lib/phases.sh lib/system.sh; do
      printf '%s\n' "$output" | grep -Fxq "libexec/$file"
    done
    ! printf '%s\n' "$output" | grep -Fxq libexec/validate-pi-permission-config
    ! printf '%s\n' "$output" | grep -Fxq libexec/validate-pi-security-runtime.ts
    ! printf '%s\n' "$output" | grep -Fxq libexec/pi-permission-pipeline-checks.ts
  done
}

@test "private command discovery includes shell sources but excludes other interpreters and ignored state" {
  local fixture="$TEST_ROOT/private-discovery" class file
  mkdir -p "$fixture/bin" "$fixture/libexec/lib" "$fixture/libexec/.opencode"
  git init -q "$fixture"
  cp "$REPO_ROOT/libexec/list-check-files" "$fixture/list-check-files"
  printf '.opencode/\n' >"$fixture/.gitignore"
  printf '#!/usr/bin/env bash\ntrue\n' >"$fixture/bin/public-probe"
  printf '#!/bin/sh\ntrue\n' >"$fixture/libexec/tracked-shell"
  printf '#!/usr/bin/env -S bash -e\ntrue\n' >"$fixture/libexec/untracked-shell"
  printf 'slice() { :; }\n' >"$fixture/libexec/lib/slice.sh"
  chmod 0644 "$fixture/libexec/lib/slice.sh"
  printf '#!/usr/bin/env -S python3 -B\n' >"$fixture/libexec/python-probe"
  printf '#!/usr/bin/env node\n' >"$fixture/libexec/node-probe"
  printf 'export {};\n' >"$fixture/libexec/module.ts"
  printf 'unknown shell-like content\n' >"$fixture/libexec/ambiguous"
  : >"$fixture/libexec/empty"
  printf '#!/bin/sh\nfalse\n' >"$fixture/libexec/.opencode/ignored.sh"
  git -C "$fixture" add bin/public-probe libexec/tracked-shell

  for class in bash shellcheck shfmt; do
    run bash -o pipefail -c 'cd "$1"; bash ./list-check-files "$2" | tr "\0" "\n"' \
      _ "$fixture" "$class"
    [ "$status" -eq 0 ]
    for file in bin/public-probe libexec/tracked-shell libexec/untracked-shell \
      libexec/lib/slice.sh libexec/ambiguous libexec/empty; do
      printf '%s\n' "$output" | grep -Fxq "$file"
    done
    for file in libexec/python-probe libexec/node-probe libexec/module.ts \
      libexec/.opencode/ignored.sh; do
      ! printf '%s\n' "$output" | grep -Fxq "$file"
    done
  done
}

@test "zsh discovery includes shell symlinks and zsh sources" {
  list_files zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"core/shell/zshrc.symlink"* ]]
  [[ "$output" == *"core/path.zsh"* ]]
  [[ "$output" != *"bin/dot-install"* ]]
}

@test "bash gates recognize direct /bin/sh shebangs" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${DIRECT_SH_FILE#"$CHECKOUT/"}"* ]]
  done
}

@test "bash gates recognize spaced direct shell shebangs" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${SPACED_SHELL_FILE#"$CHECKOUT/"}"* ]]
  done
}

@test "bash gates recognize env -S shell shebangs" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${ENV_SPLIT_SHELL_FILE#"$CHECKOUT/"}"* ]]
  done
}

@test "bash gates exclude extensionless entry points with known incompatible interpreters" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *"${PYTHON_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${ENV_SEPARATOR_PYTHON_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${ENV_IGNORE_PYTHON_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${ENV_ASSIGN_PYTHON_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${FISH_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"libexec/validate-pi-permission-config"* ]]
  done
}

@test "bash gates include ambiguous explicit and empty extensionless entries" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${CUSTOM_SHELL_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" == *"${ENV_CUSTOM_SHELL_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" == *"${UNKNOWN_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" == *"${EMPTY_FILE#"$CHECKOUT/"}"* ]]
  done
}

@test "shellcheck discovery includes repository shell entry points" {
  list_files shellcheck

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/dot-install"* ]]
  [[ "$output" == *"libexec/common.sh"* ]]
  [[ "$output" == *"ai/pi/install.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$CHECKOUT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$CHECKOUT/"}"* ]]
}

@test "shfmt discovery includes the shared Bats helper" {
  list_files shfmt

  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/test_helper.bash"* ]]
  [[ "$output" == *"libexec/common.sh"* ]]
  [[ "$output" == *"ai/pi/install.sh"* ]]
}

@test "shfmt discovery covers Bats suites" {
  # The suites were format-checked by nothing for either linter, so they drifted
  # silently: two of them were already unformatted when this gate was added.
  # shfmt only — bash -n and shellcheck cannot parse @test block syntax, so the
  # other classes deliberately still exclude .bats.
  list_files shfmt

  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/check_file_discovery.bats"* ]]
  [[ "$output" == *"tests/pi_worktree_guard.bats"* ]]

  local class
  for class in bash shellcheck zsh; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *".bats"* ]]
  done
}

@test "shfmt covers extensionless public and private executables" {
  # Extensionless bin/ and libexec/ executables need the same format coverage
  # as lint coverage. Assert discovery independently of a clean shfmt run.
  local shellcheck_set shfmt_set
  shellcheck_set=$("$REPO_ROOT/libexec/list-check-files" shellcheck | tr '\0' '\n' | sort)
  shfmt_set=$("$REPO_ROOT/libexec/list-check-files" shfmt | tr '\0' '\n' | sort)

  run comm -23 <(printf '%s\n' "$shellcheck_set") <(printf '%s\n' "$shfmt_set")
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [[ "$shfmt_set" == *"ai/pi/install.sh"* ]]
}

@test "Makefile check pipelines propagate discovery failures portably" {
  run rg -n 'sort -z|sort -zu|xargs[^\n]* -r([[:space:]]|$)' "$REPO_ROOT/libexec/list-check-files" "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]

  run rg -n "bash -o pipefail -c" "$REPO_ROOT/Makefile"
  [ "$status" -eq 0 ]
}

@test "discovery rejects unknown classes" {
  run "$REPO_ROOT/libexec/list-check-files" ruby

  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "discovery fails clearly outside a Git checkout" {
  run bash -c 'cd "$1" && "$2/libexec/list-check-files" bash' _ "$TEST_ROOT" "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"must run inside a Git checkout"* ]]
}

@test "tools shell sources land in every bash gate, at any depth" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TOOL_INSTALL_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" == *"${TOOL_EXEC_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" == *"${TOOL_SUB_FILE#"$CHECKOUT/"}"* ]]
  done
}

@test "tools non-shell assets stay out of the bash gates" {
  # Guard against over-widening: this passes both before and after the
  # predicate change, and its job is to fail if the new prefix starts
  # swallowing .zsh plugins or config data that other consumers own.
  #
  # .tmux.conf and .service are asserted here because tools/ still ships both
  # kinds; the assertions moved from the retired tools/dev probes.
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *"${TOOL_ZSH_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${TOOL_YAML_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${TOOL_CONF_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"${TOOL_UNIT_FILE#"$CHECKOUT/"}"* ]]
    [[ "$output" != *"tools/you-should-use.zsh"* ]]
    [[ "$output" != *"tools/commit.msg.example"* ]]
  done

  list_files zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TOOL_ZSH_FILE#"$CHECKOUT/"}"* ]]
  [[ "$output" != *"${TOOL_SUB_FILE#"$CHECKOUT/"}"* ]]
}
