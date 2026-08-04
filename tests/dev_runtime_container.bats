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
