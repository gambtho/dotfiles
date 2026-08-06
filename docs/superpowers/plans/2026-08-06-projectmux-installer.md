# ProjectMux Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dotfiles installer that pins, verifies, and atomically installs a reviewed ProjectMux release, exposes its configuration under the XDG config root, and supports a developer override that never mutates the pin.

**Architecture:** A single `tools/projectmux/install.sh`, registered as an optional phase in `bin/install`, sourced by its tests under `PROJECTMUX_INSTALL_SOURCE_ONLY=1`. Every managed file reaches its final name through one helper, `publish_file`, which does a same-filesystem `command mv -Tf` from a staging file created inside the destination directory — so there is never a window where a partial file sits on `PATH`. Install mode is recorded in a state marker (`v0.1.0` or `local:<path>`), and because a Git tag cannot contain a colon, a local-mode marker can never satisfy the pinned-install short-circuit; that single fact is what makes "run without the override to restore the pin" work with no special-case code.

**Tech Stack:** Bash 5 (`set -euo pipefail`), bats for tests, shellcheck and shfmt as gates, `bin/common.sh` helpers (`download_verified_artifact`, `run_phase`, `log_*`), awk and sed for template rendering, systemd user units (written, never enabled).

## Global Constraints

- **This is installation policy only.** Do not port application logic. Dotfiles owns exactly three things: pin and install a reviewed release, expose configuration under the XDG config root, retain machine-local overrides in ignored files.
- **Pin a version and a digest.** Both, committed. `PROJECTMUX_VERSION=v0.1.0`.
- **Install atomically.** No window in which the binary on `PATH` is partial.
- **`PROJECTMUX_LOCAL_BINARY` must not mutate the pin**, and running without it must restore the pinned release.
- **Migrations are the application's job, not the installer's.**
- **Out of scope, do not touch:** `bin/dev`, `tools/dev/dev-event`, `tools/dev/dev.tmux.conf`, the existing `dev-autostart` unit, the managed tmux marker block.
- **Commit messages and code comments must not mention Claude or AI assistance.**
- **Do not reproduce the maintainer's email address** in logs, comments, or docs.
- **GitHub identity routes automatically from the remote owner; do not run `gh auth switch`.**
- **Linux only.** amd64 and arm64. Refuse every other platform before doing any other work.
- **Never enable the systemd unit.** No `systemctl` invocation anywhere in this installer.
- **Environment quirks:** bare `make` is broken in this shell — use `/usr/bin/make`. `rm` silently no-ops — always pass `-f`/`-rf`. `cp` is interactive — use `command cp`, and restore tracked files with `git checkout --`. Use `/usr/bin/diff`.

---

### Task 1: Widen shell discovery so `tools/<non-dev>/` installers reach all three gates

**Files:**
- Modify: `bin/list-check-files:40-48` (`is_dev_tool_shell` definition), `:64` (bash class), `:70` (shellcheck class), `:77` (shfmt class)
- Test: `tests/check_file_discovery.bats:5-43` (setup/teardown fixture), new tests appended after `:188`

**Interfaces:**
- Consumes: `git ls-files -z`, `git ls-files -z --others --exclude-standard`, the `class` argument (`bash|zsh|shellcheck|shfmt`)
- Produces: `is_tool_shell()` (renamed from `is_dev_tool_shell()`), NUL-separated path list on stdout
- Unchanged: `is_direct_bin_shell()`, `is_repository_sh()`, `is_repository_zsh()`

Context the implementer needs: `is_dev_tool_shell` matches only `tools/dev/*`. A future `tools/projectmux/install.sh` would therefore be invisible to `bash -n`, shellcheck, and shfmt while `make check` still reported success — the failure mode spec §3.7 calls out as the worst shape, because it is silent. Widening the prefix from `tools/dev/*` to `tools/*` has a verified blast radius of zero: `git ls-files tools/ | grep -v '^tools/dev/'` returns exactly eight files — `tools/commit.msg.example`, `tools/docker/aliases.zsh`, `tools/git.plugin.zsh`, `tools/kubernetes/aliases.zsh`, `tools/kubernetes/k8s.plugin.zsh`, `tools/tmux/agent-teams-extras.conf`, `tools/tmux/tmux.conf.symlink`, `tools/you-should-use.zsh` — and none of them satisfies the extensionless-or-`.sh` rule inside the predicate. Step 6 re-verifies this rather than trusting it.

- [ ] **Step 1: Add the `tools/<non-dev>/` probe fixture to the discovery suite.**

  In `tests/check_file_discovery.bats`, insert the following immediately after the `DEV_ZSH_FILE` write at `:34`, before `setup()`'s closing brace at `:35`:

  ```bash
    # Probes for a tools/ subdirectory that is not tools/dev. The installer that
    # motivates this class does not exist yet, so a fixture stands in for it —
    # that also keeps the gate honest if the installer is later renamed or moved.
    TOOL_PROBE_DIR="$REPO_ROOT/tools/projectmux"
    TOOL_INSTALL_FILE="$TOOL_PROBE_DIR/probe-install-$BATS_TEST_NUMBER.sh"
    TOOL_EXEC_FILE="$TOOL_PROBE_DIR/probe-exec-$BATS_TEST_NUMBER"
    TOOL_ZSH_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.zsh"
    TOOL_YAML_FILE="$TOOL_PROBE_DIR/probe-$BATS_TEST_NUMBER.yaml"
    mkdir -p "$TOOL_PROBE_DIR"
    printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_INSTALL_FILE"
    printf '#!/usr/bin/env bash\ntrue\n' >"$TOOL_EXEC_FILE"
    printf 'export PROBE=1\n' >"$TOOL_ZSH_FILE"
    printf 'defaults: {}\n' >"$TOOL_YAML_FILE"
  ```

  Then replace `teardown()` at `:37-43` in full with:

  ```bash
  teardown() {
    rm -f -- "$UNTRACKED_FILE" "$IGNORED_FILE" \
      "$DEV_LIB_FILE" "$DEV_CMD_FILE" "$DEV_INSTALL_FILE" "$DEV_EXEC_FILE" \
      "$DEV_YAML_FILE" "$DEV_CONF_FILE" "$DEV_UNIT_FILE" "$DEV_ZSH_FILE" \
      "$TOOL_INSTALL_FILE" "$TOOL_EXEC_FILE" "$TOOL_ZSH_FILE" "$TOOL_YAML_FILE"
    rmdir "$IGNORED_DIR" 2>/dev/null || true
    rmdir "$DEV_LIB_DIR" "$DEV_CMD_DIR" 2>/dev/null || true
    # rmdir, not rm -r: once the real installer lands here the directory is not
    # empty and must survive the suite untouched.
    rmdir "$TOOL_PROBE_DIR" 2>/dev/null || true
  }
  ```

- [ ] **Step 2: Add the two failing assertions.**

  Append to the end of `tests/check_file_discovery.bats` (after `:188`):

  ```bash
  @test "tools shell sources outside tools/dev land in every bash gate" {
    local class
    for class in bash shellcheck shfmt; do
      list_files "$class"
      [ "$status" -eq 0 ]
      [[ "$output" == *"${TOOL_INSTALL_FILE#"$REPO_ROOT/"}"* ]]
      [[ "$output" == *"${TOOL_EXEC_FILE#"$REPO_ROOT/"}"* ]]
    done
  }

  @test "tools non-shell assets outside tools/dev stay out of the bash gates" {
    # Guard against over-widening: this passes both before and after the
    # predicate change, and its job is to fail if the new prefix starts
    # swallowing .zsh plugins or config data that other consumers own.
    local class
    for class in bash shellcheck shfmt; do
      list_files "$class"
      [ "$status" -eq 0 ]
      [[ "$output" != *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
      [[ "$output" != *"${TOOL_YAML_FILE#"$REPO_ROOT/"}"* ]]
      [[ "$output" != *"tools/you-should-use.zsh"* ]]
      [[ "$output" != *"tools/commit.msg.example"* ]]
    done

    list_files zsh
    [ "$status" -eq 0 ]
    [[ "$output" == *"${TOOL_ZSH_FILE#"$REPO_ROOT/"}"* ]]
  }
  ```

- [ ] **Step 3: Run the suite and confirm the expected failure.**

  ```bash
  bats tests/check_file_discovery.bats
  ```

  Expected: 15 tests, 1 failure. The exclusion guard passes (nothing matches yet, which is exactly the bug); the inclusion test fails on its first assertion:

  ```
   ✗ tools shell sources outside tools/dev land in every bash gate
     (in test file tests/check_file_discovery.bats, line 195)
       `[[ "$output" == *"${TOOL_INSTALL_FILE#"$REPO_ROOT/"}"* ]]' failed

  15 tests, 1 failure
  ```

  If the failure line number differs, that is fine; if the test *passes*, stop — the predicate is not what this plan assumes and the rest of the task is invalid.

- [ ] **Step 4: Widen and rename the predicate.**

  Replace `bin/list-check-files:40-48` in full with:

  ```bash
  is_tool_shell() {
    local path="$1" name
    [[ "$path" == tools/* ]] || return 1
    name=${path##*/}
    # Extensionless executables (dev-event, dev-autostart, installer entry
    # points) and .sh sources are bash; everything else under tools/ is data for
    # another consumer (.yaml config, .tmux.conf, .service unit,
    # commit.msg.example) or belongs to the zsh class (.zsh plugins and aliases).
    # The prefix is tools/ rather than tools/dev/ so a new tool directory is
    # covered by the shell gates on the day it is added, instead of silently
    # passing `make check` because nothing looked at it.
    [[ "$name" != *.* || "$name" == *.sh ]]
  }
  ```

- [ ] **Step 5: Update the three call sites.**

  ```bash
  /usr/bin/sed -i 's/is_dev_tool_shell/is_tool_shell/g' bin/list-check-files
  rg -n 'is_dev_tool_shell|is_tool_shell' bin/list-check-files
  ```

  Expected: no `is_dev_tool_shell` remains, and exactly four hits for `is_tool_shell` — the definition plus lines 64 (bash), 70 (shellcheck), and 77 (shfmt).

- [ ] **Step 6: Re-verify the blast radius is still nil.**

  ```bash
  git ls-files tools/ | grep -v '^tools/dev/'
  for class in bash shellcheck shfmt; do
    printf '== %s\n' "$class"
    ./bin/list-check-files "$class" | tr '\0' '\n' | grep '^tools/' | grep -v '^tools/dev/' || true
  done
  ```

  Expected: the first command prints exactly the eight files listed in this task's preamble. Each `==` block prints its header and nothing else — the widened predicate admits no currently-tracked file. If any path appears, the predicate is over-matching; narrow it and re-run rather than adjusting the test.

- [ ] **Step 7: Run the discovery suite and the shell gates.**

  ```bash
  bats tests/check_file_discovery.bats && /usr/bin/make syntax lint
  ```

  Expected: `15 tests, 0 failures`, then a clean `syntax` and `lint` run. The pre-existing `tools/dev` probe tests (`dev platform shell sources land in every bash gate`, `dev platform non-shell assets stay out of the bash gates`, `dev platform zsh sources stay in the zsh gate`) must still pass untouched — that is the evidence the generalization did not change behavior for the existing platform.

- [ ] **Step 8: Commit.**

  ```bash
  git add bin/list-check-files tests/check_file_discovery.bats
  git commit -m "fix(check): cover shell sources under any tools/ subdirectory

  is_dev_tool_shell matched only tools/dev/*, so a shell entry point in any
  other tools/ subdirectory was skipped by bash -n, shellcheck, and shfmt while
  make check still reported success. Widen the prefix to tools/ and rename the
  predicate to match what it now selects. No currently tracked file under
  tools/ outside tools/dev/ satisfies the extensionless-or-.sh rule, so the
  discovered set is unchanged today."
  ```

---

### Task 2: Register the ProjectMux pin with a prerelease-aware freshness check

**Files:**
- Modify: `config/versions.env` (append after `:58`), `bin/versions:43-57` (`list_pins`), `bin/versions:104-115` (`check_artifact_release`), `bin/versions:117-145` (`check_pins`)
- Test: `tests/dependency_pins.bats:18-34` (`versions list`), `:45-50` (canonical manifest), `:88-101` (curl stub) and `:105-111` (assertions)

**Interfaces:**
- Produces: `PROJECTMUX_VERSION`, `PROJECTMUX_RELEASE_BASE`, `PROJECTMUX_LINUX_AMD64_SHA256`, `PROJECTMUX_LINUX_ARM64_SHA256` in `config/versions.env`; `latest_release_including_prerelease()`, `check_prerelease_artifact_release()`, `report_artifact_release()` in `bin/versions`
- Consumes: `CURL_DOWNLOAD_ARGS` (from `bin/common.sh:9`), `jq`
- Downstream: `tools/projectmux/install.sh` (Task 3+) sources `config/versions.env` and reads exactly the four `PROJECTMUX_*` names above, the same way `ai/vekil/install.sh:20` sources it for `VEKIL_*`. These names match the surrounding block's convention (`<TOOL>_VERSION` / `<TOOL>_RELEASE_BASE` / `<TOOL>_<OS>_<ARCH>_SHA256`, unquoted values, no `export`), so no deviation is being introduced.

Two facts this task is built on, both verified against the live API rather than assumed:

1. `https://api.github.com/repos/gambtho/projectmux/releases/latest` returns `404 Not Found`. Every `v0.x` release is a prerelease and GitHub's "latest" excludes prereleases. `CURL_DOWNLOAD_ARGS` includes `--fail`, so real curl exits 22 there. Registering ProjectMux through the existing `check_artifact_release` (`bin/versions:104`) would make `make pins-check` fail permanently. **Chosen behavior:** a sibling that reads `/releases` (the full list, newest first) and takes entry 0. Verified live: `.[0].tag_name` is `v0.1.0`, `.[0].prerelease` is `true`. This works while the project is prerelease-only and keeps working unchanged after a 1.0. Rejected alternative: leave the pin unlisted and unchecked — drift would then never be reported, which is the thing pin management exists for.
2. `tests/dependency_pins.bats:114-147` (the lookup-failure test) needs **no** new stub case. Verified by reading `check_pins`: `check_artifact_release mise` at `:139` runs before any appended ProjectMux call, its `return 1` propagates under `set -e`, and `check_pins` never reaches line 145. Keep the new call **after** `check_artifact_release nerd-fonts` (`:144`) so this stays true.

The digests below were fetched from the real release, not transcribed from the design doc:

```
$ curl -sSL https://github.com/gambtho/projectmux/releases/download/v0.1.0/SHA256SUMS
7197eb19215af33f4e57fb26b8038cf701319d84fed4a6167ccb573035f43cda  projectmux-linux-amd64
7f9dbd1ee2cda2f673b8feeed346f0ea5cc592aa0a4d8c97b7ed5108c8c4599e  projectmux-linux-arm64
```

They agree with spec §3.1, which additionally records that the amd64 binary was downloaded and hashed directly (matching), reports as a statically linked ELF, and prints `v0.1.0` from `projectmux version`. The arm64 digest comes from `SHA256SUMS` only — this host is amd64.

- [ ] **Step 1: Re-fetch the digests and confirm they match this plan.**

  ```bash
  curl -sSL https://github.com/gambtho/projectmux/releases/download/v0.1.0/SHA256SUMS
  ```

  Expected: the exact two lines quoted above. If either digest differs, stop and escalate — the release was re-cut and the version needs re-review before anything is pinned.

- [ ] **Step 2: Add the failing manifest and list assertions.**

  In `tests/dependency_pins.bats`, replace the `versions list` assertion block's vekil line at `:29` with these two lines (keeping everything else in the test as-is):

  ```bash
    [[ "$output" == *"artifact vekil v0.14.0"* ]]
    [[ "$output" == *"artifact projectmux v0.1.0"* ]]
  ```

  Then replace the canonical-manifest test at `:45-50` in full with:

  ```bash
  @test "non-mise pins have one canonical manifest" {
    run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL|VEKIL_VERSION|VEKIL_RELEASE_BASE|VEKIL_(DARWIN|LINUX)_(AMD64|ARM64)_SHA256|PROJECTMUX_VERSION|PROJECTMUX_RELEASE_BASE|PROJECTMUX_LINUX_(AMD64|ARM64)_SHA256)=' "$REPO_ROOT" \
      --glob '!docs/**' --glob '!tests/**'
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_ROOT/config/versions.env" ]

    # The alternation above is an OR, so a missing key family cannot fail it —
    # any one surviving family still resolves to versions.env. Assert the new
    # family on its own so the manifest guarantee actually covers it.
    run rg -l '^PROJECTMUX_(VERSION|RELEASE_BASE|LINUX_(AMD64|ARM64)_SHA256)=' "$REPO_ROOT" \
      --glob '!docs/**' --glob '!tests/**'
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_ROOT/config/versions.env" ]
  }
  ```

- [ ] **Step 3: Run and confirm the expected failure.**

  ```bash
  bats tests/dependency_pins.bats
  ```

  Expected: 15 tests, 2 failures.

  ```
   ✗ versions list shows mise and non-mise pins
     (in test file tests/dependency_pins.bats, line 30)
       `[[ "$output" == *"artifact projectmux v0.1.0"* ]]' failed
   ✗ non-mise pins have one canonical manifest
     (in test file tests/dependency_pins.bats, line 55)
       `[ "$status" -eq 0 ]' failed

  15 tests, 2 failures
  ```

  The second failure is `rg` exiting 1 because no file defines a `PROJECTMUX_*` key yet.

- [ ] **Step 4: Add the pin block to `config/versions.env`.**

  Append to the end of the file (after `TREE_SITTER_SHA256_ARM64` at `:58`):

  ```
  # ProjectMux, the Go replacement for the tools/dev Bash workspace platform.
  # Every v0.x tag is a GitHub prerelease, so /releases/latest 404s and
  # /releases/latest/download/ is unusable — an explicit tag is pinned, which
  # the reviewed-digest requirement demands regardless. Digests come from the
  # release's SHA256SUMS; the amd64 binary was additionally downloaded and
  # hashed directly rather than trusted from that file. Upstream publishes no
  # darwin assets, and the installer is Linux-only by design.
  PROJECTMUX_VERSION=v0.1.0
  PROJECTMUX_RELEASE_BASE=https://github.com/gambtho/projectmux/releases/download/v0.1.0
  PROJECTMUX_LINUX_AMD64_SHA256=7197eb19215af33f4e57fb26b8038cf701319d84fed4a6167ccb573035f43cda
  PROJECTMUX_LINUX_ARM64_SHA256=7f9dbd1ee2cda2f673b8feeed346f0ea5cc592aa0a4d8c97b7ed5108c8c4599e
  ```

- [ ] **Step 5: List the pin in `bin/versions`.**

  In `list_pins`, insert one line after the vekil entry at `:52`:

  ```bash
    printf 'artifact vekil %s\n' "$VEKIL_VERSION"
    printf 'artifact projectmux %s\n' "$PROJECTMUX_VERSION"
    printf 'artifact nerd-fonts %s\n' "$NERD_FONTS_VERSION"
  ```

- [ ] **Step 6: Run and confirm both tests now pass.**

  ```bash
  bats tests/dependency_pins.bats
  ```

  Expected: `15 tests, 0 failures`. The `versions check reports every pinned artifact release` test still passes because nothing queries ProjectMux yet.

- [ ] **Step 7: Add the failing freshness-check assertions.**

  In `tests/dependency_pins.bats`, replace the curl stub heredoc body in `versions check reports every pinned artifact release` (`:88-100`) with:

  ```bash
    cat >"$STUB_BIN/curl" <<'SCRIPT'
  #!/usr/bin/env bash
  url="${@: -1}"
  case "$url" in
    *dl.k8s.io*) printf 'v1.28.0\n' ;;
    *jdx/mise*) printf '{"tag_name":"v2026.7.18"}\n' ;;
    *kubernetes-sigs/krew*) printf '{"tag_name":"v0.5.0"}\n' ;;
    *mikefarah/yq*) printf '{"tag_name":"v4.45.1"}\n' ;;
    *equalsraf/win32yank*) printf '{"tag_name":"v0.1.1"}\n' ;;
    *sozercan/vekil*) printf '{"tag_name":"v0.14.0"}\n' ;;
    *ryanoasis/nerd-fonts*) printf '{"tag_name":"v3.4.0"}\n' ;;
    # Every ProjectMux release is a prerelease, so /releases/latest really does
    # 404 and --fail turns that into exit 22. Listing it first means a check
    # wired to the wrong endpoint fails here instead of quietly passing.
    *gambtho/projectmux/releases/latest)
      printf 'curl: (22) The requested URL returned error: 404\n' >&2
      exit 22
      ;;
    *gambtho/projectmux/releases) printf '[{"tag_name":"v0.1.0","prerelease":true}]\n' ;;
  esac
  SCRIPT
  ```

  And add one assertion after the vekil line at `:110`:

  ```bash
    [[ "$output" == *"current artifact vekil v0.14.0"* ]]
    [[ "$output" == *"current artifact projectmux v0.1.0"* ]]
    [[ "$output" == *"current artifact nerd-fonts v3.4.0"* ]]
  ```

- [ ] **Step 8: Run and confirm the expected failure.**

  ```bash
  bats tests/dependency_pins.bats
  ```

  Expected: 15 tests, 1 failure — `check_pins` never queries ProjectMux, so the line is absent from the output:

  ```
   ✗ versions check reports every pinned artifact release
     (in test file tests/dependency_pins.bats, line 116)
       `[[ "$output" == *"current artifact projectmux v0.1.0"* ]]' failed

  15 tests, 1 failure
  ```

- [ ] **Step 9: Add the prerelease-aware lookup to `bin/versions`.**

  Replace `check_artifact_release` at `:104-115` in full with the shared reporter plus both checkers. The extracted reporter keeps the two checkers from drifting into two different output formats, which is what `versions list`/`check` consumers parse:

  ```bash
  report_artifact_release() {
    local name="$1" current="$2" latest="$3"
    if [[ "$current" == "$latest" ]]; then
      printf 'current artifact %s %s\n' "$name" "$current"
    else
      printf 'outdated artifact %s %s -> %s\n' "$name" "$current" "$latest"
    fi
  }

  check_artifact_release() {
    local name="$1" repository="$2" current="$3" latest
    latest=$(latest_artifact_release "$repository") || {
      printf 'error artifact %s: unable to query latest release for %s\n' "$name" "$repository" >&2
      return 1
    }
    report_artifact_release "$name" "$current" "$latest"
  }

  # /releases/latest excludes prereleases and 404s for a repository that has only
  # ever cut v0.x prereleases. /releases lists every release newest-first, so
  # entry 0 is the drift target both now and after the project reaches 1.0 --
  # which is why this is not a temporary shim.
  latest_release_including_prerelease() {
    local repository="$1" response
    response=$(curl "${CURL_DOWNLOAD_ARGS[@]}" --silent "https://api.github.com/repos/$repository/releases") || return
    # Guard the shape before indexing: an error body is a JSON *object*, and
    # `.[0]` against one is a jq crash rather than a clean lookup failure.
    jq -er 'if type == "array" and length > 0 then .[0].tag_name else null end' <<<"$response"
  }

  check_prerelease_artifact_release() {
    local name="$1" repository="$2" current="$3" latest
    latest=$(latest_release_including_prerelease "$repository") || {
      printf 'error artifact %s: unable to query latest release for %s\n' "$name" "$repository" >&2
      return 1
    }
    report_artifact_release "$name" "$current" "$latest"
  }
  ```

- [ ] **Step 10: Call it from `check_pins`.**

  Append one line after `check_artifact_release nerd-fonts ...` at `:144`, the last line of `check_pins`. Ordering is load-bearing: the existing lookup-failure test stubs all of `*api.github.com*` and relies on `check_pins` dying at the mise call under `set -e`, so this must not move ahead of `:139`.

  ```bash
    check_artifact_release nerd-fonts ryanoasis/nerd-fonts "$NERD_FONTS_VERSION"
    check_prerelease_artifact_release projectmux gambtho/projectmux "$PROJECTMUX_VERSION"
  ```

- [ ] **Step 11: Run the pins suite.**

  ```bash
  bats tests/dependency_pins.bats
  ```

  Expected: `15 tests, 0 failures`. In particular `versions check reports artifact release lookup failures clearly` must still pass with no new stub case — confirming the mise-first short-circuit.

- [ ] **Step 12: Confirm the check works against the live API.**

  ```bash
  ./bin/versions list | grep projectmux
  ./bin/versions check 2>&1 | grep projectmux
  ```

  Expected: `artifact projectmux v0.1.0` from the first, and `current artifact projectmux v0.1.0` from the second. If the second prints `error artifact projectmux: unable to query latest release for gambtho/projectmux`, the endpoint or jq guard is wrong — fix it here rather than after commit. (`./bin/versions check` also runs `mise outdated` and the Kubernetes lookup, so the full command may take a few seconds and may legitimately report other pins as outdated; only the projectmux line matters for this step.)

- [ ] **Step 13: Run the shell gates.**

  ```bash
  /usr/bin/make syntax lint
  ```

  Expected: clean. `bin/versions` sources `config/versions.env` under a `# shellcheck source=` directive, so the four new variables resolve; shfmt must report no diff for `bin/versions` or `tests/dependency_pins.bats`.

- [ ] **Step 14: Commit.**

  ```bash
  git add config/versions.env bin/versions tests/dependency_pins.bats
  git commit -m "feat(pins): register the ProjectMux release with a prerelease-aware check

  Pin v0.1.0 with both linux digests from the release SHA256SUMS, and list it
  alongside the other artifact pins so the single-canonical-manifest rule
  covers it.

  Freshness cannot go through check_artifact_release: every v0.x tag is a
  GitHub prerelease, and /releases/latest excludes prereleases, so that
  endpoint 404s and would break make pins-check. A sibling reads /releases and
  takes the newest entry, which is correct before and after a 1.0 release."
  ```

---

### Task 3: Installer skeleton — platform gate, path safety, atomic publish

**Files:**
- Create: `tools/projectmux/install.sh`
- Create: `tests/projectmux_install.bats`

**Interfaces:**
- Consumes: `bin/common.sh` (`log_info`, `log_success`, `log_warning`, `log_error`, `download_verified_artifact`), `config/versions.env` (the four `PROJECTMUX_*` names from Task 2)
- Produces:
  - `require_platform` → prints the normalized arch (`amd64`|`arm64`) on stdout, returns non-zero on a refusal
  - `prepare_destination_directory "$dir"` → mkdir -p, accepts a symlink-to-directory
  - `validate_install_target "$path"` → returns non-zero if `$path` is a directory (or a symlink to one)
  - `publish_file "$staged" "$destination"` → same-filesystem `command mv -Tf`
  - `installed_marker` → prints the marker's trimmed contents, returns non-zero if absent or not a regular file
  - `report_plan`, `main`, and the `PROJECTMUX_INSTALL_SOURCE_ONLY` guard
  - Globals: `PROJECTMUX_INSTALL_DIR`, `PROJECTMUX_BIN`, `PROJECTMUX_STATE_DIR`, `MARKER_FILE`, `PROJECTMUX_CONFIG_ROOT`, `DEFAULTS_TEMPLATE`, `STAGED_BIN`, `STAGED_MARKER`, `STAGED_CONFIG`, `STAGED_UNIT`, `DOWNLOAD_DIR`
- Test helper produced: `source_installer` (used by Tasks 4-7)

Two facts the implementer must not rediscover the hard way:

- `log_error` in `bin/common.sh` **exits**; it does not return. Anywhere a caller needs to keep going (or a test needs to observe a non-zero return), use `printf ... >&2; return 1` instead.
- `[[ -f path ]]` is **true** for a symlink pointing at a regular file. Every "is this really a regular file" test therefore needs `&& ! -L`. `[[ -d path ]]` follows symlinks, so a single `-d` test covers symlink-to-directory — which is why `validate_install_target` checks `-d` first.

`prepare_destination_directory` is **not** in `bin/common.sh`; it is local to `ai/vekil/install.sh:273`. This installer defines its own, deliberately differing in one way: `ai/vekil/install.sh:273` rejects a symlinked destination directory outright, whereas a symlinked `~/.local/bin` is an ordinary setup on this machine class. Accepting the symlink-to-directory is safe here because every write goes through `publish_file`, whose `mv -T` refuses to descend into a directory destination.

- [ ] **Step 1: Write the failing platform-gate test.**

  Create `tests/projectmux_install.bats`:

  ```bash
  #!/usr/bin/env bats

  load test_helper

  setup() {
    setup_dotfiles_test
  }

  # Every test sources the installer instead of executing it, matching the
  # pattern in tests/font_install.bats: sourcing lets a test override a single
  # function (download_verified_artifact, systemctl) without a PATH stub, and
  # keeps the real main() from running.
  source_installer() {
    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      PROJECTMUX_CONFIG_ROOT="$TEST_ROOT/config/projectmux" \
      "$@"
  }

  @test "a non-Linux host is refused before anything is written" {
    source_installer PROJECTMUX_OS=Darwin bash -c '
      source "$1/tools/projectmux/install.sh"
      require_platform
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Linux only"* ]]
    [ ! -e "$TEST_ROOT/bin/projectmux" ]
  }

  @test "an unsupported architecture is refused" {
    source_installer PROJECTMUX_ARCH=riscv64 bash -c '
      source "$1/tools/projectmux/install.sh"
      require_platform
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsupported ProjectMux architecture: riscv64"* ]]
  }

  @test "supported architecture spellings normalize" {
    local spelling
    for spelling in x86_64 amd64; do
      source_installer PROJECTMUX_ARCH="$spelling" bash -c '
        source "$1/tools/projectmux/install.sh"
        require_platform
      ' _ "$REPO_ROOT"
      [ "$status" -eq 0 ]
      [ "$output" = amd64 ]
    done

    for spelling in aarch64 arm64; do
      source_installer PROJECTMUX_ARCH="$spelling" bash -c '
        source "$1/tools/projectmux/install.sh"
        require_platform
      ' _ "$REPO_ROOT"
      [ "$status" -eq 0 ]
      [ "$output" = arm64 ]
    done
  }
  ```

- [ ] **Step 2: Run and watch it fail.**

  ```bash
  bats tests/projectmux_install.bats
  ```

  Expected: 3 tests, 3 failures — `tools/projectmux/install.sh: No such file or directory`.

- [ ] **Step 3: Create the installer skeleton.**

  Create `tools/projectmux/install.sh`:

  ```bash
  #!/usr/bin/env bash
  # tools/projectmux/install.sh -- install the pinned ProjectMux release, its
  # default configuration, and its (deliberately un-enabled) user unit.
  #
  # This installer owns installation policy only: which release is pinned, that
  # it verifies against a committed digest, and that it lands atomically. It
  # contains no workspace logic -- that is the application's job, including any
  # migration of existing state.

  set -euo pipefail

  # shellcheck source=bin/common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../../bin/common.sh"

  DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

  # shellcheck source=config/versions.env
  source "$DOTFILES_ROOT/config/versions.env"

  PROJECTMUX_INSTALL_DIR="${PROJECTMUX_INSTALL_DIR:-$HOME/.local/bin}"
  PROJECTMUX_BIN="$PROJECTMUX_INSTALL_DIR/projectmux"
  PROJECTMUX_STATE_DIR="${PROJECTMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/projectmux}"
  MARKER_FILE="$PROJECTMUX_STATE_DIR/installed-version"
  PROJECTMUX_CONFIG_ROOT="${PROJECTMUX_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/projectmux}"
  DEFAULTS_TEMPLATE="$DOTFILES_ROOT/tools/projectmux/defaults.yaml.template"
  SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  UNIT_TEMPLATE="$DOTFILES_ROOT/tools/projectmux/projectmux-autostart.service"
  SERVICE_UNIT="$SYSTEMD_USER_DIR/projectmux-autostart.service"
  PROJECTMUX_REPOSITORY_ROOTS="${PROJECTMUX_REPOSITORY_ROOTS:-$HOME/workspace}"

  # Staging paths, cleared as soon as each is published. cleanup removes whatever
  # is still named here, so an interrupted run leaves no dotfile litter in
  # ~/.local/bin -- and, because nothing is ever published under its final name
  # until the rename, no partial file on PATH either.
  STAGED_BIN=""
  STAGED_MARKER=""
  STAGED_CONFIG=""
  STAGED_UNIT=""
  DOWNLOAD_DIR=""

  cleanup() {
    local path
    for path in "$STAGED_BIN" "$STAGED_MARKER" "$STAGED_CONFIG" "$STAGED_UNIT"; do
      [[ -n "$path" ]] && rm -f -- "$path"
    done
    [[ -n "$DOWNLOAD_DIR" ]] && rm -rf -- "$DOWNLOAD_DIR"
    return 0
  }
  trap cleanup EXIT

  # Upstream publishes linux/amd64 and linux/arm64 only, and the workspace
  # platform this replaces is Linux-only too. Refuse rather than install
  # something that cannot run.
  require_platform() {
    local os arch
    os="${PROJECTMUX_OS:-$(uname -s)}"
    arch="${PROJECTMUX_ARCH:-$(uname -m)}"

    if [[ "$os" != Linux && "$os" != linux ]]; then
      printf 'ProjectMux supports Linux only; refusing to install on: %s\n' "$os" >&2
      return 1
    fi

    case "$arch" in
      x86_64 | amd64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *)
        printf 'Unsupported ProjectMux architecture: %s\n' "$arch" >&2
        return 1
        ;;
    esac

    printf '%s\n' "$arch"
  }

  # Unlike ai/vekil/install.sh:273 this accepts a symlinked directory: a
  # symlinked ~/.local/bin is ordinary here, and every write still goes through
  # publish_file, whose mv -T refuses to descend into a directory destination.
  prepare_destination_directory() {
    local dir="$1"
    if [[ -e "$dir" || -L "$dir" ]]; then
      if [[ ! -d "$dir" ]]; then
        printf 'Refusing to install into %s: not a directory.\n' "$dir" >&2
        return 1
      fi
      return 0
    fi
    mkdir -p "$dir"
  }

  # -d is checked first and on its own: it follows symlinks, so one test covers
  # both a real directory and a symlink pointing at one. Everything else -- a
  # symlink to a file, a regular file, or nothing at all -- is a legitimate
  # destination that mv -Tf will replace in a single atomic step.
  validate_install_target() {
    local path="$1"
    if [[ -d "$path" ]]; then
      printf 'Refusing to replace directory: %s\n' "$path" >&2
      return 1
    fi
    return 0
  }

  # The one way a managed file reaches its final name. -T is what makes this
  # safe: without it, mv follows a symlinked destination and drops the staged
  # file *inside* the target directory instead of replacing the link.
  publish_file() {
    local staged="$1" destination="$2"
    validate_install_target "$destination" || return 1
    command mv -Tf "$staged" "$destination"
  }

  # Absent, unreadable, or a symlink -> no marker. A symlinked marker is treated
  # as absent rather than followed, so a planted link cannot make the installer
  # believe a version is present that is not.
  installed_marker() {
    [[ -f "$MARKER_FILE" && ! -L "$MARKER_FILE" ]] || return 1
    tr -d '[:space:]' <"$MARKER_FILE"
  }

  report_plan() {
    printf 'ProjectMux install plan:\n'
    printf '  version:    %s\n' "$PROJECTMUX_VERSION"
    printf '  binary:     %s\n' "$PROJECTMUX_BIN"
    printf '  state:      %s\n' "$PROJECTMUX_STATE_DIR"
    printf '  config:     %s\n' "$PROJECTMUX_CONFIG_ROOT"
    printf '  unit:       %s (written, not enabled)\n' "$SERVICE_UNIT"
    printf '  installed:  %s\n' "$(installed_marker || printf '(none)')"
    if [[ -n "${PROJECTMUX_LOCAL_BINARY:-}" ]]; then
      printf '  override:   %s (pin unchanged)\n' "$PROJECTMUX_LOCAL_BINARY"
    fi
  }

  main() {
    if [[ "${1:-}" == "--check" ]]; then
      report_plan
      return 0
    fi

    # Split from the assignment on purpose: `local arch=$(...)` takes the exit
    # status of `local`, not of the command, so the platform refusal would be
    # swallowed and the install would continue on an unsupported host.
    local arch
    arch=$(require_platform)

    install_binary "$arch"
    install_config
    install_unit
  }

  if [[ "${PROJECTMUX_INSTALL_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
  fi
  ```

  `install_binary`, `install_config`, and `install_unit` are added by Tasks 4-7. Until Task 4 lands, running the script directly fails at `install_binary`; the tests source it with `PROJECTMUX_INSTALL_SOURCE_ONLY=1` and never call `main`, so the suite is green in the meantime.

- [ ] **Step 4: Make it executable and run the tests.**

  ```bash
  chmod 0755 tools/projectmux/install.sh
  bats tests/projectmux_install.bats
  ```

  Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Write the failing path-safety tests.**

  Append to `tests/projectmux_install.bats`:

  ```bash
  @test "publish_file refuses a directory destination" {
    mkdir -p "$TEST_ROOT/bin/projectmux"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      staged=$(mktemp "$TEST_ROOT/bin/.projectmux.XXXXXX")
      printf "new" >"$staged"
      publish_file "$staged" "$PROJECTMUX_BIN"
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing to replace directory"* ]]
    [ -d "$TEST_ROOT/bin/projectmux" ]
  }

  @test "publish_file replaces a symlink instead of writing through it" {
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/elsewhere"
    printf 'original' >"$TEST_ROOT/elsewhere/projectmux"
    ln -s "$TEST_ROOT/elsewhere/projectmux" "$TEST_ROOT/bin/projectmux"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      staged=$(mktemp "$TEST_ROOT/bin/.projectmux.XXXXXX")
      printf "replacement" >"$staged"
      publish_file "$staged" "$PROJECTMUX_BIN"
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ ! -L "$TEST_ROOT/bin/projectmux" ]
    [ "$(cat "$TEST_ROOT/bin/projectmux")" = replacement ]
    # The link target is untouched -- proof mv -T replaced the link rather than
    # following it.
    [ "$(cat "$TEST_ROOT/elsewhere/projectmux")" = original ]
  }

  @test "installed_marker treats a symlinked marker as absent" {
    mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/elsewhere"
    printf 'v9.9.9\n' >"$TEST_ROOT/elsewhere/version"
    ln -s "$TEST_ROOT/elsewhere/version" "$TEST_ROOT/state/installed-version"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      installed_marker
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [ -z "$output" ]
  }

  @test "prepare_destination_directory accepts a symlinked directory" {
    mkdir -p "$TEST_ROOT/real-bin"
    ln -s "$TEST_ROOT/real-bin" "$TEST_ROOT/bin"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
  }

  @test "prepare_destination_directory refuses a plain file" {
    mkdir -p "$TEST_ROOT"
    printf 'not a directory' >"$TEST_ROOT/bin"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not a directory"* ]]
  }
  ```

- [ ] **Step 6: Run the full file.**

  ```bash
  bats tests/projectmux_install.bats
  ```

  Expected: `8 tests, 0 failures`. These tests exercise code written in Step 3; if any fails, the skeleton is wrong — fix `install.sh`, not the test.

- [ ] **Step 7: Confirm the new file is covered by the gates.**

  ```bash
  ./bin/list-check-files shellcheck | tr '\0' '\n' | grep tools/projectmux/install.sh
  /usr/bin/make syntax lint
  ```

  Expected: the grep prints `tools/projectmux/install.sh` (this is Task 1's discovery fix paying off — without it the grep is silent and the gates never see the file), then a clean `syntax` and `lint`.

- [ ] **Step 8: Commit.**

  ```bash
  git add tools/projectmux/install.sh tests/projectmux_install.bats
  git commit -m "feat(projectmux): add the installer skeleton with atomic publish

  Establishes the platform gate, the destination-path safety checks, and the
  single stage-then-rename helper every managed file goes through. mv -Tf is
  used rather than mv -f so a symlinked destination is replaced instead of
  being followed into a directory."
  ```

---

### Task 4: Local-binary override and the marker writer

**Files:**
- Modify: `tools/projectmux/install.sh` — add `write_marker`, `install_local_binary`, `install_binary`
- Test: `tests/projectmux_install.bats`

**Interfaces:**
- Consumes: `prepare_destination_directory`, `validate_install_target`, `publish_file`, `MARKER_FILE`, `PROJECTMUX_BIN`, `PROJECTMUX_STATE_DIR`, `PROJECTMUX_INSTALL_DIR` (all Task 3)
- Produces:
  - `write_marker "$value"` → stages and publishes `MARKER_FILE`; **Task 5 consumes this and must not write the marker directly**
  - `install_local_binary` → symlinks `PROJECTMUX_LOCAL_BINARY` onto `PROJECTMUX_BIN`, records `local:<path>`
  - `install_binary "$arch"` → dispatches on `PROJECTMUX_LOCAL_BINARY`; the pinned branch calls `install_pinned_binary` (Task 5)

The marker's encoding is what makes requirement §11.3 work with no special-case code: a pinned install records the tag (`v0.1.0`), a local install records `local:<absolute path>`, and **a Git tag cannot contain a colon**. So a local-mode marker can never equal `$PROJECTMUX_VERSION`, the pinned short-circuit can never fire while a local build is installed, and simply re-running the installer without the override reinstalls the pin. Nothing anywhere reads `PROJECTMUX_LOCAL_BINARY` back out of the marker to decide that — the encoding alone forces it.

Because `install_binary` here already dispatches to `install_pinned_binary`, Task 5 must **not** redefine it.

- [ ] **Step 1: Write the failing local-install test.**

  Append to `tests/projectmux_install.bats`:

  ```bash
  @test "a local binary is symlinked and recorded without touching the pin" {
    mkdir -p "$TEST_ROOT/local"
    printf '#!/usr/bin/env bash\necho local\n' >"$TEST_ROOT/local/projectmux"
    chmod 0755 "$TEST_ROOT/local/projectmux"

    source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_local_binary
      printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ -L "$TEST_ROOT/bin/projectmux" ]
    [ "$(readlink "$TEST_ROOT/bin/projectmux")" = "$TEST_ROOT/local/projectmux" ]
    [[ "$output" == *"MARKER=local:$TEST_ROOT/local/projectmux"* ]]

    # The override must never mutate the pin -- the whole point of requirement 3.
    run git -C "$REPO_ROOT" diff --exit-code config/versions.env
    [ "$status" -eq 0 ]
  }
  ```

- [ ] **Step 2: Run and watch it fail.**

  ```bash
  bats tests/projectmux_install.bats --filter 'a local binary is symlinked'
  ```

  Expected: FAIL with `install_local_binary: command not found`.

- [ ] **Step 3: Add `write_marker`.**

  In `tools/projectmux/install.sh`, immediately after `installed_marker`:

  ```bash
  # The marker goes through the same stage-then-rename as every other managed
  # file, so a concurrent reader never sees a half-written version string.
  write_marker() {
    local value="$1"
    prepare_destination_directory "$PROJECTMUX_STATE_DIR"
    STAGED_MARKER=$(mktemp "$PROJECTMUX_STATE_DIR/.installed-version.XXXXXX")
    printf '%s\n' "$value" >"$STAGED_MARKER"
    chmod 0644 "$STAGED_MARKER"
    publish_file "$STAGED_MARKER" "$MARKER_FILE"
    STAGED_MARKER=""
  }
  ```

- [ ] **Step 4: Add `install_local_binary`.**

  ```bash
  # PROJECTMUX_LOCAL_BINARY points at a developer build. It is symlinked rather
  # than copied so a rebuild takes effect without re-running the installer, and
  # so `test -L` alone distinguishes override mode from a pinned install.
  install_local_binary() {
    local local_binary="$PROJECTMUX_LOCAL_BINARY"

    # Each refusal gets its own message: "not executable" and "is a directory"
    # send the developer to very different fixes. -d is checked before -e so a
    # directory does not fall through to the generic missing-file message.
    if [[ "$local_binary" != /* ]]; then
      printf 'PROJECTMUX_LOCAL_BINARY must be an absolute path: %s\n' "$local_binary" >&2
      return 1
    fi
    if [[ -d "$local_binary" ]]; then
      printf 'PROJECTMUX_LOCAL_BINARY is a directory: %s\n' "$local_binary" >&2
      return 1
    fi
    if [[ ! -e "$local_binary" ]]; then
      printf 'PROJECTMUX_LOCAL_BINARY does not exist: %s\n' "$local_binary" >&2
      return 1
    fi
    if [[ ! -x "$local_binary" ]]; then
      printf 'PROJECTMUX_LOCAL_BINARY is not executable: %s\n' "$local_binary" >&2
      return 1
    fi

    prepare_destination_directory "$PROJECTMUX_INSTALL_DIR"
    validate_install_target "$PROJECTMUX_BIN" || return 1

    # mktemp reserves the name by creating a regular file, and ln -s refuses to
    # write over an existing path, so the reservation has to be released before
    # the link is made. The window is inside the destination directory and under
    # a dot-prefixed name, never at the published name on PATH.
    STAGED_BIN=$(mktemp "$PROJECTMUX_INSTALL_DIR/.projectmux.XXXXXX")
    rm -f "$STAGED_BIN"
    ln -s "$local_binary" "$STAGED_BIN"
    publish_file "$STAGED_BIN" "$PROJECTMUX_BIN"
    STAGED_BIN=""

    write_marker "local:$local_binary"
    log_success "Using local ProjectMux build at $local_binary (pin unchanged)."
  }
  ```

- [ ] **Step 5: Add the dispatcher.**

  ```bash
  install_binary() {
    local arch="$1"
    if [[ -n "${PROJECTMUX_LOCAL_BINARY:-}" ]]; then
      install_local_binary
    else
      install_pinned_binary "$arch"
    fi
  }
  ```

  `install_pinned_binary` arrives in Task 5. Nothing calls `install_binary` until then — `main` does, but no test invokes `main` and `bin/install` does not register the phase until Task 8.

- [ ] **Step 6: Run the test.**

  ```bash
  bats tests/projectmux_install.bats --filter 'a local binary is symlinked'
  ```

  Expected: `1 test, 0 failures`.

- [ ] **Step 7: Write the refusal tests.**

  ```bash
  @test "a relative local binary path is refused" {
    source_installer PROJECTMUX_LOCAL_BINARY=build/projectmux bash -c '
      source "$1/tools/projectmux/install.sh"
      install_local_binary
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"must be an absolute path"* ]]
    [ ! -e "$TEST_ROOT/bin/projectmux" ]
  }

  @test "a missing local binary is refused" {
    source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/nope/projectmux" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_local_binary
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [ ! -e "$TEST_ROOT/bin/projectmux" ]
  }

  @test "a non-executable local binary is refused" {
    mkdir -p "$TEST_ROOT/local"
    printf 'not executable' >"$TEST_ROOT/local/projectmux"
    chmod 0644 "$TEST_ROOT/local/projectmux"

    source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_local_binary
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not executable"* ]]
    [ ! -e "$TEST_ROOT/bin/projectmux" ]
  }

  @test "a directory as the local binary is refused with its own message" {
    mkdir -p "$TEST_ROOT/local/projectmux"

    source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_local_binary
    ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"is a directory"* ]]
  }

  @test "install_binary dispatches on the override" {
    mkdir -p "$TEST_ROOT/local"
    printf '#!/usr/bin/env bash\ntrue\n' >"$TEST_ROOT/local/projectmux"
    chmod 0755 "$TEST_ROOT/local/projectmux"

    source_installer PROJECTMUX_LOCAL_BINARY="$TEST_ROOT/local/projectmux" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_pinned_binary() { printf "pinned branch taken\n"; }
      install_binary amd64
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" != *"pinned branch taken"* ]]
    [ -L "$TEST_ROOT/bin/projectmux" ]

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      install_pinned_binary() { printf "pinned branch taken\n"; }
      install_binary amd64
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"pinned branch taken"* ]]
  }
  ```

- [ ] **Step 8: Run the suite and the gates.**

  ```bash
  bats tests/projectmux_install.bats && /usr/bin/make syntax lint
  ```

  Expected: `14 tests, 0 failures`, then clean gates.

- [ ] **Step 9: Commit.**

  ```bash
  git add tools/projectmux/install.sh tests/projectmux_install.bats
  git commit -m "feat(projectmux): support a local build override that leaves the pin alone

  PROJECTMUX_LOCAL_BINARY symlinks a developer build onto the installed path and
  records it as local:<path>. A Git tag cannot contain a colon, so a local
  marker can never satisfy the pinned-install check -- which is what makes
  re-running the installer without the override restore the pinned release
  without any dedicated revert path."
  ```

---

### Task 5: Pinned release install and the restore-the-pin path

**Files:**
- Modify: `tools/projectmux/install.sh` — add `install_pinned_binary`
- Test: `tests/projectmux_install.bats`

**Interfaces:**
- Consumes: `require_platform` (prints the normalized arch), `prepare_destination_directory "$dir"`, `validate_install_target "$path"`, `publish_file "$staged" "$destination"`, `installed_marker`, `write_marker "$value"` (Task 4), the globals `MARKER_FILE`, `PROJECTMUX_BIN`, `PROJECTMUX_STATE_DIR`, and the pin variables from Task 2
- Produces: `install_pinned_binary "$arch"`. `install_binary` already dispatches to it (Task 4) — do **not** redefine that function here.

- [ ] **Step 1: Write the failing test for a pinned install**

  Append to `tests/projectmux_install.bats`:

  ```bash
  @test "pinned install publishes a regular file and records the version" {
    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      bash -c '
        source "$1/tools/projectmux/install.sh"
        download_verified_artifact() { printf "binary" >"$3"; }
        install_pinned_binary amd64
        printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
      ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKER=v0.1.0"* ]]
    [ -f "$TEST_ROOT/bin/projectmux" ]
    [ ! -L "$TEST_ROOT/bin/projectmux" ]
    [ -x "$TEST_ROOT/bin/projectmux" ]
  }
  ```

- [ ] **Step 2: Run it and watch it fail**

  Run: `bats tests/projectmux_install.bats --filter 'pinned install publishes'`

  Expected: FAIL with `install_pinned_binary: command not found`.

- [ ] **Step 3: Add `install_pinned_binary`**

  ```bash
  install_pinned_binary() {
    local arch="$1" asset digest bin_dir
    bin_dir=$(dirname "$PROJECTMUX_BIN")

    case "$arch" in
      amd64)
        asset="projectmux-linux-amd64"
        digest="$PROJECTMUX_LINUX_AMD64_SHA256"
        ;;
      arm64)
        asset="projectmux-linux-arm64"
        digest="$PROJECTMUX_LINUX_ARM64_SHA256"
        ;;
      *) log_error "Unsupported ProjectMux architecture: $arch" ;;
    esac

    prepare_destination_directory "$bin_dir"
    prepare_destination_directory "$PROJECTMUX_STATE_DIR"
    validate_install_target "$PROJECTMUX_BIN"

    # Both halves of this condition are load-bearing; do not reduce it to the
    # marker test alone. The binary and the marker are published by two separate
    # renames, so interleaved runs can pair a local-mode symlink with a pinned
    # marker. Requiring the destination to be a regular file as well means such a
    # pair fails the test and the next run reinstalls and repairs it, which is
    # what lets the installer self-heal instead of needing a lock.
    if [[ "$(installed_marker || true)" == "$PROJECTMUX_VERSION" ]] &&
      [[ -f "$PROJECTMUX_BIN" && ! -L "$PROJECTMUX_BIN" ]]; then
      log_info "ProjectMux $PROJECTMUX_VERSION is already installed at $PROJECTMUX_BIN."
      return 0
    fi

    command -v curl >/dev/null 2>&1 || log_error "curl is required to install ProjectMux."

    DOWNLOAD_DIR=$(mktemp -d)
    log_info "Downloading ProjectMux $PROJECTMUX_VERSION for linux/$arch..."
    download_verified_artifact "$PROJECTMUX_RELEASE_BASE/$asset" "$digest" "$DOWNLOAD_DIR/$asset" 0755

    STAGED_BIN=$(mktemp "$bin_dir/.projectmux.XXXXXX")
    command cp "$DOWNLOAD_DIR/$asset" "$STAGED_BIN"
    command chmod 0755 "$STAGED_BIN"

    validate_install_target "$PROJECTMUX_BIN"
    publish_file "$STAGED_BIN" "$PROJECTMUX_BIN"
    STAGED_BIN=""

    # Only after the binary is in place. An install interrupted before this point
    # leaves the old marker, so the next run reinstalls rather than believing a
    # partial install succeeded.
    write_marker "$PROJECTMUX_VERSION"

    rm -rf -- "$DOWNLOAD_DIR"
    DOWNLOAD_DIR=""
    log_success "Installed ProjectMux $PROJECTMUX_VERSION at $PROJECTMUX_BIN."
  }
  ```

- [ ] **Step 4: Run the test and watch it pass**

  Run: `bats tests/projectmux_install.bats --filter 'pinned install publishes'`
  Expected: `1 test, 0 failures`.

- [ ] **Step 5: Write the failing test for the no-download short-circuit**

  ```bash
  @test "a matching marker and a regular file skip the download entirely" {
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
    printf 'installed' >"$TEST_ROOT/bin/projectmux"
    chmod 0755 "$TEST_ROOT/bin/projectmux"
    printf 'v0.1.0\n' >"$TEST_ROOT/state/installed-version"

    # return 99 rather than a stub download: if the short-circuit fails to fire,
    # the install errors instead of quietly succeeding with fabricated content.
    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      bash -c '
        source "$1/tools/projectmux/install.sh"
        download_verified_artifact() { return 99; }
        install_pinned_binary amd64
      ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_ROOT/bin/projectmux")" = installed ]
  }
  ```

- [ ] **Step 6: Write the failing test for the reconciliation invariant**

  ```bash
  @test "a matching marker with a symlink destination still reinstalls" {
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/local"
    printf 'local build' >"$TEST_ROOT/local/projectmux"
    chmod 0755 "$TEST_ROOT/local/projectmux"
    ln -s "$TEST_ROOT/local/projectmux" "$TEST_ROOT/bin/projectmux"
    # The pathological pair the Reconciliation invariant describes: a pinned
    # marker naming a version the destination does not actually hold.
    printf 'v0.1.0\n' >"$TEST_ROOT/state/installed-version"

    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      bash -c '
        source "$1/tools/projectmux/install.sh"
        download_verified_artifact() { printf "pinned" >"$3"; }
        install_pinned_binary amd64
      ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ ! -L "$TEST_ROOT/bin/projectmux" ]
    [ "$(cat "$TEST_ROOT/bin/projectmux")" = pinned ]
    # The local build itself is untouched -- the symlink was replaced, not followed.
    [ "$(cat "$TEST_ROOT/local/projectmux")" = "local build" ]
  }
  ```

- [ ] **Step 7: Write the failing test for the restore-the-pin round trip**

  ```bash
  @test "a local marker cannot short-circuit, so the pin is restored" {
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/local"
    printf 'local build' >"$TEST_ROOT/local/projectmux"
    chmod 0755 "$TEST_ROOT/local/projectmux"
    ln -s "$TEST_ROOT/local/projectmux" "$TEST_ROOT/bin/projectmux"
    printf 'local:%s\n' "$TEST_ROOT/local/projectmux" >"$TEST_ROOT/state/installed-version"

    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      bash -c '
        source "$1/tools/projectmux/install.sh"
        download_verified_artifact() { printf "pinned" >"$3"; }
        install_pinned_binary amd64
        printf "MARKER=%s\n" "$(cat "$MARKER_FILE")"
      ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKER=v0.1.0"* ]]
    [ -f "$TEST_ROOT/bin/projectmux" ]
    [ ! -L "$TEST_ROOT/bin/projectmux" ]
    [ "$(cat "$TEST_ROOT/bin/projectmux")" = pinned ]
  }
  ```

  This test needs no new implementation code — a `local:` marker can never equal a version tag, because Git tags cannot contain a colon, so the short-circuit simply cannot fire and the normal pinned path runs. The test exists because that is a property of the marker encoding rather than of any line of code, and a later refactor could break it silently.

- [ ] **Step 8: Write the failing test for a rejected digest**

  ```bash
  @test "a failed verification leaves the installed binary untouched" {
    mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
    printf 'previous' >"$TEST_ROOT/bin/projectmux"
    chmod 0755 "$TEST_ROOT/bin/projectmux"
    printf 'v0.0.9\n' >"$TEST_ROOT/state/installed-version"

    run env PROJECTMUX_INSTALL_SOURCE_ONLY=1 \
      PROJECTMUX_INSTALL_DIR="$TEST_ROOT/bin" \
      PROJECTMUX_STATE_DIR="$TEST_ROOT/state" \
      bash -c '
        source "$1/tools/projectmux/install.sh"
        download_verified_artifact() { printf "checksum mismatch\n" >&2; return 1; }
        install_pinned_binary amd64
      ' _ "$REPO_ROOT"

    [ "$status" -ne 0 ]
    [ "$(cat "$TEST_ROOT/bin/projectmux")" = previous ]
    [ "$(cat "$TEST_ROOT/state/installed-version")" = v0.0.9 ]
  }
  ```

- [ ] **Step 9: Run the four new tests**

  Run: `bats tests/projectmux_install.bats`

  Expected: all pass. Steps 5-8 need no implementation beyond Step 3 — they assert properties of the code already written. If any fails, the short-circuit condition or the marker ordering is wrong; fix that rather than the test.

- [ ] **Step 10: Run the full suite and the gates**

  ```bash
  bats tests/projectmux_install.bats && /usr/bin/make check
  ```

  Expected: all tests pass; `make check` exits 0.

- [ ] **Step 11: Commit**

  ```bash
  git add tools/projectmux/install.sh tests/projectmux_install.bats
  git commit -m "feat(projectmux): install the pinned release and restore it after a local build"
  ```

---

### Task 6: Vendored default configuration under the XDG config root

**Files:**
- Create: `tools/projectmux/defaults.yaml.template`
- Modify: `tools/projectmux/install.sh` — add `render_defaults`, `install_config`
- Test: `tests/projectmux_install.bats`

**Interfaces:**
- Consumes: `prepare_destination_directory`, `publish_file`, `PROJECTMUX_CONFIG_ROOT`, `DEFAULTS_TEMPLATE`, `PROJECTMUX_REPOSITORY_ROOTS` (all Task 3)
- Produces: `render_defaults "$destination"`, `install_config`

Ownership rule, decided during brainstorming and binding here: the installer **creates `defaults.yaml` if it is absent, and never overwrites it**. On drift it logs a warning and returns success. A hand-edited config is machine-local state the user owns; silently reverting it on every `bin/install` run would be the single most annoying failure this component could have, and failing the phase would make an edited config break unrelated installs.

The one schema trap, verified against `internal/config/validate.go:120-140` in the ProjectMux repo: a window must set **exactly one** of `agent`, `command`, or `shell: true`. Validation counts `w.Agent != nil`, `w.Command != nil`, `w.Shell`. An explicit YAML `command: null` decodes a `*string` to nil, so it sets **zero** modes and validation fails with `window "shell" must set exactly one of agent, command, or shell: true (it sets none)`. The plain-shell window is therefore spelled `shell: true` — as every v1 fixture in that repo spells it. `command: null` is the legacy Bash-era spelling from `tools/dev/default-workspace.yaml` and must not be carried over.

The v1 loader also rejects unknown fields outright and rejects bare numbers for a `Duration`, so `start_timeout: 5m` must keep its unit suffix and no field may be invented beyond what the schema defines.

- [ ] **Step 1: Create the template.**

  Create `tools/projectmux/defaults.yaml.template`:

  ```yaml
  # ProjectMux defaults, installed by ~/.dotfiles/tools/projectmux/install.sh.
  #
  # This file is created once and then left alone: the installer never
  # overwrites it, so local edits survive every subsequent run. To go back to
  # the shipped defaults, delete it and re-run the installer.
  version: 1

  repository_roots:
  @REPOSITORY_ROOTS@

  # Autostart stays off: the user unit this repo installs is deliberately not
  # enabled, so nothing starts a session behind the user's back.
  autostart: false

  devcontainer:
    enabled: auto
    start_timeout: 5m

  windows:
    - name: agent-1
      agent: claude
      focus: true
    - name: agent-2
      agent: claude
    - name: shell
      shell: true
  ```

- [ ] **Step 2: Write the failing rendering test.**

  Append to `tests/projectmux_install.bats`:

  ```bash
  @test "defaults.yaml is created with the configured repository roots" {
    source_installer PROJECTMUX_REPOSITORY_ROOTS="$TEST_ROOT/workspace:$TEST_ROOT/other" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_config
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    local config="$TEST_ROOT/config/projectmux/defaults.yaml"
    [ -f "$config" ]
    grep -Fq "  - '"'"'$TEST_ROOT/workspace'"'"'" "$config"
    grep -Fq "  - '"'"'$TEST_ROOT/other'"'"'" "$config"
    [[ "$(cat "$config")" != *"@REPOSITORY_ROOTS@"* ]]
    grep -Fq 'shell: true' "$config"
    # command: null sets zero window modes and fails v1 validation.
    [[ "$(cat "$config")" != *"command: null"* ]]
    [ -d "$TEST_ROOT/config/projectmux/workspaces" ]
  }
  ```

- [ ] **Step 3: Run and watch it fail.**

  Run: `bats tests/projectmux_install.bats --filter 'defaults.yaml is created'`

  Expected: FAIL with `install_config: command not found`.

- [ ] **Step 4: Add the renderer.**

  In `tools/projectmux/install.sh`, after `write_marker`:

  ```bash
  # Roots arrive PATH-style (colon-separated) and are emitted as a YAML list.
  # Each entry is single-quoted and internal quotes are doubled, so a path
  # containing a space, a colon-adjacent character, or a quote survives intact
  # rather than producing a file the v1 loader rejects.
  render_defaults() {
    local destination="$1"
    PROJECTMUX_RENDER_ROOTS="${PROJECTMUX_REPOSITORY_ROOTS//:/$'\n'}" awk -v q="'" '
      $0 == "@REPOSITORY_ROOTS@" {
        n = split(ENVIRON["PROJECTMUX_RENDER_ROOTS"], list, "\n")
        for (i = 1; i <= n; i++) {
          if (list[i] == "") continue
          value = list[i]
          gsub(q, q q, value)
          printf "  - %s%s%s\n", q, value, q
        }
        next
      }
      { print }
    ' "$DEFAULTS_TEMPLATE" >"$destination"
  }
  ```

- [ ] **Step 5: Add `install_config`.**

  ```bash
  install_config() {
    local config="$PROJECTMUX_CONFIG_ROOT/defaults.yaml"

    prepare_destination_directory "$PROJECTMUX_CONFIG_ROOT"
    prepare_destination_directory "$PROJECTMUX_CONFIG_ROOT/workspaces"
    chmod 0700 "$PROJECTMUX_CONFIG_ROOT" "$PROJECTMUX_CONFIG_ROOT/workspaces"

    STAGED_CONFIG=$(mktemp "$PROJECTMUX_CONFIG_ROOT/.defaults.yaml.XXXXXX")
    render_defaults "$STAGED_CONFIG"
    chmod 0600 "$STAGED_CONFIG"

    if [[ ! -e "$config" && ! -L "$config" ]]; then
      publish_file "$STAGED_CONFIG" "$config"
      STAGED_CONFIG=""
      log_success "Installed ProjectMux defaults at $config."
      return 0
    fi

    # The config is machine-local state the user owns. Report drift and move on:
    # overwriting would silently discard a hand edit, and failing would make an
    # edited config break every unrelated phase of bin/install.
    if ! cmp -s "$STAGED_CONFIG" "$config"; then
      log_warning "$config differs from the shipped defaults; leaving it as-is."
    fi
    rm -f -- "$STAGED_CONFIG"
    STAGED_CONFIG=""
    return 0
  }
  ```

- [ ] **Step 6: Run the test.**

  Run: `bats tests/projectmux_install.bats --filter 'defaults.yaml is created'`
  Expected: `1 test, 0 failures`.

- [ ] **Step 7: Write the preservation tests.**

  ```bash
  @test "an existing config is never overwritten and drift is reported" {
    mkdir -p "$TEST_ROOT/config/projectmux"
    printf 'version: 1\n# hand edited\n' >"$TEST_ROOT/config/projectmux/defaults.yaml"

    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      install_config
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"differs from the shipped defaults"* ]]
    [ "$(cat "$TEST_ROOT/config/projectmux/defaults.yaml")" = $'version: 1\n# hand edited' ]
  }

  @test "a second run of an unedited config warns about nothing" {
    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      install_config
      install_config
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" != *"differs from the shipped defaults"* ]]
  }

  @test "no staging file is left behind in the config root" {
    source_installer bash -c '
      source "$1/tools/projectmux/install.sh"
      install_config
      install_config
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    run bash -c 'compgen -G "$1/.defaults.yaml.*"' _ "$TEST_ROOT/config/projectmux"
    [ "$status" -eq 1 ]
  }

  @test "a repository root containing a space renders as one quoted entry" {
    source_installer PROJECTMUX_REPOSITORY_ROOTS="$TEST_ROOT/my code" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_config
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    grep -Fq "  - '"'"'$TEST_ROOT/my code'"'"'" "$TEST_ROOT/config/projectmux/defaults.yaml"
    [ "$(grep -c '^  - ' "$TEST_ROOT/config/projectmux/defaults.yaml")" -eq 1 ]
  }
  ```

- [ ] **Step 8: Run the suite and the gates.**

  ```bash
  bats tests/projectmux_install.bats && /usr/bin/make syntax lint
  ```

  Expected: all tests pass, gates clean. Note `defaults.yaml.template` is a `.template` file under `tools/`, so Task 1's predicate correctly leaves it out of the shell gates.

- [ ] **Step 9: Commit.**

  ```bash
  git add tools/projectmux/defaults.yaml.template tools/projectmux/install.sh tests/projectmux_install.bats
  git commit -m "feat(projectmux): install default configuration under the XDG config root

  The template is rendered once with the configured repository roots and then
  left alone -- an existing defaults.yaml is never overwritten, and drift is
  reported as a warning rather than a failure, because the file is machine-local
  state the user owns.

  The plain-shell window is spelled 'shell: true'. The v1 schema counts window
  modes by presence, and 'command: null' decodes to a nil pointer, which sets
  no mode at all and fails validation."
  ```

---

### Task 7: Vendored user unit, written but never enabled

**Files:**
- Create: `tools/projectmux/projectmux-autostart.service`
- Modify: `tools/projectmux/install.sh` — add `install_unit`
- Test: `tests/projectmux_install.bats`

**Interfaces:**
- Consumes: `publish_file`, `prepare_destination_directory`, `SYSTEMD_USER_DIR`, `UNIT_TEMPLATE`, `SERVICE_UNIT`, `PROJECTMUX_BIN` (all Task 3)
- Produces: `install_unit`

The unit is written and **never** enabled, and `install_unit` must not call `systemctl` at all — no `daemon-reload`, no `enable`, not even a guarded one. This differs deliberately from `tools/dev/install.sh:65-71`, which does enable its unit, and the reason is stated in the unit's own header: the existing `dev-autostart.service` is still installed and enabled on these machines, and two autostart units both attaching a session at login would race. Cutover is a separate, explicit act.

`@PROJECTMUX_BIN@` is substituted with the same sed-metacharacter escaping used at `tools/dev/install.sh:52-54` (`\`, then the `|` delimiter, then `&`), so an install path containing any of those is substituted literally instead of corrupting the unit.

- [ ] **Step 1: Create the unit template.**

  Create `tools/projectmux/projectmux-autostart.service`:

  ```ini
  # Installed by ~/.dotfiles/tools/projectmux/install.sh, which writes this unit
  # but deliberately does NOT enable it or reload the user manager.
  #
  # dev-autostart.service is still installed and enabled on these machines. Two
  # units both attaching a workspace at login would race for the same tmux
  # server, so enabling this one is an explicit, manual cutover step:
  #
  #   systemctl --user disable --now dev-autostart.service
  #   systemctl --user daemon-reload
  #   systemctl --user enable --now projectmux-autostart.service
  [Unit]
  Description=Attach the ProjectMux workspace at login
  After=default.target

  [Service]
  Type=oneshot
  RemainAfterExit=yes
  ExecStart=@PROJECTMUX_BIN@ autostart

  [Install]
  WantedBy=default.target
  ```

- [ ] **Step 2: Write the failing test.**

  Append to `tests/projectmux_install.bats`:

  ```bash
  @test "the user unit is written with the installed binary path" {
    source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_unit
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    local unit="$TEST_ROOT/config/systemd/user/projectmux-autostart.service"
    [ -f "$unit" ]
    [ ! -L "$unit" ]
    grep -Fq "ExecStart=$TEST_ROOT/bin/projectmux autostart" "$unit"
    [[ "$(cat "$unit")" != *"@PROJECTMUX_BIN@"* ]]
  }

  @test "installing the unit never invokes systemctl" {
    # A stub that fails loudly: if install_unit ever grows a daemon-reload or an
    # enable, this test fails instead of the change quietly mutating the user
    # manager on every machine that runs bin/install.
    mkdir -p "$TEST_ROOT/stub-bin"
    printf '#!/usr/bin/env bash\nprintf "systemctl called\\n" >&2\nexit 1\n' \
      >"$TEST_ROOT/stub-bin/systemctl"
    chmod 0755 "$TEST_ROOT/stub-bin/systemctl"

    source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" \
      PATH="$TEST_ROOT/stub-bin:$PATH" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_unit
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" != *"systemctl called"* ]]
  }

  @test "no systemctl invocation exists anywhere in the installer" {
    run rg -n 'systemctl' "$REPO_ROOT/tools/projectmux/install.sh"
    [ "$status" -eq 1 ]
  }

  @test "rewriting an unchanged unit leaves it untouched" {
    source_installer XDG_CONFIG_HOME="$TEST_ROOT/config" bash -c '
      source "$1/tools/projectmux/install.sh"
      install_unit
      install_unit
    ' _ "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ "$(grep -c 'Installed ProjectMux user unit' <<<"$output")" -eq 1 ]
    run bash -c 'compgen -G "$1/.projectmux-autostart.service.*"' \
      _ "$TEST_ROOT/config/systemd/user"
    [ "$status" -eq 1 ]
  }
  ```

- [ ] **Step 3: Run and watch it fail.**

  Run: `bats tests/projectmux_install.bats --filter 'the user unit is written'`

  Expected: FAIL with `install_unit: command not found`. (The third test, the `rg` guard, passes already — it is a regression guard, not a driver.)

- [ ] **Step 4: Add `install_unit`.**

  ```bash
  # The unit is written but deliberately never enabled and the user manager is
  # never reloaded -- see the template's header. Enabling it while
  # dev-autostart.service is still enabled would put two units in a race for the
  # same tmux server at login, so cutover stays a manual, deliberate act.
  install_unit() {
    local escaped_bin
    prepare_destination_directory "$SYSTEMD_USER_DIR"

    # Escape the replacement so an install path containing sed metacharacters
    # (\, &, or the | delimiter) is substituted literally instead of corrupting
    # the unit. Same escaping as tools/dev/install.sh:52-54.
    escaped_bin=${PROJECTMUX_BIN//\\/\\\\}
    escaped_bin=${escaped_bin//|/\\|}
    escaped_bin=${escaped_bin//&/\\&}

    STAGED_UNIT=$(mktemp "$SYSTEMD_USER_DIR/.projectmux-autostart.service.XXXXXX")
    sed "s|@PROJECTMUX_BIN@|$escaped_bin|g" "$UNIT_TEMPLATE" >"$STAGED_UNIT"
    chmod 0644 "$STAGED_UNIT"

    if [[ -f "$SERVICE_UNIT" && ! -L "$SERVICE_UNIT" ]] && cmp -s "$STAGED_UNIT" "$SERVICE_UNIT"; then
      rm -f -- "$STAGED_UNIT"
      STAGED_UNIT=""
      return 0
    fi

    publish_file "$STAGED_UNIT" "$SERVICE_UNIT"
    STAGED_UNIT=""
    log_info "Installed ProjectMux user unit at $SERVICE_UNIT (not enabled)."
  }
  ```

  Note `SYSTEMD_USER_DIR`, `UNIT_TEMPLATE`, and `SERVICE_UNIT` are already declared in Task 3's globals block, and `SYSTEMD_USER_DIR` derives from `XDG_CONFIG_HOME` — which is what lets the test redirect it into a scratch tree.

- [ ] **Step 5: Run the new tests.**

  Run: `bats tests/projectmux_install.bats`
  Expected: all pass.

- [ ] **Step 6: Confirm `main` runs end to end.**

  `main` already calls `install_binary`, `install_config`, and `install_unit` (Task 3), and all three now exist. Verify with the override path, which needs no network:

  ```bash
  TMP=$(mktemp -d)
  printf '#!/usr/bin/env bash\necho local\n' >"$TMP/projectmux"
  chmod 0755 "$TMP/projectmux"
  PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    PROJECTMUX_LOCAL_BINARY="$TMP/projectmux" \
    bash tools/projectmux/install.sh
  ls -l "$TMP/bin/projectmux" "$TMP/state/installed-version" \
    "$TMP/config/projectmux/defaults.yaml" \
    "$TMP/config/systemd/user/projectmux-autostart.service"
  rm -rf -- "$TMP"
  ```

  Expected: all four paths exist, `$TMP/bin/projectmux` is a symlink, and the marker reads `local:$TMP/projectmux`. If `main` fails here, the wiring is wrong — fix it now rather than discovering it in Task 9.

- [ ] **Step 7: Run the gates.**

  ```bash
  /usr/bin/make syntax lint
  ```

  Expected: clean.

- [ ] **Step 8: Commit.**

  ```bash
  git add tools/projectmux/projectmux-autostart.service tools/projectmux/install.sh tests/projectmux_install.bats
  git commit -m "feat(projectmux): write the autostart user unit without enabling it

  dev-autostart.service is still installed and enabled on these machines, and
  two units attaching a workspace at login would race for the same tmux server.
  The unit is written so cutover is a one-command manual step, and the
  installer never calls systemctl -- a test asserts that so it stays true."
  ```

---

### Task 8: Register the phase in `bin/install`

**Files:**
- Modify: `bin/install:196` (one line appended after the `dev` phase)
- Create: `tests/projectmux_phase.bats`

**Interfaces:**
- Consumes: `run_phase` (`bin/common.sh`), `DOTFILES_ROOT` (`bin/install:8`), `tools/projectmux/install.sh` (Tasks 3-7)
- Produces: nothing new — this is the wiring step

The phase is `optional`, matching `dev` on the line above it: a failed ProjectMux install is reported at the end by `finish_phases` but must not abort a first-run install of shell, git, and runtimes. `bin/install` locates itself (`cd "$(dirname "${BASH_SOURCE[0]}")/.."` at `:7`, then `DOTFILES_ROOT=$(pwd -P)` at `:8`), so sourcing it from a test works from any directory.

A new test file is correct rather than extending `tests/install_orchestration.bats`: that file exercises `run_phase`'s own semantics with stub phases and never sources `bin/install`, so its harness cannot answer "is this phase registered."

- [ ] **Step 1: Write the failing registration tests.**

  Create `tests/projectmux_phase.bats`:

  ```bash
  #!/usr/bin/env bats

  load test_helper

  setup() {
    setup_dotfiles_test
  }

  # Sourcing bin/install with INSTALL_SOURCE_ONLY=1 defines main without running
  # it; overriding run_phase turns the phase list into observable output.
  list_phases() {
    run env INSTALL_SOURCE_ONLY=1 bash -c '
      source "$1/bin/install"
      run_phase() { printf "%s %s\n" "$1" "$2"; }
      setup_ai() { :; }
      finish_phases() { :; }
      log_success() { :; }
      OS=Ubuntu
      PROFILE=personal
      main
    ' _ "$REPO_ROOT"
  }

  @test "the projectmux phase is registered" {
    list_phases
    [ "$status" -eq 0 ]
    [[ "$output" == *"projectmux"* ]]
  }

  @test "the projectmux phase is optional" {
    list_phases
    [ "$status" -eq 0 ]
    [[ "$output" == *"optional projectmux"* ]]
  }

  @test "the projectmux phase runs after the dev phase" {
    list_phases
    [ "$status" -eq 0 ]
    local dev_line projectmux_line
    dev_line=$(grep -n 'optional dev$' <<<"$output" | cut -d: -f1)
    projectmux_line=$(grep -n 'optional projectmux$' <<<"$output" | cut -d: -f1)
    [ -n "$dev_line" ]
    [ -n "$projectmux_line" ]
    [ "$projectmux_line" -gt "$dev_line" ]
  }

  @test "the phase points at the installer this repo ships" {
    run rg -n 'run_phase optional projectmux bash "\$DOTFILES_ROOT/tools/projectmux/install\.sh"' \
      "$REPO_ROOT/bin/install"
    [ "$status" -eq 0 ]
    [ -x "$REPO_ROOT/tools/projectmux/install.sh" ]
  }
  ```

- [ ] **Step 2: Run and watch it fail.**

  ```bash
  bats tests/projectmux_phase.bats
  ```

  Expected: 4 tests, 4 failures — no phase named `projectmux` exists yet.

- [ ] **Step 3: Register the phase.**

  In `bin/install`, insert one line immediately after the `dev` phase at `:196`:

  ```bash
    run_phase optional dev bash "$DOTFILES_ROOT/tools/dev/install.sh"
    run_phase optional projectmux bash "$DOTFILES_ROOT/tools/projectmux/install.sh"
    setup_ai
  ```

- [ ] **Step 4: Run the tests.**

  ```bash
  bats tests/projectmux_phase.bats
  ```

  Expected: `4 tests, 0 failures`.

- [ ] **Step 5: Run the whole suite and every gate.**

  ```bash
  /usr/bin/make check
  ```

  Expected: exit 0. In particular `tests/install_orchestration.bats` must still pass — it counts nothing about the phase list, but a syntax error in the inserted line would break every test that sources `bin/install`.

- [ ] **Step 6: Commit.**

  ```bash
  git add bin/install tests/projectmux_phase.bats
  git commit -m "feat(install): run the ProjectMux installer as an optional phase

  Optional, like the dev phase above it: a failed ProjectMux install is
  reported by finish_phases but must not abort a first-run install of shell,
  git, and runtimes."
  ```

---

### Task 9: End-to-end verification against a real binary

**Files:**
- No production files are modified. This task produces a results table in `implementation-notes.md` and the two known-limits paragraphs for the PR description.

**Interfaces:**
- Consumes: everything from Tasks 1-8
- Produces: recorded evidence that the installer was **run**, not merely read

The task prompt is explicit that reading the installer is not verification: "An installer that has never been run is a guess." Every step below executes something. Run them in order against a scratch `HOME`; nothing here may touch the real `~/.local/bin`, the real config root, or the real user manager.

Set up once, and keep `$TMP` for the whole task:

```bash
TMP=$(mktemp -d)
export TMP
```

Tear down at the end with `rm -rf -- "$TMP"`.

- [ ] **Step 1: Build a real binary from the ProjectMux checkout.**

  ```bash
  (cd /home/tng/workspace/projectmux && go build -o "$TMP/projectmux" ./cmd/projectmux)
  "$TMP/projectmux" version
  ```

  Expected: a version string. This is the binary the override path installs — a real one, not a shell stub, so the config it later loads is parsed by the actual v1 loader.

- [ ] **Step 2: Install via the override.**

  ```bash
  PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    PROJECTMUX_LOCAL_BINARY="$TMP/projectmux" \
    bash tools/projectmux/install.sh
  ls -l "$TMP/bin/projectmux"
  cat "$TMP/state/installed-version"
  "$TMP/bin/projectmux" version
  ```

  Expected: `$TMP/bin/projectmux` is a symlink to `$TMP/projectmux`, the marker reads `local:$TMP/projectmux`, and running through the installed path prints the same version as Step 1.

- [ ] **Step 3: Prove the override did not mutate the pin.**

  ```bash
  git diff --exit-code config/versions.env && echo "pin unchanged"
  ```

  Expected: `pin unchanged`. This is requirement §11.3's first half, checked against the working tree rather than inferred.

- [ ] **Step 4: Restore the pin by re-running without the override.**

  ```bash
  PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    bash tools/projectmux/install.sh
  ls -l "$TMP/bin/projectmux"
  cat "$TMP/state/installed-version"
  "$TMP/bin/projectmux" version
  ```

  Expected: the symlink is gone and `$TMP/bin/projectmux` is a regular file; the marker reads `v0.1.0`; the binary prints `v0.1.0`. This downloads the real release over the network and verifies it against the committed digest — the second half of §11.3, and the first end-to-end exercise of `download_verified_artifact` with the real pin.

- [ ] **Step 5: Prove the short-circuit skips the network.**

  ```bash
  mkdir -p "$TMP/shadow"
  printf '#!/usr/bin/env bash\nprintf "curl was called\\n" >&2\nexit 1\n' >"$TMP/shadow/curl"
  chmod 0755 "$TMP/shadow/curl"
  PATH="$TMP/shadow:$PATH" \
    PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    bash tools/projectmux/install.sh
  ```

  Expected: exit 0, an "already installed" line, and **no** `curl was called`. A shadowed `curl` that fails loudly is stronger evidence than timing: if the short-circuit does not fire, the run fails instead of quietly re-downloading.

- [ ] **Step 6: Prove the rendered config is accepted by the real v1 loader.**

  ```bash
  PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" "$TMP/projectmux" config
  ```

  Expected: the loaded configuration prints without error. A non-zero exit here means the template violates the schema — most likely the window-mode rule from Task 6 — and Task 6 must be fixed rather than this step reinterpreted. This is the check that would have caught `command: null`.

- [ ] **Step 7: Prove a hand edit survives.**

  ```bash
  printf '\n# local edit\n' >>"$TMP/config/projectmux/defaults.yaml"
  cp "$TMP/config/projectmux/defaults.yaml" "$TMP/config-before.yaml"
  PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    bash tools/projectmux/install.sh
  /usr/bin/diff "$TMP/config-before.yaml" "$TMP/config/projectmux/defaults.yaml" && echo "config preserved"
  ```

  Expected: a drift warning on stderr, exit 0, `config preserved`, and no diff.

- [ ] **Step 8: Prove the unit is written and nothing was enabled.**

  ```bash
  cat "$TMP/config/systemd/user/projectmux-autostart.service"
  systemctl --user list-unit-files 'projectmux-*' 2>/dev/null || true
  ls -l ~/.config/systemd/user/ | grep -i projectmux || echo "nothing installed in the real user dir"
  ```

  Expected: the scratch unit contains `ExecStart=$TMP/bin/projectmux autostart` with no `@PROJECTMUX_BIN@` left; `list-unit-files` reports no such unit; and the real user directory is untouched.

- [ ] **Step 9: Prove a corrupted digest is rejected, and restore the pin file.**

  This step edits a tracked file. Restore it with `git checkout --` **unconditionally**, including after a failure — `cp`-based restores are unreliable in this shell, and a corrupted `config/versions.env` left behind would be committed.

  ```bash
  /usr/bin/sed -i 's/^PROJECTMUX_LINUX_AMD64_SHA256=.*/PROJECTMUX_LINUX_AMD64_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' config/versions.env
  rm -f "$TMP/bin/projectmux" "$TMP/state/installed-version"
  set +e
  PROJECTMUX_INSTALL_DIR="$TMP/bin" \
    PROJECTMUX_STATE_DIR="$TMP/state" \
    PROJECTMUX_CONFIG_ROOT="$TMP/config/projectmux" \
    XDG_CONFIG_HOME="$TMP/config" \
    bash tools/projectmux/install.sh
  status=$?
  set -e
  git checkout -- config/versions.env
  printf 'exit status: %s\n' "$status"
  ls -l "$TMP/bin/projectmux" 2>&1 || echo "no binary published"
  git diff --exit-code config/versions.env && echo "pin file restored"
  ```

  Expected: non-zero exit, a checksum-mismatch message, `no binary published`, and `pin file restored`. Nothing partial may be left on the destination path — that is requirement §11.2 observed rather than argued.

- [ ] **Step 10: Exercise the three refusals.**

  ```bash
  set +e
  PROJECTMUX_OS=Darwin bash tools/projectmux/install.sh; printf 'darwin -> %s\n' "$?"
  PROJECTMUX_ARCH=riscv64 bash tools/projectmux/install.sh; printf 'riscv -> %s\n' "$?"
  PROJECTMUX_LOCAL_BINARY=relative/path bash tools/projectmux/install.sh; printf 'relative -> %s\n' "$?"
  set -e
  ```

  Expected: all three non-zero, each with its own message ("Linux only", "Unsupported ProjectMux architecture: riscv64", "must be an absolute path"). Each refusal happens in `require_platform` or at the top of `install_local_binary`, before any destination directory is touched — so running these against the real `HOME` is safe. Confirm that: `ls ~/.local/bin/projectmux` must still report no such file (or the file from an earlier real install, unchanged).

- [ ] **Step 11: Confirm every gate actually sees the new files.**

  ```bash
  for class in bash shellcheck shfmt; do
    printf '== %s: ' "$class"
    ./bin/list-check-files "$class" | tr '\0' '\n' | grep -c 'tools/projectmux/install.sh'
  done
  ```

  Expected: `1` for each class. A `0` anywhere means Task 1's discovery fix regressed and the installer is being silently skipped.

- [ ] **Step 12: Run the full gate.**

  ```bash
  /usr/bin/make check
  ```

  Expected: exit 0, with `tests/projectmux_install.bats`, `tests/projectmux_phase.bats`, `tests/check_file_discovery.bats`, and `tests/dependency_pins.bats` all passing.

- [ ] **Step 13: Record the results.**

  Add a table to `implementation-notes.md` with one row per step 2-12: what was run, what was expected, what actually happened. Record any step whose observed behavior differed from the expectation, and what was changed in response. Do not record a step as passing that was not run.

  ```bash
  rm -rf -- "$TMP"
  ```

- [ ] **Step 14: Write the known limits for the PR description.**

  Quote these two verbatim; both are deliberate design outcomes, not defects, and a reviewer should not have to infer them from the diff:

  > **The autostart unit is installed but not enabled.** `dev-autostart.service` remains enabled on these machines, and two units attaching a workspace at login would race for the same tmux server. Cutover is a manual step, documented in the unit's own header.

  > **Nothing migrates existing `~/.local/state/dev` workspace state.** Migration is the application's job, not the installer's. Installing ProjectMux alongside the existing platform is deliberately a no-op for `bin/dev`, `tools/dev/`, and the tmux marker block, none of which this change touches.
