#!/usr/bin/env bash
# Set up a lanes worker box for review rounds, and nothing else: the pinned
# gambtho-skills plugin for Claude Code (through ai/claude/install.sh), and the
# review CLIs its skills call, pinned and digest-checked:
#   codex       cross-family review (lane-coordinator/scripts/codex-review.sh)
#   coderabbit  local CodeRabbit review round (pr-closeout)
#   jq          only when missing; the plugin installer and pr_snapshot.sh use it
#   git-lfs     only when missing; repositories with LFS hooks warn on every commit
# and links ~/.local/bin/python to the system python3 when lanes find no python.
#
# Each tool unpacks into its own versioned folder under
# ~/.local/share/lane-worker, and ~/.local/bin/<tool> (where claude already
# lives on a worker) links to it. Codex keeps its whole release package, so it
# finds its bundled bwrap sandbox helper.
#
# No sudo, no sign-in. It does not touch the login shell, shell profiles, PATH
# files, systemd user units, Herdr, lanes or ~/.developerlanes. A file in
# ~/.local/bin it did not link is left alone, and so is a tool lanes already
# find on their PATH. Linux only.
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BIN_DIR="$HOME/.local/bin"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/lane-worker"
# The PATH a systemd user service gets, plus ~/.local/bin. A tool found only
# through an interactive shell's PATH (mise shims, npm or bun bins) would not
# be found by a lane, so it does not count as present. Tests replace the
# system part with LANE_WORKER_SYSTEM_PATH.
LANE_PATH="$BIN_DIR:${LANE_WORKER_SYSTEM_PATH:-/usr/local/bin:/usr/bin:/bin}"
ORIGINAL_PATH="$PATH"

# shellcheck source=libexec/lib/artifacts.sh
source "$REPO_ROOT/libexec/lib/artifacts.sh"
# shellcheck source=config/versions.env
source "$REPO_ROOT/config/versions.env"

say() { printf 'lane-worker: %s\n' "$*"; }
die() {
  printf 'lane-worker: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == Linux ]] || die "Linux only."
case "${ARTIFACT_ARCH:-$(uname -m)}" in
  x86_64)
    CODEX_ASSET=codex-package-x86_64-unknown-linux-musl.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_LINUX_X86_64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-x64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_X64_SHA256
    JQ_ASSET=jq-linux-amd64
    JQ_SHA256=$JQ_LINUX_AMD64_SHA256
    GIT_LFS_ASSET=git-lfs-linux-amd64-v$GIT_LFS_VERSION.tar.gz
    GIT_LFS_SHA256=$GIT_LFS_LINUX_AMD64_SHA256
    ;;
  aarch64 | arm64)
    CODEX_ASSET=codex-package-aarch64-unknown-linux-musl.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_LINUX_AARCH64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-arm64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_ARM64_SHA256
    JQ_ASSET=jq-linux-arm64
    JQ_SHA256=$JQ_LINUX_ARM64_SHA256
    GIT_LFS_ASSET=git-lfs-linux-arm64-v$GIT_LFS_VERSION.tar.gz
    GIT_LFS_SHA256=$GIT_LFS_LINUX_ARM64_SHA256
    ;;
  *) die "unsupported architecture: ${ARTIFACT_ARCH:-$(uname -m)}" ;;
esac

# Each unpacker fills the folder given as $1; the second word is the binary's
# path inside it.
declare -A ENTRY=([codex]=bin/codex [coderabbit]=coderabbit [jq]=jq ["git-lfs"]="git-lfs-$GIT_LFS_VERSION/git-lfs")

# What to do with one tool. Prints one word, then a path for the last two:
#   current   ~/.local/bin/<name> links to this version's folder
#   install   no ~/.local/bin/<name>, and lanes find no <name> elsewhere
#   replace   ~/.local/bin/<name> links to another version this script installed
#   foreign   ~/.local/bin/<name> is something this script did not link
#   external  no ~/.local/bin/<name>, but lanes find <name> elsewhere
tool_state() {
  local name="$1" version="$2" link="$BIN_DIR/$1" target found
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    if found=$(PATH="$LANE_PATH" command -v "$name" 2>/dev/null); then
      echo "external $found"
    else
      echo install
    fi
    return
  fi
  target=$(readlink "$link" 2>/dev/null) || target=""
  if [[ "$target" == "$SHARE_DIR/$name-$version/${ENTRY[$name]}" && -x "$target" ]]; then
    echo current
  elif [[ "$target" == "$SHARE_DIR/$name-"* ]]; then
    echo replace
  else
    echo "foreign $link"
  fi
}

STAGE=""
cleanup() { [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"; }
trap cleanup EXIT

unpack_jq() {
  download_verified_artifact "$JQ_RELEASE_BASE/$JQ_ASSET" "$JQ_SHA256" "$1/jq" 0755
}

unpack_git-lfs() {
  download_verified_artifact "$GIT_LFS_RELEASE_BASE/$GIT_LFS_ASSET" "$GIT_LFS_SHA256" "$STAGE/git-lfs.tar.gz"
  tar -xzf "$STAGE/git-lfs.tar.gz" -C "$1" "git-lfs-$GIT_LFS_VERSION/git-lfs"
}

unpack_codex() {
  download_verified_artifact "$CODEX_RELEASE_BASE/$CODEX_ASSET" "$CODEX_SHA256" "$STAGE/codex.tar.gz"
  tar -xzf "$STAGE/codex.tar.gz" -C "$1"
}

unpack_coderabbit() {
  download_verified_artifact "$CODERABBIT_RELEASE_BASE/$CODERABBIT_ASSET" "$CODERABBIT_SHA256" "$STAGE/coderabbit.zip"
  # Workers often have no unzip; python3's zipfile reads the one member.
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive, open(sys.argv[2], "wb") as out:
    out.write(archive.read("coderabbit"))' "$STAGE/coderabbit.zip" "$1/coderabbit"
  chmod 0755 "$1/coderabbit"
}

# Unpack into a staging folder beside the versioned one, rename it into place,
# then swap the link in ~/.local/bin with one rename. An interrupted run leaves
# only staging, which the next run removes. Older versions stay, because a
# running lane may still use them.
install_tool() {
  local name="$1" version="$2" dir="$SHARE_DIR/$1-$2" tool needed=(curl)
  case "$name" in
    codex | git-lfs) needed+=(tar) ;;
    coderabbit) needed+=(python3) ;;
  esac
  for tool in "${needed[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is needed to install $name. Install it first; this script does not use sudo."
  done
  mkdir -p "$SHARE_DIR" "$BIN_DIR"
  rm -rf -- "$SHARE_DIR"/.staging-*
  STAGE=$(mktemp -d "$SHARE_DIR/.staging-XXXXXX")
  mkdir "$STAGE/$name"
  "unpack_$name" "$STAGE/$name"
  [[ -x "$STAGE/$name/${ENTRY[$name]}" ]] || die "$name: ${ENTRY[$name]} is missing from the download."
  # A folder for this version without its binary is broken, so no lane can be
  # using it; set it aside with the staging, which is removed below.
  if [[ -d "$dir" && ! -x "$dir/${ENTRY[$name]}" ]]; then
    mv -T -- "$dir" "$STAGE/broken"
  fi
  if [[ ! -d "$dir" ]]; then
    mv -T -- "$STAGE/$name" "$dir"
  fi
  ln -s -- "$dir/${ENTRY[$name]}" "$STAGE/link"
  publish_staged_file "$STAGE/link" "$BIN_DIR/$name"
  rm -rf -- "$STAGE"
  STAGE=""
}

converge_tool() {
  local name="$1" version="$2" state
  state=$(tool_state "$name" "$version")
  case "$state" in
    current) say "$name $version is installed." ;;
    external\ *) say "$name is already at ${state#external }; leaving it." ;;
    foreign\ *)
      say "${state#foreign } was not installed by this script; leaving it."
      [[ "$name" == jq || "$name" == git-lfs ]] || say "  Move it aside and rerun to use the pinned $name $version."
      ;;
    install | replace)
      if [[ "$MODE" == check ]]; then
        say "[dry-run] Would $state $name $version."
        return 0
      fi
      install_tool "$name" "$version"
      say "Installed $name $version: $BIN_DIR/$name -> $SHARE_DIR/$name-$version/${ENTRY[$name]}"
      ;;
  esac
}

# Lanes run `python`; Ubuntu ships only python3. Link ~/.local/bin/python to
# the python3 lanes find, like python-is-python3 but without sudo.
converge_python() {
  local link="$BIN_DIR/python" found python3_path
  python3_path=$(PATH="${LANE_PATH#"$BIN_DIR:"}" command -v python3 2>/dev/null) || python3_path=""
  if [[ -L "$link" && -n "$python3_path" && "$(readlink "$link")" == "$python3_path" ]]; then
    say "python links to $python3_path."
  elif [[ -e "$link" || -L "$link" ]]; then
    say "$link was not installed by this script; leaving it."
  elif found=$(PATH="$LANE_PATH" command -v python 2>/dev/null); then
    say "python is already at $found; leaving it."
  elif [[ -z "$python3_path" ]]; then
    say "No python3 where lanes look (${LANE_PATH#"$BIN_DIR:"}), so no python link. Install python3 first."
  elif [[ "$MODE" == check ]]; then
    say "[dry-run] Would link $link to $python3_path."
  else
    mkdir -p "$BIN_DIR"
    rm -rf -- "$SHARE_DIR"/.staging-*
    mkdir -p "$SHARE_DIR"
    STAGE=$(mktemp -d "$SHARE_DIR/.staging-XXXXXX")
    ln -s -- "$python3_path" "$STAGE/link"
    publish_staged_file "$STAGE/link" "$link"
    rm -rf -- "$STAGE"
    STAGE=""
    say "Linked $link -> $python3_path"
  fi
}

# Codex's bundled bwrap needs unprivileged user namespaces, which Ubuntu's
# AppArmor policy can deny. Then every command in its read-only sandbox fails.
note_codex_sandbox() {
  local knob=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  [[ -r "$knob" && "$(cat "$knob")" == 1 ]] || return 0
  say "Note: AppArmor restricts unprivileged user namespaces here, so Codex's sandbox"
  say "  probably cannot run commands. Check it from a lane worktree (README, \"Codex sandbox\")."
}

# Claude Code runs the lanes; without it there is nothing to set up.
[[ ":$PATH:" == *":$BIN_DIR:"* ]] || PATH="$BIN_DIR:$PATH"
if ! command -v claude >/dev/null 2>&1; then
  [[ "$MODE" == check ]] || die "claude is missing. A lanes worker runs lanes with Claude Code; install it first."
  say "[dry-run] claude is missing, so --apply would stop."
fi

converge_tool jq "$JQ_VERSION"

if [[ "$MODE" == check ]]; then
  if command -v jq >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
    bash "$REPO_ROOT/ai/claude/install.sh" --check
  else
    say "[dry-run] Would install the pinned gambtho-skills plugin for Claude Code (needs claude and jq)."
  fi
else
  bash "$REPO_ROOT/ai/claude/install.sh"
fi

converge_tool codex "$CODEX_VERSION"
converge_tool coderabbit "$CODERABBIT_CLI_VERSION"
converge_tool git-lfs "$GIT_LFS_VERSION"
converge_python
note_codex_sandbox

if [[ ":$ORIGINAL_PATH:" != *":$BIN_DIR:"* ]]; then
  say "Note: $BIN_DIR is not on this shell's PATH. Lanes find claude there; this script does not change PATH."
fi

cat <<EOF

Sign in once per box, as the user the lanes run as (this script does neither):
  gh auth status                   GitHub CLI; lanes already need it
  codex login --device-auth        Codex for codex-review.sh (headless sign-in)
  coderabbit auth login            CodeRabbit for the local review round
Then check from inside a lane that coderabbit auth status shows your account.
If a lane says "Non-interactive environment. Use --api-key", see the README.
Then start a new lane: running sessions load the plugin on their next start.
EOF
