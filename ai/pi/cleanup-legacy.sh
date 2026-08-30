#!/usr/bin/env bash

set -euo pipefail

# Remove only machine-local artifacts that the retired dotfiles integrations can
# positively identify as their own. User credentials and endpoint overrides are
# intentionally outside this cleanup.

legacy_systemd_user_available() {
  command_exists systemctl || return 1
  if [[ "${PI_ALLOW_REDIRECTED_SYSTEMD:-0}" == 1 ]]; then
    return 0
  fi
  local real_home
  real_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [[ -n "$real_home" && "$HOME" == "$real_home" ]] || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

stop_recorded_vekil() {
  local state_dir=$1 vekil_bin=$2 pid_file pid expected_start extra actual_start actual_exe
  pid_file="$state_dir/proxy.pid"
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 0
  IFS='|' read -r pid expected_start extra <"$pid_file" || return 0
  [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$expected_start" && -z "$extra" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  actual_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  actual_exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  if [[ "$actual_start" != "$expected_start" || "$actual_exe" != "$(readlink -f "$vekil_bin" 2>/dev/null || true)" ]]; then
    log_warning "Recorded Vekil PID $pid could not be verified; leaving Vekil runtime artifacts untouched."
    return 1
  fi

  log_info "Stopping retired Vekil proxy (pid $pid)..."
  kill "$pid"
  local _attempt
  for _attempt in {1..50}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  if [[ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)" == "$expected_start" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
}

remove_retired_link() {
  local destination=$1 expected_suffix=$2 target
  [[ -L "$destination" ]] || return 0
  target=$(readlink "$destination")
  case "$target" in
    *"$expected_suffix")
      rm "$destination"
      log_info "Removed retired AI configuration link: $destination"
      ;;
  esac
}

cleanup_legacy_ai() {
  local systemd_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  local service="$systemd_dir/vekil.service"
  local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vekil"
  local vekil_bin="$HOME/.local/bin/vekil"
  local managed_state=false vekil_cleanup_safe=true service_is_managed=false

  if [[ -f "$state_dir/installed-version" && ! -L "$state_dir/installed-version" ]]; then
    managed_state=true
  fi
  if [[ -f "$service" && ! -L "$service" ]] &&
    grep -Eq '(^Description=Vekil AI model proxy|/bin/vekil-proxy (start|stop)$)' "$service"; then
    service_is_managed=true
  fi
  if ! stop_recorded_vekil "$state_dir" "$vekil_bin"; then
    vekil_cleanup_safe=false
  fi

  if [[ "$vekil_cleanup_safe" == true && "$service_is_managed" == true ]]; then
    if legacy_systemd_user_available; then
      systemctl --user disable vekil.service >/dev/null 2>&1 || true
      # ExecStop points at the now-removed lifecycle script and may fail, but
      # asking systemd to stop still clears the unit's RemainAfterExit state.
      systemctl --user stop vekil.service >/dev/null 2>&1 || true
    fi
    rm -f "$service"
    rm -rf "$systemd_dir/vekil.service.d"
    if legacy_systemd_user_available; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user reset-failed vekil.service >/dev/null 2>&1 || true
    fi
    log_info "Removed retired Vekil user service."
  fi

  if [[ "$vekil_cleanup_safe" == true && "$managed_state" == true ]]; then
    if [[ -f "$vekil_bin" && ! -L "$vekil_bin" ]]; then
      rm -f "$vekil_bin"
    fi
    if [[ -d "$state_dir" && ! -L "$state_dir" ]]; then
      rm -rf "$state_dir"
    fi
    log_info "Removed retired Vekil binary and runtime state."
  fi

  local codex_auth="$HOME/.codex/auth.json"
  if [[ -f "$codex_auth" && ! -L "$codex_auth" ]] && command_exists jq &&
    jq -e '. == {"auth_mode":"apikey","OPENAI_API_KEY":"dummy"}' "$codex_auth" >/dev/null 2>&1; then
    rm "$codex_auth"
    log_info "Removed the generated Codex dummy-key authentication file."
  fi

  remove_retired_link "$HOME/.codex/AGENTS.md" '/ai/codex/AGENTS.md'
  remove_retired_link "$HOME/.claude/CLAUDE.md" '/ai/claude/CLAUDE.md'
  remove_retired_link "$HOME/.claude/settings.json" '/ai/claude/settings.json'
}
