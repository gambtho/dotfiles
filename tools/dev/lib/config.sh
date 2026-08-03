#!/usr/bin/env bash

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_OVERLAY_ROOT="${DEV_OVERLAY_ROOT:-$DEV_DOTFILES_ROOT/projects}"

# windows merge by the name key, never by position (spec 4.1). IN(), not
# inside(): inside() is substring matching on strings and would swallow a new
# window whose name is a substring of an existing one.
DEV_CONFIG_MERGE_JQ='
def by_name($ws): reduce $ws[] as $w ({}; .[$w.name] = $w);
def merge_windows($base; $over):
  (by_name($base)) as $bm
  | (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(. * ($om[.name] // {})))
    + ($over | map(select((.name | IN($bn[])) | not)))
;
($a.windows // []) as $bw
| ($b.windows // []) as $ow
| ($a * $b)
| .windows = merge_windows($bw; $ow)
'

DEV_CONFIG_NORMALIZE_JQ='
{ version: (.version // 1),
  autostart: (.autostart // false),
  devcontainer: ((.devcontainer // {}) | {
      enabled: (.enabled // "auto"),
      config: (.config // null),
      start_timeout: (.start_timeout // 300) }),
  environment: (.environment // {}),
  windows: ((.windows // []) | map({
      name: .name,
      agent: (.agent // null),
      command: (.command // null),
      cwd: (.cwd // null),
      location: (.location // null),
      focus: (.focus // false) })) }
'
# `location` normalizes to null, NOT to "container". Spec §4.1 reads "Default
# container when one exists" — the default is conditional on the workspace
# having a container, so it cannot be resolved here, where no record is in
# scope. Collapsing unset to "container" at normalize time is what made a plain
# repository unopenable: agent-1, agent-2 and shell would demand a container
# binding that `devcontainer.enabled: auto` correctly never creates.
# `dev_window_location` (Task 10) resolves null against the record instead, and
# an EXPLICIT `location: container` still fails loudly on a repo with no
# container, because that one the user actually asked for.

dev_config_layer_json() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '{}\n'
    return 0
  fi
  yq -o=json -I=0 '.' "$file"
}

# worktree is accepted for signature stability; no Phase 1 layer is keyed by it
# (ADR-7 ships no per-worktree configuration layer).
dev_config_merged() {
  local slug="$1" worktree="$2" acc layer file
  : "$worktree"
  acc='{}'
  for file in \
    "$DEV_DOTFILES_ROOT/tools/dev/default-workspace.yaml" \
    "$DEV_OVERLAY_ROOT/$slug/workspace.yaml" \
    "$DEV_OVERLAY_ROOT/$slug/workspace.local.yaml"; do
    layer="$(dev_config_layer_json "$file")" || return 1
    acc="$(jq -c -n --argjson a "$acc" --argjson b "$layer" "$DEV_CONFIG_MERGE_JQ")" || return 1
  done
  # -S -c: sorted keys, one line, so the digest ignores cosmetic edits.
  printf '%s\n' "$acc" | jq -S -c "$DEV_CONFIG_NORMALIZE_JQ"
}

dev_config_digest() {
  local json="$1" sum
  sum="$(printf '%s' "$json" | sha256sum | cut -d' ' -f1)"
  printf 'sha256:%s\n' "$sum"
}

dev_config_validate() {
  local json="$1" problem
  problem="$(printf '%s' "$json" | jq -r '
    def problems:
      (if (.version != 1) then ["version must be 1, got \(.version | tostring)"] else [] end)
      + ((.windows // []) | map(select(.agent != null and .command != null)
          | "window \(.name) sets both agent and command") )
      + ((.windows // []) | map(select(.location != null and (.location
          | IN("container","host") | not))
          | "window \(.name) has invalid location \(.location | tostring)") )
      + ((.windows // []) | map(select(.name == null or ((.name | tostring)
          | test("^[A-Za-z0-9._-]+$") | not))
          | "window \(.name | tostring) has an invalid name; use [A-Za-z0-9._-]") )
      + ([(.windows // []) | group_by(.name)[] | select(length > 1)
          | "window \(.[0].name) is defined more than once"])
      + (if (((.windows // []) | map(select(.focus == true)) | length) > 1)
         then [((.windows // []) | map(select(.focus == true) | .name) | join(", "))
               | "more than one window sets focus: \(.)"]
         else [] end);
    problems | first // ""')" || return 1
  [[ -z "$problem" ]] && return 0
  printf 'invalid workspace config: %s\n' "$problem" >&2
  return 5
}
