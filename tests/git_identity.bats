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

@test "identity_owner_slug case-folds the owner before lookup" {
  run bash -c "source '$LIB'; identity_owner_slug Guarzo '$MAP'"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_owner_slug GUARZO '$MAP'"
  [ "$status" -eq 0 ]
  [ "$output" = "guarzo" ]

  run bash -c "source '$LIB'; identity_owner_slug GaMbThO '$MAP'"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
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

@test "generated routes agree with the ACTIVE map as owner+slug pairs" {
  # Assert each owner and its path as ONE adjacent block. Checking the two lines
  # independently would pass on crossed routes -- owner A pointing at slug B's
  # file and vice versa -- which is the same blind spot that made the previous
  # version of this test compare only tracked-against-tracked.
  setup_routes
  printf 'guarzo default\ngambtho gambtho\nacme    acme\n' >"$DOTFILES/core/git/identity-owners.local"
  local routes owner slug block
  routes="$(render_routes)"
  while read -r owner slug; do
    [ -n "$owner" ] || continue
    if [ "$slug" = default ]; then
      [[ "$routes" != *"github.com/$owner/"* ]]
      continue
    fi
    block="$(printf '[includeIf "hasconfig:remote.*.url:https://github.com/%s/**"]\n\tpath = ~/.gitconfig.%s' "$owner" "$slug")"
    [[ "$routes" == *"$block"* ]]
  done < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES/core/git/identity-owners.local")
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

@test "the secondary identity template carries placeholders, not real values" {
  local template="$REPO_ROOT/core/git/gitconfig.secondary.symlink.example"
  [ -f "$template" ]
  run grep -Eq '@(gmail|microsoft|outlook)\.' "$template"
  [ "$status" -ne 0 ]
  run grep -Fq 'GH_CONFIG_DIR=$HOME/.gh-IDENTITY_SLUG' "$template"
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

@test "shim fails closed with a clear message when the identity library is missing" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/gambtho/repo.git
  rm -f "$DOTFILES/core/git/identity-lib.sh"
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/gh" pr list
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity library not found"* ]]
  [[ "$output" != *": No such file or directory"* ]]
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

@test "guard blocks a mixed-case owner push made under the default identity" {
  # GitHub owner names are case-insensitive, so a clone of Guarzo/repo is
  # ordinary. Git's own hasconfig matching is case-sensitive and won't fire,
  # so the repo's effective identity stays default -- but the guard must
  # still recognise the destination as the guarzo identity and block, not
  # silently allow a push under the wrong account.
  setup_guard
  provision_guarzo
  be_default
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/Guarzo/repo.git </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Guarzo"* ]]
  [[ "$output" == *"guarzo"* ]]
}

@test "guard still fails open for an unmapped owner in mixed case" {
  # Case-folding the lookup must not widen the guard's remit to owners that
  # were never mapped in the first place.
  setup_guard
  cd "$GUARD_REPO"
  run "$HOOK" origin https://github.com/Kubernetes-SIGS/repo.git </dev/null
  [ "$status" -eq 0 ]
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
  setup_sec_boot old50 'guarzo default\ngambtho gambtho\n'
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=true
    DOTFILES_ROOT='$SECBOOT'
    setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  assert_file_absent "$SECBOOT/core/git/gitconfig.gambtho.symlink"
}

@test "non-interactive bootstrap leaves an already-provisioned identity for relink" {
  setup_sec_boot old51 'guarzo default\ngambtho gambtho\n'
  printf '[user]\n\temail = x@example.invalid\n' >"$SECBOOT/core/git/gitconfig.gambtho.symlink"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=true
    DOTFILES_ROOT='$SECBOOT'
    setup_secondary_identity
  " </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
  run grep -c 'x@example.invalid' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "identity_validate_map rejects a non-canonical uppercase owner" {
  # An uppercase owner parses fine but can never match, because
  # identity_owner_slug folds the lookup key -- a silent misconfiguration.
  printf 'Guarzo guarzo\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "identity_validate_map rejects a slug containing a path separator" {
  # Slugs become path components in ~/.gitconfig.<slug> and ~/.gh-<slug>.
  printf 'evil a/../../tmp/pwned\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"slug"* ]]

  printf 'evil ../escape\n' >"$MAP"
  run bash -c "source '$LIB'; identity_validate_map '$MAP'"
  [ "$status" -eq 1 ]
}

@test "the shipped owner map passes its own validation" {
  run bash -c "source '$LIB'; identity_validate_map '$REPO_ROOT/core/git/identity-owners'"
  [ "$status" -eq 0 ]
}

@test "the primary gitconfig template uses the tokens bootstrap substitutes" {
  # setup_gitconfig substitutes AUTHORNAME/AUTHOREMAIL; any other placeholder is
  # copied through literally and every commit is authored as it.
  local template="$REPO_ROOT/core/git/gitconfig.local.symlink.example"
  run grep -Fq 'AUTHORNAME' "$template"
  [ "$status" -eq 0 ]
  run grep -Fq 'AUTHOREMAIL' "$template"
  [ "$status" -eq 0 ]
  run bash -c "sed -e 's|AUTHORNAME|Real Name|g' -e 's|AUTHOREMAIL|real@example.invalid|g' '$template' | grep -cE 'AUTHORNAME|AUTHOREMAIL|YOUR_NAME'"
  [ "$output" -eq 0 ]
}

@test "secondary identity provisioning rejects a relative signing key path" {
  setup_sec_boot old56 'guarzo default\ngambtho gambtho\n'
  run_sec_setup 'y\nName\nuser@example.invalid\nrelative/key.pub\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"absolute"* ]]
  assert_file_absent "$SECBOOT/core/git/gitconfig.gambtho.symlink"
}

@test "secondary identity provisioning escapes sed metacharacters in answers" {
  setup_sec_boot old57 'guarzo default\ngambtho gambtho\n'
  # Inline rather than via run_sec_setup: the & | and backslash survive fewer
  # quoting layers this way, so the test exercises the escaping and not the
  # harness.
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=false
    DOTFILES_ROOT='$SECBOOT'
    printf 'y\nA&B|C\\\\D\nuser@example.invalid\n/abs/k&y.pub\n' | setup_secondary_identity
  "
  [ "$status" -eq 0 ]
  run grep -Fq 'A&B|C\D' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$status" -eq 0 ]
  run grep -Fq '/abs/k&y.pub' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$status" -eq 0 ]
}

@test "secondary identity render is atomic and leaves no partial file" {
  setup_sec_boot old58 'guarzo default\ngambtho gambtho\n'
  chmod a-w "$SECBOOT/core/git"
  run_sec_setup 'y\nName\nuser@example.invalid\n/abs/key.pub\n'
  chmod u+w "$SECBOOT/core/git"
  [ "$status" -eq 0 ]
  assert_file_absent "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  run bash -c "ls -A '$SECBOOT/core/git' | grep -c '^[.]gitconfig[.]'"
  [ "$output" -eq 0 ]
}

@test "a failed secondary identity render does not abort bootstrap under set -e" {
  setup_sec_boot old59 'guarzo default\ngambtho gambtho\n'
  chmod a-w "$SECBOOT/core/git"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    set -e
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=false
    DOTFILES_ROOT='$SECBOOT'
    printf 'y\nName\nuser@example.invalid\n/abs/key.pub\n' | setup_secondary_identity
    echo REACHED_NEXT_STEP
  "
  chmod u+w "$SECBOOT/core/git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_NEXT_STEP"* ]]
}

# ---- machine-local / per-profile owner map resolution ----

setup_map_root() {
  export DOTFILES="$TEST_ROOT/dotfiles"
  mkdir -p "$DOTFILES/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$DOTFILES/core/git/"
  printf 'gambtho default\nguarzo  guarzo\n' >"$DOTFILES/core/git/identity-owners"
  unset IDENTITY_MAP_FILE
}

active_map() {
  bash -c "source '$DOTFILES/core/git/identity-lib.sh'; printf '%s\n' \"\$IDENTITY_MAP_FILE\""
}

@test "map resolution falls back to the shared tracked map" {
  setup_map_root
  run active_map
  [ "$output" = "$DOTFILES/core/git/identity-owners" ]
}

@test "a per-profile map beats the shared map" {
  setup_map_root
  printf 'personal\n' >"$HOME/.dotfiles-profile"
  printf 'guarzo default\n' >"$DOTFILES/core/git/identity-owners.personal"
  run active_map
  [ "$output" = "$DOTFILES/core/git/identity-owners.personal" ]
}

@test "a machine-local map beats the per-profile and shared maps" {
  setup_map_root
  printf 'personal\n' >"$HOME/.dotfiles-profile"
  printf 'guarzo default\n' >"$DOTFILES/core/git/identity-owners.personal"
  printf 'guarzo default\ngambtho gambtho\n' >"$DOTFILES/core/git/identity-owners.local"
  run active_map
  [ "$output" = "$DOTFILES/core/git/identity-owners.local" ]
}

@test "an explicit IDENTITY_MAP_FILE beats every discovered map" {
  setup_map_root
  printf 'guarzo default\n' >"$DOTFILES/core/git/identity-owners.local"
  printf 'gambtho default\n' >"$TEST_ROOT/explicit-map"
  run bash -c "export IDENTITY_MAP_FILE='$TEST_ROOT/explicit-map'; source '$DOTFILES/core/git/identity-lib.sh'; printf '%s\n' \"\$IDENTITY_MAP_FILE\""
  [ "$output" = "$TEST_ROOT/explicit-map" ]
}

@test "a machine-local map REPLACES rather than extends the shared map" {
  # Replace semantics: an owner present only in the shared map must become
  # unmapped, or a machine would silently inherit the other machine's roles.
  setup_map_root
  printf 'guarzo default\n' >"$DOTFILES/core/git/identity-owners.local"
  run bash -c "source '$DOTFILES/core/git/identity-lib.sh'; identity_owner_slug guarzo"
  [ "$status" -eq 0 ]
  [ "$output" = "default" ]
  run bash -c "source '$DOTFILES/core/git/identity-lib.sh'; identity_owner_slug gambtho"
  [ "$status" -eq 1 ]
}

@test "a malformed machine-local map fails closed instead of falling back" {
  setup_map_root
  printf 'Guarzo guarzo\n' >"$DOTFILES/core/git/identity-owners.local"
  run bash -c "source '$DOTFILES/core/git/identity-lib.sh'; identity_validate_map"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "a profile name that is not a safe path component is ignored" {
  setup_map_root
  printf '../../etc\n' >"$HOME/.dotfiles-profile"
  run active_map
  [ "$output" = "$DOTFILES/core/git/identity-owners" ]
}

@test "the machine-local map is gitignored and has a tracked example" {
  run git -C "$REPO_ROOT" check-ignore -q core/git/identity-owners.local
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/core/git/identity-owners.local.example" ]
}

@test "the doctor reports which owner map is in effect" {
  setup_shim_repo "$TEST_ROOT/r" https://github.com/kubernetes-sigs/repo.git
  cd "$TEST_ROOT/r"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 0 ]
  [[ "$output" == *"map:"* ]]
}

@test "non-interactive bootstrap skips the machine-local owner map" {
  local fake="$TEST_ROOT/boot7"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/identity-owners.local.example" "$fake/core/git/"
  cp "$REPO_ROOT/core/git/identity-owners" "$fake/core/git/"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=true
    DOTFILES_ROOT='$fake'
    setup_identity_map
  " </dev/null
  [ "$status" -eq 0 ]
  assert_file_absent "$fake/core/git/identity-owners.local"
}

@test "bootstrap writes a valid machine-local map from the answers" {
  local fake="$TEST_ROOT/boot8"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/identity-owners.local.example" "$fake/core/git/"
  cp "$REPO_ROOT/core/git/identity-owners" "$fake/core/git/"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$fake/core/git/"
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=false
    DOTFILES_ROOT='$fake'
    printf 'y\nguarzo\ngambtho\n' | setup_identity_map
  "
  [ "$status" -eq 0 ]
  [ -f "$fake/core/git/identity-owners.local" ]
  # The generated map must satisfy the library's own validator.
  run bash -c "source '$fake/core/git/identity-lib.sh'; identity_validate_map '$fake/core/git/identity-owners.local'"
  [ "$status" -eq 0 ]
  run bash -c "source '$fake/core/git/identity-lib.sh'; identity_owner_slug guarzo '$fake/core/git/identity-owners.local'"
  [ "$output" = "default" ]
  run bash -c "source '$fake/core/git/identity-lib.sh'; identity_owner_slug gambtho '$fake/core/git/identity-owners.local'"
  [ "$output" = "gambtho" ]
  run bash -c "ls -A '$fake/core/git' | grep -c '^\.identity-owners\.'"
  [ "$output" -eq 0 ]
}

@test "a non-regular file at the map path fails closed, not open" {
  # A directory passes a bare -r test but yields an EMPTY map, which would make
  # every owner unmapped and every consumer fail open.
  setup_map_root
  mkdir -p "$DOTFILES/core/git/identity-owners.local"
  run bash -c "source '$DOTFILES/core/git/identity-lib.sh'; identity_validate_map"
  [ "$status" -eq 1 ]
  [[ "$output" == *"regular file"* ]]
}

setup_map_boot() {
  MAPBOOT="$TEST_ROOT/$1"
  mkdir -p "$MAPBOOT/core/git"
  cp "$REPO_ROOT/core/git/identity-owners.local.example" "$MAPBOOT/core/git/"
  cp "$REPO_ROOT/core/git/identity-owners" "$MAPBOOT/core/git/"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$MAPBOOT/core/git/"
}

run_map_setup() {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=false
    DOTFILES_ROOT='$MAPBOOT'
    printf '%b' '$1' | setup_identity_map
  "
}

@test "bootstrap allows a map that keeps the default but changes secondaries" {
  setup_map_boot mb1
  run_map_setup 'y\ngambtho\nacme\n'
  [ "$status" -eq 0 ]
  [ -f "$MAPBOOT/core/git/identity-owners.local" ]
  run bash -c "source '$MAPBOOT/core/git/identity-lib.sh'; identity_owner_slug gambtho '$MAPBOOT/core/git/identity-owners.local'"
  [ "$output" = "default" ]
  run bash -c "source '$MAPBOOT/core/git/identity-lib.sh'; identity_owner_slug acme '$MAPBOOT/core/git/identity-owners.local'"
  [ "$output" = "acme" ]
  # guarzo came only from the shared map, so replace semantics drop it
  run bash -c "source '$MAPBOOT/core/git/identity-lib.sh'; identity_owner_slug guarzo '$MAPBOOT/core/git/identity-owners.local'"
  [ "$status" -eq 1 ]
}

@test "bootstrap rejects an invalid owner name instead of installing it" {
  setup_map_boot mb2
  run_map_setup 'y\nGuarzo\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rejected"* ]]
  assert_file_absent "$MAPBOOT/core/git/identity-owners.local"
}

@test "bootstrap rejects a duplicate owner across default and secondaries" {
  setup_map_boot mb3
  run_map_setup 'y\nguarzo\nguarzo\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rejected"* ]]
  assert_file_absent "$MAPBOOT/core/git/identity-owners.local"
}

@test "bootstrap does not glob-expand the secondaries answer" {
  setup_map_boot mb4
  # Run from a directory whose only entry is a VALID owner name. Without this,
  # '*' expands to repo files like AGENTS.md, validation rejects them, and the
  # map is absent either way -- the test would pass even with expansion enabled.
  # With 'acme' as the sole entry, an expansion produces a map that validates
  # and installs, so the assertion below genuinely detects the bug.
  local glob_dir="$TEST_ROOT/glob-input"
  mkdir -p "$glob_dir"
  : >"$glob_dir/acme"
  # The cd must happen AFTER sourcing: bin/bootstrap cds to its own repo root at
  # source time, so any directory set before the source call is discarded.
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    cd '$glob_dir'
    NON_INTERACTIVE=false
    DOTFILES_ROOT='$MAPBOOT'
    printf 'y\nguarzo\n*\n' | setup_identity_map
  "
  [ "$status" -eq 0 ]
  assert_file_absent "$MAPBOOT/core/git/identity-owners.local"
}

@test "bootstrap refuses to install over a non-regular map path" {
  setup_map_boot mb5
  mkdir -p "$MAPBOOT/core/git/identity-owners.local"
  run_map_setup 'y\nguarzo\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a regular file"* ]]
  [ -d "$MAPBOOT/core/git/identity-owners.local" ]
  run bash -c "ls -A '$MAPBOOT/core/git/identity-owners.local' | wc -l"
  [ "$output" -eq 0 ]
}

# ---- slug-agnostic secondary identity provisioning ----

@test "gitignore covers any secondary identity slug, not just guarzo" {
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.gambtho.symlink
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.acme.symlink
  [ "$status" -eq 0 ]
  # The existing machine-local guarzo file must stay covered.
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.guarzo.symlink
  [ "$status" -eq 0 ]
}

@test "the wildcard ignore does not swallow tracked git config files" {
  # gitconfig.symlink is the tracked global config -- ignoring it would be a
  # catastrophic regression. Templates must stay trackable too.
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.symlink
  [ "$status" -ne 0 ]
  run git -C "$REPO_ROOT" ls-files --error-unmatch core/git/gitconfig.symlink
  [ "$status" -eq 0 ]
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.secondary.symlink.example
  [ "$status" -ne 0 ]
}

@test "the secondary identity template is slug-agnostic" {
  local t="$REPO_ROOT/core/git/gitconfig.secondary.symlink.example"
  [ -f "$t" ]
  run grep -c 'IDENTITY_SLUG' "$t"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
  run grep -Eq '@(gmail|microsoft|outlook)\.' "$t"
  [ "$status" -ne 0 ]
}

setup_sec_boot() {
  SECBOOT="$TEST_ROOT/$1"
  # setup() exports IDENTITY_MAP_FILE, which outranks every discovered map and
  # would otherwise feed these tests the fixture map instead of the one below.
  unset IDENTITY_MAP_FILE
  mkdir -p "$SECBOOT/core/git"
  cp "$REPO_ROOT/core/git/gitconfig.secondary.symlink.example" "$SECBOOT/core/git/"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$SECBOOT/core/git/"
  printf '%b' "$2" >"$SECBOOT/core/git/identity-owners"
}

run_sec_setup() {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    NON_INTERACTIVE=${2:-false}
    DOTFILES_ROOT='$SECBOOT'
    printf '%b' '$1' | setup_secondary_identity
  "
}

@test "bootstrap provisions the secondary slug named by the owner map" {
  setup_sec_boot sec1 'guarzo default\ngambtho gambtho\n'
  run_sec_setup 'y\ngambtho\nuser@example.invalid\n/abs/gambtho.pub\n'
  [ "$status" -eq 0 ]
  # Named for the slug in the map, NOT hardcoded to guarzo.
  [ -f "$SECBOOT/core/git/gitconfig.gambtho.symlink" ]
  assert_file_absent "$SECBOOT/core/git/gitconfig.guarzo.symlink"
  run grep -Fq 'GH_CONFIG_DIR=$HOME/.gh-gambtho' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$status" -eq 0 ]
  run grep -cE 'IDENTITY_SLUG|YOUR_ACCOUNT_NAME|you@example.com|YOUR_USER' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$output" -eq 0 ]
}

@test "bootstrap offers nothing when the map has no secondary slugs" {
  setup_sec_boot sec2 'guarzo default\n'
  run_sec_setup 'y\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no secondary"* ]]
}

@test "bootstrap skips a secondary slug that is already provisioned" {
  setup_sec_boot sec3 'guarzo default\ngambtho gambtho\n'
  printf '[user]\n\temail = existing@example.invalid\n' >"$SECBOOT/core/git/gitconfig.gambtho.symlink"
  run_sec_setup 'y\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured"* ]]
  run grep -c 'existing@example.invalid' "$SECBOOT/core/git/gitconfig.gambtho.symlink"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "non-interactive bootstrap still skips secondary identities" {
  setup_sec_boot sec4 'guarzo default\ngambtho gambtho\n'
  run_sec_setup '' true
  [ "$status" -eq 0 ]
  assert_file_absent "$SECBOOT/core/git/gitconfig.gambtho.symlink"
}

# ---- generated routing blocks ----

setup_routes() {
  export DOTFILES="$TEST_ROOT/rt"
  mkdir -p "$DOTFILES/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$DOTFILES/core/git/"
  cp "$REPO_ROOT/core/git/gitconfig.symlink" "$DOTFILES/core/git/"
  printf 'gambtho default\nguarzo  guarzo\n' >"$DOTFILES/core/git/identity-owners"
  unset IDENTITY_MAP_FILE
}

render_routes() {
  bash -c ". '$DOTFILES/core/git/identity-lib.sh' && identity_render_routes"
}

@test "routes are generated for every non-default slug in the ACTIVE map" {
  setup_routes
  run render_routes
  [ "$status" -eq 0 ]
  [[ "$output" == *'hasconfig:remote.*.url:https://github.com/guarzo/**'* ]]
  [[ "$output" == *'path = ~/.gitconfig.guarzo'* ]]
  # The default owner never gets a routing block.
  [[ "$output" != *'github.com/gambtho/'* ]]
}

@test "routes follow a machine-local map that flips the roles" {
  # The case that shipped broken: identity-owners.local made gambtho a secondary
  # slug, but the tracked includeIf still named guarzo, so gambtho was never
  # routed and the old pair test passed anyway.
  setup_routes
  printf 'guarzo default\ngambtho gambtho\n' >"$DOTFILES/core/git/identity-owners.local"
  run render_routes
  [ "$status" -eq 0 ]
  [[ "$output" == *'hasconfig:remote.*.url:https://github.com/gambtho/**'* ]]
  [[ "$output" == *'path = ~/.gitconfig.gambtho'* ]]
  [[ "$output" != *'github.com/guarzo/'* ]]
}

@test "a map with no secondary slugs renders no routing blocks" {
  setup_routes
  printf 'guarzo default\n' >"$DOTFILES/core/git/identity-owners.local"
  run render_routes
  [ "$status" -eq 0 ]
  [[ "$output" != *"includeIf"* ]]
}

@test "the tracked gitconfig carries no hardcoded per-owner includeIf" {
  # Routing must come from the generated file, or a machine whose active map
  # differs from the tracked one silently loses routing.
  run grep -c 'hasconfig:remote' "$REPO_ROOT/core/git/gitconfig.symlink"
  [ "$output" -eq 0 ]
  run grep -Fq 'path = ~/.gitconfig.identity-routes' "$REPO_ROOT/core/git/gitconfig.symlink"
  [ "$status" -eq 0 ]
}

@test "generated routes actually route git config end to end" {
  setup_routes
  printf 'guarzo default\ngambtho gambtho\n' >"$DOTFILES/core/git/identity-owners.local"
  cp "$REPO_ROOT/core/git/gitconfig.symlink" "$HOME/.gitconfig"
  printf '[user]\n\temail = ambient@example.invalid\n' >"$HOME/.gitconfig.local"
  printf '[user]\n\temail = gambtho@example.invalid\n\tsigningKey = /k/gambtho.pub\n' >"$HOME/.gitconfig.gambtho"
  render_routes >"$HOME/.gitconfig.identity-routes"
  git init -q "$TEST_ROOT/gr"
  git -C "$TEST_ROOT/gr" remote add origin https://github.com/gambtho/thing.git
  run git -C "$TEST_ROOT/gr" config user.email
  [ "$output" = "gambtho@example.invalid" ]
  run git -C "$TEST_ROOT/gr" config user.signingKey
  [ "$output" = "/k/gambtho.pub" ]
  # An unrelated repo stays on the ambient identity.
  git init -q "$TEST_ROOT/other"
  git -C "$TEST_ROOT/other" remote add origin https://github.com/kubernetes-sigs/x.git
  run git -C "$TEST_ROOT/other" config user.email
  [ "$output" = "ambient@example.invalid" ]
}

@test "the generated routes file is gitignored" {
  run git -C "$REPO_ROOT" check-ignore -q core/git/gitconfig.identity-routes.symlink
  [ "$status" -eq 0 ]
}

@test "route rendering reads the map from the same root it writes to" {
  # The library resolves its root from $DOTFILES. Without binding it to
  # DOTFILES_ROOT, relink/bootstrap read the map from $HOME/.dotfiles while
  # writing output under DOTFILES_ROOT -- two different roots, silently.
  local fake="$TEST_ROOT/rootbind"
  mkdir -p "$fake/core/git" "$HOME/.dotfiles/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$fake/core/git/"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$HOME/.dotfiles/core/git/"
  # Decoy map at $HOME/.dotfiles names a DIFFERENT owner.
  printf 'decoy decoyslug\n' >"$HOME/.dotfiles/core/git/identity-owners"
  printf 'guarzo default\ngambtho gambtho\n' >"$fake/core/git/identity-owners"
  unset IDENTITY_MAP_FILE
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    source '$REPO_ROOT/bin/bootstrap'
    DOTFILES_ROOT='$fake'
    render_identity_routes
  "
  [ "$status" -eq 0 ]
  run cat "$fake/core/git/gitconfig.identity-routes.symlink"
  [[ "$output" == *"github.com/gambtho/"* ]]
  [[ "$output" != *"decoy"* ]]
}

@test "a failed routes render leaves the previous routes file in place" {
  # The render is redirected into the routes file's replacement, not the file
  # itself: a mid-render failure must leave the OLD routes intact, because an
  # empty or partial file still parses as git config and silently disables
  # routing for every identity.
  local fake="$TEST_ROOT/atomicroutes"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$fake/core/git/"
  printf 'guarzo default\ngambtho gambtho\n' >"$fake/core/git/identity-owners"
  # Validation stays real; only the render fails, after emitting partial output.
  printf 'identity_render_routes() { printf "partial\\n"; return 1; }\n' \
    >>"$fake/core/git/identity-lib.sh"
  printf 'OLD ROUTES\n' >"$fake/core/git/gitconfig.identity-routes.symlink"

  run bash -c "source '$REPO_ROOT/bin/common.sh'; regenerate_identity_routes '$fake'"
  [ "$status" -eq 1 ]
  run cat "$fake/core/git/gitconfig.identity-routes.symlink"
  [ "$output" = "OLD ROUTES" ]
  # No orphaned temporary may survive the failure.
  run bash -c "ls '$fake/core/git' | grep -c 'tmp'"
  [ "$output" -eq 0 ]
}

@test "a failed routes render warns and does not abort bootstrap under set -e" {
  local fake="$TEST_ROOT/atomicroutes-boot"
  mkdir -p "$fake/core/git"
  cp "$REPO_ROOT/core/git/identity-lib.sh" "$fake/core/git/"
  printf 'guarzo default\ngambtho gambtho\n' >"$fake/core/git/identity-owners"
  printf 'identity_render_routes() { return 1; }\n' >>"$fake/core/git/identity-lib.sh"
  printf 'OLD ROUTES\n' >"$fake/core/git/gitconfig.identity-routes.symlink"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c "
    set -e
    source '$REPO_ROOT/bin/bootstrap'
    DOTFILES_ROOT='$fake'
    render_identity_routes
    echo REACHED_NEXT_STEP
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous routes left in place"* ]]
  [[ "$output" == *"REACHED_NEXT_STEP"* ]]
  run cat "$fake/core/git/gitconfig.identity-routes.symlink"
  [ "$output" = "OLD ROUTES" ]
}

@test "an identity file with no email is reported incomplete, not OK" {
  setup_shim_repo "$TEST_ROOT/inc" https://github.com/guarzo/repo.git
  # File exists (so it counts as provisioned) but defines nothing usable.
  printf '# empty\n' >"$HOME/.gitconfig.guarzo"
  mkdir -p "$HOME/.gh-guarzo"
  cd "$TEST_ROOT/inc"
  run "$REPO_ROOT/bin/git-identity"
  [ "$status" -eq 3 ]
  [[ "$output" == *"INCOMPLETE"* ]]
}

@test "the tracked gitconfig links worktrees relatively" {
  # An absolute `gitdir:` names a host path that does not exist inside the
  # repository's container, where linked worktrees are now reached from.
  run git config --file "$REPO_ROOT/core/git/gitconfig.symlink" \
    --type bool --get worktree.useRelativePaths
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "worktree.useRelativePaths actually produces a relative gitdir" {
  # Asserts the behavior, not just the key: a git that does not support the
  # option parses the config without complaint and writes an absolute link.
  #
  # Which is exactly why an old git skips rather than fails, before any setup
  # runs: the absolute link it writes is correct behavior for that git, not a
  # regression in this repo. bin/relink warns on the same 2.48 floor for the
  # same reason -- the setting is inert there, not broken. The gitconfig test
  # above still holds on every version, so the key itself stays covered.
  local want=2.48.0 have
  have=$(git --version | awk '{print $3}')
  if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" != "$want" ]; then
    skip "git $have is older than $want; worktree.useRelativePaths is ignored"
  fi

  local repo="$TEST_ROOT/relwt"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  echo one >"$repo/file"
  git -C "$repo" add file
  git -C "$repo" -c commit.gpgsign=false commit -q -m one
  git -C "$repo" config worktree.useRelativePaths true
  git -C "$repo" worktree add -q "$TEST_ROOT/relwt-a" -b feat-a

  run cat "$TEST_ROOT/relwt-a/.git"
  [ "$status" -eq 0 ]
  [ "$output" = "gitdir: ../relwt/.git/worktrees/relwt-a" ]

  # The relative link must still be a working repository.
  run git -C "$TEST_ROOT/relwt-a" rev-parse --abbrev-ref HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "feat-a" ]
}
