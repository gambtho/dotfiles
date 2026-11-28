#!/usr/bin/env bash
# Opt-in fix for Codex's read-only sandbox on Ubuntu 24.04 and later, where
# AppArmor restricts unprivileged user namespaces
# (kernel.apparmor_restrict_unprivileged_userns=1). There bwrap cannot set up
# its namespaces, so every command Codex runs fails, for example with
# "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted".
# Nothing else runs this; `make codex-sandbox` does. It:
#   installs bubblewrap from the distribution, so Codex uses /usr/bin/bwrap
#     instead of its bundled copy;
#   installs Ubuntu's bwrap-userns-restrict AppArmor profile (a verbatim copy
#     from Ubuntu's apparmor-profiles package, bwrap-userns-restrict.apparmor
#     next to this script) as /etc/apparmor.d/bwrap-userns-restrict, and
#     loads it.
# The profile lets /usr/bin/bwrap create user namespaces and strips
# capabilities from what bwrap runs, so the restriction stays on for every
# other program. The sysctl is not changed.
#
# --check reads only. --apply uses sudo for apt, the profile file and
# apparmor_parser, and changes nothing that is already in place.
set -euo pipefail

usage() {
  printf 'Usage: %s --check | --apply\n' "${0##*/}"
}

if (($# != 1)); then
  usage >&2
  exit 2
fi
case "$1" in
  --check) MODE=check ;;
  --apply) MODE=apply ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

say() { printf 'codex-sandbox: %s\n' "$*"; }
die() {
  printf 'codex-sandbox: %s\n' "$*" >&2
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PROFILE_SOURCE="$REPO_ROOT/tools/lane-worker/bwrap-userns-restrict.apparmor"
# Tests replace these system paths.
USERNS_KNOB="${CODEX_SANDBOX_USERNS_KNOB:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
PROFILE="${CODEX_SANDBOX_APPARMOR_DIR:-/etc/apparmor.d}/bwrap-userns-restrict"
BWRAP="${CODEX_SANDBOX_BWRAP:-/usr/bin/bwrap}"
LANE_PATH="$HOME/.local/bin:${LANE_WORKER_SYSTEM_PATH:-/usr/local/bin:/usr/bin:/bin}"

if [[ "$(uname -s)" != Linux ]]; then
  say "Codex uses the system sandbox on $(uname -s); nothing to do."
  exit 0
fi
if [[ ! -r "$USERNS_KNOB" || "$(cat "$USERNS_KNOB")" != 1 ]]; then
  say "AppArmor does not restrict unprivileged user namespaces here; nothing to do."
  exit 0
fi
command -v dpkg >/dev/null 2>&1 ||
  die "AppArmor restricts user namespaces, but this is not a Debian-family system. Nothing was changed."

# shellcheck source=libexec/lib/apt.sh
source "$REPO_ROOT/libexec/lib/apt.sh"

# The same namespaces Codex asks for, network included: its loopback setup is
# what the restriction breaks first.
bwrap_works() {
  [[ -x "$BWRAP" ]] && "$BWRAP" --unshare-all --ro-bind / / --proc /proc --dev /dev true >/dev/null 2>&1
}

# ── bubblewrap ───────────────────────────────────────────────────────────────

if [[ "$(dpkg-query -W -f='${Status}' bubblewrap 2>/dev/null || true)" == *" ok installed" ]]; then
  say "bubblewrap is installed."
elif [[ "$MODE" == check ]]; then
  say "[dry-run] Would install bubblewrap (apt), so Codex uses $BWRAP."
else
  say "Installing bubblewrap (apt)."
  sudo_apt apt-get update >/dev/null
  sudo_apt apt-get install -y bubblewrap >/dev/null
  say "Installed bubblewrap."
fi

# ── AppArmor profile ─────────────────────────────────────────────────────────

LOAD=false
if [[ -e "$PROFILE" ]] && cmp -s "$PROFILE_SOURCE" "$PROFILE"; then
  say "$PROFILE is installed."
elif [[ -e "$PROFILE" ]]; then
  die "$PROFILE is there but is not Ubuntu's profile this script installs, so it was left alone. Compare it with $PROFILE_SOURCE."
elif [[ "$MODE" == check ]]; then
  say "[dry-run] Would install $PROFILE (Ubuntu's bwrap-userns-restrict) and load it."
else
  sudo install -m 0644 "$PROFILE_SOURCE" "$PROFILE"
  say "Installed $PROFILE."
  LOAD=true
fi

if bwrap_works; then
  say "$BWRAP can set up its sandbox."
elif [[ "$MODE" == check ]]; then
  if [[ -e "$PROFILE" ]]; then
    say "[dry-run] $BWRAP cannot set up its sandbox yet; --apply would load $PROFILE."
  fi
else
  LOAD=true
fi
if [[ "$LOAD" == true ]]; then
  sudo apparmor_parser -r "$PROFILE"
  say "Loaded $PROFILE."
  bwrap_works ||
    die "$BWRAP still cannot set up its sandbox after loading $PROFILE. See journalctl -k | grep apparmor."
  say "$BWRAP can set up its sandbox."
fi

# ── Codex itself ─────────────────────────────────────────────────────────────

if [[ "$MODE" == apply ]] || bwrap_works; then
  if codex=$(PATH="$LANE_PATH" command -v codex 2>/dev/null); then
    if (cd "$HOME" && PATH="$LANE_PATH" "$codex" sandbox linux -- true) >/dev/null 2>&1; then
      say "Codex's sandbox runs commands."
    else
      die "$BWRAP works, but codex sandbox linux -- true still fails. Run it to see why."
    fi
  else
    say "Lanes find no codex; make lane-worker installs it."
  fi
fi
