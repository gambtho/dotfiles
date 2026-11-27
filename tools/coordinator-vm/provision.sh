#!/usr/bin/env bash
# tools/coordinator-vm/provision.sh -- set up the coordinator VM's admin account
# from this checkout. cloud-init runs it once on first boot; it is safe to run
# again by hand. It signs in to nothing and reads no secrets.
#
# Usage: provision.sh [GIT_IDENTITY_FILE]
#   GIT_IDENTITY_FILE is a Git config file with user.name and user.email. It is
#   needed only the first time, before bootstrap has written the local identity.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  printf '%s\n' 'provision.sh: run as the admin user, not root.' >&2
  exit 1
fi

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
identity_file=${1:-}
export PATH="$HOME/.local/bin:$PATH"

# Bootstrap reads the identity from Git's global config. Point Git at the
# deploy-time file for this one command so no stray ~/.gitconfig is left for
# the symlink step to trip over.
if [[ -n "$identity_file" && ! -f "$DOTFILES_ROOT/core/git/gitconfig.local.symlink" ]]; then
  GIT_CONFIG_GLOBAL="$identity_file" bash "$DOTFILES_ROOT/libexec/bootstrap" --non-interactive --profile server
else
  bash "$DOTFILES_ROOT/libexec/bootstrap" --non-interactive --profile server
fi

bash "$DOTFILES_ROOT/bin/dot-install"

# shellcheck source=libexec/lib/artifacts.sh
source "$DOTFILES_ROOT/libexec/lib/artifacts.sh"
# shellcheck source=config/versions.env
source "$DOTFILES_ROOT/config/versions.env"

# Claude Code runs the coordinator sessions. Full machines no longer install it
# (ai/README.md); this box exists to run it, as it exists to run Herdr. Its
# official installer is unpinned, and Claude Code updates itself afterwards.
if [[ ! -x "$HOME/.local/bin/claude" ]]; then
  ALLOW_REMOTE_INSTALLERS=1 run_remote_installer https://claude.ai/install.sh bash
  [[ -x "$HOME/.local/bin/claude" ]] || {
    printf '%s\n' 'provision.sh: the Claude Code installer did not leave ~/.local/bin/claude.' >&2
    exit 1
  }
fi

# uv installs lanes later (make coordinator-lanes), once GitHub is signed in.
# Pinned and digest-checked, like the other release downloads.
if [[ ! -x "$HOME/.local/bin/uv" ]]; then
  case "$(uname -m)" in
    x86_64) uv_target=x86_64-unknown-linux-gnu uv_sha256=$UV_LINUX_X86_64_SHA256 ;;
    aarch64 | arm64) uv_target=aarch64-unknown-linux-gnu uv_sha256=$UV_LINUX_AARCH64_SHA256 ;;
    *)
      printf 'provision.sh: no uv build for %s.\n' "$(uname -m)" >&2
      exit 1
      ;;
  esac
  uv_stage=$(mktemp -d)
  download_verified_artifact "$UV_RELEASE_BASE/uv-$uv_target.tar.gz" "$uv_sha256" "$uv_stage/uv.tar.gz"
  tar -xzf "$uv_stage/uv.tar.gz" -C "$uv_stage"
  mkdir -p "$HOME/.local/bin"
  for uv_tool in uvx uv; do
    publish_staged_file "$uv_stage/uv-$uv_target/$uv_tool" "$HOME/.local/bin/$uv_tool"
  done
  rm -rf -- "$uv_stage"
fi

# dot-install treats Herdr as optional; this box exists to run it.
if [[ ! -x "$HOME/.local/bin/herdr" ]]; then
  printf '%s\n' 'provision.sh: Herdr was not installed; see the dot-install output above.' >&2
  exit 1
fi

# One Herdr session at boot. cloud-init has already enabled lingering, which is
# what starts the user manager without a login.
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$unit_dir"
install -m 0644 "$DOTFILES_ROOT/tools/coordinator-vm/coordinator-herdr.service" "$unit_dir/coordinator-herdr.service"
systemctl --user daemon-reload
systemctl --user enable --now coordinator-herdr.service
# systemd reports the unit started as soon as the binary runs, so ask the
# server itself.
ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if "$HOME/.local/bin/herdr" workspace list >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  printf '%s\n' 'provision.sh: the Herdr server did not answer; see journalctl --user -u coordinator-herdr.service.' >&2
  exit 1
fi

printf '%s\n' 'Provisioning finished. Continue with tools/coordinator-vm/README.md, "First boot".'
