#!/usr/bin/env bash
# Local-only devcontainer seed (gitignored). Copies the authored subset of the
# host ~/.claude into a CONTAINER-LOCAL ~/.claude so nothing the container writes
# can reach the host. The expensive copy/install steps are guarded by a
# versioned sentinel: bump SEED_VERSION whenever those steps change and existing
# containers re-run them on next start without a manual volume wipe.
#
# CRITICAL: this compose `command:` may run as root or as a user OTHER than the
# remoteUser whose terminal/extension actually use the seeded config. So this
# script does NOT use $HOME — it hardcodes the remoteUser's home (SEED_HOME,
# filled in from Step 2) and writes everything there, owned by that user. Keep
# SEED_USER / SEED_HOME in sync with the named-volume targets in the override.
set -euo pipefail

# Bump this whenever the gated steps below (copies, installers) change so
# already-seeded containers refresh instead of silently keeping stale state.
SEED_VERSION=8

# The remoteUser (Step 2) — the user VS Code opens terminals as and whose
# ~/.claude Claude Code reads. NOT necessarily the user running this script.
#
# Resolve BOTH values empirically and once. Do not assume uid 1000 is the
# remoteUser, and do not assume the home is /home/$SEED_USER: images pin homes
# like /home/node, /home/vscode, or /root independently of the name, and a
# guessed home seeds a directory the login shell never reads (mounts "work",
# seed logs success, Claude Code sees nothing). Every mount target and seed
# path below derives from SEED_HOME, so getting it wrong here is silent.
SEED_USER="{USER}"
SEED_HOME="$(getent passwd "$SEED_USER" | cut -d: -f6)"
if [ -z "$SEED_HOME" ]; then
  echo "❌ seed: cannot resolve passwd home for '$SEED_USER' — refusing to guess" >&2
  exit 1
fi
SEED_UID="$(id -u "$SEED_USER")"
SEED_GID="$(id -g "$SEED_USER")"

SEED_CLAUDE="/host-seed/.claude"
SEED_DOTFILES="/host-seed/.dotfiles"
CLAUDE_HOME="$SEED_HOME/.claude"
DOTFILES_HOME="$SEED_HOME/.dotfiles"
SENTINEL="$CLAUDE_HOME/.seeded"

# Run a command as the remoteUser regardless of who this script runs as. If the
# script runs as root, `runuser` needs no password; if it runs as a non-root
# user that differs from SEED_USER, prefix with sudo (confirmed available in
# Step 2). If the script already runs AS SEED_USER, this still works.
if [ "$(id -u)" -eq 0 ]; then
  as_user() { runuser -u "$SEED_USER" -- "$@"; }
  SUDO=""
elif [ "$(id -un)" = "$SEED_USER" ]; then
  as_user() { "$@"; }
  SUDO="sudo"
else
  as_user() { sudo -u "$SEED_USER" -- "$@"; }
  SUDO="sudo"
fi

# --- Always-run block (before the sentinel) --------------------------------
# Everything here runs on EVERY launch, even when the sentinel is current, so it
# survives a rebuild that wiped the ephemeral writable layer. This covers:
# ownership repair, the Vekil zsh hook, the ~/.local/bin PATH entry, the
# default-shell switch, the dotfiles refresh, and the claude/codex installs —
# because all of those targets are either re-derived cheaply or live in the
# ephemeral layer, NOT the persisted named volume the sentinel guards.

# Named-volume mountpoints can start as root:root. Repair them to the remoteUser
# every launch. mkdir first: on a fresh volume the home subdirs may not exist yet.
echo "🌱 seed: repairing container-local volume ownership ($SEED_HOME)"
$SUDO mkdir -p "$CLAUDE_HOME" "$DOTFILES_HOME"
$SUDO chown -R "$SEED_UID:$SEED_GID" "$CLAUDE_HOME" "$DOTFILES_HOME"

# Load Vekil's endpoint variables and managed Codex wrapper in container zsh
# sessions. Write into the remoteUser's ~/.zshrc so their terminal sources it.
# Keep this before the sentinel so existing volumes gain the hook.
VEKIL_ENV_HOOK='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
ZSHRC="$SEED_HOME/.zshrc"

$SUDO touch "$ZSHRC"
if ! grep -Fqx "$VEKIL_ENV_HOOK" "$ZSHRC" 2>/dev/null; then
  printf '\n%s\n' "$VEKIL_ENV_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: configured Vekil shell integration"
fi

# The native Claude Code installer drops the binary in ~/.local/bin, which most
# base images do not have on PATH. Add it for interactive shells so `claude`
# resolves after the seed installs it. Kept in the always-run block so existing
# volumes gain the PATH entry without a full reseed.
LOCALBIN_HOOK='[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"'
if ! grep -Fqx "$LOCALBIN_HOOK" "$ZSHRC" 2>/dev/null; then
  printf '%s\n' "$LOCALBIN_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: added ~/.local/bin to PATH"
fi
$SUDO chown "$SEED_UID:$SEED_GID" "$ZSHRC"

# Vekil's shell integration (env.zsh, sourced above) is zsh-only, and it is what
# points claude and codex at the proxy (ANTHROPIC_BASE_URL / OPENAI_BASE_URL). If
# the remoteUser's default shell is bash, an interactive terminal never sources
# env.zsh, so claude launched from it misses the proxy entirely — the classic
# "claude isn't picking up the vekil proxy" symptom. Make zsh the remoteUser's
# login shell so terminals inherit the proxy env. /etc/passwd lives in the
# writable layer and is reset on rebuild, so this re-applies every launch (kept in
# the always-run block, not the gate). This is FATAL, not best-effort: a quiet
# skip leaves a bash login shell that silently bypasses the proxy, which is the
# exact symptom this block exists to prevent. The fix belongs to the user (a base
# image with zsh, or an override that installs it), so fail loudly and say so.
if ! command -v zsh >/dev/null 2>&1; then
  echo "❌ seed: zsh not found — Vekil's env.zsh is zsh-only, so the proxy" >&2
  echo "   would be silently bypassed. Install zsh in the image/override." >&2
  exit 1
fi
ZSH_PATH="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "$SEED_USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "$ZSH_PATH" ]; then
  if command -v chsh >/dev/null 2>&1 && $SUDO chsh -s "$ZSH_PATH" "$SEED_USER" >/dev/null 2>&1; then
    echo "🌱 seed: set $SEED_USER default shell to zsh"
  elif { [ -w /etc/passwd ] || [ "$(id -u)" -eq 0 ]; } &&
    $SUDO sed -i "s#^\($SEED_USER:.*:\)[^:]*\$#\1$ZSH_PATH#" /etc/passwd; then
    echo "🌱 seed: set $SEED_USER default shell to zsh (via /etc/passwd)"
  else
    echo "❌ seed: could not set $SEED_USER's login shell to zsh — neither chsh" >&2
    echo "   nor a writable /etc/passwd is available. Terminals would open bash" >&2
    echo "   and bypass the Vekil proxy." >&2
    exit 1
  fi
fi

# Git excludes for the personal overlay. The overlay's import shims and personal
# settings are kept out of git by the HOST's global core.excludesFile — but that
# config never reaches the container, so without this the shims show as untracked
# in the container's `git status`. Seed a container-local ~/.gitignore for the
# remoteUser and point core.excludesFile at it. Always-run block: git config
# lives in the ephemeral layer and resets on rebuild.
#
# ONLY list personal-overlay artifacts. Do NOT ignore CLAUDE.md or .claude/
# wholesale like the host ~/.gitignore does — inside a project checkout those are
# frequently REAL tracked files (many public and private repos commit their own
# CLAUDE.md and .claude/ contents), and a blanket ignore would hide them from
# `git status` and `git add`. The host can afford the broad patterns because its
# overlay files are personal symlinks; the container cannot.
GITIGNORE="$SEED_HOME/.gitignore"
if ! as_user test -f "$GITIGNORE"; then
  as_user tee "$GITIGNORE" >/dev/null <<'GITEOF'
.DS_Store
*~
*.swp

# Personal Claude Code overlay shims (symlinked in from ~/.dotfiles/projects/).
CLAUDE.local.md
AGENTS.local.md
.claude/settings.local.json
**/.claude/settings.local.json

# Personal docker-compose overrides.
docker-compose.override.yml
docker-compose.override.yaml
GITEOF
  echo "🌱 seed: wrote container-local ~/.gitignore"
fi
as_user git config --global core.excludesFile "$GITIGNORE"

# Personal overlay files can also live INSIDE .claude/ as symlinks pointing into
# ~/.dotfiles/projects/ (e.g. .claude/agents/<name>.md, .claude/commands/...). We
# can't blanket-ignore .claude/ (it holds real tracked project files), and the
# set changes as the overlay grows, so discover the exact overlay symlinks each
# launch and maintain them in a marked, rewritten section of ~/.gitignore. Match
# by the symlink's target TEXT (find -lname), which works in the container even
# though the /home/<host-user>/... target is unresolvable here. Discover the
# enclosing worktree from this mounted script's path. The fallback keeps the
# seed usable when the project is not a Git checkout.
WORKSPACE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$0")"
GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# <<< overlay symlinks (auto) <<<"
if [ -d "$WORKSPACE" ]; then
  overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*/.dotfiles/projects/*' \
    -not -path './node_modules/*' 2>/dev/null | sed 's#^\./##' | sort)"
  # Rewrite the marked block: strip any existing one, then append the current set.
  new_gitignore="$(as_user sed "/^${GI_MARK_BEGIN}$/,/^${GI_MARK_END}$/d" "$GITIGNORE")"
  {
    printf '%s\n' "$new_gitignore"
    printf '%s\n' "$GI_MARK_BEGIN"
    [ -n "$overlay_links" ] && printf '%s\n' "$overlay_links"
    printf '%s\n' "$GI_MARK_END"
  } | as_user tee "$GITIGNORE" >/dev/null
  n="$(printf '%s' "$overlay_links" | grep -c . || true)"
  echo "🌱 seed: refreshed ~/.gitignore overlay-symlink list ($n entries)"
fi

# Refresh dotfiles container-local, then install the tools whose targets live in
# the EPHEMERAL writable layer (claude → ~/.local/bin, codex → ~/.codex). All
# three are in the ALWAYS-RUN block, NOT the versioned gate, for one reason: the
# sentinel lives in the persisted claude-local-home named volume, but these
# targets are wiped on every rebuild. If they were gated, a rebuild would keep
# the old sentinel, the gate would exit "already seeded," and the container would
# come up with NO claude binary and NO codex config — the "claude is missing /
# not using the proxy after rebuild" bug. Guards (command -v / file presence)
# keep warm restarts cheap: only a genuinely absent tool reinstalls.
#
# Every step runs as the remoteUser via as_user so files land owned by them, not
# by root/the seed user. Dotfiles first, because the installers live under
# ~/.dotfiles. rsync -a --delete makes the container tree an EXACT mirror of the
# read-only host seed — files removed upstream are pruned, not left stale (the
# named volume persists across rebuilds, so without --delete a deleted path
# lingers until a manual wipe). Fall back to cp -a where rsync is absent.
if [ -d "$SEED_DOTFILES" ]; then
  if command -v rsync >/dev/null 2>&1; then
    # -c checksums instead of the default size+mtime quick check. The quick
    # check compares mtime at 1-second resolution, so a same-size edit made
    # within a second of the previous sync is skipped -- silently, and this
    # tree decides the model. 40M of unchanged files hashes fast enough that
    # correctness is the better trade here.
    as_user rsync -ac --delete "$SEED_DOTFILES/" "$DOTFILES_HOME/"
    echo "🌱 seed: mirrored ~/.dotfiles via rsync ($(du -sh "$DOTFILES_HOME" | cut -f1))"
  else
    # No non-pruning fallback. DOTFILES_HOME persists across rebuilds and the
    # always-run installers below EXECUTE files from it, so a stale installer
    # deleted upstream would keep running. Wipe-then-copy prunes equivalently.
    as_user find "$DOTFILES_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    as_user cp -a "$SEED_DOTFILES/." "$DOTFILES_HOME/"
    echo "🌱 seed: rebuilt ~/.dotfiles via wipe+cp (no rsync) ($(du -sh "$DOTFILES_HOME" | cut -f1))"
  fi
fi

# Managed global git hooks — most importantly commit-msg, which strips
# Co-authored-by trailers from locally-authored commits. On the host these are
# installed by symlinking ~/.git-hooks -> ~/.dotfiles/core/git/git-hooks.symlink,
# but that symlink is never seeded into the container. Point core.hooksPath
# straight at the mirrored dotfiles copy instead: no symlink to maintain, and it
# follows the repo automatically on every refresh.
#
# MUST come after the ~/.dotfiles mirror above — the hooks only exist once that
# has run. Always-run block: git config lives in the ephemeral layer and resets
# on rebuild, same as core.excludesFile.
#
# Non-fatal, unlike the Vekil proxy steps: a missing hook costs one commit
# trailer rather than silently routing traffic off-proxy. Warn, don't exit.
HOOKS_DIR="$DOTFILES_HOME/core/git/git-hooks.symlink"
if as_user test -x "$HOOKS_DIR/commit-msg"; then
  as_user git config --global core.hooksPath "$HOOKS_DIR"
  echo "🌱 seed: pointed core.hooksPath at $HOOKS_DIR"
else
  echo "⚠️  seed: $HOOKS_DIR/commit-msg missing or not executable — global git" >&2
  echo "   hooks not configured; Co-authored-by trailers will not be stripped." >&2
fi

# Claude CLI binary (ephemeral target). Run as the remoteUser via a login shell
# so the installer sees their PATH and installs into their home.
# Probe the concrete install path, NOT `bash -lc command -v`: the PATH entry for
# ~/.local/bin is added to ~/.zshrc, which a bash login shell never sources, so
# the PATH probe misses an existing binary and reinstalls on every warm restart.
#
# SUPPLY CHAIN: the default path sets ALLOW_REMOTE_INSTALLERS=1, which opts past
# the dotfiles guard and fetches https://claude.ai/install.sh UNPINNED — a
# rebuild executes whatever upstream currently serves. That is accepted here
# because the seed only ever runs against the user's own devcontainer (see
# SKILL.md rule #12). A project that needs supply-chain pinning sets
# CLAUDE_CLI_INSTALL_CMD (via the override's `environment:`) to a command that
# installs a pinned, checksum-verified artifact into $SEED_HOME/.local/bin; the
# remote installer is then never invoked. Note `ai/claude/install.sh` itself has
# no version/checksum support — the pinned artifact must come from the project.
if as_user test -x "$SEED_HOME/.local/bin/claude" || as_user bash -lc 'command -v claude >/dev/null 2>&1'; then
  echo "🌱 seed: claude already installed for $SEED_USER — skipping CLI install"
elif [ -n "${CLAUDE_CLI_INSTALL_CMD:-}" ]; then
  echo "🌱 seed: installing Claude Code CLI via pinned CLAUDE_CLI_INSTALL_CMD"
  as_user bash -lc "$CLAUDE_CLI_INSTALL_CMD" ||
    echo "⚠️  seed: pinned claude CLI install failed (non-fatal)"
elif [ -x "$DOTFILES_HOME/ai/claude/install.sh" ]; then
  echo "🌱 seed: installing Claude Code CLI (unpinned upstream installer)"
  as_user env ALLOW_REMOTE_INSTALLERS=1 bash "$DOTFILES_HOME/ai/claude/install.sh" || echo "⚠️  seed: claude CLI install failed (non-fatal)"
fi

# Codex config (ephemeral target ~/.codex).
if as_user test -f "$SEED_HOME/.codex/config.toml"; then
  : # already linked
elif [ -x "$DOTFILES_HOME/ai/codex/install.sh" ]; then
  echo "🌱 seed: linking Codex config"
  as_user bash "$DOTFILES_HOME/ai/codex/install.sh" || echo "⚠️  seed: codex install failed (non-fatal)"
fi

# ---------------------------------------------------------------------------
# AUTHORED ~/.claude COPY — ALWAYS-RUN, deliberately ABOVE the version gate.
#
# Clause 2 of the two-clause rule: the target persists (claude-local-home), but
# the SOURCE IS THE HOST. SEED_VERSION lives in this script, so the gate cannot
# observe a host-side edit — gating this copy pins the container to whatever the
# host looked like at first seed, through any number of rebuilds, with the fresh
# value sitting unread in the read-only mount one directory away. Unconditional
# costs ~9ms for a ~12K tree, so there is nothing worth protecting. Do NOT
# substitute rsync: absent from many base images, pointless at this size, and
# `rm -rf` + `cp -a` already deletes host-removed files.
#
# PRUNE FIRST, UNCONDITIONALLY. The destination lives in the PERSISTED
# claude-local-home volume, so anything not removed here survives every rebuild.
# Removing inside an `if source exists` guard is the bug: when the host DELETES
# settings.json / CLAUDE.md / config / commands / skills, the guard never fires,
# the stale copy is left behind, and the next sentinel stamp preserves it
# forever. Clearing first makes the seed converge on the host in both
# directions. It also fixes nesting: `cp -a src/commands dst/commands` copies
# *into* an existing destination, producing ~/.claude/commands/commands on the
# second copy.
#
# Only these five seed-owned paths are pruned. ~/.claude/plugins (marketplace),
# the sentinel, and all runtime state are deliberately untouched.
# The prune runs even when $SEED_CLAUDE is absent entirely — removing the whole
# mount is just the limiting case of deleting every file in it, and leaving the
# stale copies behind there would be the same bug.
# ---------------------------------------------------------------------------
echo "🌱 seed: creating container-local $CLAUDE_HOME"
as_user mkdir -p "$CLAUDE_HOME"

for item in settings.json CLAUDE.md; do
  as_user rm -rf "$CLAUDE_HOME/$item"
  if [ -e "$SEED_CLAUDE/$item" ]; then
    as_user cp -a "$SEED_CLAUDE/$item" "$CLAUDE_HOME/$item"
  fi
done
for dir in config commands skills; do
  as_user rm -rf "$CLAUDE_HOME/$dir"
  if [ -d "$SEED_CLAUDE/$dir" ]; then
    as_user cp -a "$SEED_CLAUDE/$dir" "$CLAUDE_HOME/$dir"
  fi
done
if [ -d "$SEED_CLAUDE" ]; then
  echo "🌱 seed: refreshed authored ~/.claude subset from host"
else
  echo "🌱 seed: no $SEED_CLAUDE mount — pruned seed-owned ~/.claude paths"
fi

# ---------------------------------------------------------------------------
# DRIFT CHECK — runs on BOTH the gated-skip and reseed paths.
# Compares CONTENT against the host mount rather than trusting the sentinel, so
# it reports staleness no matter the cause — including a seed still running the
# old layout where this copy sat below the gate. This is the check that turns
# "why is my model wrong" from a debugging session into a line in the log.
# Advisory only: never exits nonzero, so a false positive cannot block startup.
# ---------------------------------------------------------------------------
config_drift_check() {
  local drift=""
  # The SAME five seed-owned paths the copy above manages. Comparing a subset
  # would pass while commands/ or skills/ were stale.
  for item in settings.json CLAUDE.md config commands skills; do
    local src="$SEED_CLAUDE/$item" dst="$CLAUDE_HOME/$item"
    # Both directions. An `[ -e "$src" ] || continue` guard is the bug it is
    # meant to catch: a path DELETED on the host but still present in the
    # persisted volume is exactly the stale-copy case, and skipping absent
    # sources makes it invisible.
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
      drift="$drift $item(missing)"
    elif [ ! -e "$src" ] && [ -e "$dst" ]; then
      drift="$drift $item(orphaned)"
    elif [ -d "$src" ] || [ -d "$dst" ]; then
      # --no-dereference is REQUIRED here, not a nicety. ~/.claude/skills is a
      # tree of symlinks into ~/.agents, which is deliberately NOT mounted, so a
      # dereferencing diff compares two unreachable targets and reports drift
      # between byte-identical trees — a FAIL on every single start.
      diff --no-dereference -rq "$src" "$dst" >/dev/null 2>&1 ||
        drift="$drift $item"
    elif [ -e "$src" ]; then
      cmp -s "$src" "$dst" || drift="$drift $item"
    fi
  done
  if [ -n "$drift" ]; then
    echo "   FAIL  ~/.claude differs from host mount:$drift"
    echo "         seed may predate the always-run config copy — re-copy"
    echo "         local-seed.sh from the project-claude-setup skill"
  else
    echo "   PASS  authored ~/.claude matches host mount"
  fi
  return 0
}

# Invoked here, ABOVE the gate, so it runs on BOTH paths — the gated-skip branch
# below and the reseed path. Placed after the copy so it verifies the result of
# this run rather than the previous one.
config_drift_check

# --- Versioned gate --------------------------------------------------------
# Skip the gated INSTALL steps only when the sentinel already records this
# SEED_VERSION. An empty legacy sentinel (the pre-versioning contract) is NOT
# treated as current: it falls through once so the versioned steps run and the
# sentinel gets stamped, after which the gate is a plain version match. A bump
# likewise re-runs them. The Vekil hook and the authored-config copy above run
# regardless. A read that FAILS (permission/IO) also falls through to the
# reseed path so the later sentinel write surfaces the error.
#
# NOTE what is NOT below this gate: the authored ~/.claude copy. Its target
# persists, but its SOURCE IS THE HOST, and SEED_VERSION lives in this file —
# so a host-side edit bumps no version and a gated copy would never see it.
# See clause 2 of the two-clause rule (SKILL.md item 15).
SEED_ALREADY_CURRENT=0
if [ -f "$SENTINEL" ] && SEEN_VERSION="$(cat "$SENTINEL")" 2>/dev/null &&
  [ "$SEEN_VERSION" = "$SEED_VERSION" ]; then
  echo "🌱 seed: already seeded (v$SEEN_VERSION) — skipping installers"
  SEED_ALREADY_CURRENT=1
fi
if [ "$SEED_ALREADY_CURRENT" -eq 0 ]; then
  if [ -f "$SENTINEL" ] && [ -z "${SEEN_VERSION:-}" ]; then
    echo "🌱 seed: migrating legacy unstamped sentinel to v$SEED_VERSION"
  fi
  echo "🌱 seed: seeding to v$SEED_VERSION"

  # Reinstall my@guarzo marketplace + plugins into container-local ~/.claude.
  # This is correctly gated: it targets the PERSISTED claude-local-home named
  # volume, so once installed it survives rebuilds and only needs re-running on a
  # SEED_VERSION bump. (Dotfiles refresh, claude binary, and codex config moved to
  # the always-run block above because their targets are ephemeral and would vanish
  # on rebuild while this sentinel persisted.)
  # A failed install must NOT be stamped: the sentinel is the only thing standing
  # between a half-populated ~/.claude/plugins and a permanent skip on every later
  # launch. Record the failure and leave the sentinel alone so the next run retries.
  MARKETPLACE_OK=1
  if [ -x "$DOTFILES_HOME/ai/marketplace/install.sh" ]; then
    echo "🌱 seed: installing my@guarzo marketplace + plugin"
    as_user bash "$DOTFILES_HOME/ai/marketplace/install.sh" || {
      MARKETPLACE_OK=0
      echo "⚠️  seed: marketplace install failed — NOT stamping sentinel; next launch retries"
    }
  fi

  # Stamp the sentinel with the current version, but only on a clean run.
  if [ "$MARKETPLACE_OK" -eq 1 ]; then
    printf '%s\n' "$SEED_VERSION" | as_user tee "$SENTINEL" >/dev/null
    echo "🌱 seed: done (v$SEED_VERSION)"
  else
    # Exit non-zero so the failure is visible to anything that checks. Note the
    # compose command uses `;` (not `&&`) before `exec {BASE_COMMAND}`, so the
    # container still starts — deliberately, since a degraded container the user
    # can debug beats one that will not boot. A missing installer stays non-fatal;
    # only an installer that ran and failed reports an error.
    echo "❌ seed: marketplace install failed (sentinel left at previous version)" >&2
    exit 1
  fi
fi

case "${1:-}" in
  --argv)
    shift
    (($# > 0)) || exit 2
    exec "$@"
    ;;
  --shell)
    shift
    (($# == 1)) || exit 2
    exec bash -lc -- "$1"
    ;;
  "") ;;
  *)
    printf 'seed: unknown command mode: %s\n' "$1" >&2
    exit 2
    ;;
esac
