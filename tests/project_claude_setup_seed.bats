#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test

  REFERENCE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md"
  SKILL_DOC="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md"
  SEED_SCRIPT="$TEST_ROOT/local-seed.sh"
  SUDO_LOG="$TEST_ROOT/sudo.log"
  export REFERENCE SKILL_DOC SEED_SCRIPT SUDO_LOG

  mkdir -p "$TEST_ROOT/host-seed/.claude" \
    "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace" \
    "$HOME/.claude" "$HOME/.dotfiles"

  # The seed script now routes several commands through $SUDO, not just chown.
  # Log every invocation, emit the ownership-repair event for chown (which the
  # assertions key on), and otherwise run the command as the current user.
  cat >"$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SUDO_LOG"
[ "${1:-}" = -u ] && { shift 2; }
if [ "${1:-}" = chown ]; then
  printf 'test-event: ownership repaired\n'
  shift
  [ "${1:-}" = -R ] && shift
  shift
  chmod -R u+rwX "$@"
  exit 0
fi
exec "$@"
EOF
  chmod +x "$STUB_BIN/sudo"

  # The seed hard-fails when it cannot make zsh the login shell, because a silent
  # skip in a real container leaves a bash terminal that bypasses the Vekil
  # proxy. A test sandbox cannot rewrite the runner's /etc/passwd, so the login
  # shell is faked through a state file: it starts as bash (what a fresh
  # container and the CI runner both look like) and the chsh stub rewrites it.
  # Reporting zsh unconditionally would be wrong — the seed would take the no-op
  # branch and neither the chsh path nor its failure path would ever run, which
  # is exactly how a broken fatal-exit shipped green from a developer machine.
  SHELL_STATE="$TEST_ROOT/login-shell"
  export SHELL_STATE
  printf '/bin/bash\n' >"$SHELL_STATE"

  cat >"$STUB_BIN/chsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# chsh -s <shell> <user>
[ "${1:-}" = -s ] || exit 1
printf '%s\n' "$2" >"$SHELL_STATE"
exit 0
EOF
  chmod +x "$STUB_BIN/chsh"

  # Only passwd field 7 is synthesized, from the state file; everything else
  # passes through to the real getent.
  cat >"$STUB_BIN/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = passwd ]; then
  line="$(/usr/bin/getent passwd "${2:-}")" || exit 2
  printf '%s\n' "$line" | awk -F: -v OFS=: -v s="$(cat "$SHELL_STATE")" '{$7=s; print}'
  exit 0
fi
exec /usr/bin/getent "$@"
EOF
  chmod +x "$STUB_BIN/getent"

  ZSH_STUB_PATH="$(command -v zsh || true)"
  if [ -z "$ZSH_STUB_PATH" ]; then
    ZSH_STUB_PATH="$STUB_BIN/zsh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$ZSH_STUB_PATH"
    chmod +x "$ZSH_STUB_PATH"
  fi
  export ZSH_STUB_PATH

  extract_seed_script
}

teardown() {
  chmod -R u+rwX "$HOME/.claude" "$HOME/.dotfiles" 2>/dev/null || true
}

extract_seed_script() {
  awk '
    /^Write the seed script at `\{SEED_SCRIPT\}`/ { found = 1; next }
    found && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$REFERENCE" >"$SEED_SCRIPT"
  [ -s "$SEED_SCRIPT" ] || {
    echo "extract_seed_script: no bash block found — the anchor sentence in" \
      "$REFERENCE changed; update this awk pattern" >&2
    return 1
  }

  # This PR moved the seed script off $HOME onto an explicit SEED_USER/SEED_HOME
  # pair. SEED_USER is templated as {USER}; left unsubstituted, `id -u "{USER}"`
  # aborts the whole script under `set -euo pipefail` before any assertion runs.
  # SEED_HOME is resolved from passwd at runtime, which would resolve to the
  # real home rather than the sandbox, so it is pinned to $HOME for the test.
  sed -i \
    -e "s|^SEED_USER=\"{USER}\"|SEED_USER=\"$(id -un)\"|" \
    -e "s|^SEED_HOME=\"\$(getent passwd .*|SEED_HOME=\"$HOME\"|" \
    -e "s|SEED_CLAUDE=\"/host-seed/.claude\"|SEED_CLAUDE=\"$TEST_ROOT/host-seed/.claude\"|" \
    -e "s|SEED_DOTFILES=\"/host-seed/.dotfiles\"|SEED_DOTFILES=\"$TEST_ROOT/host-seed/.dotfiles\"|" \
    "$SEED_SCRIPT"
}

@test "fresh named-volume mountpoints are made writable and seeded" {
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"
  chmod 500 "$HOME/.claude" "$HOME/.dotfiles"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  grep -F "chown -R $(id -u):$(id -g)" "$SUDO_LOG"
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [ -f "$HOME/.claude/.seeded" ]
}

@test "ownership is repaired before a stale sentinel skips seeding" {
  local vekil_hook='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"
  [ -n "$seed_version" ]

  printf '%s\n' "$seed_version" >"$HOME/.claude/.seeded"
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"
  chmod 000 "$HOME/.claude" "$HOME/.dotfiles"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  grep -F "chown -R $(id -u):$(id -g)" "$SUDO_LOG"
  [ ! -e "$HOME/.claude/settings.json" ]
  # ~/.dotfiles is mirrored above the sentinel gate on purpose: the installers
  # live under it, so a warm restart must still get a current tree. Only the
  # ~/.claude copies and the installers themselves are gated.
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [[ "$output" == *"test-event: ownership repaired"*"already seeded"* ]]

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc "$vekil_hook" "$HOME/.zshrc")" -eq 1 ]
}

@test "an empty legacy sentinel migrates once and is then stamped" {
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"
  [ -n "$seed_version" ]

  # Pre-versioning contract: a bare touch-file. It cannot prove the versioned
  # copy/install steps ever ran, so it must not be accepted as current.
  touch "$HOME/.claude/.seeded"
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"migrating legacy unstamped sentinel"* ]]
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [ "$(cat "$HOME/.claude/.seeded")" = "$seed_version" ]

  # Second run matches on version and skips the gated steps.
  rm -f "$HOME/.claude/settings.json"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already seeded (v$seed_version)"* ]]
  [ ! -e "$HOME/.claude/settings.json" ]
}

@test "a stale stamped sentinel is reseeded and restamped" {
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"
  [ -n "$seed_version" ]

  # Distinct from both the empty-sentinel migration and the matching-version
  # skip: a real but older version must re-run the gated steps.
  printf '%s\n' "$((seed_version - 1))" >"$HOME/.claude/.seeded"
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"seeding to v$seed_version"* ]]
  [[ "$output" != *"migrating legacy unstamped sentinel"* ]]
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [ "$(cat "$HOME/.claude/.seeded")" = "$seed_version" ]
}

@test "reseeding replaces directory contents without nesting" {
  mkdir -p "$TEST_ROOT/host-seed/.claude/commands"
  printf 'current\n' >"$TEST_ROOT/host-seed/.claude/commands/live.md"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/commands/live.md" ]

  # Force a second gated run against the now-populated destination.
  printf '0\n' >"$HOME/.claude/.seeded"
  printf 'stale\n' >"$HOME/.claude/commands/removed-from-host.md"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/commands/commands" ]
  [ ! -e "$HOME/.claude/commands/removed-from-host.md" ]
  [ -f "$HOME/.claude/commands/live.md" ]
}

@test "config removed from the host is pruned from the persisted volume" {
  # The destination lives in the persisted claude-local-home named volume, so a
  # source the host DELETED must be cleared on the next gated reseed. Pruning
  # only inside an `if source exists` guard never fires for a deleted source and
  # leaves the stale copy behind forever.
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  mkdir -p "$TEST_ROOT/host-seed/.claude/skills"
  printf 'doomed\n' >"$TEST_ROOT/host-seed/.claude/skills/going-away.md"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.claude/skills/going-away.md" ]

  # Marketplace-installed plugins are NOT seed-owned and must survive the prune.
  mkdir -p "$HOME/.claude/plugins"
  printf 'keep\n' >"$HOME/.claude/plugins/installed.json"

  # The host drops both entries, then a version bump forces a gated reseed.
  rm -f "$TEST_ROOT/host-seed/.claude/settings.json"
  rm -rf "$TEST_ROOT/host-seed/.claude/skills"
  printf '0\n' >"$HOME/.claude/.seeded"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json" ]
  [ ! -e "$HOME/.claude/skills" ]
  [ -f "$HOME/.claude/plugins/installed.json" ]
}

@test "removing the whole seed mount prunes authored config but keeps plugins" {
  printf '{}\n' >"$TEST_ROOT/host-seed/.claude/settings.json"
  mkdir -p "$TEST_ROOT/host-seed/.claude/commands"
  printf 'doomed\n' >"$TEST_ROOT/host-seed/.claude/commands/gone.md"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/settings.json" ]
  [ -f "$HOME/.claude/commands/gone.md" ]

  mkdir -p "$HOME/.claude/plugins"
  printf 'keep\n' >"$HOME/.claude/plugins/installed.json"

  # The entire mount disappears — the limiting case of deleting every file.
  rm -rf "$TEST_ROOT/host-seed/.claude"
  printf '0\n' >"$HOME/.claude/.seeded"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json" ]
  [ ! -e "$HOME/.claude/commands" ]
  [ -f "$HOME/.claude/plugins/installed.json" ]
}

@test "the installed zsh hook loads Vekil endpoints and the Codex wrapper" {
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/ai/vekil"
  cp "$REPO_ROOT/ai/vekil/env.zsh" \
    "$TEST_ROOT/host-seed/.dotfiles/ai/vekil/env.zsh"
  stub_command curl 'exit 0'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]

  run env \
    -u OPENAI_BASE_URL -u OPENAI_API_KEY \
    -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_MODEL \
    -u VEKIL_MANAGED_OPENAI_BASE_URL -u VEKIL_MANAGED_OPENAI_API_KEY \
    -u VEKIL_MANAGED_ANTHROPIC_BASE_URL -u VEKIL_MANAGED_ANTHROPIC_API_KEY \
    -u VEKIL_MANAGED_ANTHROPIC_MODEL \
    HOME="$HOME" PATH="$PATH" REMOTE_CONTAINERS=true \
    zsh -dic 'print -r -- "OPENAI_BASE_URL=$OPENAI_BASE_URL"; print -r -- "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"; whence -w codex'

  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENAI_BASE_URL=http://host.docker.internal:1337/v1"* ]]
  [[ "$output" == *"ANTHROPIC_BASE_URL=http://host.docker.internal:1337"* ]]
  [[ "$output" == *"codex: function"* ]]
}

@test "a failed marketplace install leaves the sentinel unstamped" {
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"

  # A stamped sentinel over a half-installed ~/.claude/plugins would make every
  # later launch skip the repair, so a failing installer must not stamp.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace"
  printf '#!/usr/bin/env bash\nexit 1\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"
  chmod +x "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"

  run bash "$SEED_SCRIPT"

  # A failed install must report non-zero, not just decline to stamp.
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT stamping sentinel"* ]]
  [ ! -e "$HOME/.claude/.seeded" ]

  # Once the installer succeeds, the stamp lands and the gate engages. The
  # replacement must differ in size from the failing stub: rsync -a compares
  # size+mtime, so a same-size rewrite inside the same second is not mirrored.
  printf '#!/usr/bin/env bash\n# now succeeds\nexit 0\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"
  chmod +x "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/.seeded")" = "$seed_version" ]
}

@test "tracked devcontainer files are explicitly inspection-only" {
  local permitted='The only permitted devcontainer writes are the gitignored `docker-compose.override.yml`, `local-seed.sh`, the user-approved `dockerComposeFile` entry in `devcontainer.json`, and `.git/info/exclude` entries needed for the two local files.'
  local initial='Capture the initial `git status --short` output before any write, **and a copy of the tracked `devcontainer.json` content**'
  local final='At final verification, run `git status --short` and compare its output byte-for-byte with the initial snapshot, **and diff `devcontainer.json` against the captured copy**.'
  local document

  for document in "$SKILL_DOC" "$REFERENCE"; do
    grep -Fqx "$permitted" "$document"
    # Substring, not whole-line: both sentences carry trailing rationale prose.
    grep -Fq "$initial" "$document"
    grep -Fq "$final" "$document"
    # The sanctioned exception must stay narrow: one approved key, nothing else.
    grep -Fq 'Never edit a project Dockerfile or a base Compose file.' "$document"
  done

  # The Dockerfile prohibition is worded differently in each document, so it is
  # asserted per-document rather than through one shared exact-match string.
  grep -Fqx 'Never edit a project Dockerfile or a base Compose file. Never edit `.devcontainer/devcontainer.json` **except** for the single user-approved change of adding `docker-compose.override.yml` to the `dockerComposeFile` array (Section 6c) — and even then, touch no other key. That edit only happens after the user explicitly approves it, knowing it is a tracked change.' "$SKILL_DOC"
  grep -Fqx 'Never edit a project Dockerfile or a base Compose file. Never edit `devcontainer.json` except for the user-approved `dockerComposeFile` entry above — and never touch any other key in it.' "$REFERENCE"
}

@test "a bash login shell is switched to zsh" {
  # The starting state of both a fresh container and the CI runner. Asserting
  # the state file changed proves the chsh branch actually ran, rather than the
  # seed short-circuiting on an already-zsh shell as it does on a dev machine.
  [ "$(cat "$SHELL_STATE")" = /bin/bash ]

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"default shell to zsh"* ]]
  [ "$(cat "$SHELL_STATE")" = "$ZSH_STUB_PATH" ]
}

@test "an already-zsh login shell is left alone" {
  printf '%s\n' "$ZSH_STUB_PATH" >"$SHELL_STATE"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"default shell to zsh"* ]]
}

@test "a missing zsh aborts the seed instead of leaving a bash terminal" {
  # Vekil's env.zsh is zsh-only. Continuing here would produce a container whose
  # terminal silently bypasses the proxy — the failure this check exists to
  # prevent — so the seed must stop and say why. zsh cannot be uninstalled, so
  # run against a PATH that mirrors the real one minus zsh.
  local nozsh="$TEST_ROOT/nozsh"
  mkdir -p "$nozsh"
  local entry
  for entry in /usr/bin/* /bin/*; do
    case "${entry##*/}" in
      zsh | zsh?*) continue ;;
    esac
    ln -sf "$entry" "$nozsh/${entry##*/}" 2>/dev/null || true
  done
  [ ! -e "$nozsh/zsh" ]

  PATH="$STUB_BIN:$nozsh" run bash "$SEED_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"zsh not found"* ]]
}

@test "an unchangeable login shell aborts the seed" {
  # chsh fails and /etc/passwd is not writable (the seed runs unprivileged).
  # Previously this was a non-fatal warning, which let a proxy-bypassing
  # container look like a successful seed.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_BIN/chsh"
  chmod +x "$STUB_BIN/chsh"
  [ "$(cat "$SHELL_STATE")" = /bin/bash ]

  run bash "$SEED_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not set"*"login shell to zsh"* ]]
  [ "$(cat "$SHELL_STATE")" = /bin/bash ]
}

@test "every documented bash block is syntactically valid" {
  # These blocks are meant to be copy-pasted. A block that cannot even parse
  # ships a broken command to whoever runs it, and nothing else in this suite
  # would notice — the seed-script tests only extract one specific block.
  # Fill-in values are written as shell variables assigned to a <placeholder>
  # string, so the block still parses while remaining obviously templated.
  local document block_file total=0
  block_file="$TEST_ROOT/block.sh"

  for document in "$SKILL_DOC" "$REFERENCE"; do
    local count
    count="$(awk '/^```bash$/ {n++} END {print n + 0}' "$document")"
    [ "$count" -gt 0 ]
    local i
    for ((i = 1; i <= count; i++)); do
      awk -v want="$i" '
        /^```bash$/ { n++; if (n == want) { inb = 1; next } }
        inb && /^```$/ { exit }
        inb { print }
      ' "$document" >"$block_file"
      run bash -n "$block_file"
      if [ "$status" -ne 0 ]; then
        echo "block #$i in $document does not parse:" >&2
        cat "$block_file" >&2
        echo "$output" >&2
        return 1
      fi
      total=$((total + 1))
    done
  done

  [ "$total" -ge 10 ]
}

@test "login-shell troubleshooting excludes tracked rc and retry-loop changes" {
  grep -F "zsh -lic" "$SKILL_DOC" "$REFERENCE"
  grep -F "Empty endpoint variables or Codex resolving to the raw binary" \
    "$SKILL_DOC" "$REFERENCE"
  run grep -F 'for _ in {1..30}' "$SKILL_DOC" "$REFERENCE"
  [ "$status" -eq 1 ]
  run grep -F 'config_files=($DOTFILES/**/*.zsh)' "$SKILL_DOC" "$REFERENCE"
  [ "$status" -eq 1 ]
}

@test "core.hooksPath is pointed at the mirrored dotfiles git hooks" {
  # The commit-msg hook that strips Co-authored-by trailers reaches the host via
  # a ~/.git-hooks symlink that is never seeded into a container. The seed must
  # configure hooksPath directly, or container commits keep the trailers.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/core/git/git-hooks.symlink"
  printf '#!/bin/sh\nexit 0\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/core/git/git-hooks.symlink/commit-msg"
  chmod +x "$TEST_ROOT/host-seed/.dotfiles/core/git/git-hooks.symlink/commit-msg"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"pointed core.hooksPath at"* ]]

  run git config --global --get core.hooksPath
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.dotfiles/core/git/git-hooks.symlink" ]
  # Ordering guard: the hooks only exist after the ~/.dotfiles mirror runs, so a
  # step placed before it would configure a path that is empty at the time.
  [ -x "$output/commit-msg" ]
}

@test "missing git hooks warn without aborting the seed" {
  # No git-hooks.symlink in the host seed. A missing hook costs one commit
  # trailer, unlike the proxy steps, so it must not take the container down.
  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"global git"* ]]
  [[ "$output" == *"trailers will not be stripped"* ]]
}
