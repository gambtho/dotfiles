#!/usr/bin/env bash
# Opt-in cluster tools for a lanes worker that builds images and runs kind
# clusters. Nothing else runs this; `make cluster-tools` does. It installs:
#   Docker Engine   Docker's apt repository; the user joins the docker group
#   runsc           gVisor's apt repository, registered as Docker runtime runsc
#   kind, kubectl   pinned, digest-checked binaries linked from ~/.local/bin
#   Go              pinned, digest-checked release, the same minor as mise's pin
#   Azure CLI       Microsoft's apt repository
# The apt repositories are the ones the work profile uses (libexec/lib/
# apt-repositories.sh), with their keys in /etc/apt/keyrings and signed-by.
# The binaries unpack under ~/.local/share/lane-worker like the review CLIs.
#
# Ubuntu or Debian, amd64 or arm64; anything else stops before any change.
# --check reads only. --apply uses sudo for apt, the docker group and
# /etc/docker/daemon.json, and changes nothing that is already in place.
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

say() { printf 'cluster-tools: %s\n' "$*"; }
die() {
  printf 'cluster-tools: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == Linux ]] || die "Linux only (Ubuntu or Debian); this is $(uname -s). Nothing was changed."

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BIN_DIR="$HOME/.local/bin"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/lane-worker"
# Where lanes look, as in install.sh. Tests replace the system part.
LANE_PATH="$BIN_DIR:${LANE_WORKER_SYSTEM_PATH:-/usr/local/bin:/usr/bin:/bin}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
DAEMON_JSON="${CLUSTER_TOOLS_DAEMON_JSON:-/etc/docker/daemon.json}"
RUNSC_PATH=/usr/bin/runsc
USER_NAME="${USER:-$(id -un)}"

DISTRO=$(
  # shellcheck source=/dev/null
  . "$OS_RELEASE_FILE" 2>/dev/null
  printf '%s' "${ID:-}"
)
case "$DISTRO" in
  ubuntu | debian) ;;
  *) die "Ubuntu or Debian only; this is ${DISTRO:-an unknown distribution}. Nothing was changed." ;;
esac
command -v dpkg >/dev/null 2>&1 || die "dpkg is missing, so this is not a Debian-family system. Nothing was changed."

# shellcheck source=libexec/lib/artifacts.sh
source "$REPO_ROOT/libexec/lib/artifacts.sh"
# shellcheck source=libexec/lib/apt.sh
source "$REPO_ROOT/libexec/lib/apt.sh"
# shellcheck source=libexec/lib/apt-repositories.sh
source "$REPO_ROOT/libexec/lib/apt-repositories.sh"
# shellcheck source=config/versions.env
source "$REPO_ROOT/config/versions.env"

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64)
    KIND_SHA256=$KIND_LINUX_AMD64_SHA256
    KUBECTL_SHA256=$KUBECTL_LINUX_AMD64_SHA256
    GO_SHA256=$GO_LINUX_AMD64_SHA256
    ;;
  arm64)
    KIND_SHA256=$KIND_LINUX_ARM64_SHA256
    KUBECTL_SHA256=$KUBECTL_LINUX_ARM64_SHA256
    GO_SHA256=$GO_LINUX_ARM64_SHA256
    ;;
  *) die "unsupported architecture: $ARCH. Nothing was changed." ;;
esac

STAGE=""
cleanup() { [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"; }
trap cleanup EXIT

# ── apt packages ─────────────────────────────────────────────────────────────

package_installed() {
  [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == *" ok installed" ]]
}

# listing_source HOST [FILE...]: the first of FILE (by default every APT source
# file) that names HOST on a line that is not a comment. grep exits 2 when one
# of the files is missing, so its status is not used.
listing_source() {
  local host="$1"
  shift
  (($#)) || set -- "$APT_ETC/sources.list" "$APT_ETC/sources.list.d/"*.list "$APT_ETC/sources.list.d/"*.sources
  { grep -lsE "^[[:space:]]*[^#[:space:]].*${host//./[.]}" "$@" || true; } | head -n 1
}

# Microsoft publishes the Azure CLI only for some releases (not Debian trixie,
# for one). Adding a source for another release would stop every apt update.
azure_cli_suite_served() {
  curl --fail --silent --head --location --connect-timeout 10 --max-time 30 --output /dev/null \
    "https://packages.microsoft.com/repos/azure-cli/dists/$(os_codename)/InRelease"
}

# One line per repository: label, its source file, the host another source
# file would name if it already lists the repository, its setup function, and
# its packages.
APT_COMPONENTS=(
  "Docker Engine|docker.list|download.docker.com|setup_docker_repository $DISTRO|docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  "gVisor runsc|gvisor.list|storage.googleapis.com/gvisor|setup_gvisor_repository|runsc"
  "Azure CLI|azure-cli.sources|packages.microsoft.com/repos/azure-cli|setup_azure_cli_repository|azure-cli"
)

converge_apt() {
  local line label file host setup packages package listed
  local -a missing=() wanted=() repositories=()
  for line in "${APT_COMPONENTS[@]}"; do
    IFS='|' read -r label file host setup packages <<<"$line"
    wanted=()
    for package in $packages; do
      package_installed "$package" || wanted+=("$package")
    done
    if ((${#wanted[@]} == 0)); then
      say "$label is installed."
      continue
    fi
    if [[ -n "$(listing_source "$host" "$APT_ETC/sources.list.d/$file")" ]]; then
      listed="its repository is listed"
    elif listed=$(listing_source "$host") && [[ -n "$listed" ]]; then
      # Another file already lists it. A second source with another key would
      # make apt refuse every source, so use that one.
      listed="its repository is already listed in $listed"
    elif [[ "$setup" == setup_azure_cli_repository ]] && ! azure_cli_suite_served; then
      say "Microsoft publishes no Azure CLI packages for $(os_codename); skipping the Azure CLI."
      continue
    else
      listed="adding its repository"
      repositories+=("$setup")
    fi
    missing+=("${wanted[@]}")
    if [[ "$MODE" == check ]]; then
      say "[dry-run] Would install $label (${wanted[*]}); $listed."
    else
      say "Installing $label (${wanted[*]}); $listed."
    fi
  done
  [[ "$MODE" == apply && ${#missing[@]} -gt 0 ]] || return 0
  sudo install -m 0755 -d "$APT_ETC/keyrings"
  # The repository keys are imported with gpg, which a minimal Debian lacks.
  if ((${#repositories[@]} > 0)) && ! command -v gpg >/dev/null 2>&1; then
    say "Installing gnupg from the distribution to import the repository keys."
    sudo_apt apt-get update >/dev/null
    sudo_apt apt-get install -y gnupg >/dev/null
  fi
  for setup in ${repositories[@]+"${repositories[@]}"}; do
    # shellcheck disable=SC2086  # "function argument" from the table above
    $setup
  done
  sudo_apt apt-get update >/dev/null
  sudo_apt apt-get install -y "${missing[@]}" >/dev/null
  say "Installed ${missing[*]}."
}

# ── docker group ─────────────────────────────────────────────────────────────

RELOGIN=false

converge_docker_group() {
  if [[ " $(id -nG "$USER_NAME") " == *" docker "* ]]; then
    if [[ " $(id -nG) " == *" docker "* ]]; then
      say "$USER_NAME is in the docker group."
    else
      say "$USER_NAME is in the docker group, but this session started before that."
      RELOGIN=true
    fi
  elif [[ "$MODE" == check ]]; then
    say "[dry-run] Would add $USER_NAME to the docker group (takes effect at the next login)."
  else
    sudo usermod -aG docker "$USER_NAME"
    say "Added $USER_NAME to the docker group."
    RELOGIN=true
  fi
}

# ── runsc as a Docker runtime ────────────────────────────────────────────────

# daemon_json check FILE      prints present, missing or invalid
# daemon_json merge FILE OUT  writes FILE plus runtimes.runsc to OUT; every
#                             other key stays as it was
daemon_json() {
  python3 -I - "$@" "$RUNSC_PATH" <<'PY'
import json, sys

mode, path = sys.argv[1], sys.argv[2]
runsc = sys.argv[-1]
try:
    with open(path) as source:
        text = source.read()
except FileNotFoundError:
    text = ""
try:
    data = json.loads(text) if text.strip() else {}
except ValueError:
    data = None
if not isinstance(data, dict) or not isinstance(data.get("runtimes", {}), dict):
    print("invalid")
    sys.exit(0 if mode == "check" else 1)
if mode == "check":
    print("present" if "runsc" in data.get("runtimes", {}) else "missing")
    sys.exit(0)
data.setdefault("runtimes", {})["runsc"] = {"path": runsc}
with open(sys.argv[3], "w") as out:
    json.dump(data, out, indent=2)
    out.write("\n")
PY
}

# Set while daemon.json has a runsc that Docker may not have loaded yet, so a
# run after a failed reload reloads again.
RELOAD_PENDING="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/cluster-tools-docker-reload"

# Docker rereads runtimes on reload, so running containers keep running.
reload_docker() {
  if systemctl is-active --quiet docker 2>/dev/null; then
    sudo systemctl reload docker ||
      die "runsc is in $DAEMON_JSON, but Docker did not reload. Rerun this, or run: sudo systemctl reload docker"
    say "Reloaded Docker."
  else
    say "Docker is not running; it reads the runtime when it starts."
  fi
  rm -f -- "$RELOAD_PENDING"
}

converge_runsc_runtime() {
  local state source="$DAEMON_JSON" temporary mode=0644 owner=0 group=0
  temporary=$(mktemp)
  # A daemon.json only root can read is read with sudo, and only by --apply.
  if [[ -e "$DAEMON_JSON" && ! -r "$DAEMON_JSON" ]]; then
    if [[ "$MODE" == check ]]; then
      rm -f -- "$temporary"
      say "[dry-run] Only root can read $DAEMON_JSON; --apply reads it with sudo and adds runsc if it is missing."
      return 0
    fi
    source="$temporary.current"
    # shellcheck disable=SC2024  # the copy is meant to be the user's own temporary file
    sudo cat -- "$DAEMON_JSON" >"$source"
  fi
  state=$(daemon_json check "$source")
  case "$state" in
    present)
      rm -f -- "$temporary" "$temporary.current"
      say "runsc is a Docker runtime in $DAEMON_JSON."
      if [[ -e "$RELOAD_PENDING" ]]; then
        if [[ "$MODE" == check ]]; then
          say "[dry-run] Would reload Docker, which a previous run did not finish."
        else
          reload_docker
        fi
      fi
      return 0
      ;;
    invalid)
      rm -f -- "$temporary" "$temporary.current"
      [[ "$MODE" == check ]] || die "$DAEMON_JSON is not a JSON object with a runtimes object, so runsc was not added. Fix it, then rerun."
      say "[dry-run] $DAEMON_JSON is not a JSON object with a runtimes object; --apply would stop here."
      return 0
      ;;
  esac
  if [[ "$MODE" == check ]]; then
    rm -f -- "$temporary"
    say "[dry-run] Would add runsc ($RUNSC_PATH) to the runtimes in $DAEMON_JSON, keeping its other settings."
    return 0
  fi
  daemon_json merge "$source" "$temporary" || {
    rm -f -- "$temporary" "$temporary.current"
    die "could not merge runsc into $DAEMON_JSON."
  }
  # Keep the owner and mode of an existing file; it may hold proxy credentials.
  if [[ -e "$DAEMON_JSON" ]]; then
    read -r mode owner group < <(stat -c '%a %u %g' "$DAEMON_JSON")
  fi
  mkdir -p "$(dirname "$RELOAD_PENDING")"
  touch "$RELOAD_PENDING"
  sudo install -D -m "$mode" -o "$owner" -g "$group" "$temporary" "$DAEMON_JSON"
  rm -f -- "$temporary" "$temporary.current"
  say "Added runsc to the runtimes in $DAEMON_JSON."
  reload_docker
}

# ── pinned binaries ──────────────────────────────────────────────────────────

# What to do with one link in ~/.local/bin, as install.sh decides it:
#   current, install, replace, foreign <path>, external <path>
link_state() {
  local name="$1" target_path="$2" link="$BIN_DIR/$1" target found
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    if found=$(PATH="$LANE_PATH" command -v "$name" 2>/dev/null); then
      echo "external $found"
    else
      echo install
    fi
    return
  fi
  target=$(readlink "$link" 2>/dev/null) || target=""
  if [[ "$target" == "$target_path" && -x "$target" ]]; then
    echo current
  elif [[ "$target" == "$SHARE_DIR/"* ]]; then
    echo replace
  else
    echo "foreign $link"
  fi
}

unpack_kind() {
  download_verified_artifact "$KIND_RELEASE_BASE/kind-linux-$ARCH" "$KIND_SHA256" "$1/kind" 0755
}

unpack_kubectl() {
  download_verified_artifact "$KUBECTL_RELEASE_BASE/$ARCH/kubectl" "$KUBECTL_SHA256" "$1/kubectl" 0755
}

unpack_go() {
  download_verified_artifact "$GO_RELEASE_BASE/go$GO_VERSION.linux-$ARCH.tar.gz" "$GO_SHA256" "$STAGE/go.tar.gz"
  tar -xzf "$STAGE/go.tar.gz" -C "$1"
}

# converge_binary TOOL VERSION LINK=PATH...: unpack TOOL into
# ~/.local/share/lane-worker/TOOL-VERSION and point each ~/.local/bin/LINK at
# PATH inside it. The first link decides whether lanes already have the tool.
converge_binary() {
  local tool="$1" version="$2" dir="$SHARE_DIR/$1-$2" pair state action=current
  shift 2
  for pair in "$@"; do
    state=$(link_state "${pair%%=*}" "$dir/${pair#*=}")
    case "$state" in
      current) ;;
      foreign\ *)
        say "${state#foreign } was not installed by this script; leaving $tool alone."
        return 0
        ;;
      external\ *)
        if [[ "$pair" == "$1" ]]; then
          say "$tool is already at ${state#external }; leaving it."
          return 0
        fi
        [[ "$action" == replace ]] || action=install
        ;;
      install) [[ "$action" == replace ]] || action=install ;;
      replace) action=replace ;;
    esac
  done
  if [[ "$action" == current ]]; then
    say "$tool $version is installed."
    return 0
  fi
  if [[ "$MODE" == check ]]; then
    say "[dry-run] Would $action $tool $version."
    return 0
  fi
  mkdir -p "$SHARE_DIR" "$BIN_DIR"
  STAGE=$(mktemp -d "$SHARE_DIR/.cluster-staging-XXXXXX")
  if [[ ! -x "$dir/${1#*=}" ]]; then
    mkdir "$STAGE/$tool"
    "unpack_$tool" "$STAGE/$tool"
    [[ -x "$STAGE/$tool/${1#*=}" ]] || die "$tool: ${1#*=} is missing from the download."
    # A folder for this version without its binary is broken; no lane uses it.
    [[ ! -d "$dir" ]] || publish_staged_file "$dir" "$STAGE/broken"
    publish_staged_file "$STAGE/$tool" "$dir"
  fi
  for pair in "$@"; do
    ln -s -- "$dir/${pair#*=}" "$STAGE/link"
    publish_staged_file "$STAGE/link" "$BIN_DIR/${pair%%=*}"
  done
  rm -rf -- "$STAGE"
  STAGE=""
  say "Installed $tool $version under $dir, linked from $BIN_DIR."
}

# ── main ─────────────────────────────────────────────────────────────────────

[[ "$MODE" == check ]] || say "Installing cluster tools for $DISTRO/$ARCH; sudo is used for apt, the docker group and $DAEMON_JSON."
converge_apt
converge_docker_group
converge_runsc_runtime
converge_binary kind "$KIND_VERSION" kind=kind
converge_binary kubectl "$KUBECTL_VERSION" kubectl=kubectl
converge_binary go "$GO_VERSION" go=go/bin/go gofmt=go/bin/gofmt

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  say "Note: $BIN_DIR is not on this shell's PATH. Lanes find kind, kubectl and go there; this script does not change PATH."
fi
if [[ "$RELOGIN" == true ]]; then
  cat <<EOF

The docker group takes effect only in sessions that start after this run. Log
out and back in, and restart anything lanes run under that outlives a
login (a lingering user service such as Herdr's), or reboot. Until then
docker needs sudo.
EOF
fi
if [[ "$MODE" == apply ]]; then
  cat <<'EOF'

Check after a new login:
  docker run --rm hello-world
  docker run --rm --runtime=runsc hello-world
  kind create cluster && kubectl get nodes && kind delete cluster
  az version
  go version
EOF
fi
