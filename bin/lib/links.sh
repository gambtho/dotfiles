#!/usr/bin/env bash
# The managed-symlink contract: which files this repo links into $HOME, how
# conflicts are reconciled, and the shared loop bootstrap and relink walk.
# Sourced, never executed; must not change the caller's shell options.

source "$(dirname "${BASH_SOURCE[0]}")/../log-helper"

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

# Reconcile one managed pair under a caller-selected conflict mode:
#
#   interactive       bootstrap: prompt per conflict. The sticky "-all" answers
#                     live in the caller-scoped overwrite_all / backup_all /
#                     skip_all variables (skip_all doubles as the
#                     non-interactive switch).
#   replace-symlinks  relink: replace any existing symlink regardless of where
#                     it points, never touch a real file, never prompt.
#
# Destinations that remain unlinked afterwards are appended to the
# caller-declared SKIPPED_DESTINATIONS array; each caller owns how loudly to
# report them.
# shellcheck disable=SC2034  # the sticky answers live in the caller's scope
link_managed_file() {
  local src=$1 dst=$2 mode=$3
  local label policy
  label=$(basename "$src")

  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    # Already correct: not a conflict, so never consult the user. The policy
    # is irrelevant — reconcile_link short-circuits before applying it.
    policy=skip
  elif [[ "$mode" == replace-symlinks ]]; then
    policy=skip
    [[ -L "$dst" ]] && policy=replace
  elif [[ "${overwrite_all:-false}" == true ]]; then
    policy=replace
  elif [[ "${backup_all:-false}" == true ]]; then
    policy=backup
  elif [[ "${skip_all:-false}" == true ]]; then
    policy=skip
  elif [[ -e "$dst" || -L "$dst" ]]; then
    policy=$(prompt_link_policy "$src" "$dst" "$label")
    case "$policy" in
      replace-all)
        overwrite_all=true
        policy=replace
        ;;
      backup-all)
        backup_all=true
        policy=backup
        ;;
      skip-all)
        skip_all=true
        policy=skip
        ;;
    esac
  else
    policy=skip
  fi

  reconcile_link "$src" "$dst" "$label" "$policy" apply || return
  if [[ "$(readlink "$dst" 2>/dev/null || true)" != "$src" ]]; then
    SKIPPED_DESTINATIONS+=("$dst")
  fi
}

# Walk every managed pair for $root into $home under one conflict mode. This is
# the single link loop bootstrap and relink share; a change to the link
# contract (a new exclusion, a new destination shape) lands here once instead
# of drifting between two copies.
link_managed_pairs() {
  local root=$1 home=$2 mode=$3
  local src dst

  if [[ -d "$root/config" ]]; then
    mkdir -p "$home/.config"
  fi

  while IFS= read -r -d '' src && IFS= read -r -d '' dst; do
    link_managed_file "$src" "$dst" "$mode"
  done < <(managed_link_pairs "$root" "$home")
}

# Regenerate the generated identity-routes include file from the ACTIVE owner
# map, atomically: the render goes to a temporary file that replaces the real
# one only on success, so a mid-render failure leaves the previous routes in
# place instead of an empty file that git happily includes (which silently
# disables identity routing).
#
# Returns 0 with the file updated, 2 when the owner map is missing or unusable
# (file left unchanged), 1 when rendering or the final rename failed (file left
# unchanged). Callers own the logging and failure policy.
regenerate_identity_routes() {
  local root="$1"
  local lib="$root/core/git/identity-lib.sh"
  local out="$root/core/git/gitconfig.identity-routes.symlink"
  local tmp

  [[ -r "$lib" ]] || return 2
  # Source in subshells with DOTFILES bound: the library resolves its root from
  # it, so without this the map is read from $HOME/.dotfiles while output goes
  # to $root -- silently different roots whenever the caller runs outside the
  # canonical checkout.
  # shellcheck source=/dev/null
  if ! (
    export DOTFILES="$root"
    . "$lib" && identity_validate_map
  ) >/dev/null 2>&1; then
    return 2
  fi

  tmp="$out.tmp.$$"
  # shellcheck source=/dev/null
  if ! (
    export DOTFILES="$root"
    . "$lib" && identity_render_routes
  ) >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  # The temporary sits beside a tracked file, so a failed rename must not
  # leave it behind to accumulate in the checkout.
  if ! mv -f -- "$tmp" "$out"; then
    rm -f -- "$tmp"
    return 1
  fi
}
