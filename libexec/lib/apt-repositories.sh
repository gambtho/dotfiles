#!/usr/bin/env bash
# Vendor APT repositories shared by the work profile (work/install.sh) and the
# opt-in cluster tools (tools/lane-worker/cluster-tools.sh). Each one writes its
# signing key to $APT_ETC/keyrings and a source that names it with signed-by.
# Sourced, never executed; must not change the caller's shell options.

: "${APT_ETC:=/etc/apt}"

download_apt_key() {
  local url="$1" destination="$2" temporary
  temporary=$(mktemp) || return
  if ! curl --fail --show-error --location --connect-timeout 10 --max-time 120 --retry 3 "$url" --output "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! sudo gpg --dearmor --yes --output "$destination" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
  sudo chmod a+r "$destination"
}

# OS_RELEASE_FILE lets tests describe another release.
os_codename() (
  # shellcheck source=/dev/null
  . "${OS_RELEASE_FILE:-/etc/os-release}"
  printf '%s' "${VERSION_CODENAME:-}"
)

# setup_docker_repository [DISTRO]: Docker publishes one tree per distribution;
# DISTRO is ubuntu (the default) or debian.
setup_docker_repository() {
  local distro="${1:-ubuntu}"
  download_apt_key "https://download.docker.com/linux/$distro/gpg" "$APT_ETC/keyrings/docker.gpg" || return
  printf 'deb [arch=%s signed-by=%s/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$APT_ETC" "$distro" "$(os_codename)" |
    sudo tee "$APT_ETC/sources.list.d/docker.list" >/dev/null || return
}

setup_azure_cli_repository() {
  download_apt_key https://packages.microsoft.com/keys/microsoft.asc "$APT_ETC/keyrings/microsoft.gpg" || return
  # The azure-cli installer ships a deb822 azure-cli.sources. Write the same
  # file rather than a legacy .list so the two cannot describe the same repo at
  # once, which makes apt warn about duplicate targets on every update.
  printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-By: %s/keyrings/microsoft.gpg\n' \
    "$(os_codename)" "$(dpkg --print-architecture)" "$APT_ETC" |
    sudo tee "$APT_ETC/sources.list.d/azure-cli.sources" >/dev/null || return
  sudo rm -f "$APT_ETC/sources.list.d/azure-cli.list"
}

# gVisor publishes one suite for every distribution; `release` follows its
# latest release.
setup_gvisor_repository() {
  download_apt_key https://gvisor.dev/archive.key "$APT_ETC/keyrings/gvisor-archive-keyring.gpg" || return
  printf 'deb [arch=%s signed-by=%s/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main\n' \
    "$(dpkg --print-architecture)" "$APT_ETC" |
    sudo tee "$APT_ETC/sources.list.d/gvisor.list" >/dev/null || return
}
