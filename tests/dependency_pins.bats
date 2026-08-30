#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/config/versions.env"
}

@test "README documents Kubernetes channel as operator-selected" {
  run rg -n 'pins-update.*report.*[Kk]ubernetes|[Kk]ubernetes channel.*drift|reports.*[Kk]ubernetes.*drift' \
    "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  run rg -n 'refresh.*Git refs and the Kubernetes channel|automatically.*[Kk]ubernetes channel' "$REPO_ROOT/README.md"
  [ "$status" -eq 1 ]
}

@test "versions list shows mise and non-mise pins" {
  run bash "$REPO_ROOT/bin/versions" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise go 1.26"* ]]
  [[ "$output" == *"git prezto $PREZTO_REF"* ]]
  [[ "$output" == *"git zsh-defer $ZSH_DEFER_REF"* ]]
  [[ "$output" == *"channel kubernetes v1.28"* ]]
  [[ "$output" == *"artifact mise v2026.7.18"* ]]
  [[ "$output" == *"artifact krew v0.5.0"* ]]
  [[ "$output" == *"artifact yq v4.45.1"* ]]
  [[ "$output" == *"artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"artifact herdr v0.8.0"* ]]
  [[ "$output" == *"npm pi $PI_VERSION"* ]]
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
  run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL|PI_VERSION|HERDR_VERSION|HERDR_RELEASE_BASE|HERDR_LINUX_(X86_64|AARCH64)_SHA256)=' "$REPO_ROOT" \
    --glob '!docs/**' --glob '!tests/**'
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/config/versions.env" ]

  # The alternation above is an OR, so a missing key family cannot fail it —
  # any one surviving family still resolves to versions.env. Assert the new
  # family on its own so the manifest guarantee actually covers it.
  run rg -l '^HERDR_(VERSION|RELEASE_BASE|LINUX_(X86_64|AARCH64)_SHA256)=' "$REPO_ROOT" \
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
  *kubernetes-sigs/krew*) printf '{"tag_name":"v0.5.0"}\n' ;;
  *mikefarah/yq*) printf '{"tag_name":"v4.45.1"}\n' ;;
  *equalsraf/win32yank*) printf '{"tag_name":"v0.1.1"}\n' ;;
  *ryanoasis/nerd-fonts*) printf '{"tag_name":"v3.4.0"}\n' ;;
  *herdrdev/herdr*) printf '{"tag_name":"v0.8.0"}\n' ;;
  *registry.npmjs.org*) printf '{"version":"0.84.4"}\n' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash "$REPO_ROOT/bin/versions" check

  [ "$status" -eq 0 ]
  [[ "$output" == *"current artifact mise v2026.7.18"* ]]
  [[ "$output" == *"current artifact krew v0.5.0"* ]]
  [[ "$output" == *"current artifact yq v4.45.1"* ]]
  [[ "$output" == *"current artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"current artifact herdr v0.8.0"* ]]
  [[ "$output" == *"current artifact nerd-fonts v3.4.0"* ]]
  [[ "$output" == *"current npm pi $PI_VERSION"* ]]
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

@test "versions check rejects a malformed Kubernetes channel instead of reporting it" {
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *zsh-defer*) printf '%s\tHEAD\n' '$ZSH_DEFER_REF' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/git"
  # A successful transfer of the wrong body: an interstitial or error page from
  # the CDN exits 0, so only the shape check can catch it. Reporting it verbatim
  # would announce the pin as outdated against a value nothing upstream moved to.
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*) printf '<!doctype html>\n' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash "$REPO_ROOT/bin/versions" check

  [ "$status" -ne 0 ]
  [[ "$output" == *"error channel kubernetes: unable to query upstream stable channel"* ]]
  [[ "$output" != *"outdated channel kubernetes"* ]]
}

@test "versions check fails when the Kubernetes channel lookup fails" {
  stub_command mise 'exit 0'
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *zsh-defer*) printf '%s\tHEAD\n' '$ZSH_DEFER_REF' ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/git"
  # Emit a plausible channel *and* exit non-zero, the shape a truncated or
  # redirected transfer takes. Output alone must not be enough to pass.
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*)
    printf 'v1.34.0\n'
    exit 22
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash "$REPO_ROOT/bin/versions" check

  [ "$status" -ne 0 ]
  [[ "$output" == *"error channel kubernetes: unable to query upstream stable channel"* ]]
  [[ "$output" != *"outdated channel kubernetes"* ]]
}

@test "versions update writes no pins when the Kubernetes channel lookup fails" {
  local fixture="$TEST_ROOT/fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_ROOT/bin" "$fixture/bin"
  cp -R "$REPO_ROOT/config" "$fixture/config"

  stub_command mise 'exit 0'
  stub_command make 'exit 0'
  stub_command git 'printf "deadbeef\tHEAD\n"'
  cat >"$STUB_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *dl.k8s.io*)
    printf 'v9.99.0\n'
    exit 22
    ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run bash "$fixture/bin/versions" update

  [ "$status" -ne 0 ]
  [[ "$output" == *"no pins were updated"* ]]
  # The Git pins are written after the lookup, so an unnoticed failure would
  # show up here as a repo half-updated against an unverified channel.
  [ "$(grep '^PREZTO_REF=' "$fixture/config/versions.env")" = "PREZTO_REF=$PREZTO_REF" ]
  [ "$(grep '^ZSH_DEFER_REF=' "$fixture/config/versions.env")" = "ZSH_DEFER_REF=$ZSH_DEFER_REF" ]
}

@test "versions update keeps artifact bumps behind checksum review" {
  run rg -n 'checksum-reviewed manual update required' "$REPO_ROOT/bin/versions"

  [ "$status" -eq 0 ]
}

@test "versions update leaves the Kubernetes channel operator-owned" {
  local fixture="$TEST_ROOT/fixture"
  # Copy whole directories rather than a hand-maintained file list: bin/versions
  # sources siblings, and naming them individually makes an unrelated new
  # dependency fail this test for a reason that has nothing to do with the
  # Kubernetes channel.
  mkdir -p "$fixture"
  cp -R "$REPO_ROOT/bin" "$fixture/bin"
  cp -R "$REPO_ROOT/config" "$fixture/config"

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

@test "versions update writes no pins when a remote HEAD cannot be resolved" {
  local fixture="$TEST_ROOT/fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_ROOT/bin" "$fixture/bin"
  cp -R "$REPO_ROOT/config" "$fixture/config"

  stub_command mise 'exit 0'
  stub_command make 'exit 0'
  # prezto resolves; zsh-defer answers with a ref-less error line, the shape a
  # renamed or unreachable remote takes. `git ls-remote | awk` reports awk's
  # status, so nothing about this is visible from the pipeline's exit code.
  cat >"$STUB_BIN/git" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
  *ls-remote*prezto*) printf '%s\tHEAD\n' '$PREZTO_REF' ;;
  *ls-remote*zsh-defer*)
    printf 'fatal: repository not found\n' >&2
    exit 128
    ;;
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

  [ "$status" -ne 0 ]
  [[ "$output" == *"no pins were updated"* ]]
  # Neither pin may move: PREZTO_REF resolved fine, but writing it alone leaves
  # versions.env half-advanced with ZSH_DEFER_REF blank.
  [ "$(grep '^PREZTO_REF=' "$fixture/config/versions.env")" = "PREZTO_REF=$PREZTO_REF" ]
  [ "$(grep '^ZSH_DEFER_REF=' "$fixture/config/versions.env")" = "ZSH_DEFER_REF=$ZSH_DEFER_REF" ]
}
