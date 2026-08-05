#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  # This file tests merge mechanics against the default layer as ambient
  # fixture data (window/pane counts, field-by-field precedence), not the
  # shape of the real shipped default -- pin it so these keep exercising the
  # single-pane window baseline regardless of what tools/dev/default-
  # workspace.yaml ships as (see test_helper.bash).
  dev_pin_legacy_default_root
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
  # Caught by dev_config_merged's per-layer duplicate check now, not by
  # post-merge validation: a layer that duplicates a name the merge would
  # otherwise silently collapse must fail before that collapse happens.
  run dev_config_merged slabledger "$WORKTREE"
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

@test "config: panes-less window normalizes without panes/layout/environment keys (digest stability)" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: solo
    command: null
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "solo")' <<<"$output")
  [ "$(jq 'has("panes")' <<<"$win")" = "false" ]
  [ "$(jq 'has("layout")' <<<"$win")" = "false" ]
  [ "$(jq 'has("environment")' <<<"$win")" = "false" ]
}

@test "config: panes normalize with per-pane defaults; window environment survives on single-pane windows" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    layout: tiled
    panes:
      - name: agent-1
        agent: claude
        focus: true
      - name: shell
        command: null
        environment: {PANE: "2"}
  - name: solo
    command: null
    environment: {WIN: "1"}
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.layout' <<<"$win")" = "tiled" ]
  [ "$(jq -c '.panes[0]' <<<"$win")" = '{"agent":"claude","command":null,"cwd":null,"focus":true,"location":null,"name":"agent-1"}' ]
  [ "$(jq -r '.panes[1].environment.PANE' <<<"$win")" = "2" ]
  # the spec §7.1 fix: window-level environment is kept for single-pane windows
  [ "$(jq -r '.windows[] | select(.name == "solo") | .environment.WIN' <<<"$output")" = "1" ]
}

@test "config: a layer defining an inherited pane twice fails loudly, never silently collapses" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    panes:
      - name: shell
        command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: main
    panes:
      - name: shell
        cwd: a
      - name: shell
        cwd: b
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]] # bats `run` folds stderr into $output
}

@test "config: panes merge by name across layers, never by index" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: main
    panes:
      - name: agent-1
        agent: claude
      - name: shell
        command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: main
    panes:
      - name: shell
        cwd: sub
      - name: extra
        command: htop
EOF
  run dev_config_merged "proj" "$TEST_ROOT/workspace/proj"
  [ "$status" -eq 0 ]
  win=$(jq -c '.windows[] | select(.name == "main")' <<<"$output")
  [ "$(jq -r '.panes | length' <<<"$win")" -eq 3 ]
  [ "$(jq -r '.panes[] | select(.name == "shell") | .cwd' <<<"$win")" = "sub" ]
  [ "$(jq -r '.panes[] | select(.name == "agent-1") | .agent' <<<"$win")" = "claude" ]
  [ "$(jq -r '.panes[] | select(.name == "extra") | .command' <<<"$win")" = "htop" ]
}

@test "config: converting an agent window to panes without nulling agent fails loudly" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: agent-1
    agent: claude
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: agent-1
    panes:
      - name: a
        agent: claude
EOF
  config=$(dev_config_merged "proj" "$TEST_ROOT/workspace/proj")
  run dev_config_validate "$config"
  [ "$status" -eq 5 ]
  [[ "$output" == *"agent-1"* && "$output" == *"panes"* ]]
}

@test "config: agent: null alongside panes converts cleanly; a shell window converts silently" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: agent-1
    agent: claude
  - name: shell
    command: null
EOF
  cat >"$DEV_OVERLAY_ROOT/proj/workspace.local.yaml" <<'EOF'
windows:
  - name: agent-1
    agent: null
    panes:
      - name: a
        agent: claude
  - name: shell
    panes:
      - name: s
        command: null
EOF
  config=$(dev_config_merged "proj" "$TEST_ROOT/workspace/proj")
  run dev_config_validate "$config"
  [ "$status" -eq 0 ]
}

@test "config: multi-pane validation failures are loud and name the offender" {
  bad() {
    jq -nc --argjson w "$1" '{version: 1, windows: [$w]}'
  }
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"layout":"tiled"}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"layout":"mosaic","panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":"x","command":"y","cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false},{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":true},{"name":"b","agent":null,"command":null,"cwd":null,"location":null,"focus":true}]}')"
  [ "$status" -eq 5 ]
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"bad name","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  # "-" is the unstamped-pane placeholder in dev_backend_query and the focus
  # pass; a pane literally named "-" would read back as pane:null.
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"-","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
  # only the exact placeholder is reserved: "--" cannot collide and stays valid
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"panes":[{"name":"--","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 0 ]
  # exclusive schema: window-level environment is a single-pane key (spec §5)
  run dev_config_validate "$(bad '{"name":"m","agent":null,"command":null,"cwd":null,"location":null,"focus":false,"environment":{"A":"1"},"panes":[{"name":"a","agent":null,"command":null,"cwd":null,"location":null,"focus":false}]}')"
  [ "$status" -eq 5 ]
}
