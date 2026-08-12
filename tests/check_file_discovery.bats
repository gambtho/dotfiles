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

  # Probes for a tools/ subdirectory. tools/herdr hosts the real Herdr
  # installer, but this fixture writes its own probe files there rather than
  # relying on that installer's actual layout — that keeps the gate honest if
  # the installer is later renamed or moved.
  #
  # These probes previously lived in tools/dev/ as a second, parallel set.
  # tools/dev/ is gone (design §13 step 8) and the discovery rules were never
  # keyed on it (bin/list-check-files:40-52 matches tools/*), so one set covers
  # the same predicate.
  TOOL_PROBE_DIR="$REPO_ROOT/tools/herdr"
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

teardown() {
  rm -f -- "$UNTRACKED_FILE" "$IGNORED_FILE" \
    "$TOOL_INSTALL_FILE" "$TOOL_EXEC_FILE" "$TOOL_SUB_FILE" "$TOOL_ZSH_FILE" \
    "$TOOL_YAML_FILE" "$TOOL_CONF_FILE" "$TOOL_UNIT_FILE"
  rmdir "$IGNORED_DIR" 2>/dev/null || true
  rmdir "$TOOL_SUB_DIR" 2>/dev/null || true
  # rmdir, not rm -r: the real installer lives here, so the directory is not
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

@test "tools shell sources land in every bash gate, at any depth" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TOOL_INSTALL_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${TOOL_EXEC_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${TOOL_SUB_FILE#"$REPO_ROOT/"}"* ]]
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
    [[ "$output" != *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${TOOL_YAML_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${TOOL_CONF_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${TOOL_UNIT_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"tools/you-should-use.zsh"* ]]
    [[ "$output" != *"tools/commit.msg.example"* ]]
  done

  list_files zsh
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${TOOL_SUB_FILE#"$REPO_ROOT/"}"* ]]
}
