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
