#!/usr/bin/env bash
# Set up a lanes worker box for review rounds, and nothing else: the pinned
# gambtho-skills plugin for Claude Code (through ai/claude/install.sh), and the
# review CLIs its skills call, as pinned, digest-checked binaries in
# ~/.local/bin (where claude already lives on a worker):
#   codex       cross-family review (lane-coordinator/scripts/codex-review.sh)
#   coderabbit  local CodeRabbit review round (pr-closeout)
#   jq          only when missing; the plugin installer and pr_snapshot.sh use it
#
# No sudo, no sign-in. It does not touch the login shell, shell profiles, PATH
# files, systemd user units, Herdr, lanes or ~/.developerlanes. It writes only
# ~/.local/bin/{codex,coderabbit,jq}, its receipt under ~/.local/state/dotfiles,
# and whatever `claude plugin` writes under ~/.claude.
#
# A binary in ~/.local/bin it did not install is left alone, and so is a tool
# that is already on PATH somewhere else. Linux only.
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
RECEIPT="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/lane-worker-tools"
ORIGINAL_PATH="$PATH"

# shellcheck source=libexec/lib/artifacts.sh
source "$REPO_ROOT/libexec/lib/artifacts.sh"
# shellcheck source=libexec/lib/tool-path.sh
source "$REPO_ROOT/libexec/lib/tool-path.sh"
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
    CODEX_ASSET=codex-x86_64-unknown-linux-musl
    CODEX_SHA256=$CODEX_LINUX_X86_64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-x64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_X64_SHA256
    JQ_ASSET=jq-linux-amd64
    JQ_SHA256=$JQ_LINUX_AMD64_SHA256
    ;;
  aarch64 | arm64)
    CODEX_ASSET=codex-aarch64-unknown-linux-musl
    CODEX_SHA256=$CODEX_LINUX_AARCH64_SHA256
    CODERABBIT_ASSET=coderabbit-linux-arm64.zip
    CODERABBIT_SHA256=$CODERABBIT_LINUX_ARM64_SHA256
    JQ_ASSET=jq-linux-arm64
    JQ_SHA256=$JQ_LINUX_ARM64_SHA256
    ;;
  *) die "unsupported architecture: ${ARTIFACT_ARCH:-$(uname -m)}" ;;
esac

[[ "$MODE" == check ]] || mkdir -p "$BIN_DIR"
prepend_managed_tool_path

# What to do with one tool. Prints one word, then a path for the last two:
#   current   ~/.local/bin/<name> is the pinned build this script installed
#   install   nothing by that name anywhere on PATH
#   replace   ~/.local/bin/<name> is an older build this script installed
#   foreign   ~/.local/bin/<name> is not a build this script installed (it may
#             have self-updated); it stays
#   external  ~/.local/bin/<name> is absent and <name> is on PATH elsewhere
tool_state() {
  local name="$1" version="$2" target="$BIN_DIR/$1" found current recorded
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    if found=$(command -v "$name" 2>/dev/null); then
      echo "external $found"
    else
      echo install
    fi
    return
  fi
  current=$(sha256_file "$target" 2>/dev/null) || current=""
  recorded=""
  [[ ! -f "$RECEIPT" ]] || recorded=$(awk -v name="$name" '$1 == name { print $2, $3 }' "$RECEIPT")
  if [[ -n "$current" && "$recorded" == "$version $current" ]]; then
    echo current
  elif [[ -n "$current" && -n "$recorded" && "${recorded#* }" == "$current" ]]; then
    echo replace
  else
    echo "foreign $target"
  fi
}

record_receipt() {
  local name="$1" version="$2" digest
  digest=$(sha256_file "$BIN_DIR/$name")
  mkdir -p "$(dirname "$RECEIPT")"
  {
    [[ ! -f "$RECEIPT" ]] || awk -v name="$name" '$1 != name' "$RECEIPT"
    printf '%s %s %s\n' "$name" "$version" "$digest"
  } >"$RECEIPT.tmp"
  mv -f "$RECEIPT.tmp" "$RECEIPT"
}

WORK_DIR=""
cleanup() { [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

# Stage the binary next to its destination, then rename it into place.
publish_binary() {
  local source="$1" name="$2" staged
  staged=$(mktemp "$BIN_DIR/.$name.XXXXXX")
  cp -- "$source" "$staged"
  chmod 0755 "$staged"
  publish_staged_file "$staged" "$BIN_DIR/$name" || {
    rm -f -- "$staged"
    return 1
  }
}

install_jq() {
  download_verified_artifact "$JQ_RELEASE_BASE/$JQ_ASSET" "$JQ_SHA256" "$WORK_DIR/jq" 0755
  publish_binary "$WORK_DIR/jq" jq
}

install_codex() {
  download_verified_artifact "$CODEX_RELEASE_BASE/$CODEX_ASSET.tar.gz" "$CODEX_SHA256" "$WORK_DIR/codex.tar.gz"
  tar -xzf "$WORK_DIR/codex.tar.gz" -C "$WORK_DIR" "$CODEX_ASSET"
  publish_binary "$WORK_DIR/$CODEX_ASSET" codex
}

install_coderabbit() {
  download_verified_artifact "$CODERABBIT_RELEASE_BASE/$CODERABBIT_ASSET" "$CODERABBIT_SHA256" "$WORK_DIR/coderabbit.zip"
  # Workers often have no unzip; python3's zipfile reads the one member.
  python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive, open(sys.argv[2], "wb") as out:
    out.write(archive.read("coderabbit"))' "$WORK_DIR/coderabbit.zip" "$WORK_DIR/coderabbit"
  publish_binary "$WORK_DIR/coderabbit" coderabbit
}

# One tool: report in --check, act in --apply. jq is wanted only when missing,
# so a jq on PATH anywhere is enough; codex and coderabbit follow the same rule.
converge_tool() {
  local name="$1" version="$2" installer="$3" state
  state=$(tool_state "$name" "$version")
  case "$state" in
    current) say "$name $version is installed in $BIN_DIR." ;;
    external\ *) say "$name is already on PATH at ${state#external }; leaving it." ;;
    foreign\ *) say "${state#foreign } is not a build this script installed; leaving it. Move it aside and rerun to use the pinned $name $version." ;;
    install | replace)
      if [[ "$MODE" == check ]]; then
        say "[dry-run] Would ${state} $name $version in $BIN_DIR."
        return 0
      fi
      if [[ -z "$WORK_DIR" ]]; then
        WORK_DIR=$(mktemp -d)
      fi
      "$installer"
      record_receipt "$name" "$version"
      say "Installed $name $version in $BIN_DIR."
      ;;
  esac
}

# Fail before downloading anything when a tool the downloads need is missing.
missing=()
command -v claude >/dev/null 2>&1 || missing+=("claude (Claude Code, which a worker runs lanes with)")
for tool in curl tar python3; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
  if [[ "$MODE" == apply ]]; then
    die "missing: ${missing[*]}. Install them first; this script does not use sudo."
  fi
  say "[dry-run] Missing, so --apply would stop: ${missing[*]}"
fi

converge_tool jq "$JQ_VERSION" install_jq

if [[ "$MODE" == check ]]; then
  if command -v jq >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
    bash "$REPO_ROOT/ai/claude/install.sh" --check
  else
    say "[dry-run] Would install the pinned gambtho-skills plugin for Claude Code (needs claude and jq)."
  fi
else
  bash "$REPO_ROOT/ai/claude/install.sh"
fi

converge_tool codex "$CODEX_VERSION" install_codex
converge_tool coderabbit "$CODERABBIT_CLI_VERSION" install_coderabbit

if [[ ":$ORIGINAL_PATH:" != *":$BIN_DIR:"* ]]; then
  say "Note: $BIN_DIR is not on this shell's PATH. Lanes find claude there; this script does not change PATH."
fi

cat <<EOF

Sign in once per box, as the user the lanes run as (this script does neither):
  gh auth status                   GitHub CLI; lanes already need it
  codex login --device-auth        Codex for codex-review.sh (headless sign-in)
  coderabbit auth login            CodeRabbit for the local review round
Then start a new lane: running sessions load the plugin on their next start.
EOF
