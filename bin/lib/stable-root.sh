#!/usr/bin/env bash
# The stable link root and worktree-aware project slugs used by the Claude
# project-overlay tooling (bin/claude-link-project) and the scripts that keep
# the root fresh (bin/bootstrap, bin/relink). Sourced, never executed; must not
# change the caller's shell options.

source "$(dirname "${BASH_SOURCE[0]}")/../log-helper"
source "$(dirname "${BASH_SOURCE[0]}")/system.sh"

# bin/claude-link-project symlinks personal Claude overlays into project trees.
# Those symlinks live in the project's working tree, which a devcontainer
# bind-mounts, so a $HOME-derived target ("/home/tng/.dotfiles/...") is wrong
# everywhere that mount is seen under a different $HOME — inside a container
# running as another user, or on a second machine. Repairing per environment
# cannot work: both sides see the same file, so fixing it for one breaks the
# other, forever.
#
# Instead every environment publishes the same path pointing at its own
# checkout, and overlay links target that:
#
#   host:      /opt/dotfiles -> /home/tng/.dotfiles
#   container: /opt/dotfiles -> /home/developer/.dotfiles
#
# /opt rather than a new top-level directory because macOS is a supported
# platform: / is not writable there without /etc/synthetic.conf and a reboot,
# while /opt takes a plain mkdir on both platforms.
#
# DOTFILES_LINK_ROOT exists so the test suite never touches the real /opt. It is
# deliberately NOT a per-environment knob — two environments disagreeing about
# the root reintroduce the exact dangling-link bug this removes.
STABLE_LINK_ROOT_DEFAULT="/opt/dotfiles"

stable_link_root() {
  printf '%s\n' "${DOTFILES_LINK_ROOT:-$STABLE_LINK_ROOT_DEFAULT}"
}

# Run with sudo only when the caller determined escalation is needed. Avoids
# expanding a possibly-empty array, which errors under `set -u` on bash 3.2
# (still the system bash on macOS).
_stable_link_root_run() {
  local use_sudo="$1"
  shift
  if [[ "$use_sudo" == 1 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# ensure_stable_link_root <canonical-checkout>
#
# The target is passed in, never inferred. bin/bootstrap and bin/relink both
# derive their root from the running script's own location, so inferring it here
# would aim the stable root at whichever linked worktree happened to invoke the
# command — pointing every overlay link at a directory that later gets deleted.
# Callers pass "$HOME/.dotfiles".
#
# Never fatal: a locked-down or passwordless host must still finish bootstrap.
# On failure overlay links fall back to $HOME-absolute targets, which is the
# pre-existing behavior rather than a regression.
ensure_stable_link_root() {
  local target="$1"
  local root parent current use_sudo=0

  root="$(stable_link_root)"
  parent="$(dirname "$root")"

  if [[ -z "$target" ]]; then
    log_warning "ensure_stable_link_root: no target given; leaving $root alone"
    return 0
  fi
  if [[ ! -d "$target" ]]; then
    log_warning "ensure_stable_link_root: $target is not a directory; leaving $root alone"
    return 0
  fi

  if [[ -L "$root" ]]; then
    current="$(readlink "$root")"
    if [[ "$current" == "$target" ]]; then
      log_info "Stable link root already correct: $root -> $target"
      return 0
    fi
    log_warning "Stable link root $root points at $current; repointing to $target"
  elif [[ -e "$root" ]]; then
    log_warning "$root exists as a real file or directory, not a symlink."
    log_warning "Move it aside and re-run. Until then overlay links keep using"
    log_warning "\$HOME-absolute targets, which break in containers."
    return 0
  fi

  # Escalate only when we cannot write the tree ourselves — a container running
  # as root, or a host where /opt is already user-writable, needs none.
  #
  # Test the nearest EXISTING ancestor, not $parent directly: when $parent does
  # not exist yet, `-w` on it is false for the trivial reason that it is absent,
  # and escalating on that alone makes the common case demand a password it
  # never needed.
  local probe="$parent"
  while [[ ! -e "$probe" && "$probe" != "/" && "$probe" != "." ]]; do
    probe="$(dirname "$probe")"
  done
  if [[ ! -w "$probe" ]]; then
    if command_exists sudo; then
      use_sudo=1
    else
      log_warning "Cannot write $probe and sudo is unavailable; leaving $root alone"
      return 0
    fi
  fi

  if [[ ! -d "$parent" ]] && ! _stable_link_root_run "$use_sudo" mkdir -p -- "$parent"; then
    log_warning "Could not create $parent; leaving $root alone"
    return 0
  fi

  # -n so an existing symlink is replaced rather than dereferenced, which would
  # otherwise create $root/<basename> inside the old target directory.
  if _stable_link_root_run "$use_sudo" ln -sfn -- "$target" "$root"; then
    log_success "Stable link root: $root -> $target"
  else
    log_warning "Could not create $root -> $target. Overlay links will fall back"
    log_warning "to \$HOME-absolute targets, which break in containers and on"
    log_warning "other machines."
  fi
  return 0
}

# Derive the slug a directory belongs to. Normally that is the directory's own
# name, but a linked git worktree is named after its branch, so the primary
# working tree's name is used instead (git lists it first in --porcelain
# output). Keeps the overlay claude-link-project writes and the directory the
# overlay reads back always pointing at the same place.
dev_slug_for_path() {
  local dir="$1" resolved slug main_root

  if ! resolved="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf 'dev_slug_for_path: no such directory: %s\n' "$dir" >&2
    return 1
  fi

  slug="$(basename "$resolved")"
  if main_root="$(git -C "$resolved" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{print substr($0, 10); exit}')" && [[ -d "$main_root" ]]; then
    slug="$(basename "$main_root")"
  fi

  printf '%s\n' "$slug"
}
