# Multi-GitHub-Identity Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route git and `gh` to the correct GitHub account automatically, based on who owns the repository's remote, so one machine holds two identities with no global switching.

**Architecture:** A tracked owner map (`core/git/identity-owners`) is the single source of truth for which GitHub owners this machine knows. A shared bash library resolves URL → owner → identity slug, and derives an *identity fingerprint* (author email, signing key, credential routing) for each slug. Three consumers use it: a `git` conditional include routes config declaratively, a `bin/gh` PATH shim routes the CLI, and a `pre-push` guard blocks any push whose destination disagrees with the fingerprint actually in effect. Machine-local identity values live in a gitignored file, so nothing personal is committed to this public repository.

**Tech Stack:** bash 3.2-compatible shell, git 2.36+ conditional includes (`includeIf hasconfig:`), GitHub CLI (`gh`), bats, shellcheck + shfmt.

**Spec:** `docs/superpowers/specs/2026-08-05-multi-github-identity-design.md` (approved at commit `e22a66a`).

## Global Constraints

- **This repository is public.** No email addresses, key paths, or account-identifying values in tracked files. Placeholders only.
- **Bash 3.2 compatibility is mandatory for `bin/` and `core/`.** macOS ships bash 3.2, and `tests/portability.bats` **already fails any `mapfile` under `$REPO_ROOT/bin`**. Therefore: no `mapfile`, no `readarray`, no associative arrays (`declare -A` / `declare -gA`), no `${var^^}`. Indexed arrays and `arr+=()` are fine.
- **Formatting:** all shell must pass `shfmt -d -i 2 -ci` and `shellcheck -x -S warning -e SC1091`. Run `make lint` before every commit.
- **Global hooks must fail open *outside their remit*.** `core.hooksPath` is global; a hook that errors breaks every repository on the machine. Fail-open applies only before the destination is known to be a mapped GitHub owner.
- **Once the destination is a mapped GitHub owner, every uncertainty is fail-CLOSED.** This includes a malformed owner map. A dropped map entry silently demotes a known owner to "unmapped", converting a blocked operation into a wrong-identity operation — so map validation failure must be a hard error in every consumer, never a fallthrough.
- **The pre-push hook must preserve stdin.** Git feeds ref updates there and `git lfs pre-push` consumes them. The guard reads only `$1` (remote name) and `$2` (remote URL).
- **The pre-push hook must preserve the exact `git lfs pre-push` exit status.** It runs last; its status is authoritative.
- **The guard verifies EVERY mapped destination, including `default`.** Checking only non-default destinations leaves the fork case — `origin`=gambtho, `upstream`=guarzo, routing resolved to guarzo — pushing to gambtho under the guarzo identity.
- **Identity comparison covers more than email.** The original incident had correct local emails and the wrong signing key in all three repositories. The fingerprint is author email + signing key + credential routing.
- **The `gh` shim must resolve symlinks when excluding itself** from the `PATH` scan, or it recurses when invoked through a link.
- **Owner map semantics — three states, never two:** absent = *unmapped* (fail open); `default` = default identity; any other slug requires `~/.gitconfig.<slug>` and `~/.gh-<slug>`, and if either is absent the state is *known but unprovisioned* (fail closed), never "unmapped".
- **Repository work and machine migration are separate.** Tasks 1–9 change only tracked files and are verified with `DOTFILES` pointed at the worktree. Task 10 runs **after the branch is integrated into `~/.dotfiles`** and is the only task that mutates machine state. Never run `bin/relink` from the worktree — it would point `$HOME` symlinks at a disposable directory.
- **Known-bad test baseline** (pre-existing on `main`, never attribute to this work): `tests/dev_commands.bats`, `tests/dev_config_merge.bats`, `tests/dev_install.bats`, `tests/dev_lifecycle.bats`, `tests/claude_compose_override.bats`. Every other suite must stay green.
- **Test harness:** `load test_helper` then `setup_dotfiles_test`, which sets `HOME="$TEST_ROOT/home"`, `STUB_BIN`, and `PATH="$STUB_BIN:/usr/bin:/bin"`. `git` is `/usr/bin/git`. Use `stub_command <name> <body>`.
- **Sourcing `bin/bootstrap` in tests requires `BOOTSTRAP_SOURCE_ONLY=1`** (`bin/bootstrap:331`), or the footer runs `main "$@"` — real OS prep, `sudo apt`, symlink installation. Follow `tests/install_orchestration.bats:136`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `core/git/identity-owners` | Tracked owner→slug map. Data only. |
| `core/git/identity-lib.sh` | Shared resolution: URL parsing, map validation, fingerprints. Sourced, never executed. |
| `core/git/gitconfig.symlink` | Conditional include + single credential block. |
| `core/git/gitconfig.guarzo.symlink.example` | Tracked template, placeholders only. |
| `core/git/gitconfig.guarzo.symlink` | Gitignored machine-local identity values. |
| `bin/gh` | PATH shim. Routes `GH_CONFIG_DIR`, refuses mixed-owner and invalid maps. |
| `bin/git-identity` | Doctor. Reports resolved identity and provisioning state. |
| `core/git/git-hooks.symlink/pre-push` | Guard, composed before the existing LFS call. |
| `core/shell/bash_profile.symlink` | Bash login `PATH` coverage, chained to `~/.profile`. |
| `tests/git_identity.bats` | Library, routing, shim, guard, doctor, bootstrap tests. |
| `tests/repository_hygiene.bats` | Extended: no real addresses in tracked `.example` files. |

---

### Task 1: Owner map and shared resolution library

**Files:**
- Create: `core/git/identity-owners`
- Create: `core/git/identity-lib.sh`
- Test: `tests/git_identity.bats`

**Interfaces produced** (all sourced from `core/git/identity-lib.sh`):
- `identity_url_owner <url>` → prints owner for a github.com URL; exit 1 otherwise.
- `identity_validate_map [file]` → exit 0 if well-formed; exit 1 with a message on stderr for malformed or duplicate entries.
- `identity_owner_slug <owner> [file]` → prints slug; exit 1 if unmapped.
- `identity_slugs [file]` → prints every distinct slug, one per line.
- `identity_slug_configdir <slug>` → `$HOME/.config/gh` for `default`, else `$HOME/.gh-<slug>`.
- `identity_slug_configfile <slug>` → `$HOME/.gitconfig.local` for `default`, else `$HOME/.gitconfig.<slug>`.
- `identity_slug_provisioned <slug>` → exit 0 if usable; `default` always is.
- `identity_slug_email <slug>` / `identity_slug_key <slug>` → expected values from that slug's config file.
- `identity_repo_owners` → distinct **mapped** owners across all remotes, sorted.
- `identity_effective_slug` → the slug whose fingerprint matches the repo's effective config, or empty.

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
  export IDENTITY_MAP_FILE="$MAP"
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

@test "identity_validate_map rejects duplicates and malformed lines" {
  printf 'guarzo guarzo\nguarzo default\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate owner"* ]]

  printf 'guarzo\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]

  printf 'a b c\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed"* ]]
}

@test "identity_owner_slug maps known owners and rejects unmapped ones" {
  run bash -c "source '$LIB'; identity_owner_slug guarzo '$MAP'"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_owner_slug gambtho '$MAP'"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]

  run bash -c "source '$LIB'; identity_owner_slug kubernetes-sigs '$MAP'"
  [ "$status" -eq 1 ]
}

@test "identity_slug_provisioned distinguishes default, provisioned, unprovisioned" {
  run bash -c "source '$LIB'; identity_slug_provisioned default"
  [ "$status" -eq 0 ]

  run bash -c "source '$LIB'; identity_slug_provisioned guarzo"
  [ "$status" -eq 1 ]

  touch "$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  run bash -c "source '$LIB'; identity_slug_provisioned guarzo"
  [ "$status" -eq 0 ]
}

@test "library uses no bash-4-only constructs" {
  run grep -nE '(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)|declare -g?A' "$LIB"
  [ "$status" -ne 0 ]
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
# Tracked and non-secret on purpose: this file states which owners this machine
# knows about INDEPENDENTLY of whether their identity files exist. That is what
# lets consumers tell "unmapped and unrelated" (fail open) apart from "known
# identity but not provisioned" (fail closed).
#
# The default slug uses the stock ~/.config/gh and ~/.gitconfig.local. Any other
# slug requires ~/.gitconfig.<slug> and ~/.gh-<slug>.
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
# BASH 3.2 ONLY: macOS ships bash 3.2. No associative arrays, and none of the
# Bash-4-only array-reading builtins.
#
# Three states, and conflating any two reintroduces a silent wrong-identity
# path:
#   unmapped   owner absent from the map   -> out of remit
#   default    owner maps to the default   -> stock gh config
#   secondary  maps to another slug        -> may be UNPROVISIONED

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
IDENTITY_MAP_FILE="${IDENTITY_MAP_FILE:-$IDENTITY_DOTFILES_ROOT/core/git/identity-owners}"

# Print the owner for a github.com URL. Exit 1 for any other host or
# unparseable input; callers treat that as "out of remit".
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

# Validate the map. A malformed or duplicated entry is a hard error, never a
# skipped line: a dropped entry demotes a known owner to "unmapped" and turns a
# blocked push into a silent wrong-identity push.
identity_validate_map() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line owner slug extra rest lineno=0 seen=""

  if [ ! -r "$file" ]; then
    printf 'identity: owner map not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    # Split explicitly rather than relying on unquoted expansion, so the
    # behaviour is identical under `sh`-like IFS settings.
    IFS=$' \t' read -r owner slug extra rest <<<"$line"
    [ -n "$owner" ] || continue

    if [ -z "$slug" ] || [ -n "$extra" ]; then
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
    case " $seen " in
      *" $owner "*)
        printf 'identity: duplicate owner %s at %s:%d\n' "$owner" "$file" "$lineno" >&2
        return 1
        ;;
    esac
    seen="$seen $owner"
  done <"$file"

  return 0
}

identity_owner_slug() {
  local owner="$1" file="${2:-$IDENTITY_MAP_FILE}"
  local line o s extra rest

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    IFS=$' \t' read -r o s extra rest <<<"$line"
    [ -n "$o" ] || continue
    if [ "$o" = "$owner" ]; then
      printf '%s\n' "$s"
      return 0
    fi
  done <"$file"

  return 1
}

# shellcheck disable=SC2120  # callers may pass a map path; the default is used internally
identity_slugs() {
  local file="${1:-$IDENTITY_MAP_FILE}"
  local line o s extra rest

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    IFS=$' \t' read -r o s extra rest <<<"$line"
    [ -n "$s" ] || continue
    printf '%s\n' "$s"
  done <"$file" | sort -u
}

identity_slug_configdir() {
  local slug="$1"
  if [ "$slug" = default ]; then
    printf '%s\n' "${GH_DEFAULT_CONFIG_DIR:-$HOME/.config/gh}"
  else
    printf '%s\n' "$HOME/.gh-$slug"
  fi
}

identity_slug_configfile() {
  local slug="$1"
  if [ "$slug" = default ]; then
    printf '%s\n' "$HOME/.gitconfig.local"
  else
    printf '%s\n' "$HOME/.gitconfig.$slug"
  fi
}

# A secondary slug is provisioned only when BOTH its git include and its gh
# config dir exist. Either alone is a half-configured identity, which looks
# usable to a naive check and then fails at push time.
identity_slug_provisioned() {
  local slug="$1" dir
  [ "$slug" = default ] && return 0
  [ -e "$(identity_slug_configfile "$slug")" ] || return 1
  dir="$(identity_slug_configdir "$slug")"
  [ -d "$dir" ] || return 1
  return 0
}

identity_slug_email() {
  local file
  file="$(identity_slug_configfile "$1")"
  [ -r "$file" ] || return 1
  git config --file "$file" user.email 2>/dev/null
}

identity_slug_key() {
  local file
  file="$(identity_slug_configfile "$1")"
  [ -r "$file" ] || return 1
  git config --file "$file" user.signingKey 2>/dev/null
}

# Distinct MAPPED owners across every remote. Unmapped owners are omitted, so
# "guarzo + an unmapped work org" is not mixed-owner.
identity_repo_owners() {
  local url owner
  git config --get-regexp '^remote\..*\.url$' 2>/dev/null |
    cut -d' ' -f2- |
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      owner="$(identity_url_owner "$url")" || continue
      identity_owner_slug "$owner" >/dev/null 2>&1 || continue
      printf '%s\n' "$owner"
    done | sort -u
}

# Which mapped slug does this repository's EFFECTIVE config actually match?
# Compares author email and signing key -- the original incident had correct
# emails and the wrong signing key in all three repositories, so email alone
# does not identify an identity. Prints nothing when no slug matches.
identity_effective_slug() {
  local eff_email eff_key slug exp_email exp_key
  eff_email="$(git config user.email 2>/dev/null || true)"
  eff_key="$(git config user.signingKey 2>/dev/null || true)"
  [ -n "$eff_email" ] || return 0

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    exp_email="$(identity_slug_email "$slug" 2>/dev/null || true)"
    [ -n "$exp_email" ] || continue
    [ "$exp_email" = "$eff_email" ] || continue
    exp_key="$(identity_slug_key "$slug" 2>/dev/null || true)"
    if [ -n "$exp_key" ] && [ -n "$eff_key" ] && [ "$exp_key" != "$eff_key" ]; then
      continue
    fi
    printf '%s\n' "$slug"
    return 0
  done < <(identity_slugs)

  return 0
}
```

- [ ] **Step 5: Run tests, lint, commit**

```bash
bats tests/git_identity.bats
make lint
git add core/git/identity-owners core/git/identity-lib.sh tests/git_identity.bats
git commit -m "feat(git): add tracked owner map and identity resolution library"
```

Expected: 6 tests PASS, lint clean.

---

### Task 2: Conditional include and single credential block

**Files:**
- Modify: `core/git/gitconfig.symlink`
- Test: `tests/git_identity.bats`

**Scope note:** this task changes only the **tracked** file. The machine-local `~/.gitconfig.local` carries its own GitHub and Gist helper blocks; those are stripped in Task 10, which is the only task permitted to mutate machine state. Verification here is therefore about the tracked file, not the machine's effective config — the end-to-end assertion lives in Task 10 Step 4.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "gitconfig declares exactly one github credential block" {
  run grep -c '^\[credential "https://github.com"\]' "$REPO_ROOT/core/git/gitconfig.symlink"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "tracked gitconfig pins no absolute gh path" {
  run grep -n 'helper = !/.*gh auth git-credential' "$REPO_ROOT/core/git/gitconfig.symlink"
  [ "$status" -ne 0 ]
}

@test "owner map and conditional includes agree as owner+slug pairs" {
  # Compare PAIRS, not slugs: a slug-only check passes while an owner is wired
  # to the wrong include.
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
Expected: FAIL — the file pins `/usr/bin/gh` and has no `includeIf`.

- [ ] **Step 3: Replace the credential blocks**

In `core/git/gitconfig.symlink`, replace:

```
[credential "https://github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper = 
	helper = !/usr/bin/gh auth git-credential
```

with (referencing `gh` by name so it resolves through `PATH` instead of pinning the older apt binary):

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
# Secondary GitHub identity, routed by remote owner per
# core/git/identity-owners. The include path is gitignored and machine-local,
# so this block is inert where it has not been provisioned -- git silently
# ignores a missing include file.
#
# hasconfig matches ANY configured remote, not the push target, so a repo with
# remotes under two mapped owners resolves ambiguously. That case is not
# routed: the pre-push guard blocks it and bin/gh refuses to run.
[includeIf "hasconfig:remote.*.url:https://github.com/guarzo/**"]
	path = ~/.gitconfig.guarzo
```

- [ ] **Step 5: Run tests, lint, commit**

```bash
bats tests/git_identity.bats
make lint
git add core/git/gitconfig.symlink tests/git_identity.bats
git commit -m "fix(git): unpin the gh credential helper and route guarzo by owner"
```

Expected: PASS, lint clean.

---

### Task 3: Machine-local identity file and its template

**Files:**
- Create: `core/git/gitconfig.guarzo.symlink.example`
- Modify: `.gitignore`
- Test: `tests/git_identity.bats`

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

- [ ] **Step 2: Run to verify it fails**

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
# gitignored; this template is tracked and must never hold real values.
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

- [ ] **Step 5: Run tests and commit**

```bash
bats tests/git_identity.bats
git add .gitignore core/git/gitconfig.guarzo.symlink.example tests/git_identity.bats
git commit -m "feat(git): add gitignored secondary identity file and tracked template"
```

---

### Task 4: The `gh` PATH shim

**Files:**
- Create: `bin/gh`
- Test: `tests/git_identity.bats`

**Interfaces consumed:** all Task 1 functions.

**Two hazards:** the shim must exclude *itself* from the `PATH` scan by comparing **resolved** paths, or it execs itself forever. And a map that fails validation must be a hard error once we know we are in a GitHub repository — falling through to the real `gh` would silently use the wrong account.

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
  unset IDENTITY_MAP_FILE
  mkdir -p "$STUB_BIN/real"
  printf '#!/usr/bin/env bash\necho "real gh: GH_CONFIG_DIR=[${GH_CONFIG_DIR:-unset}] args=$*"\n' \
    >"$STUB_BIN/real/gh"
  chmod +x "$STUB_BIN/real/gh"
  export PATH="$STUB_BIN:$STUB_BIN/real:/usr/bin:/bin"
}

provision_guarzo_files() {
  cat >"$HOME/.gitconfig.guarzo" <<'EOF'
[user]
	email = guarzo@example.invalid
	signingKey = /keys/guarzo.pub
EOF
  mkdir -p "$HOME/.gh-guarzo"
}

@test "shim routes a guarzo repo to the guarzo gh config dir" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  provision_guarzo_files
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
}

@test "shim does not treat a mapped owner plus an unmapped org as mixed" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  git -C "$TEST_ROOT/r" remote add fork https://github.com/kubernetes-sigs/repo.git
  provision_guarzo_files
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

@test "shim refuses when the owner map is invalid" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  printf 'guarzo guarzo\nguarzo default\n' >"$DOTFILES/core/git/identity-owners"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate owner"* ]]
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

@test "shim uses no bash-4-only constructs" {
  run grep -nE '(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)|declare -g?A' "$REPO_ROOT/bin/gh"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `bin/gh` does not exist.

- [ ] **Step 3: Write the shim**

Create `bin/gh` (mode 0755):

```bash
#!/usr/bin/env bash
# PATH shim routing `gh` to the identity owning the current repository's
# remote. A shell function would reach only interactive zsh; scripts, editors,
# Codex, and Claude Code's bash tool would all silently use the default
# account -- the exact disagreement this design exists to prevent.
#
# BASH 3.2 ONLY: macOS ships bash 3.2, and tests/portability.bats rejects
# Bash-4-only array builtins anywhere under bin/ -- including in comments,
# since it matches the bare word. Keep that word out of this file.
set -uo pipefail

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
# shellcheck source=/dev/null
. "$IDENTITY_DOTFILES_ROOT/core/git/identity-lib.sh"

# Resolve through symlinks. Comparing raw paths fails to recognise this script
# when invoked through a link, and the exec below then re-enters this file
# forever.
identity_realpath() {
  local target="$1" dir base
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$target"
    return
  fi
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
  local self entry candidate rest="$PATH"
  self="$(identity_realpath "${BASH_SOURCE[0]}")"
  while [ -n "$rest" ]; do
    entry="${rest%%:*}"
    if [ "$entry" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*:}"
    fi
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
# second-guess it -- it is the documented escape hatch for mixed-owner repos.
if [ -n "${GH_CONFIG_DIR:-}" ]; then
  exec "$real_gh" "$@"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exec "$real_gh" "$@"

# Inside a git repository, an unusable map is a hard error. Falling through
# would silently use the default account for a repo that may not be its.
if ! identity_validate_map; then
  printf 'gh: refusing to run -- the owner map is unusable (see above).\n' >&2
  exit 5
fi

owners=""
owner_count=0
while IFS= read -r owner; do
  [ -n "$owner" ] || continue
  owners="$owners $owner"
  owner_count=$((owner_count + 1))
done < <(identity_repo_owners)

if [ "$owner_count" -eq 0 ]; then
  exec "$real_gh" "$@"
fi

if [ "$owner_count" -gt 1 ]; then
  printf 'gh: refusing to run -- remotes under mixed mapped identities:%s\n' "$owners" >&2
  printf 'gh: re-run with an explicit GH_CONFIG_DIR (and GH_REPO if needed).\n' >&2
  exit 3
fi

owner="${owners# }"
slug="$(identity_owner_slug "$owner")"

if [ "$slug" = default ]; then
  exec "$real_gh" "$@"
fi

if ! identity_slug_provisioned "$slug"; then
  printf 'gh: identity "%s" is mapped but not provisioned.\n' "$slug" >&2
  printf 'gh: expected %s and %s.\n' \
    "$(identity_slug_configfile "$slug")" "$(identity_slug_configdir "$slug")" >&2
  printf 'gh: run bin/git-identity for the remaining steps.\n' >&2
  exit 4
fi

GH_CONFIG_DIR="$(identity_slug_configdir "$slug")"
export GH_CONFIG_DIR
exec "$real_gh" "$@"
```

- [ ] **Step 4: Make executable, test, lint, commit**

```bash
chmod 755 bin/gh
bats tests/git_identity.bats
bats tests/portability.bats
make lint
git add bin/gh tests/git_identity.bats
git commit -m "feat(gh): route gh by remote owner with a recursion-safe PATH shim"
```

Expected: PASS including `portability.bats` (no `mapfile` under `bin/`).

---

### Task 5: Bash login PATH coverage

**Files:**
- Create: `core/shell/bash_profile.symlink`
- Test: `tests/git_identity.bats`

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

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — the file does not exist.

- [ ] **Step 3: Write the file**

Create `core/shell/bash_profile.symlink`:

```bash
# ~/.bash_profile -- managed by dotfiles.
#
# Bash reads this INSTEAD of ~/.profile when it exists, so source ~/.profile
# first to preserve whatever is already there (on a stock Debian/Ubuntu box
# that means sourcing ~/.bashrc, adding ~/bin and ~/.local/bin, and loading the
# Cargo environment).
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

- [ ] **Step 4: Test and commit**

```bash
bats tests/git_identity.bats
git add core/shell/bash_profile.symlink tests/git_identity.bats
git commit -m "feat(shell): add bash login profile chaining to ~/.profile for shim PATH"
```

---

### Task 6: Pre-push identity guard

**Files:**
- Modify: `core/git/git-hooks.symlink/pre-push`
- Test: `tests/git_identity.bats`

**The rule, stated exactly.** For a push to a mapped owner, let `dest` be that owner's slug and `eff` be `identity_effective_slug` (the slug whose author email *and* signing key match the repository's effective config).

| `dest` | Condition | Result |
| --- | --- | --- |
| unmapped / non-github | any | allow, silent |
| any | map invalid | **block** |
| non-`default` | unprovisioned | **block** |
| non-`default` | `eff` empty (indeterminate) | **block** |
| non-`default` | `eff` != `dest` | **block** |
| `default` | `eff` is another mapped, provisioned slug | **block** — the fork case |
| `default` | `eff` empty or `default` | allow |
| otherwise | | allow |

The `default` row is why the guard verifies *every* mapped destination. Checking only non-default destinations leaves `origin`=gambtho + `upstream`=guarzo pushing to gambtho under the guarzo identity — the exact case that motivated the guard. It blocks only when the effective identity *positively matches another identity*, so a legitimate per-repo email override on a gambtho repo is not a false positive.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
setup_guard() {
  export DOTFILES="$TEST_ROOT/dotfiles"
  mkdir -p "$DOTFILES/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$DOTFILES/core/git/"
  cp "$MAP" "$DOTFILES/core/git/identity-owners"
  unset IDENTITY_MAP_FILE
  HOOK="$REPO_ROOT/core/git/git-hooks.symlink/pre-push"
  GUARD_REPO="$TEST_ROOT/g"
  git init -q "$GUARD_REPO"
  stub_command git-lfs 'exit 0'
  cat >"$HOME/.gitconfig.local" <<'EOF'
[user]
	email = default@example.invalid
	signingKey = /keys/default.pub
EOF
}

provision_guarzo() {
  cat >"$HOME/.gitconfig.guarzo" <<'EOF'
[user]
	email = guarzo@example.invalid
	signingKey = /keys/guarzo.pub
EOF
  mkdir -p "$HOME/.gh-guarzo"
}

be_guarzo() {
  git -C "$GUARD_REPO" config user.email guarzo@example.invalid
  git -C "$GUARD_REPO" config user.signingKey /keys/guarzo.pub
}

be_default() {
  git -C "$GUARD_REPO" config user.email default@example.invalid
  git -C "$GUARD_REPO" config user.signingKey /keys/default.pub
}

@test "guard fails open for a non-github destination" {
  setup_guard
  cd "$GUARD_REPO"
  run "$HOOK" origin https://gitlab.com/guarzo/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard fails open for an unmapped owner" {
  setup_guard
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/kubernetes-sigs/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard blocks a guarzo push when the identity is unprovisioned" {
  setup_guard
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"not provisioned"* ]]
}

@test "guard blocks a guarzo push made under the default identity" {
  setup_guard
  provision_guarzo
  be_default
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
}

@test "guard allows a guarzo push made under the guarzo identity" {
  setup_guard
  provision_guarzo
  be_guarzo
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard blocks the fork case: pushing to gambtho as guarzo" {
  # origin=gambtho, upstream=guarzo -- hasconfig resolves the repo to guarzo,
  # and the push targets gambtho. This is the case the guard exists for.
  setup_guard
  provision_guarzo
  be_guarzo
  git -C "$GUARD_REPO" remote add upstream https://github.com/guarzo/repo.git
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/gambtho/repo.git </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"gambtho"* ]]
}

@test "guard allows a gambtho push made under the default identity" {
  setup_guard
  provision_guarzo
  be_default
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/gambtho/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard allows a gambtho push with an unrelated per-repo email" {
  # A legitimate override must not be a false positive: it matches no identity.
  setup_guard
  provision_guarzo
  git -C "$GUARD_REPO" config user.email project-specific@example.invalid
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/gambtho/repo.git </dev/null
  [ "$status" -eq 0 ]
}

@test "guard blocks a mapped destination when the identity is indeterminate" {
  setup_guard
  provision_guarzo
  cd "$GUARD_REPO"
  git config --unset user.email || true
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
}

@test "guard blocks a github push when the owner map is invalid" {
  setup_guard
  provision_guarzo
  be_guarzo
  printf 'guarzo guarzo\nguarzo default\n' >"$DOTFILES/core/git/identity-owners"
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
}

@test "composed hook preserves a non-zero git-lfs exit status" {
  setup_guard
  provision_guarzo
  be_guarzo
  stub_command git-lfs 'exit 7'
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -eq 7 ]
}

@test "a rejecting guard never reaches git lfs pre-push" {
  setup_guard
  stub_command git-lfs "echo ran >>'$TEST_ROOT/lfs.log'; exit 0"
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  assert_file_absent "$TEST_ROOT/lfs.log"
}

@test "guard leaves stdin intact for git lfs pre-push" {
  setup_guard
  provision_guarzo
  be_guarzo
  stub_command git-lfs "cat >'$TEST_ROOT/lfs-stdin.txt'; exit 0"
  cd "$GUARD_REPO"
  printf 'refs/heads/main aaa refs/heads/main bbb\n' |
    "$HOOK" origin https://github.com/guarzo/repo.git
  run cat "$TEST_ROOT/lfs-stdin.txt"
  [[ "$output" == *"refs/heads/main"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — no guard present.

- [ ] **Step 3: Rewrite the hook**

Replace `core/git/git-hooks.symlink/pre-push` with:

```bash
#!/usr/bin/env bash
# Global pre-push hook: identity guard, then the stock git-lfs hook.
#
# ORDER IS LOAD-BEARING. `git lfs pre-push` runs LAST because its exit status
# is the hook's exit status; running it first and appending the guard would let
# a passing guard mask a failed LFS upload and push refs whose objects never
# uploaded.
#
# This hook must never read stdin: git feeds ref updates there and
# `git lfs pre-push` consumes them. The guard uses only $1 and $2.
#
# FAIL-OPEN BOUNDARY. core.hooksPath is global, so this runs for every repo on
# the machine. It exits 0 silently for anything outside its remit -- non-github
# hosts and unmapped owners. Once the destination is a mapped owner, every
# uncertainty blocks instead.

remote_url="${2:-}"

identity_guard() {
  local url="$1"
  local root owner dest eff exp_email exp_key eff_email eff_key

  [ -n "$url" ] || return 0

  root="${DOTFILES:-$HOME/.dotfiles}"
  [ -r "$root/core/git/identity-lib.sh" ] || return 0
  # shellcheck source=/dev/null
  . "$root/core/git/identity-lib.sh"

  owner="$(identity_url_owner "$url")" || return 0

  # Past this point the destination is on github.com. An unusable map can no
  # longer be shrugged off: a dropped entry would demote a known owner to
  # "unmapped" and convert a blocked push into a wrong-identity push.
  if ! identity_validate_map; then
    printf 'pre-push: BLOCKED -- the owner map is unusable (see above).\n' >&2
    return 1
  fi

  dest="$(identity_owner_slug "$owner")" || return 0

  if [ "$dest" != default ]; then
    if ! identity_slug_provisioned "$dest"; then
      printf 'pre-push: BLOCKED -- pushing to %s but identity "%s" is not provisioned.\n' "$owner" "$dest" >&2
      printf 'pre-push: expected %s and %s. Run bin/git-identity.\n' \
        "$(identity_slug_configfile "$dest")" "$(identity_slug_configdir "$dest")" >&2
      return 1
    fi

    exp_email="$(identity_slug_email "$dest" 2>/dev/null || true)"
    exp_key="$(identity_slug_key "$dest" 2>/dev/null || true)"
    eff_email="$(git config user.email 2>/dev/null || true)"
    eff_key="$(git config user.signingKey 2>/dev/null || true)"

    if [ -z "$exp_email" ] || [ -z "$eff_email" ]; then
      printf 'pre-push: BLOCKED -- cannot determine the identity for %s.\n' "$owner" >&2
      return 1
    fi
    if [ "$exp_email" != "$eff_email" ]; then
      printf 'pre-push: BLOCKED -- pushing to %s as %s, but identity "%s" is %s.\n' \
        "$owner" "$eff_email" "$dest" "$exp_email" >&2
      return 1
    fi
    if [ -n "$exp_key" ] && [ "$exp_key" != "$eff_key" ]; then
      printf 'pre-push: BLOCKED -- signing key %s does not match identity "%s" (%s).\n' \
        "${eff_key:-<unset>}" "$dest" "$exp_key" >&2
      return 1
    fi
    return 0
  fi

  # Default destination. Block only when the effective identity positively
  # matches ANOTHER provisioned identity -- that is the fork case (origin=
  # default owner, upstream=secondary, routing resolved to the secondary).
  # A merely unusual per-repo email matches nothing and is left alone.
  eff="$(identity_effective_slug)"
  if [ -n "$eff" ] && [ "$eff" != default ]; then
    if identity_slug_provisioned "$eff"; then
      printf 'pre-push: BLOCKED -- pushing to %s, but this repository resolves to identity "%s".\n' \
        "$owner" "$eff" >&2
      printf 'pre-push: a repository with remotes under two mapped owners is not routed; see bin/git-identity.\n' >&2
      return 1
    fi
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

- [ ] **Step 4: Test, lint, commit**

```bash
bats tests/git_identity.bats
make lint
git add core/git/git-hooks.symlink/pre-push tests/git_identity.bats
git commit -m "feat(git): guard pushes against identity mismatch before the LFS hook"
```

---

### Task 7: `bin/git-identity` doctor

**Files:**
- Create: `bin/git-identity`
- Test: `tests/git_identity.bats`

Exit codes: `0` usable; `1` unusable owner map; `2` mixed-owner; `3` mapped but unprovisioned; `4` token invalid; `5` guarzo SSH remote.

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

@test "doctor exits 1 on an invalid owner map" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  printf 'guarzo guarzo\nguarzo default\n' >"$DOTFILES/core/git/identity-owners"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 1 ]
}

@test "doctor exits 3 for a mapped but unprovisioned identity" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 3 ]
  [[ "$output" == *"NOT PROVISIONED"* ]]
}

@test "doctor exits 2 for a mixed-owner repository" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  git -C "$TEST_ROOT/r" remote add upstream https://github.com/guarzo/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MIXED"* ]]
}

@test "doctor exits 5 for a guarzo ssh remote" {
  setup_shim_repo "$TEST_ROOT/r" git@github.com:guarzo/repo.git
  provision_guarzo_files
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 5 ]
  [[ "$output" == *"SSH"* ]]
}

@test "doctor exits 4 when the token is invalid" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/guarzo/repo.git
  provision_guarzo_files
  rm -f "$STUB_BIN/real/gh"
  stub_command gh 'echo "token invalid" >&2; exit 1'
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 4 ]
  [[ "$output" == *"TOKEN"* ]]
}

@test "doctor uses no bash-4-only constructs" {
  run grep -nE '(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)|declare -g?A' "$REPO_ROOT/bin/git-identity"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `bin/git-identity` does not exist.

- [ ] **Step 3: Write the doctor**

Create `bin/git-identity` (mode 0755):

```bash
#!/usr/bin/env bash
# Report which GitHub identity applies to the current repository and whether it
# is usable. Every failure mode in this design is silent -- a missing include,
# an unmapped remote, an expired token all present as "you are quietly the
# default identity" -- so this turns that into one line.
#
# BASH 3.2 ONLY (see core/git/identity-lib.sh).
set -uo pipefail

IDENTITY_DOTFILES_ROOT="${DOTFILES:-$HOME/.dotfiles}"
# shellcheck source=/dev/null
. "$IDENTITY_DOTFILES_ROOT/core/git/identity-lib.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'not inside a git repository\n'
  exit 0
fi

identity_validate_map || exit 1

owners=""
owner_count=0
while IFS= read -r o; do
  [ -n "$o" ] || continue
  owners="$owners $o"
  owner_count=$((owner_count + 1))
done < <(identity_repo_owners)

if [ "$owner_count" -eq 0 ]; then
  printf 'owner:    <unmapped>\nidentity: default (stock gh config)\n'
  exit 0
fi

if [ "$owner_count" -gt 1 ]; then
  printf 'owner:   %s\n' "$owners"
  printf 'identity: MIXED -- this repository is not routed.\n'
  printf 'Use an explicit GH_CONFIG_DIR, or remove one remote.\n'
  exit 2
fi

owner="${owners# }"
slug="$(identity_owner_slug "$owner")"
printf 'owner:    %s\nidentity: %s\n' "$owner" "$slug"

if [ "$slug" = default ]; then
  printf 'email:    %s\n' "$(git config user.email 2>/dev/null || echo '<unset>')"
  exit 0
fi

if ! identity_slug_provisioned "$slug"; then
  printf 'status:   NOT PROVISIONED\n'
  [ -e "$(identity_slug_configfile "$slug")" ] ||
    printf '  missing: %s\n' "$(identity_slug_configfile "$slug")"
  [ -d "$(identity_slug_configdir "$slug")" ] ||
    printf '  missing: %s\n' "$(identity_slug_configdir "$slug")"
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

- [ ] **Step 4: Make executable, test, lint, commit**

```bash
chmod 755 bin/git-identity
bats tests/git_identity.bats
bats tests/portability.bats
make lint
git add bin/git-identity tests/git_identity.bats
git commit -m "feat(git): add bin/git-identity to report the resolved identity"
```

---

### Task 8: Provisioning through bootstrap

**Files:**
- Modify: `bin/bootstrap`
- Test: `tests/git_identity.bats`

`*.symlink` discovery is automatic, so `bin/relink` needs no change: `managed_link_pairs` maps the new file to `~/.gitconfig.guarzo` once it exists.

**Non-interactive contract:** `--non-interactive` already requires `user.name`/`user.email` beforehand and errors rather than reading stdin (`bin/bootstrap:65`). The secondary identity follows the same rule: **never prompt, never partially create.** Skip unless the file already exists. No new flags. A half-populated identity file is worse than none — it looks provisioned to the guard and then fails at push time.

- [ ] **Step 1: Write the failing tests**

Append to `tests/git_identity.bats`:

```bash
@test "non-interactive bootstrap skips secondary provisioning and reads no stdin" {
  local fake="$TEST_ROOT/boot1"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/gitconfig.guarzo.symlink.example" "$fake/core/git/"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=true
    DOTFILES_ROOT='$fake'
    setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  assert_file_absent "$fake/core/git/gitconfig.guarzo.symlink"
}

@test "non-interactive bootstrap leaves an already-provisioned identity for relink" {
  local fake="$TEST_ROOT/boot2"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/gitconfig.guarzo.symlink.example" "$fake/core/git/"
  printf '[user]\n\temail = x@example.invalid\n' >"$fake/core/git/gitconfig.guarzo.symlink"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=true
    DOTFILES_ROOT='$fake'
    setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
  run grep -c 'x@example.invalid' "$fake/core/git/gitconfig.guarzo.symlink"
  [ "$output" -eq 1 ]
  run bash -c "source '$REPO_ROOT/bin/common.sh' >/dev/null 2>&1; managed_link_pairs '$fake' '$HOME' | tr '\0' '\n'"
  [[ "$output" == *"$HOME/.gitconfig.guarzo"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/git_identity.bats`
Expected: FAIL — `setup_secondary_identity` is not defined.

- [ ] **Step 3: Add the function to `bin/bootstrap`**

Define it beside the existing gitconfig setup, and call it from the same place:

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

  if [ "${NON_INTERACTIVE:-false}" = true ]; then
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

- [ ] **Step 4: Test, lint, commit**

```bash
bats tests/git_identity.bats
make lint
git add bin/bootstrap tests/git_identity.bats
git commit -m "feat(bootstrap): provision the optional secondary identity without prompting non-interactively"
```

**Do not run `bin/relink` from the worktree.** It would repoint `$HOME` symlinks at a disposable directory. Linking is verified in Task 10 from the canonical checkout.

---

### Task 9: Documentation and hygiene

**Files:**
- Modify: `core/git/gitconfig.local.symlink.example`
- Modify: `README.md`
- Modify: `tests/repository_hygiene.bats`

Note: the stale `git/gitconfig.local.symlink` is an **untracked** file that exists only in the primary checkout, not in this worktree. It cannot be asserted on from here, and removing it is machine state — so it moves to Task 10. What *can* be asserted here is that nothing under `git/` is tracked.

- [ ] **Step 1: Write the failing tests**

Append to `tests/repository_hygiene.bats`:

```bash
@test "tracked git example files carry no real email addresses" {
  # Templates keep illustrative placeholders, so allow only reserved example
  # domains. Anything else is a personal address in a public repo.
  run bash -c "
    grep -hoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
      '$REPO_ROOT'/core/git/*.example 2>/dev/null |
      grep -vE '@example\.(com|invalid|org)\$' || true
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the public repository tracks nothing under git/" {
  run git -C "$REPO_ROOT" ls-files git/
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/repository_hygiene.bats`
Expected: FAIL on the first test — the example file contains a real gmail address.

- [ ] **Step 3: Scrub the example**

In `core/git/gitconfig.local.symlink.example`, replace the `[user]` block with:

```
[user]
	name = YOUR_NAME
	email = you@example.com
	# signingkey = YOUR_GPG_KEY_ID
```

This changes `HEAD` only; the address remains in history and is already public. Rewriting history is out of scope.

- [ ] **Step 4: Replace the README section**

Replace `## Multiple GitHub Accounts` (the SSH host-alias recipe) with owner-based routing: the `core/git/identity-owners` map, the gitignored `gitconfig.guarzo.symlink` and its template, `bin/gh`, `bin/git-identity`, the pre-push guard, and the two manual provisioning steps. Add `~/.gitconfig.guarzo` and `~/.bash_profile` to the symlink table. State that SSH transport and mixed-owner repositories are unsupported and detected.

- [ ] **Step 5: Test and commit**

```bash
bats tests/repository_hygiene.bats
make lint
git add -A
git commit -m "docs(git): document owner-based identity routing and scrub the example address"
```

- [ ] **Step 6: Full suite before integration**

```bash
make check 2>&1 | tail -20
```

Expected: no failures outside the known-bad baseline. Compare the count against the 60 recorded on `main`; any increase is a regression.

---

### Task 10: Integrate, then migrate the machine

**This is the only task that mutates machine state, and it runs from `~/.dotfiles` after the branch is integrated.** Everything above changed tracked files only. Running these steps from the worktree would point `$HOME` symlinks at a disposable directory and invoke a `bin/git-identity` that the canonical checkout does not yet have.

- [ ] **Step 1: Integrate the branch**

```bash
cd ~/.dotfiles
git merge --no-ff worktree-multi-github-identity
git log --oneline -1
```

Verify `~/.dotfiles/bin/git-identity` and `~/.dotfiles/core/git/identity-lib.sh` now exist.

- [ ] **Step 2: Record current machine state (reversibility)**

```bash
{
  for repo in binderplan slabledger yetishopify; do
    printf '=== %s ===\n' "$repo"
    git -C "$HOME/workspace/$repo" config --local --get-regexp 'user\.|credential' || true
  done
  printf '=== gitconfig.local ===\n'
  cat "$HOME/.gitconfig.local"
  printf '=== effective helper ===\n'
  git config --includes --show-origin --get-all credential.https://github.com.helper
} | tee /tmp/identity-migration-backup.txt
```

Keep this file until Step 8 passes.

- [ ] **Step 3: Complete the two manual provisioning steps**

```bash
GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth login # scopes: repo, workflow
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_guarzo" -C "guarzo signing key"
```

Register `~/.ssh/id_ed25519_guarzo.pub` on the guarzo account **as a signing key** (GitHub keeps authentication and signing keys in separate lists), then append a line for the guarzo email to `~/.ssh/allowed_signers`.

Create `~/.dotfiles/core/git/gitconfig.guarzo.symlink` from the template with the real values.

Verify: `GH_CONFIG_DIR=$HOME/.gh-guarzo gh auth status` reports a valid token.

- [ ] **Step 4: Finish the credential collapse in the machine-local file**

Task 2 fixed the tracked file; `~/.gitconfig.local` still declares its own GitHub and Gist helper blocks, whose trailing reset discards the tracked one.

```bash
cp -a "$HOME/.dotfiles/git/gitconfig.local.symlink" "$HOME/.dotfiles/core/git/gitconfig.local.symlink"
ln -sfn "$HOME/.dotfiles/core/git/gitconfig.local.symlink" "$HOME/.gitconfig.local"
rm -f "$HOME/.dotfiles/git/gitconfig.local.symlink"
```

Then delete the `[credential "https://github.com"]` and `[credential "https://gist.github.com"]` sections from `~/.dotfiles/core/git/gitconfig.local.symlink`, leaving the tracked block as the only source.

Verify the complete ordered result, not a block count:

```bash
git config --includes --show-origin --get-all credential.https://github.com.helper
```

Expected: exactly two entries from `core/git/gitconfig.symlink` — one empty reset, then `!gh auth git-credential`. No entry originating from `.gitconfig.local`, and no absolute `/usr/bin/gh` or `/usr/local/bin/gh` path.

- [ ] **Step 5: Link the new files**

```bash
cd ~/.dotfiles && bash bin/relink 2>&1 | tail -5
readlink "$HOME/.gitconfig.guarzo"
readlink "$HOME/.bash_profile"
```

Expected: relink completes with no skipped destinations; both symlinks resolve into `~/.dotfiles`.

- [ ] **Step 6: Strip the repo-local overrides**

```bash
for repo in binderplan slabledger yetishopify; do
  cd "$HOME/workspace/$repo"
  git config --local --unset-all user.name || true
  git config --local --unset-all user.email || true
  git config --local --unset-all credential.helper || true
  git config --local --unset-all credential.https://github.com.helper || true
done
```

- [ ] **Step 7: Verify routing, the guard, and the untouched default**

```bash
for repo in binderplan slabledger yetishopify; do
  printf '=== %s ===\n' "$repo"
  (cd "$HOME/workspace/$repo" && git-identity)
done
cd "$HOME/workspace/slabledger" && git push --dry-run origin HEAD
cd "$HOME/workspace/headlamp" && git-identity && git push --dry-run origin HEAD
gh auth status
```

Expected: each guarzo repo reports `owner: guarzo`, `identity: guarzo`, `status: OK`, with the email from the Step 2 backup; the guarzo dry-run authenticates and is not blocked; `headlamp` reports `<unmapped>` / `default` and its dry-run is unaffected; `gh auth status` still shows the default account active.

- [ ] **Step 8: Full verification and cleanup**

```bash
cd ~/.dotfiles && make check 2>&1 | tail -20
git status --short
rm -f /tmp/identity-migration-backup.txt
```

Expected: no failures outside the known-bad baseline; clean tree.

---

## Self-Review

**Spec coverage:** owner map → Task 1; routing + credential unpinning → Task 2 (tracked) and Task 10 Step 4 (machine-local); identity file + template + gitignore → Task 3; shim incl. mixed-owner and invalid-map refusal → Task 4; bash login coverage → Task 5; guard incl. LFS composition, stdin, and both fail directions → Task 6; doctor with six exit codes → Task 7; provisioning contract → Task 8; docs and hygiene → Task 9; integration and migration → Task 10.

**Review findings addressed:** default-destination guard hole → Task 6 rule table plus the fork-case and false-positive tests; identity comparison beyond email → `identity_effective_slug` compares email *and* signing key, with an explicit signing-key check for secondary destinations; invalid map failing open → hard error in shim, guard, and doctor, each with a test; bootstrap side effects → `env BOOTSTRAP_SOURCE_ONLY=1` per `tests/install_orchestration.bats:136`, and the second test now asserts linking; incomplete credential collapse → Task 10 Step 4 strips the machine-local blocks and verifies with `git config --includes --show-origin --get-all`; bash 3.2 → no `mapfile`/`readarray`/associative arrays, with a grep test per script and `tests/portability.bats` run in Tasks 4 and 7; worktree/checkout mixing → Tasks 1–9 are repo-only, Task 10 runs post-integration from `~/.dotfiles`, and the unassertable stale-file test is replaced by a tracked-files assertion.

**Type consistency:** every library function name is identical across Tasks 1, 4, 6, and 7 (`identity_url_owner`, `identity_validate_map`, `identity_owner_slug`, `identity_slugs`, `identity_slug_configdir`, `identity_slug_configfile`, `identity_slug_provisioned`, `identity_slug_email`, `identity_slug_key`, `identity_repo_owners`, `identity_effective_slug`). `identity_load_map` from the previous revision is gone entirely, replaced by `identity_validate_map`.
