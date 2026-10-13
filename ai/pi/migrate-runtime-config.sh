#!/usr/bin/env bash
# Selective, fixture-testable migrations. Installer publication helpers are sourced first.

set -euo pipefail

pi_migration_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

# The caller owns these dynamically scoped snapshot variables. Capture before
# parsing, and compare both inode identity and contents before every publication.
pi_migration_snapshot() {
  local destination=$1 suffix=${2:-} allow_dangling=${3:-0}
  kind=absent link_target='' snapshot_hash=absent identity=absent
  if [[ -L "$destination" ]]; then
    if [[ -z "$suffix" ]] || ! is_recognized_source_link "$destination" "$suffix"; then
      log_warning "Refusing foreign mutable symlink at $destination"
      return 1
    fi
    kind=symlink link_target=$(readlink "$destination")
    if [[ ! -e "$destination" && "$allow_dangling" != 1 ]]; then
      log_warning "Refusing dangling migration link at $destination"
      return 1
    fi
  elif [[ -e "$destination" ]]; then
    kind='file'
  else
    return 0
  fi
  identity=$(pi_migration_identity "$destination") || return 1
  if [[ -e "$destination" ]]; then
    [[ -f "$destination" ]] || {
      log_warning "Refusing non-file migration destination at $destination"
      return 1
    }
    snapshot_hash=$(sha256_file "$destination") || return 1
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$destination" >/dev/null 2>&1 || {
      log_warning "Invalid JSON object at $destination; preserving runtime contents."
      return 1
    }
  fi
}

pi_migration_unchanged() {
  local destination=$1
  permission_destination_is_unchanged "$destination" "$kind" "$link_target" "$snapshot_hash" || return 1
  [[ "$kind" == absent ]] || [[ "$(pi_migration_identity "$destination")" == "$identity" ]]
}

# rendered is already validated JSON. delete=1 is used only for retired, empty
# model output (including a recognized dangling link), never for preferences.
publish_pi_migration() {
  local destination=$1 rendered=$2 file_mode=$3 delete=${4:-0} candidate backup
  if ! pi_migration_unchanged "$destination"; then
    log_warning "Pi configuration changed during migration at $destination; refusing publication."
    return 1
  fi
  if [[ "$delete" == 0 && "$kind" == file ]] &&
    [[ "$(jq -cS . "$destination")" == "$(jq -cS . <<<"$rendered")" ]]; then
    return 0
  fi
  if [[ "$delete" == 1 && "$kind" == absent ]]; then
    return 0
  fi
  if [[ "$MODE" == check ]]; then
    log_info "[dry-run] Would back up and migrate $destination"
    return 0
  fi
  mkdir -p "$(dirname "$destination")"
  if [[ "$snapshot_hash" != absent ]]; then
    backup=$(backup_regular_contents "$destination" "$destination") || return 1
  fi
  if ! pi_migration_unchanged "$destination"; then
    log_warning "Pi configuration changed during migration at $destination; refusing publication."
    return 1
  fi
  if [[ "$delete" == 1 ]]; then
    rm -- "$destination" || return 1
  else
    candidate=$(mktemp "${destination}.candidate.XXXXXX") || return 1
    if ! printf '%s\n' "$rendered" >"$candidate" ||
      ! atomic_publish_file "$candidate" "$destination" "$file_mode"; then
      rm -f "$candidate"
      return 1
    fi
    rm -f "$candidate"
  fi
  log_success "Migrated $destination${backup:+; private backup: $backup}"
}

retire_astra_override() {
  local destination=$1 receipt="$PI_AGENT_DIR/dotfiles-migrations.json"
  local kind link_target snapshot_hash identity rendered delete=0
  local receipt_kind receipt_target receipt_hash receipt_identity receipt_contents='{}'
  pi_migration_snapshot "$receipt" || return 1
  receipt_kind=$kind receipt_target=$link_target receipt_hash=$snapshot_hash receipt_identity=$identity
  if [[ "$kind" != absent ]]; then
    receipt_contents=$(jq . "$receipt") || return 1
    if jq -e '.astraOverrideRetired == true' "$receipt" >/dev/null; then
      log_info "Astra override retirement already completed; preserving later overrides at $destination"
      return 0
    fi
    jq -e 'has("astraOverrideRetired") | not' "$receipt" >/dev/null || {
      log_warning "Invalid Astra retirement receipt at $receipt"
      return 1
    }
  fi
  pi_migration_snapshot "$destination" 'ai/pi/config/models.json' 1 || return 1
  rendered='{}'
  if [[ "$snapshot_hash" != absent ]]; then
    jq -e '
      (has("providers") | not) or
      ((.providers | type) == "object" and
        ((.providers | has("github-copilot") | not) or
          ((.providers["github-copilot"] | type) == "object" and
            ((.providers["github-copilot"] | has("models") | not) or
              ((.providers["github-copilot"].models | type) == "array" and
                all(.providers["github-copilot"].models[]; type == "object" and (.id | type) == "string"))))))
    ' "$destination" >/dev/null || {
      log_warning "Invalid Astra override structure at $destination; preserving runtime contents."
      return 1
    }
    rendered=$(jq '
      if any(.providers["github-copilot"].models[]?; .id == "gpt-6-astra") then
        .providers["github-copilot"].models |= map(select(.id != "gpt-6-astra"))
        | if .providers["github-copilot"].models == [] then del(.providers["github-copilot"].models) else . end
        | if .providers["github-copilot"] == {} then del(.providers["github-copilot"]) else . end
        | if .providers == {} then del(.providers) else . end
      else . end
    ' "$destination") || return 1
  fi
  [[ "$(jq -c . <<<"$rendered")" != '{}' ]] || delete=1
  publish_pi_migration "$destination" "$rendered" 0600 "$delete" || return 1
  # A receipt failure is retryable: the prior model contents remain in a private
  # backup/recovery snapshot, and no successful receipt is manufactured.
  kind=$receipt_kind link_target=$receipt_target snapshot_hash=$receipt_hash identity=$receipt_identity
  rendered=$(jq '.astraOverrideRetired = true' <<<"$receipt_contents") || return 1
  publish_pi_migration "$receipt" "$rendered" 0600
}

pi_preferences_are_valid() {
  jq -e '
    def optional($key; $type): (has($key) | not) or (.[$key] | type) == $type;
    type == "object" and optional("defaultTools"; "array")
    and (all(.defaultTools[]?; type == "string"))
    and optional("codemode"; "object") and optional("compaction"; "object")
    and ((.compaction // {}) | optional("modelOverrides"; "object"))
    and all((.compaction.modelOverrides // {})[]; type == "object")
  ' "$1" >/dev/null 2>&1
}

refresh_pi_preferences() {
  local settings=$1 modes=$2 baseline_settings=$3 baseline_modes=$4
  [[ "${PI_AI_REFRESH_PREFERENCES:-0}" == 1 ]] || return 0
  local kind link_target snapshot_hash identity settings_kind settings_target settings_hash settings_identity
  local settings_contents modes_contents
  # Match the installer's legacy-link ownership. Dangling owned links have no
  # preferences to inspect; the mutable-file reconcilers install their baselines.
  pi_migration_snapshot "$settings" 'ai/pi/settings.json' 1 || return 1
  settings_kind=$kind settings_target=$link_target settings_hash=$snapshot_hash settings_identity=$identity
  pi_migration_snapshot "$modes" 'ai/pi/modes.json' 1 || return 1
  # Validate both inputs before either file changes; this is selective refresh,
  # not a reset or a mechanism to repair unknown malformed preference data.
  pi_preferences_are_valid "$baseline_settings" &&
    jq -e 'type == "object" and (.modes | type) == "object"' "$baseline_modes" >/dev/null &&
    { [[ "$settings_hash" == absent ]] || pi_preferences_are_valid "$settings"; } &&
    { [[ "$snapshot_hash" == absent ]] || jq -e 'type == "object" and ((has("modes") | not) or ((.modes | type) == "object" and all(.modes[]; type == "object")))' "$modes" >/dev/null; } || {
    log_warning "Invalid JSON preference structure; refusing selective refresh."
    return 1
  }
  if [[ "$settings_hash" != absent ]]; then
    settings_contents=$(jq --slurpfile baseline "$baseline_settings" --slurpfile roles "$baseline_modes" '
      $baseline[0] as $b | $roles[0].modes as $roles
      | {rush: ["gpt-5.4-mini", "gpt-6-luna"], smart: ["gpt-5.6-sol", "gpt-6-sol"], deep: ["gpt-5.6-terra", "gpt-6-astra"], review: ["claude-opus-5", "claude-opus-5.5"]} as $historic
      | .defaultModel as $old
      | if .defaultProvider == "github-copilot" then
          reduce ($historic | keys[]) as $role (.;
            if ($historic[$role] | index($old)) != null and $roles[$role].modelId != null then
              .defaultModel = $roles[$role].modelId | .defaultProvider = $roles[$role].provider
            else . end)
        else . end
      | if ($b.defaultTools // [] | any(. == "+codemode" or . == "codemode")) then
          if (reduce (.defaultTools // [])[] as $tool (false;
                if $tool == "codemode" or $tool == "+codemode" then true
                elif $tool == "-codemode" then false else . end)) then .
          else .defaultTools = ((.defaultTools // []) + ["+codemode"]) end
        else . end
      | if $b.codemode.mode != null then .codemode.mode = $b.codemode.mode else . end
      | reduce ["reserveTokens", "keepRecentTokens"][] as $key (.;
          (if $key == "reserveTokens" then 650000 else 60000 end) as $oldTokens
          | if .compaction[$key] == $oldTokens and $b.compaction[$key] != null
              and ($b.compaction.modelOverrides | type) == "object" then
              .compaction[$key] = $b.compaction[$key]
              | reduce ($b.compaction.modelOverrides | keys[]) as $model (.;
                  if (.compaction.modelOverrides[$model] | has($key) | not) then
                    .compaction.modelOverrides[$model][$key] = $b.compaction.modelOverrides[$model][$key]
                  else . end)
            else . end)
    ' "$settings") || return 1
  fi
  if [[ "$snapshot_hash" != absent ]]; then
    modes_contents=$(jq --slurpfile baseline "$baseline_modes" '
      $baseline[0].modes as $b
      | {rush: ["gpt-5.4-mini", "gpt-6-luna"], smart: ["gpt-5.6-sol", "gpt-6-sol"], deep: ["gpt-5.6-terra", "gpt-6-astra"], review: ["claude-opus-5", "claude-opus-5.5"]} as $historic
      | reduce ($historic | keys[]) as $role (.;
          if .modes[$role].provider == "github-copilot" then
            .modes[$role].modelId as $old
            | if ($historic[$role] | index($old)) != null and $b[$role].modelId != null then
                .modes[$role].modelId = $b[$role].modelId | .modes[$role].provider = $b[$role].provider
              else . end
          else . end)
    ' "$modes") || return 1
    publish_pi_migration "$modes" "$modes_contents" 0644 || return 1
  fi
  if [[ "$settings_hash" != absent ]]; then
    kind=$settings_kind link_target=$settings_target snapshot_hash=$settings_hash identity=$settings_identity
    publish_pi_migration "$settings" "$settings_contents" 0644
  fi
}

remove_retired_subagent_grace_turns() {
  local destination=$1 kind link_target snapshot_hash identity rendered
  pi_migration_snapshot "$destination" 'ai/pi/config/subagents.json' || return 1
  [[ "$kind" != absent ]] || return 0
  jq -e 'has("graceTurns")' "$destination" >/dev/null || return 0
  # Upstream ignores this key; do not translate it into a different turn budget.
  rendered=$(jq 'del(.graceTurns)' "$destination") || return 1
  publish_pi_migration "$destination" "$rendered" 0600
}

reconcile_child_exclusions() {
  local destination=$1 baseline=$2 kind link_target snapshot_hash identity rendered
  pi_migration_snapshot "$destination" 'ai/pi/config/subagents.json' || return 1
  local filter='type == "object" and ((has("excludedExtensionPackages") | not) or ((.excludedExtensionPackages | type) == "array" and all(.excludedExtensionPackages[]; type == "string")))'
  jq -e "$filter" "$baseline" >/dev/null &&
    { [[ "$kind" == absent ]] || jq -e "$filter" "$destination" >/dev/null; } || {
    log_warning "Invalid child exclusion JSON structure; refusing publication."
    return 1
  }
  [[ "$kind" != absent ]] || return 0
  rendered=$(jq --slurpfile baseline "$baseline" '
    # Only repository npm/Git spellings are owned. Paths, URLs and other source
    # forms stay opaque, including values that merely share a package prefix.
    def identity:
      if test("^npm:(@[-a-zA-Z0-9_.]+/)?[-a-zA-Z0-9_.]+(@[^@[:space:]]+)?$") then sub("@[^@/]+$"; "")
      elif test("^git:github\\.com/[-a-zA-Z0-9_.]+/[-a-zA-Z0-9_.]+(@[^@[:space:]]+)?$") then sub("@[^@]+$"; "")
      else . end;
    ($baseline[0].excludedExtensionPackages // []) as $required
    | (reduce $required[] as $source ({}; .[$source | identity] = $source)) as $owned
    | (reduce ((.excludedExtensionPackages // []) + $required)[] as $source
        ({result: [], seen: {}};
          ($source | identity) as $id
          # Retirement is package-specific; do not infer ownership of opaque
          # paths, URLs, custom prefixes or malformed source spellings.
          | if $source | test("^npm:(shitty-extensions|@narumitw/pi-caffeinate)(@[^@[:space:]]+)?$") then .
            elif $owned | has($id) then
              if .seen[$id] then . else .result += [$owned[$id]] | .seen[$id] = true end
            else .result += [$source] end)) as $normalized
    | .excludedExtensionPackages = $normalized.result
  ' "$destination") || return 1
  publish_pi_migration "$destination" "$rendered" 0600
}

refresh_pi_file_context() {
  local destination=$1 baseline=$2 kind link_target snapshot_hash identity rendered
  [[ "${PI_AI_REFRESH_PREFERENCES:-0}" == 1 ]] || return 0
  pi_migration_snapshot "$destination" 'ai/pi/config/file-context.json' || return 1
  [[ "$kind" != absent ]] || return 0
  rendered=$(jq --slurpfile baseline "$baseline" '
    if .openShortcut == "ctrl+shift+x" then .openShortcut = $baseline[0].openShortcut else . end
  ' "$destination") || return 1
  publish_pi_migration "$destination" "$rendered" 0644
}
