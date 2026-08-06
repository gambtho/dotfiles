#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  UNTRACKED_FILE="$REPO_ROOT/bin/example-check-script-$BATS_TEST_NUMBER"
  IGNORED_DIR="$REPO_ROOT/bin/.opencode"
  IGNORED_FILE="$IGNORED_DIR/project-$BATS_TEST_NUMBER.sh"
  mkdir -p "$IGNORED_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$UNTRACKED_FILE"
  printf '#!/usr/bin/env bash\nfalse\n' >"$IGNORED_FILE"

  # Throwaway probes for the tools/dev discovery classes. They are untracked,
  # so they exercise the same --others path the bin/ probe above does.
  DEV_LIB_DIR="$REPO_ROOT/tools/dev/lib"
  DEV_CMD_DIR="$REPO_ROOT/tools/dev/commands"
  DEV_LIB_FILE="$DEV_LIB_DIR/probe-$BATS_TEST_NUMBER.sh"
  DEV_CMD_FILE="$DEV_CMD_DIR/probe-$BATS_TEST_NUMBER.sh"
  DEV_INSTALL_FILE="$REPO_ROOT/tools/dev/probe-install-$BATS_TEST_NUMBER.sh"
  DEV_EXEC_FILE="$REPO_ROOT/tools/dev/probe-exec-$BATS_TEST_NUMBER"
  DEV_YAML_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.yaml"
  DEV_CONF_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.tmux.conf"
  DEV_UNIT_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.service"
  DEV_ZSH_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.zsh"
  mkdir -p "$DEV_LIB_DIR" "$DEV_CMD_DIR"
  printf 'probe_lib() { :; }\n' >"$DEV_LIB_FILE"
  printf 'dev_cmd_probe() { :; }\n' >"$DEV_CMD_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$DEV_INSTALL_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$DEV_EXEC_FILE"
  printf 'windows: []\n' >"$DEV_YAML_FILE"
  printf 'set -g status on\n' >"$DEV_CONF_FILE"
  printf '[Unit]\nDescription=probe\n' >"$DEV_UNIT_FILE"
  printf 'export PROBE=1\n' >"$DEV_ZSH_FILE"

  # Probes for a tools/ subdirectory that is not tools/dev. tools/projectmux
  # now hosts the real ProjectMux installer, but this fixture writes its own
  # probe files there rather than relying on that installer's actual layout —
  # that keeps the gate honest if the installer is later renamed or moved.
  TOOL_PROBE_DIR="$REPO_ROOT/tools/projectmux"
  TOOL_INSTALL_FILE="$TOOL_PROBE_DIR/probe-install-$BATS_TEST_NUMBER.sh"
  TOOL_EXEC_FILE="$TOOL_PROBE_DIR/probe-exec-$BATS_TEST_NUMBER"
  TOOL_ZSH_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.zsh"
  TOOL_YAML_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.yaml"
  mkdir -p "$TOOL_PROBE_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_INSTALL_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_EXEC_FILE"
  printf 'export PROBE=1\n' >"$TOOL_ZSH_FILE"
  printf 'defaults: {}\n' >"$TOOL_YAML_FILE"
}

teardown() {
  rm -f -- "$UNTRACKED_FILE" "$IGNORED_FILE" \
    "$DEV_LIB_FILE" "$DEV_CMD_FILE" "$DEV_INSTALL_FILE" "$DEV_EXEC_FILE" \
    "$DEV_YAML_FILE" "$DEV_CONF_FILE" "$DEV_UNIT_FILE" "$DEV_ZSH_FILE" \
    "$TOOL_INSTALL_FILE" "$TOOL_EXEC_FILE" "$TOOL_ZSH_FILE" "$TOOL_YAML_FILE"
  rmdir "$IGNORED_DIR" 2>/dev/null || true
  rmdir "$DEV_LIB_DIR" "$DEV_CMD_DIR" 2>/dev/null || true
  # rmdir, not rm -r: once the real installer lands here the directory is not
  # empty and must survive the suite untouched.
  rmdir "$TOOL_PROBE_DIR" 2>/dev/null || true
}

list_files() {
  local class="$1"
  run bash -c '"$1/bin/list-check-files" "$2" | tr "\0" "\n"' _ "$REPO_ROOT" "$class"
}

@test "bash discovery includes tracked and untracked source but excludes ignored state" {
  list_files bash

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/install"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"core/shell/zshrc.symlink"* ]]
}

@test "zsh discovery includes shell symlinks and zsh sources" {
  list_files zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"core/shell/zshrc.symlink"* ]]
  [[ "$output" == *"core/path.zsh"* ]]
  [[ "$output" != *"bin/install"* ]]
}

@test "shellcheck discovery includes repository shell entry points" {
  list_files shellcheck

  [ "$status" -eq 0 ]
  [[ "$output" == *"bin/install"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"ai/claude/install.sh"* ]]
  [[ "$output" == *"${UNTRACKED_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${IGNORED_FILE#"$REPO_ROOT/"}"* ]]
}

@test "shfmt discovery includes the shared Bats helper" {
  list_files shfmt

  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/test_helper.bash"* ]]
  [[ "$output" == *"bin/common.sh"* ]]
  [[ "$output" == *"ai/claude/install.sh"* ]]
}

@test "shfmt discovery covers Bats suites" {
  # The suites were format-checked by nothing for either linter, so they drifted
  # silently: two of them were already unformatted when this gate was added.
  # shfmt only — bash -n and shellcheck cannot parse @test block syntax, so the
  # other classes deliberately still exclude .bats.
  list_files shfmt

  [ "$status" -eq 0 ]
  [[ "$output" == *"tests/check_file_discovery.bats"* ]]
  [[ "$output" == *"tests/seed_drift.bats"* ]]

  local class
  for class in bash shellcheck zsh; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *".bats"* ]]
  done
}

@test "project seed template is covered by every bash source gate" {
  local expected="ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh"
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected"* ]]
  done
}

@test "shfmt covers extensionless bin executables" {
  # Extensionless bin/ executables are the bulk of this repo's shell code.
  # Linting but never format-checking them let drift accumulate exactly where
  # most changes land. Discovery now matches the shellcheck set; the remaining
  # backlog of unformatted bin/ scripts is tracked separately, so this asserts
  # discovery rather than a clean shfmt run.
  local shellcheck_set shfmt_set
  shellcheck_set=$("$REPO_ROOT/bin/list-check-files" shellcheck | tr '\0' '\n' | sort)
  shfmt_set=$("$REPO_ROOT/bin/list-check-files" shfmt | tr '\0' '\n' | sort)

  run comm -23 <(printf '%s\n' "$shellcheck_set") <(printf '%s\n' "$shfmt_set")
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [[ "$shfmt_set" == *"bin/vekil-proxy"* ]]
}

@test "Makefile check pipelines propagate discovery failures portably" {
  run rg -n 'sort -z|sort -zu|xargs[^\n]* -r([[:space:]]|$)' "$REPO_ROOT/bin/list-check-files" "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]

  run rg -n "bash -o pipefail -c" "$REPO_ROOT/Makefile"
  [ "$status" -eq 0 ]
}

@test "discovery rejects unknown classes" {
  run "$REPO_ROOT/bin/list-check-files" ruby

  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "discovery fails clearly outside a Git checkout" {
  run bash -c 'cd "$1" && "$2/bin/list-check-files" bash' _ "$TEST_ROOT" "$REPO_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"must run inside a Git checkout"* ]]
}

@test "dev platform shell sources land in every bash gate" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${DEV_LIB_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_CMD_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_INSTALL_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_EXEC_FILE#"$REPO_ROOT/"}"* ]]
  done
}

@test "dev platform non-shell assets stay out of the bash gates" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *"${DEV_YAML_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_CONF_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_UNIT_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  done
}

@test "dev platform zsh sources stay in the zsh gate" {
  list_files zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"${DEV_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${DEV_LIB_FILE#"$REPO_ROOT/"}"* ]]
}

@test "tools shell sources outside tools/dev land in every bash gate" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TOOL_INSTALL_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${TOOL_EXEC_FILE#"$REPO_ROOT/"}"* ]]
  done
}

@test "tools non-shell assets outside tools/dev stay out of the bash gates" {
  # Guard against over-widening: this passes both before and after the
  # predicate change, and its job is to fail if the new prefix starts
  # swallowing .zsh plugins or config data that other consumers own.
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${TOOL_YAML_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"tools/you-should-use.zsh"* ]]
    [[ "$output" != *"tools/commit.msg.example"* ]]
  done

  list_files zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
}
