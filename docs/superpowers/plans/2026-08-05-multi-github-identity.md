# Multi-GitHub-Identity Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route git and `gh` to the correct GitHub account automatically, based on who owns the repository's remote, so one machine holds two identities with no global switching.

**Architecture:** A tracked owner map (`core/git/identity-owners`) is the single source of truth for which GitHub owners this machine knows. A shared bash library resolves URL → owner → identity slug. Three consumers read it: a `git` conditional include routes config declaratively, a `bin/gh` PATH shim routes the CLI, and a `pre-push` guard blocks any push whose destination disagrees with the resolved identity. Machine-local identity values live in a gitignored file, so nothing personal is committed to this public repository.

**Tech Stack:** bash, git 2.36+ conditional includes (`includeIf hasconfig:`), GitHub CLI (`gh`), bats for tests, shellcheck + shfmt for lint.

**Spec:** `docs/superpowers/specs/2026-08-05-multi-github-identity-design.md` (approved at commit `e22a66a`).

## Global Constraints

- **This repository is public.** No email addresses, key paths, or account-identifying values in tracked files. Placeholders only. `tests/repository_hygiene.bats` enforces this.
- **Formatting:** all shell must pass `shfmt -d -i 2 -ci` and `shellcheck -x -S warning -e SC1091`. Run `make lint` before every commit.
- **Global hooks must fail open outside their remit.** `core.hooksPath` is global; a hook that errors breaks every repository on the machine. See the existing comment in `core/git/git-hooks.symlink/pre-push`.
- **The pre-push hook must preserve stdin.** Git feeds ref updates to `pre-push` on stdin, and `git lfs pre-push` consumes them. A guard that reads stdin starves LFS.
- **The pre-push hook must preserve the exact `git lfs pre-push` exit status.** It runs last and its status is authoritative.
- **The `gh` shim must resolve symlinks when excluding itself** from the `PATH` scan, or it recurses when invoked through a link.
- **The owner map must be validated, not silently accepted.** Malformed lines and duplicate owners are errors.
- **The owner-map/include consistency test compares owner-and-slug PAIRS**, not slugs alone.
- **Owner map semantics — three states, never two:** absent from map = *unmapped* (fail open); maps to `default` = default identity; maps to a secondary slug = requires `~/.gitconfig.<slug>` and `~/.gh-<slug>`, and if either is absent the state is *known but unprovisioned* (fail closed), never "unmapped".
- **Known-bad test baseline** (pre-existing on `main`, never attribute to this work): `tests/dev_commands.bats`, `tests/dev_config_merge.bats`, `tests/dev_install.bats`, `tests/dev_lifecycle.bats`, `tests/claude_compose_override.bats`. Every other suite must stay green.
- **Test harness:** `load test_helper` then `setup_dotfiles_test`, which sets `HOME="$TEST_ROOT/home"`, `STUB_BIN`, and `PATH="$STUB_BIN:/usr/bin:/bin"`. `git` is `/usr/bin/git` so it remains available. Use `stub_command <name> <body>` for stubs.
- **Root resolution:** all new scripts resolve the repo as `DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"`. Tests override `DOTFILES`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `core/git/identity-owners` | Tracked owner→slug map. Data only. |
| `core/git/identity-lib.sh` | Shared resolution: URL parsing, map load/validate, provisioning checks. Sourced, never executed. |
| `core/git/gitconfig.symlink` | Conditional include + collapsed credential block. |
| `core/git/gitconfig.guarzo.symlink.example` | Tracked template with placeholders. |
| `core/git/gitconfig.guarzo.symlink` | Gitignored, machine-local identity values. Never tracked. |
| `bin/gh` | PATH shim. Routes `GH_CONFIG_DIR`, refuses mixed-owner. |
| `bin/git-identity` | Doctor. Reports resolved identity and provisioning state. |
| `core/git/git-hooks.symlink/pre-push` | Guard, composed before the existing LFS call. |
| `core/shell/bash_profile.symlink` | Bash login `PATH` coverage, chained to `~/.profile`. |
| `tests/git_identity.bats` | Library, routing, shim, guard, doctor tests. |
| `tests/repository_hygiene.bats` | Extended: no real addresses in tracked `.example` files. |

Tasks 1–8 are ordered by dependency. Task 9 (adjacent fixes) and Task 10 (migration) are independent of each other but both depend on 1–8.

---

### Task 1: Owner map and shared resolution library

**Files:**
- Create: `core/git/identity-owners`
- Create: `core/git/identity-lib.sh`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: nothing.
- Produces, all sourced from `core/git/identity-lib.sh`:
  - `identity_url_owner <url>` → prints `<owner>` on stdout for a github.com URL; exit 1 for any non-github.com URL or unparseable input.
  - `identity_load_map [path]` → validates and loads the map into the associative array `IDENTITY_MAP`; exit 1 with a message on stderr for malformed or duplicate entries.
  - `identity_owner_slug <owner>` → prints the slug; exit 1 if unmapped.
  - `identity_slug_configdir <slug>` → prints the `gh` config dir (`$HOME/.config/gh` for `default`, `$HOME/.gh-<slug>` otherwise).
  - `identity_slug_provisioned <slug>` → exit 0 if usable; exit 1 if a secondary slug is missing `~/.gitconfig.<slug>` or its `gh` config dir. `default` is always provisioned.
  - `identity_repo_owners` → prints distinct **mapped** owners across all remotes of the current repo, one per line, sorted.

- [ ] **Step 1: Write the failing test**

Create `tests/git_identity.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  LIB="$REPO_ROOT/core/git/identity-lib.sh"
  MAP="$TEST_ROOT/identity-owners"
  cat >"$MAP" <<'EOF'
# owner slug
gambtho default
guarzo  guarzo
EOF
}

@test "identity_url_owner parses https, ssh, and scp-style github URLs" {
  run bash -c "source '$LIB'; identity_url_owner https://github.com/guarzo/repo.git"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_url_owner ssh://git@github.com/guarzo/repo.git"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_url_owner git@github.com:guarzo/repo.git"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]
}

@test "identity_url_owner rejects non-github hosts" {
  run bash -c "source '$LIB'; identity_url_owner https://gitlab.com/guarzo/repo.git"
  [ "$status" -eq 1 ]

  run bash -c "source '$LIB'; identity_url_owner https://msazure.visualstudio.com/x/_git/y"
  [ "$status" -eq 1 ]
}

@test "identity_load_map rejects a duplicate owner" {
  cat >"$MAP" <<'EOF'
guarzo guarzo
guarzo default
EOF
  run bash -c "source '$LIB'; identity_load_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate owner"* ]]
}

@test "identity_load_map rejects a malformed line" {
  cat >"$MAP" <<'EOF'
guarzo
EOF
  run bash -c "source '$LIB'; identity_load_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]
}

@test "identity_owner_slug maps known owners and rejects unmapped ones" {
  run bash -c "source '$LIB'; identity_load_map '$MAP'; identity_owner_slug guarzo"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_load_map '$MAP'; identity_owner_slug gambtho"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]

  run bash -c "source '$LIB'; identity_load_map '$MAP'; identity_owner_slug kubernetes-sigs"
  [ "$status" -eq 1 ]
}

@test "identity_slug_provisioned distinguishes default, provisioned, and unprovisioned" {
  run bash -c "source '$LIB'; identity_slug_provisioned default"
  [ "$status" -eq 0 ]

  run bash -c "source '$LIB'; identity_slug_provisioned guarzo"
  [ "$status" -eq 1 ]

  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  run bash -c "source '$LIB'; identity_slug_provisioned guarzo"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `core/git/identity-lib.sh` does not exist.

- [ ] **Step 3: Create the owner map**

Create `core/git/identity-owners`:

```
# GitHub owner -> identity slug.
#
# Tracked and non-secret on purpose: this file must state which owners this
# machine knows about INDEPENDENTLY of whether their identity files exist.
# That is what lets consumers tell "unmapped and unrelated" (fail open) apart
# from "known identity but not provisioned" (fail closed).
#
# The default slug uses the standard ~/.config/gh and ~/.gitconfig.local.
# Any other slug requires ~/.gitconfig.<slug> and ~/.gh-<slug>.
#
# Adding an owner here also requires an includeIf block in gitconfig.symlink;
# tests/git_identity.bats asserts the two agree as owner+slug pairs.
gambtho default
guarzo  guarzo
```

- [ ] **Step 4: Write the library**

Create `core/git/identity-lib.sh`:

```bash
#!/usr/bin/env bash
# Shared owner -> identity resolution for bin/gh, bin/git-identity, and the
# pre-push guard. Sourced, never executed.
#
# Every consumer shares these three states, and conflating any two of them
# reintroduces a silent wrong-identity path:
#   unmapped            owner absent from the map      -> out of remit
#   default             owner maps to the default      -> stock gh config
#   secondary           owner maps to another slug     -> may be UNPROVISIONED

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
IDENTITY_MAP_FILE="${IDENTITY_MAP_FILE:-$IDENTITY_DOTFILES_ROOT/core/git/identity-owners}"

declare -gA IDENTITY_MAP

# Print the owner for a github.com URL. Exit 1 for any other host or for input
# that does not parse -- callers treat that as "out of remit", so being strict
# here is what keeps unrelated remotes on the fail-open path.
identity_url_owner() {
  local url="$1" rest host path

  case "$url" in
    https://* | http://*)
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    ssh://*)
      rest="${url#ssh://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      path="${rest#*/}"
      ;;
    *@*:*)
      rest="${url#*@}"
      host="${rest%%:*}"
      path="${rest#*:}"
      ;;
    *)
      return 1
      ;;
  esac

  host="${host%%:*}"
  [ "$host" = "github.com" ] || return 1

  path="${path#/}"
  case "$path" in
    */*) : ;;
    *) return 1 ;;
  esac

  printf '%s\n' "${path%%/*}"
}

# Load and VALIDATE the owner map. A malformed or duplicated entry is an error,
# never a silently skipped line: a dropped entry would demote a known owner to
# "unmapped" and turn a blocked push into a silent wrong-identity push.
identity_load_map() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line owner slug extra lineno=0

  IDENTITY_MAP=()

  if [ ! -r "$file" ]; then
    printf 'identity: owner map not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    # shellcheck disable=SC2086
    set -- $line
    [ "$#" -gt 0 ] || continue
    owner="$1"
    slug="${2:-}"
    extra="${3:-}"

    if [ "$#" -ne 2 ] || [ -n "$extra" ]; then
      printf 'identity: malformed entry at %s:%d\n' "$file" "$lineno" >&2
      return 1
    fi
    case "$owner" in
      [A-Za-z0-9]*) : ;;
      *)
        printf 'identity: malformed entry at %s:%d\n' "$file" "$lineno" >&2
        return 1
        ;;
    esac
    case "$slug" in
      [a-z0-9]*) : ;;
      *)
        printf 'identity: malformed entry at %s:%d\n' "$file" "$lineno" >&2
        return 1
        ;;
    esac
    if [ -n "${IDENTITY_MAP[$owner]:-}" ]; then
      printf 'identity: duplicate owner %s at %s:%d\n' "$owner" "$file" "$lineno" >&2
      return 1
    fi
    IDENTITY_MAP["$owner"]="$slug"
  done <"$file"

  return 0
}

identity_owner_slug() {
  local owner="$1"
  local slug="${IDENTITY_MAP[$owner]:-}"
  [ -n "$slug" ] || return 1
  printf '%s\n' "$slug"
}

identity_slug_configdir() {
  local slug="$1"
  if [ "$slug" = default ]; then
    printf '%s\n' "${GH_DEFAULT_CONFIG_DIR:-$HOME/.config/gh}"
  else
    printf '%s\n' "$HOME/.gh-$slug"
  fi
}

# A secondary slug is provisioned only when BOTH its git include and its gh
# config dir exist. Either alone is a half-configured identity, which looks
# usable to a naive check and then fails at push time.
identity_slug_provisioned() {
  local slug="$1" dir
  [ "$slug" = default ] && return 0
  [ -e "$HOME/.gitconfig.$slug" ] || return 1
  dir="$(identity_slug_configdir "$slug")"
  [ -d "$dir" ] || return 1
  return 0
}

# Distinct MAPPED owners across every remote of the current repo. Unmapped
# owners are omitted, so "guarzo + an unmapped work org" is not mixed-owner.
identity_repo_owners() {
  local url owner slug
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    owner="$(identity_url_owner "$url")" || continue
    slug="$(identity_owner_slug "$owner")" || continue
    printf '%s\n' "$owner"
  done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | cut -d' ' -f2-) | sort -u
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/git_identity.bats`
Expected: PASS, 6 tests.

- [ ] **Step 6: Lint**

Run: `make lint`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add core/git/identity-owners core/git/identity-lib.sh tests/git_identity.bats
git commit -m "feat(git): add tracked owner map and identity resolution library"
```

---

### Task 2: Conditional include and collapsed credential block

**Files:**
- Modify: `core/git/gitconfig.symlink`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: `identity_load_map` from Task 1 (for the pair-consistency test).
- Produces: `~/.gitconfig.guarzo` as the include path for slug `guarzo`.

**Why this is riskiest:** collapsing the credential block changes credential resolution for *every* repository including work. Do it in its own commit and verify before anything else layers on top.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "gitconfig declares exactly one github credential block" {
  run grep -c '^\[credential "https://github.com"\]' "$REPO_ROOT/core/git/gitconfig.symlink"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "owner map and conditional includes agree as owner+slug pairs" {
  # Compare PAIRS, not slugs: a test that only checked slugs would pass while
  # an owner was wired to the wrong include.
  local config="$REPO_ROOT/core/git/gitconfig.symlink"
  local owner slug expected
  while read -r owner slug; do
    [ -n "$owner" ] || continue
    [ "$slug" = default ] && continue
    expected="[includeIf \"hasconfig:remote.*.url:https://github.com/$owner/**\"]"
    run grep -Fq "$expected" "$config"
    [ "$status" -eq 0 ]
    run grep -A1 -F "$expected" "$config"
    [[ "$output" == *"~/.gitconfig.$slug"* ]]
  done < <(grep -v '^[[:space:]]*#' "$REPO_ROOT/core/git/identity-owners" | grep -v '^[[:space:]]*$')
}

@test "every conditional include corresponds to a mapped owner" {
  local config="$REPO_ROOT/core/git/gitconfig.symlink"
  local owner
  while read -r owner; do
    run grep -qE "^$owner[[:space:]]" "$REPO_ROOT/core/git/identity-owners"
    [ "$status" -eq 0 ]
  done < <(sed -n 's|^\[includeIf "hasconfig:remote\.\*\.url:https://github\.com/\([^/]*\)/\*\*"\]$|\1|p' "$config")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — two credential blocks exist and no `includeIf` is present.

- [ ] **Step 3: Collapse the duplicate credential block**

In `core/git/gitconfig.symlink`, delete this block entirely:

```
[credential "https://github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
```

and replace it with one referencing `gh` by name so it resolves through `PATH`
rather than pinning the older apt binary at `/usr/bin/gh`:

```
[credential "https://github.com"]
	helper =
	helper = !gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !gh auth git-credential
```

- [ ] **Step 4: Add the conditional include**

Append to `core/git/gitconfig.symlink`:

```
# Secondary GitHub identity. Routed by remote owner, per
# core/git/identity-owners. The include path is gitignored and machine-local,
# so this block is inert on a machine that has not provisioned it -- git
# silently ignores a missing include file.
#
# hasconfig matches ANY configured remote, not the push target, so a repo with
# remotes owned by two mapped owners resolves ambiguously. That case is not
# routed: the pre-push guard blocks it and bin/gh refuses to run.
[includeIf "hasconfig:remote.*.url:https://github.com/guarzo/**"]
	path = ~/.gitconfig.guarzo
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/git_identity.bats`
Expected: PASS.

- [ ] **Step 6: Verify credential resolution did not break**

Run: `git config --get-all credential.https://github.com.helper`
Expected: exactly one non-empty helper, `!gh auth git-credential`, preceded by the empty reset.

Run: `git -C ~/workspace/headlamp ls-remote --exit-code origin HEAD >/dev/null && echo OK`
Expected: `OK` — an unrelated repository still authenticates.

- [ ] **Step 7: Commit**

```bash
git add core/git/gitconfig.symlink tests/git_identity.bats
git commit -m "fix(git): collapse duplicate github credential block and route guarzo by owner"
```

---

### Task 3: Machine-local identity file and its template

**Files:**
- Create: `core/git/gitconfig.guarzo.symlink.example`
- Modify: `.gitignore`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `core/git/gitconfig.guarzo.symlink` (gitignored, created at provisioning time by Task 8), linking to `~/.gitconfig.guarzo`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "the machine-local guarzo identity file is gitignored" {
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.guarzo.symlink
  [ "$status" -eq 0 ]
}

@test "the guarzo identity template carries placeholders, not real values" {
  local template="$REPO_ROOT/core/git/gitconfig.guarzo.symlink.example"
  [ -f "$template" ]
  run grep -Eq '@(gmail|microsoft|outlook)\.' "$template"
  [ "$status" -ne 0 ]
  run grep -Fq 'GH_CONFIG_DIR=$HOME/.gh-guarzo' "$template"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — neither the ignore rule nor the template exists.

- [ ] **Step 3: Add the ignore rule**

Append to `.gitignore`, beside the existing `core/git/gitconfig.local.symlink` entry:

```
# Machine-local secondary GitHub identity (name, email, signing key). The
# tracked template is core/git/gitconfig.guarzo.symlink.example.
core/git/gitconfig.guarzo.symlink
```

- [ ] **Step 4: Create the template**

Create `core/git/gitconfig.guarzo.symlink.example`:

```
# Copy to core/git/gitconfig.guarzo.symlink and fill in. That file is
# gitignored; this template is tracked and must never contain real values.
#
# signingKey must be an ABSOLUTE path -- git does not expand ~ for this key on
# every platform.
[user]
	name = YOUR_ACCOUNT_NAME
	email = you@example.com
	signingKey = /home/YOUR_USER/.ssh/id_ed25519_guarzo.pub
[credential "https://github.com"]
	helper =
	helper = !GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth git-credential
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/git_identity.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .gitignore core/git/gitconfig.guarzo.symlink.example tests/git_identity.bats
git commit -m "feat(git): add gitignored secondary identity file and tracked template"
```

---

### Task 4: The `gh` PATH shim

**Files:**
- Create: `bin/gh`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: `identity_load_map`, `identity_repo_owners`, `identity_owner_slug`, `identity_slug_configdir`, `identity_slug_provisioned` from Task 1.
- Produces: nothing consumed by later tasks.

**Recursion hazard:** the shim must exclude *itself* from the `PATH` scan by comparing fully resolved paths. Comparing raw paths fails when the shim is reached through a symlink, and it then execs itself forever.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
setup_shim_repo() {
  local dir="$1" url="$2"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  export DOTFILES="$TEST_ROOT/dotfiles"
  mkdir -p "$DOTFILES/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$DOTFILES/core/git/"
  cp "$MAP" "$DOTFILES/core/git/identity-owners"
  stub_command gh-real 'echo "real gh: GH_CONFIG_DIR=[${GH_CONFIG_DIR:-unset}] args=$*"'
  mkdir -p "$STUB_BIN/real"
  mv "$STUB_BIN/gh-real" "$STUB_BIN/real/gh"
  export PATH="$STUB_BIN:$STUB_BIN/real:/usr/bin:/bin"
}

@test "shim routes a guarzo repo to the guarzo gh config dir" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=[$HOME/.gh-guarzo]"* ]]
}

@test "shim delegates unchanged for a default-owner repo" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=[unset]"* ]]
}

@test "shim delegates unchanged outside a repository" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  cd "$TEST_ROOT"
  run "$REPO_ROOT/bin/gh" auth status
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=[unset]"* ]]
}

@test "shim refuses a mixed-owner repo even when the secondary is unprovisioned" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  git -C "$TEST_ROOT/r" remote add upstream https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr merge
  [ "$status" -ne 0 ]
  [[ "$output" == *"mixed"* ]]
  [[ "$output" == *"GH_CONFIG_DIR"* ]]
}

@test "shim does not treat a mapped owner plus an unmapped org as mixed" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  git -C "$TEST_ROOT/r" remote add fork https://github.com/kubernetes-sigs/repo.git
  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=[$HOME/.gh-guarzo]"* ]]
}

@test "shim refuses an unprovisioned guarzo repo and names the missing step" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -ne 0 ]
  [[ "$output" == *"not provisioned"* ]]
}

@test "shim passes through untouched when the caller set GH_CONFIG_DIR" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  git -C "$TEST_ROOT/r" remote add upstream https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  GH_CONFIG_DIR="$HOME/explicit" run "$REPO_ROOT/bin/gh" pr merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"GH_CONFIG_DIR=[$HOME/explicit]"* ]]
}

@test "shim does not recurse when reached through a symlink" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  ln -s "$REPO_ROOT/bin/gh" "$STUB_BIN/gh"
  cd "$TEST_ROOT/r"
  run timeout 10 "$STUB_BIN/gh" pr list
  [ "$status" -eq 0 ]
  [[ "$output" == *"real gh"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `bin/gh` does not exist.

- [ ] **Step 3: Write the shim**

Create `bin/gh` (mode 0755):

```bash
#!/usr/bin/env bash
# PATH shim that routes `gh` to the identity owning the current repository's
# remote. A shell function would reach only interactive zsh; scripts, editors,
# Codex, and Claude Code's bash tool would all silently use the default
# account, which is the exact disagreement this design exists to prevent.
set -euo pipefail

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
# shellcheck source=/dev/null
. "$IDENTITY_DOTFILES_ROOT/core/git/identity-lib.sh"

# Resolve a path through symlinks. Comparing raw paths would fail to recognise
# this script when it is invoked through a link, and the exec below would then
# re-enter this same file forever.
identity_realpath() {
  local target="$1"
  if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f "$target"
    return
  fi
  local dir base
  dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$target")"
  while [ -L "$dir/$base" ]; do
    target="$(readlink "$dir/$base")"
    case "$target" in
      /*) : ;;
      *) target="$dir/$target" ;;
    esac
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "$target")"
  done
  printf '%s/%s\n' "$dir" "$base"
}

find_real_gh() {
  local self entry candidate
  local -a entries
  self="$(identity_realpath "${BASH_SOURCE[0]}")"
  IFS=: read -r -a entries <<<"$PATH"
  for entry in "${entries[@]}"; do
    [ -n "$entry" ] || continue
    candidate="$entry/gh"
    [ -x "$candidate" ] || continue
    [ "$(identity_realpath "$candidate")" = "$self" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

real_gh="$(find_real_gh)" || {
  printf 'gh: no real gh found on PATH\n' >&2
  exit 127
}

# An explicit GH_CONFIG_DIR means the caller has already chosen. Never
# second-guess it -- it is also the documented escape hatch for mixed-owner
# repositories.
if [ -n "${GH_CONFIG_DIR:-}" ]; then
  exec "$real_gh" "$@"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exec "$real_gh" "$@"

identity_load_map || exec "$real_gh" "$@"

mapfile -t owners < <(identity_repo_owners)

if [ "${#owners[@]}" -eq 0 ]; then
  exec "$real_gh" "$@"
fi

if [ "${#owners[@]}" -gt 1 ]; then
  printf 'gh: refusing to run -- this repository has remotes owned by mixed mapped identities: %s\n' "${owners[*]}" >&2
  printf 'gh: re-run with an explicit GH_CONFIG_DIR (and GH_REPO if needed) to choose.\n' >&2
  exit 3
fi

slug="$(identity_owner_slug "${owners[0]}")"

if [ "$slug" = default ]; then
  exec "$real_gh" "$@"
fi

if ! identity_slug_provisioned "$slug"; then
  printf 'gh: identity "%s" is mapped but not provisioned.\n' "$slug" >&2
  printf 'gh: expected %s and %s.\n' "$HOME/.gitconfig.$slug" "$(identity_slug_configdir "$slug")" >&2
  printf 'gh: run bin/git-identity for the remaining steps.\n' >&2
  exit 4
fi

GH_CONFIG_DIR="$(identity_slug_configdir "$slug")"
export GH_CONFIG_DIR
exec "$real_gh" "$@"
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod 755 bin/gh
bats tests/git_identity.bats
```

Expected: PASS.

- [ ] **Step 5: Lint**

Run: `make lint`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add bin/gh tests/git_identity.bats
git commit -m "feat(gh): route gh by remote owner with a recursion-safe PATH shim"
```

---

### Task 5: Bash login PATH coverage

**Files:**
- Create: `core/shell/bash_profile.symlink`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `~/.bash_profile`, placing `~/.dotfiles/bin` ahead of `/usr/local/bin` for bash login shells.

**Why not `profile.symlink`:** `link_file` in `bin/relink` uses `policy=skip` for any destination that is not already a symlink, and `bin/relink` then calls `log_error`, which exits. A `profile.symlink` would collide with the real `~/.profile` and abort relink for *every* managed dotfile. `~/.bash_profile` does not exist on this machine, so it links cleanly. Bash reads `.bash_profile` instead of `.profile` when present, so chaining preserves the existing file.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "bash_profile puts dotfiles/bin ahead of /usr/local/bin in a clean login shell" {
  local profile="$REPO_ROOT/core/shell/bash_profile.symlink"
  [ -f "$profile" ]
  mkdir -p "$HOME/.dotfiles/bin"
  cp "$profile" "$HOME/.bash_profile"
  run env -i HOME="$HOME" /bin/bash -lc 'printf "%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  local dotfiles_pos local_pos
  dotfiles_pos=$(printf '%s' "$output" | tr ':' '\n' | grep -n "^$HOME/.dotfiles/bin$" | head -1 | cut -d: -f1)
  local_pos=$(printf '%s' "$output" | tr ':' '\n' | grep -n '^/usr/local/bin$' | head -1 | cut -d: -f1)
  [ -n "$dotfiles_pos" ]
  [ -z "$local_pos" ] || [ "$dotfiles_pos" -lt "$local_pos" ]
}

@test "bash_profile preserves an existing real ~/.profile" {
  mkdir -p "$HOME/.dotfiles/bin"
  cp "$REPO_ROOT/core/shell/bash_profile.symlink" "$HOME/.bash_profile"
  cat >"$HOME/.profile" <<'EOF'
export EXISTING_PROFILE_RAN=yes
PATH="$HOME/preexisting:$PATH"
EOF
  run env -i HOME="$HOME" /bin/bash -lc 'printf "%s|%s\n" "$EXISTING_PROFILE_RAN" "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == yes\|* ]]
  [[ "$output" == *"$HOME/preexisting"* ]]
}

@test "bash_profile is mapped to ~/.bash_profile by the link mapper" {
  run bash -c "source '$REPO_ROOT/bin/common.sh' >/dev/null 2>&1; managed_link_pairs '$REPO_ROOT' '$HOME' | tr '\0' '\n'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.bash_profile"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `core/shell/bash_profile.symlink` does not exist.

- [ ] **Step 3: Write the file**

Create `core/shell/bash_profile.symlink`:

```bash
# ~/.bash_profile -- managed by dotfiles.
#
# Bash reads this INSTEAD of ~/.profile when it exists, so source ~/.profile
# first to preserve whatever is already there (on a stock Debian/Ubuntu box
# that includes sourcing ~/.bashrc, adding ~/bin and ~/.local/bin, and loading
# the Cargo environment).
#
# Then put the dotfiles bin directory ahead of /usr/local/bin so the bin/gh
# identity shim wins over the real gh for bash login shells too -- without
# this, only zsh and its descendants route gh by owner.

if [ -f "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

case ":$PATH:" in
  *":$HOME/.dotfiles/bin:"*) ;;
  *) PATH="$HOME/.dotfiles/bin:$PATH" ;;
esac
export PATH
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/git_identity.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/shell/bash_profile.symlink tests/git_identity.bats
git commit -m "feat(shell): add bash login profile chaining to ~/.profile for shim PATH"
```

---

### Task 6: Pre-push identity guard

**Files:**
- Modify: `core/git/git-hooks.symlink/pre-push`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: Task 1 library.
- Produces: nothing consumed by later tasks.

**Three constraints that are easy to get wrong:**
1. **stdin** — git feeds ref updates on stdin and `git lfs pre-push` consumes them. The guard must not read stdin at all; it uses only `$1` (remote name) and `$2` (remote URL).
2. **exit status** — `git lfs pre-push "$@"` runs last so its status is the hook's status.
3. **fail-open boundary** — open before the destination is known in remit, closed after.

"Resolved identity matches" is defined explicitly: the repository's effective `user.email` equals the `user.email` that the destination slug's include file sets. If either side is empty or unreadable, the identity is *indeterminate*, which is a fail-closed condition — not a pass.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
setup_guard_repo() {
  export DOTFILES="$TEST_ROOT/dotfiles"
  mkdir -p "$DOTFILES/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$DOTFILES/core/git/"
  cp "$MAP" "$DOTFILES/core/git/identity-owners"
  HOOK="$REPO_ROOT/core/git/git-hooks.symlink/pre-push"
  GUARD_REPO="$TEST_ROOT/g"
  git init -q "$GUARD_REPO"
  stub_command git-lfs 'exit 0'
  stub_command jq 'exit 0'
}

provision_guarzo() {
  cat >"$HOME/.gitconfig.guarzo" <<'EOF'
[user]
	email = guarzo@example.invalid
EOF
  mkdir -p "$HOME/.gh-guarzo"
}

@test "guard fails open for a non-github destination" {
  setup_guard_repo
  cd "$GUARD_REPO"
  run "$HOOK" origin https://gitlab.com/guarzo/repo.git </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard fails open for an unmapped owner" {
  setup_guard_repo
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/kubernetes-sigs/repo.git </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard blocks a guarzo push when the identity is unprovisioned" {
  setup_guard_repo
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"not provisioned"* ]]
}

@test "guard blocks a guarzo push whose resolved identity disagrees" {
  setup_guard_repo
  provision_guarzo
  git -C "$GUARD_REPO" config user.email someone-else@example.invalid
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]
}

@test "guard allows a guarzo push whose resolved identity matches" {
  setup_guard_repo
  provision_guarzo
  git -C "$GUARD_REPO" config user.email guarzo@example.invalid
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard blocks a mapped destination when the identity is indeterminate" {
  setup_guard_repo
  provision_guarzo
  git -C "$GUARD_REPO" config --unset user.email || true
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
}

@test "composed hook preserves a non-zero git-lfs exit status" {
  setup_guard_repo
  provision_guarzo
  git -C "$GUARD_REPO" config user.email guarzo@example.invalid
  stub_command git-lfs 'exit 7'
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -eq 7 ]
}

@test "a rejecting guard never reaches git lfs pre-push" {
  setup_guard_repo
  stub_command git-lfs "echo LFS_RAN >>'$TEST_ROOT/lfs.log'; exit 0"
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  assert_file_absent "$TEST_ROOT/lfs.log"
}

@test "guard leaves stdin intact for git lfs pre-push" {
  setup_guard_repo
  provision_guarzo
  git -C "$GUARD_REPO" config user.email guarzo@example.invalid
  stub_command git-lfs "cat >'$TEST_ROOT/lfs-stdin.txt'; exit 0"
  cd "$GUARD_REPO"
  printf 'refs/heads/main aaa refs/heads/main bbb\n' |
    run "$HOOK" origin https://github.com/guarzo/repo.git
  run cat "$TEST_ROOT/lfs-stdin.txt"
  [[ "$output" == *"refs/heads/main"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — the guard is not present.

- [ ] **Step 3: Rewrite the hook**

Replace `core/git/git-hooks.symlink/pre-push` with:

```bash
#!/usr/bin/env bash
# Global pre-push hook: identity guard, then the stock git-lfs hook.
#
# ORDER IS LOAD-BEARING. `git lfs pre-push` must run LAST because its exit
# status is the hook's exit status; running it first and appending the guard
# would let a passing guard mask a failed LFS upload and push refs whose
# objects never uploaded.
#
# This hook must also never read stdin: git feeds ref updates there and
# `git lfs pre-push` consumes them. The guard uses only $1 (remote name) and
# $2 (remote URL).
#
# FAIL-OPEN BOUNDARY. core.hooksPath is global, so this hook runs for every
# repository on the machine. It exits 0 silently for anything outside its
# remit -- non-github.com hosts and unmapped owners. Once the destination is
# known to belong to a mapped identity, "cannot verify" becomes a blocking
# condition rather than a silent pass.

remote_url="${2:-}"

identity_guard() {
  local url="$1"
  local root owner slug expected actual

  [ -n "$url" ] || return 0

  root="${DOTFILES:-$HOME/.dotfiles}"
  [ -r "$root/core/git/identity-lib.sh" ] || return 0
  # shellcheck source=/dev/null
  . "$root/core/git/identity-lib.sh"

  owner="$(identity_url_owner "$url")" || return 0
  identity_load_map || return 0
  slug="$(identity_owner_slug "$owner")" || return 0

  # Past this point the destination is in remit: fail closed.
  if [ "$slug" = default ]; then
    return 0
  fi

  if ! identity_slug_provisioned "$slug"; then
    printf 'pre-push: BLOCKED -- pushing to %s but identity "%s" is not provisioned.\n' "$owner" "$slug" >&2
    printf 'pre-push: expected %s and %s. Run bin/git-identity.\n' "$HOME/.gitconfig.$slug" "$(identity_slug_configdir "$slug")" >&2
    return 1
  fi

  expected="$(git config --file "$HOME/.gitconfig.$slug" user.email 2>/dev/null || true)"
  actual="$(git config user.email 2>/dev/null || true)"

  if [ -z "$expected" ] || [ -z "$actual" ]; then
    printf 'pre-push: BLOCKED -- cannot determine the identity for %s (expected=%s actual=%s).\n' \
      "$owner" "${expected:-<empty>}" "${actual:-<empty>}" >&2
    return 1
  fi

  if [ "$expected" != "$actual" ]; then
    printf 'pre-push: BLOCKED -- pushing to %s as %s, but identity "%s" is %s.\n' \
      "$owner" "$actual" "$slug" "$expected" >&2
    printf 'pre-push: a repository with remotes under two mapped owners is not routed; see bin/git-identity.\n' >&2
    return 1
  fi

  return 0
}

identity_guard "$remote_url" || exit 1

# Stock git-lfs hook, adapted for a GLOBAL core.hooksPath. git-lfs writes these
# per-repo, where a missing binary really is an error worth `exit 2`. The
# dotfiles point core.hooksPath here for EVERY repo, so that exit code turns any
# machine without git-lfs into one where clone and checkout fail outright --
# including the repos that never touched LFS. Devcontainer images are the common
# case: it breaks lazy.nvim's plugin clones with an error naming LFS, not the
# container. Warn and step aside instead. A genuine LFS repo still checks out,
# just with pointer files, which is the best available outcome without the
# binary -- and far better than no checkout at all.
command -v git-lfs >/dev/null 2>&1 || {
  printf >&2 '%s\n' "git-lfs not found - skipping 'git lfs pre-push'; any LFS files are left as pointers."
  exit 0
}
git lfs pre-push "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/git_identity.bats`
Expected: PASS.

- [ ] **Step 5: Verify the hook did not break unrelated repositories**

Run: `git -C ~/workspace/headlamp push --dry-run origin HEAD 2>&1 | tail -3`
Expected: normal dry-run output, no `pre-push: BLOCKED`.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add core/git/git-hooks.symlink/pre-push tests/git_identity.bats
git commit -m "feat(git): guard pushes against identity mismatch before the LFS hook"
```

---

### Task 7: `bin/git-identity` doctor

**Files:**
- Create: `bin/git-identity`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: Task 1 library.
- Produces: nothing consumed by later tasks.

Exit codes: `0` usable; `2` mixed-owner; `3` mapped but unprovisioned; `4` mapped and provisioned but the token is invalid; `5` guarzo SSH remote (unsupported transport). An unmapped owner is `0` — the default identity working as intended.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "doctor reports the default identity for an unmapped owner" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/kubernetes-sigs/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 0 ]
  [[ "$output" == *"default"* ]]
}

@test "doctor exits 3 for a mapped but unprovisioned identity" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not provisioned"* ]]
}

@test "doctor exits 2 for a mixed-owner repository" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  git -C "$TEST_ROOT/r" remote add upstream https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mixed"* ]]
}

@test "doctor exits 5 for a guarzo ssh remote" {
  setup_shim_repo "$TEST_ROOT/r" git@github.com:guarzo/repo.git
  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 5 ]
  [[ "$output" == *"SSH"* ]]
}

@test "doctor exits 4 when the token is invalid" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  rm -f "$STUB_BIN/real/gh"
  stub_command gh 'echo "token invalid" >&2; exit 1'
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 4 ]
  [[ "$output" == *"token"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `bin/git-identity` does not exist.

- [ ] **Step 3: Write the doctor**

Create `bin/git-identity` (mode 0755):

```bash
#!/usr/bin/env bash
# Report which GitHub identity applies to the current repository, and whether
# it is actually usable. Every failure mode in this design is silent -- a
# missing include, an unmapped remote, an expired token all present as "you are
# quietly the default identity" -- so this turns that into one line.
set -uo pipefail

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
# shellcheck source=/dev/null
. "$IDENTITY_DOTFILES_ROOT/core/git/identity-lib.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'not inside a git repository\n'
  exit 0
fi

if ! identity_load_map; then
  exit 1
fi

mapfile -t owners < <(identity_repo_owners)

if [ "${#owners[@]}" -eq 0 ]; then
  printf 'owner:    <unmapped>\nidentity: default (stock gh config)\n'
  exit 0
fi

if [ "${#owners[@]}" -gt 1 ]; then
  printf 'owner:    %s\n' "${owners[*]}"
  printf 'identity: MIXED -- this repository is not routed.\n'
  printf 'Use an explicit GH_CONFIG_DIR, or remove one remote.\n'
  exit 2
fi

owner="${owners[0]}"
slug="$(identity_owner_slug "$owner")"
printf 'owner:    %s\nidentity: %s\n' "$owner" "$slug"

if [ "$slug" = default ]; then
  printf 'email:    %s\n' "$(git config user.email 2>/dev/null || echo '<unset>')"
  exit 0
fi

if ! identity_slug_provisioned "$slug"; then
  printf 'status:   NOT PROVISIONED\n'
  [ -e "$HOME/.gitconfig.$slug" ] || printf '  missing: %s\n' "$HOME/.gitconfig.$slug"
  [ -d "$(identity_slug_configdir "$slug")" ] || printf '  missing: %s\n' "$(identity_slug_configdir "$slug")"
  exit 3
fi

configdir="$(identity_slug_configdir "$slug")"
printf 'email:    %s\n' "$(git config user.email 2>/dev/null || echo '<unset>')"
printf 'key:      %s\n' "$(git config user.signingKey 2>/dev/null || echo '<unset>')"
printf 'ghconfig: %s\n' "$configdir"

# SSH transport is deliberately unsupported: git never invokes a credential
# helper for it, and user.signingKey does not select an authentication key.
while IFS= read -r url; do
  case "$url" in
    https://*) continue ;;
  esac
  if [ "$(identity_url_owner "$url" 2>/dev/null || true)" = "$owner" ]; then
    printf 'status:   UNSUPPORTED -- SSH remote for a routed identity (%s)\n' "$url"
    printf 'Re-point the remote at its https:// URL.\n'
    exit 5
  fi
done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | cut -d' ' -f2-)

if ! GH_CONFIG_DIR="$configdir" gh auth status >/dev/null 2>&1; then
  printf 'status:   TOKEN INVALID OR MISSING\n'
  printf 'Run: GH_CONFIG_DIR=%s gh auth login\n' "$configdir"
  exit 4
fi

printf 'status:   OK\n'
```

- [ ] **Step 4: Make executable, run tests, lint**

```bash
chmod 755 bin/git-identity
bats tests/git_identity.bats
make lint
```

Expected: PASS, lint clean.

- [ ] **Step 5: Commit**

```bash
git add bin/git-identity tests/git_identity.bats
git commit -m "feat(git): add bin/git-identity to report the resolved identity"
```

---

### Task 8: Provisioning through bootstrap and relink

**Files:**
- Modify: `bin/bootstrap`
- Test: `tests/git_identity.bats`

**Interfaces:**
- Consumes: `core/git/gitconfig.guarzo.symlink.example` from Task 3.
- Produces: `core/git/gitconfig.guarzo.symlink`, linked to `~/.gitconfig.guarzo` by the existing `managed_link_pairs` machinery — no change to `bin/relink` is needed, since `*.symlink` discovery is automatic.

**Non-interactive contract:** `bin/bootstrap --non-interactive` already requires `user.name`/`user.email` to be set beforehand and errors rather than reading stdin (`bin/bootstrap:65`). The secondary identity follows the same rule: **never prompt, never partially create.** Skip unless the file already exists. No new flags.

A half-populated identity file is worse than none — it looks provisioned to the guard and then fails at push time.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "non-interactive bootstrap skips secondary provisioning and reads no stdin" {
  local fake="$TEST_ROOT/dotfiles-boot"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/gitconfig.guarzo.symlink.example" "$fake/core/git/"
  run bash -c "
    set -e
    source '$REPO_ROOT/bin/bootstrap' >/dev/null 2>&1 || true
    NON_INTERACTIVE=true DOTFILES_ROOT='$fake' setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  assert_file_absent "$fake/core/git/gitconfig.guarzo.symlink"
}

@test "non-interactive bootstrap links an already-provisioned identity" {
  local fake="$TEST_ROOT/dotfiles-boot2"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/gitconfig.guarzo.symlink.example" "$fake/core/git/"
  printf '[user]\n\temail = x@example.invalid\n' >"$fake/core/git/gitconfig.guarzo.symlink"
  run bash -c "
    set -e
    source '$REPO_ROOT/bin/bootstrap' >/dev/null 2>&1 || true
    NON_INTERACTIVE=true DOTFILES_ROOT='$fake' setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  [ -f "$fake/core/git/gitconfig.guarzo.symlink" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `setup_secondary_identity` is not defined.

- [ ] **Step 3: Add the function to `bin/bootstrap`**

Add near the existing gitconfig setup, and call it from the same place that sets up `gitconfig.local`:

```bash
# Optional secondary GitHub identity (see core/git/identity-owners).
#
# --non-interactive NEVER prompts and NEVER partially creates this file, the
# same contract bootstrap already enforces for the primary identity. A
# half-populated identity file is worse than none: it looks provisioned to the
# pre-push guard and then fails at push time.
setup_secondary_identity() {
  local template="$DOTFILES_ROOT/core/git/gitconfig.guarzo.symlink.example"
  local target="$DOTFILES_ROOT/core/git/gitconfig.guarzo.symlink"
  local name email keypath reply

  [ -f "$template" ] || return 0

  if [ -f "$target" ]; then
    log_info "Secondary GitHub identity already configured."
    return 0
  fi

  if [ "$NON_INTERACTIVE" = true ]; then
    log_info "Skipping optional secondary GitHub identity (non-interactive)."
    return 0
  fi

  printf 'Configure a secondary GitHub identity? [y/N] '
  read -r reply
  case "$reply" in
    [Yy]*) : ;;
    *) return 0 ;;
  esac

  printf 'Account name: '
  read -r name
  printf 'Account email: '
  read -r email
  printf 'Absolute path to its SSH signing public key: '
  read -r keypath

  if [ -z "$name" ] || [ -z "$email" ] || [ -z "$keypath" ]; then
    log_warning "Incomplete answers; leaving the secondary identity unconfigured."
    return 0
  fi

  sed -e "s|YOUR_ACCOUNT_NAME|$name|" \
    -e "s|you@example.com|$email|" \
    -e "s|/home/YOUR_USER/.ssh/id_ed25519_guarzo.pub|$keypath|" \
    "$template" >"$target"

  log_success "Secondary identity written to $target"
  log_info "Next: GH_CONFIG_DIR=\$HOME/.gh-guarzo gh auth login"
}
```

- [ ] **Step 4: Run tests, lint, and verify relink maps the new files**

```bash
bats tests/git_identity.bats
make lint
bash bin/relink 2>&1 | tail -5
```

Expected: tests PASS, lint clean, relink completes without reporting skipped destinations.

- [ ] **Step 5: Commit**

```bash
git add bin/bootstrap tests/git_identity.bats
git commit -m "feat(bootstrap): provision the optional secondary identity without prompting non-interactively"
```

---

### Task 9: Adjacent fixes

**Files:**
- Modify: `core/git/gitconfig.local.symlink.example`
- Modify: `README.md`
- Modify: `tests/repository_hygiene.bats`
- Delete: `git/gitconfig.local.symlink` (and repoint `~/.gitconfig.local`)

- [ ] **Step 1: Write the failing hygiene test**

Append to `tests/repository_hygiene.bats`:

```bash
@test "tracked git example files carry no real email addresses" {
  # Templates keep illustrative placeholders, so allow only the reserved
  # example domains. Anything else is a personal address in a public repo.
  run bash -c "
    grep -hoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
      '$REPO_ROOT'/core/git/*.example 2>/dev/null |
      grep -vE '@example\.(com|invalid|org)$' || true
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the stale git/ gitconfig.local copy is gone" {
  assert_file_absent "$REPO_ROOT/git/gitconfig.local.symlink"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/repository_hygiene.bats`
Expected: FAIL — the example file contains a real gmail address, and the stale copy exists.

- [ ] **Step 3: Scrub the example**

In `core/git/gitconfig.local.symlink.example`, replace the `[user]` block with:

```
[user]
	name = YOUR_NAME
	email = you@example.com
	# signingkey = YOUR_GPG_KEY_ID
```

Note: this changes `HEAD` only. The address remains in git history and is already public; rewriting history is out of scope.

- [ ] **Step 4: Repoint the machine-local symlink and remove the stale copy**

```bash
cp -a ~/.dotfiles/git/gitconfig.local.symlink ~/.dotfiles/core/git/gitconfig.local.symlink
ln -sfn "$HOME/.dotfiles/core/git/gitconfig.local.symlink" "$HOME/.gitconfig.local"
rm -f ~/.dotfiles/git/gitconfig.local.symlink
git -C ~/.dotfiles rm -r --cached --ignore-unmatch git/ 2>/dev/null || true
```

Verify: `readlink ~/.gitconfig.local` prints the `core/git/` path, and `git config user.email` is unchanged.

- [ ] **Step 5: Replace the README section**

Replace the `## Multiple GitHub Accounts` section (the SSH host-alias recipe) with a description of owner-based routing: the `core/git/identity-owners` map, the gitignored `gitconfig.guarzo.symlink` and its template, `bin/gh`, `bin/git-identity`, the pre-push guard, and the two manual provisioning steps. Add `~/.gitconfig.guarzo` and `~/.bash_profile` to the symlink table. State that SSH transport and mixed-owner repositories are unsupported and detected.

- [ ] **Step 6: Run tests and commit**

```bash
bats tests/repository_hygiene.bats
make lint
git add -A
git commit -m "docs(git): document owner-based identity routing and scrub the example address"
```

---

### Task 10: Migrate the three repositories and verify end to end

**Files:** none in this repository. Operates on `~/workspace/{binderplan,slabledger,yetishopify}`.

**Why this is required, not cleanup:** repo-local config outranks `~/.gitconfig` includes, so these three repositories shadow the new mechanism entirely. Until they are migrated, none of the routing above takes effect for them.

- [ ] **Step 1: Record the current values (reversibility)**

```bash
for repo in binderplan slabledger yetishopify; do
  printf '=== %s ===\n' "$repo"
  git -C "$HOME/workspace/$repo" config --local --get-regexp 'user\.|credential' || true
done | tee /tmp/identity-migration-backup.txt
```

Expected: each repo shows `user.name`, `user.email`, and a credential helper. Keep this file until Step 5 passes.

- [ ] **Step 2: Complete the two manual provisioning steps**

These require the account holder and cannot be scripted:

```bash
GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth login # scopes: repo, workflow
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_guarzo" -C "guarzo signing key"
```

Register `~/.ssh/id_ed25519_guarzo.pub` on the guarzo account **as a signing key** (GitHub keeps authentication and signing keys in separate lists), then append a line for the guarzo email to `~/.ssh/allowed_signers`.

Then create `core/git/gitconfig.guarzo.symlink` from the template with the real values and run `bin/relink`.

Verify: `GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth status` reports a valid token.

- [ ] **Step 3: Strip the repo-local config**

```bash
for repo in binderplan slabledger yetishopify; do
  cd "$HOME/workspace/$repo"
  git config --local --unset-all user.name || true
  git config --local --unset-all user.email || true
  git config --local --unset-all credential.helper || true
  git config --local --unset-all credential.https://github.com.helper || true
done
```

- [ ] **Step 4: Verify each repository resolves correctly from the remote alone**

```bash
for repo in binderplan slabledger yetishopify; do
  printf '=== %s ===\n' "$repo"
  (cd "$HOME/workspace/$repo" && "$HOME/.dotfiles/bin/git-identity")
done
```

Expected: each prints `owner: guarzo`, `identity: guarzo`, `status: OK`, and an email matching the recorded backup.

- [ ] **Step 5: Verify a real push path and the untouched default identity**

```bash
cd "$HOME/workspace/slabledger" && git push --dry-run origin HEAD
cd "$HOME/workspace/headlamp" && "$HOME/.dotfiles/bin/git-identity"
gh auth status
```

Expected: the guarzo dry-run authenticates and is not blocked; `headlamp` reports `<unmapped>` / `default`; `gh auth status` still shows the default account active.

- [ ] **Step 6: Full verification**

```bash
make check 2>&1 | tail -20
```

Expected: no failures outside the known-bad baseline (`dev_commands`, `dev_config_merge`, `dev_install`, `dev_lifecycle`, `claude_compose_override`). Compare the failure count against the 60 recorded on `main`; any increase is a regression from this work.

- [ ] **Step 7: Clean up and commit**

```bash
rm -f /tmp/identity-migration-backup.txt
git -C ~/.dotfiles status --short
```

Expected: clean tree — this task changes no tracked files.

---

## Self-Review

**Spec coverage:** owner map → Task 1; routing + credential collapse → Task 2; machine-local identity + template + gitignore → Task 3; `gh` shim incl. mixed-owner refusal and recursion safety → Task 4; bash login coverage → Task 5; guard incl. LFS composition, stdin, and the fail-open boundary → Task 6; doctor incl. all five exit codes → Task 7; provisioning and the non-interactive contract → Task 8; adjacent fixes and hygiene → Task 9; migration and manual steps → Task 10. No spec section is unimplemented.

**Reviewer constraints:** (1) validation → Task 1 Step 4, tested Step 1; (2) pair comparison → Task 2 Step 1, second test; (3) explicit match definition → Task 6 preamble and implementation, with the indeterminate case tested; (4) stdin and LFS status → Task 6, three dedicated tests; (5) symlink-resolving self-exclusion → Task 4 `identity_realpath`, tested via the symlink test.

**Type consistency:** all five library functions are named identically across Tasks 1, 4, 6, and 7 (`identity_url_owner`, `identity_load_map`, `identity_owner_slug`, `identity_slug_configdir`, `identity_slug_provisioned`, `identity_repo_owners`). The slug `guarzo` and path `~/.gh-guarzo` are consistent throughout.
