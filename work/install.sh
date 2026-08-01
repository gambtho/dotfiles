#!/usr/bin/env bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/../bin/common.sh"

download_apt_key() {
  local url="$1" destination="$2" temporary
  temporary=$(mktemp)
  curl --fail --show-error --location --connect-timeout 10 --max-time 120 --retry 3 "$url" --output "$temporary"
  sudo gpg --dearmor --yes --output "$destination" "$temporary"
  rm -f -- "$temporary"
  sudo chmod a+r "$destination"
}

setup_docker_repository() {
  download_apt_key https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
}

setup_kubernetes_repository() {
  download_apt_key https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' |
    sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
}

setup_microsoft_repositories() {
  download_apt_key https://packages.microsoft.com/keys/microsoft.asc /etc/apt/keyrings/microsoft.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ %s main\n' \
    "$(dpkg --print-architecture)" "$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")" |
    sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
  printf '%s\n' 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main' |
    sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
}

setup_work_apt_repositories() {
  sudo install -m 0755 -d /etc/apt/keyrings
  setup_docker_repository
  setup_kubernetes_repository
  setup_microsoft_repositories
}

install_krew_plugins() {
  if ! kubectl krew version >/dev/null 2>&1; then
    log_warning "kubectl krew is not available; install Krew before installing ctx and ns."
    return 1
  fi

  log_info "Installing kubectl ctx and ns plugins via Krew"
  kubectl krew install ctx ns
  log_success "kubectl ctx and ns plugins installed"
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

  install_krew_plugins
}

if [[ "${WORK_INSTALL_SOURCE_ONLY:-0}" != 1 ]]; then
  work_main "$@"
fi
