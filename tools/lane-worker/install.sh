#!/usr/bin/env bash
# Set up a lanes worker box for review rounds, and nothing else: the pinned
# gambtho-skills plugin for Claude Code (through ai/claude/install.sh), and the
# review CLIs its skills call, pinned and digest-checked:
#   codex       cross-family review (lane-coordinator/scripts/codex-review.sh)
#   coderabbit  local CodeRabbit review round (pr-closeout)
#   jq          only when missing; the plugin installer and pr_snapshot.sh use it
#   git-lfs     only when missing; repositories with LFS hooks warn on every commit
#   kubectl     pinned to the Kubernetes channel
#   az          the Azure CLI: on Linux `uv tool install azure-cli==<pin>` (uv
#               pinned, unpacked privately), on macOS Homebrew; sign-in stays manual
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
# find on their PATH. Linux and macOS, x86_64 and arm64. Bash 3.2, as macOS
# ships it, runs it too.
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
# through an interactive shell's PATH (mise shims, npm or bun bins, Homebrew on
# Apple silicon) would not be found by a lane, so it does not count as present.
# Tests replace the system part with LANE_WORKER_SYSTEM_PATH.
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

ARCH="${ARTIFACT_ARCH:-$(uname -m)}"
case "$(uname -s)/$ARCH" in
  Linux/x86_64)
    CODEX_ASSET=codex-package-x86_64-unknown-linux-musl.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_LINUX_X86_64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-x64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_X64_SHA256
    JQ_ASSET=jq-linux-amd64
    JQ_SHA256=$JQ_LINUX_AMD64_SHA256
    GIT_LFS_ASSET=git-lfs-linux-amd64-v$GIT_LFS_VERSION.tar.gz
    GIT_LFS_SHA256=$GIT_LFS_LINUX_AMD64_SHA256
    KUBECTL_PLATFORM=linux/amd64
    KUBECTL_SHA256=$KUBECTL_LINUX_AMD64_SHA256
    UV_TARGET=x86_64-unknown-linux-gnu
    UV_SHA256=$UV_LINUX_X86_64_SHA256
    ;;
  Linux/aarch64 | Linux/arm64)
    CODEX_ASSET=codex-package-aarch64-unknown-linux-musl.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_LINUX_AARCH64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-arm64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_ARM64_SHA256
    JQ_ASSET=jq-linux-arm64
    JQ_SHA256=$JQ_LINUX_ARM64_SHA256
    GIT_LFS_ASSET=git-lfs-linux-arm64-v$GIT_LFS_VERSION.tar.gz
    GIT_LFS_SHA256=$GIT_LFS_LINUX_ARM64_SHA256
    KUBECTL_PLATFORM=linux/arm64
    KUBECTL_SHA256=$KUBECTL_LINUX_ARM64_SHA256
    UV_TARGET=aarch64-unknown-linux-gnu
    UV_SHA256=$UV_LINUX_AARCH64_SHA256
    ;;
  Darwin/x86_64)
    CODEX_ASSET=codex-package-x86_64-apple-darwin.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_DARWIN_X86_64_SHA256
    CODERABBIT_ASSET=coderabbit-darwin-x64.zip
    CODERABBIT_SHA256=$CODERABBIT_DARWIN_X64_SHA256
    JQ_ASSET=jq-macos-amd64
    JQ_SHA256=$JQ_MACOS_AMD64_SHA256
    GIT_LFS_ASSET=git-lfs-darwin-amd64-v$GIT_LFS_VERSION.zip
    GIT_LFS_SHA256=$GIT_LFS_DARWIN_AMD64_SHA256
    KUBECTL_PLATFORM=darwin/amd64
    KUBECTL_SHA256=$KUBECTL_DARWIN_AMD64_SHA256
    ;;
  Darwin/arm64 | Darwin/aarch64)
    CODEX_ASSET=codex-package-aarch64-apple-darwin.tar.gz
    CODEX_SHA256=$CODEX_PACKAGE_DARWIN_AARCH64_SHA256
    CODERABBIT_ASSET=coderabbit-darwin-arm64.zip
    CODERABBIT_SHA256=$CODERABBIT_DARWIN_ARM64_SHA256
    JQ_ASSET=jq-macos-arm64
    JQ_SHA256=$JQ_MACOS_ARM64_SHA256
    GIT_LFS_ASSET=git-lfs-darwin-arm64-v$GIT_LFS_VERSION.zip
    GIT_LFS_SHA256=$GIT_LFS_DARWIN_ARM64_SHA256
    KUBECTL_PLATFORM=darwin/arm64
    KUBECTL_SHA256=$KUBECTL_DARWIN_ARM64_SHA256
    ;;
  Linux/* | Darwin/*) die "unsupported architecture: $ARCH" ;;
  *) die "Linux and macOS only." ;;
esac

# Each unpacker fills the folder given as $1; this is the binary's path inside
# it. A function, not an associative array, because macOS ships bash 3.2.
entry() {
  case "$1" in
    codex) echo bin/codex ;;
    git-lfs) echo "git-lfs-$GIT_LFS_VERSION/git-lfs" ;;
    *) echo "$1" ;;
  esac
}

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
  if [[ "$target" == "$SHARE_DIR/$name-$version/$(entry "$name")" && -x "$target" ]]; then
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

unpack_kubectl() {
  download_verified_artifact "$KUBECTL_RELEASE_BASE/$KUBECTL_PLATFORM/kubectl" "$KUBECTL_SHA256" "$1/kubectl" 0755
}

unpack_jq() {
  download_verified_artifact "$JQ_RELEASE_BASE/$JQ_ASSET" "$JQ_SHA256" "$1/jq" 0755
}

# Extract one member of a zip as an executable. Workers often have no unzip,
# and python3's zipfile reads it on Linux and macOS alike.
unzip_member() {
  local archive="$1" member="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive, open(sys.argv[3], "wb") as out:
    out.write(archive.read(sys.argv[2]))' "$archive" "$member" "$out"
  chmod 0755 "$out"
}

unpack_git-lfs() {
  local member="git-lfs-$GIT_LFS_VERSION/git-lfs"
  case "$GIT_LFS_ASSET" in
    *.zip)
      download_verified_artifact "$GIT_LFS_RELEASE_BASE/$GIT_LFS_ASSET" "$GIT_LFS_SHA256" "$STAGE/git-lfs.zip"
      unzip_member "$STAGE/git-lfs.zip" "$member" "$1/$member"
      ;;
    *)
      download_verified_artifact "$GIT_LFS_RELEASE_BASE/$GIT_LFS_ASSET" "$GIT_LFS_SHA256" "$STAGE/git-lfs.tar.gz"
      tar -xzf "$STAGE/git-lfs.tar.gz" -C "$1" "$member"
      ;;
  esac
}

unpack_codex() {
  download_verified_artifact "$CODEX_RELEASE_BASE/$CODEX_ASSET" "$CODEX_SHA256" "$STAGE/codex.tar.gz"
  tar -xzf "$STAGE/codex.tar.gz" -C "$1"
}

unpack_coderabbit() {
  download_verified_artifact "$CODERABBIT_RELEASE_BASE/$CODERABBIT_ASSET" "$CODERABBIT_SHA256" "$STAGE/coderabbit.zip"
  unzip_member "$STAGE/coderabbit.zip" coderabbit "$1/coderabbit"
}

# Unpack into a staging folder beside the versioned one, rename it into place,
# then swap the link in ~/.local/bin with one rename. An interrupted run leaves
# only staging, which the next run removes. Older versions stay, because a
# running lane may still use them.
install_tool() {
  local name="$1" version="$2" dir="$SHARE_DIR/$1-$2" tool needed=(curl)
  case "$name/$GIT_LFS_ASSET" in
    codex/* | git-lfs/*.tar.gz) needed+=(tar) ;;
    coderabbit/* | git-lfs/*.zip) needed+=(python3) ;;
  esac
  for tool in "${needed[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is needed to install $name. Install it first; this script does not use sudo."
  done
  mkdir -p "$SHARE_DIR" "$BIN_DIR"
  rm -rf -- "$SHARE_DIR"/.staging-*
  STAGE=$(mktemp -d "$SHARE_DIR/.staging-XXXXXX")
  mkdir "$STAGE/$name"
  "unpack_$name" "$STAGE/$name"
  [[ -x "$STAGE/$name/$(entry "$name")" ]] || die "$name: $(entry "$name") is missing from the download."
  # A folder for this version without its binary is broken, so no lane can be
  # using it; set it aside with the staging, which is removed below.
  # publish_staged_file renames the way both GNU and macOS mv support; neither
  # destination exists here.
  if [[ -d "$dir" && ! -x "$dir/$(entry "$name")" ]]; then
    publish_staged_file "$dir" "$STAGE/broken"
  fi
  if [[ ! -d "$dir" ]]; then
    publish_staged_file "$STAGE/$name" "$dir"
  fi
  ln -s -- "$dir/$(entry "$name")" "$STAGE/link"
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
      say "Installed $name $version: $BIN_DIR/$name -> $SHARE_DIR/$name-$version/$(entry "$name")"
      ;;
  esac
}

# ── Azure CLI ────────────────────────────────────────────────────────────────

UV_TOOLS="${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"

# Sets UV to the uv this script uses on Linux: one lanes find, or the pinned
# build unpacked under ~/.local/share/lane-worker and not linked anywhere.
# Not called through $(...), so the EXIT trap still removes its staging.
find_or_unpack_uv() {
  local dir="$SHARE_DIR/uv-$UV_VERSION"
  if UV=$(PATH="$LANE_PATH" command -v uv 2>/dev/null); then
    return 0
  fi
  if [[ ! -x "$dir/uv" ]]; then
    command -v tar >/dev/null 2>&1 || die "tar is needed to install uv. Install it first; this script does not use sudo."
    mkdir -p "$SHARE_DIR"
    STAGE=$(mktemp -d "$SHARE_DIR/.staging-XXXXXX")
    download_verified_artifact "$UV_RELEASE_BASE/uv-$UV_TARGET.tar.gz" "$UV_SHA256" "$STAGE/uv.tar.gz"
    tar -xzf "$STAGE/uv.tar.gz" -C "$STAGE"
    [[ -x "$STAGE/uv-$UV_TARGET/uv" ]] || die "uv: uv-$UV_TARGET/uv is missing from the download."
    [[ ! -d "$dir" ]] || publish_staged_file "$dir" "$STAGE/broken"
    publish_staged_file "$STAGE/uv-$UV_TARGET" "$dir"
    rm -rf -- "$STAGE"
    STAGE=""
  fi
  UV="$dir/uv"
}

# Linux: `uv tool install` puts the Azure CLI in its own environment under
# $UV_TOOLS/azure-cli and links ~/.local/bin/az to it. A different pin
# replaces it there.
converge_az_linux() {
  local link="$BIN_DIR/az" target found
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    if found=$(PATH="$LANE_PATH" command -v az 2>/dev/null); then
      say "az is already at $found; leaving it."
      return 0
    fi
  else
    target=$(readlink "$link" 2>/dev/null) || target=""
    if [[ "$target" != "$UV_TOOLS/azure-cli/bin/az" ]]; then
      say "$link was not installed by uv; leaving it."
      return 0
    fi
    set -- "$UV_TOOLS"/azure-cli/lib/python*/site-packages/azure_cli-"$AZURE_CLI_VERSION".dist-info
    if [[ -d "$1" ]]; then
      say "az (azure-cli $AZURE_CLI_VERSION) is installed."
      return 0
    fi
  fi
  if [[ "$MODE" == check ]]; then
    say "[dry-run] Would run: uv tool install azure-cli==$AZURE_CLI_VERSION (into $UV_TOOLS, linked from $BIN_DIR)."
    return 0
  fi
  find_or_unpack_uv
  mkdir -p "$BIN_DIR"
  UV_TOOL_DIR="$UV_TOOLS" UV_TOOL_BIN_DIR="$BIN_DIR" "$UV" tool install --quiet "azure-cli==$AZURE_CLI_VERSION" ||
    die "uv could not install azure-cli $AZURE_CLI_VERSION."
  say "Installed azure-cli $AZURE_CLI_VERSION with uv: $link"
}

# macOS: Homebrew's azure-cli, without sudo. Lanes do not see /opt/homebrew/bin,
# so ~/.local/bin/az links to it there.
# Where Homebrew lives when it is not on PATH. Tests replace the list.
BREW_CANDIDATES="${LANE_WORKER_BREW_CANDIDATES-/opt/homebrew/bin/brew /usr/local/bin/brew}"

converge_az_macos() {
  local link="$BIN_DIR/az" brew="" prefix found
  # shellcheck disable=SC2086  # a space-separated list of paths
  for found in "$(command -v brew 2>/dev/null || true)" $BREW_CANDIDATES; do
    if [[ -n "$found" && -x "$found" ]]; then
      brew=$found
      break
    fi
  done
  if [[ -z "$brew" ]]; then
    if found=$(PATH="$LANE_PATH" command -v az 2>/dev/null); then
      say "az is already at $found; leaving it."
    else
      say "Homebrew is missing, so no az. Install Homebrew, then rerun."
    fi
    return 0
  fi
  prefix=$("$brew" --prefix)
  if [[ -z "$("$brew" list --versions azure-cli 2>/dev/null || true)" ]]; then
    if found=$(PATH="$LANE_PATH" command -v az 2>/dev/null); then
      say "az is already at $found; leaving it."
      return 0
    fi
    if [[ "$MODE" == check ]]; then
      say "[dry-run] Would run: brew install azure-cli"
    else
      "$brew" install azure-cli
      say "Installed azure-cli with Homebrew."
    fi
  else
    say "azure-cli is installed with Homebrew."
  fi
  # Link it where lanes look, unless they already find it or another az.
  if [[ -L "$link" && "$(readlink "$link")" == "$prefix/bin/az" ]]; then
    return 0
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    say "$link was not installed by this script; leaving it."
  elif found=$(PATH="$LANE_PATH" command -v az 2>/dev/null); then
    [[ "$found" == "$prefix/bin/az" ]] || say "Lanes find az at $found; not linking Homebrew's."
  elif [[ "$MODE" == check ]]; then
    say "[dry-run] Would link $link to $prefix/bin/az."
  else
    mkdir -p "$BIN_DIR"
    ln -s -- "$prefix/bin/az" "$link"
    say "Linked $link -> $prefix/bin/az"
  fi
}

# Lanes run `python`; Ubuntu and macOS ship only python3. Link ~/.local/bin/python to
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
converge_tool kubectl "$KUBECTL_VERSION"
if [[ "$(uname -s)" == Darwin ]]; then
  converge_az_macos
else
  converge_az_linux
fi
converge_python
note_codex_sandbox

if [[ ":$ORIGINAL_PATH:" != *":$BIN_DIR:"* ]]; then
  say "Note: $BIN_DIR is not on this shell's PATH. Lanes find claude there; this script does not change PATH."
fi

cat <<EOF

Sign in once per box, as the user the lanes run as (this script signs in to nothing):
  gh auth status                   GitHub CLI; lanes already need it
  codex login --device-auth        Codex for codex-review.sh (headless sign-in)
  coderabbit auth login            CodeRabbit for the local review round
  az login --use-device-code       Azure CLI, if the lanes need Azure
Then check from inside a lane that coderabbit auth status shows your account.
If a lane says "Non-interactive environment. Use --api-key", see the README.
Then start a new lane: running sessions load the plugin on their next start.
EOF
