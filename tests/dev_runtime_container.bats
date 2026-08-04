#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/runtime.sh"
  WT="$DEV_REPO_ROOT/demo"
  mkdir -p "$WT"
}

# The mise search order is $HOME/.local/bin/mise first, so a stub there wins
# over any real /usr/local/bin/mise on the developer's machine.
stub_mise() {
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/mise" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$HOME/.local/bin/mise"
}

@test "a resolvable but failing devcontainer shim is reported absent" {
  # Presence succeeds ...
  stub_command devcontainer 'echo "mise ERROR No version is set for shim" >&2; exit 1'
  run command -v devcontainer
  [ "$status" -eq 0 ]

  # ... execution does not.
  stub_mise 'echo "mise ERROR No version is set for shim: devcontainer" >&2; exit 1'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 6 ]
  [[ "$output" == *"unrunnable"* ]]
}

@test "a working mise exec path returns the full invocation prefix" {
  stub_mise '[[ "$1" == exec && "$3" == -- && "$4" == devcontainer && "$5" == --version ]] || exit 1
echo 0.86.1'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/bin/mise exec npm:@devcontainers/cli@0.86.1 -- devcontainer" ]
}

@test "a version probe that prints garbage is treated as absent" {
  stub_mise 'echo "devcontainer: command not found"'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 6 ]
  [[ "$output" == *"parseable version"* ]]
}

@test "docker_ok follows the daemon probe" {
  stub_command docker 'exit 0'
  run dev_runtime_docker_ok
  [ "$status" -eq 0 ]
  stub_command docker 'echo "Cannot connect to the Docker daemon" >&2; exit 1'
  run dev_runtime_docker_ok
  [ "$status" -ne 0 ]
}

@test "runtime kind is compose when dockerComposeFile is present" {
  mkdir -p "$WT/.devcontainer"
  cat >"$WT/.devcontainer/devcontainer.json" <<'JSON'
{
  "name": "demo",
  "dockerComposeFile": "docker-compose.yml",
  "service": "app"
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = compose ]
}

@test "runtime kind tolerates JSONC comments and a trailing comma" {
  mkdir -p "$WT/.devcontainer"
  cat >"$WT/.devcontainer/devcontainer.json" <<'JSON'
{
  // See https://containers.dev — this URL must not be mistaken for a comment.
  "name": "demo",
  "image": "mcr.microsoft.com/devcontainers/base:bookworm", // trailing comment
  "remoteUser": "vscode",
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = single ]
}

@test "runtime kind is none without a devcontainer" {
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "runtime detection is cached and reused" {
  stub_command docker 'exit 0'
  stub_mise 'echo 0.86.1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = true ]
  [ "$(jq -r '.cli_spec' <<<"$output")" = "npm:@devcontainers/cli@0.86.1" ]
  [ -f "$DEV_STATE_ROOT/runtime.json" ]

  # Break both probes; a fresh cache must still be served from disk.
  stub_command docker 'exit 1'
  stub_mise 'exit 1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = true ]
}

@test "an expired runtime cache is re-probed" {
  stub_command docker 'exit 0'
  stub_mise 'echo 0.86.1'
  dev_runtime_detect >/dev/null
  touch -d '2 days ago' "$DEV_STATE_ROOT/runtime.json"

  stub_command docker 'exit 1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = false ]
}

# --- fix round 1: additive coverage for review findings, plan tests unchanged above ---

@test "cli spec is read from config/mise/config.toml, not hardcoded" {
  local fake_root="$TEST_ROOT/fake-dotfiles"
  mkdir -p "$fake_root/config/mise"
  cat >"$fake_root/config/mise/config.toml" <<'TOML'
"npm:@devcontainers/cli" = "1.2.3"
TOML
  export DEV_DOTFILES_ROOT="$fake_root"
  run dev_runtime_cli_spec
  [ "$status" -eq 0 ]
  [ "$output" = "npm:@devcontainers/cli@1.2.3" ]
}

@test "cli spec takes the first line when the pin appears more than once" {
  local fake_root="$TEST_ROOT/fake-dotfiles"
  mkdir -p "$fake_root/config/mise"
  cat >"$fake_root/config/mise/config.toml" <<'TOML'
"npm:@devcontainers/cli" = "1.1.1"
"npm:@devcontainers/cli" = "2.2.2"
TOML
  export DEV_DOTFILES_ROOT="$fake_root"
  run dev_runtime_cli_spec
  [ "$status" -eq 0 ]
  [ "$output" = "npm:@devcontainers/cli@1.1.1" ]
}

@test "cli spec ignores a commented-out pin line" {
  local fake_root="$TEST_ROOT/fake-dotfiles"
  mkdir -p "$fake_root/config/mise"
  cat >"$fake_root/config/mise/config.toml" <<'TOML'
# "npm:@devcontainers/cli" = "9.9.9"
"npm:@devcontainers/cli" = "1.2.3"
TOML
  export DEV_DOTFILES_ROOT="$fake_root"
  run dev_runtime_cli_spec
  [ "$status" -eq 0 ]
  [ "$output" = "npm:@devcontainers/cli@1.2.3" ]
}

@test "cli spec fails when the pinned version is empty" {
  local fake_root="$TEST_ROOT/fake-dotfiles"
  mkdir -p "$fake_root/config/mise"
  cat >"$fake_root/config/mise/config.toml" <<'TOML'
"npm:@devcontainers/cli" = ""
TOML
  export DEV_DOTFILES_ROOT="$fake_root"
  run dev_runtime_cli_spec
  [ "$status" -ne 0 ]
}

@test "runtime kind survives JSONC torture in a compose fixture" {
  mkdir -p "$WT/.devcontainer"
  cat >"$WT/.devcontainer/devcontainer.json" <<'JSON'
{
  // See https://containers.dev — this URL must not be mistaken for a comment.
  "name": "demo",
  "image": "https://example.com/img:tag", // trailing comment
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = compose ]
}

@test "runtime kind is single for a .devcontainer directory with no json in it" {
  mkdir -p "$WT/.devcontainer"
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = single ]
}

@test "runtime kind reads a root-level .devcontainer.json" {
  cat >"$WT/.devcontainer.json" <<'JSON'
{
  "name": "demo",
  "image": "mcr.microsoft.com/devcontainers/base:bookworm"
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = single ]
}

# --- Task 10: container -----------------------------------------------------

load_container() { source "$REPO_ROOT/tools/dev/lib/container.sh"; }

CFG_AUTO='{"devcontainer":{"enabled":"auto","start_timeout":300}}'

@test "devcontainer up parses the JSON tail line out of log noise" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  stub_mise 'if [[ "$5" == --version ]]; then echo 0.86.1; exit 0; fi
echo "[12 ms] @devcontainers/cli 0.86.1."
echo "[+] Building 0.4s"
echo "not json at all"
echo "{\"outcome\":\"success\",\"containerId\":\"a710dead\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspace\"}"'

  run dev_container_up "$WT" "$CFG_AUTO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.containerId' <<<"$output")" = a710dead ]
  [ "$(jq -r '.remoteUser' <<<"$output")" = vscode ]
  [ "$(jq -r '.remoteWorkspaceFolder' <<<"$output")" = /workspace ]
  [ "$(jq -r '.exit_status' <<<"$output")" = 0 ]
  [ "$(jq -r '.up_result.outcome' <<<"$output")" = success ]
}

@test "a failing devcontainer up reports its status and stderr tail" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  stub_mise 'if [[ "$5" == --version ]]; then echo 0.86.1; exit 0; fi
echo "starting"
echo "Error: pull access denied for ghcr.io/private/image" >&2
echo "docker compose exited with code 18" >&2
exit 18'

  run dev_container_up "$WT" "$CFG_AUTO"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.exit_status' <<<"$output")" = 18 ]
  [ "$(jq -r '.containerId' <<<"$output")" = null ]
  [[ "$(jq -r '.stderr_tail' <<<"$output")" == *"pull access denied"* ]]
  [[ "$(jq -r '.stderr_tail' <<<"$output")" == *"code 18"* ]]
}

@test "enabled:false with a .devcontainer present still yields no container" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  run dev_container_enabled '{"devcontainer":{"enabled":false}}' "$WT"
  [ "$status" -eq 1 ]
}

@test "enabled:auto follows the presence of .devcontainer" {
  load_container
  run dev_container_enabled "$CFG_AUTO" "$WT"
  [ "$status" -eq 1 ]
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  run dev_container_enabled "$CFG_AUTO" "$WT"
  [ "$status" -eq 0 ]
}

@test "enabled:true without a .devcontainer is an error" {
  load_container
  stub_mise 'echo 0.86.1'
  run dev_container_up "$WT" '{"devcontainer":{"enabled":true,"start_timeout":300}}'
  [ "$status" -eq 5 ]
  [[ "$output" == *"no .devcontainer"* ]]
}

@test "container liveness is true only for a literal true" {
  load_container
  stub_command docker 'echo true'
  run dev_container_alive a710dead
  [ "$status" -eq 0 ]
  stub_command docker 'echo false'
  run dev_container_alive a710dead
  [ "$status" -ne 0 ]
  stub_command docker 'echo "Error: No such object" >&2; exit 1'
  run dev_container_alive a710dead
  [ "$status" -ne 0 ]
  run dev_container_alive ""
  [ "$status" -ne 0 ]
}

@test "the exec prefix for a host window is bash -lc" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"vscode","workdir":"/workspace"}}'
  run dev_container_exec_prefix "$rec" '{"name":"scratch","location":"host"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = bash ]
  [ "${lines[1]}" = -lc ]
}

@test "the exec prefix for a compose container window carries the record's user and workdir" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  [ "${lines[0]}" = docker ]
  [ "${lines[1]}" = exec ]
  [ "${lines[2]}" = -i ]
  [ "${lines[3]}" = -t ]
  [ "${lines[4]}" = -u ]
  [ "${lines[5]}" = node ]
  [ "${lines[6]}" = -w ]
  [ "${lines[7]}" = /srv/app ]
  [ "${lines[8]}" = a710dead ]
  # Every prefix ends in a shell with -c so the caller can append the window's
  # command as one argv element. Without this, `docker exec ... <id> 'make test'`
  # looks for a binary named "make test".
  [ "${lines[9]}" = sh ]
  [ "${lines[10]}" = -c ]
}

@test "the exec prefix for a single-container window uses devcontainer exec" {
  load_container
  stub_mise 'echo 0.86.1'
  rec='{"worktree":"/w","container":{"status":"ready","kind":"single","id":"a710dead","user":"vscode","workdir":"/workspace"}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/.local/bin/mise" ]
  [ "${lines[1]}" = exec ]
  [ "${lines[2]}" = "npm:@devcontainers/cli@0.86.1" ]
  [ "${lines[3]}" = -- ]
  [ "${lines[4]}" = devcontainer ]
  [ "${lines[5]}" = exec ]
  [ "${lines[6]}" = --workspace-folder ]
  [ "${lines[7]}" = /w ]
  [ "${lines[8]}" = sh ]
  [ "${lines[9]}" = -c ]
}

@test "an unset location resolves to host when the record has no container" {
  # This is the plain-repository path. `devcontainer.enabled: auto` starts
  # nothing, so agent-1, agent-2 and shell — none of which pin a location —
  # must land on the host rather than demand a binding that will never exist.
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_location "$rec" '{"name":"agent-1","location":null}'
  [ "$status" -eq 0 ]
  [ "$output" = host ]
  run dev_container_exec_prefix "$rec" '{"name":"agent-1","location":null}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = bash ]
  [ "${lines[1]}" = -lc ]
}

@test "an unset location resolves to container when the record has one" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_location "$rec" '{"name":"shell","location":null}'
  [ "$status" -eq 0 ]
  [ "$output" = container ]
}

@test "an EXPLICIT container location still fails on a workspace with no container" {
  # The silent-downgrade case. A config that asked for a container and got the
  # host would put an agent in the wrong filesystem, so this one stays loud.
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no live container binding"* ]]
}

@test "cwd resolves against the worktree on the host and remoteWorkspaceFolder inside" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_workdir "$rec" '{"name":"scratch","location":"host","cwd":"sub/dir"}'
  [ "$output" = "/w/sub/dir" ]
  run dev_window_workdir "$rec" '{"name":"shell","location":"container","cwd":"sub/dir"}'
  [ "$output" = "/srv/app/sub/dir" ]
  run dev_window_workdir "$rec" '{"name":"shell","location":"container","cwd":null}'
  [ "$output" = "/srv/app" ]
}

@test "the inner command applies cwd, environment and the agent" {
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_inner_command "$rec" \
    '{"name":"agent-1","agent":"claude --resume","cwd":"api","location":null}' \
    '{"CGO_ENABLED":"1","MSG":"a b"}'
  [ "$status" -eq 0 ]
  # `export`, not `env`: exec is a builtin, so `env FOO=1 exec claude` would ask
  # env(1) for a binary named `exec` and the pane would die immediately.
  [[ "$output" == "cd /w/api || exit 1; export "* ]]
  [[ "$output" == *"CGO_ENABLED='1'"* ]]
  # @sh quoting: every value is quoted, even one with no special characters;
  # a value with a space survives as one argument.
  [[ "$output" == *"MSG='a b'"* ]]
  [[ "$output" == *"; exec claude --resume"* ]]
}

@test "the inner command's environment reaches the process it execs" {
  load_container
  rec="$(jq -nc --arg w "$BATS_TEST_TMPDIR" '{worktree:$w,container:{status:"none",id:null}}')"
  local cmd
  cmd=$(dev_window_inner_command "$rec" \
    '{"name":"shell","command":"printenv MSG","location":null}' '{"MSG":"a b"}')
  run sh -c "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "a b" ]
}

@test "the inner command falls back to a login shell and never emits a bare export" {
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_inner_command "$rec" '{"name":"shell","location":null}' '{}'
  [ "$status" -eq 0 ]
  [ "$output" = 'cd /w || exit 1; exec "${SHELL:-/bin/bash}" -l' ]
  # A container window cannot use the host's $SHELL, and bash may not exist.
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_inner_command "$rec" '{"name":"shell","location":null}' '{}'
  [[ "$output" == *"exec bash -l 2>/dev/null || exec sh -l" ]]
}

@test "the exec prefix refuses to guess a missing user or workdir" {
  load_container
  rec='{"worktree":"/w","container":{"status":"lost","kind":"compose","id":null,"user":null,"workdir":null}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no live container binding"* ]]
}
