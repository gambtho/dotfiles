#!/usr/bin/env bash
# tools/coordinator-vm/install-lanes.sh -- install lanes (the `lane` command)
# on the coordinator VM from its main branch, with the Relay extra. Run it after
# `gh auth login`: the lanes repository is private, and Git reaches it through
# gh, which the tracked Git config makes its credential helper.
#
# Usage: install-lanes.sh OWNER/REPO   (or: make coordinator-lanes LANES_REPO=OWNER/REPO)
#
# A rerun reinstalls from the current main.

set -euo pipefail

usage() {
  printf 'Usage: %s OWNER/REPO\n' "${0##*/}"
  printf '  OWNER/REPO is the GitHub repository lanes is published from.\n'
}

if (($# != 1)); then
  usage >&2
  exit 2
fi
case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
esac
repo=$1
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'install-lanes.sh: %s is not OWNER/REPO.\n' "$repo" >&2
  usage >&2
  exit 2
fi

die() {
  printf 'install-lanes.sh: %s\n' "$*" >&2
  exit 1
}

# provision.sh installs uv here; a non-login shell may not have it on PATH.
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || die 'uv is missing. Rerun tools/coordinator-vm/provision.sh, which installs it.'
command -v gh >/dev/null 2>&1 || die 'gh is missing. Rerun tools/coordinator-vm/provision.sh.'
gh auth status --hostname github.com >/dev/null 2>&1 ||
  die 'GitHub is not signed in. Run gh auth login (README, "First boot", step 2), then rerun this.'

# Python 3.11 is what lanes is tested on; uv downloads it if the box has none.
uv tool install --reinstall --python 3.11 "developerlanes[relay] @ git+https://github.com/$repo.git@main"

[[ -x "$HOME/.local/bin/lane" ]] || die 'uv finished, but ~/.local/bin/lane is missing.'
printf 'install-lanes.sh: lanes installed: %s. Next: lane doctor.\n' "$HOME/.local/bin/lane"
