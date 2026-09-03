#!/usr/bin/bash -p
# Prepare the pinned Pi Web UI runtime and durable worktree for service publication.

set -euo pipefail

ARCHIVE_PATH='/usr/bin:/bin'
ARCHIVE_MV='/usr/bin/mv'
if [[ "${1:-}" == --archive-pending ]]; then
  PATH=$ARCHIVE_PATH
  export PATH
  hash -r
fi
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
MODE=''
SOURCE_ROOT=''
SOURCE_COMMON_DIR=''
SOURCE_HEAD=''
WORKTREE_PREVIOUS_HEAD=ABSENT
INITIAL_WORKTREE_PREVIOUS_HEAD=ABSENT
WORKTREE_UPDATE_STARTED=0
MANAGED_PLAN_FILE_COUNT=0
MANAGED_PLAN_MAX_FILES=100
MANAGED_PLAN_MAX_FILE_SIZE=1048576
MANAGED_PLAN_MAX_TOTAL_SIZE=10485760
PI_LAUNCHER=''
PI_REAL_EXECUTABLE=''
STATE_ROOT="$HOME/.local/share/pi-webui"
RUNTIME_PARENT="$STATE_ROOT/runtimes"
CANDIDATE_RUNTIME="$RUNTIME_PARENT/candidate"
CURRENT_RUNTIME="$RUNTIME_PARENT/current"
PREVIOUS_RUNTIME="$RUNTIME_PARENT/previous"
TRANSACTION_DIR="$STATE_ROOT/transactions/pending"
APPLY_LOCK="$STATE_ROOT/transactions/apply.lock"
WORKTREE="$STATE_ROOT/worktrees/dotfiles"
SYSTEMD_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_DIR="$SYSTEMD_CONFIG_HOME/systemd/user"
UNIT_PATH="$UNIT_DIR/pi-webui.service"
UNIT_CANDIDATE="$STATE_ROOT/transactions/pi-webui.candidate.service"
BACKUP_ROOT="$STATE_ROOT/backups/previous"
FAILURE_ROOT="$STATE_ROOT/backups/failures"
UNIT_TEMPORARY=''
BACKUP_TEMPORARY=''
TRIAL_RUNTIME="$HOME/.local/share/pi-webui-runtime"
TRIAL_RUNTIME_BACKUP=''
TRIAL_RUNTIME_STAGED=0
ACCEPTED_TRIAL_UNIT_SHA256=c3ba39ea60e3b6e7be197f96d13091e61f1c02220ff1d17cb7489dc7a0e8dac4
SERVICE_TEMPLATE_SHA256=be71933031443393d963e293dd3d2820447eb0307b39c9c873fbabc251f83e32
LOCK_TOKEN=''
LOCK_ACQUIRED=0
LOCK_COMPROMISED=0
LOCK_INITIALIZATION_SIGNAL=''
CANDIDATE_CREATED=0
TRANSACTION_CREATED=0
TRANSACTION_READY=0
APPLY_COMPLETE=0
SERVICE_STARTED=0
RUNTIME_PROMOTED=0
PRIOR_RUNTIME_MOVED=0
UNIT_PROMOTED=0
PRIOR_UNIT_KIND=absent
PRIOR_RUNTIME_KIND=absent
PRIOR_HEALTH_WORKTREE=''
PRIOR_HEALTH_PI_LAUNCHER=''
PRIOR_ACTIVE=0
PRIOR_ENABLED=0
ARCHIVE_ID=''
ARCHIVE_TEMPORARY=''
ARCHIVE_DESTINATION=''
CANDIDATE_OWNER_TOKEN=''
TRANSACTION_OWNER_TOKEN=''
ARCHIVE_TRAP_ACTIVE=0
ARCHIVE_TEMP_CREATED=0
ARCHIVE_FIRST_MOVED=0
ARCHIVE_SECOND_MOVED=0
ARCHIVE_THIRD_MOVED=0
ARCHIVE_UNIT_PRESENT=0
ARCHIVE_UNIT_SHA256=''
ARCHIVE_PUBLICATION_STARTED=0
ARCHIVE_PUBLISHED=0
ARCHIVE_DEVICE_ID=''

usage() {
  printf 'usage: %s --check|--apply|--archive-pending\n' "$0"
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
    *)
      fail 'test HOME must be below BATS_TEST_TMPDIR'
      return 1
      ;;
  esac
  case "$PI_WEBUI_TEST_OS_RELEASE" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      fail 'test os-release fixture must be below BATS_TEST_TMPDIR'
      return 1
      ;;
  esac
  [[ -f "$PI_WEBUI_TEST_OS_RELEASE" && ! -L "$PI_WEBUI_TEST_OS_RELEASE" ]] || {
    fail 'test os-release fixture must be a regular file'
    return 1
  }
  printf '%s\n' "$PI_WEBUI_TEST_OS_RELEASE"
}

require_platform_identity() {
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
}

require_supported_platform() {
  require_platform_identity
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
  for command_name in curl find git mise sha256sum ss systemd-analyze; do
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
  identity=$(
    mise exec -- node - "$PI_LAUNCHER" <<'NODE'
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

validate_systemd_path() {
  local value=$1 label=$2
  [[ "$value" == /* ]] || {
    fail "$label must be an absolute path"
    return 1
  }
  case "$value" in
    *'$'*)
      fail "$label contains a systemd expansion character (\$)"
      return 1
      ;;
    *%*)
      fail "$label contains a systemd specifier character (%)"
      return 1
      ;;
    *$'\n'* | *$'\r'*)
      fail "$label contains a newline"
      return 1
      ;;
    *'&'* | *'"'* | *\\*)
      fail "$label cannot be represented safely in the service unit"
      return 1
      ;;
  esac
  if LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'; then
    fail "$label contains an unsafe control character"
    return 1
  fi
}

quote_systemd_argument() {
  printf '"%s"' "$1"
}

render_unit() {
  local runtime_launcher=${1:-$CURRENT_RUNTIME/node_modules/.bin/pi-webui}
  local worktree=${2:-$WORKTREE}
  local pi_launcher=${3:-$PI_LAUNCHER}
  local template="$SOURCE_ROOT/ai/pi/webui/pi-webui.service.in"
  local rendered token count replacement
  [[ -f "$template" && ! -L "$template" ]] || {
    fail 'tracked Pi Web UI service template is missing or unsafe'
    return 1
  }
  validate_systemd_path "$runtime_launcher" 'runtime launcher path'
  validate_systemd_path "$worktree" 'durable worktree path'
  validate_systemd_path "$pi_launcher" 'Pi launcher path'
  rendered=$(cat "$template") || return 1
  for token in @RUNTIME_LAUNCHER@ @WORKTREE@ @PI_LAUNCHER@; do
    count=$(printf '%s' "$rendered" | grep -o "$token" | wc -l)
    [[ "$count" == 1 ]] || {
      fail "service template must contain exactly one $token token"
      return 1
    }
    case "$token" in
      @RUNTIME_LAUNCHER@) replacement=$(quote_systemd_argument "$runtime_launcher") ;;
      @WORKTREE@) replacement=$(quote_systemd_argument "$worktree") ;;
      @PI_LAUNCHER@) replacement=$(quote_systemd_argument "$pi_launcher") ;;
    esac
    rendered=${rendered//$token/$replacement}
  done
  if printf '%s\n' "$rendered" | grep -Eq '@[A-Z][A-Z0-9_]*@'; then
    fail 'service template contains unresolved tokens'
    return 1
  fi
  [[ "$(unit_sha256 "$template")" == "$SERVICE_TEMPLATE_SHA256" ]] || {
    fail "service template SHA-256 must be $SERVICE_TEMPLATE_SHA256"
    return 1
  }
  if printf '%s\n' "$rendered" | grep -Eq '^(KillMode|.*Funnel|.*network-open|.*update)'; then
    fail 'service template contains a prohibited service option'
    return 1
  fi
  printf '%s\n' "$rendered"
}

render_and_verify_candidate_unit() {
  [[ ! -e "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" ]] || {
    fail 'candidate service unit already exists'
    return 1
  }
  (
    umask 077
    render_unit >"$UNIT_CANDIDATE"
  )
  chmod 0600 "$UNIT_CANDIDATE"
  systemd-analyze --user verify "$UNIT_CANDIDATE"
}

unit_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

unit_matches_rendered() {
  cmp -s "$UNIT_PATH" <(render_unit)
}

expand_accepted_trial_path() {
  local encoded=$1 expanded
  case "$encoded" in
    %h/*) expanded="$HOME${encoded#%h}" ;;
    /*) expanded=$encoded ;;
    *) return 1 ;;
  esac
  validate_systemd_path "$expanded" 'accepted trial unit path' || return 1
  printf '%s\n' "$expanded"
}

derive_accepted_trial_health_identity() {
  local line prefix suffix encoded_worktree encoded_launcher
  prefix='ExecStart=/usr/bin/mise exec -- %h/.local/share/pi-webui-runtime/node_modules/.bin/pi-webui --host 127.0.0.1 --port 31415 --cwd '
  suffix=' --no-remote-auth --name pi-webui-smoke'
  [[ "$(grep -c '^ExecStart=' "$UNIT_PATH")" == 1 ]] || return 1
  line=$(grep '^ExecStart=' "$UNIT_PATH")
  case "$line" in
    "$prefix"*' --pi '*"$suffix") ;;
    *) return 1 ;;
  esac
  line=${line#"$prefix"}
  line=${line%"$suffix"}
  encoded_worktree=${line%% --pi *}
  encoded_launcher=${line#* --pi }
  [[ -n "$encoded_worktree" && -n "$encoded_launcher" &&
    "$encoded_worktree" != *[[:space:]]* &&
    "$encoded_launcher" != *[[:space:]]* ]] || return 1
  PRIOR_HEALTH_WORKTREE=$(expand_accepted_trial_path "$encoded_worktree") || return 1
  PRIOR_HEALTH_PI_LAUNCHER=$(expand_accepted_trial_path "$encoded_launcher") || return 1
}

preflight_service() {
  local unit_hash='' fragment_path=''
  if ! fragment_path=$(systemctl --user show --property=FragmentPath --value \
    pi-webui.service 2>/dev/null); then
    fail 'cannot inspect the loaded Pi Web UI service unit'
    return 1
  fi
  if [[ -n "$fragment_path" && "$fragment_path" != "$UNIT_PATH" ]]; then
    fail 'loaded Pi Web UI service unit is foreign'
    return 1
  fi
  if systemctl --user is-active --quiet pi-webui.service; then
    PRIOR_ACTIVE=1
  fi
  if systemctl --user is-enabled --quiet pi-webui.service; then
    PRIOR_ENABLED=1
  fi
  if [[ -e "$UNIT_PATH" || -L "$UNIT_PATH" ]]; then
    [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" &&
      "$(stat -c '%u' "$UNIT_PATH")" == "$(id -u)" &&
      "$(stat -c '%a' "$UNIT_PATH")" == 600 ]] || {
      fail 'existing Pi Web UI unit is unsafe or foreign'
      return 1
    }
    unit_hash=$(unit_sha256 "$UNIT_PATH")
    if [[ "$unit_hash" == "$ACCEPTED_TRIAL_UNIT_SHA256" ]]; then
      PRIOR_UNIT_KIND=trial
      derive_accepted_trial_health_identity || {
        fail 'accepted trial unit shape is invalid'
        return 1
      }
    elif unit_matches_rendered; then
      PRIOR_UNIT_KIND=managed
      PRIOR_HEALTH_WORKTREE=$WORKTREE
      PRIOR_HEALTH_PI_LAUNCHER=$PI_LAUNCHER
    else
      fail 'existing Pi Web UI unit is foreign'
      return 1
    fi
  elif [[ "$PRIOR_ACTIVE" == 1 || "$PRIOR_ENABLED" == 1 ]]; then
    fail 'loaded Pi Web UI service has no recognized unit file'
    return 1
  fi

  if [[ -e "$CURRENT_RUNTIME" || -L "$CURRENT_RUNTIME" ]]; then
    [[ ! -L "$CURRENT_RUNTIME" && "$(stat -c '%a' "$CURRENT_RUNTIME")" == 700 ]] || {
      fail 'current runtime must be an owner-only real directory'
      return 1
    }
    require_owned_managed_directory "$CURRENT_RUNTIME" 'current runtime' \
      .pi-webui-current pi-webui-task3-current-v1
    bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$CURRENT_RUNTIME" >/dev/null
    PRIOR_RUNTIME_KIND=managed
  elif [[ "$PRIOR_UNIT_KIND" == trial ]]; then
    [[ -d "$TRIAL_RUNTIME" && ! -L "$TRIAL_RUNTIME" &&
      "$(stat -c '%u' "$TRIAL_RUNTIME")" == "$(id -u)" &&
      "$(stat -c '%a' "$TRIAL_RUNTIME")" == 700 ]] || {
      fail 'accepted trial unit runtime is missing or unsafe'
      return 1
    }
    bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime "$TRIAL_RUNTIME" >/dev/null
    PRIOR_RUNTIME_KIND=trial
  fi
  if [[ "$PRIOR_UNIT_KIND" == managed && "$PRIOR_RUNTIME_KIND" != managed ]]; then
    fail 'managed Pi Web UI unit runtime is missing'
    return 1
  fi
  if [[ "$PRIOR_UNIT_KIND" == absent && "$PRIOR_RUNTIME_KIND" == managed ]]; then
    fail 'managed Pi Web UI runtime has no recognized unit'
    return 1
  fi
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

validate_managed_plan_tree() {
  local worktree=$1 label=$2 pi_root="$1/.pi" plans_root="$1/.pi/plans"
  local current_uid canonical_worktree canonical_pi canonical_plans entry
  local entry_parent mode links size total_size=0
  MANAGED_PLAN_FILE_COUNT=0
  [[ -e "$pi_root" || -L "$pi_root" ]] || return 0
  [[ -d "$pi_root" && ! -L "$pi_root" ]] || {
    fail "$label managed Pi plan tree must use real directories"
    return 1
  }
  current_uid=$(id -u)
  canonical_worktree=$(canonical_directory "$worktree") || return 1
  canonical_pi=$(canonical_directory "$pi_root") || return 1
  [[ "$canonical_pi" == "$canonical_worktree/.pi" ]] || {
    fail "$label managed Pi plan tree escapes the worktree"
    return 1
  }
  if [[ -e "$plans_root" || -L "$plans_root" ]]; then
    [[ -d "$plans_root" && ! -L "$plans_root" ]] || {
      fail "$label managed Pi plan tree must use real directories"
      return 1
    }
    canonical_plans=$(canonical_directory "$plans_root") || return 1
    [[ "$canonical_plans" == "$canonical_pi/plans" ]] || {
      fail "$label managed Pi plan tree escapes the worktree"
      return 1
    }
  else
    canonical_plans="$canonical_pi/plans"
  fi
  for entry in "$pi_root" "$plans_root"; do
    [[ -e "$entry" ]] || continue
    [[ "$(stat -c '%u' "$entry")" == "$current_uid" ]] || {
      fail "$label managed Pi plan tree must be owned by the current user"
      return 1
    }
    mode=$(stat -c '%a' "$entry")
    (((8#$mode & 022) == 0)) || {
      fail "$label managed Pi plan tree must not be group or world writable"
      return 1
    }
  done
  while IFS= read -r -d '' entry; do
    if [[ "$entry" == "$plans_root" ]]; then
      continue
    fi
    case "$entry" in
      "$plans_root"/*) ;;
      *)
        fail "$label managed Pi plan tree contains an unsupported entry"
        return 1
        ;;
    esac
    [[ ! -L "$entry" && -f "$entry" ]] || {
      fail "$label managed Pi plan tree contains an unsupported entry"
      return 1
    }
    entry_parent=$(canonical_directory "$(dirname "$entry")") || return 1
    [[ "$entry_parent" == "$canonical_plans" ]] || {
      fail "$label managed Pi plan tree contains nested or escaping entries"
      return 1
    }
    [[ "$(stat -c '%u' "$entry")" == "$current_uid" ]] || {
      fail "$label managed Pi plan files must be owned by the current user"
      return 1
    }
    mode=$(stat -c '%a' "$entry")
    (((8#$mode & 022) == 0)) || {
      fail "$label managed Pi plan files must not be group or world writable"
      return 1
    }
    links=$(stat -c '%h' "$entry")
    [[ "$links" == 1 ]] || {
      fail "$label managed Pi plan files must not have additional hard links"
      return 1
    }
    size=$(stat -c '%s' "$entry")
    [[ "$size" =~ ^[0-9]+$ && "$size" -le "$MANAGED_PLAN_MAX_FILE_SIZE" ]] || {
      fail "$label managed Pi plan file exceeds the 1 MiB limit"
      return 1
    }
    MANAGED_PLAN_FILE_COUNT=$((MANAGED_PLAN_FILE_COUNT + 1))
    total_size=$((total_size + size))
    [[ "$MANAGED_PLAN_FILE_COUNT" -le "$MANAGED_PLAN_MAX_FILES" &&
      "$total_size" -le "$MANAGED_PLAN_MAX_TOTAL_SIZE" ]] || {
      fail "$label managed Pi plan tree exceeds 100 files or 10 MiB"
      return 1
    }
  done < <(find -P "$pi_root" -mindepth 1 -print0)
}

require_source_without_managed_pi_collision() {
  local collision
  collision=$(git -C "$SOURCE_ROOT" ls-tree "$SOURCE_HEAD" -- .pi)
  [[ -z "$collision" ]] || {
    fail 'target source commit tracks .pi; refusing managed plan collision'
    return 1
  }
}

preflight_worktree() {
  local target_common_raw target_common target_git_raw target_git status ignored_status line
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
    fail 'durable worktree must be clean, including untracked and ignored files'
    return 1
  }
  ignored_status=$(git -C "$WORKTREE" status --porcelain --untracked-files=all --ignored=matching)
  if [[ -n "$ignored_status" ]]; then
    while IFS= read -r line; do
      case "$line" in
        '!! .pi/' | '!! .pi/plans/' | '!! .pi/plans/'*) ;;
        *)
          fail 'durable worktree must be clean, including untracked and ignored files'
          return 1
          ;;
      esac
    done <<<"$ignored_status"
  fi
  validate_managed_plan_tree "$WORKTREE" 'durable worktree' || return 1
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
  require_safe_current_user_directory "$directory" "$label" || return 1
  [[ -e "$directory" ]] || return 0
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

require_current_user_directory() {
  local directory=$1 label=$2
  require_existing_directory "$directory" "$label" || return 1
  [[ ! -e "$directory" || "$(stat -c '%u' "$directory")" == "$(id -u)" ]] || {
    fail "$label must be owned by the current user"
    return 1
  }
}

require_safe_current_user_directory() {
  local directory=$1 label=$2 mode
  require_current_user_directory "$directory" "$label" || return 1
  [[ -e "$directory" ]] || return 0
  mode=$(stat -c '%a' "$directory")
  (((8#$mode & 022) == 0)) || {
    fail "$label must not be group or world writable"
    return 1
  }
}

require_owned_directory_tree() {
  local root=$1 label=$2 entry
  require_safe_current_user_directory "$root" "$label" || return 1
  [[ -e "$root" ]] || return 0
  while IFS= read -r -d '' entry; do
    require_safe_current_user_directory "$entry" "$label descendant" || return 1
  done < <(find "$root" -type d -print0)
  while IFS= read -r -d '' entry; do
    if [[ -d "$entry" ]]; then
      fail "$label contains a symbolic-link directory"
      return 1
    fi
  done < <(find "$root" -type l -print0)
}

preflight_backup_paths() {
  local retained_trial="$BACKUP_ROOT/accepted-trial-runtime"
  require_owned_directory_tree "$STATE_ROOT/backups" \
    'Pi Web UI backup parent' || return 1
  if [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
    require_owned_managed_directory "$BACKUP_ROOT" 'previous service backup' \
      .pi-webui-backup pi-webui-task3-backup-v1 || return 1
  fi
  if [[ -e "$retained_trial" || -L "$retained_trial" ]]; then
    [[ -d "$retained_trial" && ! -L "$retained_trial" &&
      "$(stat -c '%u' "$retained_trial")" == "$(id -u)" &&
      "$(stat -c '%a' "$retained_trial")" == 700 ]] || {
      fail 'retained accepted trial runtime must be an owner-only real directory'
      return 1
    }
    bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime \
      "$retained_trial" >/dev/null || return 1
  fi
}

remove_previous_backup() {
  preflight_backup_paths || return 1
  [[ -e "$BACKUP_ROOT" ]] || return 0
  require_owned_managed_directory "$BACKUP_ROOT" 'previous service backup' \
    .pi-webui-backup pi-webui-task3-backup-v1 || return 1
  rm -rf "$BACKUP_ROOT"
}

preflight_apply_lock() {
  [[ -e "$APPLY_LOCK" || -L "$APPLY_LOCK" ]] || return 0
  [[ ! -L "$APPLY_LOCK" ]] || {
    fail 'apply lock must not be a symbolic link'
    return 1
  }
  [[ -d "$APPLY_LOCK" ]] || {
    fail 'apply lock collision must be a directory'
    return 1
  }
  if [[ "$(stat -c '%u' "$APPLY_LOCK")" != "$(id -u)" ||
  ! -f "$APPLY_LOCK/.pi-webui-lock" || -L "$APPLY_LOCK/.pi-webui-lock" ||
  ! -f "$APPLY_LOCK/.pi-webui-owner" || -L "$APPLY_LOCK/.pi-webui-owner" ||
  "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-lock")" != "$(id -u)" ||
  "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-owner")" != "$(id -u)" ||
  "$(cat "$APPLY_LOCK/.pi-webui-lock")" != pi-webui-task2-lock-v1 ||
  -z "$(cat "$APPLY_LOCK/.pi-webui-owner")" ]]; then
    fail 'apply lock collision is foreign or malformed'
    return 1
  fi
  fail 'apply lock is already held'
  return 1
}

preflight_archive_path_components() {
  require_current_user_directory "$HOME" 'HOME directory'
  require_current_user_directory "$HOME/.local" 'HOME .local directory'
  require_current_user_directory "$HOME/.local/share" 'HOME share directory'
  require_safe_current_user_directory "$STATE_ROOT" 'Pi Web UI state root'
  require_safe_current_user_directory "$RUNTIME_PARENT" 'Pi Web UI runtime parent'
  require_safe_current_user_directory "$STATE_ROOT/transactions" 'Pi Web UI transaction parent'
  require_safe_current_user_directory "$STATE_ROOT/backups" 'Pi Web UI backup parent'
  require_safe_current_user_directory "$FAILURE_ROOT" 'failure archive parent'
}

preflight_worktree_path_components() {
  require_current_user_directory "$HOME" 'HOME directory'
  require_current_user_directory "$HOME/.local" 'HOME .local directory'
  require_current_user_directory "$HOME/.local/share" 'HOME share directory'
  require_safe_current_user_directory "$STATE_ROOT" 'Pi Web UI state root'
  require_safe_current_user_directory "$STATE_ROOT/worktrees" 'Pi Web UI worktree parent'
}

preflight_handoff_state() {
  require_owned_managed_directory "$CANDIDATE_RUNTIME" 'stale candidate runtime' \
    .pi-webui-candidate pi-webui-task2-candidate-v1
  require_owned_managed_directory "$TRANSACTION_DIR" 'stale pending transaction' \
    .pi-webui-transaction pi-webui-task2-transaction-v1
  if [[ -e "$UNIT_CANDIDATE" || -L "$UNIT_CANDIDATE" ]]; then
    if [[ ! -e "$CANDIDATE_RUNTIME" || ! -e "$TRANSACTION_DIR" ]]; then
      fail 'candidate service unit has no recognized pending handoff'
      return 1
    fi
    validate_archive_evidence || return 1
  fi
  if [[ "$MODE" == apply && (-e "$TRANSACTION_DIR" || -L "$TRANSACTION_DIR") ]]; then
    fail 'pending transaction already exists; Task 3 must consume or discard it explicitly'
    return 1
  fi
}

preflight_unit_path_components() {
  require_safe_current_user_directory "$SYSTEMD_CONFIG_HOME" 'systemd configuration root'
  require_safe_current_user_directory "$SYSTEMD_CONFIG_HOME/systemd" 'systemd configuration directory'
  require_safe_current_user_directory "$UNIT_DIR" 'systemd user unit directory'
}

preflight_destinations() {
  preflight_worktree_path_components
  preflight_unit_path_components
  require_safe_current_user_directory "$RUNTIME_PARENT" 'Pi Web UI runtime parent'
  require_safe_current_user_directory "$STATE_ROOT/transactions" 'Pi Web UI transaction parent'
  preflight_backup_paths
  preflight_handoff_state
  preflight_apply_lock
}

print_interface() {
  printf 'PI_WEBUI_MODE=%s\n' "$MODE"
  printf 'PI_WEBUI_TRANSACTION=%s\n' "$TRANSACTION_DIR"
  printf 'PI_WEBUI_CANDIDATE_RUNTIME=%s\n' "$CANDIDATE_RUNTIME"
  printf 'PI_WEBUI_RUNTIME=%s\n' "$CURRENT_RUNTIME"
  printf 'PI_WEBUI_WORKTREE=%s\n' "$WORKTREE"
  printf 'PI_WEBUI_PI_LAUNCHER=%s\n' "$PI_LAUNCHER"
  printf 'PI_WEBUI_UNIT=%s\n' "$UNIT_PATH"
  if [[ "$MODE" == apply ]]; then
    if systemctl --user is-enabled --quiet pi-webui.service; then
      printf 'PI_WEBUI_SERVICE_ENABLED=1\n'
    else
      printf 'PI_WEBUI_SERVICE_ENABLED=0\n'
    fi
    if systemctl --user is-active --quiet pi-webui.service; then
      printf 'PI_WEBUI_SERVICE_ACTIVE=1\n'
    else
      printf 'PI_WEBUI_SERVICE_ACTIVE=0\n'
    fi
  fi
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
  mkdir -p "$RUNTIME_PARENT" "$STATE_ROOT/transactions" "$STATE_ROOT/worktrees" \
    "$STATE_ROOT/backups"
  chmod 0700 "$STATE_ROOT" "$RUNTIME_PARENT" "$STATE_ROOT/transactions" \
    "$STATE_ROOT/worktrees" "$STATE_ROOT/backups"
}

owned_by_this_apply() {
  local directory=$1
  [[ -d "$directory" && ! -L "$directory" &&
    "$(stat -c '%u' "$directory")" == "$(id -u)" &&
    -f "$directory/.pi-webui-owner" && ! -L "$directory/.pi-webui-owner" &&
    "$(stat -c '%u' "$directory/.pi-webui-owner")" == "$(id -u)" &&
    "$(cat "$directory/.pi-webui-owner")" == "$LOCK_TOKEN" ]]
}

defer_lock_initialization_signal() {
  [[ -n "$LOCK_INITIALIZATION_SIGNAL" ]] || LOCK_INITIALIZATION_SIGNAL=$1
}

restore_signal_handler() {
  local signal=$1 definition=$2
  if [[ -n "$definition" ]]; then
    eval "$definition"
  else
    trap - "$signal"
  fi
}

restore_lock_initialization_handlers() {
  local saved_hup=$1 saved_int=$2 saved_term=$3 pending=$LOCK_INITIALIZATION_SIGNAL
  restore_signal_handler HUP "$saved_hup"
  restore_signal_handler INT "$saved_int"
  restore_signal_handler TERM "$saved_term"
  LOCK_INITIALIZATION_SIGNAL=''
  if [[ -n "$pending" ]]; then
    kill -s "$pending" "$$"
  fi
}

partial_apply_lock_matches() {
  local stage=$1 entry
  local -a entries=()
  [[ -d "$APPLY_LOCK" && ! -L "$APPLY_LOCK" &&
    "$(stat -c '%u' "$APPLY_LOCK")" == "$(id -u)" &&
    "$(stat -c '%a' "$APPLY_LOCK")" == 700 ]] || return 1
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(find "$APPLY_LOCK" -mindepth 1 -maxdepth 1 -print0)
  case "$stage" in
    directory)
      [[ ${#entries[@]} -eq 0 ]]
      ;;
    owner)
      [[ ${#entries[@]} -eq 1 && "${entries[0]}" == "$APPLY_LOCK/.pi-webui-owner" &&
        -f "$APPLY_LOCK/.pi-webui-owner" && ! -L "$APPLY_LOCK/.pi-webui-owner" &&
        "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-owner")" == "$(id -u)" &&
        "$(stat -c '%a' "$APPLY_LOCK/.pi-webui-owner")" == 600 &&
        "$(cat "$APPLY_LOCK/.pi-webui-owner")" == "$LOCK_TOKEN" ]]
      ;;
    complete)
      [[ ${#entries[@]} -eq 2 &&
        -f "$APPLY_LOCK/.pi-webui-owner" && ! -L "$APPLY_LOCK/.pi-webui-owner" &&
        -f "$APPLY_LOCK/.pi-webui-lock" && ! -L "$APPLY_LOCK/.pi-webui-lock" &&
        "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-owner")" == "$(id -u)" &&
        "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-lock")" == "$(id -u)" &&
        "$(stat -c '%a' "$APPLY_LOCK/.pi-webui-owner")" == 600 &&
        "$(stat -c '%a' "$APPLY_LOCK/.pi-webui-lock")" == 600 &&
        "$(cat "$APPLY_LOCK/.pi-webui-owner")" == "$LOCK_TOKEN" &&
        "$(cat "$APPLY_LOCK/.pi-webui-lock")" == pi-webui-task2-lock-v1 ]]
      ;;
    *) return 1 ;;
  esac
}

cleanup_partial_apply_lock() {
  local stage=$1
  partial_apply_lock_matches "$stage" || {
    fail 'partial apply lock changed; refusing cleanup'
    return 1
  }
  case "$stage" in
    complete) rm "$APPLY_LOCK/.pi-webui-lock" "$APPLY_LOCK/.pi-webui-owner" ;;
    owner) rm "$APPLY_LOCK/.pi-webui-owner" ;;
  esac || {
    fail 'could not remove partial apply lock markers'
    return 1
  }
  rmdir "$APPLY_LOCK" || {
    fail 'could not remove partial apply lock directory'
    return 1
  }
}

acquire_apply_lock() {
  local saved_hup saved_int saved_term stage='' failure=''
  LOCK_TOKEN="pi-webui-task2:$$:$RANDOM"
  LOCK_INITIALIZATION_SIGNAL=''
  saved_hup=$(trap -p HUP)
  saved_int=$(trap -p INT)
  saved_term=$(trap -p TERM)
  trap 'defer_lock_initialization_signal HUP' HUP
  trap 'defer_lock_initialization_signal INT' INT
  trap 'defer_lock_initialization_signal TERM' TERM
  if ! mkdir -m 0700 "$APPLY_LOCK" 2>/dev/null; then
    restore_lock_initialization_handlers "$saved_hup" "$saved_int" "$saved_term"
    if preflight_apply_lock; then
      fail 'could not create the apply lock'
    fi
    return 1
  fi
  stage=directory
  if ! run_test_lock_after_mkdir_hook; then
    failure='lock after-mkdir lifecycle hook failed'
  elif ! (umask 077 && printf '%s\n' "$LOCK_TOKEN" >"$APPLY_LOCK/.pi-webui-owner"); then
    failure='could not create the apply lock owner marker'
  else
    stage=owner
    if ! run_test_lock_after_owner_hook; then
      failure='lock after-owner lifecycle hook failed'
    elif ! (umask 077 && printf '%s\n' pi-webui-task2-lock-v1 >"$APPLY_LOCK/.pi-webui-lock"); then
      failure='could not create the apply lock marker'
    else
      stage=complete
      if ! chmod 0600 "$APPLY_LOCK/.pi-webui-owner" "$APPLY_LOCK/.pi-webui-lock" ||
        ! partial_apply_lock_matches complete; then
        failure='could not verify the initialized apply lock'
      fi
    fi
  fi
  if [[ -n "$failure" ]]; then
    cleanup_partial_apply_lock "$stage" || true
    restore_lock_initialization_handlers "$saved_hup" "$saved_int" "$saved_term"
    fail "$failure" || true
    return 1
  fi
  LOCK_ACQUIRED=1
  restore_lock_initialization_handlers "$saved_hup" "$saved_int" "$saved_term"
}

release_apply_lock() {
  [[ "$LOCK_ACQUIRED" == 1 ]] || return 0
  if ! owned_by_this_apply "$APPLY_LOCK" ||
    [[ ! -f "$APPLY_LOCK/.pi-webui-lock" || -L "$APPLY_LOCK/.pi-webui-lock" ]] ||
    [[ "$(cat "$APPLY_LOCK/.pi-webui-lock")" != pi-webui-task2-lock-v1 ]]; then
    fail 'owned apply lock changed; refusing cleanup'
    return 1
  fi
  if ! rm "$APPLY_LOCK/.pi-webui-owner" "$APPLY_LOCK/.pi-webui-lock"; then
    fail 'could not remove owned apply lock markers'
    return 1
  fi
  if ! rmdir "$APPLY_LOCK"; then
    fail 'owned apply lock contains unexpected entries; refusing recursive cleanup'
    return 1
  fi
  LOCK_ACQUIRED=0
}

remove_stale_candidate() {
  preflight_handoff_state
  [[ -e "$CANDIDATE_RUNTIME" || -L "$CANDIDATE_RUNTIME" ]] || return 0
  rm -rf "$CANDIDATE_RUNTIME"
}

build_candidate_runtime() {
  remove_stale_candidate
  mkdir -m 0700 "$CANDIDATE_RUNTIME"
  printf '%s\n' "$LOCK_TOKEN" >"$CANDIDATE_RUNTIME/.pi-webui-owner"
  CANDIDATE_CREATED=1
  printf '%s\n' pi-webui-task2-candidate-v1 >"$CANDIDATE_RUNTIME/.pi-webui-candidate"
  chmod 0600 "$CANDIDATE_RUNTIME/.pi-webui-owner" "$CANDIDATE_RUNTIME/.pi-webui-candidate"
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

run_restricted_test_hook() {
  local variable=$1 hook=$2 description=$3
  [[ -n "$hook" ]] || return 0
  if [[ "${PI_WEBUI_TESTING:-0}" != 1 || -z "${BATS_TEST_TMPDIR:-}" ]]; then
    fail "$variable is restricted to the test sandbox"
    return 1
  fi
  case "$HOME/" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      fail 'test HOME must be below BATS_TEST_TMPDIR'
      return 1
      ;;
  esac
  case "$hook" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      fail "test $description hook must be below BATS_TEST_TMPDIR"
      return 1
      ;;
  esac
  [[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || {
    fail "test $description hook must be an executable regular file"
    return 1
  }
  "$hook"
}

run_test_before_lock_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_BEFORE_LOCK_HOOK \
    "${PI_WEBUI_TEST_BEFORE_LOCK_HOOK:-}" before-lock
}

run_test_lock_after_mkdir_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_LOCK_AFTER_MKDIR_HOOK \
    "${PI_WEBUI_TEST_LOCK_AFTER_MKDIR_HOOK:-}" lock-after-mkdir
}

run_test_lock_after_owner_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_LOCK_AFTER_OWNER_HOOK \
    "${PI_WEBUI_TEST_LOCK_AFTER_OWNER_HOOK:-}" lock-after-owner
}

run_test_after_npm_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_AFTER_NPM_HOOK \
    "${PI_WEBUI_TEST_AFTER_NPM_HOOK:-}" after-npm
}

run_test_before_trial_stage_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_BEFORE_TRIAL_STAGE_HOOK \
    "${PI_WEBUI_TEST_BEFORE_TRIAL_STAGE_HOOK:-}" before-trial-stage
}

run_test_archive_after_lock_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_AFTER_LOCK_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_AFTER_LOCK_HOOK:-}" archive-after-lock
}

run_test_archive_before_move_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_BEFORE_MOVE_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_BEFORE_MOVE_HOOK:-}" archive-before-move
}

run_test_archive_after_first_move_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_AFTER_FIRST_MOVE_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_AFTER_FIRST_MOVE_HOOK:-}" archive-after-first-move
}

run_test_archive_after_second_move_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_AFTER_SECOND_MOVE_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_AFTER_SECOND_MOVE_HOOK:-}" archive-after-second-move
}

run_test_archive_after_third_move_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_AFTER_THIRD_MOVE_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_AFTER_THIRD_MOVE_HOOK:-}" archive-after-third-move
}

run_test_archive_after_publication_hook() {
  run_restricted_test_hook PI_WEBUI_TEST_ARCHIVE_AFTER_PUBLICATION_HOOK \
    "${PI_WEBUI_TEST_ARCHIVE_AFTER_PUBLICATION_HOOK:-}" archive-after-publication
}

revalidate_worktree_before_mutation() {
  local observed_previous
  preflight_worktree_path_components
  preflight_worktree
  observed_previous=$WORKTREE_PREVIOUS_HEAD
  WORKTREE_PREVIOUS_HEAD=$INITIAL_WORKTREE_PREVIOUS_HEAD
  [[ "$observed_previous" == "$INITIAL_WORKTREE_PREVIOUS_HEAD" ]] || {
    fail 'durable worktree changed after initial preflight'
    return 1
  }
}

verify_worktree_at() {
  local expected=$1 saved_previous=$WORKTREE_PREVIOUS_HEAD observed
  preflight_worktree_path_components || return 1
  preflight_worktree || return 1
  observed=$WORKTREE_PREVIOUS_HEAD
  WORKTREE_PREVIOUS_HEAD=$saved_previous
  [[ "$observed" == "$expected" ]] || {
    fail "durable worktree HEAD is $observed; expected $expected"
    return 1
  }
}

update_worktree() {
  revalidate_worktree_before_mutation
  require_source_without_managed_pi_collision
  WORKTREE_UPDATE_STARTED=1
  if [[ "$WORKTREE_PREVIOUS_HEAD" == ABSENT ]]; then
    git -C "$SOURCE_ROOT" worktree add --detach "$WORKTREE" "$SOURCE_HEAD"
  else
    git -C "$WORKTREE" checkout --detach "$SOURCE_HEAD"
  fi
  verify_worktree_at "$SOURCE_HEAD"
}

write_metadata_file() {
  local name=$1 value=$2
  printf '%s\n' "$value" >"$TRANSACTION_DIR/$name"
  chmod 0600 "$TRANSACTION_DIR/$name"
}

verify_transaction_metadata_file() {
  local name=$1 expected=$2 path="$TRANSACTION_DIR/$1"
  [[ -f "$path" && ! -L "$path" &&
    "$(stat -c '%u' "$path")" == "$(id -u)" &&
    "$(stat -c '%a' "$path")" == 600 &&
    "$(cat "$path")" == "$expected" ]]
}

verify_apply_ownership() {
  if ! owned_by_this_apply "$APPLY_LOCK" ||
    ! owned_by_this_apply "$CANDIDATE_RUNTIME" ||
    ! owned_by_this_apply "$TRANSACTION_DIR"; then
    LOCK_COMPROMISED=1
    fail 'apply transaction ownership changed; retaining evidence'
    return 1
  fi
  [[ "$(stat -c '%a' "$APPLY_LOCK")" == 700 &&
  "$(stat -c '%a' "$CANDIDATE_RUNTIME")" == 700 &&
  "$(stat -c '%a' "$TRANSACTION_DIR")" == 700 &&
  -f "$APPLY_LOCK/.pi-webui-lock" && ! -L "$APPLY_LOCK/.pi-webui-lock" &&
  "$(cat "$APPLY_LOCK/.pi-webui-lock")" == pi-webui-task2-lock-v1 &&
  -f "$CANDIDATE_RUNTIME/.pi-webui-candidate" &&
  "$(cat "$CANDIDATE_RUNTIME/.pi-webui-candidate")" == pi-webui-task2-candidate-v1 ]] || {
    LOCK_COMPROMISED=1
    fail 'apply transaction markers changed; retaining evidence'
    return 1
  }
  if ! verify_transaction_metadata_file .pi-webui-transaction pi-webui-task2-transaction-v1 ||
    ! verify_transaction_metadata_file candidate-unit "$UNIT_CANDIDATE" ||
    ! verify_transaction_metadata_file source-head "$SOURCE_HEAD" ||
    ! verify_transaction_metadata_file source-root "$SOURCE_ROOT" ||
    ! verify_transaction_metadata_file source-common-dir "$SOURCE_COMMON_DIR" ||
    ! verify_transaction_metadata_file candidate-runtime "$CANDIDATE_RUNTIME" ||
    ! verify_transaction_metadata_file worktree "$WORKTREE" ||
    ! verify_transaction_metadata_file worktree-previous-head "$WORKTREE_PREVIOUS_HEAD" ||
    ! verify_transaction_metadata_file worktree-head "$SOURCE_HEAD" ||
    ! verify_transaction_metadata_file pi-launcher "$PI_LAUNCHER" ||
    ! verify_transaction_metadata_file pi-real-executable "$PI_REAL_EXECUTABLE"; then
    LOCK_COMPROMISED=1
    fail 'apply transaction metadata changed; retaining evidence'
    return 1
  fi
  if [[ -e "$UNIT_CANDIDATE" || -L "$UNIT_CANDIDATE" ]]; then
    verify_transaction_metadata_file candidate-unit-sha256 \
      "$(unit_sha256 "$UNIT_CANDIDATE")" || {
      LOCK_COMPROMISED=1
      fail 'apply candidate unit metadata changed; retaining evidence'
      return 1
    }
  elif [[ -e "$TRANSACTION_DIR/candidate-unit-sha256" ||
    -L "$TRANSACTION_DIR/candidate-unit-sha256" ]]; then
    LOCK_COMPROMISED=1
    fail 'apply candidate unit metadata is inconsistent; retaining evidence'
    return 1
  fi
}

write_transaction() {
  [[ ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || {
    fail 'pending transaction appeared after preflight'
    return 1
  }
  mkdir -m 0700 "$TRANSACTION_DIR"
  printf '%s\n' "$LOCK_TOKEN" >"$TRANSACTION_DIR/.pi-webui-owner"
  chmod 0600 "$TRANSACTION_DIR/.pi-webui-owner"
  TRANSACTION_CREATED=1
  write_metadata_file .pi-webui-transaction pi-webui-task2-transaction-v1
  write_metadata_file candidate-unit "$UNIT_CANDIDATE"
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

verify_absent_worktree_rollback() {
  [[ ! -e "$WORKTREE" && ! -L "$WORKTREE" ]] || return 1
  ! git -C "$SOURCE_ROOT" worktree list --porcelain | grep -Fqx "worktree $WORKTREE"
}

restore_worktree() {
  local rollback_target=$WORKTREE_PREVIOUS_HEAD
  preflight_worktree_path_components || return 1
  if [[ -e "$WORKTREE" || -L "$WORKTREE" ]]; then
    preflight_worktree || return 1
    WORKTREE_PREVIOUS_HEAD=$rollback_target
  fi
  if [[ "$rollback_target" == ABSENT ]]; then
    [[ "$MANAGED_PLAN_FILE_COUNT" == 0 ]] || {
      fail 'managed Pi plan files appeared; refusing automatic worktree removal'
      return 1
    }
    git -C "$SOURCE_ROOT" worktree remove "$WORKTREE" >/dev/null 2>&1 || true
    verify_absent_worktree_rollback || return 1
    return 0
  fi
  [[ -d "$WORKTREE" && ! -L "$WORKTREE" ]] || return 1
  git -C "$WORKTREE" checkout --detach "$rollback_target" >/dev/null 2>&1 || true
  verify_worktree_at "$rollback_target"
}

run_process_check() {
  local hook=${PI_WEBUI_TEST_PROCESS_CHECK:-}
  if [[ -n "$hook" ]]; then
    run_restricted_test_hook PI_WEBUI_TEST_PROCESS_CHECK "$hook" process-check
    return 0
  fi
  mise exec -- node - "$WORKTREE" "$HOME/.dotfiles/tmp/worktrees/piface-smoke" \
    "$PI_LAUNCHER" <<'NODE'
const fs = require('node:fs');
const [worktree, trialWorktree, launcher] = process.argv.slice(2);
const scopedCwds = new Set([worktree, trialWorktree]);
const self = new Set([process.pid, process.ppid]);
const offenders = [];
for (const name of fs.readdirSync('/proc')) {
  if (!/^\d+$/.test(name) || self.has(Number(name))) continue;
  try {
    const cwd = fs.readlinkSync(`/proc/${name}/cwd`);
    const cmd = fs.readFileSync(`/proc/${name}/cmdline`).toString().split('\0').filter(Boolean);
    const text = cmd.join(' ');
    const webui = /(?:^|\/)(?:pi-webui|pi-webui\.mjs)(?:\s|$)/.test(text) &&
      (scopedCwds.has(cwd) || text.includes('/pi-webui/runtimes/') || text.includes('/pi-webui-runtime/'));
    const supervisor = /rpc-supervisor/.test(text) && scopedCwds.has(cwd);
    const scopedPi = scopedCwds.has(cwd) &&
      (cmd[0] === launcher || /(?:^|\/)pi(?:\s|$)/.test(text));
    if (webui || supervisor || scopedPi) offenders.push(`${name}:${cwd}:${cmd[0] || ''}`);
  } catch (error) {
    if (!['ENOENT', 'EACCES'].includes(error.code)) throw error;
  }
}
if (offenders.length) {
  console.error(`managed Pi Web UI processes remain: ${offenders.join(', ')}`);
  process.exit(1);
}
NODE
}

verify_no_listener() {
  local output
  output=$(ss -H -ltn '( sport = :31415 )')
  [[ -z "$output" ]] || {
    fail 'port 31415 still has a listener'
    return 1
  }
  return 0
}

listener_process_root() {
  local process_root=${PI_WEBUI_TEST_PROC_ROOT:-/proc}
  if [[ "$process_root" != /proc ]]; then
    [[ "${PI_WEBUI_TESTING:-0}" == 1 && -n "${BATS_TEST_TMPDIR:-}" ]] || {
      fail 'PI_WEBUI_TEST_PROC_ROOT is restricted to the test sandbox'
      return 1
    }
    case "$process_root/" in
      "$BATS_TEST_TMPDIR"/*) ;;
      *)
        fail 'test proc root must be below BATS_TEST_TMPDIR'
        return 1
        ;;
    esac
  fi
  [[ -d "$process_root" && ! -L "$process_root" ]] || {
    fail 'listener process root must be a real directory'
    return 1
  }
  printf '%s\n' "$process_root"
}

verify_exact_listener() {
  local output process_root main_pid control_group status
  output=$(ss -H -ltnp '( sport = :31415 )')
  process_root=$(listener_process_root)
  systemctl --user is-active --quiet pi-webui.service || {
    fail 'Pi Web UI service is not active while verifying its listener'
    return 1
  }
  main_pid=$(systemctl --user show --property=MainPID --value pi-webui.service) || {
    fail 'cannot inspect the Pi Web UI service MainPID'
    return 1
  }
  control_group=$(systemctl --user show --property=ControlGroup --value \
    pi-webui.service) || {
    fail 'cannot inspect the Pi Web UI service control group'
    return 1
  }

  if mise exec -- node - "$process_root" "$main_pid" "$control_group" "$output" <<'NODE'; then
const fs = require('node:fs');
const path = require('node:path');
const [procRoot, mainPidText, controlGroup, input] = process.argv.slice(2);
const lines = input.split('\n').filter((line) => line.trim() !== '');
if (lines.length !== 1) process.exit(41);
const fields = lines[0].trim().split(/\s+/);
if (fields[0] !== 'LISTEN' || fields[3] !== '127.0.0.1:31415') process.exit(40);
const pids = [...new Set([...lines[0].matchAll(/(?:^|,)pid=(\d+)(?:,|\))/g)]
  .map((match) => Number(match[1])))];
const mainPid = Number(mainPidText);
if (pids.length !== 1 || !Number.isSafeInteger(mainPid) || mainPid <= 0) process.exit(42);

const snapshots = new Map();
function snapshot(pid) {
  const directory = path.join(procRoot, String(pid));
  const stat = fs.readFileSync(path.join(directory, 'stat'), 'utf8').trim();
  const close = stat.lastIndexOf(')');
  if (close < 0) throw new Error('malformed process stat');
  const statFields = stat.slice(close + 2).split(/\s+/);
  if (statFields.length < 20 || !/^\d+$/.test(statFields[19])) {
    throw new Error('malformed process start time');
  }
  const status = fs.readFileSync(path.join(directory, 'status'), 'utf8');
  const parent = status.match(/^PPid:\s*(\d+)$/m);
  if (!parent) throw new Error('missing process parent');
  const cgroups = fs.readFileSync(path.join(directory, 'cgroup'), 'utf8')
    .trim().split('\n').map((line) => line.split(':').slice(2).join(':'));
  const value = {pid, startTime: statFields[19], parent: Number(parent[1]), cgroups};
  snapshots.set(pid, value);
  return value;
}

try {
  const listenerPid = pids[0];
  const listener = snapshot(listenerPid);
  const cgroupOwned = controlGroup.startsWith('/') &&
    listener.cgroups.some((candidate) => candidate === controlGroup);
  let ancestryOwned = listenerPid === mainPid;
  if (!cgroupOwned && !ancestryOwned) {
    let current = listener.parent;
    const visited = new Set([listenerPid]);
    for (let depth = 1; depth < 256 && current > 0 && !visited.has(current); depth += 1) {
      visited.add(current);
      const process = snapshot(current);
      if (current === mainPid) {
        ancestryOwned = true;
        break;
      }
      current = process.parent;
    }
  }
  if (!ancestryOwned && !cgroupOwned) process.exit(42);
  for (const process of snapshots.values()) {
    const stat = fs.readFileSync(path.join(procRoot, String(process.pid), 'stat'), 'utf8').trim();
    const close = stat.lastIndexOf(')');
    const fieldsAfterName = close < 0 ? [] : stat.slice(close + 2).split(/\s+/);
    if (fieldsAfterName[19] !== process.startTime) process.exit(42);
  }
} catch (error) {
  process.exit(42);
}
NODE
    return 0
  else
    status=$?
  fi
  case "$status" in
    40) fail 'Pi Web UI listener is not confined to exact loopback' ;;
    41) fail 'expected exactly one Pi Web UI listener' ;;
    *) fail 'Pi Web UI listener is not owned by the active Pi Web UI service' ;;
  esac
  return 1
}

service_verification_attempts() {
  local max_attempts=20
  if [[ -n "${PI_WEBUI_TEST_HEALTH_ATTEMPTS:-}" ]]; then
    [[ "${PI_WEBUI_TESTING:-0}" == 1 && -n "${BATS_TEST_TMPDIR:-}" ]] || {
      fail 'PI_WEBUI_TEST_HEALTH_ATTEMPTS is restricted to the test sandbox'
      return 1
    }
    max_attempts=$PI_WEBUI_TEST_HEALTH_ATTEMPTS
    [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || {
      fail 'test health attempts must be a positive integer'
      return 1
    }
  fi
  printf '%s\n' "$max_attempts"
}

wait_for_service_active() {
  local attempt max_attempts
  max_attempts=$(service_verification_attempts)
  for attempt in $(seq 1 "$max_attempts"); do
    systemctl --user is-active --quiet pi-webui.service && return 0
    [[ "$attempt" == "$max_attempts" ]] || sleep 1
  done
  fail 'Pi Web UI service did not become active'
  return 1
}

verify_service_health() {
  local expected_worktree=${1:-$WORKTREE} expected_launcher=${2:-$PI_LAUNCHER}
  local attempt health status_json max_attempts
  max_attempts=$(service_verification_attempts)
  for attempt in $(seq 1 "$max_attempts"); do
    if health=$(curl --fail --silent --show-error \
      http://127.0.0.1:31415/api/health 2>/dev/null) &&
      printf '%s' "$health" | mise exec -- node -e '
let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
  const v=JSON.parse(s); if (v.ok!==true || v.webuiVersion!=="0.10.3" || v.piVersion!=="0.84.4") process.exit(1);
});'; then
      break
    fi
    [[ "$attempt" == "$max_attempts" ]] && {
      fail 'Pi Web UI exact health check failed'
      return 1
    }
    sleep 1
  done
  status_json=$(curl --fail --silent --show-error \
    'http://127.0.0.1:31415/api/webui-status?detailed=1&events=0')
  # shellcheck disable=SC2016 # JavaScript template literal, not shell expansion.
  printf '%s' "$status_json" | mise exec -- node -e '
const fs = require("node:fs");
const [worktree, launcher] = process.argv.slice(1);
const value = JSON.parse(fs.readFileSync(0, "utf8"));
const data = value.data;
if (value.ok !== true || data?.webuiVersion !== "0.10.3" || data?.piVersion !== "0.84.4") process.exit(1);
const network = data.network;
if (!network || network.host !== "127.0.0.1" || network.port !== 31415 || network.open !== false) process.exit(1);
if (Object.prototype.hasOwnProperty.call(network, "urls") ||
    !Array.isArray(network.networkUrls) || network.networkUrls.length !== 0) process.exit(1);
if (!Array.isArray(data.tabs) || data.tabs.length < 1) process.exit(1);
const rpcCommand = `${launcher} --mode rpc`;
for (const tab of data.tabs) {
  if (tab.cwd !== worktree || tab.running !== true) {
    console.error("Pi Web UI status tab does not match the expected cwd/running state");
    process.exit(1);
  }
  if (typeof tab.command !== "string" ||
      !(tab.command === rpcCommand ||
        (tab.command.startsWith(rpcCommand) && /\s/.test(tab.command[rpcCommand.length])))) {
    console.error("Pi Web UI status tab does not match the expected Pi launcher");
    process.exit(1);
  }
}
' "$expected_worktree" "$expected_launcher" || {
    fail 'Pi Web UI detailed status validation failed'
    return 1
  }
  verify_exact_listener
}

stop_service_cleanly() {
  systemctl --user stop pi-webui.service
  if systemctl --user is-active --quiet pi-webui.service; then
    fail 'Pi Web UI service remained active after stop'
    return 1
  fi
  verify_no_listener
  run_process_check
  return 0
}

validate_accepted_trial_runtime() {
  local runtime=$1
  [[ -d "$runtime" && ! -L "$runtime" &&
    "$(stat -c '%u' "$runtime")" == "$(id -u)" &&
    "$(stat -c '%a' "$runtime")" == 700 ]] || return 1
  bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime \
    "$runtime" >/dev/null
}

stage_trial_runtime() {
  local staged="$STATE_ROOT/backups/.accepted-trial-runtime.$$"
  [[ "$PRIOR_RUNTIME_KIND" == trial ]] || return 0
  [[ ! -e "$staged" && ! -L "$staged" ]] || {
    fail 'temporary accepted trial runtime backup already exists'
    return 1
  }
  run_test_before_trial_stage_hook
  mv "$TRIAL_RUNTIME" "$staged"
  TRIAL_RUNTIME_BACKUP=$staged
  TRIAL_RUNTIME_STAGED=1
}

restore_trial_runtime() {
  [[ "$PRIOR_RUNTIME_KIND" == trial ]] || return 0
  if [[ "$TRIAL_RUNTIME_STAGED" == 0 ]]; then
    validate_accepted_trial_runtime "$TRIAL_RUNTIME" || return 1
    return 0
  fi
  [[ -n "$TRIAL_RUNTIME_BACKUP" && ! -e "$TRIAL_RUNTIME" &&
    ! -L "$TRIAL_RUNTIME" ]] || return 1
  validate_accepted_trial_runtime "$TRIAL_RUNTIME_BACKUP" || return 1
  mv "$TRIAL_RUNTIME_BACKUP" "$TRIAL_RUNTIME"
  TRIAL_RUNTIME_BACKUP=''
  TRIAL_RUNTIME_STAGED=0
}

record_prior_service_state() {
  write_metadata_file prior-unit-kind "$PRIOR_UNIT_KIND"
  write_metadata_file prior-runtime-kind "$PRIOR_RUNTIME_KIND"
  write_metadata_file prior-active "$PRIOR_ACTIVE"
  write_metadata_file prior-enabled "$PRIOR_ENABLED"
  if [[ "$PRIOR_UNIT_KIND" != absent ]]; then
    write_metadata_file prior-health-worktree "$PRIOR_HEALTH_WORKTREE"
    write_metadata_file prior-health-pi-launcher "$PRIOR_HEALTH_PI_LAUNCHER"
    cp "$UNIT_PATH" "$TRANSACTION_DIR/prior-unit"
    chmod 0600 "$TRANSACTION_DIR/prior-unit"
  fi
}

promote_runtime_and_unit() {
  UNIT_TEMPORARY="$UNIT_PATH.new.$$"
  if [[ -e "$PREVIOUS_RUNTIME" || -L "$PREVIOUS_RUNTIME" ]]; then
    require_owned_managed_directory "$PREVIOUS_RUNTIME" 'previous runtime' \
      .pi-webui-current pi-webui-task3-current-v1
    rm -rf "$PREVIOUS_RUNTIME"
  fi
  if [[ "$PRIOR_RUNTIME_KIND" == managed ]]; then
    mv "$CURRENT_RUNTIME" "$PREVIOUS_RUNTIME"
    PRIOR_RUNTIME_MOVED=1
  elif [[ "$PRIOR_RUNTIME_KIND" == trial ]]; then
    stage_trial_runtime
  fi
  printf '%s\n' pi-webui-task3-current-v1 >"$CANDIDATE_RUNTIME/.pi-webui-current"
  chmod 0600 "$CANDIDATE_RUNTIME/.pi-webui-current"
  mv "$CANDIDATE_RUNTIME" "$CURRENT_RUNTIME"
  RUNTIME_PROMOTED=1
  mkdir -p "$UNIT_DIR"
  (
    umask 077
    cp "$UNIT_CANDIDATE" "$UNIT_TEMPORARY"
  )
  chmod 0600 "$UNIT_TEMPORARY"
  mv "$UNIT_TEMPORARY" "$UNIT_PATH"
  UNIT_TEMPORARY=''
  UNIT_PROMOTED=1
}

start_and_verify_service() {
  systemctl --user daemon-reload
  if [[ "$PRIOR_UNIT_KIND" == absent ]]; then
    systemctl --user enable --now pi-webui.service
  else
    if [[ "$PRIOR_ENABLED" == 1 ]]; then
      systemctl --user enable pi-webui.service
    else
      systemctl --user disable pi-webui.service >/dev/null 2>&1
    fi
    systemctl --user start pi-webui.service
  fi
  SERVICE_STARTED=1
  wait_for_service_active
  verify_service_health
  if [[ "$PRIOR_UNIT_KIND" != absent && "$PRIOR_ACTIVE" == 0 ]]; then
    stop_service_cleanly
    SERVICE_STARTED=0
  fi
}

retain_previous_backup() {
  local retained_trial="$BACKUP_ROOT/accepted-trial-runtime"
  BACKUP_TEMPORARY="$STATE_ROOT/backups/.previous.$$"
  mkdir -p "$STATE_ROOT/backups"
  chmod 0700 "$STATE_ROOT/backups"
  mkdir -m 0700 "$BACKUP_TEMPORARY"
  printf '%s\n' pi-webui-task3-backup-v1 >"$BACKUP_TEMPORARY/.pi-webui-backup"
  cp "$TRANSACTION_DIR"/prior-* "$BACKUP_TEMPORARY/"
  cp "$TRANSACTION_DIR/worktree-previous-head" "$TRANSACTION_DIR/worktree-head" \
    "$TRANSACTION_DIR/source-head" "$BACKUP_TEMPORARY/"
  find "$BACKUP_TEMPORARY" -maxdepth 1 -type f -exec chmod 0600 {} +
  if [[ -n "$TRIAL_RUNTIME_BACKUP" ]]; then
    mv "$TRIAL_RUNTIME_BACKUP" "$BACKUP_TEMPORARY/accepted-trial-runtime"
    TRIAL_RUNTIME_BACKUP="$BACKUP_TEMPORARY/accepted-trial-runtime"
  elif [[ -d "$retained_trial" && ! -L "$retained_trial" ]]; then
    mv "$retained_trial" "$BACKUP_TEMPORARY/accepted-trial-runtime"
    TRIAL_RUNTIME_BACKUP="$BACKUP_TEMPORARY/accepted-trial-runtime"
  fi
  if [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
    remove_previous_backup
  fi
  mv "$BACKUP_TEMPORARY" "$BACKUP_ROOT"
  BACKUP_TEMPORARY=''
  if [[ -n "$TRIAL_RUNTIME_BACKUP" ]]; then
    TRIAL_RUNTIME_BACKUP="$BACKUP_ROOT/accepted-trial-runtime"
  fi
}

complete_service_reconciliation() {
  preflight_backup_paths
  record_prior_service_state
  if [[ "$PRIOR_ACTIVE" == 1 ]]; then
    stop_service_cleanly
  else
    verify_no_listener
    run_process_check
  fi
  promote_runtime_and_unit
  start_and_verify_service
  retain_previous_backup
  rm -f "$UNIT_CANDIDATE"
  rm -rf "$TRANSACTION_DIR"
  TRANSACTION_CREATED=0
  CANDIDATE_CREATED=0
}

cleanup_apply_evidence() {
  local cleanup_failed=0
  if [[ -f "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" ]]; then
    rm -f "$UNIT_CANDIDATE" || cleanup_failed=1
  fi
  if [[ "$TRANSACTION_CREATED" == 1 ]]; then
    if owned_by_this_apply "$TRANSACTION_DIR"; then
      if rm -rf "$TRANSACTION_DIR"; then
        TRANSACTION_CREATED=0
      else
        fail 'could not remove the owned partial transaction'
        cleanup_failed=1
      fi
    else
      fail 'partial transaction ownership changed; refusing cleanup'
      cleanup_failed=1
    fi
  fi
  if [[ "$CANDIDATE_CREATED" == 1 ]]; then
    if owned_by_this_apply "$CANDIDATE_RUNTIME"; then
      if rm -rf "$CANDIDATE_RUNTIME"; then
        CANDIDATE_CREATED=0
      else
        fail 'could not remove the owned partial candidate'
        cleanup_failed=1
      fi
    else
      fail 'partial candidate ownership changed; refusing cleanup'
      cleanup_failed=1
    fi
  fi
  [[ "$cleanup_failed" == 0 ]]
}

verify_restored_prior_artifacts() {
  case "$PRIOR_UNIT_KIND" in
    absent)
      [[ ! -e "$UNIT_PATH" && ! -L "$UNIT_PATH" ]] || return 1
      ;;
    managed | trial)
      [[ -f "$UNIT_PATH" && ! -L "$UNIT_PATH" &&
        "$(stat -c '%u' "$UNIT_PATH")" == "$(id -u)" &&
        "$(stat -c '%a' "$UNIT_PATH")" == 600 ]] || return 1
      cmp -s "$TRANSACTION_DIR/prior-unit" "$UNIT_PATH" || return 1
      ;;
    *) return 1 ;;
  esac
  case "$PRIOR_RUNTIME_KIND" in
    absent) ;;
    managed)
      require_owned_managed_directory "$CURRENT_RUNTIME" 'restored current runtime' \
        .pi-webui-current pi-webui-task3-current-v1 || return 1
      bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime \
        "$CURRENT_RUNTIME" >/dev/null || return 1
      ;;
    trial)
      [[ -d "$TRIAL_RUNTIME" && ! -L "$TRIAL_RUNTIME" &&
        "$(stat -c '%u' "$TRIAL_RUNTIME")" == "$(id -u)" &&
        "$(stat -c '%a' "$TRIAL_RUNTIME")" == 700 ]] || return 1
      bash "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime \
        "$TRIAL_RUNTIME" >/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
}

verify_restored_service_state() {
  verify_restored_prior_artifacts || {
    fail 'restored Pi Web UI unit or runtime does not match the prior service'
    return 1
  }
  if [[ "$PRIOR_ENABLED" == 1 ]]; then
    systemctl --user is-enabled --quiet pi-webui.service || {
      fail 'Pi Web UI service enablement was not restored'
      return 1
    }
  elif systemctl --user is-enabled --quiet pi-webui.service; then
    fail 'Pi Web UI service disablement was not restored'
    return 1
  fi
  if [[ "$PRIOR_ACTIVE" == 1 ]]; then
    wait_for_service_active
    verify_service_health "$PRIOR_HEALTH_WORKTREE" "$PRIOR_HEALTH_PI_LAUNCHER"
  else
    if systemctl --user is-active --quiet pi-webui.service; then
      fail 'Pi Web UI service activity was not restored'
      return 1
    fi
    verify_no_listener
    run_process_check
  fi
}

rollback_service_reconciliation() {
  local failed=0
  if [[ "$SERVICE_STARTED" == 1 ]]; then
    stop_service_cleanly || failed=1
    SERVICE_STARTED=0
  fi
  if [[ "$UNIT_PROMOTED" == 1 ]]; then
    if [[ "$PRIOR_UNIT_KIND" == absent ]]; then
      rm -f "$UNIT_PATH" || failed=1
    else
      UNIT_TEMPORARY="$UNIT_PATH.rollback.$$"
      if ! (
        umask 077
        cp "$TRANSACTION_DIR/prior-unit" "$UNIT_TEMPORARY"
      ) ||
        ! chmod 0600 "$UNIT_TEMPORARY" || ! mv "$UNIT_TEMPORARY" "$UNIT_PATH"; then
        failed=1
      else
        UNIT_TEMPORARY=''
      fi
    fi
    UNIT_PROMOTED=0
  fi
  if [[ "$RUNTIME_PROMOTED" == 1 ]]; then
    if [[ -e "$CANDIDATE_RUNTIME" || -L "$CANDIDATE_RUNTIME" ]]; then
      failed=1
    elif ! mv "$CURRENT_RUNTIME" "$CANDIDATE_RUNTIME"; then
      failed=1
    elif [[ "$PRIOR_RUNTIME_MOVED" == 1 ]] &&
      ! mv "$PREVIOUS_RUNTIME" "$CURRENT_RUNTIME"; then
      failed=1
    fi
    RUNTIME_PROMOTED=0
    PRIOR_RUNTIME_MOVED=0
  elif [[ "$PRIOR_RUNTIME_MOVED" == 1 ]]; then
    mv "$PREVIOUS_RUNTIME" "$CURRENT_RUNTIME" || failed=1
    PRIOR_RUNTIME_MOVED=0
  fi
  if [[ "$PRIOR_RUNTIME_KIND" == trial ]] && ! restore_trial_runtime; then
    failed=1
  fi
  if [[ -n "$UNIT_TEMPORARY" && -f "$UNIT_TEMPORARY" && ! -L "$UNIT_TEMPORARY" ]]; then
    rm -f "$UNIT_TEMPORARY" || failed=1
    UNIT_TEMPORARY=''
  fi
  if [[ -n "$BACKUP_TEMPORARY" && -d "$BACKUP_TEMPORARY" &&
    ! -L "$BACKUP_TEMPORARY" ]]; then
    case "$TRIAL_RUNTIME_BACKUP/" in
      "$BACKUP_TEMPORARY"/*)
        fail 'temporary service backup retains the accepted trial runtime; refusing cleanup'
        failed=1
        ;;
      *)
        if require_owned_managed_directory "$BACKUP_TEMPORARY" 'temporary service backup' \
          .pi-webui-backup pi-webui-task3-backup-v1; then
          rm -rf "$BACKUP_TEMPORARY" || failed=1
          BACKUP_TEMPORARY=''
        else
          failed=1
        fi
        ;;
    esac
  fi
  if [[ "$WORKTREE_UPDATE_STARTED" == 1 ]] && ! restore_worktree; then
    failed=1
  fi
  if ! verify_restored_prior_artifacts; then
    fail 'restored Pi Web UI unit or runtime does not match the prior service'
    failed=1
  fi
  if [[ "$failed" == 0 ]]; then
    systemctl --user daemon-reload || failed=1
    if [[ "$PRIOR_ENABLED" == 1 ]]; then
      systemctl --user enable pi-webui.service || failed=1
    else
      systemctl --user disable pi-webui.service >/dev/null 2>&1 || failed=1
    fi
    if [[ "$PRIOR_ACTIVE" == 1 ]]; then
      systemctl --user start pi-webui.service || failed=1
    else
      systemctl --user stop pi-webui.service >/dev/null 2>&1 || failed=1
    fi
  fi
  if [[ "$failed" == 0 ]] && ! verify_restored_service_state; then
    failed=1
  fi
  [[ "$failed" == 0 ]]
}

rollback_failed_apply() {
  local status=$? rollback_failed=0 lock_cleanup_failed=0
  trap - EXIT
  if [[ "$APPLY_COMPLETE" != 1 ]]; then
    if [[ "$TRANSACTION_READY" == 1 ]]; then
      if ! rollback_service_reconciliation; then
        rollback_failed=1
        status=78
        printf '%s\n' 'error: service rollback failed; candidate and transaction evidence retained' >&2
      fi
    else
      if [[ "$LOCK_COMPROMISED" == 1 ]]; then
        : # Preserve candidate and transaction evidence when ownership is lost.
      else
        if [[ "$WORKTREE_UPDATE_STARTED" == 1 ]] && ! restore_worktree; then
          rollback_failed=1
          status=75
          printf '%s\n' 'error: worktree rollback failed; candidate and transaction evidence retained' >&2
        fi
        if [[ "$rollback_failed" != 1 ]] && ! cleanup_apply_evidence; then
          status=77
        fi
      fi
    fi
  fi
  if ! release_apply_lock; then
    lock_cleanup_failed=1
    [[ "$status" == 75 || "$status" == 78 ]] || status=76
  fi
  if [[ "$lock_cleanup_failed" == 1 && "$status" == 76 ]]; then
    printf '%s\n' 'error: apply lock cleanup failed; transaction evidence retained' >&2
  fi
  exit "$status"
}

read_archive_metadata() {
  local name=$1 path="$TRANSACTION_DIR/$1"
  [[ -f "$path" && ! -L "$path" &&
    "$(stat -c '%u' "$path")" == "$(id -u)" &&
    "$(stat -c '%a' "$path")" == 600 ]] || {
    fail "pending transaction metadata $name is unsafe or missing"
    return 1
  }
  cat "$path"
}

validate_archive_artifact_root() {
  local directory=$1 label=$2 marker=$3 expected_marker=$4 token_variable=$5 token
  require_owned_managed_directory "$directory" "$label" "$marker" "$expected_marker" || return 1
  [[ -e "$directory" && "$(stat -c '%a' "$directory")" == 700 ]] || {
    fail "$label must be owner-only"
    return 1
  }
  [[ -f "$directory/.pi-webui-owner" && ! -L "$directory/.pi-webui-owner" &&
    "$(stat -c '%u' "$directory/.pi-webui-owner")" == "$(id -u)" &&
    "$(stat -c '%a' "$directory/.pi-webui-owner")" == 600 &&
    "$(stat -c '%a' "$directory/$marker")" == 600 ]] || {
    fail "$label ownership metadata is unsafe or missing"
    return 1
  }
  token=$(cat "$directory/.pi-webui-owner")
  [[ ${#token} -le 80 && "$token" =~ ^pi-webui-task2:[1-9][0-9]*:[0-9]+$ ]] || {
    fail "$label ownership token is foreign or malformed"
    return 1
  }
  printf -v "$token_variable" '%s' "$token"
}

validate_archive_transaction() {
  local entry name source_head source_root source_common candidate_path worktree_path
  local worktree_head previous_head pi_launcher pi_real prior_unit_kind prior_runtime_kind
  local prior_active prior_enabled prior_present=0
  while IFS= read -r -d '' entry; do
    [[ -f "$entry" && ! -L "$entry" ]] || {
      fail 'pending transaction contains a non-regular entry'
      return 1
    }
    [[ "$(stat -c '%u' "$entry")" == "$(id -u)" &&
    "$(stat -c '%a' "$entry")" == 600 ]] || {
      fail 'pending transaction contains unsafe metadata'
      return 1
    }
    name=${entry##*/}
    case "$name" in
      .pi-webui-owner | .pi-webui-transaction | source-head | source-root | \
        source-common-dir | candidate-runtime | candidate-unit | candidate-unit-sha256 | \
        worktree | worktree-previous-head | worktree-head | pi-launcher | \
        pi-real-executable) ;;
      prior-unit-kind | prior-runtime-kind | prior-active | prior-enabled | \
        prior-health-worktree | prior-health-pi-launcher | prior-unit)
        prior_present=1
        ;;
      *)
        fail "pending transaction contains unrecognized metadata: $name"
        return 1
        ;;
    esac
  done < <(find "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -print0)

  source_head=$(read_archive_metadata source-head) || return 1
  source_root=$(read_archive_metadata source-root) || return 1
  source_common=$(read_archive_metadata source-common-dir) || return 1
  candidate_path=$(read_archive_metadata candidate-runtime) || return 1
  worktree_path=$(read_archive_metadata worktree) || return 1
  previous_head=$(read_archive_metadata worktree-previous-head) || return 1
  worktree_head=$(read_archive_metadata worktree-head) || return 1
  pi_launcher=$(read_archive_metadata pi-launcher) || return 1
  pi_real=$(read_archive_metadata pi-real-executable) || return 1

  [[ "$source_root" == "$SOURCE_ROOT" && "$source_common" == "$SOURCE_COMMON_DIR" &&
    "$candidate_path" == "$CANDIDATE_RUNTIME" && "$worktree_path" == "$WORKTREE" ]] || {
    fail 'pending transaction paths do not match this installer'
    return 1
  }
  [[ "$source_head" =~ ^[0-9a-f]{40}$ && "$worktree_head" == "$source_head" ]] || {
    fail 'pending transaction source commit is malformed'
    return 1
  }
  git -C "$SOURCE_ROOT" cat-file -e "$source_head^{commit}" 2>/dev/null || {
    fail 'pending transaction source commit is unavailable'
    return 1
  }
  if [[ "$previous_head" != ABSENT ]]; then
    [[ "$previous_head" =~ ^[0-9a-f]{40}$ ]] &&
      git -C "$SOURCE_ROOT" cat-file -e "$previous_head^{commit}" 2>/dev/null || {
      fail 'pending transaction previous worktree commit is malformed or unavailable'
      return 1
    }
  fi
  [[ "$pi_launcher" == /* && "$pi_real" == /* &&
    "$pi_launcher" != *$'\n'* && "$pi_real" != *$'\n'* ]] || {
    fail 'pending transaction Pi identity paths are malformed'
    return 1
  }

  validate_archive_candidate_unit "$worktree_path" "$pi_launcher" || return 1

  if [[ "$prior_present" == 1 ]]; then
    prior_unit_kind=$(read_archive_metadata prior-unit-kind) || return 1
    prior_runtime_kind=$(read_archive_metadata prior-runtime-kind) || return 1
    prior_active=$(read_archive_metadata prior-active) || return 1
    prior_enabled=$(read_archive_metadata prior-enabled) || return 1
    [[ "$prior_unit_kind" == absent || "$prior_unit_kind" == managed ||
      "$prior_unit_kind" == trial ]] || {
      fail 'pending transaction prior unit kind is malformed'
      return 1
    }
    [[ "$prior_runtime_kind" == absent || "$prior_runtime_kind" == managed ||
      "$prior_runtime_kind" == trial ]] || {
      fail 'pending transaction prior runtime kind is malformed'
      return 1
    }
    [[ "$prior_active" == 0 || "$prior_active" == 1 ]] &&
      [[ "$prior_enabled" == 0 || "$prior_enabled" == 1 ]] || {
      fail 'pending transaction prior service state is malformed'
      return 1
    }
    if [[ "$prior_unit_kind" == absent ]]; then
      [[ "$prior_runtime_kind" == absent && "$prior_active" == 0 &&
        "$prior_enabled" == 0 &&
        ! -e "$TRANSACTION_DIR/prior-unit" && ! -L "$TRANSACTION_DIR/prior-unit" &&
        ! -e "$TRANSACTION_DIR/prior-health-worktree" &&
        ! -L "$TRANSACTION_DIR/prior-health-worktree" &&
        ! -e "$TRANSACTION_DIR/prior-health-pi-launcher" &&
        ! -L "$TRANSACTION_DIR/prior-health-pi-launcher" ]] || {
        fail 'pending transaction absent prior service metadata is inconsistent'
        return 1
      }
    else
      [[ "$prior_runtime_kind" == "$prior_unit_kind" ]] || {
        fail 'pending transaction prior service/runtime kinds do not match'
        return 1
      }
      read_archive_metadata prior-unit >/dev/null || return 1
      [[ "$(read_archive_metadata prior-health-worktree)" == /* &&
      "$(read_archive_metadata prior-health-pi-launcher)" == /* ]] || {
        fail 'pending transaction prior health identity is malformed'
        return 1
      }
    fi
  fi
}

validate_archive_candidate_unit() {
  local worktree_path=$1 pi_launcher=$2 metadata_path='' expected_hash='' observed_hash
  local unit_present=0
  [[ -e "$UNIT_CANDIDATE" || -L "$UNIT_CANDIDATE" ]] && unit_present=1
  ARCHIVE_UNIT_PRESENT=$unit_present
  ARCHIVE_UNIT_SHA256=''

  if [[ -e "$TRANSACTION_DIR/candidate-unit" || -L "$TRANSACTION_DIR/candidate-unit" ]]; then
    metadata_path=$(read_archive_metadata candidate-unit) || return 1
    [[ "$metadata_path" == "$UNIT_CANDIDATE" ]] || {
      fail 'pending transaction candidate unit path does not match this installer'
      return 1
    }
  fi
  if [[ -e "$TRANSACTION_DIR/candidate-unit-sha256" ||
    -L "$TRANSACTION_DIR/candidate-unit-sha256" ]]; then
    [[ -n "$metadata_path" ]] || {
      fail 'pending transaction candidate unit hash has no path relationship'
      return 1
    }
    expected_hash=$(read_archive_metadata candidate-unit-sha256) || return 1
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || {
      fail 'pending transaction candidate unit hash is malformed'
      return 1
    }
  fi
  if [[ "$unit_present" == 0 ]]; then
    [[ -z "$expected_hash" ]] || {
      fail 'pending transaction candidate unit hash exists but the unit is absent'
      return 1
    }
    return 0
  fi
  [[ -f "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" &&
    "$(stat -c '%u' "$UNIT_CANDIDATE")" == "$(id -u)" &&
    "$(stat -c '%a' "$UNIT_CANDIDATE")" == 600 ]] || {
    fail 'candidate service unit must be an owner-only real file'
    return 1
  }
  observed_hash=$(unit_sha256 "$UNIT_CANDIDATE") || return 1
  ARCHIVE_UNIT_SHA256=$observed_hash
  [[ -z "$expected_hash" || "$observed_hash" == "$expected_hash" ]] || {
    fail 'candidate service unit hash does not match pending transaction metadata'
    return 1
  }
  cmp -s "$UNIT_CANDIDATE" <(render_unit \
    "$CURRENT_RUNTIME/node_modules/.bin/pi-webui" "$worktree_path" "$pi_launcher") || {
    fail 'candidate service unit does not match the expected rendered template'
    return 1
  }
}

verify_archive_lock() {
  owned_by_this_apply "$APPLY_LOCK" &&
    [[ "$(stat -c '%a' "$APPLY_LOCK")" == 700 &&
    "$(stat -c '%a' "$APPLY_LOCK/.pi-webui-owner")" == 600 &&
    -f "$APPLY_LOCK/.pi-webui-lock" && ! -L "$APPLY_LOCK/.pi-webui-lock" &&
    "$(stat -c '%u' "$APPLY_LOCK/.pi-webui-lock")" == "$(id -u)" &&
    "$(stat -c '%a' "$APPLY_LOCK/.pi-webui-lock")" == 600 &&
    "$(cat "$APPLY_LOCK/.pi-webui-lock")" == pi-webui-task2-lock-v1 ]] || {
    fail 'owned archive apply lock changed; refusing evidence moves'
    return 1
  }
}

validate_archive_evidence() {
  local candidate_present=0 transaction_present=0
  [[ -e "$CANDIDATE_RUNTIME" || -L "$CANDIDATE_RUNTIME" ]] && candidate_present=1
  [[ -e "$TRANSACTION_DIR" || -L "$TRANSACTION_DIR" ]] && transaction_present=1
  [[ "$candidate_present" == "$transaction_present" ]] || {
    fail 'candidate and pending transaction evidence must both be present'
    return 1
  }
  [[ "$candidate_present" == 1 ]] || return 0

  validate_archive_artifact_root "$CANDIDATE_RUNTIME" 'candidate runtime' \
    .pi-webui-candidate pi-webui-task2-candidate-v1 CANDIDATE_OWNER_TOKEN || return 1
  validate_archive_artifact_root "$TRANSACTION_DIR" 'pending transaction' \
    .pi-webui-transaction pi-webui-task2-transaction-v1 TRANSACTION_OWNER_TOKEN || return 1
  [[ "$CANDIDATE_OWNER_TOKEN" == "$TRANSACTION_OWNER_TOKEN" ]] || {
    fail 'candidate and pending transaction ownership tokens do not match'
    return 1
  }
  resolve_source_repository || return 1
  validate_archive_transaction || return 1
  /usr/bin/bash -p "$SOURCE_ROOT/bin/validate-pi-webui" --installed-runtime \
    "$CANDIDATE_RUNTIME" >/dev/null || {
    fail 'candidate runtime failed installed validation'
    return 1
  }
  ARCHIVE_ID=${CANDIDATE_OWNER_TOKEN//:/-}
  [[ ${#ARCHIVE_ID} -le 80 && "$ARCHIVE_ID" =~ ^pi-webui-task2-[1-9][0-9]*-[0-9]+$ ]] || {
    fail 'candidate archive identifier is malformed'
    return 1
  }
}

archive_path_matches_device() {
  local path=$1 label=$2 observed_device
  observed_device=$(stat -c '%d' "$path") || return 1
  [[ "$observed_device" == "$ARCHIVE_DEVICE_ID" ]] || {
    fail "$label must be on the same filesystem as the archive evidence"
    return 1
  }
}

archive_same_device() {
  ARCHIVE_DEVICE_ID=$(stat -c '%d' "$CANDIDATE_RUNTIME") || return 1
  archive_path_matches_device "$TRANSACTION_DIR" 'pending transaction' || return 1
  if [[ "$ARCHIVE_UNIT_PRESENT" == 1 ]]; then
    archive_path_matches_device "$UNIT_CANDIDATE" 'candidate service unit' || return 1
  fi
  archive_path_matches_device "$FAILURE_ROOT" 'failure archive root' || return 1
  if [[ "$ARCHIVE_TEMP_CREATED" == 1 ]]; then
    archive_path_matches_device "$ARCHIVE_TEMPORARY" 'temporary failure archive' || return 1
  fi
}

archive_remaining_paths_same_device() {
  archive_path_matches_device "$TRANSACTION_DIR" 'pending transaction' || return 1
  if [[ "$ARCHIVE_UNIT_PRESENT" == 1 ]]; then
    archive_path_matches_device "$UNIT_CANDIDATE" 'candidate service unit' || return 1
  fi
  archive_path_matches_device "$FAILURE_ROOT" 'failure archive root' || return 1
  archive_path_matches_device "$ARCHIVE_TEMPORARY" 'temporary failure archive' || return 1
}

published_archive_is_complete() {
  local expected_token=$CANDIDATE_OWNER_TOKEN archived_candidate_token archived_transaction_token
  [[ ! -e "$CANDIDATE_RUNTIME" && ! -L "$CANDIDATE_RUNTIME" &&
    ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" &&
    ! -e "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" ]] || return 1
  validate_archive_artifact_root "$ARCHIVE_DESTINATION/candidate" \
    'published candidate runtime' .pi-webui-candidate \
    pi-webui-task2-candidate-v1 archived_candidate_token || return 1
  validate_archive_artifact_root "$ARCHIVE_DESTINATION/pending" \
    'published pending transaction' .pi-webui-transaction \
    pi-webui-task2-transaction-v1 archived_transaction_token || return 1
  [[ "$archived_candidate_token" == "$expected_token" &&
    "$archived_transaction_token" == "$expected_token" ]] || return 1
  if [[ "$ARCHIVE_UNIT_PRESENT" == 1 ]]; then
    [[ -f "$ARCHIVE_DESTINATION/pi-webui.candidate.service" &&
      ! -L "$ARCHIVE_DESTINATION/pi-webui.candidate.service" &&
      "$(stat -c '%u' "$ARCHIVE_DESTINATION/pi-webui.candidate.service")" == "$(id -u)" &&
      "$(stat -c '%a' "$ARCHIVE_DESTINATION/pi-webui.candidate.service")" == 600 &&
      "$(unit_sha256 "$ARCHIVE_DESTINATION/pi-webui.candidate.service")" == "$ARCHIVE_UNIT_SHA256" ]]
  else
    [[ ! -e "$ARCHIVE_DESTINATION/pi-webui.candidate.service" &&
      ! -L "$ARCHIVE_DESTINATION/pi-webui.candidate.service" ]]
  fi
}

restore_archive_moves() {
  local failed=0
  [[ "$ARCHIVE_PUBLISHED" == 0 ]] || return 0
  if [[ "$ARCHIVE_PUBLICATION_STARTED" == 1 &&
    ! -e "$ARCHIVE_TEMPORARY" && ! -L "$ARCHIVE_TEMPORARY" ]] &&
    published_archive_is_complete >/dev/null 2>&1; then
    ARCHIVE_PUBLISHED=1
    return 0
  fi
  if [[ "$ARCHIVE_UNIT_PRESENT" == 1 && "$ARCHIVE_THIRD_MOVED" == 0 &&
    ! -e "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" &&
    -f "$ARCHIVE_TEMPORARY/pi-webui.candidate.service" &&
    ! -L "$ARCHIVE_TEMPORARY/pi-webui.candidate.service" &&
    "$(stat -c '%u' "$ARCHIVE_TEMPORARY/pi-webui.candidate.service")" == "$(id -u)" &&
    "$(stat -c '%a' "$ARCHIVE_TEMPORARY/pi-webui.candidate.service")" == 600 &&
    "$(unit_sha256 "$ARCHIVE_TEMPORARY/pi-webui.candidate.service")" == "$ARCHIVE_UNIT_SHA256" ]]; then
    ARCHIVE_THIRD_MOVED=1
  fi
  if [[ "$ARCHIVE_THIRD_MOVED" == 1 ]]; then
    if [[ ! -e "$UNIT_CANDIDATE" && ! -L "$UNIT_CANDIDATE" ]] &&
      "$ARCHIVE_MV" -T --no-copy "$ARCHIVE_TEMPORARY/pi-webui.candidate.service" \
        "$UNIT_CANDIDATE"; then
      ARCHIVE_THIRD_MOVED=0
    else
      failed=1
    fi
  fi
  if [[ "$ARCHIVE_SECOND_MOVED" == 1 ]]; then
    if [[ ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] &&
      "$ARCHIVE_MV" -T --no-copy "$ARCHIVE_TEMPORARY/pending" "$TRANSACTION_DIR"; then
      ARCHIVE_SECOND_MOVED=0
    else
      failed=1
    fi
  fi
  if [[ "$ARCHIVE_FIRST_MOVED" == 1 ]]; then
    if [[ ! -e "$CANDIDATE_RUNTIME" && ! -L "$CANDIDATE_RUNTIME" ]] &&
      "$ARCHIVE_MV" -T --no-copy "$ARCHIVE_TEMPORARY/candidate" "$CANDIDATE_RUNTIME"; then
      ARCHIVE_FIRST_MOVED=0
    else
      failed=1
    fi
  fi
  if [[ "$failed" == 0 && "$ARCHIVE_TEMP_CREATED" == 1 ]]; then
    if rmdir "$ARCHIVE_TEMPORARY"; then
      ARCHIVE_TEMP_CREATED=0
    else
      failed=1
    fi
  fi
  [[ "$failed" == 0 ]]
}

archive_disarm_traps() {
  trap - EXIT INT TERM HUP
  ARCHIVE_TRAP_ACTIVE=0
}

archive_exit_handler() {
  local status=$1 restore_failed=0 lock_failed=0 retained_location=$ARCHIVE_TEMPORARY
  trap - EXIT INT TERM HUP
  [[ "$ARCHIVE_TRAP_ACTIVE" == 1 ]] || exit "$status"
  ARCHIVE_TRAP_ACTIVE=0
  [[ "$LOCK_ACQUIRED" == 1 ]] || exit "$status"
  if [[ "$ARCHIVE_PUBLISHED" == 0 ]]; then
    if restore_archive_moves; then
      if [[ "$ARCHIVE_PUBLISHED" == 1 ]]; then
        printf '%s\n' 'error: completed archive publication retained after interruption' >&2
      else
        printf '%s\n' 'error: archive evidence restored after interruption or failure' >&2
      fi
    else
      restore_failed=1
      if [[ ! -e "$retained_location" && ! -L "$retained_location" &&
        (-e "$ARCHIVE_DESTINATION" || -L "$ARCHIVE_DESTINATION") ]]; then
        retained_location=$ARCHIVE_DESTINATION
      fi
      printf 'error: could not restore archived evidence; evidence retained in %s\n' \
        "$retained_location" >&2
    fi
  fi
  if ! release_apply_lock; then
    lock_failed=1
    printf '%s\n' 'error: archive apply lock changed; refusing cleanup' >&2
  fi
  if [[ "$status" == 0 ]]; then
    status=79
  fi
  if [[ "$restore_failed" == 1 || "$lock_failed" == 1 ]]; then
    status=79
  fi
  exit "$status"
}

archive_signal_handler() {
  local signal=$1 status=$2
  trap - "$signal"
  printf 'error: archive action interrupted by %s\n' "$signal" >&2
  exit "$status"
}

require_archive_mv_no_copy() {
  local help
  help=$(LC_ALL=C "$ARCHIVE_MV" --help 2>&1) || {
    fail 'could not inspect fixed mv no-copy support'
    return 1
  }
  [[ "$help" == *'--no-copy'* ]] || {
    fail 'mv --no-copy support is required for atomic evidence archival'
    return 1
  }
}

archive_arm_traps() {
  ARCHIVE_TRAP_ACTIVE=1
  trap 'archive_exit_handler $?' EXIT
  trap 'archive_signal_handler INT 130' INT
  trap 'archive_signal_handler TERM 143' TERM
  trap 'archive_signal_handler HUP 129' HUP
}

archive_evidence_under_lock() {
  local validated_archive_id
  preflight_archive_path_components || return 1
  verify_archive_lock || return 1
  validate_archive_evidence || return 1
  [[ -n "$ARCHIVE_ID" ]] || {
    fail 'pending archive evidence disappeared after lock acquisition'
    return 1
  }
  if [[ ! -e "$STATE_ROOT/backups" && ! -L "$STATE_ROOT/backups" ]]; then
    mkdir -m 0700 "$STATE_ROOT/backups" || {
      fail 'could not create Pi Web UI backup parent'
      return 1
    }
  fi
  require_safe_current_user_directory "$STATE_ROOT/backups" 'Pi Web UI backup parent' || return 1
  [[ "$(stat -c '%a' "$STATE_ROOT/backups")" == 700 ]] || {
    fail 'Pi Web UI backup parent must be owner-only'
    return 1
  }
  if [[ ! -e "$FAILURE_ROOT" && ! -L "$FAILURE_ROOT" ]]; then
    mkdir -m 0700 "$FAILURE_ROOT" || {
      fail 'could not create failure archive parent'
      return 1
    }
  fi
  require_safe_current_user_directory "$FAILURE_ROOT" 'failure archive parent' || return 1
  [[ "$(stat -c '%a' "$FAILURE_ROOT")" == 700 ]] || {
    fail 'failure archive parent must be owner-only'
    return 1
  }
  ARCHIVE_DESTINATION="$FAILURE_ROOT/$ARCHIVE_ID"
  ARCHIVE_TEMPORARY="$FAILURE_ROOT/.$ARCHIVE_ID.pending"
  [[ ! -e "$ARCHIVE_DESTINATION" && ! -L "$ARCHIVE_DESTINATION" ]] || {
    fail 'failure archive destination already exists'
    return 1
  }
  [[ ! -e "$ARCHIVE_TEMPORARY" && ! -L "$ARCHIVE_TEMPORARY" ]] || {
    fail 'temporary failure archive destination already exists'
    return 1
  }
  validated_archive_id=$ARCHIVE_ID
  verify_archive_lock || return 1
  validate_archive_evidence || return 1
  [[ "$ARCHIVE_ID" == "$validated_archive_id" ]] || {
    fail 'candidate archive identity changed before evidence moves'
    return 1
  }
  archive_same_device || return 1
  mkdir -m 0700 "$ARCHIVE_TEMPORARY" || {
    fail 'could not create temporary failure archive'
    return 1
  }
  ARCHIVE_TEMP_CREATED=1
  archive_same_device || return 1
  run_test_archive_before_move_hook || {
    fail 'archive before-move lifecycle hook failed'
    return 1
  }
  verify_archive_lock || return 1
  archive_same_device || return 1
  if ! "$ARCHIVE_MV" -T --no-copy "$CANDIDATE_RUNTIME" "$ARCHIVE_TEMPORARY/candidate"; then
    fail 'could not archive candidate runtime'
    return 1
  fi
  ARCHIVE_FIRST_MOVED=1
  run_test_archive_after_first_move_hook || {
    fail 'archive after-first-move lifecycle hook failed'
    return 1
  }
  verify_archive_lock || return 1
  archive_remaining_paths_same_device || return 1
  if ! "$ARCHIVE_MV" -T --no-copy "$TRANSACTION_DIR" "$ARCHIVE_TEMPORARY/pending"; then
    fail 'could not archive pending transaction'
    return 1
  fi
  ARCHIVE_SECOND_MOVED=1
  run_test_archive_after_second_move_hook || {
    fail 'archive after-second-move lifecycle hook failed'
    return 1
  }
  if [[ "$ARCHIVE_UNIT_PRESENT" == 1 ]]; then
    verify_archive_lock || return 1
    archive_path_matches_device "$UNIT_CANDIDATE" 'candidate service unit' || return 1
    archive_path_matches_device "$ARCHIVE_TEMPORARY" 'temporary failure archive' || return 1
    if ! "$ARCHIVE_MV" -T --no-copy "$UNIT_CANDIDATE" \
      "$ARCHIVE_TEMPORARY/pi-webui.candidate.service"; then
      fail 'could not archive candidate service unit'
      return 1
    fi
    ARCHIVE_THIRD_MOVED=1
    run_test_archive_after_third_move_hook || {
      fail 'archive after-third-move lifecycle hook failed'
      return 1
    }
  fi
  verify_archive_lock || return 1
  archive_path_matches_device "$FAILURE_ROOT" 'failure archive root' || return 1
  archive_path_matches_device "$ARCHIVE_TEMPORARY" 'temporary failure archive' || return 1
  ARCHIVE_PUBLICATION_STARTED=1
  if ! "$ARCHIVE_MV" -T --no-copy "$ARCHIVE_TEMPORARY" "$ARCHIVE_DESTINATION"; then
    fail 'could not publish failure archive'
    return 1
  fi
  run_test_archive_after_publication_hook || {
    fail 'archive after-publication lifecycle hook failed'
    return 1
  }
  ARCHIVE_PUBLISHED=1
  ARCHIVE_TEMP_CREATED=0
  printf 'archived: %s\n' "$ARCHIVE_DESTINATION"
}

archive_pending_evidence() {
  local candidate_present=0 transaction_present=0 unit_present=0 status=0
  preflight_archive_path_components || return 1
  preflight_apply_lock || return 1
  [[ -e "$CANDIDATE_RUNTIME" || -L "$CANDIDATE_RUNTIME" ]] && candidate_present=1
  [[ -e "$TRANSACTION_DIR" || -L "$TRANSACTION_DIR" ]] && transaction_present=1
  [[ -e "$UNIT_CANDIDATE" || -L "$UNIT_CANDIDATE" ]] && unit_present=1
  if [[ "$unit_present" == 1 &&
    ("$candidate_present" == 0 || "$transaction_present" == 0) ]]; then
    fail 'candidate service unit has no recognized pending handoff'
    return 1
  fi
  if [[ "$candidate_present" == 0 && "$transaction_present" == 0 ]]; then
    printf 'ready: no pending candidate/transaction evidence to archive\n'
    return 0
  fi
  [[ "$candidate_present" == "$transaction_present" ]] || {
    fail 'candidate and pending transaction evidence must both be present'
    return 1
  }
  require_archive_mv_no_copy || return 1
  archive_arm_traps
  if ! acquire_apply_lock; then
    archive_disarm_traps
    return 1
  fi
  run_test_archive_after_lock_hook || {
    fail 'archive after-lock lifecycle hook failed'
    return 1
  }
  archive_evidence_under_lock || return $?
  if ! release_apply_lock; then
    status=76
  fi
  archive_disarm_traps
  return "$status"
}

apply_installation() {
  trap rollback_failed_apply EXIT
  prepare_private_directories
  run_test_before_lock_hook
  acquire_apply_lock
  preflight_handoff_state
  build_candidate_runtime
  write_transaction
  run_test_after_npm_hook
  verify_apply_ownership
  revalidate_worktree_before_mutation
  update_worktree
  render_and_verify_candidate_unit
  write_metadata_file candidate-unit-sha256 "$(unit_sha256 "$UNIT_CANDIDATE")"
  verify_apply_ownership
  TRANSACTION_READY=1
  complete_service_reconciliation
  release_apply_lock
  APPLY_COMPLETE=1
  print_interface
  printf 'ready: Pi Web UI runtime and service reconciled\n'
  trap - EXIT
}

main() {
  [[ $# -eq 1 ]] || {
    usage >&2
    return 2
  }
  case "$1" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    --archive-pending) MODE=archive-pending ;;
    *)
      usage >&2
      return 2
      ;;
  esac
  if [[ "$MODE" == archive-pending ]]; then
    PATH=$ARCHIVE_PATH
    export PATH
    hash -r
    require_platform_identity
    archive_pending_evidence
    return
  fi
  require_supported_platform
  require_commands
  resolve_source_repository
  resolve_pi_identity
  validate_tracked_runtime
  require_source_without_managed_pi_collision
  preflight_destinations
  preflight_worktree
  preflight_service
  INITIAL_WORKTREE_PREVIOUS_HEAD=$WORKTREE_PREVIOUS_HEAD
  if [[ "$MODE" == check ]]; then
    check_plan
    return 0
  fi
  apply_installation
}

main "$@"
