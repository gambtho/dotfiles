#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/config/versions.env"
}

@test "versions list shows mise and non-mise pins" {
  run bash "$REPO_ROOT/bin/versions" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise go 1.25.12"* ]]
  [[ "$output" == *"git prezto 9739c8bdc9c288ffc134c209225543180e32ff69"* ]]
  [[ "$output" == *"git zsh-defer $ZSH_DEFER_REF"* ]]
  [[ "$output" == *"channel kubernetes v1.28"* ]]
  [[ "$output" == *"artifact mise v2026.7.18"* ]]
  [[ "$output" == *"artifact yq v4.45.1"* ]]
  [[ "$output" == *"artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"artifact vekil v0.14.0"* ]]
  [[ "$output" == *"artifact nerd-fonts v3.4.0"* ]]
  [[ "$output" == *"artifact nerd-font-cascadia-mono v3.4.0 $NERD_FONT_CASCADIA_MONO_SHA256"* ]]
  [[ "$output" == *"artifact nerd-font-hack v3.4.0 $NERD_FONT_HACK_SHA256"* ]]
  [[ "$output" == *"artifact nerd-font-meslo v3.4.0 $NERD_FONT_MESLO_SHA256"* ]]
}

@test "versions check fails when mise cannot check pins" {
  stub_command mise 'exit 1'
  stub_command git 'printf "unrelated-ref\\n"'
  stub_command curl 'printf "v1.28.0\\n"'

  run bash "$REPO_ROOT/bin/versions" check
  [ "$status" -ne 0 ]
}

@test "non-mise pins have one canonical manifest" {
  run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL|VEKIL_VERSION|VEKIL_RELEASE_BASE|VEKIL_(DARWIN|LINUX)_(AMD64|ARM64)_SHA256)=' "$REPO_ROOT" \
    --glob '!docs/**' --glob '!tests/**'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/config/versions.env" ]
}

@test "versions rejects unknown commands" {
  run bash "$REPO_ROOT/bin/versions" unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "Neovim lockfile is tracked and pins lazy bootstrap" {
  local lock="$REPO_ROOT/config/nvim/lazy-lock.json"

  [ -f "$lock" ]
  run git -C "$REPO_ROOT" check-ignore config/nvim/lazy-lock.json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.["lazy.nvim"].commit' "$lock")" = 306a05526ada86a7b30af95c5cc81ffba93fef97 ]
  run rg -n '306a05526ada86a7b30af95c5cc81ffba93fef97' "$REPO_ROOT/config/nvim/init.lua"
  [ "$status" -eq 0 ]
  run rg -n -- '--branch=stable|--branch[[:space:]]*=[[:space:]]*stable' "$REPO_ROOT/config/nvim/init.lua"
  [ "$status" -eq 1 ]
}

@test "routine Neovim convergence restores without updating the lock" {
  run rg -n 'Lazy![[:space:]]+restore' "$REPO_ROOT/bin/install"
  [ "$status" -eq 0 ]
  run rg -n 'Lazy![[:space:]]+(sync|update)' "$REPO_ROOT/bin/install"
  [ "$status" -eq 1 ]
}

@test "versions check reports every pinned artifact release" {
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *zsh-defer*) printf '%s\tHEAD\n' '$ZSH_DEFER_REF' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/git"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*) printf 'v1.28.0\n' ;;
  *jdx/mise*) printf '{"tag_name":"v2026.7.18"}\n' ;;
  *mikefarah/yq*) printf '{"tag_name":"v4.45.1"}\n' ;;
  *equalsraf/win32yank*) printf '{"tag_name":"v0.1.1"}\n' ;;
  *sozercan/vekil*) printf '{"tag_name":"v0.14.0"}\n' ;;
  *ryanoasis/nerd-fonts*) printf '{"tag_name":"v3.4.0"}\n' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash "$REPO_ROOT/bin/versions" check

  [ "$status" -eq 0 ]
  [[ "$output" == *"current artifact mise v2026.7.18"* ]]
  [[ "$output" == *"current artifact yq v4.45.1"* ]]
  [[ "$output" == *"current artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"current artifact vekil v0.14.0"* ]]
  [[ "$output" == *"current artifact nerd-fonts v3.4.0"* ]]
}

@test "versions check reports artifact release lookup failures clearly" {
  local failure
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *zsh-defer*) printf '%s\tHEAD\n' '$ZSH_DEFER_REF' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/git"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*) printf 'v1.28.0\n' ;;
  *api.github.com*)
    if [[ "$VERSION_LOOKUP_FAILURE" == transport ]]; then
      exit 22
    fi
    printf '{}\n'
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  for failure in transport response; do
    run env PATH="$PATH" VERSION_LOOKUP_FAILURE="$failure" bash "$REPO_ROOT/bin/versions" check

    [ "$status" -ne 0 ]
    [[ "$output" == *"error artifact mise: unable to query latest release for jdx/mise"* ]]
    [[ "$output" != *"outdated artifact mise"* ]]
  done
}

@test "versions update keeps artifact bumps behind checksum review" {
  run rg -n 'checksum-reviewed manual update required' "$REPO_ROOT/bin/versions"

  [ "$status" -eq 0 ]
}

@test "versions update leaves the Kubernetes channel operator-owned" {
  local fixture="$TEST_ROOT/fixture"
  mkdir -p "$fixture/bin" "$fixture/config/mise"
  cp "$REPO_ROOT/bin/versions" "$fixture/bin/versions"
  cp "$REPO_ROOT/bin/common.sh" "$fixture/bin/common.sh"
  cp "$REPO_ROOT/bin/log-helper" "$fixture/bin/log-helper"
  cp "$REPO_ROOT/config/versions.env" "$fixture/config/versions.env"
  cp "$REPO_ROOT/config/mise/config.toml" "$fixture/config/mise/config.toml"

  stub_command mise 'exit 0'
  stub_command make 'exit 0'
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *ls-remote*prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *ls-remote*zsh-defer*) printf '%s\tHEAD\n' '$ZSH_DEFER_REF' ;;
  *diff*) exit 0 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/git"
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*) printf 'v9.99.0\n' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run bash "$fixture/bin/versions" update

  [ "$status" -eq 0 ]
  [ "$(grep '^KUBERNETES_CHANNEL=' "$fixture/config/versions.env")" = \
    "KUBERNETES_CHANNEL=$KUBERNETES_CHANNEL" ]
  [[ "$output" == *"operator-managed Kubernetes channel"* ]]
  [[ "$output" == *"current: $KUBERNETES_CHANNEL"* ]]
  [[ "$output" == *"upstream: v9.99"* ]]
}
