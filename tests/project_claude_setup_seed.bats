#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test

  REFERENCE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/devcontainer-host-mounts.md"
  SKILL_DOC="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/SKILL.md"
  SEED_TEMPLATE="$REPO_ROOT/ai/marketplace/plugins/my/skills/project-claude-setup/templates/local-seed.sh"
  SEED_SCRIPT="$TEST_ROOT/local-seed.sh"
  SUDO_LOG="$TEST_ROOT/sudo.log"
  export REFERENCE SKILL_DOC SEED_TEMPLATE SEED_SCRIPT SUDO_LOG

  # The seed publishes a stable root that overlay symlinks target, so they
  # resolve under both the host's $HOME and the container's. In production that
  # is /opt/dotfiles; pin it into the sandbox so the suite never touches /opt.
  export DOTFILES_LINK_ROOT="$TEST_ROOT/opt/dotfiles"

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

  # A real container has the claude CLI installed before the marketplace step,
  # and the seed now refuses to stamp the sentinel when it is missing. The
  # helper sanitizes PATH to $STUB_BIN:/usr/bin:/bin, so without this stub every
  # test would exercise the no-CLI failure path instead of the normal one.
  stub_command claude 'exit 0'

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
  cp "$SEED_TEMPLATE" "$SEED_SCRIPT"

  # This PR moved the seed script off $HOME onto an explicit SEED_USER/SEED_HOME
  # pair. SEED_USER is templated as {USER}; left unsubstituted, `id -u "{USER}"`
  # aborts the whole script under `set -euo pipefail` before any assertion runs.
  # SEED_HOME is resolved from passwd at runtime, which would resolve to the
  # real home rather than the sandbox, so it is pinned to $HOME for the test.
  # WORKSPACE is templated as {WORKSPACE} and rendered by the helper from the
  # workspace the setup skill inspected; the sandbox stands in for it here.
  mkdir -p "$TEST_ROOT/workspace"
  sed -i \
    -e "s|^SEED_USER=\"{USER}\"|SEED_USER=\"$(id -un)\"|" \
    -e "s|^WORKSPACE=\"{WORKSPACE}\"|WORKSPACE=\"$TEST_ROOT/workspace\"|" \
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
  # The authored ~/.claude copy is ALSO above the gate. Its target persists, but
  # its source is the host mount, and SEED_VERSION lives in the template — so a
  # gated copy could never observe a host-side edit and would serve stale config
  # through any number of rebuilds. Asserting absence here encoded that bug.
  [ -f "$HOME/.claude/settings.json" ]
  # ~/.dotfiles is mirrored above the sentinel gate for the same reason, plus the
  # installers live under it, so a warm restart must still get a current tree.
  # Only the installers themselves are gated.
  [ -f "$HOME/.dotfiles/ai/marketplace/marker" ]
  [[ "$output" == *"test-event: ownership repaired"*"already seeded"* ]]

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc "$vekil_hook" "$HOME/.zshrc")" -eq 1 ]
}

@test "argv command dispatch runs after a current sentinel skips gated work" {
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"
  printf '%s\n' "$seed_version" >"$HOME/.claude/.seeded"

  run bash "$SEED_SCRIPT" --argv bash -c \
    'printf "%s\n" "$1" >"$2"' _ 'argument with spaces' "$TEST_ROOT/argv-result"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/argv-result")" = "argument with spaces" ]
}

@test "shell command dispatch receives exactly one command string" {
  run bash "$SEED_SCRIPT" --shell \
    "printf '%s\\n' shell-ran >'$TEST_ROOT/shell-result'"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/shell-result")" = shell-ran ]

  run bash "$SEED_SCRIPT" --shell 'printf first' 'printf second'
  [ "$status" -eq 2 ]
}

@test "seed rejects an unknown command mode" {
  run bash "$SEED_SCRIPT" --unknown

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command mode: --unknown"* ]]
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

  # Second run matches on version and skips the gated INSTALL steps — but the
  # always-run authored-config copy still restores this file, which is the whole
  # point of keeping it above the gate.
  rm -f "$HOME/.claude/settings.json"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already seeded (v$seed_version)"* ]]
  [ -f "$HOME/.claude/settings.json" ]
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

@test "host dotfiles edits reach a warm container on every start" {
  # Regression: ~/.dotfiles used to be seeded only into an EMPTY volume. That
  # volume survives --remove-existing-container, so the tree froze at first-seed
  # state forever. It is the SOURCE of ~/.claude/settings.json (a symlink into
  # it) and of ai/vekil/env.zsh, which exports ANTHROPIC_MODEL -- an env var that
  # OUTRANKS settings.json. So a frozen tree silently overrode the correct model
  # the ~/.claude copy had just written, and rebuilding never helped.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/ai/vekil"
  printf 'export ANTHROPIC_MODEL=old-model\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/vekil/env.zsh"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  grep -Fq 'old-model' "$HOME/.dotfiles/ai/vekil/env.zsh"

  # The host changes the model. No SEED_VERSION bump -- that is the point: the
  # version lives in the template and cannot observe a host-side edit.
  # Differ in LENGTH, not just content: rsync's default quick check is
  # size+mtime at 1-second resolution, so two same-size writes inside the same
  # second are skipped. Real host edits change size or cross a second boundary.
  printf 'export ANTHROPIC_MODEL=claude-opus-5-brand-new\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/vekil/env.zsh"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already seeded"* ]]
  grep -Fq 'claude-opus-5-brand-new' "$HOME/.dotfiles/ai/vekil/env.zsh"
}

@test "dotfiles deleted on the host are pruned from the warm volume" {
  # The always-run installers EXECUTE files from this persisted tree, so a
  # non-pruning refresh would keep running an installer deleted upstream.
  printf 'stale\n' >"$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/doomed.sh"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.dotfiles/ai/marketplace/doomed.sh" ]

  rm -f "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/doomed.sh"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.dotfiles/ai/marketplace/doomed.sh" ]
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

@test "seed refreshes the gitignore list from the workspace it was rendered with" {
  local workspace="$TEST_ROOT/workspace"
  mkdir -p "$workspace/.devcontainer" "$workspace/.claude"
  # The seed sits below the workspace, the shape that used to be discovered by
  # rev-parse; the rendered WORKSPACE is what decides now, not this location.
  mv "$SEED_SCRIPT" "$workspace/.devcontainer/local-seed.sh"
  SEED_SCRIPT="$workspace/.devcontainer/local-seed.sh"
  ln -s /foreign/.dotfiles/projects/demo/agent.md \
    "$workspace/.claude/personal-agent.md"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  grep -Fqx '.claude/personal-agent.md' "$HOME/.gitignore"
}

@test "an unusable workspace warns instead of reporting an empty refresh" {
  # A workspace that is not a directory is a rendering or mount mistake. The old
  # rev-parse fallback made it indistinguishable from a real checkout with no
  # overlay links: both printed "refreshed ... (0 entries)".
  rmdir "$TEST_ROOT/workspace"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a directory"* ]]
  [[ "$output" != *"refreshed ~/.gitignore overlay-symlink list"* ]]
}

@test "a failed marketplace install still starts the container's base command" {
  # This script IS the compose `command:` — it exec's the base command from its
  # own dispatch — so exiting on a failed installer means the container never
  # boots at all. A degraded container the user can debug beats one that will
  # not start, and the unstamped sentinel already forces a retry next launch.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace"
  printf '#!/usr/bin/env bash\nexit 1\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"
  chmod +x "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/install.sh"

  run bash "$SEED_SCRIPT" --argv echo container-started

  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT stamping sentinel"* ]]
  [[ "$output" == *"container-started"* ]]
  [ ! -e "$HOME/.claude/.seeded" ]
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

@test "project setup routes generation through the safe helper and executable templates" {
  local document
  for document in "$SKILL_DOC" "$REFERENCE"; do
    run grep -Fi 'do not use `claude-merge-compose-override`' "$document"
    [ "$status" -eq 1 ]
    run grep -Fi 'do **not** use `claude-merge-compose-override`' "$document"
    [ "$status" -eq 1 ]
  done

  local flag
  for flag in --service --remote-user --remote-home --seed-file \
    --seed-container-path --base-command-json; do
    grep -Fq -- "$flag" "$SKILL_DOC"
  done
  grep -Fq -- '--share-host-auth' "$SKILL_DOC"
  grep -Fq 'default remains no host SSH or gh credentials' "$SKILL_DOC"

  grep -Fq '[Compose skeleton](templates/compose-override.yml)' "$REFERENCE"
  grep -Fq '[seed script](templates/local-seed.sh)' "$REFERENCE"
  grep -Fq '[safe renderer](../../../../../../bin/claude-merge-compose-override)' "$REFERENCE"
  # Exact link text alone only proves the prose was not rewritten. Resolve each
  # target relative to the reference document so moving or renaming a linked
  # file fails here instead of shipping a dead link in the skill.
  local reference_dir target
  reference_dir="$(dirname "$REFERENCE")"
  for target in templates/compose-override.yml templates/local-seed.sh \
    ../../../../../../bin/claude-merge-compose-override; do
    [ -f "$reference_dir/$target" ]
  done
  run grep -F 'Write the seed script at `{SEED_SCRIPT}`' "$REFERENCE"
  [ "$status" -eq 1 ]
  run grep -F 'Use this template, filling in' "$REFERENCE"
  [ "$status" -eq 1 ]
}

@test "legacy remediation and tracked-file guidance have one canonical statement" {
  [ "$(grep -Fc -- '- Inspect the fully merged Compose config' "$SKILL_DOC")" -eq 1 ]
  [ "$(grep -Fc -- '- Optional host cleanup:' "$SKILL_DOC")" -eq 1 ]
  [ "$(grep -Fc -- '- Tell the user to rebuild the container' "$SKILL_DOC")" -eq 1 ]

  local avoid_section
  avoid_section="$(sed -n '/^## Things to avoid$/,$p' "$REFERENCE")"
  [[ "$avoid_section" == *'Never edit a project Dockerfile or a base Compose file.'* ]]
  [[ "$avoid_section" == *'The sole tracked-file exception is the user-approved `dockerComposeFile` entry in `devcontainer.json`.'* ]]
  [[ "$avoid_section" != *'`devcontainer.json`, or base Compose file; they are evidence only'* ]]
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
  local document block_file
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
    done
  done

  run bash -n "$SEED_TEMPLATE"
  [ "$status" -eq 0 ]
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

@test "the stable link root is published and points at the mirrored dotfiles" {
  # Personal overlay symlinks in the workspace store an ABSOLUTE target. Written
  # under the host's $HOME they dangle in the container, taking out .claude/skills,
  # .claude/agents, .claude/references and CLAUDE.md at once. They now target this
  # root, which each environment aims at its own checkout.
  touch "$TEST_ROOT/host-seed/.dotfiles/ai/marketplace/marker"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ -L "$DOTFILES_LINK_ROOT" ]
  [ "$(readlink "$DOTFILES_LINK_ROOT")" = "$HOME/.dotfiles" ]
  # Ordering guard: the root must be published after the mirror, or it names a
  # directory that is still empty when the links are first followed.
  [ -f "$DOTFILES_LINK_ROOT/ai/marketplace/marker" ]
}

@test "the stable link root is re-published on a warm start" {
  # It lives in the container's EPHEMERAL layer and is wiped by every rebuild,
  # while the sentinel persists in a named volume. Gating it would leave a
  # rebuilt container reporting "already seeded" with every overlay link broken.
  local seed_version
  seed_version="$(sed -n 's/^SEED_VERSION=//p' "$SEED_SCRIPT")"
  printf '%s\n' "$seed_version" >"$HOME/.claude/.seeded"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already seeded"* ]]
  [ "$(readlink "$DOTFILES_LINK_ROOT")" = "$HOME/.dotfiles" ]
}

@test "overlay symlinks through the stable root are added to the container gitignore" {
  # The matcher keys on the symlink's target TEXT, since the target is often
  # unresolvable here. A '*/.dotfiles/projects/*' pattern requires a literal
  # dot-prefixed .dotfiles and silently misses every /opt/dotfiles link — which
  # puts personal overlay files, CLAUDE.md included, into container git status.
  mkdir -p "$TEST_ROOT/workspace"
  ln -s "$DOTFILES_LINK_ROOT/projects/demo/.claude/skills" \
    "$TEST_ROOT/workspace/skills-link"
  ln -s "$HOME/.dotfiles/projects/demo/CLAUDE.md" \
    "$TEST_ROOT/workspace/CLAUDE.md"
  sed -i "s|^WORKSPACE=.*|WORKSPACE=\"$TEST_ROOT/workspace\"|" "$SEED_SCRIPT"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]

  grep -Fx 'skills-link' "$HOME/.gitignore"
  grep -Fx 'CLAUDE.md' "$HOME/.gitignore"
}

@test "the seed installs neovim and links its dotfiles config" {
  # The dotfiles set EDITOR=nvim but never install the binary — on a host it
  # arrives via the apt/brew package lists, which no devcontainer image runs.
  # An EDITOR naming a missing command breaks `git commit` with an error that
  # blames git. Guarded on the binary, so this asserts the wiring, not a download.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/config/nvim" "$HOME/.local/bin"
  touch "$TEST_ROOT/host-seed/.dotfiles/config/nvim/init.lua"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/nvim"
  chmod +x "$HOME/.local/bin/nvim"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nvim already present"* ]]
  [ "$(readlink "$HOME/.config/nvim")" = "$HOME/.dotfiles/config/nvim" ]
}

@test "a neovim pin without a checksum skips the install instead of downloading" {
  # The checksum is checked before the download, not left to the verify step: an
  # unpinned SHA can only ever fail `sha256sum -c` after the whole tarball is on
  # disk, once per container start.
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/config"
  printf 'NVIM_VERSION=0.11.0\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/config/versions.env"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"pins no neovim checksum"* ]]
  [[ "$output" != *"installing neovim"* ]]
}

@test "a real ~/.config/nvim is left alone" {
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/config/nvim" "$HOME/.config/nvim" \
    "$HOME/.local/bin"
  echo mine >"$HOME/.config/nvim/init.lua"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/nvim"
  chmod +x "$HOME/.local/bin/nvim"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.config/nvim" ]
  [ "$(cat "$HOME/.config/nvim/init.lua")" = mine ]
}

# --- tree-sitter CLI -------------------------------------------------------
# config/nvim pins nvim-treesitter to its `main` branch, whose installer shells
# out to `tree-sitter build` for every parser with no fallback to a bare `cc`.
# A container with gcc but no CLI still fails every parser at first launch.

# Stages a gzipped fake tree-sitter, points a curl stub at it, and writes a
# versions.env whose checksum matches. Both arch SHAs get the same value so the
# suite passes on x86_64 and arm64 runners alike.
stage_tree_sitter_download() {
  local body="$1"
  mkdir -p "$TEST_ROOT/host-seed/.dotfiles/config" "$HOME/.local/bin"

  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$TEST_ROOT/ts-bin"
  # -n suppresses the mtime header, so the checksum is reproducible.
  gzip -n -c "$TEST_ROOT/ts-bin" >"$TEST_ROOT/ts.gz"
  TS_FIXTURE="$TEST_ROOT/ts.gz"
  export TS_FIXTURE

  local sha
  sha="$(sha256sum "$TS_FIXTURE" | cut -d' ' -f1)"
  cat >"$TEST_ROOT/host-seed/.dotfiles/config/versions.env" <<EOF
TREE_SITTER_VERSION=0.26.11
TREE_SITTER_SHA256_X86_64=$sha
TREE_SITTER_SHA256_ARM64=$sha
EOF

  # The nvim block shares this curl stub, so keep it out of the way by
  # presenting an already-installed binary — this test is about tree-sitter.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/nvim"
  chmod +x "$HOME/.local/bin/nvim"

  stub_command curl '
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
cp "$TS_FIXTURE" "$out"
'
}

@test "the seed installs the tree-sitter CLI nvim-treesitter needs" {
  stage_tree_sitter_download 'exit 0'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter ready"* ]]
  [ -x "$HOME/.local/bin/tree-sitter" ]
  # The staging file must never survive a successful install.
  [ ! -e "$HOME/.local/bin/tree-sitter.new" ]
}

@test "an existing tree-sitter is left alone" {
  stage_tree_sitter_download 'exit 0'
  stub_command tree-sitter 'exit 0'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter already present"* ]]
  [ ! -e "$HOME/.local/bin/tree-sitter" ]
}

@test "a warm restart reuses the installed tree-sitter instead of re-downloading" {
  # The seed runs as a container `command:`, whose PATH does not include
  # ~/.local/bin — so a `command -v` guard alone would miss the binary this block
  # installed and pull 26MB again on every single container start. The guard has
  # to test the path.
  stage_tree_sitter_download 'exit 0'
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/tree-sitter"
  chmod +x "$HOME/.local/bin/tree-sitter"
  # Any download attempt is a failure of this test, so make one impossible.
  stub_command curl 'exit 1'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter already present"* ]]
  [[ "$output" != *"installing tree-sitter"* ]]
}

@test "an unpinned checksum skips tree-sitter before spending a download" {
  stage_tree_sitter_download 'exit 0'
  sed -i 's/^TREE_SITTER_SHA256_\(.*\)=.*/TREE_SITTER_SHA256_\1=/' \
    "$TEST_ROOT/host-seed/.dotfiles/config/versions.env"
  stub_command curl 'exit 1'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no pinned tree-sitter build"* ]]
  [[ "$output" != *"installing tree-sitter"* ]]
  [ ! -e "$HOME/.local/bin/tree-sitter" ]
}

@test "a tree-sitter on PATH that cannot run is replaced, not trusted" {
  # `command -v` is satisfied by a shim whose tool was never installed, and by a
  # glibc binary on a musl base that dies at exec time. Trusting either latches
  # the block shut: "already present" every start, parsers failing every start.
  stage_tree_sitter_download 'exit 0'
  stub_command tree-sitter 'exit 127'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter ready"* ]]
  # Asserted the way the seed's own guard asserts it: the bit says nothing about
  # whether the file can actually run, which is the whole point of this test.
  run "$HOME/.local/bin/tree-sitter" --version
  [ "$status" -eq 0 ]
}

@test "an installed tree-sitter that stops running is reinstalled" {
  stage_tree_sitter_download 'exit 0'
  # Executable, on the expected path, and broken — the shape a base-image change
  # leaves behind. The guard must not accept it on the strength of `test -x`.
  printf '#!/usr/bin/env bash\nexit 127\n' >"$HOME/.local/bin/tree-sitter"
  chmod +x "$HOME/.local/bin/tree-sitter"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter ready"* ]]
  run "$HOME/.local/bin/tree-sitter" --version
  [ "$status" -eq 0 ]
}

@test "a tree-sitter that cannot execute is not installed" {
  # The release binaries are dynamically linked against glibc, so on an older
  # base image the file is executable and still dies at exec time. `test -x`
  # would accept it and leave a binary that looks installed while
  # nvim-treesitter keeps failing — so the seed validates by running --version.
  stage_tree_sitter_download 'exit 127'

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  # Reported as the environment limit it is, not as a generic failure: no
  # published 0.26.x build runs on a glibc this old, so the operator needs to
  # know a retry cannot help and a newer base image is the only fix.
  [[ "$output" == *"needs a newer glibc"* ]]
  [[ "$output" == *"regex highlighting"* ]]
  [ ! -e "$HOME/.local/bin/tree-sitter" ]
  [ ! -e "$HOME/.local/bin/tree-sitter.new" ]
}

@test "a checksum mismatch never lands a tree-sitter binary" {
  stage_tree_sitter_download 'exit 0'
  sed -i 's/^TREE_SITTER_SHA256_\(.*\)=.*/TREE_SITTER_SHA256_\1=deadbeef/' \
    "$TEST_ROOT/host-seed/.dotfiles/config/versions.env"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"tree-sitter install failed"* ]]
  [ ! -e "$HOME/.local/bin/tree-sitter" ]
}

@test "a missing versions.env skips tree-sitter without aborting the seed" {
  # Non-fatal throughout: treesitter highlighting is a nicety, and an editor that
  # opens without it beats a container that will not start.
  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"tree-sitter ready"* ]]
}

@test "the dotfiles shell loader is installed exactly once" {
  # load-custom.zsh is the supported entry point. Globbing **/*.zsh instead also
  # matches load-custom.zsh itself, so the whole tree loads twice — aliases
  # redefined, PATH entries duplicated, and a stray `file=...` line per prompt.
  local hook='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(grep -Fxc "$hook" "$HOME/.zshrc")" = 1 ]
  # It must precede the Vekil hook, which owns the endpoint/model variables and
  # has to get the last word.
  local load_at vekil_at
  load_at="$(grep -Fxn "$hook" "$HOME/.zshrc" | cut -d: -f1)"
  vekil_at="$(grep -n 'ai/vekil/env.zsh' "$HOME/.zshrc" | head -n1 | cut -d: -f1)"
  [ "$load_at" -lt "$vekil_at" ]
}

@test "the shell loader is inserted above a Vekil hook left by an earlier seed" {
  # The upgrade path, and the one the test above cannot see: it writes both hooks
  # in a single fresh run, where appending happens to land in the right order. On
  # a volume already seeded by an older version the Vekil hook is present and the
  # loader is not, so a plain append would place the loader *after* it and
  # silently invert the precedence — core/ would then win over ai/vekil/env.zsh
  # for ANTHROPIC_MODEL, pointing the container at the wrong model with no error.
  local hook='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'
  local vekil='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
  printf '%s\n' "$vekil" >"$HOME/.zshrc"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(grep -Fxc "$hook" "$HOME/.zshrc")" = 1 ]
  [ "$(grep -Fxc "$vekil" "$HOME/.zshrc")" = 1 ]
  local load_at vekil_at
  load_at="$(grep -Fxn "$hook" "$HOME/.zshrc" | cut -d: -f1)"
  vekil_at="$(grep -Fxn "$vekil" "$HOME/.zshrc" | cut -d: -f1)"
  [ "$load_at" -lt "$vekil_at" ]

  # And the rewrite is idempotent — a second start must not stack another copy.
  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc "$hook" "$HOME/.zshrc")" = 1 ]
}

@test "a loader left below the Vekil hook by an older seed is moved above it" {
  # The population the previous fix does NOT reach: every container seeded
  # before it has both hooks, in the wrong order. Keying the repair on "is our
  # hook present?" declares that state fixed and latches the inverted
  # precedence permanently — core/ beats ai/vekil/env.zsh on ANTHROPIC_MODEL
  # and the container talks to the wrong model with nothing in the log.
  local hook='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'
  local vekil='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
  printf '# keep me\n%s\n%s\n' "$vekil" "$hook" >"$HOME/.zshrc"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]

  # Reordered, not duplicated — the rewrite drops the old copy before re-emitting.
  [ "$(grep -Fxc "$hook" "$HOME/.zshrc")" = 1 ]
  [ "$(grep -Fxc "$vekil" "$HOME/.zshrc")" = 1 ]
  local load_at vekil_at
  load_at="$(grep -Fxn "$hook" "$HOME/.zshrc" | cut -d: -f1)"
  vekil_at="$(grep -Fxn "$vekil" "$HOME/.zshrc" | cut -d: -f1)"
  [ "$load_at" -lt "$vekil_at" ]
  # Unrelated lines survive the rewrite.
  grep -Fqx '# keep me' "$HOME/.zshrc"
}

@test "duplicate loaders left by repeated appends collapse to one" {
  # A guard that only asks "where is the first copy?" reads a zshrc whose first
  # hook sits correctly as already-fixed, and the extra copies below it source
  # the whole tree a second time — duplicate aliases, duplicate PATH entries.
  local hook='[[ -r "$HOME/.dotfiles/core/shell/load-custom.zsh" ]] && source "$HOME/.dotfiles/core/shell/load-custom.zsh"'
  local vekil='[[ -r "$HOME/.dotfiles/ai/vekil/env.zsh" ]] && source "$HOME/.dotfiles/ai/vekil/env.zsh"'
  printf '%s\n%s\n%s\n' "$hook" "$vekil" "$hook" >"$HOME/.zshrc"

  run bash "$SEED_SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(grep -Fxc "$hook" "$HOME/.zshrc")" = 1 ]
  [ "$(grep -Fxc "$vekil" "$HOME/.zshrc")" = 1 ]
  local load_at vekil_at
  load_at="$(grep -Fxn "$hook" "$HOME/.zshrc" | cut -d: -f1)"
  vekil_at="$(grep -Fxn "$vekil" "$HOME/.zshrc" | cut -d: -f1)"
  [ "$load_at" -lt "$vekil_at" ]
}

@test "a missing claude CLI leaves the sentinel unstamped" {
  # Skipping registration and stamping anyway is the worst outcome: the gated
  # block never runs again, so the marketplaces stay unregistered for the life
  # of the volume with no further complaint.
  rm -f "$STUB_BIN/claude"

  run bash "$SEED_SCRIPT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT stamping sentinel"* ]]
  [ ! -e "$HOME/.claude/.seeded" ]
}

@test "codex reinstall is guarded on the binary, not the config" {
  # Guarding on ~/.codex/config.toml latches: the installer writes config even
  # when it cannot produce a binary, so config-present/codex-missing skipped the
  # install on every subsequent start.
  mkdir -p "$HOME/.codex" "$TEST_ROOT/host-seed/.dotfiles/ai/codex"
  printf 'x\n' >"$HOME/.codex/config.toml"
  printf '#!/usr/bin/env bash\nmkdir -p "$HOME/.local/bin"\ntouch "$HOME/.local/bin/codex"\nchmod +x "$HOME/.local/bin/codex"\n' \
    >"$TEST_ROOT/host-seed/.dotfiles/ai/codex/install.sh"
  chmod +x "$TEST_ROOT/host-seed/.dotfiles/ai/codex/install.sh"

  run bash "$SEED_SCRIPT"

  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/codex" ]
}
