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
