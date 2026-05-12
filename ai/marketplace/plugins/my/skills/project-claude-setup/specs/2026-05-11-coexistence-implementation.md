# Project overlay coexistence — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `ai/marketplace/plugins/my/skills/project-claude-setup/specs/2026-05-11-coexistence-design.md`

**Goal:** Make `my:project-claude-setup` work cleanly on projects that already track CLAUDE.md / AGENTS.md / `.claude/` / `docker-compose.override.yml`, without renaming or shadowing their tracked files.

**Architecture:** Personal overlay master stays in `~/.dotfiles/projects/<slug>/`. Coexistence happens via documented Claude Code mechanisms (`CLAUDE.local.md` + `@~/` import; per-file symlinks in `.claude/`; merged `settings.local.json`; merged `docker-compose.override.yml` via yq). The skill never moves or renames project-tracked files.

**Tech stack:** Bash, jq, yq (mikefarah Go version), Markdown (the SKILL.md itself).

**Verification harness:** Real projects in `~/workspace/`: slabledger (tracked CLAUDE.md + AGENTS.md + `.claude/skills/` + tracked compose override), cronfoundry (mostly bare + a couple tracked commands), headlamp (tracked top-level files, empty .claude/).

---

## File map

| File | Action |
|---|---|
| `core/git/gitignore.symlink` | Modify — add `CLAUDE.local.md` and `AGENTS.local.md` |
| `bin/setup-agent-teams` | Modify — add yq install block (mirror tmux/win32yank pattern) |
| `bin/claude-link-project` | Modify — add `--local-md` mode for `.local.md` import shims, add `--with-claude-dir` per-file mode, split helpers out |
| `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md` | Rewrite — replace prereq #5 abort logic with the new step 5/6/7 control flow |
| `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md` | Modify — explain merge-when-existing behavior; reference yq |

No new files. Each task is one logical unit ending in a commit.

---

## Task 1: Global gitignore additions

**Files:**
- Modify: `core/git/gitignore.symlink`

- [ ] **Step 1: Read the file**

```bash
grep -n -i "claude" core/git/gitignore.symlink
```
Expect to see existing entries for `.claude/` and `CLAUDE.md`.

- [ ] **Step 2: Add the two new patterns**

After the existing `CLAUDE.md` line, add:

```text
CLAUDE.local.md
AGENTS.local.md
```

- [ ] **Step 3: Verify in a project**

```bash
cd ~/workspace/slabledger
touch CLAUDE.local.md AGENTS.local.md
git status --porcelain | grep -E '(CLAUDE|AGENTS)\.local\.md'
```
Expected: no output (both files ignored by global gitignore).
Then: `rm CLAUDE.local.md AGENTS.local.md`.

- [ ] **Step 4: Commit**

```bash
cd ~/.dotfiles
git add core/git/gitignore.symlink
git commit -m "gitignore: ignore CLAUDE.local.md and AGENTS.local.md

These are the documented per-project personal-notes channels; the
project-claude-setup skill will create them as import shims into the
dotfiles overlay. Ignore globally so they never show in 'git status'
for any project."
```

---

## Task 2: setup-agent-teams — yq install block

**Files:**
- Modify: `bin/setup-agent-teams`

Mirrors the existing tmux + win32yank pattern. yq is the [mikefarah/yq](https://github.com/mikefarah/yq) Go binary — small static download, idempotent install.

- [ ] **Step 1: Locate the right insertion point**

Read `bin/setup-agent-teams`. The script currently has sections:
- §1 Sanity
- §2 tmux
- §3 win32yank
- §4 tmux.conf clipboard block
- §5 Claude settings deep-merge
- §6 Final verification

Add a new §3.5 for yq, right after win32yank and before the tmux.conf block, so deps cluster together.

- [ ] **Step 2: Pick the yq version**

Pin to a recent stable. As of writing, mikefarah/yq is at v4.x. Use `YQ_VER="v4.45.1"` near the top of the script next to `WIN32YANK_VER`.

Verify the URL pattern works:
```bash
curl -fIsSL https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 | head -1
```
Expected: `HTTP/2 200`. If it 404s, look up the latest tag and update the version pin.

- [ ] **Step 3: Add the install block**

After the win32yank section, insert this section. Match the existing script's idiom (the `info`/`ok`/`confirm`/`die` helpers, the `DRY_RUN` guard, the `command -v` short-circuit):

```bash
# ── 3.5 yq ───────────────────────────────────────────────────────────────────
if command -v yq >/dev/null; then
  # Sanity-check it's the Go version (mikefarah), not the Python one — they
  # have incompatible syntax and we rely on the Go one's merge semantics.
  if yq --version 2>&1 | grep -qi 'mikefarah'; then
    ok "yq already installed: $(yq --version)"
  else
    warn "Found a 'yq' on PATH but it isn't mikefarah/yq (likely the Python kislyuk/yq)."
    warn "The project-claude-setup skill relies on mikefarah's merge semantics."
    warn "Install mikefarah/yq to /usr/local/bin/yq or shadow the existing one in your PATH."
    die  "Aborting to avoid silent breakage."
  fi
else
  url="https://github.com/mikefarah/yq/releases/download/${YQ_VER}/yq_linux_amd64"
  info "yq not found. Will install ${YQ_VER} from:"
  info "  $url"
  info "Steps: curl → chmod +x → sudo mv to /usr/local/bin/yq"
  confirm "Proceed?" || die "Aborted."
  if (( ! DRY_RUN )); then
    tmpfile=$(mktemp); trap 'rm -f "$tmpfile"' EXIT
    curl -fsSL "$url" -o "$tmpfile"
    chmod +x "$tmpfile"
    sudo mv "$tmpfile" /usr/local/bin/yq
  fi
  ok "yq installed: $(yq --version 2>/dev/null || echo '(dry-run)')"
fi
```

And add `YQ_VER="v4.45.1"` next to the existing `WIN32YANK_VER` constant.

- [ ] **Step 4: Update the verification block**

In §6, add a yq line next to the tmux/win32yank/claude-settings lines:

```bash
echo "yq:        $(command -v yq || echo missing)"
```

- [ ] **Step 5: Lint and dry-run**

```bash
bash -n ~/.dotfiles/bin/setup-agent-teams
~/.dotfiles/bin/setup-agent-teams --dry-run
```

Expected: `bash -n` passes silently. Dry-run reports yq's status (already installed → skips; missing → prints install plan without executing).

- [ ] **Step 6: Real run (optional, if yq isn't installed)**

```bash
command -v yq || ~/.dotfiles/bin/setup-agent-teams
```

If yq isn't there yet, run the installer and confirm the yq prompt. After it finishes:

```bash
yq --version
# Expected: yq (https://github.com/mikefarah/yq/) version v4.45.1
```

- [ ] **Step 7: Commit**

```bash
cd ~/.dotfiles
git add bin/setup-agent-teams
git commit -m "setup-agent-teams: install mikefarah/yq

project-claude-setup will use yq to merge devcontainer
docker-compose.override.yml files structurally rather than text-patch
them. Pin to a known stable version and refuse to proceed if the
incompatible Python kislyuk/yq is on PATH instead."
```

---

## Task 3: claude-link-project — `--local-md` mode

The new behavior: when the project tracks its own `CLAUDE.md` (or `AGENTS.md`), create a 1-line `CLAUDE.local.md` (or `AGENTS.local.md`) in the project root that imports `@~/.dotfiles/projects/<slug>/CLAUDE.md`. Existing `--no-claude-md` flag stays for backward compatibility but is implied by the new auto-detection.

**Files:**
- Modify: `bin/claude-link-project`

- [ ] **Step 1: Read the existing script**

```bash
wc -l ~/.dotfiles/bin/claude-link-project
```
Expected: ~140 lines. Re-read it to understand `link_one`, `unlink_one`, and the `--create` / `--unlink` / default `link` modes.

- [ ] **Step 2: Add a new helper for the import-shim file**

After the existing `link_one()` function, add `write_import_shim()`:

```bash
# Write a 1-line .local.md import shim that pulls in the overlay's master
# file via Claude Code's @~/ import syntax. Idempotent: if the file
# already exists with the correct import line, do nothing.
write_import_shim() {
  local overlay_path="$1"   # e.g. ~/.dotfiles/projects/foo/CLAUDE.md
  local dst="$2"            # e.g. <project>/CLAUDE.local.md

  # Convert overlay_path to a @~/-prefixed form for portability across machines.
  local home_prefix="$HOME/"
  local import_target
  if [[ "$overlay_path" == "$home_prefix"* ]]; then
    import_target="@~/${overlay_path#$home_prefix}"
  else
    import_target="@${overlay_path}"
  fi
  local desired="${import_target}"

  if [[ -L "$dst" ]]; then
    warn "$dst is a symlink — leaving as-is. (Remove it manually if you want a .local.md import shim instead.)"
    return
  fi
  if [[ -e "$dst" ]]; then
    if grep -qxF "$desired" "$dst"; then
      ok "already has import: $dst"
      return
    fi
    warn "$dst exists and doesn't contain the expected import line. Leaving as-is. Add this manually if you want it:"
    warn "  $desired"
    return
  fi

  printf '%s\n' "$desired" > "$dst"
  ok "wrote import shim: $dst -> $desired"
}
```

- [ ] **Step 3: Add new flag handling**

In the `while [[ $# -gt 0 ]]` flag-parsing loop, after `--no-claude-md`, add `--local-md` and `--no-agents-md`:

```bash
    --local-md)       MODE_LOCAL_MD=1; shift ;;
    --no-agents-md)   SKIP_AGENTS_MD=1; shift ;;
```

And at the top with the other defaults:

```bash
MODE_LOCAL_MD=0
SKIP_AGENTS_MD=1   # default-off; AGENTS.local.md is opt-in (see spec)
```

- [ ] **Step 4: Wire the new mode into the link block**

Replace the existing `if (( SKIP_CLAUDE_MD )); then ... else link_one ... fi` block with:

```bash
# CLAUDE.md handling: three paths.
#   --local-md   → write CLAUDE.local.md import shim (project tracks its own CLAUDE.md)
#   --no-claude-md → skip entirely (legacy; equivalent to "user doesn't want a personal CLAUDE.md")
#   default      → symlink overlay's CLAUDE.md into project (no tracked file in the way)
if (( MODE_LOCAL_MD )); then
  write_import_shim "$OVERLAY/CLAUDE.md" "$PROJECT_DIR/CLAUDE.local.md"
elif (( SKIP_CLAUDE_MD )); then
  info "Skipping CLAUDE.md symlink (--no-claude-md). Project keeps its own."
else
  link_one "$OVERLAY/CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
fi

# AGENTS.md handling: only when --local-md AND the user opted into AGENTS too.
# Default off — most users don't keep an AGENTS overlay separately.
if (( MODE_LOCAL_MD && ! SKIP_AGENTS_MD )); then
  if [[ -f "$OVERLAY/AGENTS.md" ]]; then
    write_import_shim "$OVERLAY/AGENTS.md" "$PROJECT_DIR/AGENTS.local.md"
  else
    info "Skipping AGENTS.local.md — no overlay AGENTS.md at $OVERLAY/AGENTS.md."
  fi
fi
```

- [ ] **Step 5: Update the `--create` scaffold to also write an empty AGENTS.md placeholder when `--with-agents-md` is set**

(Optional, but keeps the overlay-master pattern consistent.) In the create block, after writing `CLAUDE.md`:

```bash
if (( MODE_LOCAL_MD )) && (( ! SKIP_AGENTS_MD )); then
  : > "$OVERLAY/AGENTS.md"
  ok "Scaffolded empty $OVERLAY/AGENTS.md (for AGENTS.local.md import)"
fi
```

But really, the skill will create these files explicitly in its flow — keep `--create` minimal. **Skip this step unless we hit a real need.** Mark this step as N/A and move on. ✅ done.

- [ ] **Step 6: Update usage text**

The usage banner at the top of the script (lines 8-12 in the current version) needs the new flags documented:

```text
# Usage:
#   claude-link-project <project-dir>          # link CLAUDE.md + .claude/
#   claude-link-project --unlink <project-dir> # remove symlinks
#   claude-link-project --create <project-dir> # scaffold overlay + link
#   claude-link-project --local-md <project-dir>      # use CLAUDE.local.md import shim instead of symlinking CLAUDE.md
#   claude-link-project --no-claude-md <project-dir>  # skip CLAUDE.md entirely (legacy)
#   claude-link-project --local-md --no-agents-md=0   # also write AGENTS.local.md import shim
```

(The negative-flag form `--no-agents-md=0` is awkward — leave it implicit and document that AGENTS.local.md is opt-in via the skill, not the CLI. Drop the third example line above and keep just the first four. ✅)

- [ ] **Step 7: Add an integration test**

Run against a throwaway test project. Steps:

```bash
mkdir -p /tmp/cltest && cd /tmp/cltest && git init -q
echo "# project's tracked CLAUDE.md" > CLAUDE.md
git add CLAUDE.md && git commit -q -m "init"

# Use --create --local-md against this dir
~/.dotfiles/bin/claude-link-project --create --local-md /tmp/cltest

# Verify
ls -la /tmp/cltest/CLAUDE.md /tmp/cltest/CLAUDE.local.md
cat /tmp/cltest/CLAUDE.local.md
# Expected: tracked CLAUDE.md untouched (real file, not symlink),
#           CLAUDE.local.md is a 1-line file with @~/.dotfiles/projects/cltest/CLAUDE.md

cd ~ && rm -rf /tmp/cltest ~/.dotfiles/projects/cltest
```

- [ ] **Step 8: Lint**

```bash
bash -n ~/.dotfiles/bin/claude-link-project
```

- [ ] **Step 9: Commit**

```bash
cd ~/.dotfiles
git add bin/claude-link-project
git commit -m "claude-link-project: add --local-md import shim mode

When a project tracks its own CLAUDE.md (or AGENTS.md), we can't
symlink the overlay on top without shadowing the project's file.
--local-md writes a 1-line CLAUDE.local.md that imports the overlay's
master via Claude Code's @~/ import syntax instead. The .local.md file
is gitignored globally so it stays out of the project repo.

The legacy --no-claude-md flag is preserved for callers that don't
want any personal CLAUDE-channel for the project."
```

---

## Task 4: claude-link-project — per-file `.claude/` symlinks

When the project already has a `.claude/` directory (tracked or not), don't symlink the directory wholesale — symlink each personal item individually into it.

**Files:**
- Modify: `bin/claude-link-project`

- [ ] **Step 1: Add the `--claude-dir-per-file` flag**

In the flag loop, after `--local-md`:

```bash
    --claude-dir-per-file) MODE_CLAUDE_PER_FILE=1; shift ;;
```

Default at top:

```bash
MODE_CLAUDE_PER_FILE=0
```

- [ ] **Step 2: Add a helper to walk the overlay's `.claude/` and link each leaf**

After `write_import_shim`, add:

```bash
# For each file under <overlay>/.claude/, create a per-file symlink at
# the analogous path inside <project>/.claude/, creating intermediate
# directories as needed. Skips files that already exist at the target
# unless they're symlinks pointing into our overlay (idempotent re-run).
#
# settings.local.json is special-cased: merged (via jq) instead of
# symlinked, because the project may have its own untracked
# settings.local.json the user wants preserved.
link_claude_dir_per_file() {
  local overlay_dir="$1"     # ~/.dotfiles/projects/<slug>/.claude
  local project_dir="$2"     # <project>/.claude

  [[ -d "$overlay_dir" ]] || { warn "no overlay .claude/ at $overlay_dir, nothing to link"; return; }

  mkdir -p "$project_dir"

  # Find regular files in the overlay .claude/ tree.
  while IFS= read -r -d '' src; do
    rel="${src#$overlay_dir/}"
    dst="$project_dir/$rel"

    # settings.local.json: merge, don't symlink.
    if [[ "$rel" == "settings.local.json" ]]; then
      merge_settings_local_json "$src" "$dst"
      continue
    fi

    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
      cur="$(readlink "$dst")"
      if [[ "$cur" == "$src" ]]; then
        ok "already linked: $dst"
        continue
      fi
      warn "$dst is a symlink to $cur — leaving as-is."
      continue
    fi
    if [[ -e "$dst" ]]; then
      # Real file at the target. If it's tracked, that's a collision
      # the user must resolve by renaming their overlay item.
      if git -C "$(dirname "$project_dir")" ls-files --error-unmatch -- "${dst#$(dirname "$project_dir")/}" >/dev/null 2>&1; then
        die "Collision: $dst is tracked in git. Rename your overlay item ($src) and re-run."
      fi
      warn "$dst exists (untracked, not a symlink). Skipping — move or remove it manually if you want to link the overlay version."
      continue
    fi
    ln -s "$src" "$dst"
    ok "linked: $dst -> $src"
  done < <(find "$overlay_dir" -type f -print0)
}
```

- [ ] **Step 3: Add the `merge_settings_local_json` helper**

Above `link_claude_dir_per_file`:

```bash
# Merge personal allowlist entries from overlay's settings.local.json
# into the project's settings.local.json. jq dedupes the merged allow
# array while preserving insertion order. If the project file is
# tracked, the merge still happens but the function warns that the
# change will appear in 'git diff'.
merge_settings_local_json() {
  local src="$1"  # overlay master
  local dst="$2"  # project file (may not exist)

  if [[ ! -f "$src" ]]; then
    info "no overlay settings.local.json at $src, skipping"
    return
  fi

  if [[ ! -e "$dst" ]]; then
    # No project file — just copy and symlink, equivalent to the simple case.
    cp "$src" "$dst"
    ok "wrote: $dst (copied from overlay)"
    return
  fi

  # Both exist. Detect tracked.
  local proj_root tracked=0
  proj_root="$(git -C "$(dirname "$dst")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$proj_root" ]] && git -C "$proj_root" ls-files --error-unmatch -- "${dst#$proj_root/}" >/dev/null 2>&1; then
    tracked=1
  fi

  # Merge: env, permissions.allow (dedupe), top-level keys from overlay.
  local merged
  merged=$(mktemp)
  jq -s '
    .[0] as $dst | .[1] as $src |
    ($dst // {}) * ($src // {}) |
    .permissions = ((.permissions // {}) | . + {
      allow: ((($dst.permissions.allow // []) + ($src.permissions.allow // []))
              | reduce .[] as $x ([]; if index($x) then . else . + [$x] end))
    })
  ' "$dst" "$src" > "$merged"

  if diff -q "$dst" "$merged" >/dev/null; then
    ok "$dst already up to date"
    rm -f "$merged"
    return
  fi

  info "──── proposed diff (settings.local.json) ────"
  diff -u "$dst" "$merged" || true
  echo
  if (( tracked )); then
    warn "Note: $dst is tracked in git — this change will appear in 'git diff' in the project."
    warn "Decide whether to commit, stash, or revert after reviewing."
  fi
  read -r -p "Apply merge to $dst? [y/N] " a
  if [[ "${a:-N}" =~ ^[Yy]$ ]]; then
    cp "$dst" "${dst}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$merged" "$dst"
    ok "Updated: $dst"
  else
    warn "Skipped merge into $dst."
  fi
  rm -f "$merged"
}
```

- [ ] **Step 4: Wire it into the main link flow**

Replace the existing `link_one "$OVERLAY/.claude" "$PROJECT_DIR/.claude"` line with:

```bash
if (( MODE_CLAUDE_PER_FILE )); then
  link_claude_dir_per_file "$OVERLAY/.claude" "$PROJECT_DIR/.claude"
else
  link_one "$OVERLAY/.claude" "$PROJECT_DIR/.claude"
fi
```

- [ ] **Step 5: Update usage**

Add to the usage banner:

```text
#   claude-link-project --claude-dir-per-file <project-dir>
#       Symlink overlay's .claude/ contents file-by-file into project's .claude/
#       instead of symlinking the whole directory. Use when project tracks
#       .claude/ content. settings.local.json gets merged via jq.
```

- [ ] **Step 6: Integration test against a synthetic project**

```bash
mkdir -p /tmp/cltest2/.claude/skills/existing-skill && cd /tmp/cltest2 && git init -q
echo "# tracked skill" > .claude/skills/existing-skill/SKILL.md
echo '{"permissions":{"allow":["Bash(make:*)"]}}' > .claude/settings.local.json
git add . && git commit -q -m "init"

# Scaffold overlay with a personal agent + settings.local.json
mkdir -p ~/.dotfiles/projects/cltest2/.claude/agents
echo "# personal test agent" > ~/.dotfiles/projects/cltest2/.claude/agents/test-runner.md
echo '{"permissions":{"allow":["Bash(go test:*)"]}}' > ~/.dotfiles/projects/cltest2/.claude/settings.local.json

# Run per-file mode (no scaffold since overlay already exists)
~/.dotfiles/bin/claude-link-project --claude-dir-per-file /tmp/cltest2

# Expected:
#   - /tmp/cltest2/.claude/skills/existing-skill/SKILL.md untouched (still real, tracked)
#   - /tmp/cltest2/.claude/agents/test-runner.md symlinked into overlay
#   - /tmp/cltest2/.claude/settings.local.json offered as a merge (you respond y)
#   - merged file has both Bash(make:*) and Bash(go test:*) entries

ls -la /tmp/cltest2/.claude/agents/test-runner.md
jq . /tmp/cltest2/.claude/settings.local.json
git -C /tmp/cltest2 status

# Cleanup
rm -rf /tmp/cltest2 ~/.dotfiles/projects/cltest2
```

- [ ] **Step 7: Lint**

```bash
bash -n ~/.dotfiles/bin/claude-link-project
```

- [ ] **Step 8: Commit**

```bash
cd ~/.dotfiles
git add bin/claude-link-project
git commit -m "claude-link-project: per-file .claude/ symlinks

--claude-dir-per-file mode walks the overlay's .claude/ tree and
symlinks each leaf file into the project's .claude/ at the same
relative path. This lets a personal overlay coexist with a project
that tracks .claude/ content (skills, commands, rules) without
shadowing the tracked files.

settings.local.json is merged via jq instead of symlinked, because the
project may have its own untracked settings.local.json the user wants
to preserve. The merge shows a diff and warns if the file is tracked
(rare but possible)."
```

---

## Task 5: compose-override yq-merge — a helper script

Rather than inlining yq logic in the SKILL.md, write a small helper script the skill can call. Keeps the merge logic testable and reusable.

**Files:**
- Create: `bin/claude-merge-compose-override`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# claude-merge-compose-override
#
# Merge our standard host-mount block into a docker-compose override
# YAML file, in-place. Used by the my:project-claude-setup skill.
#
# Usage:
#   claude-merge-compose-override --service <name> --user <user> [--dry-run] <path-to-override.yml>
#
# Writes our mounts (~/.ssh, ~/.config/gh, ~/.claude, ~/.config/opencode,
# ~/.dotfiles + the parallel ${HOME}:${HOME} mounts) and the agent-teams
# env var into the given service. Shows a diff and asks before writing.
# Idempotent — re-running on a file that already has the mounts is a no-op.

set -euo pipefail

DRY_RUN=0
SERVICE=""
USER_IN_CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)  SERVICE="$2"; shift 2 ;;
    --user)     USER_IN_CONTAINER="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[[ -n "${TARGET:-}" ]]       || { echo "missing target file" >&2; exit 2; }
[[ -n "$SERVICE" ]]          || { echo "--service required" >&2; exit 2; }
[[ -n "$USER_IN_CONTAINER" ]] || { echo "--user required" >&2; exit 2; }

command -v yq >/dev/null || { echo "yq not installed; run setup-agent-teams first" >&2; exit 127; }
yq --version | grep -qi mikefarah || { echo "yq is not mikefarah/yq — merge semantics differ; refusing" >&2; exit 127; }

# Resolve HOME inside the container. For most images, it's /home/<user>;
# for root it's /root.
if [[ "$USER_IN_CONTAINER" == "root" ]]; then
  C_HOME="/root"
else
  C_HOME="/home/$USER_IN_CONTAINER"
fi

# Build the patch document we want to merge in.
PATCH=$(mktemp); trap 'rm -f "$PATCH"' EXIT

cat > "$PATCH" <<EOF
services:
  ${SERVICE}:
    environment:
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1"
    volumes:
      - \${HOME}/.ssh:${C_HOME}/.ssh:cached
      - \${HOME}/.config/gh:${C_HOME}/.config/gh:cached
      - \${HOME}/.claude:${C_HOME}/.claude:cached
      - \${HOME}/.config/opencode:${C_HOME}/.config/opencode:cached
      - \${HOME}/.dotfiles:${C_HOME}/.dotfiles:cached
      # Parallel \${HOME}:\${HOME} mounts so absolute symlinks and
      # absolute paths baked into JSON (e.g. installed_plugins.json's
      # installPath) still resolve inside the container.
      - \${HOME}/.claude:\${HOME}/.claude:cached
      - \${HOME}/.config/opencode:\${HOME}/.config/opencode:cached
      - \${HOME}/.dotfiles:\${HOME}/.dotfiles:cached
EOF

# If target doesn't exist, just write our patch as the new override.
if [[ ! -f "$TARGET" ]]; then
  if (( DRY_RUN )); then
    echo "──── would write to $TARGET ────"
    cat "$PATCH"
    exit 0
  fi
  cp "$PATCH" "$TARGET"
  echo "wrote: $TARGET"
  exit 0
fi

# Both exist — merge. yq's `*+` merge appends arrays, `*=` deep-merges maps.
# We want: append volumes (then dedupe), deep-merge environment, deep-merge services.
MERGED=$(mktemp); trap 'rm -f "$PATCH" "$MERGED"' EXIT

# Step 1: deep-merge with array append.
yq eval-all '
  select(fileIndex == 0) * select(fileIndex == 1) |
  .services |= map_values(
    .volumes = (.volumes // [] | unique)
  )
' "$TARGET" "$PATCH" > "$MERGED"

# Verify it parses.
yq eval '.' "$MERGED" >/dev/null || { echo "merged YAML failed to parse" >&2; exit 1; }

# Show diff. Detect tracked status for warning.
PROJ_ROOT="$(git -C "$(dirname "$TARGET")" rev-parse --show-toplevel 2>/dev/null || true)"
TRACKED=0
if [[ -n "$PROJ_ROOT" ]] && git -C "$PROJ_ROOT" ls-files --error-unmatch -- "${TARGET#$PROJ_ROOT/}" >/dev/null 2>&1; then
  TRACKED=1
fi

if diff -q "$TARGET" "$MERGED" >/dev/null; then
  echo "no changes — $TARGET already has the required mounts and env"
  exit 0
fi

echo "──── proposed diff ────"
diff -u "$TARGET" "$MERGED" || true
echo
if (( TRACKED )); then
  echo "Note: $TARGET is tracked in git — this change will appear in 'git diff'."
  echo "Decide whether to commit, stash, or revert after reviewing."
fi

if (( DRY_RUN )); then
  echo "--dry-run; not writing."
  exit 0
fi

read -r -p "Apply this merge to $TARGET? [y/N] " a
if [[ "${a:-N}" =~ ^[Yy]$ ]]; then
  cp "$TARGET" "${TARGET}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$MERGED" "$TARGET"
  echo "wrote: $TARGET"
else
  echo "Aborted; $TARGET unchanged."
  exit 1
fi
```

- [ ] **Step 2: chmod and lint**

```bash
chmod +x ~/.dotfiles/bin/claude-merge-compose-override
bash -n ~/.dotfiles/bin/claude-merge-compose-override
```

- [ ] **Step 3: Test against an empty target (write path)**

```bash
TMP=$(mktemp); rm -f "$TMP"
~/.dotfiles/bin/claude-merge-compose-override --service app --user node "$TMP"
yq . "$TMP" | head -20
rm -f "$TMP"
```

Expected: file created with the expected mounts under `services.app`.

- [ ] **Step 4: Test against an existing file (merge path)**

```bash
TMP=$(mktemp)
cat > "$TMP" <<EOF
services:
  app:
    volumes:
      - ~/.gh-guarzo:/home/tng/.gh-guarzo:cached
EOF
~/.dotfiles/bin/claude-merge-compose-override --service app --user tng "$TMP"
# Confirm at the prompt with 'y'
yq . "$TMP"
rm -f "$TMP" "$TMP".backup-*
```

Expected: ~/.gh-guarzo mount preserved, our mounts appended, environment added.

- [ ] **Step 5: Idempotency check — re-run on the merged file**

```bash
TMP=$(mktemp)
~/.dotfiles/bin/claude-merge-compose-override --service app --user node "$TMP"
~/.dotfiles/bin/claude-merge-compose-override --service app --user node "$TMP"
# Second run should report "no changes"
rm -f "$TMP"
```

- [ ] **Step 6: Commit**

```bash
cd ~/.dotfiles
git add bin/claude-merge-compose-override
git commit -m "add claude-merge-compose-override helper

yq-based merge of host-mount block into an existing
docker-compose.override.yml (or creation if absent). Shows diff,
warns if the target is tracked in git, backs up on write, idempotent
on re-run. Used by the project-claude-setup skill so it doesn't have
to inline yq logic in SKILL.md."
```

---

## Task 6: SKILL.md rewrite

The largest single edit. Replace the abort-on-tracked-files prereq logic and rewrite Steps 4/5/6 to match the new control flow. Reference the new helper script and `--local-md` flag.

**Files:**
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md`
- Modify: `ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md`

- [ ] **Step 1: Re-read current SKILL.md**

```bash
sed -n '25,45p' ~/.dotfiles/ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md
```
Confirm Prereq #5 is the abort-on-tracked-CLAUDE.md gate that's being replaced.

- [ ] **Step 2: Replace Prereq #5**

Current (lines 31–39):
```
5. **Project doesn't already track CLAUDE.md or AGENTS.md.** Check `git ls-files CLAUDE.md AGENTS.md` and also a plain `ls`. If either file exists as a real (non-symlink) file:
   - ...stop and ask the user which they want:
     - (a) Skip the overlay's CLAUDE.md ...
     - (b) Move the project file out of the way ...
     - (c) Abort ...
```

Replace with:

```markdown
5. **`yq` (mikefarah/yq) available.** `command -v yq` resolves, and `yq --version` mentions `mikefarah`. If missing, point the user at `~/.dotfiles/bin/setup-agent-teams` which installs it. (The Python `kislyuk/yq` has incompatible merge semantics — refuse rather than risk a silent mismerge.)
```

Drop the "what tracked files do we find?" branching from the prereqs entirely — it moves into the per-step logic below.

- [ ] **Step 3: Rewrite Step 3 (create the overlay) to detect tracked files and select the right `claude-link-project` flags**

Replace the current Step 3 body. After the slug-derivation paragraph, the new flow:

```markdown
Detect what the project tracks before calling the helper:

```bash
cd <project>
PROJ_HAS_CLAUDE_MD=0
PROJ_HAS_AGENTS_MD=0
PROJ_CLAUDE_DIR_TRACKED=0
git ls-files --error-unmatch CLAUDE.md   >/dev/null 2>&1 && PROJ_HAS_CLAUDE_MD=1
git ls-files --error-unmatch AGENTS.md   >/dev/null 2>&1 && PROJ_HAS_AGENTS_MD=1
# .claude is "tracked" if git knows about ANY file under it.
git ls-files --error-unmatch -- '.claude/**' >/dev/null 2>&1 && PROJ_CLAUDE_DIR_TRACKED=1
```

Pick the helper flags:

| Detected | Flags to pass |
|---|---|
| Project tracks CLAUDE.md | `--local-md` (writes CLAUDE.local.md import shim) |
| Project tracks AGENTS.md, user wants AGENTS.local.md too | `--local-md` (same flag triggers AGENTS.local.md if `~/.dotfiles/projects/<slug>/AGENTS.md` exists) |
| Project tracks anything under `.claude/` | `--claude-dir-per-file` |
| Project tracks none of the above | no extra flags — legacy symlink-the-whole-thing path |

Then invoke:

```bash
flags=()
(( PROJ_HAS_CLAUDE_MD )) && flags+=(--local-md)
(( PROJ_CLAUDE_DIR_TRACKED )) && flags+=(--claude-dir-per-file)
claude-link-project --create "${flags[@]}" <project-dir>
```
```

(Indented backticked block above is example shell the skill emits / runs; render verbatim in the SKILL.md.)

- [ ] **Step 4: Replace Step 4 ("CLAUDE.md: defer to /init")**

The current Step 4 assumes the overlay's CLAUDE.md is the project's primary CLAUDE.md and tells the user to run `/init`. In the tracked-CLAUDE.md case it's wrong — the project's tracked file is what Claude reads first; the overlay is supplementary.

Rewrite as:

```markdown
## Step 4 — CLAUDE.md content

**When the project tracks its own CLAUDE.md** (the `--local-md` path):

The project's tracked CLAUDE.md is Claude Code's primary instruction file — leave its content alone, it's the team's shared agreement. The overlay's `~/.dotfiles/projects/<slug>/CLAUDE.md` is your *personal* extension, loaded alongside the tracked file via the `CLAUDE.local.md` import shim. Use it for things like:

- Personal preferences ("use my custom test runner alias")
- Local sandbox URLs or credentials hints (no actual secrets)
- Reminders about decisions you keep making that the project doesn't document

Don't put team-relevant rules here — if other contributors would benefit, propose them as a change to the tracked CLAUDE.md.

**When the project does NOT track CLAUDE.md** (the legacy symlink path):

The overlay's CLAUDE.md is the project's primary CLAUDE.md, surfaced into the project tree via symlink. Run `/init` from inside the project (`cd <project> && claude`) to generate content — Claude reads the codebase and writes a starting CLAUDE.md. The output lands at the symlinked path, which routes back to your dotfiles overlay.
```

- [ ] **Step 5: Replace Step 5 ("settings.json: grounded allowlist")**

The current Step 5 writes the personal allowlist into `<overlay>/.claude/settings.json`. With the new design, personal allows always go into `settings.local.json` so they layer on top of any project-shared `settings.json` without conflict.

Rewrite the file path references and the prose:

```markdown
## Step 5 — settings.local.json: grounded allowlist

Personal allowlist entries always land in `settings.local.json`, never in `settings.json`. Claude Code's documented settings layering puts `.local.json` on top of `.json`, and `.local.json` is gitignored by convention — keeping personal allows out of the project repo.

Edit `~/.dotfiles/projects/<slug>/.claude/settings.local.json` (the overlay master; the file in the project tree is either a symlink to this, or a merged copy — see Step 3).

Read the existing file (the placeholder is `{ "permissions": { "allow": [] } }`). Append + dedupe — never replace.

[the rest of the existing per-file table from the current SKILL.md goes here unchanged — that's the inspection-driven allowlist guidance]

For projects that already track their own `.claude/settings.local.json` (rare; usually it's gitignored), `claude-link-project --claude-dir-per-file` merges your overlay's allows into the tracked file via jq, shows a diff, and warns that the change will appear in `git diff`. Decide whether to commit, stash, or revert.
```

(Keep the existing table of "Allow entry / Add when…" rows unchanged.)

- [ ] **Step 6: Rewrite Step 6 ("Compose host mounts") to call the new helper**

Current Step 6 punts to `devcontainer-host-mounts.md` for the template and merge logic. With the new helper, it becomes:

```markdown
## Step 6 — Compose host mounts (case a only)

The host mounts give the container the user's `~/.ssh`, `~/.config/gh`, `~/.claude`, `~/.config/opencode`, `~/.dotfiles` so the symlinked overlay actually resolves inside the container, and so `claude` inside the container reuses the host's auth/plugins/skills.

Use `~/.dotfiles/bin/claude-merge-compose-override` for both the create-new and merge-into-existing cases:

```bash
# Resolve service name and container user from devcontainer.json + base
# compose file (see Step 2 inspection results).
service=<from devcontainer.json or first key under services:>
user=<remoteUser or USER from Dockerfile or base-image default>

override="$(dirname "$(jq -r '.dockerComposeFile | if type=="array" then .[0] else . end' .devcontainer/devcontainer.json | sed 's|^./||')")/docker-compose.override.yml"

claude-merge-compose-override --service "$service" --user "$user" "$override"
```

The helper:
1. Creates the file with our standard mounts if it doesn't exist.
2. Merges our mounts and env var into an existing file, deduping volume mounts, showing a unified diff.
3. Warns if the target is tracked in git ("this change will appear in `git diff`; decide whether to commit, stash, or revert").
4. Refuses if `yq` is missing or is the wrong yq (Python kislyuk vs Go mikefarah).
5. Backs up the original to `<file>.backup-<timestamp>`.

See `devcontainer-host-mounts.md` for the mount table reference (what each mount is for, the parallel `${HOME}:${HOME}` mount explanation, verification commands inside the container).
```

- [ ] **Step 7: Update `devcontainer-host-mounts.md`**

Add a paragraph at the top noting that the merge mechanics are now handled by the `claude-merge-compose-override` helper; this doc is the *reference* for what each mount does and why, not a how-to. Move any prescriptive "write this file by hand" instructions to a "manual fallback" section near the end.

Don't fully rewrite — just add the front-matter pointer and adjust headings so it reads as reference material.

- [ ] **Step 8: Update the "Things to avoid" list at the bottom of SKILL.md**

Current list (line ~226-232) has bullets that are obsolete or need rephrasing. New version:

```markdown
## Things to avoid

- **Don't write CLAUDE.md content.** `/init` does it better for projects that don't track CLAUDE.md. For projects that DO track CLAUDE.md, the overlay is just your personal notes — let the project's tracked CLAUDE.md drive the shared rules.
- **Don't shadow tracked project files.** If the project tracks CLAUDE.md, AGENTS.md, or anything under `.claude/`, never propose renaming or symlinking on top. Use the `.local.md` import-shim and per-file symlink modes instead. This skill enforces this; `claude-link-project --claude-dir-per-file` will refuse on collision.
- **Don't auto-generate agents.** Ask, offer grounded candidates from the inspected stack, generate only the picked ones. On collision with a tracked file, ask the user for a different name — don't auto-prefix.
- **Don't add wildcards to settings.local.json allowlist.** Per-tool, per-command, grounded in inspected facts.
- **Don't clobber existing files in the overlay.** Re-runs should merge or skip.
- **Don't run installers.** `~/.dotfiles/bin/setup-agent-teams` handles host-side setup (tmux, win32yank, yq, settings.json merge).
- **Don't commit changes.** Print commit commands; let the user run them.
```

- [ ] **Step 9: Update the skill's frontmatter `description` if needed**

Re-read the description field and confirm it still reads correctly. Currently it mentions "creates a per-project overlay … and — for compose-based devcontainers — writes a docker-compose.override.yml that mounts host SSH/gh/Claude/dotfiles." Optional tweak: "or merges into an existing one" after "writes". One-line change.

- [ ] **Step 10: Commit**

```bash
cd ~/.dotfiles
git add ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md \
        ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md
git commit -m "project-claude-setup: coexist with tracked project config

Replace the abort-on-tracked-CLAUDE.md prereq with a per-step
classification flow that picks the right claude-link-project flags
(--local-md for CLAUDE.md/AGENTS.md, --claude-dir-per-file for
.claude/) and delegates compose-override merging to the new
claude-merge-compose-override helper.

Behavioral changes from a user perspective:
- Projects with tracked CLAUDE.md no longer require an abort/decision
  prereq; the personal layer goes into CLAUDE.local.md.
- Personal allowlist entries always land in settings.local.json, never
  in the shared settings.json.
- Existing docker-compose.override.yml is merged in place (with diff +
  tracked-file warning) instead of being treated as a conflict."
```

---

## Task 7: Verification on slabledger / cronfoundry / headlamp

Real-project validation. Each project tests a different shape from the spec's verification table.

For each project below:

1. Run the skill (or its helper directly with the right flags).
2. Verify the expected state.
3. Run `git status` inside the project — must be clean.
4. Clean up (remove symlinks/shims, restore project to pre-test state).

- [ ] **Step 1: slabledger (tracked CLAUDE.md + AGENTS.md + tracked `.claude/skills/` + tracked compose override)**

```bash
cd ~/workspace/slabledger
git status   # baseline
flags=(--local-md --claude-dir-per-file)
~/.dotfiles/bin/claude-link-project --create "${flags[@]}" "$PWD"
# Verify:
ls -la CLAUDE.local.md           # exists, contains @~/.dotfiles/projects/slabledger/CLAUDE.md
ls -la CLAUDE.md                  # untouched, real file, tracked
ls -la .claude/skills/csv-import  # untouched (tracked)
ls -la .claude/settings.local.json # symlink OR merged file
git status                         # must be clean (only ignored files)

# Compose override merge:
~/.dotfiles/bin/claude-merge-compose-override \
  --service app --user tng \
  .devcontainer/docker-compose.override.yml
# (review diff, ~/.gh-guarzo mount preserved, our mounts appended, accept with y)
git diff .devcontainer/docker-compose.override.yml
# ← user inspects, decides whether to commit/stash/revert
```

Expected end state: `git status` clean for all non-tracked changes; `git diff` shows the compose merge addition (user decides whether to keep).

- [ ] **Step 2: cronfoundry (mostly bare, `.claude/commands/dogfood-*.md` tracked)**

```bash
cd ~/workspace/cronfoundry
git status
flags=()
# No CLAUDE.md tracked → no --local-md
# But .claude/commands/dogfood-*.md IS tracked → --claude-dir-per-file
git ls-files -- '.claude/**' | head && flags+=(--claude-dir-per-file)
~/.dotfiles/bin/claude-link-project --create "${flags[@]}" "$PWD"
ls -la CLAUDE.md                          # symlink into overlay (legacy path)
ls -la .claude/commands/dogfood-*.md      # untouched
ls -la .claude/settings.local.json        # symlink or merged
git status                                 # clean
```

- [ ] **Step 3: headlamp (tracked CLAUDE.md + AGENTS.md, no tracked `.claude/` content)**

```bash
cd ~/workspace/headlamp
git status
# CLAUDE.md tracked → --local-md
# No .claude tracked → no --claude-dir-per-file (use legacy symlink of .claude/)
# BUT .claude/ already exists with settings.local.json (untracked) → that would
# conflict with directory symlink. Use --claude-dir-per-file anyway when .claude
# directory exists, even if nothing is tracked, to be safe.
flags=(--local-md --claude-dir-per-file)
~/.dotfiles/bin/claude-link-project --create "${flags[@]}" "$PWD"
ls -la CLAUDE.md         # untouched, tracked
ls -la CLAUDE.local.md   # exists, 1 line import
ls -la .claude/          # mix of personal symlinks + project's untracked settings.local.json
git status                # clean
```

- [ ] **Step 4: Cleanup (per project)**

For each project after testing:

```bash
~/.dotfiles/bin/claude-link-project --unlink "$PWD"
# Also remove any .local.md shims (the unlink command currently only removes symlinks)
rm -f CLAUDE.local.md AGENTS.local.md
# Revert compose override merge if you don't want to keep it
git checkout -- .devcontainer/docker-compose.override.yml 2>/dev/null || true
```

If you decide you want to keep an overlay in place, skip the cleanup for that project.

- [ ] **Step 5: Cleanup gap — claude-link-project --unlink should also remove .local.md shims**

If Step 4's `rm -f CLAUDE.local.md AGENTS.local.md` is a permanent papercut, extend the `--unlink` mode of claude-link-project to also delete `CLAUDE.local.md` and `AGENTS.local.md` if they contain only an `@~/.dotfiles/projects/<slug>/...` import line (refuse if they contain other content — user owns it). Small follow-up, not blocking this plan.

Decision: defer to a follow-up commit. Note it in commit message.

- [ ] **Step 6: Final verification commit (if any incidental fixes surfaced)**

If running through Tasks 1–6 surfaced any small bugs (a typo in usage, a missing chmod, etc.), commit them as `fix: address issues found during slabledger/cronfoundry/headlamp verification`. Otherwise no commit is needed — Task 7 is validation only.

---

## Self-review

**Spec coverage check:**

| Spec section | Covered by |
|---|---|
| CLAUDE.local.md + @~/ import | Task 3 (write_import_shim + --local-md mode) |
| Per-file .claude/ symlinks | Task 4 (--claude-dir-per-file) |
| settings.local.json merge with jq dedupe | Task 4 (merge_settings_local_json helper) |
| docker-compose.override.yml yq merge | Task 5 (claude-merge-compose-override script) |
| Tracked-file warning ("appears in git diff") | Tasks 4 and 5 both implement this |
| yq install in setup-agent-teams | Task 2 |
| Global gitignore for *.local.md | Task 1 |
| SKILL.md rewrite per new control flow | Task 6 |
| Verification on slabledger/cronfoundry/headlamp | Task 7 |
| AGENTS.local.md opt-in default | Task 3 step 3 (SKIP_AGENTS_MD=1 default) |
| Agent collision = error | Task 4 link_claude_dir_per_file die-on-collision, Task 6 SKILL.md text |

All spec sections have a task. ✓

**Placeholder scan:** None. Every step has concrete commands or code. The one "decision: defer to a follow-up" in Task 7 Step 5 is explicit and bounded, not a placeholder.

**Type / name consistency check:**
- Helper function names: `write_import_shim`, `link_claude_dir_per_file`, `merge_settings_local_json` — consistent across Tasks 3, 4.
- New flags: `--local-md`, `--claude-dir-per-file`, `--no-agents-md` — referenced consistently.
- Helper script: `claude-merge-compose-override` — same name in Tasks 5 and 6.
- Vars: `MODE_LOCAL_MD`, `MODE_CLAUDE_PER_FILE`, `SKIP_AGENTS_MD`, `SKIP_CLAUDE_MD` — consistent.

No mismatches.

---

## Execution handoff

Plan complete and saved to `ai/marketplace/plugins/my/skills/project-claude-setup/specs/2026-05-11-coexistence-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. Each task here is self-contained (file map + commit boundary), well-suited to one-shot subagent dispatch.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints. Reasonable given task size, but Task 6 (SKILL.md rewrite) is the longest and might benefit from a fresh-context worker.

Which approach?
