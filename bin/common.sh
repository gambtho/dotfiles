#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/log-helper"

COMMON_DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

PHASE_FAILURES=()
PHASE_WARNINGS=()
CURL_DOWNLOAD_ARGS=(
  --fail
  --show-error
  --location
  --connect-timeout 10
  --max-time 120
  --retry 3
)

run_phase() {
  local requirement="$1"
  local name="$2"
  shift 2

  log_info "Starting phase: $name"
  if "$@"; then
    log_success "Completed phase: $name"
    return 0
  fi

  if [[ "$requirement" == required ]]; then
    PHASE_FAILURES+=("$name")
    printf 'Required phase failed: %s\n' "$name" >&2
  else
    PHASE_WARNINGS+=("$name")
    log_warning "Optional phase failed: $name"
  fi
  return 0
}

finish_phases() {
  local name
  for name in "${PHASE_WARNINGS[@]}"; do
    printf 'WARNING: %s\n' "$name"
  done
  for name in "${PHASE_FAILURES[@]}"; do
    printf 'FAILED: %s\n' "$name" >&2
  done
  ((${#PHASE_FAILURES[@]} == 0))
}

next_backup_path() {
  local destination="$1"
  local candidate="${destination}.backup"
  local timestamp suffix=0

  if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  # Callers may invoke this from a function used as an `if`/`!` condition, which
  # suspends errexit for the whole call chain. Check explicitly so a date
  # failure surfaces here instead of yielding a path with an empty timestamp.
  timestamp=$(date -u +%Y%m%dT%H%M%SZ) || return 1
  candidate="${destination}.backup.${timestamp}"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="${destination}.backup.${timestamp}.${suffix}"
  done
  printf '%s\n' "$candidate"
}

# Emit every dotfile that this repo manages, as NUL-delimited (source,
# destination) pairs. Both fields are NUL-terminated rather than newline- or
# space-separated so paths containing whitespace survive the round trip; read
# them back with a paired `while IFS= read -r -d '' src && IFS= read -r -d '' dst`.
# Covers *.symlink files (mapped to ~/.<name>, minus the suffix) and each
# directory under config/ (mapped to ~/.config/<name>).
managed_link_pairs() {
  local dotfiles_root="$1"
  local home_root="$2"
  local src dst

  while IFS= read -r -d '' src; do
    dst="$home_root/.$(basename "${src%.*}")"
    printf '%s\0%s\0' "$src" "$dst"
  done < <(find -H "$dotfiles_root" \
    -not -path '*/archived/*' \
    -not -path '*/.git/*' \
    -not -path "$dotfiles_root/.claude/worktrees/*" \
    -name '*.symlink' -print0)

  if [[ -d "$dotfiles_root/config" ]]; then
    for src in "$dotfiles_root/config"/*/; do
      [[ -d "$src" ]] || continue
      src="${src%/}"
      dst="$home_root/.config/$(basename "$src")"
      printf '%s\0%s\0' "$src" "$dst"
    done
  fi
}

link_policy_for_action() {
  case "$1" in
    s) printf '%s\n' skip ;;
    S) printf '%s\n' skip-all ;;
    o) printf '%s\n' replace ;;
    O) printf '%s\n' replace-all ;;
    b) printf '%s\n' backup ;;
    B) printf '%s\n' backup-all ;;
    *) printf '%s\n' skip ;;
  esac
}

prompt_link_policy() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local action

  log_warning "$label already exists at $destination (source: $source)." >&2
  printf '%s' '[s]kip, [S]kip all, [o]verwrite, [O]verwrite all, [b]ackup, [B]ackup all? ' >&2
  IFS= read -r -n 1 action </dev/tty || action=s
  printf '\n' >&2
  link_policy_for_action "$action"
}

reconcile_link() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local policy="$4"
  local mode="$5"
  local backup moved_to="" keep_backup=false

  [[ "$policy" == skip || "$policy" == replace || "$policy" == backup ]] || return 2
  [[ "$mode" == apply || "$mode" == check ]] || return 2

  if [[ -L "$destination" && "$(readlink "$destination")" == "$source" ]]; then
    log_info "$label already linked."
    return 0
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    case "$policy" in
      skip)
        log_info "Skipped $label at $destination"
        return 0
        ;;
      replace)
        if [[ "$mode" == check ]]; then
          log_info "[dry-run] Would replace $label at $destination"
          return 0
        fi
        moved_to=$(next_backup_path "$destination")
        mv -- "$destination" "$moved_to" || return
        ;;
      backup)
        backup=$(next_backup_path "$destination")
        if [[ "$mode" == check ]]; then
          log_info "[dry-run] Would back up $label to $backup"
          return 0
        fi
        mv -- "$destination" "$backup" || return
        moved_to=$backup
        keep_backup=true
        ;;
    esac
  elif [[ "$mode" == check ]]; then
    log_info "[dry-run] Would link $source -> $destination"
    return 0
  fi

  if ! ln -s -- "$source" "$destination"; then
    if [[ -n "$moved_to" && ! -e "$destination" && ! -L "$destination" ]]; then
      mv -- "$moved_to" "$destination" || true
    fi
    return 1
  fi
  if [[ -n "$moved_to" && "$keep_backup" != true ]]; then
    rm -rf -- "$moved_to"
  fi
  log_success "Linked $source to $destination"
}

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
  mv -f -- "$temporary" "$destination"
}

install_pinned_mise() {
  local destination="$1"
  local arch="${ARTIFACT_ARCH:-$(uname -m)}"
  local asset digest
  # shellcheck source=config/versions.env
  source "$COMMON_DOTFILES_ROOT/config/versions.env"

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
  source "$COMMON_DOTFILES_ROOT/config/versions.env"

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

validate_vekil_access_token() {
  local access_token_file="$1"
  [[ -e "$access_token_file" || -L "$access_token_file" ]] || return 0
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be absent or a regular file: %s\n' "$access_token_file" >&2
    return 1
  }

  chmod 0600 "$access_token_file" || return 1
  [[ ! -L "$access_token_file" && -f "$access_token_file" ]] || {
    printf 'Vekil access token must be a regular file: %s\n' "$access_token_file" >&2
    return 1
  }
}

# Check if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Function to detect the operating system
detect_os() {
  case "$(uname)" in
    Darwin)
      OS="macOS"
      ;;
    Linux)
      if grep -qE "(Microsoft|WSL)" /proc/version &>/dev/null; then
        OS="WSL"
      elif [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" == "ubuntu" ]; then
          OS="Ubuntu"
        else
          #OS=$NAME
          OS="Unsupported"
        fi
      else
        OS="Unsupported"
        #OS="Linux"
      fi
      ;;
    *)
      OS="Unsupported"
      ;;
  esac
  export OS
  # echo "Detected OS: $OS"
}

# ── Stable link root ─────────────────────────────────────────────────────────
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
