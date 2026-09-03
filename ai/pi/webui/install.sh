#!/usr/bin/env bash
# Prepare the pinned Pi Web UI runtime and durable worktree for service publication.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MODE=''
SOURCE_ROOT=''
SOURCE_COMMON_DIR=''
SOURCE_HEAD=''
WORKTREE_PREVIOUS_HEAD=ABSENT
WORKTREE_UPDATE_STARTED=0
PI_LAUNCHER=''
PI_REAL_EXECUTABLE=''
STATE_ROOT="$HOME/.local/share/pi-webui"
RUNTIME_PARENT="$STATE_ROOT/runtimes"
CANDIDATE_RUNTIME="$RUNTIME_PARENT/candidate"
TRANSACTION_DIR="$STATE_ROOT/transactions/pending"
WORKTREE="$STATE_ROOT/worktrees/dotfiles"

usage() {
  printf 'usage: %s --check|--apply\n' "$0"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  return 1
}

platform_release_file() {
  if [[ -z "${PI_WEBUI_TEST_OS_RELEASE:-}" ]]; then
    printf '%s\n' /etc/os-release
    return 0
  fi

  # The release-file seam exists only for Bats sandboxes. Requiring both HOME
  # and the fixture below BATS_TEST_TMPDIR prevents an accidental production
  # environment variable from bypassing the platform gate.
  if [[ "${PI_WEBUI_TESTING:-0}" != 1 || -z "${BATS_TEST_TMPDIR:-}" ]]; then
    fail 'PI_WEBUI_TEST_OS_RELEASE is restricted to the test sandbox'
    return 1
  fi
  case "$HOME/" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *) fail 'test HOME must be below BATS_TEST_TMPDIR'; return 1 ;;
  esac
  case "$PI_WEBUI_TEST_OS_RELEASE" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *) fail 'test os-release fixture must be below BATS_TEST_TMPDIR'; return 1 ;;
  esac
  [[ -f "$PI_WEBUI_TEST_OS_RELEASE" && ! -L "$PI_WEBUI_TEST_OS_RELEASE" ]] || {
    fail 'test os-release fixture must be a regular file'
    return 1
  }
  printf '%s\n' "$PI_WEBUI_TEST_OS_RELEASE"
}

require_supported_platform() {
  local release_file id='' version_id='' codename='' key value kernel
  release_file=$(platform_release_file)
  while IFS='=' read -r key value; do
    value=${value#\"}
    value=${value%\"}
    case "$key" in
      ID) id=$value ;;
      VERSION_ID) version_id=$value ;;
      VERSION_CODENAME) codename=$value ;;
    esac
  done <"$release_file"
  kernel=$(uname -r)
  if [[ "$id" != ubuntu || "$version_id" != 24.04 || "$codename" != noble ||
    "$kernel" != *[Mm]icrosoft* ]]; then
    fail 'Pi Web UI requires Ubuntu 24.04 Noble under WSL'
    return 1
  fi
  command -v systemctl >/dev/null 2>&1 || {
    fail 'systemd user manager is unavailable'
    return 1
  }
  systemctl --user show-environment >/dev/null 2>&1 || {
    fail 'systemd user manager is unavailable'
    return 1
  }
}

require_commands() {
  local command_name
  for command_name in git mise; do
    command -v "$command_name" >/dev/null 2>&1 || {
      fail "$command_name is required"
      return 1
    }
  done
  mise exec -- node --version >/dev/null 2>&1 || {
    fail 'Node.js must be available through mise'
    return 1
  }
  mise exec -- npm --version >/dev/null 2>&1 || {
    fail 'npm must be available through mise'
    return 1
  }
}

canonical_directory() {
  local directory=$1
  [[ -d "$directory" ]] || return 1
  (cd "$directory" && pwd -P)
}

resolve_source_repository() {
  local top common
  top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || {
    fail 'installer source is not in a Git repository'
    return 1
  }
  SOURCE_ROOT=$(canonical_directory "$top") || {
    fail 'cannot resolve canonical source repository'
    return 1
  }
  [[ "$SOURCE_ROOT" == "$ROOT" ]] || {
    fail "installer must run from the repository rooted at $ROOT"
    return 1
  }
  common=$(git -C "$SOURCE_ROOT" rev-parse --git-common-dir)
  case "$common" in
    /*) ;;
    *) common="$SOURCE_ROOT/$common" ;;
  esac
  SOURCE_COMMON_DIR=$(canonical_directory "$common") || {
    fail 'cannot resolve source Git common directory'
    return 1
  }
  SOURCE_HEAD=$(git -C "$SOURCE_ROOT" rev-parse --verify HEAD)
}

resolve_pi_identity() {
  local identity
  PI_LAUNCHER=$(mise which pi 2>/dev/null) || {
    fail 'Pi must be available through mise'
    return 1
  }
  [[ "$PI_LAUNCHER" == /* && -x "$PI_LAUNCHER" ]] || {
    fail 'mise returned an invalid Pi executable'
    return 1
  }
  identity=$(mise exec -- node - "$PI_LAUNCHER" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const launcher = process.argv[2];
const real = fs.realpathSync(launcher);
let current = path.dirname(real);
while (true) {
  const manifestPath = path.join(current, 'package.json');
  if (fs.existsSync(manifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    if (manifest.name === '@earendil-works/pi-coding-agent') {
      if (manifest.version !== '0.84.4') {
        throw new Error('Pi must be @earendil-works/pi-coding-agent@0.84.4');
      }
      if (typeof manifest.bin?.pi !== 'string' ||
          fs.realpathSync(path.resolve(current, manifest.bin.pi)) !== real) {
        throw new Error('Pi launcher does not belong to its declared package executable');
      }
      process.stdout.write(real);
      process.exit(0);
    }
  }
  const parent = path.dirname(current);
  if (parent === current) break;
  current = parent;
}
throw new Error('Pi must be @earendil-works/pi-coding-agent@0.84.4');
NODE
) || {
    fail 'Pi must be @earendil-works/pi-coding-agent@0.84.4'
    return 1
  }
  PI_REAL_EXECUTABLE=$identity
}

validate_tracked_runtime() {
  [[ -x "$SOURCE_ROOT/bin/validate-pi-webui" || -f "$SOURCE_ROOT/bin/validate-pi-webui" ]] || {
    fail 'tracked Pi Web UI validator is missing'
    return 1
  }
  bash "$SOURCE_ROOT/bin/validate-pi-webui" --tracked-only >/dev/null
}

canonical_git_path() {
  local worktree=$1 path_value=$2
  case "$path_value" in
    /*) ;;
    *) path_value="$worktree/$path_value" ;;
  esac
  if [[ -d "$path_value" ]]; then
    canonical_directory "$path_value"
  else
    local parent base
    parent=$(canonical_directory "$(dirname "$path_value")") || return 1
    base=$(basename "$path_value")
    printf '%s/%s\n' "$parent" "$base"
  fi
}

preflight_worktree() {
  local target_common_raw target_common target_git_raw target_git status
  [[ -e "$WORKTREE" || -L "$WORKTREE" ]] || {
    WORKTREE_PREVIOUS_HEAD=ABSENT
    return 0
  }
  [[ ! -L "$WORKTREE" ]] || {
    fail 'durable worktree must not be a symbolic link'
    return 1
  }
  [[ -d "$WORKTREE" ]] || {
    fail 'durable worktree must be a directory'
    return 1
  }
  [[ "$(stat -c '%u' "$WORKTREE")" == "$(id -u)" ]] || {
    fail 'durable worktree must be owned by the current user'
    return 1
  }
  git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    fail 'durable worktree belongs to a foreign repository'
    return 1
  }
  target_common_raw=$(git -C "$WORKTREE" rev-parse --git-common-dir)
  target_common=$(canonical_git_path "$WORKTREE" "$target_common_raw") || {
    fail 'cannot resolve durable worktree Git common directory'
    return 1
  }
  [[ "$target_common" == "$SOURCE_COMMON_DIR" ]] || {
    fail 'durable worktree belongs to a foreign repository'
    return 1
  }
  target_git_raw=$(git -C "$WORKTREE" rev-parse --git-dir)
  target_git=$(canonical_git_path "$WORKTREE" "$target_git_raw") || {
    fail 'cannot resolve durable worktree Git directory'
    return 1
  }
  [[ "$target_git" != "$target_common" ]] || {
    fail 'durable worktree must not be the primary checkout'
    return 1
  }
  if git -C "$WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'durable worktree must be detached'
    return 1
  fi
  status=$(git -C "$WORKTREE" status --porcelain --untracked-files=all)
  [[ -z "$status" ]] || {
    fail 'durable worktree must be clean, including untracked files'
    return 1
  }
  WORKTREE_PREVIOUS_HEAD=$(git -C "$WORKTREE" rev-parse --verify HEAD)
}

require_existing_directory() {
  local directory=$1 label=$2
  [[ -e "$directory" || -L "$directory" ]] || return 0
  [[ ! -L "$directory" && -d "$directory" ]] || {
    fail "$label must be a real directory"
    return 1
  }
}

require_owned_managed_directory() {
  local directory=$1 label=$2 marker=$3 expected_marker=$4
  require_existing_directory "$directory" "$label" || return 1
  [[ -e "$directory" ]] || return 0
  [[ "$(stat -c '%u' "$directory")" == "$(id -u)" ]] || {
    fail "$label must be owned by the current user"
    return 1
  }
  [[ -f "$directory/$marker" && ! -L "$directory/$marker" ]] || {
    fail "$label is not an owned Pi Web UI artifact"
    return 1
  }
  [[ "$(stat -c '%u' "$directory/$marker")" == "$(id -u)" &&
    "$(cat "$directory/$marker")" == "$expected_marker" ]] || {
    fail "$label is not an owned Pi Web UI artifact"
    return 1
  }
}

preflight_destinations() {
  require_existing_directory "$HOME/.local" 'HOME .local directory'
  require_existing_directory "$HOME/.local/share" 'HOME share directory'
  require_existing_directory "$STATE_ROOT" 'Pi Web UI state root'
  require_existing_directory "$RUNTIME_PARENT" 'Pi Web UI runtime parent'
  require_existing_directory "$STATE_ROOT/transactions" 'Pi Web UI transaction parent'
  require_existing_directory "$STATE_ROOT/worktrees" 'Pi Web UI worktree parent'
  if [[ -e "$STATE_ROOT" ]]; then
    [[ "$(stat -c '%u' "$STATE_ROOT")" == "$(id -u)" ]] || {
      fail 'Pi Web UI state root must be owned by the current user'
      return 1
    }
  fi
  require_owned_managed_directory "$CANDIDATE_RUNTIME" 'stale candidate runtime' \
    .pi-webui-candidate pi-webui-task2-candidate-v1
  require_owned_managed_directory "$TRANSACTION_DIR" 'stale pending transaction' \
    .pi-webui-transaction pi-webui-task2-transaction-v1
}

print_interface() {
  printf 'PI_WEBUI_MODE=%s\n' "$MODE"
  printf 'PI_WEBUI_TRANSACTION=%s\n' "$TRANSACTION_DIR"
  printf 'PI_WEBUI_CANDIDATE_RUNTIME=%s\n' "$CANDIDATE_RUNTIME"
  printf 'PI_WEBUI_WORKTREE=%s\n' "$WORKTREE"
  printf 'PI_WEBUI_PI_LAUNCHER=%s\n' "$PI_LAUNCHER"
}

check_plan() {
  print_interface
  if [[ -e "$WORKTREE" || -L "$WORKTREE" ]]; then
    printf 'check: would verify and update detached worktree to %s\n' "$SOURCE_HEAD"
  else
    printf 'check: would create detached worktree at %s\n' "$SOURCE_HEAD"
  fi
  printf 'check: would build and validate candidate runtime\n'
}

prepare_private_directories() {
  mkdir -p "$RUNTIME_PARENT" "$STATE_ROOT/transactions" "$STATE_ROOT/worktrees"
  chmod 0700 "$STATE_ROOT" "$RUNTIME_PARENT" "$STATE_ROOT/transactions" "$STATE_ROOT/worktrees"
}

build_candidate_runtime() {
  rm -rf "$CANDIDATE_RUNTIME"
  mkdir -m 0700 "$CANDIDATE_RUNTIME"
  printf '%s\n' pi-webui-task2-candidate-v1 >"$CANDIDATE_RUNTIME/.pi-webui-candidate"
  chmod 0600 "$CANDIDATE_RUNTIME/.pi-webui-candidate"
  cp "$SOURCE_ROOT/ai/pi/webui/runtime/package.json" "$CANDIDATE_RUNTIME/package.json"
  cp "$SOURCE_ROOT/ai/pi/webui/runtime/package-lock.json" "$CANDIDATE_RUNTIME/package-lock.json"
  chmod 0600 "$CANDIDATE_RUNTIME/package.json" "$CANDIDATE_RUNTIME/package-lock.json"
  mise exec -- npm ci --prefix "$CANDIDATE_RUNTIME" --ignore-scripts --omit=optional
  cmp -s "$SOURCE_ROOT/ai/pi/webui/runtime/package.json" "$CANDIDATE_RUNTIME/package.json" || {
    fail 'candidate manifest changed during npm ci'
    return 1
  }
  cmp -s "$SOURCE_ROOT/ai/pi/webui/runtime/package-lock.json" "$CANDIDATE_RUNTIME/package-lock.json" || {
    fail 'candidate lock changed during npm ci'
    return 1
  }
  bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$CANDIDATE_RUNTIME" >/dev/null
}

update_worktree() {
  WORKTREE_UPDATE_STARTED=1
  if [[ "$WORKTREE_PREVIOUS_HEAD" == ABSENT ]]; then
    git -C "$SOURCE_ROOT" worktree add --detach "$WORKTREE" "$SOURCE_HEAD"
  else
    git -C "$WORKTREE" checkout --detach "$SOURCE_HEAD"
  fi
  [[ "$(git -C "$WORKTREE" rev-parse --verify HEAD)" == "$SOURCE_HEAD" ]] || {
    fail 'durable worktree did not reach the source HEAD'
    return 1
  }
  ! git -C "$WORKTREE" symbolic-ref -q HEAD >/dev/null 2>&1 || {
    fail 'durable worktree became attached during update'
    return 1
  }
  [[ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]] || {
    fail 'durable worktree became dirty during update'
    return 1
  }
}

write_metadata_file() {
  local name=$1 value=$2
  printf '%s\n' "$value" >"$TRANSACTION_DIR/$name"
  chmod 0600 "$TRANSACTION_DIR/$name"
}

write_transaction() {
  rm -rf "$TRANSACTION_DIR"
  mkdir -m 0700 "$TRANSACTION_DIR"
  write_metadata_file .pi-webui-transaction pi-webui-task2-transaction-v1
  write_metadata_file source-head "$SOURCE_HEAD"
  write_metadata_file source-root "$SOURCE_ROOT"
  write_metadata_file source-common-dir "$SOURCE_COMMON_DIR"
  write_metadata_file candidate-runtime "$CANDIDATE_RUNTIME"
  write_metadata_file worktree "$WORKTREE"
  write_metadata_file worktree-previous-head "$WORKTREE_PREVIOUS_HEAD"
  write_metadata_file worktree-head "$SOURCE_HEAD"
  write_metadata_file pi-launcher "$PI_LAUNCHER"
  write_metadata_file pi-real-executable "$PI_REAL_EXECUTABLE"
}

rollback_failed_apply() {
  local status=$?
  trap - EXIT
  if [[ "${APPLY_COMPLETE:-0}" != 1 ]]; then
    if [[ "$WORKTREE_UPDATE_STARTED" == 1 ]]; then
      if [[ "$WORKTREE_PREVIOUS_HEAD" == ABSENT ]]; then
        git -C "$SOURCE_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
      elif [[ -d "$WORKTREE" && ! -L "$WORKTREE" ]]; then
        git -C "$WORKTREE" checkout --detach "$WORKTREE_PREVIOUS_HEAD" >/dev/null 2>&1 || true
      fi
    fi
    if [[ -d "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" &&
      -f "$TRANSACTION_DIR/.pi-webui-transaction" &&
      "$(cat "$TRANSACTION_DIR/.pi-webui-transaction" 2>/dev/null || true)" == pi-webui-task2-transaction-v1 ]]; then
      rm -rf "$TRANSACTION_DIR"
    fi
    if [[ -d "$CANDIDATE_RUNTIME" && ! -L "$CANDIDATE_RUNTIME" &&
      -f "$CANDIDATE_RUNTIME/.pi-webui-candidate" &&
      "$(cat "$CANDIDATE_RUNTIME/.pi-webui-candidate" 2>/dev/null || true)" == pi-webui-task2-candidate-v1 ]]; then
      rm -rf "$CANDIDATE_RUNTIME"
    fi
  fi
  exit "$status"
}

apply_installation() {
  APPLY_COMPLETE=0
  trap rollback_failed_apply EXIT
  prepare_private_directories
  rm -rf "$TRANSACTION_DIR"
  build_candidate_runtime
  update_worktree
  write_transaction
  APPLY_COMPLETE=1
  print_interface
  printf 'ready: Task 3 may validate and promote this transaction\n'
  trap - EXIT
}

main() {
  [[ $# -eq 1 ]] || { usage >&2; return 2; }
  case "$1" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    *) usage >&2; return 2 ;;
  esac
  require_supported_platform
  require_commands
  resolve_source_repository
  resolve_pi_identity
  validate_tracked_runtime
  preflight_destinations
  preflight_worktree
  if [[ "$MODE" == check ]]; then
    check_plan
    return 0
  fi
  apply_installation
}

main "$@"
