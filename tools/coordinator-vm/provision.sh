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

printf '%s\n' 'Provisioning finished. Continue with tools/coordinator-vm/README.md, "First boot".'
