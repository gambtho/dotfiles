#!/usr/bin/env bash
# SessionStart hook: make the personal overlay's skills/agents available in
# git worktrees, and repair overlay links that point at a foreign $HOME.
#
# Two failure modes this addresses:
#
#   1. `git worktree add` produces a fresh working tree. The .claude/ overlay
#      is untracked, so it does not come along and none of the project's
#      personal skills exist in the new worktree.
#   2. A link created under one $HOME (e.g. a WSL host user's home) does not
#      resolve under another (e.g. a devcontainer running as root), so
#      the overlay is silently invisible even in the main checkout.
#
# Both are repaired by re-running claude-link-project, which is idempotent and
# writes only inside the current working tree.
#
# Fails open: any unexpected condition exits 0 without touching anything. A
# broken hook must never prevent a session from starting.
set -u

exit_quiet() { exit 0; }

[ "${CLAUDE_OVERLAY_SYNC:-on}" = "off" ] && exit_quiet

input=$(cat 2>/dev/null) || exit_quiet
command -v jq >/dev/null 2>&1 || exit_quiet
command -v git >/dev/null 2>&1 || exit_quiet

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit_quiet
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$cwd" ] || exit_quiet

DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
LINKER="$DOTFILES/bin/claude-link-project"
[ -x "$LINKER" ] || exit_quiet

repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit_quiet
repo_root=$(cd "$repo_root" && pwd -P) || exit_quiet

# The overlay is keyed on the project's directory name. A linked worktree is
# named after its branch, not the project, so resolve the slug from the main
# checkout: `git worktree list` prints the primary working tree first.
main_root=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null |
  awk '/^worktree /{print substr($0, 10); exit}') || exit_quiet
[ -n "$main_root" ] && [ -d "$main_root" ] || main_root="$repo_root"
slug=$(basename "$main_root")

# The directory name is not always the project name. A devcontainer bind-mounts
# the repo at whatever path its compose file picked — /app, /workspace, /src —
# so the same checkout that is `wanderer` on the host is `app` inside the
# container, and this hook would look for a projects/app that does not exist and
# fail open on every worktree. Recover the real slug from an overlay link the
# main checkout already carries: those are created with an explicit slug, and
# readlink reads the target text without resolving it, so a link left dangling
# by the foreign-$HOME breakage above still names its project correctly.
if [ ! -d "$DOTFILES/projects/$slug" ]; then
  for link in "$main_root"/.claude/* "$main_root"/*; do
    [ -L "$link" ] || continue
    target=$(readlink "$link" 2>/dev/null) || continue
    case "$target" in
      */projects/*) ;;
      *) continue ;;
    esac
    candidate=${target#*/projects/}
    candidate=${candidate%%/*}
    # A slug is one path component, so "." and ".." are never valid ones — and
    # the -d test below cannot reject them, since both resolve to directories
    # that exist. ".." is the one that bites: it escapes projects/ entirely, so
    # the linker would be handed --slug .. and would link $DOTFILES/.claude,
    # the global agent config, into the project as if it were an overlay.
    case "$candidate" in
      "" | "." | "..") continue ;;
    esac
    if [ -d "$DOTFILES/projects/$candidate" ]; then
      slug="$candidate"
      break
    fi
  done
fi

overlay="$DOTFILES/projects/$slug"
[ -d "$overlay" ] || exit_quiet

# Nothing to do unless something is actually missing or broken. Checking first
# keeps the common case free of writes and output.
needs_work=0
for sub in skills agents; do
  [ -d "$overlay/.claude/$sub" ] || continue
  # -e follows symlinks, so a dangling link fails this test — which is
  # exactly the foreign-$HOME breakage we want to catch.
  [ -e "$repo_root/.claude/$sub" ] || needs_work=1
done
# Any dangling link anywhere under .claude/ also warrants a repair pass.
if [ -d "$repo_root/.claude" ] &&
  [ -n "$(find "$repo_root/.claude" -xtype l -print -quit 2>/dev/null)" ]; then
  needs_work=1
fi
[ "$needs_work" -eq 1 ] || exit_quiet

# --claude-dir-per-file is the safe mode: it refuses to shadow tracked project
# files, and links skills/ and agents/ as whole directories.
# --no-claude-md leaves CLAUDE.md alone; this hook only repairs discovery of
# skills and agents, and must not touch instruction files behind the user's back.
out=$("$LINKER" --claude-dir-per-file --no-claude-md --slug "$slug" "$repo_root" 2>&1 </dev/null) || exit_quiet

# Count only the linker's change-reporting lines. Anchored at line start so
# "already linked:" does not match — otherwise a no-op run would announce
# itself on every session start.
linked=$(printf '%s\n' "$out" |
  grep -cE '^(linked:|repaired |migrated )' 2>/dev/null) || linked=0
[ "${linked:-0}" -gt 0 ] || exit_quiet

# Skills are discovered when the session starts, so links created by this hook
# are not guaranteed to be loaded in the session that just began. Say so rather
# than let the user wonder why a repaired skill still isn't listed.
msg="Personal overlay for '$slug' was re-linked into $repo_root ($linked item(s) \
created or migrated). Skills and agents are discovered at session start, so any \
newly linked ones may not appear until this session is restarted."

jq -n --arg c "$msg" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
