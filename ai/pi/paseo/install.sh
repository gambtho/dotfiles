#!/usr/bin/env bash
# Opt-in Paseo provisioning; ordinary Pi reconciliation remains independent.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/common.sh"

# Transaction state is confined to one owned root and an atomic installer lock.
apply_reconciliation() (
  umask 0077
  local stage='' runtime_changed=0 config_changed=0 launcher_changed=0 unit_changed=0 stopped=0 started=0 enablement_changed=0 prior_runtime=0 prior_config=0 prior_launcher=0 prior_unit=0 prior_active=0 prior_enabled=0
  local auth_status=0 path
  resolve_node_dns_name || exit 1
  validate_state_root || exit 1
  read_service_state pi-webui.service || exit 1
  [[ "$SERVICE_ACTIVE_STATE" != active && "$SERVICE_FILE_STATE" != enabled ]] || {
    fail 'legacy Pi Web UI remains active or enabled; disable it explicitly first'
    exit 1
  }
  classify_existing_unit || exit 1
  [[ "$UNIT_KIND" == absent ]] || prior_unit=1
  local observe_runtime=$INSTALLED_RUNTIME observe_home=$PASEO_HOME
  if [[ "$UNIT_KIND" == trial ]]; then
    observe_runtime=$TRIAL_ROOT/runtime
    observe_home=$TRIAL_ROOT/home
  fi
  read_service_state paseo.service || exit 1
  [[ "$SERVICE_LOAD" != loaded || "$SERVICE_FRAGMENT" == "$UNIT_PATH" ]] || {
    fail 'loaded Paseo unit belongs to a foreign location'
    exit 1
  }
  [[ "$SERVICE_ACTIVE_STATE" != active ]] || prior_active=1
  [[ "$SERVICE_FILE_STATE" != enabled ]] || prior_enabled=1
  [[ "$prior_unit" -eq 1 || "$SERVICE_LOAD" == not-found ]] || {
    fail 'unowned loaded Paseo service'
    exit 1
  }
  for path in "$STATE_ROOT" "$PASEO_HOME" "$MANAGED_LAUNCHER" "$UNIT_PATH" "$MISE_LAUNCHER"; do safe_unit_path "$path" || exit 1; done
  if path_exists "$INSTALLED_RUNTIME"; then
    "$SOURCE_ROOT/libexec/validate-pi-paseo" --installed-runtime "$INSTALLED_RUNTIME" || exit 1
    validate_launcher || exit 1
    prior_runtime=1
  fi
  if [[ "$prior_active" -eq 1 ]]; then require_quiescent "$observe_runtime" "$observe_home" || exit 1; fi
  prepare_managed_directory "$STATE_ROOT" 'Paseo state root' || exit 1
  if [[ ! -f "$STATE_ROOT/.managed.json" ]]; then printf '{"kind":"dotfiles-paseo","schemaVersion":1}\n' >"$STATE_ROOT/.managed.json" || exit 1; fi
  prepare_managed_directory "$STATE_ROOT/runtimes" 'Paseo runtime parent' || exit 1
  prepare_managed_directory "$PASEO_HOME" 'Paseo home' || exit 1
  for path in "$STATE_ROOT"/.apply.* "$STATE_ROOT"/.install.lock; do
    ! path_exists "$path" || {
      fail "preserving prior installer evidence: $path"
      exit 1
    }
  done
  mkdir "$STATE_ROOT/.install.lock" || exit 1
  finish_transaction() {
    local status=$1 restore_failed=0
    trap - EXIT
    trap '' INT TERM HUP
    if [[ "$status" -ne 0 && "$status" -ne 2 ]]; then
      if [[ "$started" -eq 1 ]]; then systemctl --user stop paseo.service || restore_failed=1; fi
      if [[ "$runtime_changed" -eq 1 && ("$prior_runtime" -eq 0 || -d "$stage/prior-runtime") ]]; then
        if path_exists "$INSTALLED_RUNTIME"; then mv "$INSTALLED_RUNTIME" "$stage/discard-runtime" || restore_failed=1; fi
        if [[ "$prior_runtime" -eq 1 ]]; then mv "$stage/prior-runtime" "$INSTALLED_RUNTIME" || restore_failed=1; fi
      fi
      if [[ "$config_changed" -eq 1 ]]; then
        if [[ "$prior_config" -eq 1 ]]; then cp -p "$stage/prior-config" "$PASEO_HOME/config.json" || restore_failed=1; else rm -f "$PASEO_HOME/config.json" || restore_failed=1; fi
      fi
      if [[ "$launcher_changed" -eq 1 ]]; then
        if [[ "$prior_launcher" -eq 1 ]]; then cp -p "$stage/prior-launcher" "$MANAGED_LAUNCHER" || restore_failed=1; else rm -f "$MANAGED_LAUNCHER" || restore_failed=1; fi
      fi
      if [[ "$enablement_changed" -eq 1 ]]; then
        if [[ "$prior_enabled" -eq 1 ]]; then systemctl --user enable paseo.service || restore_failed=1; else systemctl --user disable paseo.service || restore_failed=1; fi
      fi
      if [[ "$unit_changed" -eq 1 ]]; then
        if [[ "$prior_unit" -eq 1 ]]; then cp -p "$stage/prior-unit" "$UNIT_PATH" || restore_failed=1; else rm -f "$UNIT_PATH" || restore_failed=1; fi
        systemctl --user daemon-reload || restore_failed=1
      fi
      if [[ "$stopped" -eq 1 && "$prior_active" -eq 1 ]]; then systemctl --user start paseo.service || restore_failed=1; fi
    fi
    if [[ "$status" -eq 0 && "$UNIT_KIND" == trial && -n "$stage" ]]; then
      local evidence=$STATE_ROOT/.rollback-trial.${stage##*.}
      mkdir "$evidence" && mv "$stage/prior-unit" "$evidence/unit" &&
        printf '{"kind":"dotfiles-paseo-trial-rollback","schemaVersion":1}\n' >"$evidence/identity.json" || restore_failed=1
    fi
    if [[ "$restore_failed" -eq 0 ]]; then
      [[ -z "$stage" ]] || rm -rf -- "$stage" || restore_failed=1
      rmdir "$STATE_ROOT/.install.lock" || restore_failed=1
    fi
    if [[ "$restore_failed" -ne 0 ]]; then
      fail "restoration failed; preserving private evidence: $stage"
      exit 1
    fi
    exit "$status"
  }
  trap 'finish_transaction $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  stage=$(mktemp -d "$STATE_ROOT/.apply.XXXXXX") || exit 1
  mkdir "$stage/runtime" || exit 1
  cp "$SOURCE_ROOT/ai/pi/paseo/runtime/"*.json "$stage/runtime/" || exit 1
  "$MISE_LAUNCHER" exec -- npm ci --prefix "$stage/runtime" --ignore-scripts --omit=dev || exit 1
  "$SOURCE_ROOT/libexec/validate-pi-paseo" --installed-runtime "$stage/runtime" || exit 1
  if path_exists "$PASEO_HOME/config.json"; then
    [[ -f "$PASEO_HOME/config.json" && ! -L "$PASEO_HOME/config.json" && $(stat -c %u "$PASEO_HOME/config.json") == "$(id -u)" ]] || {
      fail 'configuration must be an owned private regular file'
      exit 1
    }
    cp -p "$PASEO_HOME/config.json" "$stage/prior-config" || exit 1
    prior_config=1
  fi
  if path_exists "$MANAGED_LAUNCHER"; then
    cp -p "$MANAGED_LAUNCHER" "$stage/prior-launcher" || exit 1
    prior_launcher=1
  fi
  if [[ "$prior_unit" -eq 1 ]]; then cp -p "$UNIT_PATH" "$stage/prior-unit" || exit 1; fi
  node "$SOURCE_ROOT/ai/pi/paseo/config.mjs" reconcile "$stage/prior-config" "$stage/config" "$PI_LAUNCHER" "$SOURCE_ROOT/ai/pi/paseo/config.json" "$PASEO_NODE_DNS_NAME" || exit 1
  node "$SOURCE_ROOT/ai/pi/paseo/config.mjs" validate "$stage/config" "$PI_LAUNCHER" "$PASEO_NODE_DNS_NAME" || auth_status=$?
  [[ "$auth_status" -eq 0 || "$auth_status" -eq 2 ]] || exit 1
  render_launcher >"$stage/launcher" || exit 1
  chmod 0700 "$stage/launcher" || exit 1
  render_unit >"$stage/paseo.service" || exit 1
  if [[ "$auth_status" -eq 2 && "$UNIT_KIND" == managed ]]; then
    printf 'Choose a password with: %s daemon set-password\n' "$MANAGED_LAUNCHER"
    exit 2
  fi
  if [[ "$auth_status" -eq 0 ]]; then
    prepare_managed_directory "$(dirname "$UNIT_PATH")" 'systemd user unit directory' || exit 1
    systemd-analyze --user verify "$stage/paseo.service" || exit 1
  fi
  if [[ "$prior_config" -eq 1 ]]; then cmp -s "$PASEO_HOME/config.json" "$stage/prior-config" || {
    fail 'configuration changed during staging; rerun'
    exit 1
  }; else
    ! path_exists "$PASEO_HOME/config.json" || {
      fail 'configuration appeared during staging; rerun'
      exit 1
    }
  fi
  if [[ "$prior_active" -eq 1 && "$auth_status" -eq 0 ]]; then
    require_quiescent "$observe_runtime" "$observe_home" || exit 1
    stopped=1
    systemctl --user stop paseo.service || exit 1
    # Shutdown may flush new preferences. Refuse stale publication while leaving
    # the latest config intact; EXIT recovery restarts the preceding service.
    cmp -s "$PASEO_HOME/config.json" "$stage/prior-config" || {
      fail 'configuration changed during shutdown; rerun'
      exit 1
    }
  fi
  runtime_changed=1
  if [[ "$prior_runtime" -eq 1 ]]; then mv "$INSTALLED_RUNTIME" "$stage/prior-runtime" || exit 1; fi
  mv "$stage/runtime" "$INSTALLED_RUNTIME" || exit 1
  config_changed=1
  mv "$stage/config" "$PASEO_HOME/config.json" || exit 1
  launcher_changed=1
  mv "$stage/launcher" "$MANAGED_LAUNCHER" || exit 1
  if [[ "$auth_status" -eq 2 ]]; then
    printf 'Prepared without starting a daemon. Choose a password with: %s daemon set-password\n' "$MANAGED_LAUNCHER"
    exit 2
  fi
  unit_changed=1
  mv "$stage/paseo.service" "$UNIT_PATH" || exit 1
  systemctl --user daemon-reload || exit 1
  enablement_changed=1
  if [[ "$prior_unit" -eq 0 || "$prior_enabled" -eq 1 ]]; then systemctl --user enable paseo.service || exit 1; else systemctl --user disable paseo.service || exit 1; fi
  started=1
  systemctl --user start paseo.service || exit 1
  wait_for_active_health || exit 1
  if [[ "$prior_unit" -eq 1 && "$prior_active" -eq 0 ]]; then
    systemctl --user stop paseo.service || exit 1
    started=0
  fi
  printf 'Paseo reconciliation complete; trial state untouched\n'
)

retire_trial() {
  validate_state_root || return 1
  validate_launcher || return 1
  validate_unit || return 1
  "$SOURCE_ROOT/libexec/validate-pi-paseo" --installed-runtime "$INSTALLED_RUNTIME" || return 1
  resolve_node_dns_name || return 1
  node "$SOURCE_ROOT/ai/pi/paseo/config.mjs" validate "$PASEO_HOME/config.json" "$PI_LAUNCHER" "$PASEO_NODE_DNS_NAME" || return 1
  validate_active_health || return 1
  if ! path_exists "$TRIAL_ROOT"; then
    printf 'Trial already absent; nothing deleted\n'
    return 0
  fi
  validate_trial_bundle || return 1
  local evidence
  for evidence in "$STATE_ROOT"/.rollback-trial.*; do
    if path_exists "$evidence"; then
      require_managed_directory "$evidence" 'rollback evidence' || return 1
      cmp -s "$evidence/unit" <(render_trial_unit) || {
        fail 'foreign rollback evidence'
        return 1
      }
    fi
  done
  node "$SOURCE_ROOT/ai/pi/paseo/retire.mjs" "$TRIAL_ROOT" "$STATE_ROOT"
}

main() {
  local mode=${1:-} selection=0
  [[ $# -eq 1 && ("$mode" == --check || "$mode" == --apply || "$mode" == --retire-trial) ]] || {
    printf 'usage: %s --check|--apply|--retire-trial\n' "$0" >&2
    return 2
  }
  set_managed_paths
  paseo_selected || selection=$?
  [[ "$selection" -ne 2 ]] || return 2
  if [[ "$selection" -eq 1 ]]; then
    if [[ "$mode" != --check ]]; then
      fail 'Paseo provisioning requires DOTFILES_PASEO_ENABLED=1'
      return 1
    fi
    if path_exists "$STATE_ROOT" || path_exists "$UNIT_PATH"; then printf 'Paseo installed but not selected\n'; else printf 'Paseo not selected; skipping\n'; fi
    return 0
  fi
  require_supported_platform || return 1
  resolve_source || return 1
  [[ "$mode" == --check ]] || validate_apply_source || return 1
  resolve_mise || return 1
  resolve_pi || return 1
  "$SOURCE_ROOT/libexec/validate-pi-paseo" --tracked-only || return 1
  case "$mode" in
    --check) check_paseo ;;
    --apply) apply_reconciliation ;;
    --retire-trial) retire_trial ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
