#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../bin/common.sh"
# shellcheck source=config/versions.env
source "$(dirname "${BASH_SOURCE[0]}")/../config/versions.env"

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

setup_docker_repository() {
  download_apt_key https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.gpg || return
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || return
}

setup_kubernetes_repository() {
  download_apt_key "https://pkgs.k8s.io/core:/stable:/$KUBERNETES_CHANNEL/deb/Release.key" /etc/apt/keyrings/kubernetes-apt-keyring.gpg || return
  printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "$KUBERNETES_CHANNEL" |
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null || return
}

setup_microsoft_repositories() {
  download_apt_key https://packages.microsoft.com/keys/microsoft.asc /etc/apt/keyrings/microsoft.gpg || return
  # The azure-cli installer ships a deb822 azure-cli.sources. Write the same
  # file rather than a legacy .list so the two cannot describe the same repo at
  # once, which makes apt warn about duplicate targets on every update.
  printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/microsoft.gpg\n' \
    "$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" "$(dpkg --print-architecture)" |
    sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null || return
  sudo rm -f /etc/apt/sources.list.d/azure-cli.list || return
  printf '%s\n' 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main' |
    sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
}

setup_work_apt_repositories() {
  sudo install -m 0755 -d /etc/apt/keyrings || return
  setup_docker_repository || return
  setup_kubernetes_repository || return
  setup_microsoft_repositories
}

krew_bin_directory() {
  printf '%s/bin\n' "${KREW_ROOT:-$HOME/.krew}"
}

# Krew installs itself as a kubectl plugin under $KREW_ROOT, which only becomes
# reachable once its bin directory is on PATH. The install below and every later
# `kubectl krew` call in this process need that, and work/path.zsh repeats it for
# interactive shells.
use_krew_bin_directory() {
  local directory
  directory="$(krew_bin_directory)"
  [[ ":$PATH:" == *":$directory:"* ]] || export PATH="$directory:$PATH"
}

# macOS gets Krew from platforms/macos/brewfile. Linux and WSL have no package
# for it, so without this a work host warned "install Krew first" on every run
# and never got the ctx/ns plugins. Pinned tarball rather than upstream's
# install script: same policy as every other artifact in config/versions.env.
install_krew() {
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest workspace status=0

  if kubectl krew version >/dev/null 2>&1; then
    return 0
  fi

  case "$OS" in
    Ubuntu | WSL) ;;
    *)
      log_warning "No automated Krew install for $OS; install Krew before installing ctx and ns."
      return 1
      ;;
  esac

  case "$arch" in
    x86_64 | amd64)
      asset=krew-linux_amd64
      digest="$KREW_LINUX_AMD64_SHA256"
      ;;
    aarch64 | arm64)
      asset=krew-linux_arm64
      digest="$KREW_LINUX_ARM64_SHA256"
      ;;
    *)
      log_warning "No reviewed Krew artifact for $arch; install Krew before installing ctx and ns."
      return 1
      ;;
  esac

  workspace="$(mktemp -d)" || return 1
  log_info "Installing Krew $KREW_VERSION"
  if download_verified_artifact "$KREW_RELEASE_BASE/$asset.tar.gz" "$digest" "$workspace/krew.tar.gz" &&
    tar -xzf "$workspace/krew.tar.gz" -C "$workspace" "./$asset" &&
    "$workspace/$asset" install krew; then
    log_success "Krew installed"
  else
    log_warning "Krew install failed; kubectl ctx and ns were skipped."
    status=1
  fi
  rm -rf -- "$workspace"
  return "$status"
}

install_krew_plugins() {
  if ! kubectl krew version >/dev/null 2>&1; then
    log_warning "kubectl krew is not available; install Krew before installing ctx and ns."
    return 1
  fi

  log_info "Installing kubectl ctx and ns plugins via Krew"
  # Krew skips plugins that are already present, so re-running the work profile
  # is a no-op rather than a failure.
  kubectl krew install ctx ns
  log_success "kubectl ctx and ns plugins installed"
}

setup_kubectl_plugins() {
  if ! command_exists kubectl; then
    log_warning "kubectl is not installed; skipping Krew and the ctx and ns plugins."
    return 1
  fi

  use_krew_bin_directory
  install_krew || return 1
  install_krew_plugins
}

work_main() {
  detect_os

  case "$OS" in
    Ubuntu | WSL)
      if command_exists docker; then
        sudo usermod -aG docker "$USER"
      fi
      ;;
    *) ;;
  esac

  setup_kubectl_plugins
}

if [[ "${WORK_INSTALL_SOURCE_ONLY:-0}" != 1 ]]; then
  work_main "$@"
fi
