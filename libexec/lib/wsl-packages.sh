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

wsl_package_root() { printf '/\n'; }

wsl_ubuntu_codename() (
  # OS metadata is root-controlled; never execute a downloaded installer.
  source /etc/os-release
  [[ "$ID" == ubuntu ]] || return 1
  printf '%s\n' "$VERSION_CODENAME"
)

wsl_repository_safe_path() {
  local path=$1 root=$2 metadata owner mode
  while :; do
    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" ]]; then
      metadata=$(stat -c '%u %a' "$path") || return 1
      read -r owner mode <<<"$metadata"
      [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
      (((8#$mode & 8#022) == 0)) || return 1
    fi
    [[ "$path" != "$root" ]] || break
    path=$(dirname "$path")
  done
}

wsl_publish_repository_file() {
  local input=$1 destination=$2 temporary parent
  if [[ -e "$destination" ]]; then
    cmp -s "$input" "$destination" || {
      printf 'Refusing a different existing Tailscale repository artifact: %s\n' "$destination" >&2
      return 1
    }
    return 0
  fi
  temporary=$destination.dotfiles-new
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 1
  parent=$(dirname "$destination")
  if [[ ! -d "$parent" ]]; then
    sudo install -d -o root -g root -m 0755 "$parent" || return
  fi
  sudo install -o root -g root -m 0644 "$input" "$temporary" || return
  sudo mv -T -- "$temporary" "$destination" || {
    printf 'Repository publication incomplete; inspect retained candidate: %s\n' "$temporary" >&2
    return 1
  }
}

wsl_tailscale_key_valid() {
  local keyinfo fingerprints
  keyinfo=$(gpg --batch --no-options --homedir "$2" --with-colons --show-keys "$1" 2>/dev/null) || return 1
  [[ "$keyinfo" == *'pub:'* && "$keyinfo" != *'sec:'* ]] || return 1
  fingerprints=$(awk -F: '$1 == "pub" { primary=1; next } primary && $1 == "fpr" { print $10; primary=0 }' <<<"$keyinfo")
  # Official stable primary key, verified from the vendor's HTTPS artifact.
  # This trust anchor permits offline reuse, not silent signing-key rotation.
  [[ "$fingerprints" == 2596A99EAAB33821893C0A79458CA832957F5868 ]]
}

setup_wsl_tailscale_repository() (
  [[ ${OS:-} == WSL ]] || return 0
  local root codename key source_file candidate expected declarations file status
  root=$(wsl_package_root) || return
  [[ "$root" == /* && "$root" != *'/../'* ]] || return 1
  root=${root%/}
  codename=$(wsl_ubuntu_codename) || return
  [[ "$codename" =~ ^[a-z]+$ ]] || return 1
  key=$root/usr/share/keyrings/tailscale-archive-keyring.gpg
  source_file=$root/etc/apt/sources.list.d/tailscale.list
  for candidate in "$key" "$source_file"; do
    wsl_repository_safe_path "$candidate" "${root:-/}" || {
      printf 'Unsafe Tailscale repository destination: %s\n' "$candidate" >&2
      return 1
    }
  done
  for file in "$root/etc/apt/sources.list" "$root/etc/apt/sources.list.d/"*.list "$root/etc/apt/sources.list.d/"*.sources; do
    [[ -e "$file" || -L "$file" ]] || continue
    [[ ! -L "$file" ]] || return 1
    [[ "$file" != "$source_file" ]] || continue
    status=0
    grep -Eq '^[[:space:]]*[^#].*pkgs[.]tailscale[.]com' "$file" || status=$?
    if [[ "$status" != 1 ]]; then
      printf 'Existing or unreadable Tailscale source configuration requires inspection: %s\n' "$file" >&2
      return 1
    fi
  done
  temporary=$(mktemp -d) || return
  trap 'rm -r -- "$temporary"' EXIT
  mkdir -m 0700 "$temporary/gpg" || return
  expected="deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu $codename main"
  if [[ -e "$source_file" ]]; then
    declarations=$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$source_file") || return
    [[ "$declarations" == "$expected" ]] || {
      printf 'Foreign Tailscale source declaration requires migration\n' >&2
      return 1
    }
  fi
  if [[ -e "$key" ]]; then
    wsl_tailscale_key_valid "$key" "$temporary/gpg" || {
      printf 'Unknown Tailscale signing key requires inspection\n' >&2
      return 1
    }
  fi
  # A known, Root-controlled local repository remains usable without fetching
  # its setup artifacts on every OS/security update. APT verifies Release data.
  [[ ! -e "$key" || ! -e "$source_file" ]] || return 0
  for candidate in noarmor.gpg tailscale-keyring.list; do
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 120 --max-filesize 1048576 --retry 3 \
      "https://pkgs.tailscale.com/stable/ubuntu/$codename.$candidate" \
      --output "$temporary/$candidate" || return
    [[ -s "$temporary/$candidate" ]] || return 1
    [[ $(stat -c %s "$temporary/$candidate") -le 1048576 ]] || return 1
  done
  wsl_tailscale_key_valid "$temporary/noarmor.gpg" "$temporary/gpg" || {
    printf 'Invalid or unknown Tailscale signing key\n' >&2
    return 1
  }
  declarations=$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$temporary/tailscale-keyring.list") || return
  [[ "$declarations" == "$expected" ]] || {
    printf 'Unexpected Tailscale signed repository declaration\n' >&2
    return 1
  }
  # Both existing and downloaded artifacts have been validated before writes.
  if [[ ! -e "$key" ]]; then
    wsl_publish_repository_file "$temporary/noarmor.gpg" "$key" || return
  fi
  if [[ ! -e "$source_file" ]]; then
    wsl_publish_repository_file "$temporary/tailscale-keyring.list" "$source_file" || return
  fi
  return 0
)
