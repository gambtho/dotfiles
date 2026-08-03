# Dev Workspace Platform (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `dev`, a bash CLI that turns a repository working tree into a persistent, reconciled tmux workspace — optionally backed by a devcontainer — with a durable event stream that records what actually happened and when.

**Architecture:** Three layers with JSON-only interfaces. Sourced libraries under `tools/dev/lib/` own resolution, config merge, events, records, fold, reconcile, runtime detection, container control, and the tmux backend; `tools/dev/commands/*.sh` compose them into verbs dispatched by `bin/dev`; tmux hooks call `tools/dev/dev-event` to append events at the moment they occur. Every command runs the read-only *reconcile* phase (observe → compute → commit); only `dev open` runs the *ensure* phase that may act on the workspace.

**Tech Stack:** bash 5 (`set -euo pipefail` in executables, functions-only in libraries), `jq` 1.7, `yq` v4 (mikefarah), `flock`, `openssl`, `sha256sum`, tmux 3.4, the `@devcontainers/cli` invoked via `mise exec`, systemd user units, and `bats` for tests.

## Global Constraints

- **Bash-only for Phase 1 (ADR-3).** Four triggers move this to Go, and any one of them firing is a language change, not a patch: (1) a persistent reconciler process is required — container lifecycle consumed from `docker events` in real time rather than polled at command time; (2) event-log queries need an index rather than `jq` over a tail; (3) any single library file exceeds ~300 lines, or the total exceeds ~1,500 lines; (4) any requirement to hold a lock across an operation that can block indefinitely (a container pull, a network call).
- **Never invoke bare `make`.** `make` is a broken shell function under this zsh; every plan step spells it `/usr/bin/make check` (likewise `/usr/bin/make lint`, `/usr/bin/make syntax`).
- **Every new shell file must pass `shfmt -d -i 2 -ci` and `shellcheck -x -S warning -e SC1091`.** 2-space indent, `[[ ]]`, quoted expansions, `local x; x=$(...)` split across two statements to avoid SC2155.
- **`open` never destroys, and there is no code path from `open` to `dev_backend_kill`.** `stop` is the only destructive verb.
- **Reconcile is read-only with respect to the workspace; only `open` runs ensure.** Reconcile may mutate *state* (records, events); it never starts a container, respawns a pane, or creates a window.
- **Hooks append events; only reconcile writes records.** `dev-event` holds no state lock and never reads a record — its whole envelope comes from three tmux session options plus `#{session_name}`.
- **The state lock (`locks/<workspace_id>.lock`) is held only across a record read-modify-write.** No blocking subprocess inside it, ever. Reconcile observes and computes unlocked, then commits under the lock.
- **Every workspace-mutating operation takes the operation lock (`locks/<workspace_id>.op`) with `flock -n`.** Phase 1's full list: `open` (ensure), `stop`, `dev-autostart`. Failure to acquire exits 7; it is never retried. `list` and `status` do not take it.
- **`locks/events.lock` is exclusive (`flock -x`) for rotation and shared (`flock -s`) for appends AND for folds.** A fold holds the shared lock across both establishing its segment list and reading those segments. Rotation is checked after the fold releases, never inside it.
- **One `printf` per event, 4 KiB cap.** The line is composed entirely in memory and written with a single syscall; free-form `data` is truncated and marked `truncated: true`.
- **Discovery events use deterministic ids, and the ordering is emit-then-commit.** `id = sha256(workspace_id || event_type || discriminator)` truncated to 16 hex, for `workspace.vanished` (discriminator: recorded `boot_id` + `opened_at`), `container.lost` (lost container id + the `container.observed_at` that bound it), and `config.changed` (new `config_digest` + current `applied_digest`). Emit skips ids already present in the retained segments, so CAS retries append nothing. Each discriminator names the *occasion* as well as the subject: without the second component a workspace that vanished, was reopened and vanished again — or a config edited A → B → A — would re-derive an id already on disk, and the second, genuinely new event would be dropped as a duplicate.
- **Every fold transition is an absolute assignment** (`workspace.stopped` sets `status=stopped`; nothing increments or decrements), which is what makes replay idempotent.
- **Unknown event types are ignored by the fold, not rejected.** Forward compatibility is a contract: a consumer or an older binary meeting a newer type must fold past it.
- **`dev list --json` is the public snapshot contract; `workspaces/*.json` is not.** Records are historical projections documented in §4.3 so the format is understood, not so it is depended upon.
- **The devcontainer CLI is detected by execution, never by `command -v`.** The shim resolves but fails; detection runs `devcontainer --version` through `mise exec <pinned-spec> --` with an absolute `mise` path, and exits 6 when absent-or-unrunnable.
- **`remain-on-exit` is set per-window on platform-created windows only, never globally.** Set `-g` it changes every ordinary pane in daily tmux use; it is also a correctness dependency, since `pane-died` fires only when `remain-on-exit` keeps the pane.
- **The full sha256 is the `workspace_id`, never truncated.** 64 hex characters of `sha256(realpath(worktree))`, used as the record filename and lock basename. (Only *event* ids are 16 hex.)

## File Structure

```
bin/
  dev                                  # Dispatcher: parses the verb, sources libs, refuses inside a container
  common.sh                            # MODIFIED (Task 2): gains dev_slug_for_path(), shared with claude-link-project
  claude-devcontainer-up               # MODIFIED (Task 18): tmux-install block removed; superseded by tools/dev
  list-check-files                     # MODIFIED (Task 1): discovery classes learn tools/dev/**
tools/dev/
  default-workspace.yaml               # Default layout merged under every workspace (Task 4)
  dev.tmux.conf                        # Hook registrations, sourced from tmux.conf.symlink via markers (Task 16)
  dev-event                            # Minimal event emitter invoked by tmux hooks; reads no record (Task 16)
  dev-autostart                        # Boot-time container starter; ExecStart of the user unit (Task 17)
  dev-autostart.service                # systemd user unit template (@DOTFILES_ROOT@ substituted) (Task 17)
  install.sh                           # Installs the unit and creates state dirs (Task 17)
  lib/
    resolve.sh                         # name|cwd -> slug, worktree, workspace_id, session_name (Task 3)
    config.sh                          # YAML merge -> normalized JSON + config_digest + validation (Task 4)
    events.sh                          # Event build, single-printf append, segment listing, rotation (Task 5)
    state.sh                           # Record new/read/CAS-commit/list under the state lock (Task 6)
    fold.sh                            # DEVIATION: the §4.4 transition table, split out of reconcile.sh (Task 7)
    reconcile.sh                       # observe -> compute -> commit, discovery events, drift cases A-E (Task 8)
    runtime.sh                         # Docker/mise/devcontainer-CLI detection by execution; runtime.json cache (Task 9)
    container.sh                       # devcontainer up, id parsing, liveness, exec-command builder (Task 10)
    backend-tmux.sh                    # create/apply_layout/query/respawn_pane/kill; the only tmux consumer (Task 11)
  commands/
    config.sh                          # Prints merged config JSON (Task 12)
    list.sh                            # Reconciled listing, human or --json (Task 13)
    status.sh                          # Single-workspace detail including drift and fold_gap (Task 13)
    open.sh                            # Default verb: reconcile -> ensure -> attach. Never destroys (Task 14)
    attach.sh                          # Attach only; fails if absent rather than creating (Task 14)
    stop.sh                            # Ends the session, optionally the container. The only destructive verb (Task 15)
tools/tmux/
  tmux.conf.symlink                    # MODIFIED (Task 16): committed marker block sourcing tools/dev/dev.tmux.conf
config/mise/
  config.toml                          # DEVIATION: MODIFIED (Task 9) to pin npm:@devcontainers/cli under [tools]
.gitignore                             # MODIFIED (Task 17): ignore projects/*/workspace.local.yaml
tests/
  check_file_discovery.bats            # MODIFIED (Task 1): tools/dev/** lands in bash/shellcheck/shfmt
  claude_link_project.bats             # MODIFIED (Task 2): covers the extracted shared slug function
  dev_resolve.bats                     # Slug/worktree/id resolution; also adds setup_dev_test (Task 3)
  dev_config_merge.bats                # Three-layer merge, digest stability, local-overlay precedence (Task 4)
  dev_state_events.bats                # Record round-trip, CAS, concurrent appends, JSONL rotation (Tasks 5-6)
  dev_fold.bats                        # Every §4.4 transition, idempotence, unknown-type tolerance (Task 7)
  dev_reconcile.bats                   # Drift cases A-E, CAS retry, deterministic discovery ids (Task 8)
  dev_runtime_container.bats           # Detection-by-execution and the exec-prefix builder (Tasks 9-10)
  dev_backend_tmux.bats                # Real tmux on a dedicated -L socket (Task 11)
  dev_commands.bats                    # Dispatcher, config/list/status/open/attach/stop behaviour (Tasks 12-15)
  dev_install.bats                     # Unit templating, tmux marker block, .gitignore wiring (Task 17)
  dev_lifecycle.bats                   # Fold-equivalence: replaying the log reproduces the record (Task 19)
  test_helper.bash                     # MODIFIED (Task 3): gains setup_dev_test()
$DEV_OVERLAY_ROOT/<slug>/
  workspace.yaml                       # Per-repo overrides; version-controlled
  workspace.local.yaml                 # Machine-local, gitignored; secrets and host-specific env
~/.local/state/dev/                    # Runtime state; not in the repository
  workspaces/<workspace_id>.json       # One record per working tree; name is the full sha256 of its path
  sessions/<session_name>.json         # Envelope sidecar for tmux hooks; written by open, deleted by stop
  events/events.jsonl                  # Append-only event stream
  events/events-<stamp>.jsonl          # Rotated segments, 5 retained
  locks/<workspace_id>.lock            # State lock: record read-modify-write only
  locks/<workspace_id>.op              # Operation lock: every workspace-mutating operation
  locks/events.lock                    # Global: exclusive for rotation, shared for appends and folds
  runtime.json                         # Cached detection: mise path + pinned CLI spec, docker flavor
```

Four deviations from spec §3, each verified against this repository:

1. **A session-envelope sidecar, `sessions/<session_name>.json`, is added.** Probing tmux 3.4 showed that at `session-closed` time the closing session's user options are already destroyed — `#{@dev_workspace_id}` expands empty and `#{session_name}` expands to a *different* live session — so the hook cannot build its own envelope and would either emit nothing or emit something silently wrong. `open` writes the sidecar right after session creation, `dev-event --session <name>` reads it, and `stop` deletes it before `kill-session` so the hook that fires a moment later finds nothing and only one `workspace.stopped` is produced. It is written once per incarnation, never mutated, holds no lock, and lives outside `workspaces/` — ADR-1's "hooks append events, only reconcile writes records" is intact.

2. **No PATH symlink for `bin/dev`.** `core/path.zsh` already puts `${ZSH:-$HOME/.dotfiles}/bin` first on `PATH`, so `bin/dev` is callable the moment it is committed. `install.sh` (Task 17) therefore installs the systemd unit and the state directories only, and the spec's "the only file symlinked onto PATH" is superseded.
3. **The devcontainer CLI pin lives in `config/mise/config.toml` under `[tools]`,** not in a new `tools/dev/versions.toml`. That table is the repository's existing pin mechanism and is auto-listed by `bin/versions list_mise`; a second version file would be invisible to it.
4. **`lib/fold.sh` is split out of `lib/reconcile.sh`.** The §4.4 transition table is 17 event types with per-type record assignments; combined with reconcile's observe/compute/commit cycle, CAS retry, and discovery-event emission, one file would land around 300 lines — ADR-3 trigger 3, which is a signal to move to Go rather than something to absorb. Splitting the pure fold (no I/O, no locks) from the impure reconcile keeps both well under the threshold and makes the fold-equivalence test in Task 19 able to call the fold directly.

One further note on installation: the tmux extension is a **committed** marker block in `tools/tmux/tmux.conf.symlink`, copying the shape of the existing `# claude-code-agent-teams-config-start` … `-end` pair that sources a conf under `tools/tmux/`. It is not injected by `install.sh` at install time, so there is nothing to make idempotent and the block is reviewable in the diff.

---

### Task 1: `bin/list-check-files` covers `tools/dev/**`

This task is first because every later task writes bash under `tools/dev/`, and until discovery changes, none of it is seen by `/usr/bin/make syntax`, `/usr/bin/make lint`, or the shfmt gate. Written second, the whole platform would be unchecked and the fix would arrive with a large formatting diff attached.

**Files:**
- Modify: `bin/list-check-files`
- Test: `tests/check_file_discovery.bats`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `bin/list-check-files {bash|shellcheck|shfmt}` additionally emits `tools/dev/lib/*.sh`, `tools/dev/commands/*.sh`, `tools/dev/install.sh`, `tools/dev/dev-event`, `tools/dev/dev-autostart`. No function is exported; later tasks depend on the behaviour only.

Current state, read before changing: `is_repository_sh` matches `.sh` files under `ai/ core/ fonts/ languages/ platforms/ work/` only, and `is_direct_bin_shell` matches `bin/<name>` with no subdirectory. Nothing under `tools/` reaches the bash classes. `is_repository_zsh` already claims `tools/**/*.zsh`, and that must stay untouched.

The new predicate must include the two extensionless executables `tools/dev/dev-event` and `tools/dev/dev-autostart`, and must exclude `tools/dev/default-workspace.yaml`, `tools/dev/dev.tmux.conf`, `tools/dev/dev-autostart.service`, and every `tools/**/*.zsh`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/check_file_discovery.bats`, and extend the existing `setup`/`teardown` so the throwaway files follow the `UNTRACKED_FILE`/`IGNORED_FILE` pattern already in that file (created in `setup`, removed in `teardown`, suffixed with `$BATS_TEST_NUMBER`):

```bash
setup() {
  setup_dotfiles_test
  UNTRACKED_FILE="$REPO_ROOT/bin/example-check-script-$BATS_TEST_NUMBER"
  IGNORED_DIR="$REPO_ROOT/bin/.opencode"
  IGNORED_FILE="$IGNORED_DIR/project-$BATS_TEST_NUMBER.sh"
  mkdir -p "$IGNORED_DIR"
  printf '#!/usr/bin/env bash\ntrue\n' >"$UNTRACKED_FILE"
  printf '#!/usr/bin/env bash\nfalse\n' >"$IGNORED_FILE"

  # Throwaway probes for the tools/dev discovery classes. They are untracked,
  # so they exercise the same --others path the bin/ probe above does.
  DEV_LIB_DIR="$REPO_ROOT/tools/dev/lib"
  DEV_CMD_DIR="$REPO_ROOT/tools/dev/commands"
  DEV_LIB_FILE="$DEV_LIB_DIR/probe-$BATS_TEST_NUMBER.sh"
  DEV_CMD_FILE="$DEV_CMD_DIR/probe-$BATS_TEST_NUMBER.sh"
  DEV_INSTALL_FILE="$REPO_ROOT/tools/dev/probe-install-$BATS_TEST_NUMBER.sh"
  DEV_EXEC_FILE="$REPO_ROOT/tools/dev/probe-exec-$BATS_TEST_NUMBER"
  DEV_YAML_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.yaml"
  DEV_CONF_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.tmux.conf"
  DEV_UNIT_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.service"
  DEV_ZSH_FILE="$REPO_ROOT/tools/dev/probe-$BATS_TEST_NUMBER.zsh"
  mkdir -p "$DEV_LIB_DIR" "$DEV_CMD_DIR"
  printf 'probe_lib() { :; }\n' >"$DEV_LIB_FILE"
  printf 'dev_cmd_probe() { :; }\n' >"$DEV_CMD_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$DEV_INSTALL_FILE"
  printf '#!/usr/bin/env bash\ntrue\n' >"$DEV_EXEC_FILE"
  printf 'windows: []\n' >"$DEV_YAML_FILE"
  printf 'set -g status on\n' >"$DEV_CONF_FILE"
  printf '[Unit]\nDescription=probe\n' >"$DEV_UNIT_FILE"
  printf 'export PROBE=1\n' >"$DEV_ZSH_FILE"
}

teardown() {
  rm -f -- "$UNTRACKED_FILE" "$IGNORED_FILE" \
    "$DEV_LIB_FILE" "$DEV_CMD_FILE" "$DEV_INSTALL_FILE" "$DEV_EXEC_FILE" \
    "$DEV_YAML_FILE" "$DEV_CONF_FILE" "$DEV_UNIT_FILE" "$DEV_ZSH_FILE"
  rmdir "$IGNORED_DIR" 2>/dev/null || true
  rmdir "$DEV_LIB_DIR" "$DEV_CMD_DIR" 2>/dev/null || true
}

@test "dev platform shell sources land in every bash gate" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${DEV_LIB_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_CMD_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_INSTALL_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" == *"${DEV_EXEC_FILE#"$REPO_ROOT/"}"* ]]
  done
}

@test "dev platform non-shell assets stay out of the bash gates" {
  local class
  for class in bash shellcheck shfmt; do
    list_files "$class"
    [ "$status" -eq 0 ]
    [[ "$output" != *"${DEV_YAML_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_CONF_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_UNIT_FILE#"$REPO_ROOT/"}"* ]]
    [[ "$output" != *"${DEV_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  done
}

@test "dev platform zsh sources stay in the zsh gate" {
  list_files zsh

  [ "$status" -eq 0 ]
  [[ "$output" == *"${DEV_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  [[ "$output" != *"${DEV_LIB_FILE#"$REPO_ROOT/"}"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/check_file_discovery.bats`
Expected: FAIL — "dev platform shell sources land in every bash gate" fails on the first `[[ "$output" == *"tools/dev/lib/probe-..."* ]]` assertion, because `tools/` reaches neither `is_direct_bin_shell` nor `is_repository_sh`. The other two new tests pass already (they assert exclusions).

- [ ] **Step 3: Write the implementation**

Add `is_dev_tool_shell` to `bin/list-check-files` after `is_repository_sh`, and wire it into all three bash-ish class arms. `tools/dev/dev-event` and `tools/dev/dev-autostart` are extensionless, so the predicate matches "no dot in the basename" the same way `is_direct_bin_shell` does, which is what keeps `.yaml`, `.conf`, `.service`, and `.zsh` out.

```bash
is_dev_tool_shell() {
  local path="$1" name
  [[ "$path" == tools/dev/* ]] || return 1
  name=${path##*/}
  # Extensionless executables (dev-event, dev-autostart) and .sh sources are
  # bash; everything else under tools/dev is data for another consumer
  # (.yaml config, .tmux.conf, .service unit) or belongs to the zsh class.
  [[ "$name" != *.* || "$name" == *.sh ]]
}
```

```bash
{
  git ls-files -z
  git ls-files -z --others --exclude-standard
} | while IFS= read -r -d '' path; do
  case "$class" in
    bash)
      if is_direct_bin_shell "$path" || is_repository_sh "$path" || is_dev_tool_shell "$path"; then printf '%s\0' "$path"; fi
      ;;
    zsh)
      if is_repository_zsh "$path"; then printf '%s\0' "$path"; fi
      ;;
    shellcheck)
      if is_direct_bin_shell "$path" || is_repository_sh "$path" || is_dev_tool_shell "$path"; then printf '%s\0' "$path"; fi
      ;;
    shfmt)
      if is_direct_bin_shell "$path" || is_repository_sh "$path" || is_dev_tool_shell "$path" || [[ "$path" == tests/test_helper.bash ]]; then printf '%s\0' "$path"; fi
      ;;
  esac
done
```

Note that `is_repository_zsh` is unchanged: its `tools/*` arm still requires a `.zsh` suffix, so the zsh and bash classes stay disjoint over `tools/dev/`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/check_file_discovery.bats`
Expected: PASS (11 tests, 0 failures) — the 8 pre-existing tests plus the 3 new ones. In particular "shfmt covers extensionless bin executables", which asserts the shfmt set is a superset of the shellcheck set, must still pass: both arms gained the same predicate.

- [ ] **Step 5: Verify the widened gates still pass on the current tree**

Run: `/usr/bin/make syntax && /usr/bin/make lint`
Expected: both succeed. This task changes *what* lint covers, so it is the one task where the repo-wide gates must be run before committing. `tools/dev/` does not exist yet, so the newly matched set is empty on a clean tree and the run should be identical to the previous one.

- [ ] **Step 6: Commit**

```bash
git add bin/list-check-files tests/check_file_discovery.bats
git commit -m "build(check): cover tools/dev shell sources in bash discovery"
```

---

### Task 2: extract `dev_slug_for_path` into `bin/common.sh`

`bin/claude-link-project` already derives an overlay slug from a project directory, handling the case that matters here: a linked git worktree is named after its branch, not its repository, so the slug must come from the *primary* working tree. `tools/dev/lib/resolve.sh` (Task 3) needs exactly that rule. Extracting it rather than reimplementing it is what keeps the overlay `dev` reads and the overlay `claude-link-project` writes pointing at the same directory.

`bin/common.sh` is sourced by many installers (`ai/claude/install.sh`, `core/git/install.sh`, `fonts/install.sh`, and others), so the new function must **define only** — no work at source time — and must not read any `DEV_*` variable, since none of those callers set them.

**Files:**
- Modify: `bin/common.sh`
- Modify: `bin/claude-link-project`
- Test: `tests/claude_link_project.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `dev_slug_for_path <dir>` → prints the slug (basename of the primary working tree; the directory's own basename outside git). Non-zero exit with a message on stderr when `<dir>` does not exist. Consumed by `dev_resolve` in Task 3.

Behaviour to preserve bit for bit, currently inline at `bin/claude-link-project:110-120`: start from `basename "$PROJECT_DIR"`; if `git -C "$dir" worktree list --porcelain` succeeds and its first `worktree ` line names an existing directory, use that directory's basename instead. `--slug` still short-circuits the whole thing.

- [ ] **Step 1: Write the failing test**

Append to `tests/claude_link_project.bats`. It sources `bin/common.sh` directly and exercises both a primary checkout and a real linked worktree.

```bash
@test "dev_slug_for_path resolves primary checkouts and linked worktrees" {
  source "$REPO_ROOT/bin/common.sh"

  local primary="$TEST_ROOT/slug-demo"
  mkdir -p "$primary"
  git -C "$primary" init -q -b main .
  git -C "$primary" -c user.email=t@example.com -c user.name=T \
    commit -q --allow-empty -m init

  run dev_slug_for_path "$primary"
  [ "$status" -eq 0 ]
  [ "$output" = "slug-demo" ]

  # A linked worktree's directory is named after the branch; the slug must
  # still be the primary working tree's name so both resolve to one overlay.
  local linked="$TEST_ROOT/feature-branch"
  git -C "$primary" worktree add -q -b feature "$linked"

  run dev_slug_for_path "$linked"
  [ "$status" -eq 0 ]
  [ "$output" = "slug-demo" ]

  # Outside git, the directory's own basename is the slug.
  local plain="$TEST_ROOT/plain-dir"
  mkdir -p "$plain"
  run dev_slug_for_path "$plain"
  [ "$status" -eq 0 ]
  [ "$output" = "plain-dir" ]

  run dev_slug_for_path "$TEST_ROOT/does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such directory"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/claude_link_project.bats`
Expected: FAIL with `command not found: dev_slug_for_path` (bats reports status 127 on the first `run`).

- [ ] **Step 3: Add the function to `bin/common.sh`**

Append to `bin/common.sh`. It is a pure function: it defines nothing global and runs nothing at source time.

```bash
# Derive the slug a directory belongs to. Normally that is the directory's own
# name, but a linked git worktree is named after its branch, so the primary
# working tree's name is used instead (git lists it first in --porcelain
# output). Shared with tools/dev so the overlay claude-link-project writes and
# the overlay `dev` reads are always the same directory.
dev_slug_for_path() {
  local dir="$1" resolved slug main_root

  if ! resolved="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf 'dev_slug_for_path: no such directory: %s\n' "$dir" >&2
    return 1
  fi

  slug="$(basename "$resolved")"
  if main_root="$(git -C "$resolved" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{print substr($0, 10); exit}')" && [[ -d "$main_root" ]]; then
    slug="$(basename "$main_root")"
  fi

  printf '%s\n' "$slug"
}
```

- [ ] **Step 4: Call it from `bin/claude-link-project`**

Replace the inline block (the `else` branch of the `--slug` check) with a call. The comment moves to `common.sh` with the logic; what stays is the `--slug` override, unchanged.

```bash
# The overlay is normally keyed on the project directory's name. That breaks
# for a linked git worktree, whose directory is named after the branch, so
# --slug lets the caller name the overlay explicitly. When it isn't given,
# dev_slug_for_path (bin/common.sh) applies the shared worktree-aware rule.
if [[ -n "$SLUG" ]]; then
  NAME="$SLUG"
else
  NAME="$(dev_slug_for_path "$PROJECT_DIR")" || exit 1
fi
OVERLAY="$OVERLAY_ROOT/$NAME"
```

`PROJECT_DIR` is already `cd`-and-`pwd -P` normalized a few lines above, so the extra `cd` inside `dev_slug_for_path` is a no-op here and the resolved path is identical to what the inline code used.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/claude_link_project.bats`
Expected: PASS (the pre-existing cases plus the new one, 0 failures). The pre-existing cases are the regression check that `claude-link-project`'s slug behaviour is unchanged — several of them assert overlay paths built from the slug.

- [ ] **Step 6: Run the gates that cover both modified files**

Run: `/usr/bin/make lint`
Expected: PASS. `bin/common.sh` and `bin/claude-link-project` are both in the shellcheck and shfmt sets; the `local slug; slug=$(...)` split matters here (SC2155).

- [ ] **Step 7: Commit**

```bash
git add bin/common.sh bin/claude-link-project tests/claude_link_project.bats
git commit -m "refactor(bin): extract dev_slug_for_path into common.sh"
```
### Task 3: `tools/dev/lib/resolve.sh` + the `setup_dev_test` helper

Turns a user's argument (or `$PWD`) into the one JSON object every later command starts from.
ADR-7 splits identity in two: `workspace_id` is the **full** 64-hex `sha256(realpath(worktree))`
and names every file; `session_name` is the human-facing `<slug>` / `<slug>--<basename>`. The
digest is deliberately **not truncated** — ADR-7 rejects the earlier 12-hex form because "almost
never collides" is a weaker claim than the design leans on, and the extra 52 characters sit in
filenames nobody types.

This task also adds `setup_dev_test()` to `tests/test_helper.bash`. No other task adds it; later
tasks only call it.

**Files:**
- Create: `tools/dev/lib/resolve.sh`
- Modify: `tests/test_helper.bash`
- Test: `tests/dev_resolve.bats`

**Interfaces:**
- Consumes: `dev_slug_for_path <dir>` (Task 2, from `bin/common.sh`)
- Produces:
  - `dev_resolve_workspace_id <path>` → 64-hex sha256 of the real path
  - `dev_resolve_is_primary <path>` → exit 0 primary, 1 linked worktree
  - `dev_resolve_session_name <slug> <worktree>` → `<slug>` or `<slug>--<basename>`
  - `dev_resolve <arg>` → `{"slug","worktree","workspace_id","session_name","is_primary"}`;
    exit 3 ambiguous, exit 4 unknown
  - `setup_dev_test()` in `tests/test_helper.bash`

- [ ] **Step 1: Add the shared test helper**

Append to `tests/test_helper.bash`:

```bash

setup_dev_test() {
  setup_dotfiles_test
  # yq lives in /usr/local/bin, which setup_dotfiles_test drops from PATH.
  export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin"
  export DEV_DOTFILES_ROOT="$REPO_ROOT"
  export DEV_STATE_ROOT="$TEST_ROOT/state"
  export DEV_REPO_ROOT="$TEST_ROOT/workspace"
  export DEV_OVERLAY_ROOT="$TEST_ROOT/overlay"
  export DEV_TMUX_SOCKET="devtest-$$-$BATS_TEST_NUMBER"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" \
    "$DEV_STATE_ROOT/locks" "$DEV_REPO_ROOT" "$DEV_OVERLAY_ROOT"
}
```

- [ ] **Step 2: Write the failing test**

The primary/linked distinction cannot be faked with `mkdir`, so every fixture is a real
repository. The test `HOME` has no gitconfig, which is why `git init` needs
`-c init.defaultBranch=main` and every commit needs `-c user.email=… -c user.name=…`.

Create `tests/dev_resolve.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
}

# The test HOME has no gitconfig, so the default branch name and the commit
# identity must be supplied explicitly on every git invocation.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -c init.defaultBranch=main init -q "$dir"
  git -C "$dir" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m init
}

add_worktree() {
  local repo="$1" path="$2" branch="$3"
  mkdir -p "$(dirname "$path")"
  git -C "$repo" -c user.email=t@example.com -c user.name=t \
    worktree add -q "$path" -b "$branch"
}

@test "workspace_id is the full 64-hex sha256 of the real path" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  run dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "workspace_id is stable across a trailing slash and a symlinked path" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  ln -s "$DEV_REPO_ROOT/euro_trip" "$TEST_ROOT/link"
  local plain slashed linked
  plain="$(dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip")"
  slashed="$(dev_resolve_workspace_id "$DEV_REPO_ROOT/euro_trip/")"
  linked="$(dev_resolve_workspace_id "$TEST_ROOT/link")"
  [ "$plain" = "$slashed" ]
  [ "$plain" = "$linked" ]
}

@test "a primary working tree and a non-git directory are both primary" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  mkdir -p "$DEV_REPO_ROOT/plain"
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip"
  [ "$status" -eq 0 ]
  run dev_resolve_is_primary "$DEV_REPO_ROOT/plain"
  [ "$status" -eq 0 ]
}

@test "a linked worktree is not primary, including from a subdirectory" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  mkdir -p "$DEV_REPO_ROOT/euro_trip-pr5/sub"
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip-pr5"
  [ "$status" -eq 1 ]
  run dev_resolve_is_primary "$DEV_REPO_ROOT/euro_trip-pr5/sub"
  [ "$status" -eq 1 ]
}

@test "a primary tree resolves to the bare slug as its session name" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  run dev_resolve euro_trip
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .is_primary <<<"$output")" = "true" ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/euro_trip" ]
}

@test "a sibling worktree inherits the parent slug and gets slug--basename" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  run dev_resolve euro_trip-pr5
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "euro_trip" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip--euro_trip-pr5" ]
  [ "$(jq -r .is_primary <<<"$output")" = "false" ]
}

@test "a nested .worktrees tree is found and inherits the parent slug" {
  make_repo "$DEV_REPO_ROOT/slabledger"
  add_worktree "$DEV_REPO_ROOT/slabledger" \
    "$DEV_REPO_ROOT/slabledger/.worktrees/review" review
  run dev_resolve review
  [ "$status" -eq 0 ]
  [ "$(jq -r .slug <<<"$output")" = "slabledger" ]
  [ "$(jq -r .session_name <<<"$output")" = "slabledger--review" ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/slabledger/.worktrees/review" ]
}

@test "two same-basename worktrees under different parents exit 3 and list both" {
  make_repo "$DEV_REPO_ROOT/slabledger"
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/slabledger" \
    "$DEV_REPO_ROOT/slabledger/.worktrees/review" review
  add_worktree "$DEV_REPO_ROOT/euro_trip" \
    "$DEV_REPO_ROOT/euro_trip/.claude/worktrees/review" review
  run dev_resolve review
  [ "$status" -eq 3 ]
  [[ "$output" == *"slabledger/.worktrees/review"* ]]
  [[ "$output" == *"euro_trip/.claude/worktrees/review"* ]]
  [[ "$output" == *"no argument"* ]]
  [[ "$output" == *"renaming"* ]]
}

@test "an unknown name exits 4 and names the searched roots" {
  run dev_resolve nosuchproject
  [ "$status" -eq 4 ]
  [[ "$output" == *"unknown workspace: nosuchproject"* ]]
  [[ "$output" == *"$DEV_REPO_ROOT"* ]]
  [[ "$output" == *".claude/worktrees"* ]]
}

@test "cwd resolution from a subdirectory resolves to the worktree root" {
  make_repo "$DEV_REPO_ROOT/euro_trip"
  add_worktree "$DEV_REPO_ROOT/euro_trip" "$DEV_REPO_ROOT/euro_trip-pr5" pr5
  mkdir -p "$DEV_REPO_ROOT/euro_trip-pr5/deep/nested"
  cd "$DEV_REPO_ROOT/euro_trip-pr5/deep/nested"
  run dev_resolve
  [ "$status" -eq 0 ]
  [ "$(jq -r .worktree <<<"$output")" = "$DEV_REPO_ROOT/euro_trip-pr5" ]
  [ "$(jq -r .session_name <<<"$output")" = "euro_trip--euro_trip-pr5" ]
}

@test "cwd resolution outside git falls back to the current directory" {
  mkdir -p "$TEST_ROOT/notgit"
  cd "$TEST_ROOT/notgit"
  run dev_resolve
  [ "$status" -eq 0 ]
  [ "$(jq -r .worktree <<<"$output")" = "$TEST_ROOT/notgit" ]
  [ "$(jq -r .slug <<<"$output")" = "notgit" ]
  [ "$(jq -r .is_primary <<<"$output")" = "true" ]
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bats tests/dev_resolve.bats`
Expected: FAIL — every test errors in `setup` with
`No such file or directory` on `tools/dev/lib/resolve.sh`.

- [ ] **Step 4: Write the implementation**

Two details are load-bearing and were verified against git 2.54 on this machine.
`git rev-parse --git-dir` and `--git-common-dir` may each return a **relative** path (`.git` in a
primary tree, `../.git` when invoked from a subdirectory), relative to the directory git ran in,
so both are resolved to absolute before comparison. And the candidate globs are guarded by
`[[ -d ]]` rather than `nullglob`, so an unmatched glob stays literal and is filtered out.

Create `tools/dev/lib/resolve.sh`:

```bash
#!/usr/bin/env bash

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_REPO_ROOT="${DEV_REPO_ROOT:-$HOME/workspace}"

if ! declare -F dev_slug_for_path >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$DEV_DOTFILES_ROOT/bin/common.sh"
fi

dev_resolve_workspace_id() {
  local path="$1" real
  real="$(cd "$path" 2>/dev/null && pwd -P)" || {
    printf 'no such directory: %s\n' "$path" >&2
    return 1
  }
  printf '%s' "$real" | sha256sum | cut -d' ' -f1
}

# git may report either path relative to the directory it ran in, so both are
# made absolute before they are compared. A non-git directory counts as primary.
dev_resolve_is_primary() {
  local path="$1" gitdir commondir
  gitdir="$(cd "$path" && git rev-parse --git-dir 2>/dev/null)" || return 0
  [[ -n "$gitdir" ]] || return 0
  commondir="$(cd "$path" && git rev-parse --git-common-dir 2>/dev/null)" || return 0
  gitdir="$(cd "$path" && cd "$gitdir" && pwd -P)" || return 0
  commondir="$(cd "$path" && cd "$commondir" && pwd -P)" || return 0
  [[ "$gitdir" == "$commondir" ]]
}

dev_resolve_session_name() {
  local slug="$1" worktree="$2"
  if dev_resolve_is_primary "$worktree"; then
    printf '%s\n' "$slug"
  else
    printf '%s--%s\n' "$slug" "$(basename "$worktree")"
  fi
}

# Unmatched globs stay literal under bash defaults; [[ -d ]] discards them.
dev_resolve_candidates() {
  local name="$1" dir
  for dir in "$DEV_REPO_ROOT/$name" \
    "$DEV_REPO_ROOT"/*/.worktrees/"$name" \
    "$DEV_REPO_ROOT"/*/.claude/worktrees/"$name"; do
    [[ -d "$dir" ]] && printf '%s\n' "$dir"
  done
  return 0
}

dev_resolve() {
  local name="${1:-}" worktree candidates count slug workspace_id session_name is_primary
  if [[ -z "$name" ]]; then
    worktree="$(git rev-parse --show-toplevel 2>/dev/null)" || worktree=""
    [[ -n "$worktree" ]] || worktree="$PWD"
  else
    candidates="$(dev_resolve_candidates "$name")"
    count="$(printf '%s' "$candidates" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
      printf 'unknown workspace: %s\n' "$name" >&2
      printf 'searched %s, %s/*/.worktrees and %s/*/.claude/worktrees\n' \
        "$DEV_REPO_ROOT" "$DEV_REPO_ROOT" "$DEV_REPO_ROOT" >&2
      return 4
    fi
    # ADR-7: ambiguity is an error, never a guess. Picking the first match is
    # how a user ends up running an agent against the wrong branch.
    if [[ "$count" -gt 1 ]]; then
      printf 'ambiguous workspace name: %s\n' "$name" >&2
      printf '%s\n' "$candidates" >&2
      printf 'disambiguate by cd-ing into the intended tree and running dev with no argument, or by renaming one tree\n' >&2
      return 3
    fi
    worktree="$candidates"
  fi
  worktree="$(cd "$worktree" 2>/dev/null && pwd -P)" || {
    printf 'no such directory: %s\n' "$worktree" >&2
    return 1
  }
  slug="$(dev_slug_for_path "$worktree")" || return 1
  workspace_id="$(dev_resolve_workspace_id "$worktree")" || return 1
  session_name="$(dev_resolve_session_name "$slug" "$worktree")"
  if dev_resolve_is_primary "$worktree"; then is_primary=true; else is_primary=false; fi
  jq -c -n --arg slug "$slug" --arg worktree "$worktree" \
    --arg workspace_id "$workspace_id" --arg session_name "$session_name" \
    --argjson is_primary "$is_primary" \
    '{slug: $slug, worktree: $worktree, workspace_id: $workspace_id,
      session_name: $session_name, is_primary: $is_primary}'
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats tests/dev_resolve.bats`
Expected: PASS (11 tests, 0 failures)

- [ ] **Step 6: Check formatting and lint**

Run: `shfmt -d -i 2 -ci tools/dev/lib/resolve.sh && shellcheck -x -S warning -e SC1091 tools/dev/lib/resolve.sh`
Expected: no diff, no findings.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/lib/resolve.sh tests/dev_resolve.bats tests/test_helper.bash
git commit -m "feat(dev): resolve a worktree to workspace_id, slug and session name"
```

---

### Task 4: `tools/dev/lib/config.sh` + `tools/dev/default-workspace.yaml`

Three layers merge with later winning: the shipped default, the tracked per-slug overlay, then the
gitignored machine-local overlay. The rule that makes overlays writable by hand is that **`windows`
merges by the `name` key, not by position** (spec §4.1) — an overlay may adjust one window without
restating the layout. The merged config is normalized and emitted as compact, key-sorted single-line
JSON so `dev_config_digest` is stable across cosmetic edits; the digest is what reconcile compares
to decide whether a workspace needs re-applying.

**Files:**
- Create: `tools/dev/default-workspace.yaml`
- Create: `tools/dev/lib/config.sh`
- Test: `tests/dev_config_merge.bats`

**Interfaces:**
- Consumes: `setup_dev_test()` (Task 3), `dev_resolve` output fields `slug` and `worktree` (Task 3)
- Produces:
  - `dev_config_merged <slug> <worktree>` → normalized merged config JSON, one line
  - `dev_config_digest <config_json>` → `sha256:<64 hex>`
  - `dev_config_validate <config_json>` → exit 0, or exit 5 naming the offending window

- [ ] **Step 1: Write the default layer**

Create `tools/dev/default-workspace.yaml`, exactly as spec §4.2:

```yaml
version: 1
autostart: false
devcontainer:
  enabled: auto
  start_timeout: 300
windows:
  - name: agent-1
    agent: claude
    focus: true
  - name: agent-2
    agent: claude
  - name: shell
    command: null
  - name: scratch
    command: null
    location: host
```

`scratch` defaulting to `host` is load-bearing, not incidental: it is the window most likely to
hold unsaved work, and a host-side pane cannot be killed by a container rebuild.

- [ ] **Step 2: Write the failing test**

Create `tests/dev_config_merge.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/config.sh"
  WORKTREE="$DEV_REPO_ROOT/slabledger"
  mkdir -p "$WORKTREE" "$DEV_OVERLAY_ROOT/slabledger"
}

window_field() {
  jq -r --arg n "$2" --arg f "$3" '.windows[] | select(.name == $n) | .[$f]' <<<"$1"
}

write_tracked() {
  cat >"$DEV_OVERLAY_ROOT/slabledger/workspace.yaml"
}

write_local() {
  cat >"$DEV_OVERLAY_ROOT/slabledger/workspace.local.yaml"
}

@test "the default layer alone produces the four spec windows in order" {
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch" ]
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-2 agent)" = "claude" ]
  [ "$(window_field "$output" shell agent)" = "null" ]
  [ "$(window_field "$output" scratch location)" = "host" ]
  [ "$(jq -r '.windows | map(select(.focus)) | map(.name) | join(",")' <<<"$output")" = "agent-1" ]
  [ "$(jq -r .version <<<"$output")" = "1" ]
  [ "$(jq -r .autostart <<<"$output")" = "false" ]
  [ "$(jq -r .devcontainer.enabled <<<"$output")" = "auto" ]
  [ "$(jq -r .devcontainer.start_timeout <<<"$output")" = "300" ]
}

@test "merged config is one compact line with sorted keys" {
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(jq -r 'keys | join(",")' <<<"$output")" = "autostart,devcontainer,environment,version,windows" ]
}

@test "the slabledger worked example overrides scratch and leaves the rest untouched" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
windows:
  - name: scratch
    command: make test
    location: container
YAML
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: postgres://localhost:5432/slabledger_dev
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch" ]
  [ "$(window_field "$output" scratch command)" = "make test" ]
  [ "$(window_field "$output" scratch location)" = "container" ]
  # The three windows the overlay never mentions keep every default.
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-1 focus)" = "true" ]
  [ "$(window_field "$output" agent-2 agent)" = "claude" ]
  [ "$(window_field "$output" shell command)" = "null" ]
  [ "$(window_field "$output" shell location)" = "null" ]
  [ "$(jq -r .environment.CGO_ENABLED <<<"$output")" = "1" ]
  [ "$(jq -r .environment.DATABASE_URL <<<"$output")" = "postgres://localhost:5432/slabledger_dev" ]
}

@test "windows merge by name, not by position" {
  # scratch is last in the default layer and first (and only) here. A
  # positional merge would rewrite agent-1 instead.
  write_tracked <<'YAML'
version: 1
windows:
  - name: scratch
    command: make test
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(window_field "$output" agent-1 agent)" = "claude" ]
  [ "$(window_field "$output" agent-1 command)" = "null" ]
  [ "$(window_field "$output" scratch command)" = "make test" ]
}

@test "a window only a later layer names is appended in that layer's order" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: docs
    command: mkdocs serve
  - name: logs
    command: tail -f log
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch,docs,logs" ]
  [ "$(window_field "$output" docs location)" = "null" ]
}

@test "an unset location stays null so the record can resolve it per workspace" {
  # Spec §4.1: "Default container when one exists". Normalization cannot know
  # whether one exists, so it must not decide. Only `scratch` pins host.
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(window_field "$output" agent-1 location)" = "null" ]
  [ "$(window_field "$output" agent-2 location)" = "null" ]
  [ "$(window_field "$output" shell location)" = "null" ]
  [ "$(window_field "$output" scratch location)" = "host" ]
}

@test "a window name outside [A-Za-z0-9._-] exits 5" {
  # The charset is load-bearing beyond tidiness: window names are interpolated
  # into tmux hook commands (Task 16), where a quote or backslash would break
  # out of the shell word the hook builds.
  write_tracked <<'YAML'
version: 1
windows:
  - name: "my agent's window"
    command: true
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"invalid name"* ]]
}

@test "a new window whose name is a substring of an existing one is appended" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: age
    command: watch-age
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.windows | map(.name) | join(",")' <<<"$output")" = "agent-1,agent-2,shell,scratch,age" ]
  [ "$(window_field "$output" age command)" = "watch-age" ]
}

@test "workspace.local.yaml beats workspace.yaml for a map key and a window field" {
  write_tracked <<'YAML'
version: 1
environment:
  DATABASE_URL: tracked
  CGO_ENABLED: "1"
windows:
  - name: shell
    command: tracked-cmd
    location: container
YAML
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: local
windows:
  - name: shell
    command: local-cmd
YAML
  run dev_config_merged slabledger "$WORKTREE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .environment.DATABASE_URL <<<"$output")" = "local" ]
  [ "$(jq -r .environment.CGO_ENABLED <<<"$output")" = "1" ]
  [ "$(window_field "$output" shell command)" = "local-cmd" ]
  [ "$(window_field "$output" shell location)" = "container" ]
}

@test "the digest is sha256-prefixed and byte-identical across two runs" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
YAML
  local first second
  first="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  second="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$first" = "$second" ]
  [[ "$first" =~ ^sha256:[0-9a-f]{64}$ ]]
}

@test "the digest changes when any layer changes" {
  local base tracked localised
  base="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
YAML
  tracked="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_local <<'YAML'
version: 1
environment:
  DATABASE_URL: postgres://localhost:5432/slabledger_dev
YAML
  localised="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$base" != "$tracked" ]
  [ "$tracked" != "$localised" ]
}

@test "key order inside a source YAML file does not change the digest" {
  write_tracked <<'YAML'
version: 1
environment:
  CGO_ENABLED: "1"
windows:
  - name: scratch
    command: make test
    location: container
YAML
  local ordered reordered
  ordered="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  write_tracked <<'YAML'
windows:
  - location: container
    command: make test
    name: scratch
environment:
  CGO_ENABLED: "1"
version: 1
YAML
  reordered="$(dev_config_digest "$(dev_config_merged slabledger "$WORKTREE")")"
  [ "$ordered" = "$reordered" ]
}

@test "a valid config passes validation" {
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 0 ]
}

@test "a window setting both agent and command exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: agent-2
    command: make test
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"agent-2"* ]]
  [[ "$output" == *"both agent and command"* ]]
}

@test "a second focused window exits 5 naming the windows" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: shell
    focus: true
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"focus"* ]]
  [[ "$output" == *"agent-1"* ]]
  [[ "$output" == *"shell"* ]]
}

@test "a duplicated window name exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: docs
    command: one
  - name: docs
    command: two
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"docs"* ]]
  [[ "$output" == *"more than once"* ]]
}

@test "an unknown location exits 5 naming that window" {
  write_tracked <<'YAML'
version: 1
windows:
  - name: shell
    location: kubernetes
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"kubernetes"* ]]
}

@test "a version other than 1 exits 5" {
  write_tracked <<'YAML'
version: 2
YAML
  run dev_config_validate "$(dev_config_merged slabledger "$WORKTREE")"
  [ "$status" -eq 5 ]
  [[ "$output" == *"version must be 1"* ]]
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bats tests/dev_config_merge.bats`
Expected: FAIL — every test errors in `setup` with
`No such file or directory` on `tools/dev/lib/config.sh`.

- [ ] **Step 4: Write the implementation**

`merge_windows` indexes both layers by `name`, rewrites each base window as
`base * override` (jq's `*` deep-merges field by field), then appends the later layer's
unseen windows in that layer's own order. Membership uses `IN($bn[])` rather than
`inside($bn)` on purpose: `inside` falls through to `contains`, which is substring matching on
strings, so a new window named `age` would be wrongly treated as already present when the base
has `agent-1`. Everything outside `windows` merges with a plain `*`.

Create `tools/dev/lib/config.sh`:

```bash
#!/usr/bin/env bash

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_OVERLAY_ROOT="${DEV_OVERLAY_ROOT:-$DEV_DOTFILES_ROOT/projects}"

# windows merge by the name key, never by position (spec 4.1). IN(), not
# inside(): inside() is substring matching on strings and would swallow a new
# window whose name is a substring of an existing one.
DEV_CONFIG_MERGE_JQ='
def by_name($ws): reduce $ws[] as $w ({}; .[$w.name] = $w);
def merge_windows($base; $over):
  (by_name($base)) as $bm
  | (by_name($over)) as $om
  | ($base | map(.name)) as $bn
  | ($base | map(. * ($om[.name] // {})))
    + ($over | map(select((.name | IN($bn[])) | not)))
;
($a.windows // []) as $bw
| ($b.windows // []) as $ow
| ($a * $b)
| .windows = merge_windows($bw; $ow)
'

DEV_CONFIG_NORMALIZE_JQ='
{ version: (.version // 1),
  autostart: (.autostart // false),
  devcontainer: ((.devcontainer // {}) | {
      enabled: (.enabled // "auto"),
      config: (.config // null),
      start_timeout: (.start_timeout // 300) }),
  environment: (.environment // {}),
  windows: ((.windows // []) | map({
      name: .name,
      agent: (.agent // null),
      command: (.command // null),
      cwd: (.cwd // null),
      location: (.location // null),
      focus: (.focus // false) })) }
'
# `location` normalizes to null, NOT to "container". Spec §4.1 reads "Default
# container when one exists" — the default is conditional on the workspace
# having a container, so it cannot be resolved here, where no record is in
# scope. Collapsing unset to "container" at normalize time is what made a plain
# repository unopenable: agent-1, agent-2 and shell would demand a container
# binding that `devcontainer.enabled: auto` correctly never creates.
# `dev_window_location` (Task 10) resolves null against the record instead, and
# an EXPLICIT `location: container` still fails loudly on a repo with no
# container, because that one the user actually asked for.

dev_config_layer_json() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '{}\n'
    return 0
  fi
  yq -o=json -I=0 '.' "$file"
}

# worktree is accepted for signature stability; no Phase 1 layer is keyed by it
# (ADR-7 ships no per-worktree configuration layer).
dev_config_merged() {
  local slug="$1" worktree="$2" acc layer file
  : "$worktree"
  acc='{}'
  for file in \
    "$DEV_DOTFILES_ROOT/tools/dev/default-workspace.yaml" \
    "$DEV_OVERLAY_ROOT/$slug/workspace.yaml" \
    "$DEV_OVERLAY_ROOT/$slug/workspace.local.yaml"; do
    layer="$(dev_config_layer_json "$file")" || return 1
    acc="$(jq -c -n --argjson a "$acc" --argjson b "$layer" "$DEV_CONFIG_MERGE_JQ")" || return 1
  done
  # -S -c: sorted keys, one line, so the digest ignores cosmetic edits.
  printf '%s\n' "$acc" | jq -S -c "$DEV_CONFIG_NORMALIZE_JQ"
}

dev_config_digest() {
  local json="$1" sum
  sum="$(printf '%s' "$json" | sha256sum | cut -d' ' -f1)"
  printf 'sha256:%s\n' "$sum"
}

dev_config_validate() {
  local json="$1" problem
  problem="$(printf '%s' "$json" | jq -r '
    def problems:
      (if (.version != 1) then ["version must be 1, got \(.version | tostring)"] else [] end)
      + ((.windows // []) | map(select(.agent != null and .command != null)
          | "window \(.name) sets both agent and command") )
      + ((.windows // []) | map(select(.location != null and (.location
          | IN("container","host") | not))
          | "window \(.name) has invalid location \(.location | tostring)") )
      + ((.windows // []) | map(select(.name == null or ((.name | tostring)
          | test("^[A-Za-z0-9._-]+$") | not))
          | "window \(.name | tostring) has an invalid name; use [A-Za-z0-9._-]") )
      + ([(.windows // []) | group_by(.name)[] | select(length > 1)
          | "window \(.[0].name) is defined more than once"])
      + (if (((.windows // []) | map(select(.focus == true)) | length) > 1)
         then [((.windows // []) | map(select(.focus == true) | .name) | join(", "))
               | "more than one window sets focus: \(.)"]
         else [] end);
    problems | first // ""')" || return 1
  [[ -z "$problem" ]] && return 0
  printf 'invalid workspace config: %s\n' "$problem" >&2
  return 5
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats tests/dev_config_merge.bats`
Expected: PASS (18 tests, 0 failures)

`dev_config_merged` must leave `location` as JSON `null` for `agent-1`, `agent-2` and `shell`, and
as `"host"` for `scratch`. Any later commit that reintroduces `// "container"` here breaks plain
(non-devcontainer) repositories, which is the failure this normalization shape exists to prevent.

- [ ] **Step 6: Check formatting and lint**

Run: `shfmt -d -i 2 -ci tools/dev/lib/config.sh && shellcheck -x -S warning -e SC1091 tools/dev/lib/config.sh`
Expected: no diff, no findings.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/lib/config.sh tools/dev/default-workspace.yaml tests/dev_config_merge.bats
git commit -m "feat(dev): merge workspace config by window name with a stable digest"
```
### Task 5: `tools/dev/lib/events.sh` — the event stream

**Files:**
- Create: `tools/dev/lib/events.sh`
- Create: `tests/dev_state_events.bats` (Task 6 appends its tests to this same file)

**Interfaces:**
- Consumes: `setup_dev_test()` (Task 3, tests only).
- Produces:
  - `dev_now` → RFC 3339 UTC with milliseconds
  - `dev_event_id_random` → 16 hex
  - `dev_event_id_deterministic <workspace_id> <event_type> <discriminator>` → 16 hex
  - `dev_event_build <id> <ts> <event> <workspace_id> <slug> <session_name> <worktree> <data_json>` → one-line JSON
  - `dev_event_append <line>`
  - `dev_events_segments` → segment paths, oldest first
  - `dev_events_read_all` → every event oldest-first, one per line
  - `dev_events_has_id <id>` → exit 0 if present
  - `dev_events_rotate_if_needed`

Three roles touch `events/`: appenders take `flock -s` on `locks/events.lock`, the fold's reader
takes `flock -s`, rotation takes `flock -x`. Shared holders never contend, so the hook path stays
effectively uncontended and only rotation blocks. `dev_events_rotate_if_needed` is called from
reconcile (Task 8) **after** the fold has released its shared lock; calling it while the fold's
`flock -s` is still held self-deadlocks, because `flock` locks are per open-file-description and a
second descriptor in the same process contends with the first.

Discovery event ids are deterministic (`sha256(workspace_id || event_type || discriminator)`
truncated to 16 hex) so that reconcile's emit-then-commit ordering stays idempotent: a CAS retry
recomputes the same id, `dev_events_has_id` finds it, and the append is skipped instead of
duplicated (ADR-1). The discriminator is opaque to this function — it is the caller's job to make it
name the occasion and not just the subject, and Task 8 documents the composite each event type uses.
Getting that wrong does not corrupt anything; it silently *drops* a later real event, which is why
the composition is argued at each call site rather than left to the reader.

- [ ] **Step 1: Write the failing unit tests**

Create `tests/dev_state_events.bats`:

```bash
#!/usr/bin/env bats

load test_helper

WS_ID=9f2c4a7b1e05de3c8a41f07b2e6d95c3a8b17f42e0d6c95183ba7e4f2c0d68a9

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
}

# Writes `$1` filler event lines into the live segment. The line is ~190 bytes, so
# 50000 lines is ~9.5 MiB, comfortably past the 8 MiB rotation threshold.
fill_events() {
  head -n "$1" < <(yes '{"v":1,"id":"filler","ts":"2026-08-03T00:00:00.000Z","event":"window.created","workspace_id":"filler","slug":"f","session_name":"f","worktree":"/f","data":{"window":"w","location":"host"}}') \
    >"$DEV_STATE_ROOT/events/events.jsonl"
}

@test "events: dev_now is RFC 3339 UTC with milliseconds" {
  local now
  now=$(dev_now)
  [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}

@test "events: the envelope round-trips with all eight fields plus v" {
  local line
  line=$(dev_event_build 4b1e05a7c39f2d18 2026-08-03T14:02:11.412Z container.replaced \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
    '{"old_id":"3f9c","new_id":"a710","reason":"rebuild"}')
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ]
  [ "$(jq -r .v <<<"$line")" = 1 ]
  [ "$(jq -r .id <<<"$line")" = 4b1e05a7c39f2d18 ]
  [ "$(jq -r .ts <<<"$line")" = 2026-08-03T14:02:11.412Z ]
  [ "$(jq -r .event <<<"$line")" = container.replaced ]
  [ "$(jq -r .workspace_id <<<"$line")" = "$WS_ID" ]
  [ "$(jq -r .slug <<<"$line")" = slabledger ]
  [ "$(jq -r .session_name <<<"$line")" = slabledger ]
  [ "$(jq -r .worktree <<<"$line")" = /home/tng/workspace/slabledger ]
  [ "$(jq -r .data.reason <<<"$line")" = rebuild ]
  [ "$(jq -r 'keys_unsorted | join(",")' <<<"$line")" = "v,id,ts,event,workspace_id,slug,session_name,worktree,data" ]
}

@test "events: an oversized payload is truncated and marked" {
  local big data line written
  big=$(head -c 6000 </dev/zero | tr '\0' 'x')
  data=$(jq -c -n --arg s "$big" '{stderr_tail: $s}')
  line=$(dev_event_build 0123456789abcdef 2026-08-03T14:02:11.412Z container.failed \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger "$data")
  [ "$(printf '%s' "$line" | wc -c)" -gt 4096 ]
  dev_event_append "$line"
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -le 4097 ]
  written=$(cat "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r .event <<<"$written")" = container.failed ]
  [ "$(jq -r .id <<<"$written")" = 0123456789abcdef ]
  [ "$(jq -r .data.truncated <<<"$written")" = true ]
  [ -n "$(jq -r .data.raw <<<"$written")" ]
}

@test "events: a payload under the cap is written verbatim" {
  local line
  line=$(dev_event_build 0123456789abcdef 2026-08-03T14:02:11.412Z agent.started \
    "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
    '{"window":"agent-1","command":"claude"}')
  dev_event_append "$line"
  [ "$(cat "$DEV_STATE_ROOT/events/events.jsonl")" = "$line" ]
}

@test "events: random ids are 16 hex and differ between calls" {
  local a b
  a=$(dev_event_id_random)
  b=$(dev_event_id_random)
  [[ "$a" =~ ^[0-9a-f]{16}$ ]]
  [[ "$b" =~ ^[0-9a-f]{16}$ ]]
  [ "$a" != "$b" ]
}

@test "events: deterministic ids are stable and discriminator-sensitive" {
  local a b c d
  a=$(dev_event_id_deterministic "$WS_ID" container.lost a710deadbeef)
  b=$(dev_event_id_deterministic "$WS_ID" container.lost a710deadbeef)
  c=$(dev_event_id_deterministic "$WS_ID" container.lost 3f9cfeedface)
  d=$(dev_event_id_deterministic "$WS_ID" config.changed a710deadbeef)
  [[ "$a" =~ ^[0-9a-f]{16}$ ]]
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
  [ "$a" != "$d" ]
}

@test "events: segments list rotated files oldest-first with the live file last" {
  : >"$DEV_STATE_ROOT/events/events.jsonl"
  : >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  : >"$DEV_STATE_ROOT/events/events-20260802T000000Z.jsonl"
  run dev_events_segments
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl" ]
  [ "${lines[1]}" = "$DEV_STATE_ROOT/events/events-20260802T000000Z.jsonl" ]
  [ "${lines[2]}" = "$DEV_STATE_ROOT/events/events.jsonl" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "events: read_all returns rotated events before live ones" {
  dev_event_build aaaa000000000001 2026-08-03T13:00:00.000Z window.created \
    "$WS_ID" s s /w '{"window":"shell","location":"host"}' \
    >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  dev_event_build aaaa000000000002 2026-08-03T14:00:00.000Z window.created \
    "$WS_ID" s s /w '{"window":"scratch","location":"host"}' \
    >"$DEV_STATE_ROOT/events/events.jsonl"
  run dev_events_read_all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(jq -r .id <<<"${lines[0]}")" = aaaa000000000001 ]
  [ "$(jq -r .id <<<"${lines[1]}")" = aaaa000000000002 ]
}

@test "events: has_id finds ids in rotated segments and in the live file" {
  dev_event_build aaaa000000000001 2026-08-03T13:00:00.000Z workspace.stopped \
    "$WS_ID" s s /w '{"reason":"user"}' \
    >"$DEV_STATE_ROOT/events/events-20260801T000000Z.jsonl"
  dev_event_build aaaa000000000002 2026-08-03T14:00:00.000Z workspace.attached \
    "$WS_ID" s s /w '{"client":"/dev/pts/3"}' \
    >"$DEV_STATE_ROOT/events/events.jsonl"
  run dev_events_has_id aaaa000000000001
  [ "$status" -eq 0 ]
  run dev_events_has_id aaaa000000000002
  [ "$status" -eq 0 ]
  run dev_events_has_id aaaa00000000ffff
  [ "$status" -ne 0 ]
}

@test "events: rotation is a no-op below the threshold" {
  fill_events 100
  dev_events_rotate_if_needed
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 100 ]
  [ "$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)" -eq 0 ]
}

@test "events: rotation past the threshold empties the live file into a segment" {
  fill_events 50000
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -gt 8388608 ]
  dev_events_rotate_if_needed
  [ "$(wc -c <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 0 ]
  local segs
  segs=$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)
  [ "$segs" -eq 1 ]
  [ "$(cat "$DEV_STATE_ROOT"/events/events-*.jsonl | wc -l)" -eq 50000 ]
}

@test "events: two rotations in the same second keep both segments" {
  # The regression: a second-resolution stamp plus a bare `mv` overwrote the
  # first segment, losing 50k events with no error. Nothing here sleeps, so the
  # two rotations land in the same second on any machine.
  fill_events 50000
  dev_events_rotate_if_needed
  fill_events 50000
  dev_events_rotate_if_needed

  local d="$DEV_STATE_ROOT/events"
  [ "$(find "$d" -name 'events-*.jsonl' | wc -l)" -eq 2 ]
  [ "$(cat "$d"/events-*.jsonl | wc -l)" -eq 100000 ]

  # And they are ordered oldest-first, which is what read_all depends on.
  run dev_events_segments
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[2]}" = "$d/events.jsonl" ]
  [[ "${lines[0]}" < "${lines[1]}" ]]
}

@test "events: retention keeps exactly five rotated segments" {
  local d="$DEV_STATE_ROOT/events" n
  for n in 01 02 03 04 05 06; do
    printf 'old-%s\n' "$n" >"$d/events-202001${n}T000000Z.jsonl"
  done
  fill_events 50000
  dev_events_rotate_if_needed
  [ "$(find "$d" -name 'events-*.jsonl' | wc -l)" -eq 5 ]
  [ ! -e "$d/events-2020010" ]
  [ ! -e "$d/events-20200101T000000Z.jsonl" ]
  [ ! -e "$d/events-20200102T000000Z.jsonl" ]
  [ -e "$d/events-20200103T000000Z.jsonl" ]
  [ -e "$d/events-20200106T000000Z.jsonl" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_state_events.bats`
Expected: FAIL — every test errors with
`tests/dev_state_events.bats: line N: /home/tng/.dotfiles/tools/dev/lib/events.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

Create `tools/dev/lib/events.sh`:

```bash
#!/usr/bin/env bash
# Event stream: one append-only JSONL file per host, rotated by size.
#
# Locking (spec §4.4, ADR-1): appends take `flock -s` on locks/events.lock, the
# fold's reader takes `flock -s` across BOTH listing and reading the segments,
# rotation takes `flock -x`. flock is per open-file-description, so taking the
# exclusive lock while this process still holds the shared one deadlocks: call
# dev_events_rotate_if_needed only after the fold has released.
#
# This file is sourced. It defines functions and does no work at source time.

DEV_EVENT_MAX_BYTES=4096
DEV_EVENTS_ROTATE_BYTES=8388608
DEV_EVENTS_KEEP_SEGMENTS=5

dev_now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

dev_event_id_random() {
  openssl rand -hex 8
}

# Discovery events (workspace.vanished, container.lost, config.changed) derive
# their id from what was discovered, so a CAS retry recomputes the same id and
# the append is skipped instead of duplicated (ADR-1).
dev_event_id_deterministic() {
  printf '%s' "${1}${2}${3}" | sha256sum | cut -c1-16
}

dev_event_build() {
  local id=$1 ts=$2 event=$3 workspace_id=$4 slug=$5 session_name=$6 worktree=$7
  local data=${8:-}
  [[ -n "$data" ]] || data='{}'
  jq -c -n \
    --arg id "$id" \
    --arg ts "$ts" \
    --arg event "$event" \
    --arg workspace_id "$workspace_id" \
    --arg slug "$slug" \
    --arg session_name "$session_name" \
    --arg worktree "$worktree" \
    --argjson data "$data" \
    '{
      v: 1,
      id: $id,
      ts: $ts,
      event: $event,
      workspace_id: $workspace_id,
      slug: $slug,
      session_name: $session_name,
      worktree: $worktree,
      data: $data
    }'
}

# Appends one composed line. The whole line is emitted by a single printf whose
# redirection is outside it, so the kernel sees exactly one write(2) against an
# O_APPEND descriptor; two syscalls could interleave with another appender's.
dev_event_append() {
  local line=$1
  local file="$DEV_STATE_ROOT/events/events.jsonl"
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  local size
  mkdir -p "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks"
  size=$(printf '%s' "$line" | wc -c)
  if ((size > DEV_EVENT_MAX_BYTES)); then
    # Replace free-form data with a truncated rendering and mark it. The budget
    # is an estimate (character vs byte width, JSON escaping), so the loop
    # re-measures and halves until the composed line fits.
    local raw budget candidate
    raw=$(printf '%s' "$line" | jq -c '.data')
    budget=$((DEV_EVENT_MAX_BYTES - (size - ${#raw}) - 64))
    ((budget > 0)) || budget=0
    while :; do
      candidate=$(printf '%s' "$line" |
        jq -c --arg raw "${raw:0:budget}" '.data = {truncated: true, raw: $raw}')
      size=$(printf '%s' "$candidate" | wc -c)
      if ((size <= DEV_EVENT_MAX_BYTES)) || ((budget == 0)); then
        line=$candidate
        break
      fi
      budget=$((budget / 2))
    done
  fi
  { flock -s 9 && printf '%s\n' "$line" >>"$file"; } 9>"$lock"
}

# Rotated segments carry an RFC 3339 basic stamp, so glob order (lexicographic)
# is chronological. The live file sorts last because it is printed last.
dev_events_segments() {
  local dir="$DEV_STATE_ROOT/events"
  local seg
  for seg in "$dir"/events-*.jsonl; do
    if [[ -f "$seg" ]]; then
      printf '%s\n' "$seg"
    fi
  done
  if [[ -f "$dir/events.jsonl" ]]; then
    printf '%s\n' "$dir/events.jsonl"
  fi
  return 0
}

# Holds the shared lock across both listing the segments and reading them.
# Releasing between the two lets rotation delete an enumerated segment, and the
# resulting short read is indistinguishable from an unreachable cursor — a
# fold_gap manufactured by the reader itself (ADR-1).
dev_events_read_all() {
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  mkdir -p "$DEV_STATE_ROOT/locks"
  {
    flock -s 9
    local -a segs=()
    mapfile -t segs < <(dev_events_segments)
    if ((${#segs[@]} > 0)); then
      cat "${segs[@]}"
    fi
  } 9>"$lock"
  return 0
}

dev_events_has_id() {
  local id=$1
  dev_events_read_all | jq -e -s --arg id "$id" 'any(.[]; .id == $id)' >/dev/null
}

dev_events_rotate_if_needed() {
  local dir="$DEV_STATE_ROOT/events"
  local live="$dir/events.jsonl"
  local lock="$DEV_STATE_ROOT/locks/events.lock"
  mkdir -p "$dir" "$DEV_STATE_ROOT/locks"
  {
    flock -x 9
    [[ -f "$live" ]] || return 0
    local size
    size=$(wc -c <"$live")
    ((size > DEV_EVENTS_ROTATE_BYTES)) || return 0

    # Sub-second precision plus a collision counter. A bare second-resolution
    # stamp and a bare `mv` silently destroyed a segment when two rotations
    # landed in the same second -- possible here because the threshold is a size,
    # so a burst of appends can cross it twice in quick succession.
    #
    # The counter is present in EVERY name, not only on collision, and both parts
    # are fixed-width. Segment order is lexical (the glob below and
    # `dev_events_segments` both rely on it), and `-00` sorting against a bare
    # `.jsonl` would put the newer file first: `-` is 0x2D, `.` is 0x2E. Uniform
    # names remove that trap. Zero-padded %N sorts correctly for the same reason.
    local stamp target n=0
    stamp=$(date -u +%Y%m%dT%H%M%S.%NZ)
    printf -v target '%s/events-%s-%02d.jsonl' "$dir" "$stamp" "$n"
    while [[ -e "$target" ]]; do
      n=$((n + 1))
      # Bounded: something is badly wrong if this many segments share a
      # nanosecond, and rotating is never worth spinning forever over.
      ((n < 100)) || return 0
      printf -v target '%s/events-%s-%02d.jsonl' "$dir" "$stamp" "$n"
    done
    mv "$live" "$target"
    : >"$live"
    local -a rotated=()
    local seg
    for seg in "$dir"/events-*.jsonl; do
      if [[ -f "$seg" ]]; then
        rotated+=("$seg")
      fi
    done
    local excess=$((${#rotated[@]} - DEV_EVENTS_KEEP_SEGMENTS))
    if ((excess > 0)); then
      rm -f "${rotated[@]:0:excess}"
    fi
  } 9>"$lock"
  return 0
}
```

Two honest limits, both deliberate. If the *envelope* alone exceeded 4 KiB — a pathological
worktree path — the line is written oversized rather than dropped; a visibly long event beats a lost
one. And byte-slicing `raw` can cut a multi-byte UTF-8 sequence, which `jq --arg` replaces with
U+FFFD; the line stays valid JSON, which is the property that matters.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dev_state_events.bats`
Expected: PASS (13 tests, 0 failures)

- [ ] **Step 5: Write the concurrency test**

Append to `tests/dev_state_events.bats`. This is the test §4.4 calls non-optional: 20 concurrent
appenders emitting 25 events each, with a rotation and a full read running against the same file.

```bash
@test "events: concurrent appends survive a rotation and a concurrent read" {
  local i j
  # Pre-fill past the threshold so the concurrent rotation actually fires while
  # the appenders are running.
  fill_events 50000

  for i in $(seq 1 20); do
    (
      local j line
      for j in $(seq 1 25); do
        line=$(dev_event_build "$(printf 'ev%03d%03d' "$i" "$j")" \
          2026-08-03T14:00:00.000Z agent.started \
          "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger \
          '{"window":"agent-1","command":"claude"}')
        dev_event_append "$line"
      done
    ) &
  done
  dev_events_rotate_if_needed &
  dev_events_read_all >"$TEST_ROOT/read-all.jsonl" &
  wait

  dev_events_segments >"$TEST_ROOT/segments.txt"
  xargs -a "$TEST_ROOT/segments.txt" cat >"$TEST_ROOT/all.jsonl"

  # Every line in every segment parses as JSON — no interleaved writes.
  jq -c . "$TEST_ROOT/all.jsonl" >/dev/null
  # The concurrent reader saw whole lines too, never a half-written one.
  jq -c . "$TEST_ROOT/read-all.jsonl" >/dev/null

  # Every emitted id appears exactly once across the live file and all segments.
  jq -r 'select(.id | startswith("ev")) | .id' "$TEST_ROOT/all.jsonl" \
    | sort >"$TEST_ROOT/got.txt"
  for i in $(seq 1 20); do
    for j in $(seq 1 25); do
      printf 'ev%03d%03d\n' "$i" "$j"
    done
  done | sort >"$TEST_ROOT/want.txt"
  [ "$(wc -l <"$TEST_ROOT/got.txt")" -eq 500 ]
  diff "$TEST_ROOT/want.txt" "$TEST_ROOT/got.txt"

  # Rotation ran: the filler lines are in a segment, not the live file.
  [ "$(find "$DEV_STATE_ROOT/events" -name 'events-*.jsonl' | wc -l)" -eq 1 ]
  [ "$(grep -c '"id":"filler"' "$TEST_ROOT/all.jsonl")" -eq 50000 ]
}
```

- [ ] **Step 6: Run the concurrency test**

Run: `bats tests/dev_state_events.bats`
Expected: PASS (14 tests, 0 failures). If `diff` reports missing ids, an append was lost to a
rename; if `jq -c .` reports a parse error, an event was emitted in more than one `write`.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/lib/events.sh tests/dev_state_events.bats
git commit -m "feat(dev): append-only event stream with shared-lock appends and size rotation"
```

---

### Task 6: `tools/dev/lib/state.sh` — workspace records and compare-and-swap

**Files:**
- Create: `tools/dev/lib/state.sh`
- Modify: `tests/dev_state_events.bats` (source `state.sh` in `setup()`, append tests)

**Interfaces:**
- Consumes: `setup_dev_test()` (Task 3, tests only). Nothing from Task 5 at runtime.
- Produces:
  - `dev_state_path <workspace_id>` → `$DEV_STATE_ROOT/workspaces/<workspace_id>.json`
  - `dev_state_new <workspace_id> <slug> <session_name> <worktree>` → fresh v1 record JSON
  - `dev_state_read <workspace_id>` → record JSON, or empty output + exit 1 when absent
  - `dev_state_commit <workspace_id> <expected_json> <new_json>` → 0 on success, 9 on mismatch
  - `dev_state_list` → every record path, newline-separated
  - `dev_state_session_name <workspace_id> <fallback>` → the recorded session name, else the fallback

`dev_state_commit` holds `locks/<workspace_id>.lock` across **nothing but** the read-compare-write:
re-read the record, compare it canonically against `expected_json`, write via a temp file in the
same directory plus `mv`, release. No subprocess that can block runs inside it — no backend query,
no `devcontainer up`, no scan of the event log (ADR-3 trigger 4, ADR-1's "microseconds, no blocking
subprocess inside it, ever"). The only child processes are `jq` over one small record and `mktemp`,
both bounded. Reconcile's observe-and-compute phase runs entirely outside this lock.

The comparison canonicalizes both sides with `jq -S -c .` so that a caller which rebuilt its
expectation through a different jq pipeline — and got a different key order for the same value —
does not see a spurious mismatch and burn a CAS attempt. An absent record compares equal to an
empty `expected_json`; that is how the first write of a workspace happens.

- [ ] **Step 1: Write the failing tests**

Replace `setup()` in `tests/dev_state_events.bats` with:

```bash
setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
}
```

Then append:

```bash
@test "state: the record path uses the full 64-hex workspace id" {
  local path
  path=$(dev_state_path "$WS_ID")
  [ "$path" = "$DEV_STATE_ROOT/workspaces/$WS_ID.json" ]
  [ "${#WS_ID}" -eq 64 ]
  dev_state_commit "$WS_ID" "" "$(dev_state_new "$WS_ID" slabledger slabledger /w)"
  [ -f "$path" ]
  [ "$(basename "$path")" = "$WS_ID.json" ]
}

@test "state: a fresh record has the v1 shape" {
  local rec
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
  [ "$(jq -r .v <<<"$rec")" = 1 ]
  [ "$(jq -r .workspace_id <<<"$rec")" = "$WS_ID" ]
  [ "$(jq -r .slug <<<"$rec")" = slabledger ]
  [ "$(jq -r .session_name <<<"$rec")" = slabledger ]
  [ "$(jq -r .worktree <<<"$rec")" = /home/tng/workspace/slabledger ]
  [ "$(jq -r .status <<<"$rec")" = unknown ]
  [ "$(jq -r .boot_id <<<"$rec")" = null ]
  [ "$(jq -r .config_digest <<<"$rec")" = null ]
  [ "$(jq -r .applied_digest <<<"$rec")" = null ]
  [ "$(jq -c .container <<<"$rec")" = '{"status":"none","kind":null,"id":null,"user":null,"workdir":null,"verified":false,"up_exit_status":null,"up_result":null,"observed_at":null}' ]
  [ "$(jq -c .agents <<<"$rec")" = '[]' ]
  [ "$(jq -r .opened_at <<<"$rec")" = null ]
  [ "$(jq -r .last_seen <<<"$rec")" = null ]
  [ "$(jq -r .scanned_through <<<"$rec")" = null ]
  [ "$(jq -r .fold_gap <<<"$rec")" = false ]
  [ "$(jq -r .stopped_reason <<<"$rec")" = null ]
}

@test "state: a fresh record round-trips through commit and read unchanged" {
  local rec out
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
  run dev_state_commit "$WS_ID" "" "$rec"
  [ "$status" -eq 0 ]
  out=$(dev_state_read "$WS_ID")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]
}

@test "state: reading an absent record exits 1 with no output" {
  run dev_state_read "$WS_ID"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "state: committing over an absent record requires an empty expectation" {
  local rec
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  run dev_state_commit "$WS_ID" "$rec" "$rec"
  [ "$status" -eq 9 ]
  [ ! -e "$(dev_state_path "$WS_ID")" ]
}

@test "state: a stale expectation exits 9 and leaves the file untouched" {
  local rec stale new before after path
  path=$(dev_state_path "$WS_ID")
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  before=$(cat "$path")
  stale=$(jq -c '.status = "running"' <<<"$rec")
  new=$(jq -c '.status = "stopped"' <<<"$rec")
  run dev_state_commit "$WS_ID" "$stale" "$new"
  [ "$status" -eq 9 ]
  after=$(cat "$path")
  [ "$before" = "$after" ]
}

@test "state: a reordered expectation still matches" {
  local rec reordered new
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  reordered=$(jq -c 'to_entries | reverse | from_entries' <<<"$rec")
  [ "$reordered" != "$rec" ]
  new=$(jq -c '.status = "running"' <<<"$rec")
  run dev_state_commit "$WS_ID" "$reordered" "$new"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <"$(dev_state_path "$WS_ID")")" = running ]
}

@test "state: two concurrent committers give one winner and one exit-9 loser" {
  local rec a b rca rcb final
  rec=$(dev_state_new "$WS_ID" slabledger slabledger /w)
  dev_state_commit "$WS_ID" "" "$rec"
  a=$(jq -c '.status = "running"' <<<"$rec")
  b=$(jq -c '.status = "stopped"' <<<"$rec")
  (
    rc=0
    dev_state_commit "$WS_ID" "$rec" "$a" || rc=$?
    printf '%s\n' "$rc" >"$TEST_ROOT/rc-a"
  ) &
  (
    rc=0
    dev_state_commit "$WS_ID" "$rec" "$b" || rc=$?
    printf '%s\n' "$rc" >"$TEST_ROOT/rc-b"
  ) &
  wait
  rca=$(cat "$TEST_ROOT/rc-a")
  rcb=$(cat "$TEST_ROOT/rc-b")
  # Exactly one winner (0) and one CAS loser (9).
  [ "$((rca + rcb))" -eq 9 ]
  [ "$rca" -ne "$rcb" ]
  final=$(jq -r .status <"$(dev_state_path "$WS_ID")")
  [[ "$final" = running || "$final" = stopped ]]
  # The loser wrote nothing: the file is exactly one of the two candidates.
  [ "$(jq -S -c . <"$(dev_state_path "$WS_ID")")" = "$(jq -S -c . <<<"$a")" ] ||
    [ "$(jq -S -c . <"$(dev_state_path "$WS_ID")")" = "$(jq -S -c . <<<"$b")" ]
}

@test "state: list returns every record path" {
  local other=1111111111111111111111111111111111111111111111111111111111111111
  dev_state_commit "$WS_ID" "" "$(dev_state_new "$WS_ID" a a /a)"
  dev_state_commit "$other" "" "$(dev_state_new "$other" b b /b)"
  run dev_state_list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$DEV_STATE_ROOT/workspaces/$other.json" ]
  [ "${lines[1]}" = "$DEV_STATE_ROOT/workspaces/$WS_ID.json" ]
}

@test "state: list is empty when no records exist" {
  run dev_state_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state: the recorded session name beats the resolver's proposal" {
  # ADR-7's collision guard may have renamed this workspace to
  # `<slug>--<basename>--<hash6>`. That rename is durable, so every command
  # after the first `open` must read it back rather than re-derive the plain
  # name -- re-deriving is what left a collided workspace unreachable.
  local rec
  rec=$(dev_state_new "$WS_ID" demo demo /w)
  rec=$(jq -c '.session_name = "demo--feat--a1b2c3"' <<<"$rec")
  dev_state_commit "$WS_ID" "" "$rec"

  run dev_state_session_name "$WS_ID" demo
  [ "$status" -eq 0 ]
  [ "$output" = "demo--feat--a1b2c3" ]
}

@test "state: the fallback is used only when no record exists yet" {
  # The first `dev open`, which is exactly when the resolver's proposal is right.
  run dev_state_session_name "$(printf 'f%.0s' {1..64})" demo
  [ "$status" -eq 0 ]
  [ "$output" = "demo" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_state_events.bats`
Expected: FAIL — every test errors with
`tests/dev_state_events.bats: line N: /home/tng/.dotfiles/tools/dev/lib/state.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

Create `tools/dev/lib/state.sh`:

```bash
#!/usr/bin/env bash
# Workspace records: one JSON file per working tree, keyed by the path digest.
#
# The state lock (locks/<workspace_id>.lock) is held across the read-compare-write
# in dev_state_commit and nothing else — no backend query, no container command,
# no event scan (ADR-1, ADR-3 trigger 4). Reconcile observes and computes with no
# lock held and calls in here only to commit.
#
# This file is sourced. It defines functions and does no work at source time.

dev_state_path() {
  printf '%s\n' "$DEV_STATE_ROOT/workspaces/$1.json"
}

dev_state_new() {
  local workspace_id=$1 slug=$2 session_name=$3 worktree=$4
  jq -c -n \
    --arg workspace_id "$workspace_id" \
    --arg slug "$slug" \
    --arg session_name "$session_name" \
    --arg worktree "$worktree" \
    '{
      v: 1,
      workspace_id: $workspace_id,
      session_name: $session_name,
      slug: $slug,
      worktree: $worktree,
      status: "unknown",
      boot_id: null,
      config_digest: null,
      applied_digest: null,
      container: {
        status: "none",
        kind: null,
        id: null,
        user: null,
        workdir: null,
        verified: false,
        up_exit_status: null,
        up_result: null,
        observed_at: null
      },
      agents: [],
      opened_at: null,
      last_seen: null,
      scanned_through: null,
      fold_gap: false,
      stopped_reason: null
    }'
}

dev_state_read() {
  local path
  path=$(dev_state_path "$1")
  [[ -f "$path" ]] || return 1
  cat "$path"
}

# Compare-and-swap. Exit 0 when new_json was written, 9 when the on-disk record
# no longer equals expected_json. An absent record equals an empty expectation.
dev_state_commit() {
  local workspace_id=$1 expected=$2 new=$3
  local path lock
  path=$(dev_state_path "$workspace_id")
  lock="$DEV_STATE_ROOT/locks/$workspace_id.lock"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/locks"
  {
    flock -x 9
    local current="" want="" tmp
    if [[ -f "$path" ]]; then
      # Canonical form on both sides: key order must not fake a mismatch.
      current=$(jq -S -c . <"$path")
    fi
    if [[ -n "$expected" ]]; then
      want=$(printf '%s' "$expected" | jq -S -c .)
    fi
    [[ "$current" == "$want" ]] || return 9
    tmp=$(mktemp "$path.XXXXXX")
    printf '%s\n' "$new" >"$tmp"
    mv -f "$tmp" "$path"
  } 9>"$lock"
}

dev_state_list() {
  local record
  for record in "$DEV_STATE_ROOT/workspaces"/*.json; do
    if [[ -f "$record" ]]; then
      printf '%s\n' "$record"
    fi
  done
  return 0
}

# dev_state_session_name <workspace_id> <fallback>
#
# The recorded session name wins over the resolver's proposal, always.
#
# `dev_resolve` derives a name from the slug and worktree basename, which is a
# GUESS: ADR-7's collision guard may have renamed this workspace to
# `<slug>--<basename>--<hash6>` when another working tree already held the
# plain name. That rename is durable — `workspace.opened` carries
# `session_name_actual` and the fold writes it into the record — so every later
# command must start from the record, not re-derive the guess.
#
# Re-deriving is what made a collided workspace unreachable: once the
# CONFLICTING session went away, `dev attach` looked up the plain name, found
# nothing, and reported no live session while the hashed one was still running;
# `dev open` then created a second session for the same working tree.
#
# The fallback is used only for a workspace with no record yet, i.e. the first
# `dev open`, which is exactly when the resolver's proposal is correct.
dev_state_session_name() {
  local workspace_id="$1" fallback="$2" record name
  if record=$(dev_state_read "$workspace_id" 2>/dev/null); then
    name=$(printf '%s' "$record" | jq -r '.session_name // ""')
    if [[ -n "$name" && "$name" != null ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}
```

`mktemp` creates the temp file in the record's own directory, so the `mv` is a same-filesystem
rename and a reader either sees the old record or the new one, never a partial write.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dev_state_events.bats`
Expected: PASS (26 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add tools/dev/lib/state.sh tests/dev_state_events.bats
git commit -m "feat(dev): workspace records with compare-and-swap commits under the state lock"
```

---

### Task 7: `tools/dev/lib/fold.sh` — the event fold

**Files:**
- Create: `tools/dev/lib/fold.sh`
- Create: `tests/dev_fold.bats`

**Interfaces:**
- Consumes: `dev_state_new <workspace_id> <slug> <session_name> <worktree>` (Task 6) and
  `dev_event_build <id> <ts> <event> <workspace_id> <slug> <session_name> <worktree> <data_json>`
  (Task 5) — both in tests only; `fold.sh` itself sources nothing.
- Produces:
  - `dev_fold_apply <record_json> <event_json>` → the record after folding that one event
  - `dev_fold_stream <record_json>` (events on stdin, one per line) → the record after folding
    every event newer than `scanned_through`, cursor advanced
  - `dev_fold_jq_program` → the jq source shared by both (internal to this file; no other task
    calls it)

Task 8 pipes `dev_events_read_all` into `dev_fold_stream`, then commits with `dev_state_commit`.

The transition table is §4.4 implemented literally. Four rules carry the design and are the ones a
reviewer should check first:

- **No `container.*` event writes `status`, and no `workspace.*` event writes `container.status`.**
  A workspace whose container failed is still a live tmux session with working host-side panes;
  reporting it `stopped` is a lie the user can disprove by looking at it (ADR-2).
- **`container.ready` replaces the whole `container` object.** A rebuild can change `remoteUser`,
  `workspaceFolder`, or move a project between single-container and compose, so patching the id
  alone yields `docker exec -u vscode -w /workspace` against a container where neither is right.
  One event type writes the binding, and it is the one that observes it.
- **Only `workspace.attached`/`detached` write `last_seen` in the fold.** Reconcile sets it at
  observation time; the fold-equivalence test in Task 19 depends on knowing exactly which fields the
  fold owns.
- **Every transition is an absolute assignment**, which is what makes replay idempotent. Nothing
  increments, nothing appends to a list except `agent_upsert`, which is keyed by window and so
  converges.

`scanned_through` is a **global scan cursor**, not a last-applied cursor: it advances across events
belonging to other workspaces too. Storing the last event *applied* is the mistake ADR-1 calls out —
an idle workspace's cursor would age while the file churns until its own last transition rotated
away, reporting `fold_gap` although it missed nothing. A false gap is worse than no flag, because it
teaches a consumer to ignore the flag.

Timestamps compare as strings: RFC 3339 UTC with fixed-width milliseconds and a literal `Z` makes
lexicographic order chronological.

When `scanned_through.id` is non-null and absent from every retained segment, `dev_fold_stream` sets
`fold_gap: true`, folds nothing, and leaves the cursor alone; the caller falls back to pure
observation, which is always current, so the loss is history rather than correctness. The driver
never clears `fold_gap` — only `workspace.opened` does. One consequence worth stating because it is
not obvious: an unreachable cursor stays unreachable, so the record keeps re-flagging on every
subsequent pass until the next `workspace.opened`. Re-anchoring the cursor is reconcile's call
(Task 8), not the fold's; the fold must not silently paper over a gap it was asked to report.

- [ ] **Step 1: Write the failing tests**

Create `tests/dev_fold.bats`:

```bash
#!/usr/bin/env bats

load test_helper

WS_ID=9f2c4a7b1e05de3c8a41f07b2e6d95c3a8b17f42e0d6c95183ba7e4f2c0d68a9
OTHER_ID=1111111111111111111111111111111111111111111111111111111111111111

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  REC=$(dev_state_new "$WS_ID" slabledger slabledger /home/tng/workspace/slabledger)
}

# mkevent <id> <ts> <event> <data_json> [workspace_id]
mkevent() {
  dev_event_build "$1" "$2" "$3" "${5:-$WS_ID}" \
    slabledger slabledger /home/tng/workspace/slabledger "$4"
}

@test "fold: workspace.opened sets the incarnation and clears fold_gap" {
  local rec ev out
  rec=$(jq -c '.fold_gap = true | .stopped_reason = "user" | .status = "stopped"' <<<"$REC")
  ev=$(mkevent aaaa000000000001 2026-08-03T13:58:02.001Z workspace.opened \
    '{"boot_id":"6f2a1c9e","config_digest":"sha256:9a3f","session_name_actual":"slabledger--wt"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .opened_at <<<"$out")" = 2026-08-03T13:58:02.001Z ]
  [ "$(jq -r .boot_id <<<"$out")" = 6f2a1c9e ]
  [ "$(jq -r .applied_digest <<<"$out")" = sha256:9a3f ]
  [ "$(jq -r .session_name <<<"$out")" = slabledger--wt ]
  [ "$(jq -r .stopped_reason <<<"$out")" = null ]
  [ "$(jq -r .fold_gap <<<"$out")" = false ]
  # config_digest is written by config.changed and by reconcile, never by opened.
  [ "$(jq -r .config_digest <<<"$out")" = null ]
}

@test "fold: workspace.stopped and workspace.vanished set status and reason only" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.status = "ready" | .container.id = "a710"' <<<"$REC")
  ev=$(mkevent aaaa000000000002 2026-08-03T14:00:00.000Z workspace.stopped '{"reason":"user"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -r .stopped_reason <<<"$out")" = user ]
  # No workspace.* event may touch the container axis.
  [ "$(jq -c .container <<<"$out")" = "$(jq -c .container <<<"$rec")" ]

  ev=$(mkevent aaaa000000000003 2026-08-03T14:00:01.000Z workspace.vanished \
    '{"discovered_at":"2026-08-03T14:00:01.000Z","reason":"host_restart","last_boot_id":"old"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -r .stopped_reason <<<"$out")" = host_restart ]
  [ "$(jq -c .container <<<"$out")" = "$(jq -c .container <<<"$rec")" ]
}

@test "fold: attached and detached set last_seen and nothing else" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000004 2026-08-03T14:02:11.412Z workspace.attached '{"client":"/dev/pts/3"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .last_seen <<<"$out")" = 2026-08-03T14:02:11.412Z ]
  [ "$(jq -S -c 'del(.last_seen)' <<<"$out")" = "$(jq -S -c 'del(.last_seen)' <<<"$rec")" ]

  ev=$(mkevent aaaa000000000005 2026-08-03T14:03:00.000Z workspace.detached '{"client":"/dev/pts/3"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .last_seen <<<"$out")" = 2026-08-03T14:03:00.000Z ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -S -c 'del(.last_seen)' <<<"$out")" = "$(jq -S -c 'del(.last_seen)' <<<"$rec")" ]
}

@test "fold: container.ready replaces the whole container object" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container = {
    status: "ready", kind: "single", id: "3f9c", user: "root", workdir: "/src",
    verified: true, up_exit_status: 0, up_result: {containerId: "3f9c"},
    observed_at: "2026-08-03T10:00:00.000Z"
  }' <<<"$REC")
  ev=$(mkevent aaaa000000000006 2026-08-03T14:02:11.412Z container.ready \
    '{"id":"a710","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710","remoteUser":"vscode","remoteWorkspaceFolder":"/workspace"}}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = ready ]
  [ "$(jq -r .container.kind <<<"$out")" = compose ]
  [ "$(jq -r .container.id <<<"$out")" = a710 ]
  [ "$(jq -r .container.user <<<"$out")" = vscode ]
  [ "$(jq -r .container.workdir <<<"$out")" = /workspace ]
  [ "$(jq -r .container.up_exit_status <<<"$out")" = 0 ]
  [ "$(jq -r .container.up_result.remoteUser <<<"$out")" = vscode ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:02:11.412Z ]
  # verified is reset, never inherited (§5.3).
  [ "$(jq -r .container.verified <<<"$out")" = false ]
  # No container.* event writes the workspace status.
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r '.container | keys_unsorted | length' <<<"$out")" = 9 ]
}

@test "fold: container.starting and container.failed leave status alone" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000007 2026-08-03T14:00:00.000Z container.starting '{"config_path":".devcontainer/devcontainer.json"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = starting ]
  [ "$(jq -r .container.verified <<<"$out")" = false ]
  [ "$(jq -r .status <<<"$out")" = running ]

  ev=$(mkevent aaaa000000000008 2026-08-03T14:00:30.000Z container.failed \
    '{"reason":"compose up failed","up_exit_status":1,"stderr_tail":"no such service"}')
  out=$(dev_fold_apply "$out" "$ev")
  [ "$(jq -r .container.status <<<"$out")" = failed ]
  [ "$(jq -r .container.up_exit_status <<<"$out")" = 1 ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:00:30.000Z ]
  # The one rule an earlier draft broke: container failure is not workspace death.
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .stopped_reason <<<"$out")" = null ]
}

@test "fold: container.lost nulls the id and leaves status alone" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.status = "ready" | .container.id = "a710" | .container.user = "vscode"' <<<"$REC")
  ev=$(mkevent aaaa000000000009 2026-08-03T14:05:00.000Z container.lost \
    '{"old_id":"a710","discovered_at":"2026-08-03T14:05:00.000Z"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .container.id <<<"$out")" = null ]
  [ "$(jq -r .container.status <<<"$out")" = lost ]
  [ "$(jq -r .container.observed_at <<<"$out")" = 2026-08-03T14:05:00.000Z ]
  [ "$(jq -r .container.user <<<"$out")" = vscode ]
  [ "$(jq -r .status <<<"$out")" = running ]
}

@test "fold: container.replaced and window.created fold to nothing" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .container.id = "a710"' <<<"$REC")
  ev=$(mkevent aaaa00000000000a 2026-08-03T14:06:00.000Z container.replaced \
    '{"old_id":"3f9c","new_id":"a710","reason":"rebuild"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]

  ev=$(mkevent aaaa00000000000b 2026-08-03T14:06:01.000Z window.created \
    '{"window":"scratch","location":"host","command":"zsh"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]
}

@test "fold: agent events upsert by window" {
  local rec out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa00000000000c 2026-08-03T14:07:00.000Z agent.started '{"window":"agent-1","command":"claude"}')")
  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000d 2026-08-03T14:07:01.000Z agent.started '{"window":"agent-2","command":"claude"}')")
  [ "$(jq -c .agents <<<"$out")" = '[{"window":"agent-1","command":"claude","state":"started"},{"window":"agent-2","command":"claude","state":"started"}]' ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000e 2026-08-03T14:08:00.000Z agent.exited '{"window":"agent-2","exit_status":0}')")
  [ "$(jq -r '.agents[] | select(.window == "agent-2") | .state' <<<"$out")" = exited ]
  [ "$(jq -r '.agents[] | select(.window == "agent-1") | .state' <<<"$out")" = started ]
  [ "$(jq -r '.agents[] | select(.window == "agent-2") | .command' <<<"$out")" = claude ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa00000000000f 2026-08-03T14:09:00.000Z agent.failed '{"window":"agent-1","reason":"crash","exit_status":137}')")
  [ "$(jq -r '.agents[] | select(.window == "agent-1") | .state' <<<"$out")" = failed ]
  [ "$(jq -c '.agents | length' <<<"$out")" = 2 ]
}

@test "fold: pane events change agent state only for windows carrying an agent" {
  local rec out
  rec=$(jq -c '.status = "running" | .agents = [{window: "agent-1", command: "claude", state: "started"}]' <<<"$REC")
  out=$(dev_fold_apply "$rec" "$(mkevent aaaa000000000010 2026-08-03T14:10:00.000Z pane.died '{"window":"agent-1","exit_status":1}')")
  [ "$(jq -r '.agents[0].state' <<<"$out")" = exited ]

  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000011 2026-08-03T14:11:00.000Z pane.respawned '{"window":"agent-1","container_id":"a710"}')")
  [ "$(jq -r '.agents[0].state' <<<"$out")" = started ]

  # scratch carries no agent: the pane event must not invent one.
  out=$(dev_fold_apply "$out" "$(mkevent aaaa000000000012 2026-08-03T14:12:00.000Z pane.died '{"window":"scratch","exit_status":0}')")
  [ "$(jq -c '.agents | length' <<<"$out")" = 1 ]
  [ "$(jq -r '.agents[0].window' <<<"$out")" = agent-1 ]
  [ "$(jq -r '.agents[0].state' <<<"$out")" = started ]
}

@test "fold: config.changed writes config_digest and never applied_digest" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .config_digest = "sha256:old" | .applied_digest = "sha256:old"' <<<"$REC")
  ev=$(mkevent aaaa000000000013 2026-08-03T14:13:00.000Z config.changed \
    '{"config_digest":"sha256:new","applied_digest":"sha256:old"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .config_digest <<<"$out")" = sha256:new ]
  [ "$(jq -r .applied_digest <<<"$out")" = sha256:old ]
  [ "$(jq -S -c 'del(.config_digest)' <<<"$out")" = "$(jq -S -c 'del(.config_digest)' <<<"$rec")" ]
}

@test "fold: an event older than opened_at is skipped" {
  local rec ev out
  rec=$(jq -c '.status = "running" | .opened_at = "2026-08-03T13:58:02.001Z"' <<<"$REC")
  ev=$(mkevent aaaa000000000014 2026-08-02T22:00:00.000Z workspace.stopped '{"reason":"user"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$rec")" ]

  # ...but workspace.opened itself moves the boundary.
  ev=$(mkevent aaaa000000000015 2026-08-03T09:00:00.000Z workspace.opened \
    '{"boot_id":"b0","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}')
  out=$(dev_fold_apply "$rec" "$ev")
  [ "$(jq -r .opened_at <<<"$out")" = 2026-08-03T09:00:00.000Z ]
}

@test "fold: an unknown event type advances the cursor and changes nothing else" {
  local ev out
  ev=$(mkevent aaaa000000000016 2026-08-03T14:14:00.000Z notification.sent '{"target":"slack"}')
  out=$(printf '%s\n' "$ev" | dev_fold_stream "$REC")
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa000000000016 ]
  [ "$(jq -r .scanned_through.ts <<<"$out")" = 2026-08-03T14:14:00.000Z ]
  [ "$(jq -S -c 'del(.scanned_through)' <<<"$out")" = "$(jq -S -c 'del(.scanned_through)' <<<"$REC")" ]
}

@test "fold: the cursor advances across another workspace's event" {
  local rec ev out
  rec=$(jq -c '.status = "running"' <<<"$REC")
  ev=$(mkevent aaaa000000000017 2026-08-03T14:15:00.000Z workspace.stopped '{"reason":"user"}' "$OTHER_ID")
  out=$(printf '%s\n' "$ev" | dev_fold_stream "$rec")
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa000000000017 ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -S -c 'del(.scanned_through)' <<<"$out")" = "$(jq -S -c 'del(.scanned_through)' <<<"$rec")" ]
}

@test "fold: the stream resumes after the cursor and stops at the tail" {
  local seg rec out
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa000000000018 2026-08-03T13:58:02.001Z workspace.opened \
      '{"boot_id":"b1","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}'
    mkevent aaaa000000000019 2026-08-03T13:59:00.000Z agent.started '{"window":"agent-1","command":"claude"}'
    mkevent aaaa00000000001a 2026-08-03T14:00:00.000Z workspace.stopped '{"reason":"user"}'
  } >"$seg"
  rec=$(jq -c '
    .status = "running"
    | .opened_at = "2026-08-03T13:58:02.001Z"
    | .scanned_through = {id: "aaaa000000000019", ts: "2026-08-03T13:59:00.000Z"}
  ' <<<"$REC")
  out=$(dev_fold_stream "$rec" <"$seg")
  # Only the event after the cursor was applied.
  [ "$(jq -r .status <<<"$out")" = stopped ]
  [ "$(jq -c '.agents | length' <<<"$out")" = 0 ]
  [ "$(jq -r .scanned_through.id <<<"$out")" = aaaa00000000001a ]
}

@test "fold: folding the same segment twice is byte-identical" {
  local seg once twice replay
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa00000000001b 2026-08-03T13:58:02.001Z workspace.opened \
      '{"boot_id":"b1","config_digest":"sha256:9a3f","session_name_actual":"slabledger"}'
    mkevent aaaa00000000001c 2026-08-03T13:58:03.000Z container.starting '{}'
    mkevent aaaa00000000001d 2026-08-03T13:58:04.000Z container.ready \
      '{"id":"a710","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710"}}'
    mkevent aaaa00000000001e 2026-08-03T13:58:05.000Z agent.started '{"window":"agent-1","command":"claude"}'
    mkevent aaaa00000000001f 2026-08-03T13:58:06.000Z pane.died '{"window":"agent-1","exit_status":1}'
    mkevent aaaa000000000020 2026-08-03T13:58:07.000Z workspace.attached '{"client":"/dev/pts/3"}'
  } >"$seg"
  once=$(dev_fold_stream "$REC" <"$seg" | jq -S -c .)
  twice=$(dev_fold_stream "$REC" <"$seg" | jq -S -c .)
  [ "$once" = "$twice" ]
  # Replaying the whole segment onto the already-folded record, cursor reset,
  # must reproduce it exactly — this is the idempotence ADR-1 relies on.
  replay=$(dev_fold_stream "$(jq -c '.scanned_through = null' <<<"$once")" <"$seg" | jq -S -c .)
  diff <(printf '%s\n' "$once") <(printf '%s\n' "$replay")
}

@test "fold: an unreachable cursor sets fold_gap and folds nothing" {
  local seg rec out
  seg="$TEST_ROOT/seg.jsonl"
  {
    mkevent aaaa000000000021 2026-08-03T14:20:00.000Z workspace.stopped '{"reason":"user"}'
    mkevent aaaa000000000022 2026-08-03T14:21:00.000Z container.lost '{"old_id":"a710"}'
  } >"$seg"
  rec=$(jq -c '
    .status = "running"
    | .opened_at = "2026-08-03T13:00:00.000Z"
    | .scanned_through = {id: "deadbeefdeadbeef", ts: "2026-08-02T00:00:00.000Z"}
  ' <<<"$REC")
  out=$(dev_fold_stream "$rec" <"$seg")
  [ "$(jq -r .fold_gap <<<"$out")" = true ]
  [ "$(jq -r .status <<<"$out")" = running ]
  [ "$(jq -r .container.status <<<"$out")" = none ]
  [ "$(jq -r .scanned_through.id <<<"$out")" = deadbeefdeadbeef ]
  [ "$(jq -S -c 'del(.fold_gap)' <<<"$out")" = "$(jq -S -c 'del(.fold_gap)' <<<"$rec")" ]
}

@test "fold: an empty stream leaves the record untouched" {
  local out
  out=$(dev_fold_stream "$REC" </dev/null)
  [ "$(jq -S -c . <<<"$out")" = "$(jq -S -c . <<<"$REC")" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_fold.bats`
Expected: FAIL — every test errors with
`tests/dev_fold.bats: line N: /home/tng/.dotfiles/tools/dev/lib/fold.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

Create `tools/dev/lib/fold.sh`:

```bash
#!/usr/bin/env bash
# The event fold: spec §4.4's transition table as a jq program.
#
# Invariants the table encodes, restated because they are easy to break:
#   * no container.* event writes .status; no workspace.* event writes .container.status
#   * container.ready replaces the entire container object, never patches it
#   * only workspace.attached/detached write .last_seen in the fold
#   * every transition is an absolute assignment, which is what makes replay idempotent
#   * unknown event types fall through unchanged — ignored, never rejected
#
# This file is sourced. It defines functions and does no work at source time.

# The shared jq source. Internal to this file; no other task calls it.
dev_fold_jq_program() {
  cat <<'JQ'
def agent_has($w): any(.agents[]; .window == $w);

def agent_upsert($w; $patch):
  if $w == null then .
  elif agent_has($w) then
    .agents = [.agents[] | if .window == $w then . + $patch else . end]
  else
    .agents = (.agents + [{window: $w, command: null, state: null} + $patch])
  end;

def fold_event($ev):
  . as $r
  | ($ev.data // {}) as $d
  | $ev.ts as $ts
  | if $ev.workspace_id != $r.workspace_id then .
    elif ($r.opened_at != null
          and $ts < $r.opened_at
          and $ev.event != "workspace.opened") then .
    elif $ev.event == "workspace.opened" then
      .status = "running"
      | .opened_at = $ts
      | .boot_id = $d.boot_id
      | .applied_digest = $d.config_digest
      | .session_name = ($d.session_name_actual // .session_name)
      | .stopped_reason = null
      | .fold_gap = false
    elif $ev.event == "workspace.attached" then .last_seen = $ts
    elif $ev.event == "workspace.detached" then .last_seen = $ts
    elif $ev.event == "workspace.stopped" then
      .status = "stopped" | .stopped_reason = $d.reason
    elif $ev.event == "workspace.vanished" then
      .status = "stopped" | .stopped_reason = $d.reason
    elif $ev.event == "window.created" then .
    elif $ev.event == "pane.died" then
      if agent_has($d.window) then agent_upsert($d.window; {state: "exited"}) else . end
    elif $ev.event == "pane.respawned" then
      if agent_has($d.window) then agent_upsert($d.window; {state: "started"}) else . end
    elif $ev.event == "container.starting" then
      .container.status = "starting" | .container.verified = false
    elif $ev.event == "container.ready" then
      .container = {
        status: "ready",
        kind: $d.kind,
        id: $d.id,
        user: $d.user,
        workdir: $d.workdir,
        verified: false,
        up_exit_status: $d.up_exit_status,
        up_result: $d.up_result,
        observed_at: $ts
      }
    elif $ev.event == "container.failed" then
      .container.status = "failed"
      | .container.observed_at = $ts
      | .container.up_exit_status = $d.up_exit_status
    elif $ev.event == "container.lost" then
      .container.id = null
      | .container.status = "lost"
      | .container.observed_at = $ts
    elif $ev.event == "container.replaced" then .
    elif $ev.event == "agent.started" then
      agent_upsert($d.window; {command: $d.command, state: "started"})
    elif $ev.event == "agent.exited" then
      agent_upsert($d.window; {state: "exited"})
    elif $ev.event == "agent.failed" then
      agent_upsert($d.window; {state: "failed"})
    elif $ev.event == "config.changed" then
      .config_digest = $d.config_digest
    else .
    end;

def fold_stream($events):
  . as $r
  | $r.scanned_through.id as $cursor
  | (if $cursor == null then -1
     else (first($events | to_entries[] | select(.value.id == $cursor) | .key) // -2)
     end) as $at
  | if $at == -2 then
      .fold_gap = true
    else
      $events[($at + 1):] as $pending
      | reduce $pending[] as $ev (.; fold_event($ev))
      | ($pending | last) as $tail
      | if $tail == null then .
        else .scanned_through = {id: $tail.id, ts: $tail.ts}
        end
    end;
JQ
}

dev_fold_apply() {
  local record=$1 event=$2
  local program
  program=$(dev_fold_jq_program)
  printf '%s' "$record" | jq -c --argjson ev "$event" "$program"' fold_event($ev)'
}

# Events arrive on stdin, one JSON object per line, oldest first. Slurped so the
# cursor can be located by index; the cursor is the last event *scanned*, whether
# or not it belonged to this workspace (ADR-1).
dev_fold_stream() {
  local record=$1
  local program
  program=$(dev_fold_jq_program)
  jq -s -c --argjson rec "$record" \
    "$program"' . as $events | $rec | fold_stream($events)'
}
```

Two jq details that are load-bearing rather than incidental. `first(...) // -2` distinguishes "not
found" from "found at index 0": jq treats `0` as truthy, so a cursor at the head of the array yields
`0`, while an empty result falls through to `-2` and trips `fold_gap`. And `agent_upsert` seeds a
missing entry with `{window, command: null, state: null}` before merging the patch, so
`agent.exited` arriving without a preceding `agent.started` — a log read from the middle — records
the state it knows and leaves `command` honestly unknown rather than dropping the event.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dev_fold.bats`
Expected: PASS (17 tests, 0 failures)

- [ ] **Step 5: Run the full suite for the three libraries**

Run: `bats tests/dev_state_events.bats tests/dev_fold.bats`
Expected: PASS (43 tests, 0 failures)

- [ ] **Step 6: Commit**

```bash
git add tools/dev/lib/fold.sh tests/dev_fold.bats
git commit -m "feat(dev): fold the event stream onto workspace records with a global scan cursor"
```
### Task 8: Reconcile (`tools/dev/lib/reconcile.sh`)

**Files:**
- Create: `tools/dev/lib/reconcile.sh`
- Test: `tests/dev_reconcile.bats`

**Interfaces:**
- Consumes: `dev_now`, `dev_event_id_deterministic <workspace_id> <event_type> <discriminator>`,
  `dev_event_build <id> <ts> <event> <workspace_id> <slug> <session_name> <worktree> <data_json>`,
  `dev_event_append <line>`, `dev_events_read_all`, `dev_events_has_id <id>`,
  `dev_events_rotate_if_needed` (Task 5); `dev_state_read <workspace_id>`,
  `dev_state_new <workspace_id> <slug> <session_name> <worktree>`,
  `dev_state_commit <workspace_id> <expected_json> <new_json>` (Task 6);
  `dev_fold_apply <record_json> <event_json>`, `dev_fold_stream <record_json>` (Task 7);
  `dev_backend_query <session_name>` (Task 11); `dev_container_alive <container_id>` (Task 10).
- Produces: `dev_reconcile <resolved_json> <config_digest>` → the committed record JSON on stdout;
  exit 8 after 3 failed CAS attempts.

**What reconcile is, stated so a reviewer can check the code against it.** Reconcile is read-only
with respect to the workspace (ADR-1). It never starts a container, never respawns a pane, never
creates a window. It mutates *state* — the record and the event log — and never the workspace. That
is exactly why `dev list` and `dev status` may run it while holding no operation lock: the one
command a user reaches for when they suspect something is wrong is the one command that cannot make
it worse. Repair lives in `open`'s ensure phase alone (Task 14).

The pass is **observe → compute → commit**. Observation and folding hold no state lock; the state
lock is taken only by `dev_state_commit`, for one read-modify-write. Discovery events are appended
**before** the commit, guarded by their deterministic ids, so a CAS retry appends nothing and a crash
in the gap leaves an event that the next pass folds — the safe direction.

**Two conventions this task depends on, recorded because they are cross-task contracts.**

1. `dev_state_commit` is called with `expected_json` set to the **empty string** when the record was
   absent at observe time. Empty means "expect no record on disk"; a record that appeared in the
   meantime is a CAS mismatch and exits 9, like any other.
2. Libraries define functions only, and `bin/dev` sources all of them (Task 12). Reconcile therefore
   calls `dev_backend_query` and `dev_container_alive` as already-sourced functions and does **not**
   source `backend-tmux.sh` or `container.sh` itself. That is what lets the tests below substitute a
   fake backend by redefining two shell functions, with no tmux server and no Docker daemon.

**Discovery-event timestamps.** ADR-1 opens by rejecting a model that "discovers a death hours later
and records it as having happened at discovery time." So a discovery event's `ts` is the best
available estimate of *when the thing happened* and `data.discovered_at` is *when it was noticed*:
`workspace.vanished` takes `ts` from the record's `last_seen`, `container.lost` from
`container.observed_at` (falling back to `last_seen`), and both carry `discovered_at` = now.
`config.changed` carries no `discovered_at` in the §4.4 table — a digest change is noticed, not
timed — so its `ts` is now.

**Discovery-event discriminators.** The deterministic id exists so a CAS retry re-appends nothing
(ADR-1), and its whole risk is on the other side: an id that repeats across two *different*
occasions suppresses the second one, permanently and silently. So each discriminator pairs the
subject with the occasion it belongs to:

- `workspace.vanished` — recorded `boot_id` **and** `opened_at`. The boot id is constant until the
  host reboots, so on its own it makes every loss after the first invisible to the event stream.
  `opened_at` changes on every `workspace.opened`, which is exactly the boundary between one
  vanishing and the next.
- `container.lost` — the lost container id **and** `container.observed_at`, which the fold writes
  from the `container.ready` that bound that id. `docker start` preserves the id across a stop, so
  the id alone names a container, not a binding.
- `config.changed` — the new `config_digest` **and** the current `applied_digest`. Editing a config
  A → B → A produces two genuinely different facts about the (wanted, applied) pair; keyed on the
  wanted digest alone the return to A collides with the state before B and is dropped, leaving
  `dev status` reporting drift that no event explains.

- [ ] **Step 1: Write the failing drift-case tests**

```bash
cat >tests/dev_reconcile.bats <<'BATS'
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  source "$REPO_ROOT/tools/dev/lib/reconcile.sh"

  # Deterministic clock: two runs of the same pass must be byte-comparable.
  FAKE_NOW="2026-08-03T15:00:00.000Z"
  dev_now() { printf '%s\n' "$FAKE_NOW"; }

  BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
  WT="$DEV_REPO_ROOT/demo"
  mkdir -p "$WT"
  WS_ID=$(printf '%s' "$WT" | sha256sum | cut -d' ' -f1)
  RESOLVED=$(jq -nc --arg s demo --arg w "$WT" --arg i "$WS_ID" --arg n demo \
    '{slug: $s, worktree: $w, workspace_id: $i, session_name: $n, is_primary: true}')

  # Fake backend. Both knobs are plain globals the test body flips.
  BACKEND_EXISTS=false
  CONTAINER_ALIVE=false
  dev_backend_query() {
    jq -nc --arg e "$BACKEND_EXISTS" --arg w "$WT" \
      '{exists: ($e == "true"), worktree: $w, clients: 0, windows: []}'
  }
  dev_container_alive() { [[ "$CONTAINER_ALIVE" == "true" ]]; }
}

# A running record, opened long ago, last seen at a time distinct from FAKE_NOW.
mk_record() {
  dev_state_new "$WS_ID" demo demo "$WT" | jq -c \
    --arg b "$BOOT_ID" \
    '.status = "running"
     | .opened_at = "2026-08-03T09:00:00.000Z"
     | .last_seen = "2026-08-03T12:30:00.000Z"
     | .boot_id = $b
     | .config_digest = "sha256:aaa"
     | .applied_digest = "sha256:aaa"
     | .scanned_through = {id: null, ts: null}'
}

seed_record() { printf '%s\n' "$1" >"$(dev_state_path "$WS_ID")"; }

# Appends one event with a random id and the shared envelope.
emit() {
  local event="$1" ts="$2" data="$3" id
  id=$(dev_event_id_random)
  dev_event_append \
    "$(dev_event_build "$id" "$ts" "$event" "$WS_ID" demo demo "$WT" "$data")"
}

all_events() { cat "$DEV_STATE_ROOT"/events/*.jsonl 2>/dev/null; }

@test "case A: a workspace.stopped event with the backend absent folds to stopped/user" {
  seed_record "$(mk_record)"
  emit workspace.stopped "2026-08-03T12:45:00.000Z" '{"reason":"user"}'
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = user ]
  # The hook already explained it; reconcile must not also claim a discovery.
  [ -z "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id')" ]
}

@test "case A: a missed hook produces workspace.vanished with discovered_at distinct from ts" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = vanished ]

  ev=$(all_events | jq -c 'select(.event == "workspace.vanished")')
  [ "$(jq -r '.ts' <<<"$ev")" = "2026-08-03T12:30:00.000Z" ]
  [ "$(jq -r '.data.discovered_at' <<<"$ev")" = "$FAKE_NOW" ]
  [ "$(jq -r '.ts' <<<"$ev")" != "$(jq -r '.data.discovered_at' <<<"$ev")" ]
  [ "$(jq -r '.data.reason' <<<"$ev")" = vanished ]
  [ "$(jq -r '.data.last_boot_id' <<<"$ev")" = "$BOOT_ID" ]
}

@test "case B: a differing boot id yields host_restart rather than vanished" {
  seed_record "$(mk_record | jq -c '.boot_id = "11111111-2222-3333-4444-555555555555"')"
  BACKEND_EXISTS=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = host_restart ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .data.reason')" = host_restart ]
}

@test "case C: a dead container emits container.lost and leaves workspace status alone" {
  seed_record "$(mk_record | jq -c '
    .container = {status: "ready", kind: "compose", id: "a710dead", user: "vscode",
                  workdir: "/workspace", verified: false, up_exit_status: 0,
                  up_result: {containerId: "a710dead"},
                  observed_at: "2026-08-03T11:00:00.000Z"}')"
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = lost ]
  [ "$(jq -r '.container.id' <<<"$output")" = null ]
  # ADR-2's axis separation: a lost container does not stop the workspace.
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(jq -r '.stopped_reason' <<<"$output")" = null ]

  ev=$(all_events | jq -c 'select(.event == "container.lost")')
  [ "$(jq -r '.data.old_id' <<<"$ev")" = a710dead ]
  [ "$(jq -r '.data.discovered_at' <<<"$ev")" = "$FAKE_NOW" ]
  [ "$(jq -r '.ts' <<<"$ev")" = "2026-08-03T11:00:00.000Z" ]
}

@test "case D: a changed config digest emits config.changed and touches no tmux" {
  stub_command tmux 'echo tmux >"$TEST_ROOT/tmux-was-called"; exit 1'
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:bbb"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.config_digest' <<<"$output")" = "sha256:bbb" ]
  [ "$(jq -r '.applied_digest' <<<"$output")" = "sha256:aaa" ]
  assert_file_absent "$TEST_ROOT/tmux-was-called"

  ev=$(all_events | jq -c 'select(.event == "config.changed")')
  [ "$(jq -r '.data.config_digest' <<<"$ev")" = "sha256:bbb" ]
  [ "$(jq -r '.data.applied_digest' <<<"$ev")" = "sha256:aaa" ]
}

@test "case E: VS Code stopping the compose stack is handled identically to case C" {
  # Different setup from case C: the binding arrives by folding the container.ready
  # event that open wrote, rather than being present in the seeded record.
  seed_record "$(mk_record)"
  emit container.ready "2026-08-03T11:00:00.000Z" \
    '{"id":"a710dead","kind":"compose","user":"vscode","workdir":"/workspace","up_exit_status":0,"up_result":{"containerId":"a710dead"}}'
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = lost ]
  [ "$(jq -r '.container.id' <<<"$output")" = null ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .data.old_id')" = a710dead ]
}

@test "no drift means no discovery events and a record that only advances last_seen" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ "$(jq -r '.last_seen' <<<"$output")" = "$FAKE_NOW" ]
  [ -z "$(all_events)" ]
}

@test "an absent record is created from the resolved identity" {
  BACKEND_EXISTS=true

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspace_id' <<<"$output")" = "$WS_ID" ]
  [ "$(jq -r '.slug' <<<"$output")" = demo ]
  [ "$(jq -r '.status' <<<"$output")" = running ]
  [ -f "$(dev_state_path "$WS_ID")" ]
}
BATS
```

- [ ] **Step 2: Run the drift tests to verify they fail**

Run: `bats tests/dev_reconcile.bats`
Expected: FAIL — every test errors with
`source: tools/dev/lib/reconcile.sh: No such file or directory`.

- [ ] **Step 3: Append the two CAS tests §4.4 mandates**

```bash
cat >>tests/dev_reconcile.bats <<'BATS'

# Copies a function definition under a second name, so a test can wrap it.
copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }

@test "CAS: a discovery event is appended exactly once across a forced retry" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  copy_fn dev_state_commit dev_state_commit_orig
  CAS_TRIPPED=0
  # Mutate the on-disk record on the first commit attempt only, so attempt 1
  # exits 9 and attempt 2 re-observes and succeeds.
  dev_state_commit() {
    if [[ "$CAS_TRIPPED" == 0 ]]; then
      CAS_TRIPPED=1
      local p; p="$(dev_state_path "$WS_ID")"
      jq -c '.last_seen = "2026-08-03T12:31:00.000Z"' "$p" >"$p.mut"
      mv "$p.mut" "$p"
    fi
    dev_state_commit_orig "$@"
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = stopped ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "CAS: three consecutive CAS failures exit 8 without overwriting the record" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false

  copy_fn dev_state_commit dev_state_commit_orig
  # Mutate the record before every commit attempt, so all three exit 9.
  dev_state_commit() {
    local p; p="$(dev_state_path "$WS_ID")"
    jq -c --arg n "$RANDOM" '.last_seen = ("2026-08-03T12:31:00." + $n + "Z")' "$p" >"$p.mut"
    mv "$p.mut" "$p"
    dev_state_commit_orig "$@"
  }

  run dev_reconcile "$RESOLVED" "sha256:aaa"
  [ "$status" -eq 8 ]
  [[ "$output" == *"changing underneath"* ]]
  [ "$(jq -r '.status' "$(dev_state_path "$WS_ID")")" = running ]
  # Idempotent id: three attempts, still one event.
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "CAS: a crash between emit and commit converges to the uninterrupted record" {
  # Branch A — an uninterrupted pass, reconciled twice so its fold cursor has
  # advanced across the event it appended.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  uninterrupted=$(jq -S -c . "$(dev_state_path "$WS_ID")")

  # Branch B — the crash: the discovery event reached the log, the record never
  # changed. Rebuild the state root from scratch and replay that situation.
  rm -rf "$DEV_STATE_ROOT"
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks"
  seed_record "$(mk_record)"
  # The discriminator is boot_id + the record's opened_at (mk_record's value),
  # so this reproduces exactly the id reconcile will recompute on the next pass.
  crash_id=$(dev_event_id_deterministic "$WS_ID" workspace.vanished \
    "$BOOT_ID:2026-08-03T09:00:00.000Z")
  dev_event_append "$(dev_event_build "$crash_id" "2026-08-03T12:30:00.000Z" \
    workspace.vanished "$WS_ID" demo demo "$WT" \
    "$(jq -nc --arg d "$FAKE_NOW" --arg b "$BOOT_ID" \
      '{discovered_at: $d, reason: "vanished", last_boot_id: $b}')")"

  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  converged=$(jq -S -c . "$(dev_state_path "$WS_ID")")

  [ "$converged" = "$uninterrupted" ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]
}

@test "a second vanish in a new incarnation is a second event, not a dropped duplicate" {
  # Deduplication by deterministic id must suppress only re-derivations of the
  # SAME occasion. Keyed on boot_id alone, the boot id is identical until the
  # host reboots, so every later loss of the same workspace collapsed into the
  # first one's id and was silently discarded by the has-id check.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 1 ]

  # Reopened: a new incarnation, same boot id.
  emit workspace.opened "2026-08-03T13:00:00.000Z" \
    "$(jq -nc --arg b "$BOOT_ID" \
      '{session_name_actual: "demo", boot_id: $b, config_digest: "sha256:aaa"}')"
  BACKEND_EXISTS=true
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(jq -r '.status' "$(dev_state_path "$WS_ID")")" = running ]

  # And killed again.
  BACKEND_EXISTS=false
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | wc -l)" -eq 2 ]
  [ "$(all_events | jq -r 'select(.event == "workspace.vanished") | .id' | sort -u | wc -l)" -eq 2 ]
}

@test "losing the same container id twice across two bindings emits two events" {
  # `docker start` preserves the id, so the id alone does not identify the
  # binding; the container.ready that bound it does.
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true
  CONTAINER_ALIVE=false
  emit container.ready "2026-08-03T12:00:00.000Z" \
    '{"kind":"devcontainer","id":"cid1","user":"vscode","workdir":"/w","up_exit_status":0,"up_result":"success"}'
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .id' | wc -l)" -eq 1 ]

  # The same container comes back, then goes away again.
  emit container.ready "2026-08-03T12:40:00.000Z" \
    '{"kind":"devcontainer","id":"cid1","user":"vscode","workdir":"/w","up_exit_status":0,"up_result":"success"}'
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "container.lost") | .id' | sort -u | wc -l)" -eq 2 ]
}

@test "a config edited A to B and back to A emits an event each way" {
  seed_record "$(mk_record)"
  BACKEND_EXISTS=true
  dev_reconcile "$RESOLVED" "sha256:bbb" >/dev/null
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  [ "$(all_events | jq -r 'select(.event == "config.changed") | .id' | sort -u | wc -l)" -eq 2 ]
  [ "$(all_events | jq -r 'select(.event == "config.changed") | .data.config_digest' |
    tr '\n' ' ')" = "sha256:bbb sha256:aaa " ]
}

@test "a rotated-away cursor re-anchors: fold_gap stays set but the rescan stops" {
  seed_record "$(jq -c '.scanned_through = {id: "deadbeefdeadbeef", ts: "2026-08-03T10:00:00.000Z"}' <<<"$(mk_record)")"
  BACKEND_EXISTS=true

  # An event the cursor can anchor to, none of which is the missing cursor.
  dev_event_append "$(dev_event_build "$(dev_event_id_random)" "2026-08-03T12:00:00.000Z" \
    workspace.attached "$WS_ID" demo demo "$WT" '{"client":"/dev/pts/1"}')"

  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  after=$(jq -c . "$(dev_state_path "$WS_ID")")

  # The gap is still reported — only workspace.opened clears it.
  [ "$(jq -r '.fold_gap' <<<"$after")" = true ]
  # But the cursor has moved off the unreachable id to the newest scanned event,
  # so the next pass folds forward instead of re-deriving the same gap.
  [ "$(jq -r '.scanned_through.id' <<<"$after")" != "deadbeefdeadbeef" ]
  [ "$(jq -r '.scanned_through.ts' <<<"$after")" = "2026-08-03T12:00:00.000Z" ]

  # A second pass changes nothing but last_seen: the rescan really did stop.
  dev_reconcile "$RESOLVED" "sha256:aaa" >/dev/null
  second=$(jq -c . "$(dev_state_path "$WS_ID")")
  [ "$(jq -S -c 'del(.last_seen)' <<<"$second")" = "$(jq -S -c 'del(.last_seen)' <<<"$after")" ]
}
BATS
```

- [ ] **Step 4: Run the full file to verify all eleven tests fail**

Run: `bats tests/dev_reconcile.bats`
Expected: FAIL (10 tests, 10 failures) — still
`source: tools/dev/lib/reconcile.sh: No such file or directory`.

- [ ] **Step 5: Write the implementation**

```bash
cat >tools/dev/lib/reconcile.sh <<'SH'
# reconcile.sh — observe the backend, fold the event log, commit a record.
#
# Read-only with respect to the workspace (ADR-1): this file never starts a
# container, respawns a pane, or creates a window. Repair is `open`'s ensure
# phase alone, which is why `dev list` and `dev status` may run reconcile while
# holding no operation lock.
#
# The pass is observe -> compute -> commit. No state lock is held while
# observing or folding; `dev_state_commit` takes it for one read-modify-write.
# Discovery events are emitted BEFORE the commit and carry deterministic ids,
# so a CAS retry appends nothing and a crash in the gap leaves an event the
# next pass folds.

DEV_RECONCILE_MAX_ATTEMPTS="${DEV_RECONCILE_MAX_ATTEMPTS:-3}"

dev_reconcile_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf '\n'
}

dev_reconcile() {
  local resolved_json="$1" config_digest="$2"
  local workspace_id slug worktree proposed_name session_name
  workspace_id=$(jq -r '.workspace_id' <<<"$resolved_json")
  slug=$(jq -r '.slug' <<<"$resolved_json")
  worktree=$(jq -r '.worktree' <<<"$resolved_json")
  proposed_name=$(jq -r '.session_name' <<<"$resolved_json")

  local attempt=1
  while ((attempt <= DEV_RECONCILE_MAX_ATTEMPTS)); do
    # --- observe (no state lock held) ---------------------------------------
    local base expected
    if base=$(dev_state_read "$workspace_id"); then
      expected="$base"
      # The record's own name, never the resolver's proposal. On a workspace the
      # ADR-7 collision guard renamed, the proposal names a DIFFERENT working
      # tree's session (or nothing at all), so querying it would report this
      # workspace as vanished while it is running, and emit a false
      # workspace.vanished on every pass. Re-read inside the retry loop so a
      # concurrent open's rename is picked up on the second attempt.
      session_name=$(jq -r '.session_name // ""' <<<"$base")
      [[ -n "$session_name" && "$session_name" != null ]] || session_name="$proposed_name"
    else
      session_name="$proposed_name"
      base=$(dev_state_new "$workspace_id" "$slug" "$session_name" "$worktree")
      expected=""
    fi

    local backend_json exists
    backend_json=$(dev_backend_query "$session_name")
    exists=$(jq -r '.exists' <<<"$backend_json")

    # Capture the stream once. The tail is needed twice — by the fold, and (on a
    # gap) by the re-anchor below — and reading twice would race a rotation
    # between the two reads and produce inconsistent cursors.
    local all_events folded
    all_events=$(dev_events_read_all)
    folded=$(printf '%s\n' "$all_events" | dev_fold_stream "$base")

    local container_id container_alive=unknown
    container_id=$(jq -r '.container.id // empty' <<<"$folded")
    if [[ -n "$container_id" && "$container_id" != null ]]; then
      if dev_container_alive "$container_id"; then
        container_alive=yes
      else
        container_alive=no
      fi
    fi

    # --- compute the discovery events ---------------------------------------
    local now; now=$(dev_now)
    local -a discoveries=()
    local folded_status rec_boot_id cur_boot_id data id ts
    local rec_opened_at bound_at
    folded_status=$(jq -r '.status' <<<"$folded")
    rec_boot_id=$(jq -r '.boot_id // empty' <<<"$folded")
    cur_boot_id=$(dev_reconcile_boot_id)
    # The incarnation this record is in. `workspace.opened` sets it on every open,
    # so it is what distinguishes "this workspace vanished" from "this workspace
    # vanished, was reopened, and vanished again" -- two real events that a
    # discriminator of boot_id alone collapses into one, because the boot id is
    # identical until the host reboots. The second loss would then be silently
    # dropped by the has-id check and no consumer would ever hear about it.
    rec_opened_at=$(jq -r '.opened_at // empty' <<<"$folded")

    if [[ "$folded_status" == running && "$exists" != true ]]; then
      local reason=vanished
      if [[ -n "$rec_boot_id" && "$rec_boot_id" != "$cur_boot_id" ]]; then
        reason=host_restart
      fi
      # ts estimates when it happened; discovered_at records when we noticed.
      ts=$(jq -r '.last_seen // empty' <<<"$folded")
      [[ -n "$ts" ]] || ts="$now"
      data=$(jq -nc --arg d "$now" --arg r "$reason" --arg b "$rec_boot_id" \
        '{discovered_at: $d, reason: $r}
         + (if $b == "" then {} else {last_boot_id: $b} end)')
      id=$(dev_event_id_deterministic "$workspace_id" workspace.vanished \
        "${rec_boot_id}:${rec_opened_at}")
      discoveries+=("$(dev_event_build "$id" "$ts" workspace.vanished \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    if [[ "$container_alive" == no ]]; then
      ts=$(jq -r '.container.observed_at // .last_seen // empty' <<<"$folded")
      [[ -n "$ts" ]] || ts="$now"
      data=$(jq -nc --arg o "$container_id" --arg d "$now" \
        '{old_id: $o, discovered_at: $d}')
      # `container.observed_at` is written by the fold from the `container.ready`
      # that bound this id, so it names the binding rather than the moment of
      # this observation. Without it, a container stopped, started again under
      # the same id (which `docker start` preserves), and lost a second time
      # would produce a duplicate id and the second loss would never be emitted.
      bound_at=$(jq -r '.container.observed_at // empty' <<<"$folded")
      id=$(dev_event_id_deterministic "$workspace_id" container.lost \
        "${container_id}:${bound_at}")
      discoveries+=("$(dev_event_build "$id" "$ts" container.lost \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    local folded_digest folded_applied
    folded_digest=$(jq -r '.config_digest // empty' <<<"$folded")
    folded_applied=$(jq -r '.applied_digest // empty' <<<"$folded")
    if [[ -n "$config_digest" && "$config_digest" != "$folded_digest" ]]; then
      data=$(jq -nc --arg c "$config_digest" --arg a "$folded_applied" \
        '{config_digest: $c}
         + (if $a == "" then {} else {applied_digest: $a} end)')
      # Both digests, because the event is a statement about the pair. Editing a
      # config from A to B and back to A used to produce one event and then
      # silence: the return to A carried the same discriminator as the state
      # before B, so it was dropped, and `dev status` reported drift no event
      # explained. With the applied digest folded in, each distinct (wanted,
      # applied) pair is its own event. One case survives by design: A -> B -> A
      # -> B with no intervening `dev open` re-emits the first B event's id, and
      # the repeat is dropped -- correctly, since nothing was applied in between
      # and the second B is the same undelivered fact as the first.
      id=$(dev_event_id_deterministic "$workspace_id" config.changed \
        "${config_digest}:${folded_applied}")
      discoveries+=("$(dev_event_build "$id" "$now" config.changed \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")")
    fi

    # --- emit, then commit (ADR-1) ------------------------------------------
    local computed="$folded" ev
    if ((${#discoveries[@]} > 0)); then
      for ev in "${discoveries[@]}"; do
        id=$(jq -r '.id' <<<"$ev")
        if ! dev_events_has_id "$id"; then
          dev_event_append "$ev"
        fi
        computed=$(dev_fold_apply "$computed" "$ev")
      done
    fi

    # Overlay what observation alone establishes. When the fold cursor rotated
    # away (fold_gap) the backend is the only honest source of status.
    #
    # Re-anchor the cursor when the fold reported a gap. lib/fold.sh deliberately
    # leaves `scanned_through` untouched on an unreachable cursor — a fold that
    # silently advanced past a gap would be papering over the exact thing it was
    # asked to report. But leaving it unmoved makes the gap sticky: every later
    # reconcile re-derives it and re-flags forever. Reconcile, which is the layer
    # that has already reported the gap, anchors the cursor to the newest event it
    # scanned so folding resumes from the tail. `fold_gap` STAYS true — only
    # `workspace.opened` clears it — so the honest signal survives; what stops is
    # the pointless rescan.
    local newest
    newest=$(printf '%s\n' "$all_events" | jq -s -c 'if length == 0 then null else (.[-1] | {id, ts}) end')
    if [[ "$(jq -r '.fold_gap' <<<"$computed")" == "true" && "$newest" != "null" ]]; then
      computed=$(jq -c --argjson st "$newest" '.scanned_through = $st' <<<"$computed")
    fi

    local final
    final=$(jq -c --arg now "$now" --arg dg "$config_digest" --arg ex "$exists" '
      .last_seen = $now
      | .config_digest = (if $dg == "" then .config_digest else $dg end)
      | .status = (if $ex == "true" then "running"
                   elif (.fold_gap == true) then "stopped"
                   else .status end)
      | .stopped_reason = (if .status == "running" then null else .stopped_reason end)
    ' <<<"$computed")

    if dev_state_commit "$workspace_id" "$expected" "$final"; then
      # Rotation is checked outside the fold's shared lock, never inside it.
      dev_events_rotate_if_needed
      printf '%s\n' "$final"
      return 0
    fi

    attempt=$((attempt + 1))
  done

  printf 'dev: workspace %s is changing underneath this command; giving up after %s attempts\n' \
    "$slug" "$DEV_RECONCILE_MAX_ATTEMPTS" >&2
  return 8
}
SH
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/dev_reconcile.bats`
Expected: PASS (15 tests, 0 failures)

- [ ] **Step 7: Commit**

```bash
git add tools/dev/lib/reconcile.sh tests/dev_reconcile.bats
git commit -m "feat(dev): reconcile pass with observe/compute/commit and CAS-safe discovery"
```

---

### Task 9: Runtime detection (`tools/dev/lib/runtime.sh`) + pinning the devcontainer CLI

**Files:**
- Create: `tools/dev/lib/runtime.sh`
- Modify: `config/mise/config.toml`
- Test: `tests/dev_runtime_container.bats` (created here; Task 10 appends to it)

**Interfaces:**
- Consumes: nothing from earlier tasks. Reads `$DEV_DOTFILES_ROOT/config/mise/config.toml` and
  writes `$DEV_STATE_ROOT/runtime.json`.
- Produces: `dev_runtime_docker_ok`, `dev_runtime_devcontainer_cli`, `dev_runtime_detect`,
  `dev_runtime_kind <worktree>`, plus the two helpers `dev_runtime_mise_bin` and
  `dev_runtime_cli_spec` that Task 10 does not use but `dev doctor` will.

**Deviation from the spec, in one line.** ADR-5 pins the CLI in `tools/dev/versions.toml`; this repo
already pins mise tools in `config/mise/config.toml` and `bin/versions list_mise` reads that file
generically, so the pin goes there and `tools/dev/versions.toml` is not created. `bin/versions`
needs no change.

**The §0 evidence, in one line.** `command -v devcontainer` exits 0 for
`~/.local/share/mise/shims/devcontainer`, which then fails every call with
`mise ERROR No version is set for shim: devcontainer`, because the CLI was installed under
`node@25.9.0` while the active global is `node@26.5.0` — presence detection is worthless here, so
detection executes `devcontainer --version` and requires exit 0 *and* a parseable version.

- [ ] **Step 1: Pin the CLI in `config/mise/config.toml`**

Add to the `[tools]` table, immediately after the `npm:tree-sitter-cli` entry:

```toml
# The CLI is invoked only as `mise exec npm:@devcontainers/cli@<ver> -- devcontainer`.
# Its shim resolves against whichever node is global: it was installed under
# node@25.9.0 and the global is node@26.5.0, so the shim is executable and fails
# on every call. Pinning here makes `bin/versions list_mise` report it for free.
"npm:@devcontainers/cli" = "0.86.1"
```

- [ ] **Step 2: Write the failing runtime tests**

```bash
cat >tests/dev_runtime_container.bats <<'BATS'
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/runtime.sh"
  WT="$DEV_REPO_ROOT/demo"
  mkdir -p "$WT"
}

# The mise search order is $HOME/.local/bin/mise first, so a stub there wins
# over any real /usr/local/bin/mise on the developer's machine.
stub_mise() {
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/mise" <<EOF
#!/usr/bin/env bash
$*
EOF
  chmod +x "$HOME/.local/bin/mise"
}

@test "a resolvable but failing devcontainer shim is reported absent" {
  # Presence succeeds ...
  stub_command devcontainer 'echo "mise ERROR No version is set for shim" >&2; exit 1'
  run command -v devcontainer
  [ "$status" -eq 0 ]

  # ... execution does not.
  stub_mise 'echo "mise ERROR No version is set for shim: devcontainer" >&2; exit 1'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 6 ]
  [[ "$output" == *"unrunnable"* ]]
}

@test "a working mise exec path returns the full invocation prefix" {
  stub_mise '[[ "$1" == exec && "$3" == -- && "$4" == devcontainer && "$5" == --version ]] || exit 1
echo 0.86.1'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.local/bin/mise exec npm:@devcontainers/cli@0.86.1 -- devcontainer" ]
}

@test "a version probe that prints garbage is treated as absent" {
  stub_mise 'echo "devcontainer: command not found"'
  run dev_runtime_devcontainer_cli
  [ "$status" -eq 6 ]
  [[ "$output" == *"parseable version"* ]]
}

@test "docker_ok follows the daemon probe" {
  stub_command docker 'exit 0'
  run dev_runtime_docker_ok
  [ "$status" -eq 0 ]
  stub_command docker 'echo "Cannot connect to the Docker daemon" >&2; exit 1'
  run dev_runtime_docker_ok
  [ "$status" -ne 0 ]
}

@test "runtime kind is compose when dockerComposeFile is present" {
  mkdir -p "$WT/.devcontainer"
  cat >"$WT/.devcontainer/devcontainer.json" <<'JSON'
{
  "name": "demo",
  "dockerComposeFile": "docker-compose.yml",
  "service": "app"
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = compose ]
}

@test "runtime kind tolerates JSONC comments and a trailing comma" {
  mkdir -p "$WT/.devcontainer"
  cat >"$WT/.devcontainer/devcontainer.json" <<'JSON'
{
  // See https://containers.dev — this URL must not be mistaken for a comment.
  "name": "demo",
  "image": "mcr.microsoft.com/devcontainers/base:bookworm", // trailing comment
  "remoteUser": "vscode",
}
JSON
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = single ]
}

@test "runtime kind is none without a devcontainer" {
  run dev_runtime_kind "$WT"
  [ "$status" -eq 0 ]
  [ "$output" = none ]
}

@test "runtime detection is cached and reused" {
  stub_command docker 'exit 0'
  stub_mise 'echo 0.86.1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = true ]
  [ "$(jq -r '.cli_spec' <<<"$output")" = "npm:@devcontainers/cli@0.86.1" ]
  [ -f "$DEV_STATE_ROOT/runtime.json" ]

  # Break both probes; a fresh cache must still be served from disk.
  stub_command docker 'exit 1'
  stub_mise 'exit 1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = true ]
}

@test "an expired runtime cache is re-probed" {
  stub_command docker 'exit 0'
  stub_mise 'echo 0.86.1'
  dev_runtime_detect >/dev/null
  touch -d '2 days ago' "$DEV_STATE_ROOT/runtime.json"

  stub_command docker 'exit 1'
  run dev_runtime_detect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.docker' <<<"$output")" = false ]
}
BATS
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/dev_runtime_container.bats`
Expected: FAIL (9 tests, 9 failures) —
`source: tools/dev/lib/runtime.sh: No such file or directory`.

- [ ] **Step 4: Write the implementation**

```bash
cat >tools/dev/lib/runtime.sh <<'SH'
# runtime.sh — detection, never hardcoding. Docker reachability, devcontainer
# kind, and the devcontainer CLI resolved to an *invocation* rather than a path.
#
# The CLI is never detected with `command -v`: on this machine the mise shim
# resolves, is executable, and fails on every call because the package lives
# under a node version that is no longer global (spec §0). Detection therefore
# executes `devcontainer --version` and requires exit 0 AND a parseable version.

DEV_RUNTIME_CACHE_TTL="${DEV_RUNTIME_CACHE_TTL:-86400}"

dev_runtime_mise_bin() {
  local candidate
  for candidate in "$HOME/.local/bin/mise" /usr/local/bin/mise; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate=$(command -v mise 2>/dev/null) || return 1
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

dev_runtime_cli_spec() {
  local toml="$DEV_DOTFILES_ROOT/config/mise/config.toml" version
  [[ -f "$toml" ]] || return 1
  version=$(sed -n \
    's/^"npm:@devcontainers\/cli"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$toml" | head -n 1)
  [[ -n "$version" ]] || return 1
  printf 'npm:@devcontainers/cli@%s\n' "$version"
}

dev_runtime_devcontainer_cli() {
  local mise_bin spec out
  mise_bin=$(dev_runtime_mise_bin) || {
    echo "dev: no mise binary found; the devcontainer CLI cannot be invoked" >&2
    return 6
  }
  spec=$(dev_runtime_cli_spec) || {
    echo "dev: no devcontainer CLI pin in config/mise/config.toml" >&2
    return 6
  }
  out=$("$mise_bin" exec "$spec" -- devcontainer --version 2>/dev/null) || {
    echo "dev: devcontainer CLI present but unrunnable ($mise_bin exec $spec)" >&2
    return 6
  }
  out=${out%%$'\n'*}
  [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || {
    echo "dev: 'devcontainer --version' printed no parseable version: $out" >&2
    return 6
  }
  printf '%s exec %s -- devcontainer\n' "$mise_bin" "$spec"
}

dev_runtime_docker_ok() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# devcontainer.json is JSONC. Strip // comments that are outside string
# literals, then trailing commas, so jq can parse it. A literal ", }" inside a
# string would be mangled; no devcontainer.json in ~/workspace contains one.
dev_runtime_jsonc_to_json() {
  awk '
    {
      out = ""; instr = 0; i = 1; n = length($0)
      while (i <= n) {
        c = substr($0, i, 1)
        if (instr) {
          out = out c
          if (c == "\\") { i++; out = out substr($0, i, 1) }
          else if (c == "\"") { instr = 0 }
        } else if (c == "\"") { instr = 1; out = out c }
        else if (c == "/" && substr($0, i + 1, 1) == "/") { break }
        else { out = out c }
        i++
      }
      print out
    }
  ' "$1" | tr '\n' ' ' | sed 's/,[[:space:]]*}/}/g; s/,[[:space:]]*]/]/g'
}

dev_runtime_kind() {
  local worktree="$1" cfg
  for cfg in "$worktree/.devcontainer/devcontainer.json" "$worktree/.devcontainer.json"; do
    if [[ -f "$cfg" ]]; then
      if dev_runtime_jsonc_to_json "$cfg" |
        jq -e 'has("dockerComposeFile")' >/dev/null 2>&1; then
        printf 'compose\n'
      else
        printf 'single\n'
      fi
      return 0
    fi
  done
  if [[ -d "$worktree/.devcontainer" ]]; then
    printf 'single\n'
    return 0
  fi
  printf 'none\n'
}

dev_runtime_detect() {
  local cache="$DEV_STATE_ROOT/runtime.json" now_epoch mtime
  if [[ -f "$cache" ]]; then
    now_epoch=$(date +%s)
    mtime=$(stat -c %Y "$cache" 2>/dev/null || printf '0\n')
    if ((now_epoch - mtime < DEV_RUNTIME_CACHE_TTL)); then
      cat "$cache"
      return 0
    fi
  fi

  local docker_ok=false mise_bin spec cli
  if dev_runtime_docker_ok; then docker_ok=true; fi
  mise_bin=$(dev_runtime_mise_bin) || mise_bin=""
  spec=$(dev_runtime_cli_spec) || spec=""
  cli=$(dev_runtime_devcontainer_cli 2>/dev/null) || cli=""

  mkdir -p "$DEV_STATE_ROOT"
  jq -nc --argjson d "$docker_ok" --arg m "$mise_bin" --arg s "$spec" --arg c "$cli" \
    '{docker: $d, mise: $m, cli_spec: $s, devcontainer: $c}' >"$cache.tmp"
  mv "$cache.tmp" "$cache"
  cat "$cache"
}
SH
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/dev_runtime_container.bats`
Expected: PASS (9 tests, 0 failures)

- [ ] **Step 6: Confirm the pin is picked up by `bin/versions`**

Run: `bin/versions | grep devcontainers`
Expected: a line reporting `npm:@devcontainers/cli` at `0.86.1`, with no edit to `bin/versions`.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/lib/runtime.sh tests/dev_runtime_container.bats config/mise/config.toml
git commit -m "feat(dev): runtime detection by execution and a pinned devcontainer CLI"
```

---

### Task 10: Container (`tools/dev/lib/container.sh`)

**Files:**
- Create: `tools/dev/lib/container.sh`
- Test: `tests/dev_runtime_container.bats` (appended)

**Interfaces:**
- Consumes: `dev_runtime_devcontainer_cli` (Task 9).
- Produces: `dev_container_enabled <config_json> <worktree>`,
  `dev_container_up <worktree> <config_json>`, `dev_container_alive <container_id>`,
  `dev_window_location <record_json> <window_json>` → `host`|`container`,
  `dev_window_workdir <record_json> <window_json>` → absolute path,
  `dev_container_exec_prefix <record_json> <window_json>`,
  `dev_window_inner_command <record_json> <window_json> <env_json>` → one shell-command string.

**Three shape notes.**

`dev_container_up` returns the four contract fields `containerId`, `remoteUser`,
`remoteWorkspaceFolder`, `exit_status`, plus `stderr_tail` (last 20 lines, which
`container.failed`'s `stderr_tail` needs) and `up_result` (the parsed tail line verbatim, which
`container.ready` stores per §4.3). Both ride along because the caller has nowhere else to get them.

`dev_container_exec_prefix` prints the argv **one element per line**, so a `workdir` or user
containing a space survives. Callers read it with `mapfile`.

`bin/claude-devcontainer-up:5-6` already records the discovery this depends on: `devcontainer exec`
is broken on compose-based setups, and it works around that by `docker exec`-ing directly with the
`containerId` from `devcontainer up` (`:85`, `docker exec -it -u "$user" -w "$wd" "$cid"`). So the
prefix uses `devcontainer exec` for `kind: single` and falls back to `docker exec` for `compose` and
whenever the CLI is unavailable. The user and workdir come from the record's `container.user` and
`container.workdir` and from nowhere else — no `// "root"`, no `// "/workspace"` default. ADR-1's
rule that `container.ready` replaces the whole `container` object exists precisely so those two stay
in step with the id; reintroducing a default here would resurrect the
`docker exec -u vscode -w /workspace` against a container where neither is right.

- [ ] **Step 1: Append the failing container tests**

```bash
cat >>tests/dev_runtime_container.bats <<'BATS'

# --- Task 10: container -----------------------------------------------------

load_container() { source "$REPO_ROOT/tools/dev/lib/container.sh"; }

CFG_AUTO='{"devcontainer":{"enabled":"auto","start_timeout":300}}'

@test "devcontainer up parses the JSON tail line out of log noise" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  stub_mise 'if [[ "$5" == --version ]]; then echo 0.86.1; exit 0; fi
echo "[12 ms] @devcontainers/cli 0.86.1."
echo "[+] Building 0.4s"
echo "not json at all"
echo "{\"outcome\":\"success\",\"containerId\":\"a710dead\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspace\"}"'

  run dev_container_up "$WT" "$CFG_AUTO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.containerId' <<<"$output")" = a710dead ]
  [ "$(jq -r '.remoteUser' <<<"$output")" = vscode ]
  [ "$(jq -r '.remoteWorkspaceFolder' <<<"$output")" = /workspace ]
  [ "$(jq -r '.exit_status' <<<"$output")" = 0 ]
  [ "$(jq -r '.up_result.outcome' <<<"$output")" = success ]
}

@test "a failing devcontainer up reports its status and stderr tail" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  stub_mise 'if [[ "$5" == --version ]]; then echo 0.86.1; exit 0; fi
echo "starting"
echo "Error: pull access denied for ghcr.io/private/image" >&2
echo "docker compose exited with code 18" >&2
exit 18'

  run dev_container_up "$WT" "$CFG_AUTO"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.exit_status' <<<"$output")" = 18 ]
  [ "$(jq -r '.containerId' <<<"$output")" = null ]
  [[ "$(jq -r '.stderr_tail' <<<"$output")" == *"pull access denied"* ]]
  [[ "$(jq -r '.stderr_tail' <<<"$output")" == *"code 18"* ]]
}

@test "enabled:false with a .devcontainer present still yields no container" {
  load_container
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  run dev_container_enabled '{"devcontainer":{"enabled":false}}' "$WT"
  [ "$status" -eq 1 ]
}

@test "enabled:auto follows the presence of .devcontainer" {
  load_container
  run dev_container_enabled "$CFG_AUTO" "$WT"
  [ "$status" -eq 1 ]
  mkdir -p "$WT/.devcontainer"
  echo '{"image":"x"}' >"$WT/.devcontainer/devcontainer.json"
  run dev_container_enabled "$CFG_AUTO" "$WT"
  [ "$status" -eq 0 ]
}

@test "enabled:true without a .devcontainer is an error" {
  load_container
  stub_mise 'echo 0.86.1'
  run dev_container_up "$WT" '{"devcontainer":{"enabled":true,"start_timeout":300}}'
  [ "$status" -eq 5 ]
  [[ "$output" == *"no .devcontainer"* ]]
}

@test "container liveness is true only for a literal true" {
  load_container
  stub_command docker 'echo true'
  run dev_container_alive a710dead
  [ "$status" -eq 0 ]
  stub_command docker 'echo false'
  run dev_container_alive a710dead
  [ "$status" -ne 0 ]
  stub_command docker 'echo "Error: No such object" >&2; exit 1'
  run dev_container_alive a710dead
  [ "$status" -ne 0 ]
  run dev_container_alive ""
  [ "$status" -ne 0 ]
}

@test "the exec prefix for a host window is bash -lc" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"vscode","workdir":"/workspace"}}'
  run dev_container_exec_prefix "$rec" '{"name":"scratch","location":"host"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = bash ]
  [ "${lines[1]}" = -lc ]
}

@test "the exec prefix for a compose container window carries the record's user and workdir" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  [ "${lines[0]}" = docker ]
  [ "${lines[1]}" = exec ]
  [ "${lines[2]}" = -i ]
  [ "${lines[3]}" = -t ]
  [ "${lines[4]}" = -u ]
  [ "${lines[5]}" = node ]
  [ "${lines[6]}" = -w ]
  [ "${lines[7]}" = /srv/app ]
  [ "${lines[8]}" = a710dead ]
  # Every prefix ends in a shell with -c so the caller can append the window's
  # command as one argv element. Without this, `docker exec ... <id> 'make test'`
  # looks for a binary named "make test".
  [ "${lines[9]}" = sh ]
  [ "${lines[10]}" = -c ]
}

@test "the exec prefix for a single-container window uses devcontainer exec" {
  load_container
  stub_mise 'echo 0.86.1'
  rec='{"worktree":"/w","container":{"status":"ready","kind":"single","id":"a710dead","user":"vscode","workdir":"/workspace"}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/.local/bin/mise" ]
  [ "${lines[1]}" = exec ]
  [ "${lines[2]}" = "npm:@devcontainers/cli@0.86.1" ]
  [ "${lines[3]}" = -- ]
  [ "${lines[4]}" = devcontainer ]
  [ "${lines[5]}" = exec ]
  [ "${lines[6]}" = --workspace-folder ]
  [ "${lines[7]}" = /w ]
  [ "${lines[8]}" = sh ]
  [ "${lines[9]}" = -c ]
}

@test "an unset location resolves to host when the record has no container" {
  # This is the plain-repository path. `devcontainer.enabled: auto` starts
  # nothing, so agent-1, agent-2 and shell — none of which pin a location —
  # must land on the host rather than demand a binding that will never exist.
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_location "$rec" '{"name":"agent-1","location":null}'
  [ "$status" -eq 0 ]
  [ "$output" = host ]
  run dev_container_exec_prefix "$rec" '{"name":"agent-1","location":null}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = bash ]
  [ "${lines[1]}" = -lc ]
}

@test "an unset location resolves to container when the record has one" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_location "$rec" '{"name":"shell","location":null}'
  [ "$status" -eq 0 ]
  [ "$output" = container ]
}

@test "an EXPLICIT container location still fails on a workspace with no container" {
  # The silent-downgrade case. A config that asked for a container and got the
  # host would put an agent in the wrong filesystem, so this one stays loud.
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no live container binding"* ]]
}

@test "cwd resolves against the worktree on the host and remoteWorkspaceFolder inside" {
  load_container
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_workdir "$rec" '{"name":"scratch","location":"host","cwd":"sub/dir"}'
  [ "$output" = "/w/sub/dir" ]
  run dev_window_workdir "$rec" '{"name":"shell","location":"container","cwd":"sub/dir"}'
  [ "$output" = "/srv/app/sub/dir" ]
  run dev_window_workdir "$rec" '{"name":"shell","location":"container","cwd":null}'
  [ "$output" = "/srv/app" ]
}

@test "the inner command applies cwd, environment and the agent" {
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_inner_command "$rec" \
    '{"name":"agent-1","agent":"claude --resume","cwd":"api","location":null}' \
    '{"CGO_ENABLED":"1","MSG":"a b"}'
  [ "$status" -eq 0 ]
  # `export`, not `env`: exec is a builtin, so `env FOO=1 exec claude` would ask
  # env(1) for a binary named `exec` and the pane would die immediately.
  [[ "$output" == "cd /w/api || exit 1; export "* ]]
  [[ "$output" == *"CGO_ENABLED=1"* ]]
  # @sh quoting: a value with a space survives as one argument.
  [[ "$output" == *"MSG='a b'"* ]]
  [[ "$output" == *"; exec claude --resume"* ]]
}

@test "the inner command's environment reaches the process it execs" {
  load_container
  rec="$(jq -nc --arg w "$BATS_TEST_TMPDIR" '{worktree:$w,container:{status:"none",id:null}}')"
  local cmd
  cmd=$(dev_window_inner_command "$rec" \
    '{"name":"shell","command":"printenv MSG","location":null}' '{"MSG":"a b"}')
  run sh -c "$cmd"
  [ "$status" -eq 0 ]
  [ "$output" = "a b" ]
}

@test "the inner command falls back to a login shell and never emits a bare export" {
  load_container
  rec='{"worktree":"/w","container":{"status":"none","id":null}}'
  run dev_window_inner_command "$rec" '{"name":"shell","location":null}' '{}'
  [ "$status" -eq 0 ]
  [ "$output" = 'cd /w || exit 1; exec "${SHELL:-/bin/bash}" -l' ]
  # A container window cannot use the host's $SHELL, and bash may not exist.
  rec='{"worktree":"/w","container":{"status":"ready","kind":"compose","id":"a710dead","user":"node","workdir":"/srv/app"}}'
  run dev_window_inner_command "$rec" '{"name":"shell","location":null}' '{}'
  [[ "$output" == *"exec bash -l 2>/dev/null || exec sh -l" ]]
}

@test "the exec prefix refuses to guess a missing user or workdir" {
  load_container
  rec='{"worktree":"/w","container":{"status":"lost","kind":"compose","id":null,"user":null,"workdir":null}}'
  run dev_container_exec_prefix "$rec" '{"name":"shell","location":"container"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no live container binding"* ]]
}
BATS
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bats tests/dev_runtime_container.bats`
Expected: FAIL (25 tests, 16 failures) — the Task 9 tests still pass; each new one errors with
`source: tools/dev/lib/container.sh: No such file or directory`.

- [ ] **Step 3: Write the implementation**

```bash
cat >tools/dev/lib/container.sh <<'SH'
# container.sh — every devcontainer concern lives here, so that no layer above
# it is written twice for the two repository kinds. For a plain WSL repo the
# exec prefix is simply `bash -lc` and there is no container.

dev_container_enabled() {
  local config_json="$1" worktree="$2" enabled
  enabled=$(jq -r '.devcontainer.enabled // "auto"' <<<"$config_json")
  case "$enabled" in
    true) return 0 ;;
    false) return 1 ;;
    auto) [[ -d "$worktree/.devcontainer" || -f "$worktree/.devcontainer.json" ]] ;;
    *)
      echo "dev: devcontainer.enabled must be auto|true|false, got '$enabled'" >&2
      return 5
      ;;
  esac
}

# Runs `devcontainer up` and returns the binding it reported. The CLI prints
# banner and build noise followed by one JSON object, so the result is the LAST
# line that parses as a JSON object, not the last line.
dev_container_up() {
  local worktree="$1" config_json="$2"
  local prefix cfg_rel timeout_s
  prefix=$(dev_runtime_devcontainer_cli) || return 6
  cfg_rel=$(jq -r '.devcontainer.config // empty' <<<"$config_json")
  timeout_s=$(jq -r '.devcontainer.start_timeout // 300' <<<"$config_json")

  if [[ -z "$cfg_rel" && ! -d "$worktree/.devcontainer" && ! -f "$worktree/.devcontainer.json" ]]; then
    echo "dev: devcontainer requested but $worktree has no .devcontainer/" >&2
    return 5
  fi

  local -a argv
  read -r -a argv <<<"$prefix"
  argv+=(up --workspace-folder "$worktree")
  if [[ -n "$cfg_rel" ]]; then
    argv+=(--config "$worktree/$cfg_rel")
  fi

  local out_file err_file status=0
  out_file=$(mktemp)
  err_file=$(mktemp)
  timeout "$timeout_s" "${argv[@]}" >"$out_file" 2>"$err_file" || status=$?

  local json="" line
  while IFS= read -r line; do
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line"; then
      json="$line"
    fi
  done <"$out_file"

  local stderr_tail
  stderr_tail=$(tail -n 20 "$err_file")
  rm -f "$out_file" "$err_file"

  jq -nc --argjson s "$status" --arg t "$stderr_tail" --argjson j "${json:-null}" '
    {
      containerId: ($j.containerId // null),
      remoteUser: ($j.remoteUser // null),
      remoteWorkspaceFolder: ($j.remoteWorkspaceFolder // null),
      exit_status: $s,
      stderr_tail: $t,
      up_result: $j
    }'

  [[ "$status" -eq 0 ]]
}

dev_container_alive() {
  local id="$1" out
  [[ -n "$id" && "$id" != null ]] || return 1
  out=$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) || return 1
  [[ "$out" == true ]]
}

# Resolves a window's effective location against the workspace record.
#
# Spec §4.1 defines the default as "container when one exists", so an UNSET
# location (JSON null, per Task 4's normalization) is a question that only the
# record can answer. Three cases:
#
#   "host"      -> host, always.
#   "container" -> container, always. On a workspace with no binding this is an
#                  error rather than a silent downgrade: the config asked for a
#                  container explicitly, and quietly running the command on the
#                  host would put an agent in the wrong filesystem.
#   null        -> container iff the record carries a container id, else host.
#                  This is what makes a plain (non-devcontainer) repository
#                  openable at all: `devcontainer.enabled: auto` correctly
#                  starts nothing, so agent-1, agent-2 and shell land on the
#                  host instead of demanding a binding that will never exist.
dev_window_location() {
  local record_json="$1" window_json="$2" location id
  location=$(jq -r '.location // "auto"' <<<"$window_json")
  case "$location" in
    host | container)
      printf '%s\n' "$location"
      return 0
      ;;
  esac
  id=$(jq -r '.container.id // empty' <<<"$record_json")
  if [[ -n "$id" && "$id" != null ]]; then
    printf 'container\n'
  else
    printf 'host\n'
  fi
}

# The directory a window's command starts in. `cwd` is relative to the repo root
# (spec §4.1), which means a different absolute base on each side of the
# container boundary: the worktree on the host, remoteWorkspaceFolder inside.
dev_window_workdir() {
  local record_json="$1" window_json="$2" location base cwd
  location=$(dev_window_location "$record_json" "$window_json") || return 1
  if [[ "$location" == host ]]; then
    base=$(jq -r '.worktree' <<<"$record_json")
  else
    base=$(jq -r '.container.workdir // empty' <<<"$record_json")
    [[ -n "$base" && "$base" != null ]] || return 1
  fi
  cwd=$(jq -r '.cwd // ""' <<<"$window_json")
  if [[ -z "$cwd" ]]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "${base%/}/${cwd#/}"
  fi
}

# Prints the argv prefix for a pane's command, one element per line.
#
# `devcontainer exec` is broken on compose-based setups; bin/claude-devcontainer-up
# documents the workaround and uses `docker exec -it -u <user> -w <wd> <cid>`
# with the id from `devcontainer up`. So compose takes the docker path, and so
# does anything else once the CLI turns out to be unrunnable.
#
# Every prefix ends in a shell with `-c`, so the caller may always append the
# window's command as ONE further argv element. Without that, `docker exec ...
# <id> 'make test'` would look for a binary literally named "make test". The
# container side uses `sh` rather than `bash`, because a devcontainer image is
# frequently alpine-based and bash is not guaranteed to be installed.
dev_container_exec_prefix() {
  local record_json="$1" window_json="$2" location workdir
  location=$(dev_window_location "$record_json" "$window_json") || return 1
  if [[ "$location" == host ]]; then
    printf '%s\n' bash -lc
    return 0
  fi

  local id user kind worktree
  id=$(jq -r '.container.id // empty' <<<"$record_json")
  user=$(jq -r '.container.user // empty' <<<"$record_json")
  kind=$(jq -r '.container.kind // "single"' <<<"$record_json")
  worktree=$(jq -r '.worktree' <<<"$record_json")

  if [[ -z "$id" || "$id" == null ]]; then
    echo "dev: no live container binding for a container-located window" >&2
    return 1
  fi

  if [[ "$kind" != compose ]]; then
    local cli
    if cli=$(dev_runtime_devcontainer_cli 2>/dev/null); then
      local -a cliv
      read -r -a cliv <<<"$cli"
      # `devcontainer exec` has no -w. The working directory is applied by the
      # inner command instead (dev_window_inner_command), which is also how the
      # host and docker paths honor `cwd`, so all three agree.
      printf '%s\n' "${cliv[@]}" exec --workspace-folder "$worktree" sh -c
      return 0
    fi
  fi

  # No defaults here on purpose: user and workdir are written by the same
  # container.ready event that wrote the id (ADR-1), so a missing one means the
  # binding is stale, not that root and /workspace are a safe guess.
  workdir=$(dev_window_workdir "$record_json" "$window_json") || {
    echo "dev: no live container binding (workdir missing) for this window" >&2
    return 1
  }
  if [[ -z "$user" || "$user" == null ]]; then
    echo "dev: no live container binding (user missing) for this window" >&2
    return 1
  fi
  printf '%s\n' docker exec -i -t -u "$user" -w "$workdir" "$id" sh -c
}

# The single shell-command argv element that follows the prefix.
#
# This is where `environment`, `cwd`, and the agent-vs-command choice are all
# actually applied. They were validated in Task 4 and then, until this function
# existed, dropped on the floor: every window ran $SHELL in the worktree with no
# environment injected. Doing it here rather than through per-transport flags
# (`docker exec -e`, `--remote-env`, `new-window -c`) means one implementation
# covers the host path, the docker path and the devcontainer-CLI path
# identically, and the CLI path has no working-directory flag at all.
#
# `exec` replaces the wrapper shell so that the pane's process IS the agent or
# command; otherwise `pane-died` would report the wrapper's exit, not the
# agent's, and every agent would sit behind a stray shell.
dev_window_inner_command() {
  local record_json="$1" window_json="$2" env_json="${3:-{\}}"
  local location workdir agent command assignments inner

  location=$(dev_window_location "$record_json" "$window_json") || return 1
  workdir=$(dev_window_workdir "$record_json" "$window_json") || return 1
  agent=$(jq -r '.agent // ""' <<<"$window_json")
  command=$(jq -r '.command // ""' <<<"$window_json")

  # jq's @sh quotes each value for POSIX sh, so a value containing a space,
  # quote or newline survives intact.
  assignments=$(jq -r 'to_entries | map("\(.key)=" + (.value | tostring | @sh))
    | join(" ")' <<<"$env_json")

  if [[ -n "$agent" ]]; then
    inner="exec $agent"
  elif [[ -n "$command" ]]; then
    inner="exec $command"
  elif [[ "$location" == host ]]; then
    inner='exec "${SHELL:-/bin/bash}" -l'
  else
    # The host's $SHELL says nothing about what exists in the container.
    inner='exec bash -l 2>/dev/null || exec sh -l'
  fi

  # `export ...; exec ...` rather than `env ... exec ...`. `exec` is a shell
  # builtin, so `env FOO=1 exec cmd` asks env(1) to run a binary called `exec`,
  # which does not exist -- every window with an `environment` entry would have
  # died instantly. export also composes with the two-branch container fallback
  # above, which a single env(1) invocation cannot.
  if [[ -n "$assignments" ]]; then
    inner="export $assignments; $inner"
  fi
  printf 'cd %q || exit 1; %s\n' "$workdir" "$inner"
}
SH
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dev_runtime_container.bats`
Expected: PASS (26 tests, 0 failures)

- [ ] **Step 5: Lint the two new libraries**

Run: `shellcheck -x -S warning -e SC1091 tools/dev/lib/runtime.sh tools/dev/lib/container.sh tools/dev/lib/reconcile.sh`
and `shfmt -d -i 2 -ci tools/dev/lib/runtime.sh tools/dev/lib/container.sh tools/dev/lib/reconcile.sh`
Expected: no output from either.

- [ ] **Step 6: Commit**

```bash
git add tools/dev/lib/container.sh tests/dev_runtime_container.bats
git commit -m "feat(dev): devcontainer up, liveness, and the pane exec-prefix builder"
```
### Task 11: tmux backend (`lib/backend-tmux.sh`)

**Files:**
- Create: `tools/dev/lib/backend-tmux.sh`
- Test: `tests/dev_backend_tmux.bats`

**Interfaces:**
- Consumes: `dev_now`, `dev_event_id_random`, `dev_event_build <id> <ts> <event> <workspace_id> <slug> <session_name> <worktree> <data_json>`, `dev_event_append <line>` (Task 5); `dev_container_exec_prefix <record_json> <window_json>`, `dev_window_inner_command <record_json> <window_json> <env_json>` (Task 10)
- Produces: `dev_tmux <args...>`, `dev_backend_create <session_name> <workspace_id> <slug> <worktree>`, `dev_backend_apply_layout <session_name> <config_json> <record_json>`, `dev_backend_query <session_name>`, `dev_backend_respawn_pane <session_name> <window> <command> [<container_id>]`, `dev_backend_kill <session_name>`

**This is the only file in the platform permitted to reference tmux.** Every consumer above it
reads the backend-neutral JSON that `dev_backend_query` emits — `{exists, worktree, clients,
windows[{name, panes[{alive}]}]}` — and nothing upstream ever parses tmux output. That is what makes
the backend replaceable in the way §1.1 claims rather than only in the way it is drawn.

Three facts this task is responsible for, each of which something else depends on:

- **The three session user options** (`@dev_workspace_id`, `@dev_slug`, `@dev_worktree`) set at
  create time are what let the tmux hooks in Task 16 build a complete event envelope without reading
  a record (ADR-1) — a hook must not take a lock or parse state. The envelope's fourth identity
  field, `session_name`, is *not* a fourth user option: it comes from tmux's own `#{session_name}`,
  because a stored copy would drift the moment a user ran `rename-session` by hand, and the hook
  would then emit events attributed to a name that no longer exists.
- **`remain-on-exit on` is set per window, never `-g`.** This is a correctness dependency, not a
  courtesy: `pane-died` fires only when `remain-on-exit` holds the dead pane in place, so scenario
  3's event fidelity — and the visible dead pane with its scrollback intact — depends on it. Setting
  it globally would change every ordinary tmux pane the user has, leaving dead shells everywhere.
- **A missing session, and a missing tmux server, are normal observations, not errors.** Both return
  `{"exists":false,...}` with exit 0. Scenario 4 (`pkill tmux`, then `dev list`) requires that
  `dev list` reports honestly rather than crashing, and it can only do that if the bottom of the
  stack treats "no server running" as an answer.

All targets are given with tmux's exact-match `=` prefix (`=session`, `=session:=window`). Without
it tmux prefix-matches names, so a session `dev` would resolve a request for a session
`dev-workspace`, which is precisely the cross-workspace misattachment ADR-7 exists to prevent.

Session creation opens a placeholder window named `dev-holder`, which `apply_layout` removes once it
has created at least one real window. The placeholder exists because `new-session` always creates a
window and `create` has no configuration to name it from. Removing it is not a violation of the
never-touch-an-existing-window rule: that rule protects windows a user or a previous layout owns,
and the holder is an artifact of the same operation that is removing it, born and destroyed with no
user process ever in it.

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/dev_backend_tmux.bats <<'BATS'
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/container.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  export TEST_WT="$TEST_ROOT/workspace/proj"
  mkdir -p "$TEST_WT"
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

fixture_record() {
  jq -nc --arg wt "${1:-$TEST_WT}" --arg sn "${2:-proj}" '{
    v: 1, workspace_id: "aa11", session_name: $sn, slug: "proj", worktree: $wt,
    status: "running", boot_id: null, config_digest: null, applied_digest: null,
    container: {status: "none", kind: null, id: null, user: null, workdir: null,
                verified: false, up_exit_status: null, up_result: null, observed_at: null},
    agents: [], opened_at: null, last_seen: null,
    scanned_through: {id: null, ts: null}, fold_gap: false, stopped_reason: null
  }'
}

# The agent windows carry a long-lived placeholder command rather than "claude":
# these assertions are about window creation and event emission, not about which
# binary an agent window runs, and a command that exits would race remain-on-exit.
#
# Locations are null (unset) rather than "container", matching what Task 4's
# normalization actually produces for the default layer. fixture_record carries
# no container binding, so dev_window_location resolves them to host and the
# panes really run — which is the plain-repository path, and the only one these
# tests can exercise without docker. An earlier draft pinned "container" here
# and would have aborted apply_layout on the first window.
fixture_config() {
  jq -nc '{
    version: 1, autostart: false,
    devcontainer: {enabled: "auto", start_timeout: 300},
    environment: {},
    windows: [
      {name: "agent-1", agent: "sleep 30", command: null, cwd: null, location: null, focus: true},
      {name: "agent-2", agent: "sleep 30", command: null, cwd: null, location: null, focus: false},
      {name: "shell",   agent: null, command: null, cwd: null, location: null, focus: false},
      {name: "scratch", agent: null, command: null, cwd: null, location: "host", focus: false}
    ]}'
}

@test "create sets the three dev user options per session" {
  mkdir -p "$TEST_ROOT/workspace/wt-a" "$TEST_ROOT/workspace/wt-b"
  dev_backend_create "proj-a" "id-a" "proj" "$TEST_ROOT/workspace/wt-a"
  dev_backend_create "proj-b" "id-b" "proj" "$TEST_ROOT/workspace/wt-b"

  run dev_tmux show-options -qv -t "=proj-a" @dev_workspace_id
  [ "$output" = "id-a" ]
  run dev_tmux show-options -qv -t "=proj-b" @dev_workspace_id
  [ "$output" = "id-b" ]
  run dev_tmux show-options -qv -t "=proj-a" @dev_worktree
  [ "$output" = "$TEST_ROOT/workspace/wt-a" ]
  run dev_tmux show-options -qv -t "=proj-b" @dev_worktree
  [ "$output" = "$TEST_ROOT/workspace/wt-b" ]
  run dev_tmux show-options -qv -t "=proj-a" @dev_slug
  [ "$output" = "proj" ]
}

@test "query with no tmux server at all reports exists:false and exits 0" {
  run dev_backend_query "nothing-here"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.exists')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.worktree')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.windows | length')" -eq 0 ]
}

@test "query on a nonexistent session of a running server reports exists:false and exits 0" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  run dev_backend_query "not-this-one"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.exists')" = "false" ]
}

@test "apply_layout creates the four default windows and is idempotent" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | sort | join(",")')" = "agent-1,agent-2,scratch,shell" ]
  [ "$(printf '%s' "$output" | jq -r '.worktree')" = "$TEST_WT" ]

  # A pane id captured before the second pass must survive it untouched.
  local before
  before=$(dev_tmux list-panes -t "=proj:=shell" -F '#{pane_id}')

  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_backend_query "proj"
  [ "$(printf '%s' "$output" | jq -r '.windows | length')" -eq 4 ]
  [ "$(dev_tmux list-panes -t '=proj:=shell' -F '#{pane_id}')" = "$before" ]
}

@test "apply_layout emits window.created per window and agent.started per agent window" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  local log="$DEV_STATE_ROOT/events/events.jsonl"
  [ "$(grep -c '"event":"window.created"' "$log")" -eq 4 ]
  [ "$(grep -c '"event":"agent.started"' "$log")" -eq 2 ]
  run jq -r 'select(.event == "agent.started") | .data.window' "$log"
  [[ "$output" == *"agent-1"* ]]
  [[ "$output" == *"agent-2"* ]]
  run jq -r 'select(.event == "window.created" and .data.window == "scratch") | .data.location' "$log"
  [ "$output" = "host" ]
  # An unset location on a container-less record resolves to host, not to a
  # container that does not exist.
  run jq -r 'select(.event == "window.created" and .data.window == "agent-1") | .data.location' "$log"
  [ "$output" = "host" ]
}

@test "the focused window is selected after the layout is applied" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"
  run dev_tmux display-message -p -t "=proj" '#{window_name}'
  [ "$output" = "agent-1" ]
}

@test "per-window cwd and environment reach the running pane" {
  # The regression this pins: `environment` and `cwd` were normalized and
  # validated, then never applied — every window ran in the worktree with no
  # environment injected.
  mkdir -p "$TEST_WT/sub"
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local cfg
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {DEV_PROBE: "hello world"},
    windows: [{name: "probe", agent: null, command: "sh -c 'printf \"%s|%s\\n\" \"$PWD\" \"$DEV_PROBE\" >probe.out; sleep 5'",
               cwd: "sub", location: "host", focus: false}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  local i
  for i in $(seq 1 50); do
    [[ -f "$TEST_WT/sub/probe.out" ]] && break
    sleep 0.1
  done
  [ -f "$TEST_WT/sub/probe.out" ]
  run cat "$TEST_WT/sub/probe.out"
  [ "$output" = "$TEST_WT/sub|hello world" ]
}

@test "remain-on-exit is set per window and never globally" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  dev_backend_apply_layout "proj" "$(fixture_config)" "$(fixture_record)"

  run dev_tmux show-window-options -t "=proj:=shell" remain-on-exit
  [[ "$output" == *"on"* ]]

  run dev_tmux show-options -g remain-on-exit
  [[ "$output" != *" on"* ]]
}

@test "a window whose process exits stays visible as a dead pane" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local cfg
  # sleep first so remain-on-exit is set before the process can exit; an
  # immediate `exit 3` races the option and tmux destroys the window.
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {}, windows: [
    {name: "shell", agent: null, command: "sleep 0.2; exit 3", cwd: null, location: "host", focus: true}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  sleep 1

  run dev_backend_query "proj"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | join(",")')" = "shell" ]
  [ "$(printf '%s' "$output" | jq -r '.windows[0].panes[0].alive')" = "false" ]
}

@test "respawn_pane brings a dead pane back to alive and emits pane.respawned" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  local cfg
  cfg=$(jq -nc '{version: 1, autostart: false, environment: {}, windows: [
    {name: "shell", agent: null, command: "sleep 0.2; exit 3", cwd: null, location: "host", focus: true}]}')
  dev_backend_apply_layout "proj" "$cfg" "$(fixture_record)"
  sleep 1
  [ "$(dev_backend_query proj | jq -r '.windows[0].panes[0].alive')" = "false" ]

  dev_backend_respawn_pane "proj" "shell" "sleep 30"

  run dev_backend_query "proj"
  [ "$(printf '%s' "$output" | jq -r '.windows[0].panes[0].alive')" = "true" ]
  run jq -r 'select(.event == "pane.respawned") | .data.window + " " + .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$output" = "shell aa11" ]
}

@test "kill removes the session and is a no-op when it is already gone" {
  dev_backend_create "proj" "aa11" "proj" "$TEST_WT"
  run dev_backend_kill "proj"
  [ "$status" -eq 0 ]
  [ "$(dev_backend_query proj | jq -r '.exists')" = "false" ]
  run dev_backend_kill "proj"
  [ "$status" -eq 0 ]
}
BATS
```

`pane-died` is a **window**-scoped hook. It does not appear in `show-hooks -g` and is visible only
under `show-hooks -gw`; anyone verifying Task 16's registration by hand against `show-hooks -g` will
conclude, wrongly, that it was never installed.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/dev_backend_tmux.bats`
Expected: FAIL — every test errors with `dev_backend_create: command not found`
(`tools/dev/lib/backend-tmux.sh` does not exist yet, so `source` also fails).

- [ ] **Step 3: Write the implementation**

```bash
cat > tools/dev/lib/backend-tmux.sh <<'SH'
#!/usr/bin/env bash
# tmux execution backend.
#
# This is the ONLY file in the dev platform permitted to reference tmux. Every
# consumer above it reads the backend-neutral JSON dev_backend_query emits; no
# caller parses tmux output. Targets always use tmux's exact-match "=" prefix,
# because tmux otherwise prefix-matches names and a request for session "dev"
# would resolve to "dev-workspace".

DEV_TMUX_SOCKET="${DEV_TMUX_SOCKET:-}"

dev_tmux() {
  if [[ -n "$DEV_TMUX_SOCKET" ]]; then
    tmux -L "$DEV_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# dev_backend_create <session_name> <workspace_id> <slug> <worktree>
#
# The three user options are read by the tmux hooks in dev.tmux.conf so a hook
# can build a full event envelope without reading a record or taking a lock.
# session_name is deliberately NOT stored as a fourth option: hooks read tmux's
# own #{session_name}, which cannot go stale after a manual rename-session.
#
# The dev-holder window is a placeholder; new-session always creates a window
# and this function has no configuration to name it from. apply_layout removes
# it once it has created a real window.
dev_backend_create() {
  local session_name="$1" workspace_id="$2" slug="$3" worktree="$4"
  dev_tmux new-session -d -s "$session_name" -c "$worktree" -n dev-holder || return 1
  # The trailing colon is required, not cosmetic: set-option takes a target-pane, and
  # the bare exact-match form `-t "=name"` fails with "no such session" on tmux 3.4.
  # `=name:` parses and still pins the match exactly. Verified on this machine.
  dev_tmux set-option -t "=$session_name:" @dev_workspace_id "$workspace_id" || return 1
  dev_tmux set-option -t "=$session_name:" @dev_slug "$slug" || return 1
  dev_tmux set-option -t "=$session_name:" @dev_worktree "$worktree" || return 1
}

# dev_backend_apply_layout <session_name> <config_json> <record_json>
#
# Creates only the windows that are missing, diffed by name. It never touches,
# respawns, renames, or reorders an existing window: "open never destroys"
# (§1.2) is enforced here, at the only layer that could violate it.
dev_backend_apply_layout() {
  local session_name="$1" config_json="$2" record_json="$3"
  local workspace_id slug worktree existing created=0 env_json focus_window
  local window_json name agent location workdir inner pane_cmd
  local -a prefix
  local ev_id ev_ts data line

  workspace_id=$(printf '%s' "$record_json" | jq -r '.workspace_id')
  slug=$(printf '%s' "$record_json" | jq -r '.slug')
  worktree=$(printf '%s' "$record_json" | jq -r '.worktree')
  env_json=$(printf '%s' "$config_json" | jq -c '.environment // {}')
  existing=$(dev_tmux list-windows -t "=$session_name" -F '#{window_name}' 2>/dev/null || true)

  while IFS= read -r window_json; do
    [[ -n "$window_json" ]] || continue
    name=$(printf '%s' "$window_json" | jq -r '.name')
    if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      continue
    fi
    agent=$(printf '%s' "$window_json" | jq -r '.agent // ""')

    # Container owns how a pane reaches its execution environment, resolves the
    # window's effective location against the record, and builds the single
    # command string that applies cwd and environment. Nothing about
    # containers, working directories or environment injection is decided here:
    # this layer only knows tmux. The prefix arrives one argv element per line
    # (Task 10) so a user or workdir containing a space cannot be resplit; read
    # it into an array and quote each element exactly once.
    location=$(dev_window_location "$record_json" "$window_json") || return 1
    mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$window_json") || return 1
    [[ ${#prefix[@]} -gt 0 ]] || return 1
    inner=$(dev_window_inner_command "$record_json" "$window_json" "$env_json") || return 1
    printf -v pane_cmd '%q ' "${prefix[@]}"
    printf -v pane_cmd '%s%q' "$pane_cmd" "$inner"

    # -c sets the directory tmux starts the pane process in. For a host window
    # dev_window_workdir already resolved `cwd` against the worktree; for a
    # container window the host has no such path, so the pane starts in the
    # worktree and the inner command cd's inside the container.
    if [[ "$location" == host ]]; then
      workdir=$(dev_window_workdir "$record_json" "$window_json") || return 1
    else
      workdir="$worktree"
    fi

    dev_tmux new-window -d -t "=$session_name:" -n "$name" -c "$workdir" "$pane_cmd" || return 1

    # Per window, never -g. pane-died fires only when remain-on-exit holds the
    # dead pane, so scenario 3's event fidelity depends on this; setting it
    # globally would leave every ordinary tmux pane the user has hanging dead.
    dev_tmux set-window-option -t "=$session_name:=$name" remain-on-exit on || return 1
    created=$((created + 1))

    ev_id=$(dev_event_id_random)
    ev_ts=$(dev_now)
    data=$(jq -nc --arg w "$name" --arg loc "$location" --arg cmd "$inner" \
      '{window: $w, location: $loc, command: $cmd}')
    line=$(dev_event_build "$ev_id" "$ev_ts" "window.created" \
      "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
    dev_event_append "$line"

    if [[ -n "$agent" ]]; then
      ev_id=$(dev_event_id_random)
      ev_ts=$(dev_now)
      data=$(jq -nc --arg w "$name" --arg cmd "$agent" '{window: $w, command: $cmd}')
      line=$(dev_event_build "$ev_id" "$ev_ts" "agent.started" \
        "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
      dev_event_append "$line"
    fi
  done < <(printf '%s' "$config_json" | jq -c '.windows[]')

  if [[ "$created" -gt 0 ]] && printf '%s\n' "$existing" | grep -Fxq -- 'dev-holder'; then
    dev_tmux kill-window -t "=$session_name:=dev-holder" 2>/dev/null || true
  fi

  # `focus: true` selects the window the user lands on. Applied after the holder
  # is gone and unconditionally rather than only on creation, so that attaching
  # to a workspace whose selection drifted still puts the cursor where the
  # config says. Validation (Task 4) already guarantees at most one.
  focus_window=$(printf '%s' "$config_json" |
    jq -r 'first((.windows // [])[] | select(.focus == true) | .name) // ""')
  if [[ -n "$focus_window" ]]; then
    dev_tmux select-window -t "=$session_name:=$focus_window" 2>/dev/null || true
  fi
}

# dev_backend_query <session_name>
#
# Backend-neutral snapshot. A session that does not exist, or no tmux server at
# all, is an observation and not an error: exists:false with exit 0. dev list
# after `pkill tmux` (scenario 4) depends on that.
#
# list-panes uses -s (all panes in the session), not -a: with -a tmux ignores
# -t and returns every pane on the server. Fields are ordered so window_name,
# which may contain spaces, is last and absorbs the remainder of the line.
dev_backend_query() {
  local session_name="$1" panes worktree clients
  if ! panes=$(dev_tmux list-panes -s -t "=$session_name" \
    -F '#{pane_dead} #{window_index} #{window_name}' 2>/dev/null); then
    printf '{"exists":false,"worktree":null,"clients":0,"windows":[]}\n'
    return 0
  fi
  worktree=$(dev_tmux show-options -qv -t "=$session_name" @dev_worktree 2>/dev/null || true)
  clients=$(dev_tmux list-clients -t "=$session_name" -F 'x' 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "$panes" | jq -Rsc --arg wt "$worktree" --argjson clients "$clients" '
    (split("\n")
     | map(select(length > 0))
     | map(capture("^(?<dead>[01]) (?<idx>[0-9]+) (?<name>.*)$")))
    | group_by(.idx | tonumber)
    | map({name: .[0].name, panes: map({alive: (.dead == "0")})})
    | {exists: true,
       worktree: (if $wt == "" then null else $wt end),
       clients: $clients,
       windows: .}
  '
}

# dev_backend_respawn_pane <session_name> <window> <command> [container_id]
#
# The envelope identity is read back from the session's user options rather
# than passed in, which is the same path the tmux hooks take.
#
# This function is the SOLE emitter of pane.respawned. Callers must not emit it
# again: a respawn that produced two events would fold twice, and the fold's
# `restarts` counter would report double every recovery.
dev_backend_respawn_pane() {
  local session_name="$1" window="$2" pane_command="$3" container_id="${4:-}"
  local workspace_id slug worktree ev_id ev_ts data line
  dev_tmux respawn-pane -k -t "=$session_name:=$window" "$pane_command" || return 1
  workspace_id=$(dev_tmux show-options -qv -t "=$session_name" @dev_workspace_id 2>/dev/null || true)
  slug=$(dev_tmux show-options -qv -t "=$session_name" @dev_slug 2>/dev/null || true)
  worktree=$(dev_tmux show-options -qv -t "=$session_name" @dev_worktree 2>/dev/null || true)
  ev_id=$(dev_event_id_random)
  ev_ts=$(dev_now)
  data=$(jq -nc --arg w "$window" --arg c "$container_id" \
    '{window: $w} + (if $c == "" then {} else {container_id: $c} end)')
  line=$(dev_event_build "$ev_id" "$ev_ts" "pane.respawned" \
    "$workspace_id" "$slug" "$session_name" "$worktree" "$data")
  dev_event_append "$line"
}

# dev_backend_kill <session_name>
#
# Reachable only from `dev stop`, the one destructive verb (§1.2). Note that
# tmux does NOT fire pane-died for kill-pane or kill-session, so explicit
# destruction produces no hook events: a session killed outside `dev stop` is a
# reconcile-discovered case (workspace.vanished), never a hook-reported one.
# Killing an already-absent session succeeds, so stop is idempotent.
dev_backend_kill() {
  local session_name="$1"
  if ! dev_tmux has-session -t "=$session_name" 2>/dev/null; then
    return 0
  fi
  dev_tmux kill-session -t "=$session_name"
}
SH
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/dev_backend_tmux.bats`
Expected: PASS (11 tests, 0 failures)

- [ ] **Step 5: Lint the new file**

Run: `shfmt -d -i 2 -ci tools/dev/lib/backend-tmux.sh && shellcheck -x -S warning -e SC1091 tools/dev/lib/backend-tmux.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tools/dev/lib/backend-tmux.sh tests/dev_backend_tmux.bats
git commit -m "feat(dev): tmux backend with backend-neutral query and per-window remain-on-exit"
```

---

### Task 12: `bin/dev` dispatcher, `commands/config.sh`, and the in-container refusal

**Files:**
- Create: `bin/dev`
- Create: `tools/dev/commands/config.sh`
- Test: `tests/dev_commands.bats`

**Interfaces:**
- Consumes: `dev_resolve <arg>` (Task 3); `dev_config_merged <slug> <worktree>`, `dev_config_validate <config_json>` (Task 4)
- Produces: `bin/dev` (the executable entry point; resolves `dev <word>` to `tools/dev/commands/<word>.sh` or falls back to `open <word>`), `dev_cmd_config [--compact] [<name>]`

`bin/dev` is a dispatcher and nothing else (§1.1). One file per subcommand is what makes `close`,
`doctor`, `update`, `logs`, and `agent` additive later rather than structural. It resolves
`dev <word>` to `tools/dev/commands/<word>.sh` when that file exists and otherwise to
`open <word>`, so `dev slabledger` and `dev status` need no distinguishing syntax.

**Install note:** the spec has `install.sh` symlink `bin/dev` onto `PATH`. That is superseded by a
repository fact — `~/.dotfiles/bin` is already first on `PATH` via `core/path.zsh`, so `bin/dev`
is callable with no symlink and Task 17 installs none.

**The in-container refusal comes before anything else**, including argument parsing. Inside a
container the `~/.dotfiles` that `dev` would read is a seed-copy that has already drifted from the
host's, and the tmux server that owns every session is on the host and unreachable from in there —
so a `dev` run in a container is not a degraded invocation, it is one that cannot be right. It exits
10 naming the host tmux server as the place to run it. Detecting and delegating to the host would
be friendlier, but it needs a host channel that does not exist, and inventing one so that a wrong
invocation can work is the wrong trade (§1.3).

The marker path is `${DEV_CONTAINER_MARKER:-/.dockerenv}`, an env-var override defined in the
implementation, which is what makes the refusal testable without a container.

`dev_cmd_config` prints the merged configuration for the resolved workspace. It is both the answer
to "what layout am I actually getting" and **the seam that makes the three-layer merge testable
without tmux or Docker** — no other component reads YAML, so a passing config test is a passing
merge for every consumer.

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/dev_commands.bats <<'BATS'
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dev_test
  export DEV_CONTAINER_MARKER="$TEST_ROOT/no-such-marker"
  stage_dev_root
  make_fixture_repo "proj"
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

# The dispatcher must be exercised against a tree that contains a commands/
# directory we control, because commands/open.sh does not exist until Task 14
# and this test must not depend on it. Staging a copy of the repo and writing a
# stub open.sh into it keeps the test stable both before and after Task 14.
stage_dev_root() {
  mkdir -p "$TEST_ROOT/root/tools/dev"
  cp -r "$REPO_ROOT/bin" "$TEST_ROOT/root/bin"
  cp -r "$REPO_ROOT/tools/dev/lib" "$TEST_ROOT/root/tools/dev/lib"
  cp -r "$REPO_ROOT/tools/dev/commands" "$TEST_ROOT/root/tools/dev/commands"
  cp "$REPO_ROOT/tools/dev/default-workspace.yaml" "$TEST_ROOT/root/tools/dev/default-workspace.yaml"
  export DEV_DOTFILES_ROOT="$TEST_ROOT/root"
}

stub_open_command() {
  cat > "$TEST_ROOT/root/tools/dev/commands/open.sh" <<'EOF'
dev_cmd_open() { printf 'OPEN:%s\n' "$*"; }
EOF
}

make_fixture_repo() {
  local name="$1"
  mkdir -p "$DEV_REPO_ROOT/$name"
  git -C "$DEV_REPO_ROOT/$name" init -q
}

@test "dev --help exits 0 and lists the six verbs" {
  run "$TEST_ROOT/root/bin/dev" --help
  [ "$status" -eq 0 ]
  local verb
  for verb in open attach list status stop config; do
    [[ "$output" == *"$verb"* ]]
  done
}

@test "dev rejects an unknown flag with exit 2" {
  run "$TEST_ROOT/root/bin/dev" --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "dev refuses to run inside a container with exit 10" {
  touch "$TEST_ROOT/in-a-container"
  DEV_CONTAINER_MARKER="$TEST_ROOT/in-a-container" run "$TEST_ROOT/root/bin/dev" list
  [ "$status" -eq 10 ]
  [[ "$output" == *"tmux server"* ]]
  [[ "$output" == *"host"* ]]
}

@test "dev config prints valid JSON with the four default windows" {
  run "$TEST_ROOT/root/bin/dev" config proj
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . > /dev/null
  [ "$(printf '%s' "$output" | jq -r '[.windows[].name] | sort | join(",")')" = "agent-1,agent-2,scratch,shell" ]
  [ "$(printf '%s' "$output" | jq -r '.version')" -eq 1 ]
}

@test "dev config --compact prints one line" {
  run "$TEST_ROOT/root/bin/dev" config --compact proj
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "dev config exits 5 on a config that fails validation" {
  mkdir -p "$DEV_OVERLAY_ROOT/proj"
  cat > "$DEV_OVERLAY_ROOT/proj/workspace.yaml" <<'EOF'
version: 1
windows:
  - name: shell
    agent: claude
    command: make test
EOF
  run "$TEST_ROOT/root/bin/dev" config proj
  [ "$status" -eq 5 ]
  [[ "$output" == *"shell"* ]]
}

@test "a word matching a command file dispatches to that command" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev" config --compact proj
  [ "$status" -eq 0 ]
  [[ "$output" != OPEN:* ]]
  printf '%s' "$output" | jq -e . > /dev/null
}

@test "a word matching no command file dispatches to open with the word intact" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev" slabledger
  [ "$status" -eq 0 ]
  [ "$output" = "OPEN:slabledger" ]
}

@test "no arguments at all dispatches to open with no arguments" {
  stub_open_command
  run "$TEST_ROOT/root/bin/dev"
  [ "$status" -eq 0 ]
  [ "$output" = "OPEN:" ]
}

@test "a verb containing a path separator is a usage error" {
  run "$TEST_ROOT/root/bin/dev" ../../etc/passwd
  [ "$status" -eq 2 ]
}
BATS
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/dev_commands.bats`
Expected: FAIL — every test reports `no such file or directory` for
`$TEST_ROOT/root/bin/dev`, since neither `bin/dev` nor `tools/dev/commands/` exists yet.

- [ ] **Step 3: Write the dispatcher**

```bash
mkdir -p tools/dev/commands
cat > bin/dev <<'SH'
#!/usr/bin/env bash
#
# dev - dispatcher for the workspace platform.
#
# Resolves `dev <word>` to tools/dev/commands/<word>.sh when that file exists,
# and otherwise to `open <word>`. One file per subcommand is what makes new
# verbs additive rather than structural (§1.1).

set -euo pipefail

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_CONTAINER_MARKER="${DEV_CONTAINER_MARKER:-/.dockerenv}"

dev_usage() {
  cat <<'USAGE'
usage: dev [<workspace>] | dev <command> [args]

  open <workspace>     Reconcile, ensure, and attach. The default verb; a bare
                       `dev <workspace>` means `dev open <workspace>`.
  attach <workspace>   Attach only; fails if the session is absent.
  list [--json]        Reconciled listing of every known workspace.
                       --json is the supported snapshot contract.
  status [<workspace>] Detail for one workspace, including configuration drift.
  stop [<workspace>]   End the session. The only destructive verb.
  config [<workspace>] Print the merged configuration JSON.

With no arguments, resolves the workspace from the current directory.
USAGE
}

dev_refuse_in_container() {
  if [[ -e "$DEV_CONTAINER_MARKER" ]]; then
    # The container's ~/.dotfiles is a stale seed-copy, and the tmux server that
    # owns every session lives on the host and is not reachable from in here, so
    # this invocation cannot be made correct. Delegating to the host would need a
    # host channel that does not exist (§1.3).
    printf 'dev: refusing to run inside a container.\n' >&2
    printf 'dev: sessions are owned by the tmux server on the WSL host; run dev there.\n' >&2
    exit 10
  fi
}

dev_main() {
  dev_refuse_in_container

  local verb cmd_file lib
  verb="${1:-open}"

  case "$verb" in
    -h | --help)
      dev_usage
      exit 0
      ;;
    -*)
      printf 'dev: unknown option: %s\n' "$verb" >&2
      dev_usage >&2
      exit 2
      ;;
  esac

  if [[ ! "$verb" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'dev: invalid workspace or command name: %s\n' "$verb" >&2
    exit 2
  fi

  cmd_file="$DEV_DOTFILES_ROOT/tools/dev/commands/${verb}.sh"
  if [[ -f "$cmd_file" ]]; then
    if [[ $# -gt 0 ]]; then shift; fi
  else
    verb="open"
    cmd_file="$DEV_DOTFILES_ROOT/tools/dev/commands/open.sh"
  fi

  for lib in resolve config events state fold reconcile runtime container backend-tmux; do
    # shellcheck source=/dev/null
    source "$DEV_DOTFILES_ROOT/tools/dev/lib/${lib}.sh"
  done
  # shellcheck source=/dev/null
  source "$cmd_file"

  "dev_cmd_${verb}" "$@"
}

dev_main "$@"
SH
chmod +x bin/dev
```

- [ ] **Step 4: Write `commands/config.sh`**

```bash
cat > tools/dev/commands/config.sh <<'SH'
#!/usr/bin/env bash
# dev config - print the merged workspace configuration.
#
# This is the seam that makes the three-layer YAML merge testable without tmux
# or Docker: no other component reads YAML, so every consumer sees exactly the
# document printed here.

dev_cmd_config() {
  local compact=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compact)
        compact=1
        shift
        ;;
      -h | --help)
        printf 'usage: dev config [--compact] [<workspace>]\n'
        return 0
        ;;
      -*)
        printf 'dev config: unknown option: %s\n' "$1" >&2
        return 2
        ;;
      *)
        if [[ -n "$name" ]]; then
          printf 'dev config: too many arguments\n' >&2
          return 2
        fi
        name="$1"
        shift
        ;;
    esac
  done

  local resolved slug worktree config
  resolved=$(dev_resolve "$name") || return $?
  slug=$(printf '%s' "$resolved" | jq -r '.slug')
  worktree=$(printf '%s' "$resolved" | jq -r '.worktree')
  config=$(dev_config_merged "$slug" "$worktree") || return $?
  dev_config_validate "$config" || return 5

  if [[ "$compact" -eq 1 ]]; then
    printf '%s' "$config" | jq -c .
  else
    printf '%s' "$config" | jq .
  fi
}
SH
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats tests/dev_commands.bats`
Expected: PASS (10 tests, 0 failures)

- [ ] **Step 6: Lint**

Run: `shfmt -d -i 2 -ci bin/dev tools/dev/commands/config.sh && shellcheck -x -S warning -e SC1091 bin/dev tools/dev/commands/config.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add bin/dev tools/dev/commands/config.sh tests/dev_commands.bats
git commit -m "feat(dev): dispatcher, in-container refusal, and dev config"
```

---

### Task 13: `commands/list.sh` and `commands/status.sh`

**Files:**
- Create: `tools/dev/commands/list.sh`
- Create: `tools/dev/commands/status.sh`
- Modify: `tests/dev_commands.bats`

**Interfaces:**
- Consumes: `dev_resolve <arg>`, `dev_resolve_is_primary <path>` (Task 3); `dev_config_merged <slug> <worktree>`, `dev_config_digest <config_json>` (Task 4); `dev_state_list` (Task 6); `dev_reconcile <resolved_json> <config_digest>` (Task 8); `dev_backend_query <session_name>` (Task 11)
- Produces: `dev_cmd_list [--json]`, `dev_cmd_status [<workspace>]`

**Neither command takes the operation lock, and neither repairs anything.** They reconcile — which
writes records and events but never starts, creates, or respawns (ADR-1) — and then print. Repair
belongs to `open`'s ensure phase alone, and the operation lock exists to serialize repair. A `list`
that took it would make two concurrent read-only listings contend for no reason, and a `list` that
repaired would give the platform a second, unnamed destructive path.

Because reconcile re-observes, **`dev list` always costs one backend query.** It cannot be answered
from disk. That is ADR-2's deliberate price for never lying.

**`dev list --json` is the public snapshot contract** — `{"v":1,"workspaces":[...]}`, versioned and
backend-neutral, each entry carrying `session_name`, `slug`, `worktree`, `status`, `container.status`,
`container.id`, `agents`, `last_seen`, `fold_gap`, `stopped_reason`, and `stale`. **`workspaces/*.json`
is explicitly not the consumer interface.** Records are *last observed*, so a consumer reading them
directly renders stale `running` badges for sessions that died thirty seconds ago — the exact
failure §5.1 names as the early warning that ADR-2 has leaked. The pairing for any consumer is
`dev list --json` for current state and `events.jsonl` for transitions; §4.3 documents the record
format so it is understood, not so it is depended upon.

`stale` is how that contract stays honest when reconcile itself fails — a lost CAS race, a backend
query that errored. The entry is still listed, from the last record, because dropping a workspace
from the listing is a worse lie than describing it imprecisely; but `stale: true` marks it as
last-known rather than observed, and human output appends `(stale: could not re-observe)`. Every
other entry is `stale: false`, so a consumer can treat the field as a plain trust bit.

Human output **groups by slug**, so the several working trees of one project read as a set rather
than as unrelated entries, and **marks basenames that appear more than once**, so the condition that
makes `dev <basename>` exit 3 is visible before a user hits it (ADR-7).

`dev status` reports `status` and `container.status` as **two axes**, because they answer different
questions: `status` is "does this workspace exist right now," `container.status` is "can I exec into
it." A workspace whose container failed is still a live tmux session with working host-side panes,
which is why no `container.*` event may write `status`. It also reports drift case D —
`config_digest` differing from `applied_digest` — and the message must name the remedy honestly:
Phase 1 does no additive reconciliation, so applying a changed layout means `dev stop <name>`
followed by `dev <name>`, not some background convergence that will never happen. Where `fold_gap`
is set the record was rebuilt from observation alone, so it says that some transitions between then
and now were not recorded, rather than presenting an uneventful history that is actually a lost one.

- [ ] **Step 1: Write the failing tests (appended to `tests/dev_commands.bats`)**

```bash
cat >> tests/dev_commands.bats <<'BATS'

# ---------------------------------------------------------------------------
# Task 13: dev list / dev status
# ---------------------------------------------------------------------------

# Any invocation of docker or the devcontainer CLI leaves a marker file behind,
# so a test can assert that a read-only command started nothing.
stub_no_start_runtime() {
  stub_command docker "touch '$TEST_ROOT/docker-called'; exit 0"
  stub_command devcontainer "touch '$TEST_ROOT/devcontainer-called'; exit 0"
}

write_record() {
  local id="$1" session="$2" slug="$3" worktree="$4"
  local status="$5" cstatus="$6" applied="$7" foldgap="$8"
  jq -nc \
    --arg id "$id" --arg sn "$session" --arg slug "$slug" --arg wt "$worktree" \
    --arg st "$status" --arg cs "$cstatus" --arg ap "$applied" --argjson fg "$foldgap" '{
      v: 1, workspace_id: $id, session_name: $sn, slug: $slug, worktree: $wt,
      status: $st, boot_id: null,
      config_digest: $ap, applied_digest: $ap,
      container: {status: $cs, kind: null, id: null, user: null, workdir: null,
                  verified: false, up_exit_status: null, up_result: null, observed_at: null},
      agents: [], opened_at: null, last_seen: "2026-08-03T10:00:00.000Z",
      scanned_through: {id: null, ts: null}, fold_gap: $fg, stopped_reason: null
    }' > "$DEV_STATE_ROOT/workspaces/${id}.json"
}

@test "dev list --json emits v:1 and every workspace, and parses as JSON" {
  make_fixture_repo "alpha"
  make_fixture_repo "beta"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:x" false
  write_record "$(printf 'b%.0s' {1..64})" beta beta "$DEV_REPO_ROOT/beta" stopped none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . > /dev/null
  [ "$(printf '%s' "$output" | jq -r '.v')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '[.workspaces[].session_name] | sort | join(",")')" = "alpha,beta" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("container")')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("fold_gap")')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0] | has("stopped_reason")')" = "true" ]
}

@test "a record whose session is absent lists as stopped and starts nothing" {
  stub_no_start_runtime
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].status')" = "stopped" ]
  [ ! -e "$TEST_ROOT/docker-called" ]
  [ ! -e "$TEST_ROOT/devcontainer-called" ]
}

@test "dev list groups two worktrees of one slug together" {
  make_fixture_repo "proj"
  mkdir -p "$DEV_REPO_ROOT/proj-pr5"
  git -C "$DEV_REPO_ROOT/proj-pr5" init -q
  write_record "$(printf 'c%.0s' {1..64})" proj proj "$DEV_REPO_ROOT/proj" stopped none "sha256:x" false
  write_record "$(printf 'd%.0s' {1..64})" "proj--proj-pr5" proj "$DEV_REPO_ROOT/proj-pr5" stopped none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^proj$')" -eq 1 ]
  [[ "$output" == *"  proj"* ]]
  [[ "$output" == *"proj--proj-pr5"* ]]
}

@test "a workspace whose reconcile fails is listed, but marked stale" {
  # The listing must neither drop the workspace nor present a remembered record
  # as if it had just been observed. `dev list --json` promises observed state
  # (ADR-2); `stale` is how it stays honest when it could not deliver that.
  stub_no_start_runtime
  make_fixture_repo "alpha"
  local id
  id=$(printf 'a%.0s' {1..64})
  write_record "$id" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  # The session is gone, so reconcile must write (status running -> stopped);
  # a read-only records directory makes every commit attempt fail, and reconcile
  # gives up with 8 after its bounded retries.
  chmod 500 "$DEV_STATE_ROOT/workspaces"

  run "$TEST_ROOT/root/bin/dev" list --json
  local rc="$status" out="$output"
  chmod 700 "$DEV_STATE_ROOT/workspaces"
  [ "$rc" -eq 0 ]
  [ "$(printf '%s' "$out" | jq -r '.workspaces | length')" -eq 1 ]
  [ "$(printf '%s' "$out" | jq -r '.workspaces[0].stale')" = "true" ]
  # Reported as the record last said, not as reconcile would have corrected it.
  [ "$(printf '%s' "$out" | jq -r '.workspaces[0].status')" = "running" ]
}

@test "a successfully reconciled entry is marked not stale" {
  stub_no_start_runtime
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" running none "sha256:x" false

  run "$TEST_ROOT/root/bin/dev" list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].stale')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.workspaces[0].status')" = "stopped" ]
}

@test "dev status reports a container-failed workspace as running with container failed" {
  make_fixture_repo "alpha"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  local id
  id=$(printf 'a%.0s' {1..64})
  write_record "$id" alpha alpha "$DEV_REPO_ROOT/alpha" running failed "sha256:x" false
  dev_backend_create "alpha" "$id" "alpha" "$DEV_REPO_ROOT/alpha"

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
  [[ "$output" == *"container"*"failed"* ]]
}

@test "dev status on a drifted configuration names dev stop as the remedy" {
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:stale" false

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev stop"* ]]
  [[ "$output" == *"drift"* ]]
}

@test "dev status surfaces fold_gap in words rather than as a flag" {
  make_fixture_repo "alpha"
  write_record "$(printf 'a%.0s' {1..64})" alpha alpha "$DEV_REPO_ROOT/alpha" stopped none "sha256:x" true

  run "$TEST_ROOT/root/bin/dev" status alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"were not recorded"* ]]
}
BATS
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_commands.bats`
Expected: the ten Task-12 tests still PASS; the six new tests FAIL with
`dev: unknown option` never reached and instead
`dev_cmd_list: command not found` / `dev_cmd_status: command not found`,
because `tools/dev/commands/list.sh` and `status.sh` do not exist and the dispatcher
therefore falls through to `open`.

- [ ] **Step 3: Write `commands/list.sh`**

```bash
cat > tools/dev/commands/list.sh <<'SH'
#!/usr/bin/env bash
# dev list - reconciled listing of every known workspace.
#
# Takes no operation lock and repairs nothing: it reconciles (which writes
# records and events but never starts anything) and prints. Because reconcile
# re-observes the backend, list always costs one backend query and cannot be
# answered from disk. That is ADR-2's price for never lying.
#
# `dev list --json` is the public snapshot contract. workspaces/*.json is NOT:
# records are last-observed, so a consumer reading them directly renders stale
# `running` badges for sessions that are already gone.

dev_cmd_list() {
  local as_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        as_json=1
        shift
        ;;
      -h | --help)
        printf 'usage: dev list [--json]\n'
        return 0
        ;;
      *)
        printf 'dev list: unexpected argument: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local tmp
  tmp=$(mktemp)
  local path record slug worktree is_primary resolved config digest updated entry stale

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    record=$(cat "$path") || continue
    slug=$(printf '%s' "$record" | jq -r '.slug')
    worktree=$(printf '%s' "$record" | jq -r '.worktree')

    # A record may outlive its working tree (ADR-7); is_primary is re-derived
    # where the path still exists and is false where it does not, which is the
    # same answer a deleted primary would have given.
    if dev_resolve_is_primary "$worktree" 2> /dev/null; then
      is_primary=true
    else
      is_primary=false
    fi
    resolved=$(printf '%s' "$record" | jq -c --argjson p "$is_primary" \
      '{slug, worktree, workspace_id, session_name, is_primary: $p}')

    if config=$(dev_config_merged "$slug" "$worktree" 2> /dev/null); then
      digest=$(dev_config_digest "$config")
    else
      digest=$(printf '%s' "$record" | jq -r '.config_digest // ""')
    fi

    # A workspace whose reconcile fails is listed from its last record rather
    # than aborting the whole listing -- but it is listed as explicitly stale.
    # ADR-2 makes `dev list --json` the snapshot contract precisely because it
    # reports observed rather than remembered state; substituting the prior
    # record silently would print remembered state under that contract, which is
    # the "stale running badge" failure §5.1 names as the signal the ADR leaked.
    # `stale: true` says the entry is last-known, not current, and a consumer
    # that ignores the field is no worse off than before.
    stale=false
    updated=$(dev_reconcile "$resolved" "$digest") || {
      updated="$record"
      stale=true
    }

    entry=$(printf '%s' "$updated" | jq -c --argjson stale "$stale" '{
      session_name, slug, worktree, status,
      container: {status: .container.status, id: .container.id},
      agents, last_seen, fold_gap, stopped_reason, stale: $stale
    }')
    printf '%s\n' "$entry" >> "$tmp"
  done < <(dev_state_list)

  if [[ "$as_json" -eq 1 ]]; then
    jq -s -c '{v: 1, workspaces: .}' < "$tmp"
  elif [[ ! -s "$tmp" ]]; then
    printf 'No workspaces recorded yet. Run `dev <repository>` to create one.\n'
  else
    dev_list_render_human < "$tmp"
  fi
  rm -f "$tmp"
}

# Groups by slug so the several working trees of one project read as a set, and
# marks any basename that appears more than once, since that is exactly the
# condition under which `dev <basename>` exits 3 (ADR-7).
dev_list_render_human() {
  jq -s -r '
    def base: (.worktree | split("/") | last);
    (map(base) | group_by(.) | map(select(length > 1) | .[0])) as $dupes
    | group_by(.slug)
    | map(sort_by(.session_name))
    | .[]
    | (.[0].slug),
      (.[] |
        "  " + .session_name
        + "\t" + (.status // "unknown")
        + "\tcontainer:" + (.container.status // "none")
        + "\t" + .worktree
        + (if .stale then "\t(stale: could not re-observe)" else "" end)
        + (if ($dupes | index(base)) then "\t(ambiguous basename)" else "" end))
  '
}
SH
```

- [ ] **Step 4: Write `commands/status.sh`**

```bash
cat > tools/dev/commands/status.sh <<'SH'
#!/usr/bin/env bash
# dev status - detail for one workspace.
#
# Takes no operation lock and repairs nothing. It reconciles, re-queries the
# backend for per-pane detail, and prints. `status` and `container.status` are
# reported as two axes because they answer different questions: whether the
# workspace exists right now, and whether anything can be exec'd into it.

dev_cmd_status() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        printf 'usage: dev status [<workspace>]\n'
        return 0
        ;;
      -*)
        printf 'dev status: unknown option: %s\n' "$1" >&2
        return 2
        ;;
      *)
        if [[ -n "$name" ]]; then
          printf 'dev status: too many arguments\n' >&2
          return 2
        fi
        name="$1"
        shift
        ;;
    esac
  done

  local resolved slug worktree config digest record session query
  resolved=$(dev_resolve "$name") || return $?
  slug=$(printf '%s' "$resolved" | jq -r '.slug')
  worktree=$(printf '%s' "$resolved" | jq -r '.worktree')
  config=$(dev_config_merged "$slug" "$worktree") || return $?
  digest=$(dev_config_digest "$config")
  record=$(dev_reconcile "$resolved" "$digest") || return $?
  session=$(printf '%s' "$record" | jq -r '.session_name')
  query=$(dev_backend_query "$session")

  printf '%s\t%s\n' "$session" "$(printf '%s' "$record" | jq -r '.status')"
  printf '  worktree:   %s\n' "$worktree"
  printf '  session:    %s\n' \
    "$(printf '%s' "$query" | jq -r 'if .exists
        then "live, \(.clients) client(s) attached"
        else "not present on the tmux server" end')"
  printf '  container:  %s\n' \
    "$(printf '%s' "$record" | jq -r '.container.status // "none"')"

  printf '%s' "$query" | jq -r '.windows[]? |
    "  window \(.name): " + ([.panes[] | if .alive then "alive" else "dead" end] | join(", "))'
  printf '%s' "$record" | jq -r '.agents[]? |
    "  agent \(.window): \(.state) (\(.command // "?"))"'

  local current applied
  current=$(printf '%s' "$record" | jq -r '.config_digest // "none"')
  applied=$(printf '%s' "$record" | jq -r '.applied_digest // "none"')
  if [[ "$current" != "$applied" ]]; then
    printf '  config:     drift: this session was built from %s, but the merged configuration is now %s.\n' \
      "$applied" "$current"
    # Phase 1 does no additive reconciliation; saying "it will converge" would
    # be a promise nothing in this phase keeps.
    printf '              Run `dev stop %s` and then `dev %s` to apply it.\n' "$session" "$session"
  fi

  if [[ "$(printf '%s' "$record" | jq -r '.fold_gap')" == "true" ]]; then
    printf '  history:    incomplete: some transitions between then and now were not recorded.\n'
  fi
}
SH
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/dev_commands.bats`
Expected: PASS (18 tests, 0 failures)

- [ ] **Step 6: Lint**

Run: `shfmt -d -i 2 -ci tools/dev/commands/list.sh tools/dev/commands/status.sh && shellcheck -x -S warning -e SC1091 tools/dev/commands/list.sh tools/dev/commands/status.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tools/dev/commands/list.sh tools/dev/commands/status.sh tests/dev_commands.bats
git commit -m "feat(dev): dev list snapshot contract and dev status drift reporting"
```
### Task 14: `commands/open.sh` + `commands/attach.sh`

**Files:**
- Create: `tools/dev/commands/open.sh`
- Create: `tools/dev/commands/attach.sh`
- Test: `tests/dev_commands.bats` (append; the file and its staging exist from Tasks 12–13)

**Interfaces:**
- Consumes: `dev_resolve <arg>`, `dev_config_merged <slug> <worktree>`,
  `dev_config_validate <config_json>`, `dev_config_digest <config_json>`,
  `dev_reconcile <resolved_json> <config_digest>`, `dev_runtime_detect`,
  `dev_runtime_kind <worktree>`, `dev_container_enabled <config_json> <worktree>`,
  `dev_container_up <worktree> <config_json>`,
  `dev_container_exec_prefix <record_json> <window_json>`,
  `dev_window_inner_command <record_json> <window_json> <env_json>`,
  `dev_backend_create <session_name> <workspace_id> <slug> <worktree>`,
  `dev_backend_apply_layout <session_name> <config_json> <record_json>`,
  `dev_backend_query <session_name>`, `dev_backend_respawn_pane <session_name> <window> <command> [<container_id>]`,
  `dev_now`, `dev_event_id_random`, `dev_event_build`, `dev_event_append`
- Produces: `dev_cmd_open [<name>] [--no-attach]`, `dev_cmd_attach [<name>]`,
  `dev_open_attach <session_name>`,
  `dev_open_boot_id`,
  `dev_open_window_command <record_json> <window_json> [<env_json>]`,
  `dev_open_session_index_write <workspace_id> <slug> <session_name> <worktree>`,
  `dev_open_session_index_path <session_name>` (Tasks 15 and 16 use the last two)

**What `open` is.** Exactly `reconcile → ensure → attach`, in §1.2's nine steps: resolve, merge
config and take its digest, reconcile **read-only and outside the operation lock**, then take the
operation lock, then runtime detection, `devcontainer up`, backend create-or-find, layout for
missing windows only, `workspace.opened`, release the lock, attach.

Four properties are load-bearing and each has a test below.

**`open` never destroys.** No path from `dev_cmd_open` reaches `kill-session`, `kill-pane`, or
`respawn-pane` on a *live* pane, and no path re-runs an existing window's command. Ensure is a set
of idempotent existence checks: `devcontainer up` returns a healthy container rather than rebuilding
it, `dev_backend_apply_layout` creates only windows that are absent, and the respawn loop touches
only panes the backend reports dead. That is what makes scenario 2's unsaved scratch buffer safe,
and it is the reason `open` needs no `--no-clobber` flag: there is nothing to clobber with.

**`workspace.attached` is not emitted here.** The command ends in `exec tmux attach`, so `bin/dev`
is gone and cannot retract an event for an attach that then fails — no TTY, a server that died in
the gap, a terminal too small. Attachment is reported by tmux's own `client-attached` /
`client-detached` hooks (Task 16), which fire when a client is actually attached and also catch
attachments this platform did not initiate. `workspace.opened` stays in the CLI because session
creation is something `dev` does and confirms synchronously.

**The attach guard (ADR-7).** Before attaching to an existing session, compare that session's
`@dev_worktree` — surfaced as `.worktree` by `dev_backend_query` — against the resolved path. On
mismatch the session belongs to a different working tree that happens to share a name, so `open`
uses `<slug>--<basename>--<hash6>` instead, where `hash6` is the first six characters of the
`workspace_id`. `workspace.opened` carries `session_name_actual` in `data` so the fold records the
name actually used rather than the name that was intended.

**Container repair, drift case C.** When reconcile left `container.status: lost`, ensure runs
`devcontainer up`, emits `container.replaced` (narrative) **and then** `container.ready` (the
binding — §4.4: one event type writes the binding, and it is the one that observes it), and calls
`dev_backend_respawn_pane` for every pane the backend reports dead. The running processes are lost;
the session, the window layout, and the scrollback survive.

**Two things this task adds that the design did not name, both forced by verified tmux behaviour.**

*The session index.* Probed on tmux 3.4: at `session-closed` time the closing session's user options
are already gone (`#{@dev_workspace_id}` expands empty) and `#{session_name}` expands to some *other*
session's name, so the `session-closed` hook structurally cannot carry the envelope. Registering the
hook per-session with the values baked in does not help either — a session-scoped `session-closed`
hook does not fire, because the session that owns it no longer exists. `open` therefore writes
`$DEV_STATE_ROOT/sessions/<session_name>.json` holding the four envelope values at session-creation
time, and Task 16's hook passes `#{hook_session_name}` for `dev-event` to look up. This is not a
record: it is written once per incarnation, never mutated, needs no lock, and lives outside
`workspaces/`, so ADR-1's "hooks append events, only reconcile writes records" is intact.

*`dev_open_attach` is a function so bats can override it*, and it spells the socket out rather than
going through `dev_tmux`, because `exec` cannot replace the process with a shell function.

**`--no-attach`.** Runs the whole of reconcile and ensure, emits `workspace.opened`, and returns 0
without calling `dev_open_attach`. It is the one flag `open` takes, and it exists outside tests too:
anything that wants a workspace *ready* rather than *entered* — the autostart unit, a script that
opens several workspaces before picking one — needs the work done without a terminal to attach to.
Task 19's lifecycle test uses it for exactly that reason. It skips precisely one function call and
changes nothing else, which is what keeps it from becoming a second code path.

- [ ] **Step 1: Write the failing tests for `open` and `attach`**

Append to `tests/dev_commands.bats`:

```bash
dev_open_load_libs() {
  source "$REPO_ROOT/bin/common.sh"
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/config.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  source "$REPO_ROOT/tools/dev/lib/reconcile.sh"
  source "$REPO_ROOT/tools/dev/lib/runtime.sh"
  source "$REPO_ROOT/tools/dev/lib/container.sh"
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"
  source "$REPO_ROOT/tools/dev/commands/open.sh"
  source "$REPO_ROOT/tools/dev/commands/attach.sh"
  source "$REPO_ROOT/tools/dev/commands/stop.sh"
}

dev_open_fixture() {
  local dir="$DEV_REPO_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  printf '%s\n' "$dir"
}

dev_open_stub_attach() {
  dev_open_attach() {
    printf 'ATTACH %s\n' "$1" >>"$TEST_ROOT/attached"
  }
}

dev_open_events() {
  jq -r "$1" "$DEV_STATE_ROOT/events/events.jsonl"
}

@test "open creates the session with the four default windows and emits workspace.opened" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_tmux list-windows -t '=demo' -F '#{window_name}'
  [ "$status" -eq 0 ]
  [[ "$output" == *agent-1* ]]
  [[ "$output" == *agent-2* ]]
  [[ "$output" == *shell* ]]
  [[ "$output" == *scratch* ]]
  [[ "$output" != *dev-holder* ]]

  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]
  local opened
  opened=$(dev_open_events 'select(.event == "workspace.opened") | .data | [.boot_id, .config_digest, .session_name_actual] | @tsv')
  [[ "$opened" == *"sha256:"* ]]
  [[ "$opened" == *demo* ]]
  [ -n "${opened%%	*}" ]

  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH demo" ]
  dev_tmux kill-server || true
}

@test "a second open creates nothing, re-runs nothing, and leaves scratch untouched" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  dev_tmux send-keys -t '=demo:=scratch' 'MARKER-SCENARIO-2' Enter
  sleep 0.3

  local before
  before=$(dev_tmux list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  local after
  after=$(dev_tmux list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')
  [ "$before" = "$after" ]

  run dev_tmux capture-pane -p -t '=demo:=scratch'
  [ "$status" -eq 0 ]
  [[ "$output" == *MARKER-SCENARIO-2* ]]

  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]
  dev_tmux kill-server || true
}

@test "open --no-attach does the work, prints the session name, and never attaches" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$output" = "demo" ]
  [ ! -e "$TEST_ROOT/attached" ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -eq 0 ]
  [ "$(dev_open_events 'select(.event == "workspace.opened") | .id' | wc -l)" -eq 1 ]

  run dev_cmd_open --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-attach"* ]]
  dev_tmux kill-server || true
}

@test "open exits 7 when the operation lock is already held" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  flock -x "$DEV_STATE_ROOT/locks/$ws_id.op" sleep 5 &
  local holder=$!
  sleep 0.4

  run dev_cmd_open demo
  [ "$status" -eq 7 ]
  [[ "$output" == *"another dev is working on this workspace"* ]]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  dev_tmux kill-server || true
}

@test "open after a container loss emits container.replaced then container.ready and respawns dead panes" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  mkdir -p "$dir/.devcontainer"
  printf '{"image":"alpine:3"}\n' >"$dir/.devcontainer/devcontainer.json"

  stub_command devcontainer '
if [ "$1" = "--version" ]; then echo 0.86.1; exit 0; fi
echo "{\"outcome\":\"success\",\"containerId\":\"newcid\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspace\"}"
'
  stub_command mise 'shift 2; shift; exec "$@"'
  stub_command docker '
case "$1" in
  info) exit 0 ;;
  inspect)
    for a in "$@"; do
      if [ "$a" = "oldcid" ]; then exit 1; fi
    done
    echo true; exit 0 ;;
  exec) shift; while [ "${1#-}" != "$1" ]; do shift 2; done; shift; exec "$@" ;;
  *) exit 0 ;;
esac
'

  # Seed a record bound to a container that no longer exists.
  local session record
  session=demo
  record=$(dev_state_new "$(dev_resolve_workspace_id "$dir")" demo demo "$dir")
  record=$(jq '.status = "running"
    | .container.status = "ready"
    | .container.id = "oldcid"
    | .container.kind = "single"
    | .container.user = "vscode"
    | .container.workdir = "/workspace"' <<<"$record")
  ws_id=$(dev_resolve_workspace_id "$dir")
  printf '%s\n' "$record" >"$(dev_state_path "$ws_id")"

  # A live session with one dead pane.
  dev_backend_create "$session" "$ws_id" demo "$dir"
  dev_backend_apply_layout "$session" "$(dev_config_merged demo "$dir")" "$record"
  dev_tmux set-window-option -t '=demo:=shell' remain-on-exit on
  dev_tmux respawn-pane -k -t '=demo:=shell' 'exit 3'
  sleep 0.6
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "1" ]

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  local order
  order=$(dev_open_events 'select(.event == "container.replaced" or .event == "container.ready") | .event' | tr '\n' ' ')
  [ "$order" = "container.replaced container.ready " ]

  [ "$(dev_open_events 'select(.event == "container.replaced") | .data.old_id')" = "oldcid" ]
  [ "$(dev_open_events 'select(.event == "container.replaced") | .data.new_id')" = "newcid" ]
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .data.window')" = "shell" ]
  # Exactly one event for one respawn: `dev_backend_respawn_pane` is the sole
  # emitter and `dev_open_respawn_dead` must not emit a second. A double event
  # folds twice and reports every recovery as two restarts.
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .id' | wc -l)" = "1" ]
  [ "$(dev_open_events 'select(.event == "pane.respawned") | .data.container_id')" = "newcid" ]
  [ "$(dev_tmux list-panes -t '=demo:=shell' -F '#{pane_dead}')" = "0" ]
  dev_tmux kill-server || true
}

@test "a respawned window comes back as the window it was, not as a bare shell" {
  # The respawn path used to re-derive `.command` itself, which meant an agent
  # window came back running $SHELL in the worktree with no environment -- the
  # pane was alive and silently not what the config declared. It now goes through
  # dev_window_inner_command, the same function creation uses. Asserted by
  # running the produced string rather than by matching its text: the string is
  # `sh -c <quoted inner>`, so a substring match would be testing the quoting
  # rather than the behaviour.
  setup_dev_test
  dev_open_load_libs
  local dir ws_id record wjson env_json cmd
  dir=$(dev_open_fixture demo)
  mkdir -p "$dir/sub dir"
  ws_id=$(dev_resolve_workspace_id "$dir")
  record=$(dev_state_new "$ws_id" demo demo "$dir")

  stub_command my-agent "printf '%s|%s|%s\n' \"\$PWD\" \"\$FOO\" \"\$1\" >'$TEST_ROOT/agent-ran'"

  wjson='{"name":"agent-1","agent":"my-agent --flag","cwd":"sub dir","location":"host"}'
  env_json='{"FOO":"a b"}'
  cmd=$(dev_open_window_command "$record" "$wjson" "$env_json")

  bash -c "$cmd"
  [ "$(cat "$TEST_ROOT/agent-ran")" = "$dir/sub dir|a b|--flag" ]
}

@test "attach on an absent session exits 4 and creates nothing" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_attach demo
  [ "$status" -eq 4 ]
  [[ "$output" == *"no live session"* ]]
  [ ! -e "$TEST_ROOT/attached" ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]
  dev_tmux kill-server || true
}

@test "the attach guard picks the hashed name when an existing session holds a different worktree" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir other ws_id
  dir=$(dev_open_fixture demo)
  other=$(dev_open_fixture impostor)

  # A squatter session already owns the name "demo" but points elsewhere.
  dev_backend_create demo "$(dev_resolve_workspace_id "$other")" demo "$other"

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  ws_id=$(dev_resolve_workspace_id "$dir")
  local expected="demo--$(basename "$dir")--${ws_id:0:6}"
  run dev_tmux has-session -t "=$expected"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH $expected" ]
  [ "$(dev_open_events 'select(.event == "workspace.opened") | .data.session_name_actual')" = "$expected" ]
  [ "$(dev_tmux show-options -t "=$expected:" -qv @dev_worktree)" = "$dir" ]
  dev_tmux kill-server || true
}

@test "a collision-hashed name survives the conflicting session going away" {
  # The durability half of ADR-7's guard, and the regression this pins: every
  # later command used to re-derive the resolver's PROPOSAL rather than read the
  # record. Once the squatter left, `dev attach demo` looked up the plain name,
  # found nothing, and reported no live session — while the hashed session was
  # still running with the user's work in it. `dev demo` would then have built a
  # second session for the same working tree.
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir other ws_id expected
  dir=$(dev_open_fixture demo)
  other=$(dev_open_fixture impostor)

  dev_backend_create demo "$(dev_resolve_workspace_id "$other")" demo "$other"
  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]

  ws_id=$(dev_resolve_workspace_id "$dir")
  expected="demo--$(basename "$dir")--${ws_id:0:6}"
  [ "$(jq -r '.session_name' "$(dev_state_path "$ws_id")")" = "$expected" ]

  # The squatter leaves. The plain name is now free.
  dev_tmux kill-session -t '=demo'
  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]

  # attach must still find the hashed session.
  rm -f "$TEST_ROOT/attached"
  run dev_cmd_attach demo
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/attached")" = "ATTACH $expected" ]

  # open must reuse it rather than create a second session on the free name.
  run dev_cmd_open demo --no-attach
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]
  [ "$(dev_tmux list-sessions -F '#{session_name}' | wc -l)" = "1" ]

  # And reconcile never called it vanished: it queried the recorded name.
  [ "$(jq -r '.status' "$(dev_state_path "$ws_id")")" = "running" ]
  [ -z "$(dev_open_events 'select(.event == "workspace.vanished") | .id')" ]
  dev_tmux kill-server || true
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_commands.bats`
Expected: FAIL with `dev_cmd_open: command not found` (the files do not exist yet, so
`dev_open_load_libs` fails at `source .../commands/open.sh` with "No such file or directory").

- [ ] **Step 3: Write `tools/dev/commands/open.sh`**

```bash
# shellcheck shell=bash
# dev open — reconcile, ensure, attach. Never destroys anything.

dev_open_session_index_path() {
  printf '%s\n' "$DEV_STATE_ROOT/sessions/$1.json"
}

dev_open_session_index_write() {
  local workspace_id="$1" slug="$2" session_name="$3" worktree="$4"
  local path
  path=$(dev_open_session_index_path "$session_name")
  mkdir -p "$(dirname "$path")"
  jq -n --arg id "$workspace_id" --arg slug "$slug" --arg name "$session_name" \
    --arg tree "$worktree" \
    '{workspace_id: $id, slug: $slug, session_name: $name, worktree: $tree}' >"$path"
}

dev_open_boot_id() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    tr -d '\n' </proc/sys/kernel/random/boot_id
  else
    printf 'unknown'
  fi
}

# Every event this command writes goes through here, so the envelope is assembled
# once and picks up the post-guard session name automatically.
dev_open_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" \
    "$DEV_OPEN_SESSION" "$DEV_OPEN_WORKTREE" "$data")
  dev_event_append "$line"
}

# The shell command for one window, built exactly the way Task 12's
# `dev_backend_apply_layout` builds it: the container exec prefix (one argv
# element per line, per Task 10) quoted back into a single string, then the
# window's inner command. It must go through `dev_window_inner_command` for the
# same reason creation does -- that function is where `agent`, `command`, `cwd`
# and `environment` are applied. An earlier draft re-derived `.command` here and
# so respawned an agent window as a bare $SHELL in the worktree with no
# environment: the pane came back, silently not being what it was.
dev_open_window_command() {
  local record_json="$1" window_json="$2" env_json="${3:-{\}}"
  local prefix=() inner out
  mapfile -t prefix < <(dev_container_exec_prefix "$record_json" "$window_json") || return 1
  [[ ${#prefix[@]} -gt 0 ]] || return 1
  inner=$(dev_window_inner_command "$record_json" "$window_json" "$env_json") || return 1
  printf -v out '%q ' "${prefix[@]}"
  printf '%s%q\n' "$out" "$inner"
}

dev_open_attach() {
  local session_name="$1"
  if [[ -n "$DEV_TMUX_SOCKET" ]]; then
    exec tmux -L "$DEV_TMUX_SOCKET" attach-session -t "=$session_name"
  fi
  exec tmux attach-session -t "=$session_name"
}

# Brings the container up and returns the record with the new binding patched in.
# The on-disk record is not touched: it is reconcile's, and it catches up on the
# next pass by folding the container.ready this writes.
dev_open_container_up() {
  local config="$1" record="$2" repair="$3"
  local old_id up status ts

  old_id=$(jq -r '.container.id // ""' <<<"$record")
  dev_open_emit container.starting '{}'

  up=$(dev_container_up "$DEV_OPEN_WORKTREE" "$config") || up='{"exit_status":1}'
  status=$(jq -r '.exit_status // 1' <<<"$up")
  if [[ "$status" != "0" ]]; then
    dev_open_emit container.failed \
      "$(jq -n --argjson s "$status" '{reason: "devcontainer up failed", up_exit_status: $s}')"
    printf 'dev: devcontainer up failed for %s (exit %s)\n' "$DEV_OPEN_SESSION" "$status" >&2
    return 1
  fi

  local new_id kind user workdir ready
  new_id=$(jq -r '.containerId' <<<"$up")
  user=$(jq -r '.remoteUser' <<<"$up")
  workdir=$(jq -r '.remoteWorkspaceFolder' <<<"$up")
  kind=$(dev_runtime_kind "$DEV_OPEN_WORKTREE")

  if [[ "$repair" -eq 1 ]]; then
    dev_open_emit container.replaced \
      "$(jq -n --arg o "$old_id" --arg n "$new_id" \
        '{old_id: $o, new_id: $n, reason: "lost"}')"
  fi

  ready=$(jq -n --arg id "$new_id" --arg kind "$kind" --arg user "$user" \
    --arg workdir "$workdir" --argjson st "$status" --argjson res "$up" \
    '{id: $id, kind: $kind, user: $user, workdir: $workdir,
      up_exit_status: $st, up_result: $res}')
  dev_open_emit container.ready "$ready"

  ts=$(dev_now)
  jq --argjson d "$ready" --arg ts "$ts" \
    '.container = {status: "ready", kind: $d.kind, id: $d.id, user: $d.user,
                   workdir: $d.workdir, verified: false,
                   up_exit_status: $d.up_exit_status, up_result: $d.up_result,
                   observed_at: $ts}' <<<"$record"
}

# Only panes the backend reports dead are touched. A live pane is never respawned.
dev_open_respawn_dead() {
  local config="$1" record="$2"
  local query dead cid win wjson cmd env_json
  query=$(dev_backend_query "$DEV_OPEN_SESSION")
  dead=$(jq -r '.windows[] | select([.panes[].alive] | index(false)) | .name' <<<"$query")
  [[ -n "$dead" ]] || return 0
  cid=$(jq -r '.container.id // ""' <<<"$record")
  env_json=$(jq -c '.environment // {}' <<<"$config")
  while IFS= read -r win; do
    [[ -n "$win" ]] || continue
    wjson=$(jq -c --arg w "$win" '.windows[] | select(.name == $w)' <<<"$config")
    [[ -n "$wjson" ]] || continue
    cmd=$(dev_open_window_command "$record" "$wjson" "$env_json") || continue
    # `dev_backend_respawn_pane` is the sole emitter of pane.respawned (Task 12),
    # so the container id is handed to it rather than emitted again here. Two
    # events for one respawn would fold twice and double the `restarts` counter.
    dev_backend_respawn_pane "$DEV_OPEN_SESSION" "$win" "$cmd" "$cid" || continue
  done <<<"$dead"
}

dev_open_ensure_locked() {
  local config="$1" record="$2"
  local repair=0 created=0 query live

  if [[ "$(jq -r '.container.status // "none"' <<<"$record")" == "lost" ]]; then
    repair=1
  fi

  if dev_container_enabled "$config" "$DEV_OPEN_WORKTREE"; then
    dev_runtime_detect >/dev/null || return $?
    record=$(dev_open_container_up "$config" "$record" "$repair") || return $?
  fi

  query=$(dev_backend_query "$DEV_OPEN_SESSION")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    live=$(jq -r '.worktree // ""' <<<"$query")
    if [[ "$live" != "$DEV_OPEN_WORKTREE" ]]; then
      # ADR-7: the name is taken by a different working tree. Use the hashed form
      # rather than attaching to someone else's session.
      DEV_OPEN_SESSION="$DEV_OPEN_SLUG--$(basename "$DEV_OPEN_WORKTREE")--${DEV_OPEN_WS_ID:0:6}"
      query=$(dev_backend_query "$DEV_OPEN_SESSION")
    fi
  fi

  if [[ "$(jq -r '.exists' <<<"$query")" != "true" ]]; then
    dev_backend_create "$DEV_OPEN_SESSION" "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" \
      "$DEV_OPEN_WORKTREE" || return $?
    created=1
  fi

  dev_open_session_index_write "$DEV_OPEN_WS_ID" "$DEV_OPEN_SLUG" "$DEV_OPEN_SESSION" \
    "$DEV_OPEN_WORKTREE"

  record=$(jq --arg n "$DEV_OPEN_SESSION" '.session_name = $n' <<<"$record")
  dev_backend_apply_layout "$DEV_OPEN_SESSION" "$config" "$record" || return $?

  if [[ "$repair" -eq 1 && "$created" -eq 0 ]]; then
    dev_open_respawn_dead "$config" "$record"
  fi

  if [[ "$created" -eq 1 ]]; then
    dev_open_emit workspace.opened \
      "$(jq -n --arg b "$(dev_open_boot_id)" --arg d "$DEV_OPEN_DIGEST" \
        --arg n "$DEV_OPEN_SESSION" \
        '{boot_id: $b, config_digest: $d, session_name_actual: $n}')"
  fi
}

# The operation lock wraps ensure only. Reconcile ran before it, unlocked, because
# reconcile is read-only with respect to the workspace (ADR-1).
dev_open_ensure() {
  local config="$1" record="$2"
  local lock rc=0
  lock="$DEV_STATE_ROOT/locks/$DEV_OPEN_WS_ID.op"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if ! flock -n 9; then
    exec 9>&-
    printf 'dev: another dev is working on this workspace (%s)\n' "$DEV_OPEN_SESSION" >&2
    return 7
  fi
  dev_open_ensure_locked "$config" "$record" || rc=$?
  exec 9>&-
  return "$rc"
}

dev_open_usage() {
  cat <<'EOF'
usage: dev open [<name>] [--no-attach]

  <name>        workspace to open; defaults to the working tree containing $PWD
  --no-attach   reconcile, ensure and emit workspace.opened, then exit without
                attaching. Useful for autostart and scripting.
EOF
}

dev_cmd_open() {
  local arg="" no_attach=0 a
  for a in "$@"; do
    case "$a" in
      --no-attach)
        no_attach=1
        ;;
      -h | --help)
        dev_open_usage
        return 0
        ;;
      -*)
        dev_open_usage >&2
        return 2
        ;;
      *)
        if [[ -n "$arg" ]]; then
          dev_open_usage >&2
          return 2
        fi
        arg="$a"
        ;;
    esac
  done

  local resolved config record
  resolved=$(dev_resolve "$arg") || return $?

  DEV_OPEN_WS_ID=$(jq -r '.workspace_id' <<<"$resolved")
  DEV_OPEN_SLUG=$(jq -r '.slug' <<<"$resolved")
  DEV_OPEN_WORKTREE=$(jq -r '.worktree' <<<"$resolved")
  # Start from the recorded name so a workspace the ADR-7 guard already renamed
  # reuses its hashed session instead of re-testing the plain name and creating
  # a second session for the same working tree. The guard in
  # dev_open_ensure_locked still runs; on a renamed workspace it now finds its
  # own session and does nothing.
  DEV_OPEN_SESSION=$(dev_state_session_name "$DEV_OPEN_WS_ID" \
    "$(jq -r '.session_name' <<<"$resolved")")

  config=$(dev_config_merged "$DEV_OPEN_SLUG" "$DEV_OPEN_WORKTREE") || return $?
  dev_config_validate "$config" || return $?
  DEV_OPEN_DIGEST=$(dev_config_digest "$config")

  record=$(dev_reconcile "$resolved" "$DEV_OPEN_DIGEST") || return $?
  dev_open_ensure "$config" "$record" || return $?

  if [[ "$no_attach" -eq 1 ]]; then
    printf '%s\n' "$DEV_OPEN_SESSION"
    return 0
  fi

  dev_open_attach "$DEV_OPEN_SESSION"
}
```

- [ ] **Step 4: Write `tools/dev/commands/attach.sh`**

```bash
# shellcheck shell=bash
# dev attach — attach only. Never creates, never repairs, takes no operation lock.

dev_cmd_attach() {
  local arg="${1:-}"
  if [[ $# -gt 1 || "$arg" == -* ]]; then
    printf 'usage: dev attach [<name>]\n' >&2
    return 2
  fi

  local resolved session worktree ws_id slug query live
  resolved=$(dev_resolve "$arg") || return $?
  ws_id=$(jq -r '.workspace_id' <<<"$resolved")
  slug=$(jq -r '.slug' <<<"$resolved")
  worktree=$(jq -r '.worktree' <<<"$resolved")
  # The record's name wins. A workspace the ADR-7 guard renamed keeps that name
  # for life; re-deriving the resolver's proposal here is what made such a
  # workspace unattachable once the session it originally collided with went
  # away — the plain name resolved to nothing while the hashed session ran on.
  session=$(dev_state_session_name "$ws_id" "$(jq -r '.session_name' <<<"$resolved")")

  query=$(dev_backend_query "$session")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    live=$(jq -r '.worktree // ""' <<<"$query")
    if [[ "$live" != "$worktree" ]]; then
      # Still reachable with no record: a first-ever `dev attach` against a name
      # another working tree already holds. Fall through to the hashed form.
      session="$slug--$(basename "$worktree")--${ws_id:0:6}"
      query=$(dev_backend_query "$session")
    fi
  fi

  if [[ "$(jq -r '.exists' <<<"$query")" != "true" ]]; then
    printf 'dev: no live session for %s; run `dev %s` to create it\n' "$session" "$slug" >&2
    return 4
  fi

  dev_open_attach "$session"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/dev_commands.bats`
Expected: PASS (all Task 12–14 cases, 0 failures)

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x -S warning -e SC1091 tools/dev/commands/open.sh tools/dev/commands/attach.sh
shfmt -d -i 2 -ci tools/dev/commands/open.sh tools/dev/commands/attach.sh
git add tools/dev/commands/open.sh tools/dev/commands/attach.sh tests/dev_commands.bats
git commit -m "feat(dev): add open and attach commands with the ADR-7 attach guard"
```

---

### Task 15: `commands/stop.sh`

**Files:**
- Create: `tools/dev/commands/stop.sh`
- Test: `tests/dev_commands.bats` (append)

**Interfaces:**
- Consumes: `dev_resolve <arg>`, `dev_config_merged`, `dev_config_digest`,
  `dev_reconcile <resolved_json> <config_digest>`, `dev_backend_query <session_name>`,
  `dev_backend_kill <session_name>`, `dev_now`, `dev_event_id_random`, `dev_event_build`,
  `dev_event_append`, `dev_open_session_index_path <session_name>` (Task 14)
- Produces: `dev_cmd_stop [<name>] [--container]`

**What `stop` is.** The only destructive verb in Phase 1, and it says so in its name — which is why
`restart` is deferred (§5.2): `stop` followed by `open` already is it. It takes the operation lock
`flock -n` and exits 7 rather than waiting, emits `workspace.stopped` with `reason: user`, kills the
session, and only with `--container` also stops the container. ADR-1 lists exactly three operation-lock
takers in Phase 1 — `open` (ensure), `stop`, and `dev-autostart.service` — and `stop` racing a
concurrent `open` (one tearing down the container the other is mid-way through starting) is one of the
two races the lock exists for.

Four ordering decisions, each with a reason:

*Remove the session index before killing.* Task 16's `session-closed` hook resolves its envelope
through `$DEV_STATE_ROOT/sessions/<session_name>.json`. Deleting it first means the hook that fires a
moment later finds nothing and exits silently, so a deliberate `stop` produces exactly one
`workspace.stopped` rather than the CLI's and the hook's. The CLI keeps the emit rather than delegating
to the hook, because a session created before the tmux config was installed has no hooks at all and
`stop` must still be correct there. This deletion is also what lets §4.4 keep two distinct reasons:
because the index is gone before the kill, `session-closed` only ever fires for a close the platform
did not perform, and can label itself accordingly (Task 16).

*Emit `workspace.stopped` only after the kill succeeds.* An earlier draft emitted first, reasoning that
the user's intent is known before the kill and would be lost if the kill failed. That trade is wrong:
the fold assigns `status=stopped` absolutely, so a failed kill would leave the record claiming the
workspace is stopped while the session is still running and still accepting input — and no later
reconcile repairs it, because reconcile treats a `stopped` record as terminal. A lost `reason` is
recoverable (the next reconcile sees the session gone and records `vanished`, which is at least true);
a false `stopped` is not. If the kill fails, `stop` restores the session index it removed, so the hook
is armed again for whenever the session does end, reports the failure, and exits non-zero.

*Reconcile again after a successful kill.* Without it `stop` would return leaving the record still
reading `running`, since the reconcile it ran up front happened before the kill. Anything that reads
`workspaces/*.json` directly — Task 19's fold-equivalence test, a future dashboard between commands —
would see a workspace the user has already stopped as live. The second reconcile takes no operation
lock (ADR-1) and runs after the lock is released.

*No container event.* Phase 1 has no `container.stopped` type (§4.4), and inventing one for a single
call site is the wrong trade. The next reconcile observes the container gone and emits `container.lost`,
which is the honest description of what a subsequent command finds.

`--container` stops the container recorded in the reconciled record by id. It deliberately does not run
`docker compose down`: the record's `container.id` is the container this workspace is bound to, and
tearing down a whole compose project on behalf of one workspace would reach past the workspace boundary.

- [ ] **Step 1: Write the failing test**

Append to `tests/dev_commands.bats`:

```bash
@test "stop ends the session and the next dev list reports stopped/user" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]

  run dev_tmux has-session -t '=demo'
  [ "$status" -ne 0 ]

  [ "$(dev_open_events 'select(.event == "workspace.stopped") | .data.reason')" = "user" ]

  # stop reconciles after the kill, so the record itself reads stopped without
  # waiting for the next command to project it.
  [ "$(jq -r '.status' "$(dev_state_path "$ws_id")")" = "stopped" ]

  run dev_cmd_list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .status' <<<"$output")" = "stopped" ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .stopped_reason' <<<"$output")" = "user" ]
  dev_tmux kill-server || true
}

@test "a kill that fails does not record the workspace as stopped" {
  # The ordering regression: emitting workspace.stopped before the kill left a
  # live session recorded as stopped, and reconcile treats stopped as terminal,
  # so nothing ever corrected it.
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  dev_backend_kill() { return 1; }

  run dev_cmd_stop demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"still running"* ]]

  # No event, so nothing to fold into a false stopped.
  [ -z "$(dev_open_events 'select(.event == "workspace.stopped") | .id')" ]

  # The session index is back, so the hook is still armed for the eventual close.
  [ -s "$(dev_open_session_index_path demo)" ]

  unset -f dev_backend_kill
  run dev_cmd_list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspaces[] | select(.session_name == "demo") | .status' <<<"$output")" = "running" ]
  dev_tmux kill-server || true
}

@test "stop without --container leaves the container alone; --container stops it" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id record
  dir=$(dev_open_fixture demo)
  mkdir -p "$dir/.devcontainer"
  printf '{"image":"alpine:3"}\n' >"$dir/.devcontainer/devcontainer.json"

  stub_command devcontainer '
if [ "$1" = "--version" ]; then echo 0.86.1; exit 0; fi
echo "{\"outcome\":\"success\",\"containerId\":\"cid1\",\"remoteUser\":\"vscode\",\"remoteWorkspaceFolder\":\"/workspace\"}"
'
  stub_command mise 'shift 2; shift; exec "$@"'
  stub_command docker '
if [ "$1" = "stop" ]; then echo "$2" >>"$TEST_ROOT/docker-stop"; exit 0; fi
if [ "$1" = "info" ]; then exit 0; fi
if [ "$1" = "inspect" ]; then echo true; exit 0; fi
if [ "$1" = "exec" ]; then shift; while [ "${1#-}" != "$1" ]; do shift 2; done; shift; exec "$@"; fi
exit 0
'

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/docker-stop" ]

  run dev_cmd_open demo
  [ "$status" -eq 0 ]
  run dev_cmd_stop demo --container
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/docker-stop")" = "cid1" ]
  dev_tmux kill-server || true
}

@test "stop exits 7 while the operation lock is held" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  local dir ws_id
  dir=$(dev_open_fixture demo)
  ws_id=$(dev_resolve_workspace_id "$dir")

  run dev_cmd_open demo
  [ "$status" -eq 0 ]

  flock -x "$DEV_STATE_ROOT/locks/$ws_id.op" sleep 5 &
  local holder=$!
  sleep 0.4

  run dev_cmd_stop demo
  [ "$status" -eq 7 ]
  [[ "$output" == *"another dev is working on this workspace"* ]]
  run dev_tmux has-session -t '=demo'
  [ "$status" -eq 0 ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  dev_tmux kill-server || true
}

@test "stop on an already-stopped workspace is a no-op exiting 0" {
  setup_dev_test
  dev_open_load_libs
  dev_open_stub_attach
  dev_open_fixture demo >/dev/null

  run dev_cmd_open demo
  [ "$status" -eq 0 ]
  run dev_cmd_stop demo
  [ "$status" -eq 0 ]

  run dev_cmd_stop demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already stopped"* ]]
  [ "$(dev_open_events 'select(.event == "workspace.stopped") | .id' | wc -l)" -eq 1 ]
  dev_tmux kill-server || true
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/dev_commands.bats`
Expected: FAIL — `dev_open_load_libs` cannot source `tools/dev/commands/stop.sh` ("No such file or
directory"), so every Task 15 case errors out.

- [ ] **Step 3: Write the implementation**

```bash
# shellcheck shell=bash
# dev stop — the only destructive verb in Phase 1.

dev_stop_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$DEV_STOP_WS_ID" "$DEV_STOP_SLUG" \
    "$DEV_STOP_SESSION" "$DEV_STOP_WORKTREE" "$data")
  dev_event_append "$line"
}

dev_stop_locked() {
  local record="$1" stop_container="$2"
  local query cid index saved

  query=$(dev_backend_query "$DEV_STOP_SESSION")
  if [[ "$(jq -r '.exists' <<<"$query")" == "true" ]]; then
    # Delete the hook's envelope lookup first, so the session-closed hook that
    # fires a moment from now exits silently and does not double-emit. Keep the
    # contents: if the kill fails there is no stop to suppress, and leaving the
    # index deleted would silently disarm the hook for the rest of the session's
    # life -- the eventual close would then be observed only by a later reconcile.
    index=$(dev_open_session_index_path "$DEV_STOP_SESSION")
    saved=$(cat "$index" 2>/dev/null || true)
    rm -f "$index"

    if ! dev_backend_kill "$DEV_STOP_SESSION"; then
      if [[ -n "$saved" ]]; then
        printf '%s\n' "$saved" >"$index"
      fi
      printf 'dev: could not end session %s; it is still running\n' "$DEV_STOP_SESSION" >&2
      return 1
    fi
    # Emitted only now. The fold assigns status=stopped absolutely and reconcile
    # treats a stopped record as terminal, so emitting before a kill that failed
    # would leave a live workspace permanently recorded as stopped.
    dev_stop_emit workspace.stopped '{"reason":"user"}'
  else
    printf 'dev: %s is already stopped\n' "$DEV_STOP_SESSION" >&2
  fi

  if [[ "$stop_container" -eq 1 ]]; then
    cid=$(jq -r '.container.id // ""' <<<"$record")
    if [[ -n "$cid" && "$cid" != "null" ]]; then
      if ! docker stop "$cid" >/dev/null 2>&1; then
        printf 'dev: could not stop container %s\n' "$cid" >&2
      fi
    else
      printf 'dev: %s has no container to stop\n' "$DEV_STOP_SESSION" >&2
    fi
  fi
}

dev_cmd_stop() {
  local arg="" stop_container=0 a
  for a in "$@"; do
    case "$a" in
      --container)
        stop_container=1
        ;;
      -*)
        printf 'usage: dev stop [<name>] [--container]\n' >&2
        return 2
        ;;
      *)
        if [[ -n "$arg" ]]; then
          printf 'usage: dev stop [<name>] [--container]\n' >&2
          return 2
        fi
        arg="$a"
        ;;
    esac
  done

  local resolved config digest record
  resolved=$(dev_resolve "$arg") || return $?

  DEV_STOP_WS_ID=$(jq -r '.workspace_id' <<<"$resolved")
  DEV_STOP_SLUG=$(jq -r '.slug' <<<"$resolved")
  DEV_STOP_WORKTREE=$(jq -r '.worktree' <<<"$resolved")
  DEV_STOP_SESSION=$(jq -r '.session_name' <<<"$resolved")

  config=$(dev_config_merged "$DEV_STOP_SLUG" "$DEV_STOP_WORKTREE") || return $?
  digest=$(dev_config_digest "$config")
  record=$(dev_reconcile "$resolved" "$digest") || return $?
  DEV_STOP_SESSION=$(jq -r '.session_name' <<<"$record")

  local lock rc=0
  lock="$DEV_STATE_ROOT/locks/$DEV_STOP_WS_ID.op"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  if ! flock -n 9; then
    exec 9>&-
    printf 'dev: another dev is working on this workspace (%s)\n' "$DEV_STOP_SESSION" >&2
    return 7
  fi
  dev_stop_locked "$record" "$stop_container" || rc=$?
  exec 9>&-
  # Project the record forward. The reconcile above ran before the kill, so
  # without this `stop` returns with the record still reading `running` and
  # anything reading state between commands sees a workspace the user has
  # already stopped as live. Reconcile takes no operation lock (ADR-1), so this
  # runs after the release.
  if [[ "$rc" -eq 0 ]]; then
    dev_reconcile "$resolved" "$digest" >/dev/null || true
  fi
  return "$rc"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/dev_commands.bats`
Expected: PASS (all Task 12–15 cases, 0 failures)

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x -S warning -e SC1091 tools/dev/commands/stop.sh
shfmt -d -i 2 -ci tools/dev/commands/stop.sh
git add tools/dev/commands/stop.sh tests/dev_commands.bats
git commit -m "feat(dev): add the stop command, the only destructive verb"
```

---

### Task 16: `dev.tmux.conf` + `dev-event` + the `tmux.conf.symlink` marker

**Files:**
- Create: `tools/dev/dev-event`
- Create: `tools/dev/dev.tmux.conf`
- Modify: `tools/tmux/tmux.conf.symlink`
- Test: `tests/dev_install.bats`

**Interfaces:**
- Consumes: `dev_now`, `dev_event_id_random`, `dev_event_build`, `dev_event_append` (Task 5);
  `dev_open_session_index_path <session_name>` is *not* consumed — `dev-event` reads the index file
  by path directly, so it depends on no command module
- Produces: `tools/dev/dev-event` (executable), `tools/dev/dev.tmux.conf`

**`dev-event` is deliberately tiny.** It takes the four envelope values (`workspace_id`, `slug`,
`session_name`, `worktree`) plus the event type and zero or more `key=value` pairs, and **exits
silently when `workspace_id` is empty**. That is exactly how ad-hoc sessions are filtered out: the
hooks are global, so they fire for every session on the server, and a log full of events about
sessions that were never workspaces is worse than no log. It appends one line via `dev_event_append`
and **touches no record**: it holds no state lock, and a lock-free read-modify-write of a JSON file
is precisely the corruption the rest of this design exists to avoid. Records transition on the next
reconcile.

**Data arrives as `key=value` pairs, never as a JSON literal.** An earlier draft had the tmux config
interpolate format expansions straight into a JSON string — `'{\"window\":\"#{window_name}\"}'`. tmux
does not escape anything for JSON, so a window name or client tty containing `"` or `\` produced a
malformed line, and `dev_events_read_all` skips lines that do not parse: the event would be lost with
no error anywhere. `dev-event` builds the object with `jq --arg` instead, which escapes correctly by
construction, and every value in §4.4's hook-emitted `data` is a string, so nothing is lost by the
restriction. It also removes three levels of backslash escaping from `dev.tmux.conf`, which was its
own hazard. Task 4's window-name charset rule (`[A-Za-z0-9._-]`) still stands as defence in depth —
these values are also shell words inside `run-shell`.

**Why there is a `--session` mode, and it is not optional.** Probed on tmux 3.4 rather than assumed:
at `session-closed` time the closing session's user options are already destroyed, so
`#{@dev_workspace_id}` expands to the empty string, and `#{session_name}` expands to whichever *other*
session tmux happens to be running the hook against — the wrong name, silently. `#{hook_session_name}`
is the only field that identifies the closed session. Registering the hook per-session with the values
baked in as literals does not work either: a session-scoped `session-closed` hook never fires, because
the session that owns the hook is gone before the hook would run. So `session-closed` passes
`--session "#{hook_session_name}"` and `dev-event` reads the envelope from
`$DEV_STATE_ROOT/sessions/<session_name>.json`, the index `open` wrote at creation time (Task 14) and
`stop` removes before killing (Task 15). Missing file means "not a workspace" and exits 0, which
preserves the ad-hoc filter exactly. The other three hooks fire while the session is alive and pass
the envelope directly, which was verified to work including a worktree path containing a space.

**`--session` deletes the index after emitting.** The session it describes no longer exists, so the
file is stale from that moment on. Leaving it is not inert: session names are reused (`demo` is
`demo` again on the next `dev open`), so a stale index left by an old incarnation can answer for a
new one — and worse, `dev open` writing a fresh index is what makes the deletion-before-kill in Task
15 meaningful. The unlink happens after the append, so a crash in between leaves a stale index rather
than a lost event, which is the right way round.

**`session-closed` reports `reason: "session_closed"`, not `"user"`.** `dev stop` removes the session
index *before* killing (Task 15), so this hook cannot fire for a stop the platform performed — by the
time it runs there is no index to resolve and it exits 0. Every close it does see is therefore one the
platform did not do: `tmux kill-session` by hand, the last pane exiting, `pkill tmux`. Labelling those
`user` — the reason `dev stop` writes — collapses a deliberate teardown and an unexplained
disappearance into one value, and a consumer asking "did I stop this or did it die?" cannot tell them
apart. This widens §4.4's `stopped_reason` enum from `user | vanished | host_restart` to
`user | session_closed | vanished | host_restart`; `session_closed` sits between the other two in
certainty — the close was observed as it happened (unlike `vanished`, which is inferred later) but was
not requested through the platform (unlike `user`).

**Quoting.** `run-shell` hands its string to `sh -c`, so every format expansion is individually
single-quoted inside the double-quoted tmux string. Without that, a worktree path containing a space
arrives as two arguments and the envelope silently shifts by one field.

**`session_name` for the live hooks comes from tmux's native `#{session_name}`,** not a fourth user
option: tmux knows the live name authoritatively and a stored copy would drift after a
`rename-session`, which a user may do by hand.

**`pane-died` is window-scoped.** It is registered with `set-hook -gw`, does **not** appear in
`show-hooks -g`, and is visible only under `show-hooks -gw` — a future `dev doctor` probing only the
global scope would report a working install as broken. It fires on **process exit** under
`remain-on-exit` and does **not** fire for `kill-pane`, so explicit destruction is a
reconcile-discovered case rather than a hook-reported one.

**`#{hook_client}` rather than `#{client_name}`.** Verified on tmux 3.4: in a `client-detached` hook
every `client_*` format expands empty, while `#{hook_client}` carries the client's tty on both attach
and detach. `data.client` is required for these two event types, so this is the difference between a
required field and an empty string.

- [ ] **Step 1: Write the failing `dev-event` tests**

Append to `tests/dev_install.bats`:

```bash
@test "dev-event with an empty workspace_id writes nothing and exits 0" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" "" slug sess /tmp/tree workspace.stopped reason=user
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}

@test "dev-event appends exactly one line carrying the whole envelope" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid1 myslug mysess /home/t/tree \
    workspace.attached client=/dev/pts/3
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]

  local line
  line=$(cat "$DEV_STATE_ROOT/events/events.jsonl")
  [ "$(jq -r '.v' <<<"$line")" = "1" ]
  [ "$(jq -r '.id' <<<"$line" | wc -c)" -eq 17 ]
  [ "$(jq -r '.ts' <<<"$line")" != "null" ]
  [ "$(jq -r '.event' <<<"$line")" = "workspace.attached" ]
  [ "$(jq -r '.workspace_id' <<<"$line")" = "wsid1" ]
  [ "$(jq -r '.slug' <<<"$line")" = "myslug" ]
  [ "$(jq -r '.session_name' <<<"$line")" = "mysess" ]
  [ "$(jq -r '.worktree' <<<"$line")" = "/home/t/tree" ]
  [ "$(jq -r '.data.client' <<<"$line")" = "/dev/pts/3" ]
}

@test "dev-event emits {} when no key=value pairs are given" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid1 slug sess /tmp/tree workspace.detached
  [ "$status" -eq 0 ]
  [ "$(jq -c '.data' "$DEV_STATE_ROOT/events/events.jsonl")" = "{}" ]
}

@test "dev-event keeps a worktree path containing a space as one field" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid2 slug sess "/home/t/my tree" pane.died window=shell
  [ "$status" -eq 0 ]
  [ "$(jq -r '.worktree' "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/my tree" ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = "shell" ]
}

@test "dev-event escapes quotes and backslashes in a value instead of corrupting the line" {
  # The regression this pins: the hooks used to interpolate tmux formats into a
  # JSON literal, so a value containing " or \ produced a line that would not
  # parse -- and dev_events_read_all silently skips unparseable lines, so the
  # event vanished with no error anywhere. jq --arg escapes by construction.
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid4 slug sess /tmp/tree pane.died \
    'window=od"d\name'
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
  run jq -e . "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = 'od"d\name' ]
}

@test "dev-event keeps the whole remainder of a pair, equals signs and all" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid5 slug sess /tmp/tree pane.died \
    'window=a=b=c'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.window' "$DEV_STATE_ROOT/events/events.jsonl")" = "a=b=c" ]
}

@test "dev-event rejects an argument that is not a key=value pair" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" wsid6 slug sess /tmp/tree pane.died notapair
  [ "$status" -eq 2 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}

@test "dev-event --session resolves the envelope from the session index" {
  setup_dev_test
  mkdir -p "$DEV_STATE_ROOT/sessions"
  jq -n '{workspace_id:"wsid3", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.workspace_id' "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid3" ]
  [ "$(jq -r '.slug' "$DEV_STATE_ROOT/events/events.jsonl")" = "demo" ]
  [ "$(jq -r '.worktree' "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/demo" ]
  [ "$(jq -r '.data.reason' "$DEV_STATE_ROOT/events/events.jsonl")" = "session_closed" ]
}

@test "dev-event --session removes the index it just consumed" {
  # The session is gone, so the index is stale from this moment on -- and names
  # are reused, so a leftover index would answer for the NEXT incarnation of
  # `demo`. Deleting after the append keeps a crash in between on the safe side:
  # a stale index rather than a lost event.
  setup_dev_test
  mkdir -p "$DEV_STATE_ROOT/sessions"
  jq -n '{workspace_id:"wsid7", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ ! -e "$DEV_STATE_ROOT/sessions/demo.json" ]

  # A second close on the same name is now a no-op rather than a duplicate event.
  run "$REPO_ROOT/tools/dev/dev-event" --session demo workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$DEV_STATE_ROOT/events/events.jsonl")" -eq 1 ]
}

@test "dev-event --session on an unknown session writes nothing and exits 0" {
  setup_dev_test
  run "$REPO_ROOT/tools/dev/dev-event" --session adhoc workspace.stopped reason=session_closed
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_STATE_ROOT/events/events.jsonl" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dev_install.bats`
Expected: FAIL with "No such file or directory" for `tools/dev/dev-event`.

- [ ] **Step 3: Write `tools/dev/dev-event`**

```bash
#!/usr/bin/env bash
set -euo pipefail

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_STATE_ROOT="${DEV_STATE_ROOT:-$HOME/.local/state/dev}"
export DEV_DOTFILES_ROOT DEV_STATE_ROOT

# shellcheck source=tools/dev/lib/events.sh
source "$DEV_DOTFILES_ROOT/tools/dev/lib/events.sh"

usage() {
  printf 'usage: dev-event <workspace_id> <slug> <session_name> <worktree> <event> [<key>=<value> ...]\n' >&2
  printf '       dev-event --session <session_name> <event> [<key>=<value> ...]\n' >&2
  exit 2
}

# Builds the event `data` object from key=value arguments. Every value is a
# string, which covers every field §4.4 gives a hook-emitted event. jq --arg does
# the escaping, so a window name or client tty containing " or \ produces valid
# JSON instead of a line that dev_events_read_all would silently skip.
dev_event_data_from_pairs() {
  local pair key value out='{}'
  for pair in "$@"; do
    if [[ "$pair" != *=* ]]; then
      printf 'dev-event: not a key=value pair: %s\n' "$pair" >&2
      exit 2
    fi
    key="${pair%%=*}"
    # Longest-prefix removal on the key, shortest on the value: `a=b=c` is the
    # key `a` with the value `b=c`, not a truncated `b`.
    value="${pair#*=}"
    out=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$out")
  done
  printf '%s\n' "$out"
}

main() {
  local workspace_id slug session_name worktree event data index

  if [[ "${1:-}" == "--session" ]]; then
    [[ $# -ge 3 ]] || usage
    session_name="$2"
    event="$3"
    shift 3
    index="$DEV_STATE_ROOT/sessions/$session_name.json"
    # No index means this session was never a workspace, or its index was already
    # consumed by an earlier close. Ad-hoc sessions are filtered here exactly as
    # an empty workspace_id filters them below.
    [[ -f "$index" ]] || exit 0
    workspace_id=$(jq -r '.workspace_id // ""' "$index")
    slug=$(jq -r '.slug // ""' "$index")
    worktree=$(jq -r '.worktree // ""' "$index")
  else
    [[ $# -ge 5 ]] || usage
    workspace_id="$1"
    slug="$2"
    session_name="$3"
    worktree="$4"
    event="$5"
    shift 5
    index=""
  fi

  data=$(dev_event_data_from_pairs "$@")

  # Global hooks fire for every session on the server. Anything without an id is
  # not a workspace, and the log must not fill with noise about it.
  [[ -n "$workspace_id" ]] || exit 0

  mkdir -p "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks"

  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$workspace_id" "$slug" "$session_name" \
    "$worktree" "$data")
  dev_event_append "$line"

  # The session this index described is gone, and session names get reused, so a
  # leftover index would answer for the next incarnation. Unlink after the
  # append: a crash in between leaves a stale index, not a lost event.
  [[ -z "$index" ]] || rm -f "$index"
}

main "$@"
```

Make it executable: `chmod +x tools/dev/dev-event`.

Note on the `exit 2` inside `dev_event_data_from_pairs`: it runs inside a command substitution, so it
ends that subshell rather than the script — but `set -e` then fails the `data=$(...)` assignment and
the script exits 2 anyway, which is what the malformed-pair test asserts. Written as `exit` rather
than `return` deliberately: a `return 2` would need an explicit check at every call site, and there
would eventually be one that forgot.

- [ ] **Step 4: Run the `dev-event` tests to verify they pass**

Run: `bats tests/dev_install.bats`
Expected: PASS for the ten `dev-event` cases.

- [ ] **Step 5: Write the failing tmux hook tests**

Append to `tests/dev_install.bats`:

```bash
dev_hook_env() {
  # dev.tmux.conf reaches dev-event through ~/.dotfiles, and the tmux server
  # inherits DEV_STATE_ROOT from the shell that starts it.
  ln -sfn "$REPO_ROOT" "$HOME/.dotfiles"
  mkdir -p "$DEV_STATE_ROOT/sessions"
}

@test "session-closed emits workspace.stopped through the session index" {
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  jq -n '{workspace_id:"wsid9", slug:"demo", session_name:"demo", worktree:"/home/t/demo"}' \
    >"$DEV_STATE_ROOT/sessions/demo.json"

  dev_tmux new-session -d -s demo
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"
  dev_tmux kill-session -t '=demo'
  sleep 0.8

  [ "$(jq -r 'select(.event == "workspace.stopped") | .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid9" ]
  [ "$(jq -r 'select(.event == "workspace.stopped") | .session_name' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "demo" ]
  # Not "user": `dev stop` removes the index before killing, so a close this hook
  # observes is by construction one the platform did not perform.
  [ "$(jq -r 'select(.event == "workspace.stopped") | .data.reason' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "session_closed" ]
  [ ! -e "$DEV_STATE_ROOT/sessions/demo.json" ]
  dev_tmux kill-server || true
}

@test "a window name with a double quote still produces a parseable pane.died" {
  # End-to-end for the escaping fix: tmux interpolates the raw name into the
  # argument, and dev-event -- not the tmux config -- turns it into JSON.
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  dev_tmux new-session -d -s holder
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"

  dev_tmux new-session -d -s quoted
  dev_tmux set-option -t '=quoted:' @dev_workspace_id wsidq
  dev_tmux set-option -t '=quoted:' @dev_slug quoted
  dev_tmux set-option -t '=quoted:' @dev_worktree /home/t/quoted

  # Task 4 constrains names the platform CREATES; tmux itself does not, and a
  # hand-renamed window must not be able to corrupt the log.
  dev_tmux new-window -t '=quoted' -n 'we"ird' 'sleep 0.4; exit 3'
  dev_tmux set-window-option -t '=quoted:' remain-on-exit on
  sleep 1.2

  run jq -e . "$DEV_STATE_ROOT/events/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.event == "pane.died") | .data.window' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = 'we"ird' ]
  dev_tmux kill-server || true
}

@test "pane-died emits pane.died with the envelope from the session user options" {
  setup_dev_test
  dev_hook_env
  source "$REPO_ROOT/tools/dev/lib/backend-tmux.sh"

  dev_tmux new-session -d -s holder
  dev_tmux source-file "$REPO_ROOT/tools/dev/dev.tmux.conf"

  # pane-died is window-scoped: absent from -g, present under -gw.
  run dev_tmux show-hooks -g
  [[ "$output" != *pane-died* ]]
  run dev_tmux show-hooks -gw
  [[ "$output" == *pane-died* ]]

  dev_tmux new-session -d -s demo
  dev_tmux set-option -t '=demo:' @dev_workspace_id wsid8
  dev_tmux set-option -t '=demo:' @dev_slug demo
  dev_tmux set-option -t '=demo:' @dev_worktree '/home/t/my demo'

  # The spec warns that an immediate `exit 3` races remain-on-exit being set.
  dev_tmux new-window -t '=demo' -n shell 'sleep 0.4; exit 3'
  dev_tmux set-window-option -t '=demo:=shell' remain-on-exit on
  sleep 1.2

  [ "$(jq -r 'select(.event == "pane.died") | .workspace_id' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "wsid8" ]
  [ "$(jq -r 'select(.event == "pane.died") | .worktree' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "/home/t/my demo" ]
  [ "$(jq -r 'select(.event == "pane.died") | .data.window' \
    "$DEV_STATE_ROOT/events/events.jsonl")" = "shell" ]
  dev_tmux kill-server || true
}

@test "tmux.conf.symlink sources dev.tmux.conf between idempotency markers" {
  setup_dotfiles_test
  run grep -c '# dev-workspace-config-start' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
  run grep -c '# dev-workspace-config-end' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
  run grep -c 'tools/dev/dev.tmux.conf' "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  [ "$output" = "1" ]
}
```

- [ ] **Step 6: Run the tmux hook tests to verify they fail**

Run: `bats tests/dev_install.bats`
Expected: FAIL with `no such file: .../tools/dev/dev.tmux.conf` from `source-file`, and the marker
test failing with `output = 0`.

- [ ] **Step 7: Write `tools/dev/dev.tmux.conf`**

```tmux
# dev workspace platform — event hooks.
#
# Hooks append events; only reconcile writes records (ADR-1). dev-event exits
# silently when the workspace id is empty, which is how ad-hoc sessions are
# filtered: these hooks are global and fire for every session on the server.
#
# Every format expansion is individually single-quoted so that a worktree path
# containing a space arrives as ONE argument. run-shell hands the string to sh.
#
# Event data is passed as key=value ARGUMENTS, never as a JSON literal. tmux does
# not escape for JSON, so interpolating #{window_name} or #{hook_client} into
# '{"window":"..."}' produced an unparseable line for any value containing " or
# \ -- and unparseable lines are skipped silently by the reader. dev-event builds
# the object with jq --arg instead.
#
# session-closed cannot carry the envelope: on tmux 3.4 the closing session's
# user options are already gone and #{session_name} names a different session.
# #{hook_session_name} is the only usable identity, so it resolves through the
# session index that `dev open` wrote. `dev stop` deletes that index BEFORE
# killing, so every close this hook actually sees is one the platform did not
# perform -- hence reason=session_closed rather than `dev stop`'s reason=user.

set-hook -g session-closed "run-shell -b \"~/.dotfiles/tools/dev/dev-event --session '#{hook_session_name}' workspace.stopped reason=session_closed\""

set-hook -g client-attached "run-shell -b \"~/.dotfiles/tools/dev/dev-event '#{@dev_workspace_id}' '#{@dev_slug}' '#{session_name}' '#{@dev_worktree}' workspace.attached 'client=#{hook_client}'\""

set-hook -g client-detached "run-shell -b \"~/.dotfiles/tools/dev/dev-event '#{@dev_workspace_id}' '#{@dev_slug}' '#{session_name}' '#{@dev_worktree}' workspace.detached 'client=#{hook_client}'\""

# pane-died is WINDOW-scoped: registered with -gw, absent from `show-hooks -g`,
# visible only under `show-hooks -gw`. It fires on process exit under
# remain-on-exit and does NOT fire for kill-pane.
set-hook -gw pane-died "run-shell -b \"~/.dotfiles/tools/dev/dev-event '#{@dev_workspace_id}' '#{@dev_slug}' '#{session_name}' '#{@dev_worktree}' pane.died 'window=#{window_name}'\""
```

- [ ] **Step 8: Add the marker block to `tools/tmux/tmux.conf.symlink`**

Append after the existing `# claude-code-agent-teams-config-end` line, copying that block's shape.
It is committed, not injected at install.

```tmux
# dev-workspace-config-start
# Event hooks for the dev workspace platform (tools/dev).
if-shell '[ -x ~/.dotfiles/tools/dev/dev-event ]' \
    'source-file ~/.dotfiles/tools/dev/dev.tmux.conf'
# dev-workspace-config-end
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bats tests/dev_install.bats`
Expected: PASS (14 tests, 0 failures)

- [ ] **Step 10: Lint and commit**

```bash
shellcheck -x -S warning -e SC1091 tools/dev/dev-event
shfmt -d -i 2 -ci tools/dev/dev-event
git add tools/dev/dev-event tools/dev/dev.tmux.conf tools/tmux/tmux.conf.symlink tests/dev_install.bats
git commit -m "feat(dev): add tmux event hooks and the dev-event emitter"
```
### Task 17: Autostart unit, installer, and gitignore

ADR-5 draws a hard line: the tmux server is what survives a disconnect, and **containers only** are
what survive a reboot. `dev-autostart` therefore runs `devcontainer up` and nothing else — no tmux
session, no layout, no startup commands. Re-running declared startup commands with no human present
is a correctness question the schema cannot express, so it is not attempted.

Two rules turn `autostart: true` into an actual set, because the flag lives in `workspace.yaml`,
which is keyed by slug and inherited by every working tree of the project (ADR-7):

1. **Primary working trees only.** A linked worktree is skipped (`dev_resolve_is_primary`). Worktrees
   are short-lived and the container they need is the one the user is about to open by hand anyway.
   This keeps the inherited flag meaningful — it says "this *project's* container should be warm at
   boot," which is what someone setting it actually means.
2. **Discovery is from existing records, never from a filesystem scan.** The unit enumerates
   `$DEV_STATE_ROOT/workspaces/*.json` via `dev_state_list` and never walks `DEV_REPO_ROOT`. The
   consequence is deliberate: a repository that has never been opened has no record and is therefore
   never autostarted, so enabling the flag in a shared overlay cannot make a machine start building
   containers for projects its owner has not touched.

Each autostart is a workspace-mutating operation, so it takes the operation lock `flock -n` and skips
any workspace already held — a user who logs in and runs `dev` during boot must not race the unit.

Two facts about the unit environment shape the template. A user unit cannot order itself `After=` a
system service, so Docker readiness is a bounded `ExecStartPre` poll rather than a dependency
(`ai/vekil/vekil.service` sets this precedent). And mise, its shims, and `~/.local/bin` are absent
from a unit's default environment, so `PATH` is set explicitly — without it
`dev_runtime_devcontainer_cli` cannot find the absolute `mise` binary and the unit fails in a way
that gets misattributed to Docker.

`install.sh` deliberately does **not** symlink `bin/dev`: `~/.dotfiles/bin` is already first on
`PATH` via `core/path.zsh`, so the dispatcher is callable as installed. This supersedes the spec's
§3 note that install.sh symlinks it. It is also not under `ai/*/install.sh`, so `setup_ai`'s loop in
`bin/install` will not pick it up; it gets its own `run_phase optional dev` step.

**Files:**
- Create: `tools/dev/dev-autostart`
- Create: `tools/dev/dev-autostart.service`
- Create: `tools/dev/install.sh`
- Modify: `bin/install`
- Modify: `.gitignore`
- Test: `tests/dev_install.bats` (appended to the file Task 16 creates)

**Interfaces:**
- Consumes: `dev_resolve_is_primary <path>`, `dev_config_merged <slug> <worktree>`,
  `dev_state_list`, `dev_runtime_docker_ok`, `dev_runtime_devcontainer_cli`,
  `dev_container_enabled <config_json> <worktree>`, `dev_container_up <worktree> <config_json>`,
  `run_phase`, `log_info`, `log_warning` (from `bin/common.sh` / `bin/log-helper`), and the
  committed tmux marker block from Task 16.
- Produces: `tools/dev/dev-autostart` (executable, no arguments) and `tools/dev/install.sh`
  (executable, no arguments), both invoked by later steps and by `bin/install`.

- [ ] **Step 1: Write the failing tests for the installer**

Append to `tests/dev_install.bats`:

```bash
@test "install.sh writes the autostart unit with DOTFILES_ROOT substituted" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]

  local unit="$XDG_CONFIG_HOME/systemd/user/dev-autostart.service"
  [ -f "$unit" ]
  run grep -c "@DOTFILES_ROOT@" "$unit"
  [ "$status" -ne 0 ]
  grep -qF "ExecStart=$REPO_ROOT/tools/dev/dev-autostart" "$unit"
  grep -q "^Type=oneshot$" "$unit"
  grep -q "^WantedBy=default.target$" "$unit"
  grep -q "^Environment=PATH=" "$unit"
  grep -q "^ExecStartPre=" "$unit"
}

@test "install.sh creates the state directories" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1
  export DEV_STATE_ROOT="$TEST_ROOT/fresh-state"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  [ -d "$DEV_STATE_ROOT/workspaces" ]
  [ -d "$DEV_STATE_ROOT/events" ]
  [ -d "$DEV_STATE_ROOT/locks" ]
}

@test "install.sh is idempotent" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  local unit="$XDG_CONFIG_HOME/systemd/user/dev-autostart.service"
  cp "$unit" "$TEST_ROOT/unit.first"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  cmp "$TEST_ROOT/unit.first" "$unit"
  # No stray staging files left behind.
  run bash -c "ls -A '$XDG_CONFIG_HOME/systemd/user' | grep -c '^\\.'"
  [ "$output" = "0" ]
}

@test "install.sh verifies the committed tmux marker block" {
  setup_dev_test
  export XDG_CONFIG_HOME="$TEST_ROOT/config"
  export DEV_SKIP_SERVICE=1

  grep -qF "# dev-workspace-config-start" "$REPO_ROOT/tools/tmux/tmux.conf.symlink"
  grep -qF "# dev-workspace-config-end" "$REPO_ROOT/tools/tmux/tmux.conf.symlink"

  run bash "$REPO_ROOT/tools/dev/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tmux marker block"* ]]
}

@test "workspace.local.yaml is gitignored" {
  run git -C "$REPO_ROOT" check-ignore projects/x/workspace.local.yaml
  [ "$status" -eq 0 ]
  [ "$output" = "projects/x/workspace.local.yaml" ]
}
```

- [ ] **Step 2: Write the failing tests for `dev-autostart`**

Append to `tests/dev_install.bats`. The helper builds a record plus overlay config for one repo; each
test then asserts which of them `dev-autostart` acted on by counting lines in a marker file.

```bash
# Creates a git repo under DEV_REPO_ROOT, an overlay workspace.yaml, and a
# workspace record. Echoes the workspace_id.
dev_autostart_fixture() {
  local slug="$1" autostart="$2"
  local worktree="$DEV_REPO_ROOT/$slug"
  mkdir -p "$worktree/.devcontainer"
  printf '%s\n' '{"image":"alpine"}' >"$worktree/.devcontainer/devcontainer.json"
  git -C "$worktree" init -q
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  mkdir -p "$DEV_OVERLAY_ROOT/$slug"
  printf 'autostart: %s\n' "$autostart" >"$DEV_OVERLAY_ROOT/$slug/workspace.yaml"

  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  local id
  id=$(dev_resolve_workspace_id "$worktree")
  dev_state_new "$id" "$slug" "$slug" "$worktree" >"$DEV_STATE_ROOT/workspaces/$id.json"
  printf '%s\n' "$id"
}

# Stubs docker/mise/devcontainer so `devcontainer up` appends one line to
# $DEV_UP_MARKER and reports a plausible container.
dev_autostart_stubs() {
  export DEV_UP_MARKER="$TEST_ROOT/up.log"
  : >"$DEV_UP_MARKER"
  stub_command docker 'exit 0'
  stub_command mise 'if [[ "${1:-}" == "exec" ]]; then
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  exec "$@"
fi
exit 0'
  stub_command devcontainer 'case "${1:-}" in
  --version)
    echo "0.86.1"
    ;;
  up)
    printf "up\n" >>"$DEV_UP_MARKER"
    printf "%s\n" "{\"outcome\":\"success\",\"containerId\":\"cid-abc\",\"remoteUser\":\"node\",\"remoteWorkspaceFolder\":\"/workspaces/app\"}"
    ;;
  *)
    exit 0
    ;;
esac'
}

@test "dev-autostart runs devcontainer up exactly once for an eligible workspace" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  run wc -l <"$DEV_UP_MARKER"
  [ "$(tr -d ' ' <<<"$output")" = "1" ]
}

@test "dev-autostart skips a workspace without autostart" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app false >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
}

@test "dev-autostart skips a linked worktree" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null
  rm -f "$DEV_STATE_ROOT"/workspaces/*.json

  local linked="$DEV_REPO_ROOT/app-pr5"
  git -C "$DEV_REPO_ROOT/app" worktree add -q -b pr5 "$linked"
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  local id
  id=$(dev_resolve_workspace_id "$linked")
  dev_state_new "$id" app "app--app-pr5" "$linked" >"$DEV_STATE_ROOT/workspaces/$id.json"

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"linked worktree"* ]]
}

@test "dev-autostart skips a record whose worktree is gone" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null
  rm -rf "$DEV_REPO_ROOT/app"

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"worktree is gone"* ]]
}

@test "dev-autostart skips a workspace whose operation lock is held" {
  setup_dev_test
  dev_autostart_stubs
  local id
  id=$(dev_autostart_fixture app true)

  local op_lock="$DEV_STATE_ROOT/locks/$id.op"
  : >"$op_lock"
  flock "$op_lock" sleep 30 &
  local holder=$!
  # Wait until the background flock genuinely owns the lock.
  local i
  for i in $(seq 1 50); do
    flock -n "$op_lock" true || break
    sleep 0.1
  done

  run "$REPO_ROOT/tools/dev/dev-autostart"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [ ! -s "$DEV_UP_MARKER" ]
  [[ "$output" == *"operation lock held"* ]]
}

@test "dev-autostart creates no tmux session" {
  setup_dev_test
  dev_autostart_stubs
  dev_autostart_fixture app true >/dev/null

  run "$REPO_ROOT/tools/dev/dev-autostart"
  [ "$status" -eq 0 ]
  [ -s "$DEV_UP_MARKER" ]

  # The real test socket must have no server at all: autostart starts containers,
  # not sessions (ADR-5).
  run tmux -L "$DEV_TMUX_SOCKET" list-sessions
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/dev_install.bats`
Expected: FAIL with `no such file or directory` for `tools/dev/install.sh` and
`tools/dev/dev-autostart`, and the gitignore test failing with an empty `check-ignore` result.

- [ ] **Step 4: Write `tools/dev/dev-autostart`**

```bash
#!/usr/bin/env bash
# dev-autostart -- start containers for opted-in workspaces at boot (ADR-5).
#
# Runs `devcontainer up` and nothing else: no tmux session, no layout, no
# startup commands. Discovery is from existing records only, never a scan of
# DEV_REPO_ROOT, so a repository that has never been opened is never started.

set -euo pipefail

DEV_DOTFILES_ROOT="${DEV_DOTFILES_ROOT:-$HOME/.dotfiles}"
DEV_STATE_ROOT="${DEV_STATE_ROOT:-$HOME/.local/state/dev}"
DEV_REPO_ROOT="${DEV_REPO_ROOT:-$HOME/workspace}"
DEV_OVERLAY_ROOT="${DEV_OVERLAY_ROOT:-$DEV_DOTFILES_ROOT/projects}"
DEV_TMUX_SOCKET="${DEV_TMUX_SOCKET:-}"
export DEV_DOTFILES_ROOT DEV_STATE_ROOT DEV_REPO_ROOT DEV_OVERLAY_ROOT DEV_TMUX_SOCKET

DEV_LIB="$DEV_DOTFILES_ROOT/tools/dev/lib"
# shellcheck source=tools/dev/lib/resolve.sh
source "$DEV_LIB/resolve.sh"
# shellcheck source=tools/dev/lib/config.sh
source "$DEV_LIB/config.sh"
# shellcheck source=tools/dev/lib/state.sh
source "$DEV_LIB/state.sh"
# shellcheck source=tools/dev/lib/runtime.sh
source "$DEV_LIB/runtime.sh"
# shellcheck source=tools/dev/lib/container.sh
source "$DEV_LIB/container.sh"

autostart_log() {
  printf 'dev-autostart: %s\n' "$*" >&2
}

# Applies the two ADR-5 eligibility rules to one record, then starts its
# container under the operation lock.
autostart_one() {
  local record="$1"
  local workspace_id slug worktree config

  workspace_id=$(jq -r '.workspace_id // empty' <<<"$record")
  slug=$(jq -r '.slug // empty' <<<"$record")
  worktree=$(jq -r '.worktree // empty' <<<"$record")
  [[ -n "$workspace_id" && -n "$slug" && -n "$worktree" ]] || {
    autostart_log "skip: record is missing identity fields"
    return 0
  }

  if [[ ! -d "$worktree" ]]; then
    autostart_log "skip $slug: worktree is gone ($worktree)"
    return 0
  fi
  if ! dev_resolve_is_primary "$worktree"; then
    autostart_log "skip $slug: linked worktree"
    return 0
  fi

  if ! config=$(dev_config_merged "$slug" "$worktree"); then
    autostart_log "skip $slug: merged config is unreadable"
    return 0
  fi
  [[ "$(jq -r '.autostart // false' <<<"$config")" == "true" ]] || return 0

  if ! dev_container_enabled "$config" "$worktree"; then
    autostart_log "skip $slug: no devcontainer applies"
    return 0
  fi

  # Subshell so fd 9 and the lock are released the moment this workspace is done.
  (
    exec 9>"$DEV_STATE_ROOT/locks/$workspace_id.op"
    if ! flock -n 9; then
      autostart_log "skip $slug: operation lock held by another dev"
      exit 0
    fi
    autostart_log "starting container for $slug"
    if ! dev_container_up "$worktree" "$config" >/dev/null; then
      autostart_log "$slug: devcontainer up failed"
    fi
  )
}

main() {
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks" "$DEV_STATE_ROOT/sessions"

  if ! dev_runtime_docker_ok; then
    autostart_log "docker daemon unavailable; nothing started"
    return 0
  fi
  if ! dev_runtime_devcontainer_cli >/dev/null; then
    autostart_log "devcontainer CLI absent or unrunnable; nothing started"
    return 0
  fi

  local record_path record
  while IFS= read -r record_path; do
    [[ -n "$record_path" && -f "$record_path" ]] || continue
    record=$(cat "$record_path")
    if ! jq -e . >/dev/null 2>&1 <<<"$record"; then
      autostart_log "skip $record_path: unreadable record"
      continue
    fi
    autostart_one "$record"
  done < <(dev_state_list)
}

main "$@"
```

- [ ] **Step 5: Write `tools/dev/dev-autostart.service`**

```ini
[Unit]
Description=Start opted-in dev workspace containers
Documentation=file://@DOTFILES_ROOT@/docs/superpowers/specs/2026-08-03-dev-workspace-platform-design.md
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes

# A unit's default environment has neither mise nor its shims on PATH, and
# dev-autostart resolves the devcontainer CLI through an absolute mise binary.
# Without this the unit fails in a way that gets misattributed to Docker.
Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin

# Docker runs as a system service, so a user unit cannot order itself After= it.
# Poll for the daemon instead, bounded, then run anyway -- dev-autostart reports
# an unavailable daemon and exits 0 rather than failing the unit.
ExecStartPre=/usr/bin/env bash -c 'for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'

ExecStart=@DOTFILES_ROOT@/tools/dev/dev-autostart

# Cold devcontainer builds are slow; several in sequence are slower still.
TimeoutStartSec=1800

[Install]
WantedBy=default.target
```

- [ ] **Step 6: Write `tools/dev/install.sh`**

```bash
#!/usr/bin/env bash
# tools/dev/install.sh -- state directories, the dev-autostart user unit, and a
# check that the committed tmux marker block is in place.
#
# bin/dev is deliberately NOT symlinked: ~/.dotfiles/bin is already first on
# PATH via core/path.zsh, so the dispatcher is callable as installed.

set -euo pipefail

# shellcheck source=bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEV_STATE_ROOT="${DEV_STATE_ROOT:-$HOME/.local/state/dev}"
SERVICE_TEMPLATE="$DOTFILES_ROOT/tools/dev/dev-autostart.service"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_UNIT="$SYSTEMD_USER_DIR/dev-autostart.service"
TMUX_CONF="$DOTFILES_ROOT/tools/tmux/tmux.conf.symlink"
MARKER_START="# dev-workspace-config-start"
MARKER_END="# dev-workspace-config-end"

create_state_dirs() {
  mkdir -p "$DEV_STATE_ROOT/workspaces" "$DEV_STATE_ROOT/events" "$DEV_STATE_ROOT/locks" "$DEV_STATE_ROOT/sessions"
  chmod 0700 "$DEV_STATE_ROOT"
}

# `systemctl --user` always acts on the invoking user's real manager, ignoring
# HOME. Writing the unit into XDG_CONFIG_HOME is harmless in a sandbox, but
# reloading and enabling would mutate state outside it -- so gate only those.
systemd_user_available() {
  [[ "$(uname -s)" == "Linux" ]] || return 1
  [[ "${DEV_SKIP_SERVICE:-0}" != "1" ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  local real_home
  real_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [[ -n "$real_home" && "$HOME" == "$real_home" ]] || return 1
  # A user manager only exists for a real login session (absent in containers,
  # SSH ForceCommand, and CI).
  systemctl --user show-environment >/dev/null 2>&1 || return 1
  [[ -f "$SERVICE_TEMPLATE" && ! -L "$SERVICE_TEMPLATE" ]] || return 1
}

# Generated from the repo template so DOTFILES_ROOT is baked in and the unit
# stays a regular file -- systemd does not follow unit symlinks predictably.
install_service_unit() {
  mkdir -p "$SYSTEMD_USER_DIR"

  local staged escaped_root
  staged=$(mktemp "$SYSTEMD_USER_DIR/.dev-autostart.service.XXXXXX")
  # Escape the replacement so a repo path containing sed metacharacters (\, &,
  # or the | delimiter) is substituted literally instead of corrupting the unit.
  escaped_root=${DOTFILES_ROOT//\\/\\\\}
  escaped_root=${escaped_root//|/\\|}
  escaped_root=${escaped_root//&/\\&}
  sed "s|@DOTFILES_ROOT@|$escaped_root|g" "$SERVICE_TEMPLATE" >"$staged"
  chmod 0644 "$staged"

  if [[ -f "$SERVICE_UNIT" ]] && cmp -s "$staged" "$SERVICE_UNIT"; then
    rm -f "$staged"
  else
    command mv -f "$staged" "$SERVICE_UNIT"
    log_info "Installed dev-autostart user service at $SERVICE_UNIT."
  fi

  if ! systemd_user_available; then
    log_info "No systemd user manager available; unit written but not enabled."
    return 0
  fi
  systemctl --user daemon-reload
  systemctl --user enable dev-autostart.service >/dev/null
}

# The marker block is committed to tmux.conf.symlink (Task 16), not injected
# here. Verify rather than write, so a lost block is reported instead of
# silently re-added on top of a hand edit.
verify_tmux_marker() {
  if grep -qF "$MARKER_START" "$TMUX_CONF" && grep -qF "$MARKER_END" "$TMUX_CONF"; then
    return 0
  fi
  log_warning "tmux marker block missing from $TMUX_CONF; dev hooks will not load."
  return 1
}

main() {
  create_state_dirs
  install_service_unit
  verify_tmux_marker
}

main "$@"
```

- [ ] **Step 7: Wire it into `bin/install`**

In `main()`, add a step of its own — `tools/dev/install.sh` is not under `ai/*/install.sh`, so the
`setup_ai` loop does not pick it up. Insert after the `work` phase and before `setup_ai`:

```bash
  run_phase optional work setup_work
  run_phase optional dev bash "$DOTFILES_ROOT/tools/dev/install.sh"
  setup_ai
```

- [ ] **Step 8: Add the local overlay to `.gitignore`**

Append after the existing `projects/*/.claude/settings.local.json` line, matching its comment style:

```gitignore
# Machine-local workspace overrides for the dev platform (host paths, env, and
# anything that must not follow the repo to another machine).
projects/*/workspace.local.yaml
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bats tests/dev_install.bats`
Expected: PASS (all tests, 0 failures)

- [ ] **Step 10: Commit**

```bash
git add tools/dev/dev-autostart tools/dev/dev-autostart.service tools/dev/install.sh \
  bin/install .gitignore tests/dev_install.bats
git commit -m "feat(dev): add opt-in autostart user unit and dev installer"
```

---

### Task 18: Remove the tmux-install block from `bin/claude-devcontainer-up`

ADR-6 puts one tmux server on the WSL host and has panes exec into containers. The direct
consequence is that no image needs tmux in it, which makes the ~25 lines of apt/apk/dnf logic in
`claude-devcontainer-up` dead weight: it exists only because that script runs `tmux new -A -s claude`
*inside* the container. Removing it also removes the last place the dotfiles mutate a devcontainer
image at attach time, which is the property ADR-4 declines to give back for agents.

The script's interface does not change. It still requires `devcontainer`, `docker`, and `jq`, still
refuses to run without a `.devcontainer/`, still parses `containerId` / `remoteUser` /
`remoteWorkspaceFolder` from the last JSON line of `devcontainer up`, and still ends by exec'ing
`docker exec -it -u "$user" -w "$wd" "$cid" tmux new -A -s claude`. An image without tmux now fails
at that exec with tmux's own error rather than triggering a package install — acceptable, because
`dev open` is the supported path and this script is the legacy one.

**Files:**
- Modify: `bin/claude-devcontainer-up`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Confirm nothing asserts the removed behaviour**

Run:

```bash
grep -rn "claude-devcontainer-up" tests/ docs/ bin/ tools/
grep -rniE "install(ing)? tmux|apt-get.*tmux|apk add.*tmux|dnf install.*tmux" tests/ docs/ bin/ tools/
```

Expected: the only hits inside `bin/claude-devcontainer-up` are the block being deleted; the only
hit in `docs/` is the spec's own line 173 describing the block (which is historical narration and
stays); the only hit in `bin/setup-agent-teams` is host tmux installation, which is unrelated and
stays. `tests/claude_compose_override.bats` contains no `tmux` reference, so no test asserts the
removed behaviour. If any of these expectations does not hold, update the offending assertion or doc
line in this task before proceeding.

- [ ] **Step 2: Delete the install block**

Remove lines 57–83 of `bin/claude-devcontainer-up` — the comment `# Ensure tmux is available inside
the container.` through the closing `fi` of the `if ! docker exec "$cid" sh -c 'command -v tmux
...'` block — so the tail of the script reads exactly:

```bash
[[ -n "$cid" && "$cid" != "null" ]] || {
  echo "Failed to parse containerId from devcontainer up output" >&2
  exit 1
}

# tmux is no longer installed into the image: the dev workspace platform runs a
# single tmux server on the host and execs panes into containers (ADR-6), so
# nothing here needs to mutate the image. An image without tmux fails at the
# exec below; `dev open` is the supported path.
exec docker exec -it -u "$user" -w "$wd" "$cid" tmux new -A -s claude
```

- [ ] **Step 3: Verify the script still parses and lints**

Run:

```bash
bash -n bin/claude-devcontainer-up
shellcheck -x -S warning -e SC1091 bin/claude-devcontainer-up
shfmt -d -i 2 -ci bin/claude-devcontainer-up
bats tests/claude_compose_override.bats
```

Expected: no output from `bash -n`, `shellcheck`, or `shfmt`; `bats` passes with 0 failures.

- [ ] **Step 4: Commit**

```bash
git add bin/claude-devcontainer-up
git commit -m "refactor(dev): drop in-container tmux installation from claude-devcontainer-up"
```

---

### Task 19: Lifecycle fold-equivalence test and full verification

This is the test that keeps records honest as *eventual projections* of the event stream (ADR-1). A
hook appends an event and only a later reconcile writes the record, so the two paths can drift; this
test replays a whole workspace lifecycle through the real commands, then folds the raw event log
from an empty record and asserts the two agree. Against a bare list of event names it could assert
nothing — it is testable only because §4.4 defines what folding each type does.

Three fields are excluded from the comparison by name, because the fold does not own them: reconcile
sets `last_seen` and `container.observed_at` from observation at the moment it looks, and
`scanned_through` is the fold cursor itself, which necessarily differs between a record folded
incrementally across six reconciles and one folded in a single pass. Everything else — `status`,
`container.status`, `container.id`, `agents[]`, `opened_at`, `stopped_reason`, `config_digest`,
`applied_digest`, `boot_id`, `fold_gap` — must match exactly.

**Dependency note for Task 14:** this test invokes `dev open <slug> --no-attach`, which runs the
full open path (reconcile, container up, session create, layout apply) and returns instead of
exec'ing `tmux attach-session`. A bats test cannot attach a client.

**Dependency note for Task 13:** the observation steps go through `dev list --json`, not `dev status`.
`dev status` is prose written for a human and rejects `--json` with exit 2; `dev list --json` is the
snapshot contract (ADR-2) and reconciles before printing, which is exactly what each step here needs.

**Files:**
- Create: `tests/dev_lifecycle.bats`

**Interfaces:**
- Consumes: `bin/dev` (`open`, `list`, `stop`), `dev_resolve_workspace_id <path>`,
  `dev_state_read <workspace_id>`, `dev_state_new <workspace_id> <slug> <session_name> <worktree>`,
  `dev_events_read_all`, `dev_fold_stream <record_json>`, `dev_now`, `dev_event_id_random`,
  `dev_event_build <id> <ts> <event> <workspace_id> <slug> <session_name> <worktree> <data_json>`,
  `dev_event_append <line>`, `setup_dev_test`, `stub_command`.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Write the lifecycle test**

```bash
#!/usr/bin/env bats

load test_helper

# Stubs docker and the devcontainer CLI. Container identity is read from
# $TEST_ROOT/container.id at call time, so a test can replace the container by
# writing a new id; an empty file means "no such container is running", which is
# how container loss is simulated.
lifecycle_stubs() {
  printf 'cid-one\n' >"$TEST_ROOT/container.id"
  stub_command mise 'if [[ "${1:-}" == "exec" ]]; then
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  exec "$@"
fi
exit 0'
  stub_command devcontainer 'case "${1:-}" in
  --version)
    echo "0.86.1"
    ;;
  up)
    cid=$(cat "$TEST_ROOT/container.id")
    printf "%s\n" "{\"outcome\":\"success\",\"containerId\":\"$cid\",\"remoteUser\":\"node\",\"remoteWorkspaceFolder\":\"/workspaces/app\"}"
    ;;
  exec)
    shift
    exit 0
    ;;
  *)
    exit 0
    ;;
esac'
  stub_command docker 'cid=$(cat "$TEST_ROOT/container.id")
case "${1:-}" in
  info)
    exit 0
    ;;
  inspect)
    want="${*: -1}"
    if [[ -n "$cid" && "$want" == "$cid" ]]; then
      printf "true\n"
      exit 0
    fi
    printf "Error: No such object: %s\n" "$want" >&2
    exit 1
    ;;
  exec)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac'
}

lifecycle_repo() {
  local worktree="$DEV_REPO_ROOT/app"
  mkdir -p "$worktree/.devcontainer"
  printf '%s\n' '{"image":"alpine"}' >"$worktree/.devcontainer/devcontainer.json"
  git -C "$worktree" init -q
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  mkdir -p "$DEV_OVERLAY_ROOT/app"
  # `agent:` is a command string, not a flag, and a window may set `agent` or
  # `command` but never both -- Task 4's validation exits 5 on that pair. Windows
  # merge by name (Task 4), so these four entries rewrite the shipped default's
  # four windows rather than adding a fifth; without the rewrite `agent-1` and
  # `agent-2` would run the default `claude`, which does not exist here, and
  # their panes would die the moment they were created.
  cat >"$DEV_OVERLAY_ROOT/app/workspace.yaml" <<'YAML'
windows:
  - name: agent-1
    agent: sleep 600
  - name: agent-2
    agent: sleep 600
  - name: shell
    command: sleep 600
  - name: scratch
    command: sleep 600
YAML
  printf '%s\n' "$worktree"
}

# Appends a hook-shaped event directly, the way tools/dev/dev-event does from a
# tmux hook. The record must not be touched here -- reconcile is what projects it.
lifecycle_emit() {
  local event="$1" data="$2"
  local id ts line
  id=$(dev_event_id_random)
  ts=$(dev_now)
  line=$(dev_event_build "$id" "$ts" "$event" "$LIFE_ID" app app "$LIFE_WORKTREE" "$data")
  dev_event_append "$line"
}

# Reconcile and return this workspace's entry from the public snapshot. `dev
# status` is prose for a human and has no --json (Task 13); `dev list --json` is
# the snapshot contract, so the observation steps below go through it. Selecting
# by slug rather than session name keeps this working if ADR-7's collision guard
# ever renames the session.
lifecycle_snapshot() {
  "$REPO_ROOT/bin/dev" list --json |
    jq -e --arg slug app '.workspaces[] | select(.slug == $slug)'
}

teardown() {
  tmux -L "$DEV_TMUX_SOCKET" kill-server 2>/dev/null || true
}

@test "folding the event log from empty reproduces the reconciled record" {
  setup_dev_test
  lifecycle_stubs

  LIFE_WORKTREE=$(lifecycle_repo)
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/state.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  source "$REPO_ROOT/tools/dev/lib/fold.sh"
  LIFE_ID=$(dev_resolve_workspace_id "$LIFE_WORKTREE")

  # 1. Open: reconcile, container up, session create, layout apply.
  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  tmux -L "$DEV_TMUX_SOCKET" has-session -t "=app"

  # 2. Attach: emitted by tmux's client-attached hook, folds to last_seen only.
  lifecycle_emit workspace.attached '{"client":"/dev/pts/9"}'
  run lifecycle_snapshot
  [ "$status" -eq 0 ]

  # 3. Container loss: the container disappears out from under the record.
  : >"$TEST_ROOT/container.id"
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.status' <<<"$output")" = "lost" ]

  # 4. Container replace: a different id comes back on the next open.
  printf 'cid-two\n' >"$TEST_ROOT/container.id"
  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.container.id' <<<"$output")" = "cid-two" ]

  # 5. Agent exit: kill the agent pane's process and let reconcile observe it.
  #    remain-on-exit keeps the pane, so the window survives as dead.
  tmux -L "$DEV_TMUX_SOCKET" respawn-pane -k -t "=app:agent-1" true
  local i
  for i in $(seq 1 50); do
    [[ "$(tmux -L "$DEV_TMUX_SOCKET" display-message -p -t "=app:agent-1" '#{pane_dead}')" == "1" ]] && break
    sleep 0.1
  done
  run lifecycle_snapshot
  [ "$status" -eq 0 ]

  # 6. Stop: the only destructive verb. It reconciles after the kill, so the
  #    record is already projected forward when this returns.
  run "$REPO_ROOT/bin/dev" stop app
  [ "$status" -eq 0 ]

  # The record as the commands left it.
  local record
  record=$(dev_state_read "$LIFE_ID")
  [ -n "$record" ]
  [ "$(jq -r '.status' <<<"$record")" = "stopped" ]
  [ "$(jq -r '.stopped_reason' <<<"$record")" = "user" ]

  # The same state derived only from the event stream, folded in one pass from a
  # fresh record. Restrict to this workspace so the fold sees exactly the events
  # a consumer of this workspace would see.
  local empty folded
  empty=$(dev_state_new "$LIFE_ID" app app "$LIFE_WORKTREE")
  folded=$(dev_events_read_all |
    jq -c --arg id "$LIFE_ID" 'select(.workspace_id == $id)' |
    dev_fold_stream "$empty")
  [ -n "$folded" ]

  # last_seen and container.observed_at are set by reconcile at observation time
  # and scanned_through is the fold cursor; the fold owns every other field.
  local strip='del(.last_seen, .scanned_through, .container.observed_at)'
  diff <(jq -S -c "$strip" <<<"$record") <(jq -S -c "$strip" <<<"$folded")
}

@test "the lifecycle emitted every event type the record depends on" {
  # Guards against the equivalence above passing vacuously: if open/stop stopped
  # emitting events entirely, both sides would fold to the same empty-ish record.
  setup_dev_test
  lifecycle_stubs

  LIFE_WORKTREE=$(lifecycle_repo)
  source "$REPO_ROOT/tools/dev/lib/resolve.sh"
  source "$REPO_ROOT/tools/dev/lib/events.sh"
  LIFE_ID=$(dev_resolve_workspace_id "$LIFE_WORKTREE")

  run "$REPO_ROOT/bin/dev" open app --no-attach
  [ "$status" -eq 0 ]
  : >"$TEST_ROOT/container.id"
  run lifecycle_snapshot
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/bin/dev" stop app
  [ "$status" -eq 0 ]

  local types
  types=$(dev_events_read_all |
    jq -r --arg id "$LIFE_ID" 'select(.workspace_id == $id) | .event' | sort -u)
  local want
  for want in workspace.opened container.starting container.ready container.lost workspace.stopped; do
    grep -qx "$want" <<<"$types" || {
      printf 'missing event type: %s\nsaw:\n%s\n' "$want" "$types" >&2
      return 1
    }
  done
}
```

- [ ] **Step 2: Run the test to verify it fails, then passes**

Run: `bats tests/dev_lifecycle.bats`
Expected on a first run against an incomplete fold: FAIL with a `diff` showing the differing fields
(most commonly `container.id` or `agents`). Fix the offending fold transition in
`tools/dev/lib/fold.sh` or the offending emit in the command that owns it — never by widening the
`del(...)` list, which is what would make this test stop meaning anything. Re-run until:
PASS (2 tests, 0 failures)

- [ ] **Step 3: Commit the lifecycle test**

```bash
git add tests/dev_lifecycle.bats
git commit -m "test(dev): assert records match the folded event stream across a lifecycle"
```

- [ ] **Step 4: Confirm every new `tools/dev` file is under the check gates**

This is the payoff for Task 1. A file that `bin/list-check-files` does not list is a file that
`shellcheck` and `shfmt` never see.

```bash
bin/list-check-files shellcheck | tr '\0' '\n' | grep tools/dev | sort
```

Expected: every one of these, and nothing missing —

```
tools/dev/dev-autostart
tools/dev/dev-event
tools/dev/install.sh
tools/dev/lib/backend-tmux.sh
tools/dev/lib/config.sh
tools/dev/lib/container.sh
tools/dev/lib/events.sh
tools/dev/lib/fold.sh
tools/dev/lib/reconcile.sh
tools/dev/lib/resolve.sh
tools/dev/lib/runtime.sh
tools/dev/lib/state.sh
tools/dev/commands/attach.sh
tools/dev/commands/config.sh
tools/dev/commands/list.sh
tools/dev/commands/open.sh
tools/dev/commands/status.sh
tools/dev/commands/stop.sh
```

Also confirm `bin/dev` is listed:

```bash
bin/list-check-files shellcheck | tr '\0' '\n' | grep -x 'bin/dev'
```

Expected: `bin/dev`.

- [ ] **Step 5: Run the full check suite**

```bash
/usr/bin/make check
```

`make` is broken under this zsh (`(eval):1: make: function definition file not found`), so it must
be spelled `/usr/bin/make check`. This runs `syntax lint test python-test validate`.

Expected: exit 0, with **0 errors and 0 warnings** — no `shellcheck` findings at `-S warning`, no
`shfmt -d -i 2 -ci` diffs, and every bats file passing including `dev_resolve`, `dev_config_merge`,
`dev_state_events`, `dev_fold`, `dev_reconcile`, `dev_runtime_container`, `dev_backend_tmux`,
`dev_commands`, `dev_install`, `dev_lifecycle`, `check_file_discovery`, and `claude_link_project`.

If any `dev_*` test leaves a tmux server behind, `tmux list-sessions -L devtest-*` will show it;
each such test must kill its own socket in `teardown`.

- [ ] **Step 6: Review the full diff against the spec's file tree**

```bash
git diff --stat main...HEAD
git diff main...HEAD
```

Walk the diff against §3 of `docs/superpowers/specs/2026-08-03-dev-workspace-platform-design.md` and
confirm, file by file:

- Every path in the §3 tree exists, except the two deliberate deviations, each of which is noted in
  a one-line comment in the file that would otherwise have carried it: `tools/dev/versions.toml`
  (superseded by the `[tools]` pin in `config/mise/config.toml`) and the `bin/dev` symlink
  (superseded by `~/.dotfiles/bin` already being first on `PATH` via `core/path.zsh`).
- No path exists that §3 does not name.
- `bin/common.sh`, `bin/claude-devcontainer-up`, `tools/tmux/tmux.conf.symlink`, `.gitignore`, and
  `bin/install` are the only modified pre-existing files, plus the two modified tests
  (`check_file_discovery.bats`, `claude_link_project.bats`).
- No leftover placeholders, debug `set -x`, `echo` tracing, or commented-out code.
- Every library defines functions only and calls no `set -e`; every executable starts with
  `#!/usr/bin/env bash` and `set -euo pipefail`.

- [ ] **Step 7: Commit any fixes the review turned up**

```bash
git add -A
git commit -m "chore(dev): address full-diff review findings"
```
