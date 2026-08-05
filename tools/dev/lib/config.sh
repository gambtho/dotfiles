#!/usr/bin/env bash

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_OVERLAY_ROOT="${DEV_OVERLAY_ROOT:-$DEV_DOTFILES_ROOT/projects}"

# windows merge by the name key, never by position (spec 4.1), and panes
# within a window merge the same way. IN(), not inside(): inside() is
# substring matching on strings and would swallow a new window whose name is
# a substring of an existing one.
DEV_CONFIG_MERGE_JQ='
def by_name($ws): reduce $ws[] as $w ({}; .[$w.name] = $w);
def merge_named($base; $over):
  (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(. * ($om[.name] // {})))
    + ($over | map(select((.name | IN($bn[])) | not)));
def merge_window($b; $o):
  ($b * $o)
  | if ($b.panes? != null) and ($o.panes? != null)
    then .panes = merge_named($b.panes; $o.panes)
    else . end;
def merge_windows($base; $over):
  (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(merge_window(.; ($om[.name] // {}))))
    + ($over | map(select((.name | IN($bn[])) | not)));
($a.windows // []) as $bw
| ($b.windows // []) as $ow
| ($a * $b)
| .windows = merge_windows($bw; $ow)
'

DEV_CONFIG_NORMALIZE_JQ='
def norm_pane:
  { name: .name,
    agent: (.agent // null),
    command: (.command // null),
    cwd: (.cwd // null),
    location: (.location // null),
    focus: (.focus // false) }
  + (if .environment != null then {environment: .environment} else {} end);
{ version: (.version // 1),
  autostart: (.autostart // false),
  devcontainer: ((.devcontainer // {}) | {
      enabled: (.enabled // "auto"),
      config: (.config // null),
      start_timeout: (.start_timeout // 300) }),
  environment: (.environment // {}),
  windows: ((.windows // []) | map(
    { name: .name,
      agent: (.agent // null),
      command: (.command // null),
      cwd: (.cwd // null),
      location: (.location // null),
      focus: (.focus // false) }
    + (if .environment != null then {environment: .environment} else {} end)
    + (if .layout != null then {layout: .layout} else {} end)
    + (if .panes != null then {panes: (.panes | map(norm_pane))} else {} end))) }
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
  # `. // {}`: an existing file that parses to null (empty file, `---` only,
  # or a lone comment) must merge as an empty layer, not poison the jq
  # multiplication downstream with a literal null.
  yq -o=json -I=0 '. // {}' "$file"
}

# By-name merging collapses duplicate names before post-merge validation can
# see them: a layer that defines an inherited pane twice would silently keep
# only the last patch. So duplicates are detected per layer, while the layer
# is still a layer. The post-merge duplicate checks in dev_config_validate
# stay as defense in depth for hand-fed JSON.
dev_config_layer_dup_check() {
  local file="$1" layer="$2" problem
  problem=$(jq -r '
    ([(.windows // []) | group_by(.name)[] | select(length > 1)
       | "window \(.[0].name) is defined more than once"]
     + [(.windows // [])[] | .name as $w
        | ((.panes // []) | group_by(.name)[] | select(length > 1))
        | "pane \($w)/\(.[0].name) is defined more than once"])
    | first // ""' <<<"$layer") || return 1
  [[ -z "$problem" ]] && return 0
  printf 'invalid workspace config in %s: %s\n' "$file" "$problem" >&2
  return 5
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
    dev_config_layer_dup_check "$file" "$layer" || return $?
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
         else [] end)
      + ((.windows // []) | map(select(.panes != null
          and (.agent != null or .command != null or .cwd != null
               or .location != null or ((.environment // null) != null)))
          | "window \(.name) mixes panes with single-pane keys; null them explicitly in the overlay"))
      + ((.windows // []) | map(select(.panes != null and (.panes | length) == 0)
          | "window \(.name) declares an empty panes list"))
      + ((.windows // []) | map(select((.layout // null) != null and .panes == null)
          | "window \(.name) sets layout without panes"))
      + ((.windows // []) | map(select((.layout // null) != null
          and ((.layout | IN("even-horizontal","even-vertical","main-horizontal","main-vertical","tiled")) | not))
          | "window \(.name) has invalid layout \(.layout | tostring)"))
      + ((.windows // []) | map(. as $w | (.panes // [])[]
          | select(.agent != null and .command != null)
          | "pane \($w.name)/\(.name) sets both agent and command"))
      + ((.windows // []) | map(. as $w | (.panes // [])[]
          | select(.name == null or ((.name | tostring) | test("^[A-Za-z0-9._-]+$") | not))
          | "a pane in window \($w.name) has an invalid name; use [A-Za-z0-9._-]"))
      + ((.windows // []) | map(. as $w | (.panes // [])[]
          | select(.name != null and ((.name | tostring) | test("^-+$")))
          | "pane \($w.name)/\(.name) has a reserved name"))
      + ((.windows // []) | map(. as $w | (.panes // [])[]
          | select(.location != null and ((.location | IN("container","host")) | not))
          | "pane \($w.name)/\(.name) has invalid location \(.location | tostring)"))
      + ((.windows // []) | map(. as $w | ((.panes // []) | group_by(.name)[] | select(length > 1))
          | "pane \($w.name)/\(.[0].name) is defined more than once"))
      + ((.windows // []) | map(select(((.panes // []) | map(select(.focus == true)) | length) > 1)
          | "window \(.name) has more than one focused pane"));
    problems | first // ""')" || return 1
  [[ -z "$problem" ]] && return 0
  printf 'invalid workspace config: %s\n' "$problem" >&2
  return 5
}
