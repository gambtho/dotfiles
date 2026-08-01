# Provisioning and Reproducibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Converge Linux machines from curated platform/profile manifests, verify repository-owned downloads, lock Neovim plugins, and load Agency configuration only for the work profile.

**Architecture:** Centralize download and checksum behavior in `bin/common.sh`, then make Linux package installation and auditing consume one composed manifest. Keep third-party repository setup in the work installer, but run it before the composed APT install; pin repository-owned binaries and fonts in `config/versions.env`. Track Lazy's existing lockfile and restore it during routine convergence.

**Tech Stack:** Bash, Bats, APT, curl, sha256sum, jq, Neovim/lazy.nvim, Git

---

### Task 1: Characterize Linux package composition

**Files:**
- Create: `tests/linux_packages.bats`
- Create: `platforms/linux/packages/base_apt`
- Create: `platforms/linux/packages/ubuntu_apt`
- Create: `platforms/linux/packages/wsl_apt`
- Create: `profiles/packages/personal_apt`
- Create: `profiles/packages/work_apt`
- Create: `profiles/packages/server_apt`
- Modify: `bin/install`
- Delete: `platforms/linux/ubuntu_apt`
- Delete: `platforms/linux/wsl_apt`
- Delete: `platforms/linux/server_apt`

- [ ] **Step 1: Add failing composition tests**

Create `tests/linux_packages.bats`. Source `bin/install` with `INSTALL_SOURCE_ONLY=1`, call `compose_apt_packages OS PROFILE`, and assert:

```bash
@test "Ubuntu work composition is sorted and deduplicated" {
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/install"
    OS=Ubuntu PROFILE=work compose_apt_packages
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf "%s\n" "$output" | sort -u)" ]
  [[ "$output" == *$'\ndocker-ce\n'* ]]
}

@test "WSL server composition stays headless" {
  run env INSTALL_SOURCE_ONLY=1 bash -c '
    source "$1/bin/install"
    OS=WSL PROFILE=server compose_apt_packages
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ubuntu-desktop"* ]]
  [[ "$output" != *"docker-ce"* ]]
  [[ "$output" != *"azure-cli"* ]]
}

@test "curated manifests exclude machine snapshot packages" {
  run rg -n 'linux-generic|linux-modules|nvidia|grub|shim-signed|efibootmgr|language-pack|ibus-' \
    "$REPO_ROOT/platforms/linux/packages" "$REPO_ROOT/profiles/packages"
  [ "$status" -eq 1 ]
}
```

Add a matrix loop for `Ubuntu|WSL` × `personal|work|server`, asserting all six combinations return nonempty sorted output and that `mise` and `yq` are absent because they are managed binaries.

- [ ] **Step 2: Verify RED**

Run: `bats tests/linux_packages.bats`

Expected: FAIL because `compose_apt_packages` and the composed manifest directories do not exist.

- [ ] **Step 3: Curate the manifests and implement composition**

Move universal command/build dependencies into `base_apt`; keep only platform necessities in the two platform files; put desktop applications in `personal_apt`, work vendor packages in `work_apt`, and keep `server_apt` empty except for genuinely server-only packages. All files must be sorted and comment-free.

Add to `bin/install`:

```bash
compose_apt_packages() {
  local platform_file profile_file
  case "$OS" in
    Ubuntu) platform_file="$DOTFILES_ROOT/platforms/linux/packages/ubuntu_apt" ;;
    WSL) platform_file="$DOTFILES_ROOT/platforms/linux/packages/wsl_apt" ;;
    *) return 2 ;;
  esac
  profile_file="$DOTFILES_ROOT/profiles/packages/${PROFILE}_apt"
  [[ -f "$profile_file" ]] || return 2
  sort -u "$DOTFILES_ROOT/platforms/linux/packages/base_apt" "$platform_file" "$profile_file"
}
```

Guard `main "$@"` with `[[ ${INSTALL_SOURCE_ONLY:-0} == 1 ]] || main "$@"` so tests can source functions.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/linux_packages.bats && shellcheck -x -S warning -e SC1091 bin/install`

Expected: all package composition tests pass and ShellCheck exits 0.

- [ ] **Step 5: Commit**

```bash
git add bin/install tests/linux_packages.bats platforms/linux profiles/packages
git commit -m "refactor: compose Linux packages by profile"
```

### Task 2: Order repositories, installation, and package audit

**Files:**
- Modify: `bin/install`
- Modify: `work/install.sh`
- Modify: `tests/linux_packages.bats`

- [ ] **Step 1: Add failing orchestration tests**

Stub `sudo`, `apt-mark`, and repository setup calls. Assert work repository setup occurs before the one `apt install` call; all composed packages are arguments to that call; package audit writes sorted unmanaged extras to `tmp/unmanaged-apt-<os>-<profile>.txt`; audit output reports only the count; and an extras-only audit returns success.

Use a log assertion shaped as:

```bash
repo_line=$(grep -n '^repositories$' "$TEST_ROOT/events" | cut -d: -f1)
apt_line=$(grep -n '^apt-install ' "$TEST_ROOT/events" | cut -d: -f1)
[ "$repo_line" -lt "$apt_line" ]
```

- [ ] **Step 2: Verify RED**

Run: `bats tests/linux_packages.bats`

Expected: FAIL because installation still selects one snapshot file and audit emits every extra inline.

- [ ] **Step 3: Implement ordered convergence and summarized audit**

Split `work/install.sh` into sourceable `setup_work_apt_repositories` and post-package tool setup. In `bin/install`, invoke repository setup before composing work packages, read composition with `mapfile`, run one `sudo apt install -y "${apt_packages[@]}"`, then audit using:

```bash
check_unsaved_apt_packages() {
  local audit_file="$DOTFILES_ROOT/tmp/unmanaged-apt-${OS,,}-${PROFILE}.txt"
  local manifest_file
  manifest_file=$(mktemp)
  compose_apt_packages >"$manifest_file"
  mkdir -p "$DOTFILES_ROOT/tmp"
  comm -23 <(apt-mark showmanual | sort -u) "$manifest_file" >"$audit_file"
  log_info "Unmanaged manual APT packages: $(wc -l <"$audit_file" | tr -d ' ') (details: $audit_file)"
  rm -f "$manifest_file"
}
```

Do not remove unmanaged packages and do not fail the optional audit for extras.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/linux_packages.bats tests/install_orchestration.bats`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/install work/install.sh tests/linux_packages.bats
git commit -m "fix: converge curated Linux package manifests"
```

### Task 3: Add verified artifact primitives and canonical pins

**Files:**
- Modify: `bin/common.sh`
- Modify: `config/versions.env`
- Modify: `bin/versions`
- Modify: `tests/install_orchestration.bats`
- Modify: `tests/dependency_pins.bats`

- [ ] **Step 1: Add failing download and pin tests**

Add tests proving every curl issued by `run_remote_installer` and `download_verified_artifact` contains `--connect-timeout 10 --max-time 120 --retry 3`; a wrong checksum returns nonzero without replacing the destination; a correct checksum atomically replaces it; and `bin/versions list` reports mise, yq, win32yank, and all three Nerd Font assets.

```bash
@test "verified download rejects a checksum mismatch without replacing destination" {
  printf 'old\n' >"$HOME/tool"
  stub_command curl 'printf "new\n" >"${@: -1}"'
  run bash -c 'source "$1/bin/common.sh"; download_verified_artifact https://example.test/tool deadbeef "$2"' \
    _ "$REPO_ROOT" "$HOME/tool"
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/tool")" = old ]
}
```

- [ ] **Step 2: Verify RED**

Run: `bats tests/install_orchestration.bats tests/dependency_pins.bats`

Expected: FAIL because bounded curl is not shared, checksum installation does not exist, and pins are absent.

- [ ] **Step 3: Implement bounded verified downloads**

Add `CURL_DOWNLOAD_ARGS=(--fail --show-error --location --connect-timeout 10 --max-time 120 --retry 3)` and:

```bash
download_verified_artifact() {
  local url="$1" expected="$2" destination="$3" temporary actual
  temporary=$(mktemp "${destination}.download.XXXXXX") || return 1
  if ! curl "${CURL_DOWNLOAD_ARGS[@]}" "$url" --output "$temporary"; then rm -f "$temporary"; return 1; fi
  actual=$(sha256sum "$temporary" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    printf 'checksum mismatch for %s: expected %s, got %s\n' "$url" "$expected" "$actual" >&2
    rm -f "$temporary"
    return 1
  fi
  chmod 0755 "$temporary"
  mv -f -- "$temporary" "$destination"
}
```

Use the same array in `run_remote_installer`. Add reviewed version/release/digest variables for mise v2026.7.18, yq v4.45.1, win32yank v0.1.1, and Nerd Fonts v3.4.0 assets to `config/versions.env`. Extend `bin/versions list` with `artifact` records and `check/update` with release-tag checks that update versions only, leaving digest review explicit.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/install_orchestration.bats tests/dependency_pins.bats`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/common.sh config/versions.env bin/versions tests/install_orchestration.bats tests/dependency_pins.bats
git commit -m "feat: verify pinned remote artifacts"
```

### Task 4: Install pinned mise and yq through the shared path

**Files:**
- Modify: `bin/bootstrap`
- Modify: `bin/setup-agent-teams`
- Modify: `tests/install_orchestration.bats`

- [ ] **Step 1: Add failing installer tests**

Source both scripts in test mode, stub architecture to x86_64 and arm64, and assert the selected URL and digest variable match each architecture. Assert bootstrap no longer references undefined `install_mise_ubuntu`, and yq rejects the Python implementation already on PATH.

- [ ] **Step 2: Verify RED**

Run: `bats tests/install_orchestration.bats`

Expected: FAIL because bootstrap calls an undefined function and setup-agent-teams owns unverified yq logic.

- [ ] **Step 3: Implement reusable installers**

Add `install_pinned_mise` and `install_pinned_yq` to `bin/common.sh` or a focused `bin/artifacts` library sourced by both entry points. Map `x86_64` and `aarch64|arm64` to their explicit digest variables, download into a staging path, and install to `${HOME}/.local/bin` for mise and `/usr/local/bin` for the sudo-managed yq path. Replace the dead bootstrap call and the local yq download block; preserve setup-agent-teams prompts and dry-run behavior.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/install_orchestration.bats tests/dependency_pins.bats`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/common.sh bin/bootstrap bin/setup-agent-teams tests/install_orchestration.bats
git commit -m "fix: install pinned bootstrap tools"
```

### Task 5: Replace the moving Nerd Fonts clone

**Files:**
- Modify: `fonts/install.sh`
- Create: `tests/font_install.bats`

- [ ] **Step 1: Add failing atomic font tests**

Assert all three pinned asset URLs are downloaded and verified before `FONT_DIR` changes, a checksum failure preserves an existing managed directory/version record, a matching version performs no download, and a successful version bump replaces the managed directory and writes `installed-version`.

- [ ] **Step 2: Verify RED**

Run: `bats tests/font_install.bats`

Expected: FAIL because the installer clones moving HEAD and has no version record.

- [ ] **Step 3: Implement staged archive installation**

Source `config/versions.env`; create a temporary staging directory; call the shared verified download for `CascadiaMono.zip`, `Hack.zip`, and `Meslo.zip`; unzip each into staging; only after every verification succeeds replace `$HOME/.local/share/fonts/NerdFonts`; write `$FONT_DIR/installed-version`; refresh `fc-cache`; and preserve the existing GNOME default-font update when `gsettings` exists.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/font_install.bats`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add fonts/install.sh tests/font_install.bats
git commit -m "fix: install pinned Nerd Font assets"
```

### Task 6: Track and restore the Neovim graph

**Files:**
- Modify: `.gitignore`
- Create: `config/nvim/lazy-lock.json`
- Modify: `config/nvim/init.lua`
- Modify: `bin/install`
- Modify: `tests/dependency_pins.bats`

- [ ] **Step 1: Add failing lock tests**

Assert the lockfile is tracked, contains a `lazy.nvim.commit`, bootstrap uses `--branch=<that commit>` (or clone followed by checkout of that exact revision), and routine setup invokes `nvim --headless "+Lazy! restore" +qa` without `sync` or `update`.

- [ ] **Step 2: Verify RED**

Run: `bats tests/dependency_pins.bats`

Expected: FAIL because the lockfile is ignored, bootstrap clones `stable`, and convergence runs `sync`.

- [ ] **Step 3: Import and wire the lockfile**

Copy the existing ignored `config/nvim/lazy-lock.json` from the primary checkout into the worktree, remove its ignore rule, set the bootstrap revision to the lockfile's `lazy.nvim` commit `306a05526ada86a7b30af95c5cc81ffba93fef97`, and change routine convergence to `Lazy! restore`.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/dependency_pins.bats && jq -e '.["lazy.nvim"].commit == "306a05526ada86a7b30af95c5cc81ffba93fef97"' config/nvim/lazy-lock.json`

Expected: tests pass and jq exits 0.

- [ ] **Step 5: Commit**

```bash
git add .gitignore config/nvim/init.lua config/nvim/lazy-lock.json bin/install tests/dependency_pins.bats
git commit -m "fix: lock Neovim plugin convergence"
```

### Task 7: Scope Agency PATH to work profiles

**Files:**
- Create: `work/agency.zsh`
- Modify: `core/shell/zshrc.symlink`
- Modify: `tests/shell_loading.bats`

- [ ] **Step 1: Add failing profile tests**

For personal and server profiles, assert PATH lacks `.config/agency/CurrentVersion`. For work, set a non-default HOME, source twice, and assert `$HOME/.config/agency/CurrentVersion` occurs exactly once.

- [ ] **Step 2: Verify RED**

Run: `bats tests/shell_loading.bats`

Expected: FAIL because `.zshrc` hard-codes `/home/tng` for every profile.

- [ ] **Step 3: Move Agency configuration**

Create:

```zsh
[[ -n ${WORK_PROFILE:-} ]] || return
typeset agency_dir="$HOME/.config/agency/CurrentVersion"
if [[ ":$PATH:" != *":$agency_dir:"* ]]; then
  export PATH="$agency_dir:$PATH"
fi
unset agency_dir
```

Remove the Agency managed block from `core/shell/zshrc.symlink`.

- [ ] **Step 4: Verify GREEN**

Run: `bats tests/shell_loading.bats`

Expected: all shell profile tests pass.

- [ ] **Step 5: Commit**

```bash
git add work/agency.zsh core/shell/zshrc.symlink tests/shell_loading.bats
git commit -m "fix: scope Agency configuration to work profiles"
```

### Task 8: Verify provisioning wave

**Files:**
- Modify: none

- [ ] **Step 1: Run focused and complete verification**

```bash
bats tests/linux_packages.bats tests/install_orchestration.bats tests/dependency_pins.bats tests/font_install.bats tests/shell_loading.bats
make check
git diff --check HEAD~7..HEAD
git status --short
```

Expected: all tests and checks pass; only intentional implementation-notes state remains uncommitted if present.
