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
# remoteUser, and do not assume the home directory follows the username: images
# pin homes (e.g. under node, vscode, or root) independently of the name, and a
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

# Stable root for personal overlay symlinks (see the block that creates it).
# Constant in production; DOTFILES_LINK_ROOT is a test-only override, and it is
# the same variable bin/common.sh honours, so both branches below agree.
STABLE_LINK_ROOT="${DOTFILES_LINK_ROOT:-/opt/dotfiles}"

# Set when a gated installer ran and failed. Consulted only by the no-base-command
# dispatch branch at the bottom; a dispatched base command exec's regardless so
# the container still starts.
SEED_FAILED=0

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

# Source the mirrored dotfiles via their own entry point, so container shells
# get the same aliases, PATH, and EDITOR fallback as the host. This belongs in
# the seed rather than the tracked Dockerfile: it is only meaningful alongside
# the ~/.dotfiles mount from the (gitignored) override, and a teammate without
# that mount would just carry dead code.
#
# load-custom.zsh is the supported entry point and sources core/, languages/,
# tools/, platforms/ and the profile itself. Do NOT glob `$DOTFILES/**/*.zsh`:
# that glob also matches load-custom.zsh, so the whole tree loads twice —
# aliases redefined, PATH entries duplicated. It also prints a stray
# `file=/…/load-custom.zsh` line before every prompt, because the loop leaves
# $file set and load-custom.zsh re-declares it via `typeset`, which echoes
# name=value when TYPESET_SILENT is off (zsh's default).
#
# It must land BEFORE the Vekil hook: ai/vekil/env.zsh owns the endpoint/model
# variables and has to get the last word, but core/ (which load-custom.zsh
# sources) also sets some of them. Appending is only correct on a FRESH zshrc,
# where the Vekil block below has not run yet. Two other states exist on an
# already-seeded volume, which is exactly the upgrade path this block serves:
# the Vekil hook present and this one absent (appending would land after it),
# and — left behind by every seed older than this one — BOTH present in the
# wrong order. Checking only for our own hook's presence declares that second
# state fixed and latches the inverted precedence forever.
#
# So compare positions, and let one awk cover both repairs: it drops any
# existing copy wherever it sits, then re-emits it above the Vekil line.
DOTFILES_LOAD_HOOK='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'
# Count, don't just locate. The first match's position says nothing about copies
# below it, so a zshrc holding two hooks — one correctly placed — reads as
# already-correct and the tree sources twice forever, which is the duplicate-
# alias/duplicate-PATH failure this hook exists to avoid.
# `|| true`: under `set -o pipefail` a non-matching grep would abort the seed.
load_n="$(grep -Fxc "$DOTFILES_LOAD_HOOK" "$ZSHRC" 2>/dev/null || true)"
load_at="$(grep -Fxn "$DOTFILES_LOAD_HOOK" "$ZSHRC" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
vekil_at="$(grep -Fxn "$VEKIL_ENV_HOOK" "$ZSHRC" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
if [ "${load_n:-0}" -gt 1 ] ||
  { [ -n "$vekil_at" ] && { [ "${load_n:-0}" -eq 0 ] || [ "$load_at" -gt "$vekil_at" ]; }; }; then
  ZSHRC_TMP="$(mktemp)"
  # Exact line match on the whole hook, not a substring: awk -v takes the
  # value literally and neither hook contains a backslash. Dropping every copy
  # before re-emitting one is what makes both the reorder and the de-duplicate
  # path converge on the same single correctly-placed line; the END clause
  # covers de-duplicating a zshrc that has no Vekil hook to anchor against.
  awk -v hook="$DOTFILES_LOAD_HOOK" -v vekil="$VEKIL_ENV_HOOK" '
    $0 == hook { next }
    $0 == vekil && !ins { print hook; print ""; ins = 1 }
    { print }
    END { if (!ins) print hook }
  ' "$ZSHRC" >"$ZSHRC_TMP"
  # cp, not mv: writing through the existing path keeps the file's owner and
  # mode, which matter because the terminal user may not be the seed user.
  $SUDO cp "$ZSHRC_TMP" "$ZSHRC"
  rm -f "$ZSHRC_TMP"
  echo "🌱 seed: configured dotfiles shell integration"
elif [ "${load_n:-0}" -eq 0 ]; then
  # No Vekil hook yet — its own block below appends after this one, so a plain
  # append already lands in the right order.
  printf '\n%s\n' "$DOTFILES_LOAD_HOOK" | $SUDO tee -a "$ZSHRC" >/dev/null
  echo "🌱 seed: configured dotfiles shell integration"
fi

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
    $SUDO sed -i "s#^\($SEED_USER:.*:\)[^:]*\$#\1$ZSH_PATH#" /etc/passwd &&
    # sed exits 0 whether or not the address matched, so the edited field is read
    # back before claiming success: a SEED_USER absent from /etc/passwd (NSS-only
    # accounts) would otherwise report a shell change that never happened and let
    # terminals keep opening bash past the fatal branch below.
    [ "$(getent passwd "$SEED_USER" | cut -d: -f7)" = "$ZSH_PATH" ]; then
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
# though the host user's home-directory target is unresolvable here. The pattern is
# deliberately NOT '*/.dotfiles/projects/*': links created after the stable-root
# change target /opt/dotfiles/projects/... with no leading dot, and missing them
# puts personal overlay files — CLAUDE.md included — into container git status.
# Substituted at render time from the container workspace inspected in Step 6,
# not derived from this script's own path: the seed is mounted at an arbitrary
# container path that need not sit inside the checkout, and `git rev-parse` from
# there resolves to the wrong tree — or to nothing, whereupon the old fallback
# scanned the mount directory and reported a successful refresh of zero entries.
WORKSPACE="{WORKSPACE}"
GI_MARK_BEGIN="# >>> overlay symlinks (auto, do not edit) >>>"
GI_MARK_END="# <<< overlay symlinks (auto) <<<"
if [ ! -d "$WORKSPACE" ]; then
  echo "⚠️  seed: workspace $WORKSPACE is not a directory — leaving ~/.gitignore" >&2
  echo "   overlay-symlink list untouched; overlay files may show up in git status" >&2
else
  overlay_links="$(cd "$WORKSPACE" && find . -type l -lname '*dotfiles/projects/*' \
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

# Stable link root: /opt/dotfiles -> this container's dotfiles checkout.
#
# Personal overlay symlinks in the workspace (.claude/skills, .claude/agents,
# CLAUDE.md, ...) are bind-mounted from the host and store an ABSOLUTE target.
# Written under the host user's own home directory they dangle here, because this
# container has a different $HOME — that is the "devcontainer can't see the
# project skills" bug, and it silently takes out CLAUDE.md too. They are now
# written as /opt/dotfiles/projects/..., which each environment points at its
# own checkout. The host side is established by ~/.dotfiles/bin/relink; this is
# the container side. Both sides stay writable and independent: this root
# resolves into the dotfiles named volume, so container writes never reach the
# host.
#
# ALWAYS-RUN, never gated: /opt lives in the ephemeral writable layer and is
# wiped by every rebuild, while the sentinel persists in a named volume. Gating
# it would leave a rebuilt container reporting "already seeded" with every
# overlay link dangling. Must come after the mirror above — the helper refuses
# a target that is not a directory.
#
# The mirrored dotfiles own the root path so it is defined once; the literal
# fallback keeps this seed working against a checkout predating the helper.
if [ -r "$DOTFILES_HOME/bin/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/bin/common.sh"
fi
if command -v ensure_stable_link_root >/dev/null 2>&1; then
  ensure_stable_link_root "$DOTFILES_HOME"
elif [ -e "$STABLE_LINK_ROOT" ] && [ ! -L "$STABLE_LINK_ROOT" ]; then
  # Same guard the helper applies: a real file or directory there is somebody
  # else's, and `ln -sfn` would either fail obscurely or plant the link inside
  # it. Say what to do instead of reporting a generic creation failure.
  echo "⚠️  seed: $STABLE_LINK_ROOT exists and is not a symlink — move it aside" >&2
  echo "   and restart; overlay links will dangle in this container until then." >&2
elif $SUDO mkdir -p "$(dirname "$STABLE_LINK_ROOT")" &&
  $SUDO ln -sfn "$DOTFILES_HOME" "$STABLE_LINK_ROOT"; then
  echo "🌱 seed: $STABLE_LINK_ROOT -> $DOTFILES_HOME (literal fallback)"
else
  # Non-fatal, and deliberately so: overlay links then keep their
  # $HOME-absolute targets, which is the pre-existing behaviour rather than a
  # regression. Taking the container down over it would be worse.
  echo "⚠️  seed: could not create $STABLE_LINK_ROOT — personal overlay links" >&2
  echo "   (.claude/skills, CLAUDE.md, ...) will dangle in this container." >&2
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
#
# Guard on the BINARY, not the config. Both ~/.codex/config.toml and
# ~/.local/bin live in the ephemeral layer, but the installer writes config even
# when it cannot produce a binary (it treats a missing CLI as a soft skip).
# Testing config.toml therefore latches: config present, `codex` missing, and
# the installer skipped on every subsequent start.
if as_user test -x "$SEED_HOME/.local/bin/codex"; then
  echo "🌱 seed: codex already present"
elif [ -x "$DOTFILES_HOME/ai/codex/install.sh" ]; then
  echo "🌱 seed: linking Codex config"
  as_user bash "$DOTFILES_HOME/ai/codex/install.sh" || echo "⚠️  seed: codex install failed (non-fatal)"
fi

# Neovim (ephemeral target ~/.local). The dotfiles set EDITOR=nvim and ship
# config/nvim, but nothing in them installs the binary — on a normal host it
# arrives via the apt/brew package lists, which a devcontainer image never runs.
# An EDITOR pointing at a missing command breaks `git commit` and
# `git rebase -i` with an error that names git, not the editor. (core/env.zsh
# falls back to vim, so this is the intended editor rather than a hard
# requirement — hence non-fatal throughout.)
#
# Not apt: Debian bookworm ships 0.7.2 and config/nvim uses vim.uv + lazy.nvim,
# which need 0.10+. Not the Dockerfile either: this is a personal-dotfiles
# requirement, so it belongs with the mount that enables it. Version and
# checksums come from the mirrored config/versions.env, so the download is
# pinned and verified — unlike the claude CLI path above.
# `-f` as well as `-x`: both follow symlinks, so the normal shape (bin/nvim ->
# nvim-dist/bin/nvim) still passes, while a directory — which `-x` alone reports
# as executable — no longer counts as "already installed" and silently skips.
if as_user test -f "$SEED_HOME/.local/bin/nvim" && as_user test -x "$SEED_HOME/.local/bin/nvim"; then
  echo "🌱 seed: nvim already present"
elif [ -r "$DOTFILES_HOME/config/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/config/versions.env"
  # `:-` like the checksums below it: a versions.env that predates the pin, or
  # renames it, would otherwise take down the whole seed on the first expansion
  # under `set -u` — before the non-fatal skip below ever gets to report it.
  NVIM_VERSION="${NVIM_VERSION:-}"
  case "$(uname -m)" in
    x86_64) NVIM_ARCH=linux-x86_64 NVIM_SHA="${NVIM_SHA256_X86_64:-}" ;;
    aarch64 | arm64) NVIM_ARCH=linux-arm64 NVIM_SHA="${NVIM_SHA256_ARM64:-}" ;;
    *) NVIM_ARCH="" ;;
  esac
  if [ -z "$NVIM_ARCH" ]; then
    echo "⚠️  seed: no neovim build for $(uname -m) — skipping (EDITOR falls back to vim)"
  elif [ -z "$NVIM_VERSION" ]; then
    echo "⚠️  seed: versions.env pins no NVIM_VERSION — skipping (EDITOR falls back to vim)"
  elif [ -z "$NVIM_SHA" ]; then
    # Same reason the tree-sitter block checks its checksum up front rather than
    # leaving it to the verify step: an unpinned SHA turns every start into a
    # ~10MB download that can only ever fail `sha256sum -c` at the end.
    echo "⚠️  seed: versions.env pins no neovim checksum for $(uname -m) — skipping (EDITOR falls back to vim)"
  else
    echo "🌱 seed: installing neovim $NVIM_VERSION ($NVIM_ARCH)"
    NVIM_TMP="$(mktemp -d)"
    NVIM_URL="https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-${NVIM_ARCH}.tar.gz"
    # Every step is inside the `if` condition, so a failure anywhere falls
    # through to the non-fatal message instead of killing the seed under
    # `set -e` — an optional editor must never cost the container its start.
    # Deployment is part of the chain rather than a trailing block: an unchecked
    # mv/ln can leave ~/.local/bin/nvim dangling while "neovim ready" prints,
    # and a dangling EDITOR fails `git commit` with an error naming git.
    #
    # Timeouts are bounded for the same reason. curl's default is no timeout at
    # all, so a blackholed connection to the release CDN hangs the seed forever
    # and the container never finishes starting.
    #
    # The whole tree ships, not just the binary: nvim needs its runtime/ share
    # dir, so symlinking the bare binary gives an nvim that starts and then
    # cannot find its own runtime files.
    #
    # Staged into nvim-dist.new and validated there before the existing runtime
    # is touched. Removing nvim-dist first would destroy a working editor to
    # make room for a download that may not survive the checksum or the chown —
    # reachable whenever bin/nvim is missing or broken but the tree beneath it
    # is fine, which is precisely when this branch runs on a warm container.
    #
    # The chown must land or the tree must already belong to the seed user: a
    # runtime the remoteUser cannot write is one lazy.nvim cannot update, and
    # `test -x` alone would happily accept it.
    NVIM_DIST="$SEED_HOME/.local/share/nvim-dist"
    if curl -fsSL --connect-timeout 10 --max-time 300 \
      -o "$NVIM_TMP/nvim.tar.gz" "$NVIM_URL" &&
      echo "$NVIM_SHA  $NVIM_TMP/nvim.tar.gz" | sha256sum -c - >/dev/null 2>&1 &&
      tar -xzf "$NVIM_TMP/nvim.tar.gz" -C "$NVIM_TMP" &&
      [ -d "$NVIM_TMP/nvim-$NVIM_ARCH" ] &&
      as_user mkdir -p "$SEED_HOME/.local/share" "$SEED_HOME/.local/bin" &&
      as_user rm -rf "$NVIM_DIST.new" &&
      mv "$NVIM_TMP/nvim-$NVIM_ARCH" "$NVIM_DIST.new" &&
      { chown -R "$SEED_UID:$SEED_GID" "$NVIM_DIST.new" 2>/dev/null ||
        [ -z "$(find "$NVIM_DIST.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
      as_user test -x "$NVIM_DIST.new/bin/nvim" &&
      as_user rm -rf "$NVIM_DIST" &&
      mv "$NVIM_DIST.new" "$NVIM_DIST" &&
      as_user ln -sf "$NVIM_DIST/bin/nvim" "$SEED_HOME/.local/bin/nvim" &&
      as_user test -x "$SEED_HOME/.local/bin/nvim"; then
      echo "🌱 seed: neovim ready"
    else
      echo "⚠️  seed: neovim install failed (non-fatal; EDITOR falls back to vim)"
    fi
    as_user rm -rf "$NVIM_DIST.new"
    rm -rf "$NVIM_TMP"
  fi
fi

# Point nvim at the mirrored dotfiles config, the way the host install does.
# Without this the binary starts bare and none of config/nvim applies.
# Always-run: ~/.config is in the ephemeral layer. Replaced unconditionally when
# it is a symlink, but a real directory is left alone — that would be someone's
# own container-local config, and clobbering it is not this script's call.
if [ -d "$DOTFILES_HOME/config/nvim" ]; then
  as_user mkdir -p "$SEED_HOME/.config"
  if as_user test -L "$SEED_HOME/.config/nvim" || ! as_user test -e "$SEED_HOME/.config/nvim"; then
    as_user ln -sfn "$DOTFILES_HOME/config/nvim" "$SEED_HOME/.config/nvim"
    echo "🌱 seed: linked ~/.config/nvim to dotfiles"
  else
    echo "⚠️  seed: ~/.config/nvim is a real directory — leaving it alone"
  fi
fi

# tree-sitter CLI (ephemeral target ~/.local/bin). config/nvim pins
# nvim-treesitter to its `main` branch, whose installer shells out to
# `tree-sitter build` for EVERY parser — there is no fallback to a bare `cc`, so
# a container with gcc but no CLI still fails every parser with
# `Error during "tree-sitter build": ... ENOENT ... (cmd): 'tree-sitter'`, on the
# bootstrap set (bash, c, lua, markdown, vimdoc, ...) at the first nvim launch.
# On a host the CLI arrives from mise (`npm:tree-sitter-cli` in
# config/mise/config.toml); the seed never runs mise, so it is supplied here as a
# pinned release binary. Keep TREE_SITTER_VERSION in step with the mise pin.
#
# Always-run for the same reason as nvim: ~/.local/bin is the ephemeral writable
# layer, so a version-gated step would be skipped as "already seeded" and the
# binary would be gone after every rebuild.
#
# Non-fatal throughout, like nvim: treesitter highlighting is a nicety, and an
# editor that opens without it beats a container that will not start.
#
# Two guards, in this order, and the order matters. `command -v` alone is NOT
# enough: the seed runs as a container `command:`, whose PATH does not include
# ~/.local/bin, so on every warm start our own installed binary would look
# missing and be re-downloaded (26MB) each launch. The path test is the
# PATH-independent guard for what this block installed; the `command -v` probe
# only catches a CLI the image itself supplies somewhere else on PATH.
#
# Both guards confirm by RUNNING --version, for the same reason the install path
# below does: `test -x` and `command -v` are satisfied by a binary that dies at
# exec time (glibc release binary on a musl base) and by a shim whose tool was
# never installed. Either one would latch this block shut — the seed would report
# "already present" on every start while nvim-treesitter kept failing every
# parser. Confirming by execution instead makes the guard self-healing: an
# unusable CLI is simply replaced on the next start.
if as_user test -f "$SEED_HOME/.local/bin/tree-sitter" &&
  as_user "$SEED_HOME/.local/bin/tree-sitter" --version >/dev/null 2>&1; then
  echo "🌱 seed: tree-sitter already present"
elif as_user sh -c 'command -v tree-sitter >/dev/null 2>&1 && tree-sitter --version >/dev/null 2>&1'; then
  echo "🌱 seed: tree-sitter already present (image-provided)"
elif [ -r "$DOTFILES_HOME/config/versions.env" ]; then
  # shellcheck source=/dev/null
  . "$DOTFILES_HOME/config/versions.env"
  case "$(uname -m)" in
    x86_64) TS_ARCH=linux-x64 TS_SHA="${TREE_SITTER_SHA256_X86_64:-}" ;;
    aarch64 | arm64) TS_ARCH=linux-arm64 TS_SHA="${TREE_SITTER_SHA256_ARM64:-}" ;;
    *) TS_ARCH="" TS_SHA="" ;;
  esac
  # TS_SHA is checked here, not left to the verify step: an unpinned checksum
  # would otherwise cost a 26MB download before failing, every single start.
  if [ -z "$TS_ARCH" ] || [ -z "$TS_SHA" ] || [ -z "${TREE_SITTER_VERSION:-}" ]; then
    echo "⚠️  seed: no pinned tree-sitter build for $(uname -m) — skipping (treesitter parsers will not compile)"
  else
    echo "🌱 seed: installing tree-sitter $TREE_SITTER_VERSION ($TS_ARCH)"
    TS_TMP="$(mktemp -d)"
    TS_BIN="$SEED_HOME/.local/bin/tree-sitter"
    # The release asset is a single gzipped binary (.gz), NOT a tarball — there
    # is no directory to extract and no runtime tree to place beside it.
    #
    # Staged as tree-sitter.new on the destination filesystem and validated by
    # actually RUNNING it before the final mv. `test -x` is not enough: these are
    # dynamically linked against glibc, so on a musl base image the file is
    # executable and still dies with "not found" at exec time — which would
    # surface later as the same confusing treesitter build failure this block
    # exists to fix, only now with a binary sitting in place looking installed.
    #
    # Bounded curl timeouts for the same reason as nvim: the default is no
    # timeout at all, so a blackholed CDN would hang container start forever.
    if curl -fsSL --connect-timeout 10 --max-time 300 \
      -o "$TS_TMP/tree-sitter.gz" "https://github.com/tree-sitter/tree-sitter/releases/download/v${TREE_SITTER_VERSION}/tree-sitter-${TS_ARCH}.gz" &&
      echo "$TS_SHA  $TS_TMP/tree-sitter.gz" | sha256sum -c - >/dev/null 2>&1 &&
      gunzip -c "$TS_TMP/tree-sitter.gz" >"$TS_TMP/tree-sitter" &&
      as_user mkdir -p "$SEED_HOME/.local/bin" &&
      rm -f "$TS_BIN.new" &&
      cp "$TS_TMP/tree-sitter" "$TS_BIN.new" &&
      chmod 0755 "$TS_BIN.new" &&
      { chown "$SEED_UID:$SEED_GID" "$TS_BIN.new" 2>/dev/null ||
        [ -z "$(find "$TS_BIN.new" \( ! -uid "$SEED_UID" -o ! -gid "$SEED_GID" \) -print -quit 2>/dev/null)" ]; } &&
      as_user "$TS_BIN.new" --version >/dev/null 2>&1 &&
      as_user mv "$TS_BIN.new" "$TS_BIN"; then
      echo "🌱 seed: tree-sitter ready"
    else
      echo "⚠️  seed: tree-sitter install failed (non-fatal; treesitter parsers will not compile)"
    fi
    rm -f "$TS_BIN.new"
    rm -rf "$TS_TMP"
  fi
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
# PLUGIN REGISTRY HOME-PATH REPAIR — always-run, deliberately ABOVE the gate.
# The registry records ABSOLUTE paths. When the container user changes (root →
# vscode/node/developer), every recorded path still names the OLD home while the
# payloads live under the new one, and Claude reports `cache-miss` for every
# plugin — the marketplace looks un-downloaded when nothing is actually missing.
# This lives in the persisted volume, so no rebuild clears it.
#
# NOT gated: the source is container runtime state, which SEED_VERSION cannot
# observe, so gating latches the break the way any state-blind guard does.
# The rewrite is a no-op once paths are correct, so running it always is free.
#
# The /.claude|/.dotfiles suffix is a load-bearing anchor: a bare /root also
# matches the //rootly.com and /Rootly-AI-Labs URLs in the official catalog.
# ---------------------------------------------------------------------------
plugin_home_repair() {
  local dir="$CLAUDE_HOME/plugins"
  [ -d "$dir" ] || return 0
  local repaired="" f tmp
  for f in "$dir/known_marketplaces.json" "$dir/installed_plugins.json"; do
    [ -f "$f" ] || continue
    # mktemp in the registry's OWN directory: an exclusive create beats the
    # predictable "$f.seed.$$", and staying on the same filesystem is what keeps
    # the later rename atomic rather than a copy.
    tmp="$(mktemp "$f.seed.XXXXXX" 2>/dev/null)" || continue
    sed -E "s#(/root|/home/[^\"/]+)(/\.(claude|dotfiles))#${SEED_HOME}\2#g" \
      "$f" >"$tmp" 2>/dev/null || {
      rm -f "$tmp"
      continue
    }
    if cmp -s "$f" "$tmp"; then
      rm -f "$tmp"
      continue
    fi
    # Validate BEFORE replacing: a truncated or malformed registry is worse than
    # a stale one — Claude fails to start rather than reporting cache-miss. No
    # jq means no way to know which one we produced, so skip rather than write
    # unverified: the un-repaired registry still works, just with cache-miss.
    if ! command -v jq >/dev/null 2>&1; then
      echo "⚠️  seed: jq unavailable — cannot verify rewritten $(basename "$f"), leaving original"
      rm -f "$tmp"
      continue
    fi
    if ! jq -e . "$tmp" >/dev/null 2>&1; then
      echo "⚠️  seed: rewritten $(basename "$f") is not valid JSON — leaving original"
      rm -f "$tmp"
      continue
    fi
    # Carry owner+mode onto the temp file, then rename. `cat >"$f"` would
    # preserve them by writing through the inode, but it truncates first: an
    # interrupt mid-write leaves a half-written registry with no way back.
    # rename(2) is atomic, so the file is either fully old or fully new.
    #
    # Both must hold. Renaming a temp file that kept the seed user's owner or a
    # default mode hands the registry to the wrong identity, and Claude then
    # cannot write it — the same cache-miss symptom this function exists to fix,
    # now permanent. A stale registry is the better failure.
    #
    # chown FAILING is not itself the problem, though: a non-root seed cannot
    # call chown(2) at all on some kernels, yet mktemp already created the file
    # as that same user, so the ownership is right anyway. Test the outcome, not
    # the exit status — that covers the root and non-root seeds with one branch.
    if ! chown --reference="$f" "$tmp" 2>/dev/null &&
      [ "$(stat -c '%u:%g' "$tmp" 2>/dev/null)" != "$(stat -c '%u:%g' "$f" 2>/dev/null)" ]; then
      echo "⚠️  seed: could not carry owner onto $(basename "$f") — leaving original"
      rm -f "$tmp"
      continue
    fi
    if ! chmod --reference="$f" "$tmp" 2>/dev/null; then
      echo "⚠️  seed: could not carry mode onto $(basename "$f") — leaving original"
      rm -f "$tmp"
      continue
    fi
    # A failed rename leaves the ORIGINAL in place, which is the safe outcome —
    # but say so. Silence here is indistinguishable from "nothing needed
    # repairing", and $repaired stays empty either way, so the next start would
    # be the only hint. Not stamping is handled by the caller; this just has to
    # not claim success.
    if mv -f "$tmp" "$f"; then
      repaired="$repaired $(basename "$f")"
    else
      echo "⚠️  seed: could not replace $(basename "$f") — original left intact, retrying next start"
    fi
    rm -f "$tmp"
  done
  # Same fallout: ~/.claude symlinks aimed at the dead home. Match the TARGET
  # against the legacy-home pattern — a bare "is it dangling" test also deletes
  # the user's own broken symlinks, which this script has no business touching.
  # Use `if`, not a trailing && chain: under `set -e` a loop body ending false
  # kills the script, and on a fresh volume nothing matches, so that is NORMAL.
  local link target
  for link in "$CLAUDE_HOME"/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      "$SEED_HOME"/*) ;; # correct home: not ours to judge
      /root/.claude/* | /root/.dotfiles/* | \
        /home/*/.claude/* | /home/*/.dotfiles/*)
        rm -f "$link"
        repaired="$repaired $(basename "$link")"
        ;;
    esac
  done
  [ -n "$repaired" ] && echo "🌱 seed: repaired stale home paths in plugin registry:$repaired"
  return 0
}
plugin_home_repair

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

  # Register the GitHub-hosted marketplaces that settings.json's `enabledPlugins`
  # refers to. A marketplace that is enabled but never registered fails with the
  # SAME `cache-miss` string as a stale path (signal 7) for an unrelated reason,
  # so fix both or the errors only half clear. The authored ~/.claude allowlist
  # deliberately excludes plugins/ (hundreds of MB), so this cannot arrive by copy.
  #
  # Correctly gated: target persists in the volume, source is this template.
  # List "registry-name repo" pairs explicitly — the key comes from the
  # marketplace MANIFEST, not the repo path (techwolf-ai/ai-first-toolkit
  # registers as `techwolf-ai-first`), so it cannot be derived, and a guard that
  # guesses it never matches and re-adds on every single seed.
  # Probed as SEED_USER, not as whoever runs the seed: the CLI installs into
  # $SEED_HOME/.local/bin, which is not on root's PATH, so a root-run seed asking
  # `command -v claude` gets "no" while the user's shell finds it fine. And an
  # unavailable CLI clears MARKETPLACE_OK rather than silently skipping — skipping
  # stamps the sentinel, and the gated block then never retries the registration.
  if as_user sh -c 'command -v claude >/dev/null 2>&1'; then
    mp_registry="$CLAUDE_HOME/plugins/known_marketplaces.json"
    while read -r mp_name mp_repo; do
      [ -n "$mp_name" ] || continue
      # Exact top-level key, not a substring of arbitrary file text: a plain grep
      # for "name" also matches it inside a description, a plugin entry, or
      # another marketplace's nested JSON, and then silently skips registration.
      # No jq (or unreadable/invalid JSON) => fall through and register; adding an
      # already-present marketplace is idempotent, skipping a missing one is not.
      if [ -f "$mp_registry" ] && command -v jq >/dev/null 2>&1 &&
        jq -e --arg n "$mp_name" 'type == "object" and has($n)' \
          "$mp_registry" >/dev/null 2>&1; then
        continue
      fi
      echo "🌱 seed: registering marketplace $mp_name ($mp_repo)"
      as_user claude plugin marketplace add "$mp_repo" >/dev/null 2>&1 || {
        MARKETPLACE_OK=0
        echo "⚠️  seed: could not register $mp_repo (needs network) — NOT stamping sentinel"
      }
    done <<'MARKETPLACES'
claude-plugins-official anthropics/claude-plugins-official
MARKETPLACES
  else
    MARKETPLACE_OK=0
    echo "⚠️  seed: claude CLI not on $SEED_USER's PATH — marketplaces not registered, NOT stamping sentinel"
  fi

  # Stamp the sentinel with the current version, but only on a clean run.
  if [ "$MARKETPLACE_OK" -eq 1 ]; then
    printf '%s\n' "$SEED_VERSION" | as_user tee "$SENTINEL" >/dev/null
    echo "🌱 seed: done (v$SEED_VERSION)"
  else
    # Record the failure but do NOT exit here. This script is itself the compose
    # `command:` — it exec's the base command from the dispatch below — so an
    # early exit means the container never starts at all. A degraded container
    # the user can debug beats one that will not boot, and the unstamped
    # sentinel already guarantees the next launch retries. The failure is
    # reported on stderr and, when no base command is dispatched, surfaces as a
    # non-zero exit. A missing installer stays non-fatal; only an installer that
    # ran and failed reports an error.
    SEED_FAILED=1
    echo "❌ seed: marketplace install failed (sentinel left at previous version)" >&2
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
  # No base command to hand off to, so this exit status is the only channel the
  # seed failure has left. With a base command, exec replaces this process and
  # the container runs degraded by design.
  "") exit "$SEED_FAILED" ;;
  *)
    printf 'seed: unknown command mode: %s\n' "$1" >&2
    exit 2
    ;;
esac
