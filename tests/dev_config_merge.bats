#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/config.sh"
  WORKTREE="$DEV_REPO_ROOT/slabledger"
  mkdir -p "$WORKTREE" "$DEV_OVERLAY_ROOT/slabledger"
}

window_field() {
  jq -r --arg n "$2" --arg f "$3" '.windows[] | select(.name == $n) | .[$f]' <<<"$1"
}

write_tracked() {
  cat >"$DEV_OVERLAY_ROOT/slabledger/workspace.yaml"
}

write_local() {
  cat >"$DEV_OVERLAY_ROOT/slabledger/workspace.local.yaml"
}

@test "the default layer alone produces the four spec windows in order" {
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch" ]
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-2 agent)" = "claude" ]
  [ "$(window_field "$output" shell agent)" = "null" ]
  [ "$(window_field "$output" scratch location)" = "host" ]
  [ "$(jq -r '.windows | map(select(.focus)) | map(.name) | join(",")' <<<"$output")" = "agent-1" ]
  [ "$(jq -r .version <<<"$output")" = "1" ]
  [ "$(jq -r .autostart <<<"$output")" = "false" ]
  [ "$(jq -r .devcontainer.enabled <<<"$output")" = "auto" ]
  [ "$(jq -r .devcontainer.start_timeout <<<"$output")" = "300" ]
}

@test "merged config is one compact line with sorted keys" {
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jq -r 'keys | join(",")' <<<"$output")" = "autostart,devcontainer,environment,version,windows" ]
}

@test "the slabledger worked example overrides scratch and leaves the rest untouched" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
windows:
  - name: scratch
    command: make test
    location: container
YAML
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: postgres://localhost:5432/slabledger_dev
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch" ]
  [ "$(window_field "$output" scratch command)" = "make test" ]
  [ "$(window_field "$output" scratch location)" = "container" ]
  # The three windows the overlay never mentions keep every default.
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-1 focus)" = "true" ]
  [ "$(window_field "$output" agent-2 agent)" = "claude" ]
  [ "$(window_field "$output" shell command)" = "null" ]
  [ "$(window_field "$output" shell location)" = "null" ]
  [ "$(jq -r .environment.CGO_ENABLED <<<"$output")" = "1" ]
  [ "$(jq -r .environment.DATABASE_URL <<<"$output")" = "postgres://localhost:5432/slabledger_dev" ]
}

@test "windows merge by name, not by position" {
  # scratch is last in the default layer and first (and only) here. A
  # positional merge would rewrite agent-1 instead.
  write_tracked <<'YAML'
version: 1
windows:
  - name: scratch
    command: make test
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-1 command)" = "null" ]
  [ "$(window_field "$output" scratch command)" = "make test" ]
}

@test "a window only a later layer names is appended in that layer's order" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: docs
    command: mkdocs serve
  - name: logs
    command: tail -f log
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch,docs,logs" ]
  [ "$(window_field "$output" docs location)" = "null" ]
}

@test "an unset location stays null so the record can resolve it per workspace" {
  # Spec §4.1: "Default container when one exists". Normalization cannot know
  # whether one exists, so it must not decide. Only `scratch` pins host.
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(window_field "$output" agent-1 location)" = "null" ]
  [ "$(window_field "$output" agent-2 location)" = "null" ]
  [ "$(window_field "$output" shell location)" = "null" ]
  [ "$(window_field "$output" scratch location)" = "host" ]
}

@test "a window name outside [A-Za-z0-9._-] exits 5" {
  # The charset is load-bearing beyond tidiness: window names are interpolated
  # into tmux hook commands (Task 16), where a quote or backslash would break
  # out of the shell word the hook builds.
  write_tracked <<'YAML'
version: 1
windows:
  - name: "my agent's window"
    command: true
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"invalid name"* ]]
}

@test "a new window whose name is a substring of an existing one is appended" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: age
    command: watch-age
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch,age" ]
  [ "$(window_field "$output" age command)" = "watch-age" ]
}

@test "workspace.local.yaml beats workspace.yaml for a map key and a window field" {
  write_tracked <<'YAML'
version: 1
environment:
  DATABASE_URL: tracked
  CGO_ENABLED: "1"
windows:
  - name: shell
    command: tracked-cmd
    location: container
YAML
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: local
windows:
  - name: shell
    command: local-cmd
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .environment.DATABASE_URL <<<"$output")" = "local" ]
  [ "$(jq -r .environment.CGO_ENABLED <<<"$output")" = "1" ]
  [ "$(window_field "$output" shell command)" = "local-cmd" ]
  [ "$(window_field "$output" shell location)" = "container" ]
}

@test "the digest is sha256-prefixed and byte-identical across two runs" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
YAML
  local first second
  first="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  second="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$first" = "$second" ]
  [[ "$first" =~ ^sha256:[0-9a-f]{64}$ ]]
}

@test "the digest changes when any layer changes" {
  local base tracked localised
  base="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
YAML
  tracked="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: postgres://localhost:5432/slabledger_dev
YAML
  localised="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$base" != "$tracked" ]
  [ "$tracked" != "$localised" ]
}

@test "key order inside a source YAML file does not change the digest" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
windows:
  - name: scratch
    command: make test
    location: container
YAML
  local ordered reordered
  ordered="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_tracked <<'YAML'
windows:
  - location: container
    command: make test
    name: scratch
environment:
  CGO_ENABLED: "1"
version: 1
YAML
  reordered="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$ordered" = "$reordered" ]
}

@test "a valid config passes validation" {
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 0 ]
}

@test "a window setting both agent and command exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: agent-2
    command: make test
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"agent-2"* ]]
  [[ "$output" == *"both agent and command"* ]]
}

@test "a second focused window exits 5 naming the windows" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: shell
    focus: true
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"focus"* ]]
  [[ "$output" == *"agent-1"* ]]
  [[ "$output" == *"shell"* ]]
}

@test "a duplicated window name exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: docs
    command: one
  - name: docs
    command: two
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"docs"* ]]
  [[ "$output" == *"more than once"* ]]
}

@test "an unknown location exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: shell
    location: kubernetes
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"kubernetes"* ]]
}

@test "a version other than 1 exits 5" {
  write_tracked <<'YAML'
version: 2
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"version must be 1"* ]]
}
