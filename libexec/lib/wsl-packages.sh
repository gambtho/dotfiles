#!/usr/bin/env bash
# WSL-only package prerequisites. Sourcing this file performs no actions.

wsl_ssh_configuration_exists() {
  [[ -e /etc/ssh/sshd_config || -L /etc/ssh/sshd_config ||
    -d /etc/ssh/sshd_config.d || -L /etc/ssh/sshd_config.d ||
    -e /etc/systemd/system/sshd.service || -L /etc/systemd/system/sshd.service ]]
}

wsl_stock_ssh_state() {
  local unit info property value load active state fragment dropins masked=0
  for unit in ssh.service ssh.socket; do
    info=$(systemctl show "$unit" -p LoadState -p ActiveState -p UnitFileState -p FragmentPath -p DropInPaths) || return 1
    load='' active='' state='' fragment='' dropins=''
    while IFS='=' read -r property value; do
      case "$property" in
        LoadState) load=$value ;;
        ActiveState) active=$value ;;
        UnitFileState) state=$value ;;
        FragmentPath) fragment=$value ;;
        DropInPaths) dropins=$value ;;
      esac
    done <<<"$info"
    [[ "$active" == inactive && -z "$dropins" ]] || return 1
    if [[ "$load" == masked && "$state" == masked ]]; then
      masked=$((masked + 1))
    elif [[ "$load" != not-found || -n "$state" || -n "$fragment" ]]; then
      return 1
    fi
  done
  if [[ "$masked" -eq 2 ]]; then printf 'masked\n'; else printf 'fresh\n'; fi
}

ensure_wsl_ssh_closed() {
  [[ ${OS:-} == WSL ]] || return 0
  local version listeners state package rc=0
  version=$(systemctl show --property=Version --value) || {
    printf 'WSL systemd is required before package installation; enable systemd for this distro and restart it. SSH was not changed.\n' >&2
    return 1
  }
  [[ -n "$version" ]] || return 1
  listeners=$(ss -H -ltn 'sport = :22') || return 1
  if [[ -n "$listeners" ]]; then
    printf 'Existing port-22 listener: SSH migration required; no access was disabled.\n' >&2
    return 1
  fi
  state=$(wsl_stock_ssh_state) || {
    printf 'Existing or unknown SSH unit state: migration required before WSL package changes.\n' >&2
    return 1
  }
  [[ "$state" != masked ]] || return 0
  package=$(dpkg-query -W '-f=${Status}' openssh-server 2>/dev/null) || rc=$?
  if [[ "$rc" != 1 || -n "$package" ]] || wsl_ssh_configuration_exists; then
    printf 'Existing or unknown OpenSSH deployment: migration required; no policy changed.\n' >&2
    return 1
  fi
  # Mask before install AND upgrade; never stop an existing deployment here.
  sudo systemctl mask ssh.service ssh.socket || return
  state=$(wsl_stock_ssh_state) || return 1
  [[ "$state" == masked ]] || return 1
  listeners=$(ss -H -ltn 'sport = :22') || return 1
  [[ -z "$listeners" ]]
}
