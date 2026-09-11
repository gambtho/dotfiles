#!/usr/bin/env bash
# Pinned, digest-verified artifact acquisition: bounded curl defaults, the
# consent gate for remote installer scripts, checksum verification, and the
# shared staged-file publish primitive. Sourced, never executed; must not
# change the caller's shell options.

ARTIFACTS_DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

CURL_DOWNLOAD_ARGS=(
  --fail
  --show-error
  --location
  --connect-timeout 10
  --max-time 120
  --retry 3
)

require_remote_installers() {
  if [[ "${ALLOW_REMOTE_INSTALLERS:-0}" != 1 ]]; then
    printf '%s\n' "Remote installer execution is disabled. Re-run with ALLOW_REMOTE_INSTALLERS=1 after reviewing the installer source." >&2
    return 1
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# The one way a staged file reaches a managed destination. On GNU coreutils,
# -T is what makes the rename safe against a destination that became a symlink
# after the caller's validation: without it, mv follows the link and drops the
# staged file *inside* the target directory instead of replacing the link. BSD
# mv (macOS) has no -T; there the caller's validation remains the only guard,
# which matches the pre-existing behavior on that platform. Real directories
# are refused outright on both.
publish_staged_file() {
  local staged="$1" destination="$2"

  if [[ ! -L "$destination" && -d "$destination" ]]; then
    printf 'refusing to publish over a directory: %s\n' "$destination" >&2
    return 1
  fi
  if mv --version 2>/dev/null | grep -q 'GNU coreutils'; then
    command mv -Tf -- "$staged" "$destination"
  else
    command mv -f -- "$staged" "$destination"
  fi
}

download_verified_artifact() {
  local url="$1"
  local expected="$2"
  local destination="$3"
  local mode="${4:-0644}"
  local temporary actual

  temporary=$(mktemp "${destination}.download.XXXXXX") || return 1
  if ! curl "${CURL_DOWNLOAD_ARGS[@]}" "$url" --output "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  actual=$(sha256_file "$temporary")
  if [[ "$actual" != "$expected" ]]; then
    printf 'checksum mismatch for %s: expected %s, got %s\n' "$url" "$expected" "$actual" >&2
    rm -f -- "$temporary"
    return 1
  fi
  chmod "$mode" "$temporary"
  if ! publish_staged_file "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

install_pinned_mise() {
  local destination="$1"
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest
  # shellcheck source=config/versions.env
  source "$ARTIFACTS_DOTFILES_ROOT/config/versions.env"

  case "$arch" in
    x86_64)
      asset="mise-${MISE_VERSION}-linux-x64"
      digest="$MISE_LINUX_X64_SHA256"
      ;;
    aarch64 | arm64)
      asset="mise-${MISE_VERSION}-linux-arm64"
      digest="$MISE_LINUX_ARM64_SHA256"
      ;;
    *)
      printf 'unsupported architecture for mise install: %s\n' "$arch" >&2
      return 2
      ;;
  esac
  mkdir -p "$(dirname "$destination")"
  download_verified_artifact "$MISE_RELEASE_BASE/$asset" "$digest" "$destination" 0755
}

install_pinned_yq() {
  local destination="$1"
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest
  # shellcheck source=config/versions.env
  source "$ARTIFACTS_DOTFILES_ROOT/config/versions.env"

  case "$arch" in
    x86_64)
      asset=yq_linux_amd64
      digest="$YQ_LINUX_AMD64_SHA256"
      ;;
    aarch64 | arm64)
      asset=yq_linux_arm64
      digest="$YQ_LINUX_ARM64_SHA256"
      ;;
    *)
      printf 'unsupported architecture for yq install: %s\n' "$arch" >&2
      return 2
      ;;
  esac
  mkdir -p "$(dirname "$destination")"
  download_verified_artifact "$YQ_RELEASE_BASE/$asset" "$digest" "$destination" 0755
}

run_remote_installer() {
  local url="$1"
  local script
  local status
  local argument_index
  local script_placed=false
  local -a command
  shift

  if (($# == 0)); then
    printf 'Remote installer command is required for %s.\n' "$url" >&2
    return 1
  fi
  command=("$@")

  require_remote_installers || return 1
  script=$(mktemp) || return 1

  if ! curl "${CURL_DOWNLOAD_ARGS[@]}" "$url" --output "$script"; then
    rm -f "$script"
    return 1
  fi

  for argument_index in "${!command[@]}"; do
    if [[ "${command[$argument_index]}" == "{}" ]]; then
      command[argument_index]="$script"
      script_placed=true
    fi
  done
  if [[ "$script_placed" != true ]]; then
    command+=("$script")
  fi

  if "${command[@]}"; then
    status=0
  else
    status=$?
  fi
  rm -f "$script"
  return "$status"
}
