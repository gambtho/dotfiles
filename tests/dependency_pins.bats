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
  run bash "$REPO_ROOT/libexec/versions" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise go 1.26"* ]]
  [[ "$output" == *"git prezto $PREZTO_REF"* ]]
  [[ "$output" == *"git zsh-defer $ZSH_DEFER_REF"* ]]
  [[ "$output" == *"channel kubernetes $KUBERNETES_CHANNEL"* ]]
  [[ "$output" == *"artifact mise v2026.7.18"* ]]
  [[ "$output" == *"artifact krew v0.5.0"* ]]
  [[ "$output" == *"artifact yq v4.45.1"* ]]
  [[ "$output" == *"artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"artifact herdr v0.8.0"* ]]
  [[ "$output" == *"artifact neovim $NVIM_VERSION"* ]]
  [[ "$output" == *"artifact tree-sitter-cli $TREE_SITTER_VERSION"* ]]
  [[ "$output" == *"git herdr-devcontainer $HERDR_DEVCONTAINER_REPO $HERDR_DEVCONTAINER_REF"* ]]
  [[ "$output" == *"npm pi-paseo-runtime $PASEO_VERSION"* ]]
  [[ "$output" != *"pi-webui-runtime"* ]]
  [[ "$output" != *"pi-queue-steer"* ]]
  [[ "$output" != *"pi-web-access"* ]]
  [[ "$output" != *"pi-lsp"* ]]
  [[ "$output" != *"pi-subagents"* ]]
  [[ "$output" != *"pi-permission-system"* ]]
  [[ "$output" != *"pi-sandbox"* ]]
  [[ "$output" == *"artifact nerd-fonts v3.4.0"* ]]
  [[ "$output" == *"artifact nerd-font-cascadia-mono v3.4.0 $NERD_FONT_CASCADIA_MONO_SHA256"* ]]
  [[ "$output" == *"artifact nerd-font-hack v3.4.0 $NERD_FONT_HACK_SHA256"* ]]
  [[ "$output" == *"artifact nerd-font-meslo v3.4.0 $NERD_FONT_MESLO_SHA256"* ]]
}

@test "versions check fails when mise cannot check pins" {
  stub_command mise 'exit 1'
  stub_command git 'printf "unrelated-ref\\n"'
  stub_command curl 'printf "v1.28.0\\n"'

  run bash "$REPO_ROOT/libexec/versions" check
  [ "$status" -ne 0 ]
}

@test "non-mise pins have one canonical manifest" {
  run rg -l '^(PREZTO_REF|ZSH_DEFER_REF|KUBERNETES_CHANNEL|PASEO_VERSION|HERDR_VERSION|HERDR_RELEASE_BASE|HERDR_LINUX_(X86_64|AARCH64)_SHA256)=' "$REPO_ROOT" \
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

@test "canonical pin manifest omits retired Pi sandbox" {
  run rg '^PI_SANDBOX_REF=' "$REPO_ROOT/config/versions.env"
  [ "$status" -eq 1 ]
}

@test "main Pi remotes float except the reviewed editor release while local my remains local" {
  run jq -e --arg editor 'git:github.com/gambtho/pi-file-editor@v0.1.0' '
    [.packages[] | if type == "string" then . else .source end] as $sources
    | all($sources[];
        if startswith("npm:") then test("^npm:(@[^/]+/)?[^@]+$")
        elif startswith("git:") then . == $editor or test("^git:github.com/[^@]+$")
        else . == "~/.dotfiles/ai/marketplace/plugins/my" end)
    and ($sources | index("~/.dotfiles/ai/marketplace/plugins/my") != null)
    and ($sources | map(select(. == $editor)) | length == 1)
    and ($sources | map(select(contains("pi-sandbox"))) | length == 0)
  ' "$REPO_ROOT/ai/pi/settings.json"
  [ "$status" -eq 0 ]
}

@test "CI provisions isolated current candidates before SDK checks and fails on runtime regression" {
  local fixture="$TEST_ROOT/ci-repo" steps="$TEST_ROOT/steps.json"
  export RUNNER_TEMP="$TEST_ROOT/runner" GITHUB_ENV="$TEST_ROOT/github-env" GITHUB_PATH="$TEST_ROOT/github-path"
  mkdir -p "$fixture/libexec/lib" "$RUNNER_TEMP"
  cp "$REPO_ROOT/libexec/lib/pi-runtime.sh" "$fixture/libexec/lib/"
  yq -o=json '.' "$REPO_ROOT/.github/workflows/check.yml" >"$steps"
  printf '' >"$GITHUB_ENV"
  stub_command npm '
    [[ "$*" == *"--global"* && "$*" == *"--ignore-scripts"* ]] || exit 81
    [[ "$*" == *"@earendil-works/pi-coding-agent@latest"* && "$*" == *"@gotgenes/pi-permission-system@latest"* ]] || exit 82
    [[ "$*" == *"@gotgenes/pi-subagents@latest"* && "$*" == *"@narumitw/pi-lsp@latest"* ]] || exit 82
    [[ "$*" == *"--prefix $RUNNER_TEMP/"* && "$npm_config_cache" == "$RUNNER_TEMP/"* ]] || exit 83
    prefix=""
    while [[ $# -gt 0 ]]; do if [[ "$1" == --prefix ]]; then prefix=$2; break; fi; shift; done
    modules="$prefix/lib/node_modules"
    core="$modules/@earendil-works/pi-coding-agent"
    permission="$modules/@gotgenes/pi-permission-system"
    subagents="$modules/@gotgenes/pi-subagents"
    lsp="$modules/@narumitw/pi-lsp"
    mkdir -p "$core/dist" "$permission" "$subagents" "$lsp" "$modules/jiti/lib" "$prefix/bin"
    printf "#!/bin/sh\nexit 99\n" >"$prefix/bin/pi"
    chmod +x "$prefix/bin/pi"
    printf "export {};\n" >"$core/dist/index.js"
    touch "$modules/jiti/lib/jiti-cli.mjs"
    printf "{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"%s\"}\n" "$CI_PI_VERSION" >"$core/package.json"
    printf "{\"name\":\"@gotgenes/pi-permission-system\",\"version\":\"30.0.0\"}\n" >"$permission/package.json"
    printf "{\"name\":\"@gotgenes/pi-subagents\",\"version\":\"23.4.0\"}\n" >"$subagents/package.json"
    printf "{\"name\":\"@narumitw/pi-lsp\",\"version\":\"0.49.9\"}\n" >"$lsp/package.json"
    printf "provision\n" >>"$TEST_ROOT/ci-events"
  '
  stub_command make '
    [[ -f "$PI_TEST_HOST_ROOT/dist/index.js" ]] || { printf "SDK host not provisioned before checks\n" >&2; exit 84; }
    [[ "$(command -v pi)" == "$RUNNER_TEMP/pi-security-gate/bin/pi" ]] || { printf "selected Pi executable not on PATH before checks\n" >&2; exit 86; }
    case "$*" in
      check) printf "check\n" >>"$TEST_ROOT/ci-events" ;;
      pi-runtime-test)
        [[ -f "$PI_TEST_PERMISSION_ROOT/package.json" && -f "$PI_TEST_SUBAGENTS_ROOT/package.json" && -f "$PI_TEST_LSP_ROOT/package.json" ]] || exit 87
        printf "native\n" >>"$TEST_ROOT/ci-events"
        exit "${CI_NATIVE_FAIL:-0}" ;;
      *) exit 84 ;;
    esac
  '
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$*" == *"--package-root $RUNNER_TEMP/"* && "$*" == *"--pi-package-root $PI_TEST_HOST_ROOT"* ]] || exit 85' \
    'printf "gate\n" >>"$TEST_ROOT/ci-events"' \
    'exit "${CI_GATE_FAIL:-0}"' >"$fixture/libexec/validate-pi-security-runtime"
  chmod +x "$fixture/libexec/validate-pi-security-runtime"
  local failure
  for failure in 0 43 44 1.2.3 2.0.0 0.9.0 1.0.9 NaN.1.0 1.NaN.0 .1.0 2..0 2 2.1e2.0 0x2.1.0 2.-1.0 2.Infinity.0 2.+1.0 9007199254740992.1.0 2.9007199254740992.0 "" "2. .0"; do
    export CI_GATE_FAIL=0 CI_NATIVE_FAIL=0 CI_PI_VERSION=1.1.0
    if [[ "$failure" == 43 ]]; then export CI_GATE_FAIL=43; fi
    if [[ "$failure" == 44 ]]; then export CI_NATIVE_FAIL=44; fi
    case "$failure" in
      0 | 43 | 44) ;;
      1.2.3 | 2.0.0)
        CI_PI_VERSION=$failure
        failure=0
        ;;
      *)
        CI_PI_VERSION=$failure
        failure=1
        ;;
    esac
    unset PI_TEST_HOST_ROOT PI_TEST_PERMISSION_ROOT PI_TEST_SUBAGENTS_ROOT PI_TEST_LSP_ROOT
    rm -f "$TEST_ROOT/ci-events"
    printf '' >"$GITHUB_ENV"
    printf '' >"$GITHUB_PATH"
    run bash -c '
      set -euo pipefail
      cd "$1"
      while IFS= read -r block; do
        bash -e -c "$(printf "%s" "$block" | base64 --decode)"
        set -a; source "$GITHUB_ENV"; set +a
        while IFS= read -r directory; do export PATH="$directory:$PATH"; done <"$GITHUB_PATH"
      done < <(jq -r '\''.jobs.validate.steps[] | select(has("run") and .name != "Install shell tooling") | .run | @base64'\'' "$2")
    ' _ "$fixture" "$steps"
    if [[ "$failure" == 0 ]]; then
      [ "$status" -eq 0 ]
      [ "$(<"$TEST_ROOT/ci-events")" = $'provision\ncheck\ngate\nnative' ]
      jq -e --arg version "$CI_PI_VERSION" '.pi.version == $version and .permission.version == "30.0.0" and .subagents.version == "23.4.0" and .lsp.version == "0.49.9"' "$RUNNER_TEMP/pi-candidates.json"
    else
      [ "$status" -eq "$failure" ]
      if [[ "$failure" == 1 ]]; then
        [[ "$output" == *"Pi SDK 1.1+ required; resolved $CI_PI_VERSION"* ]]
        [ "$(<"$TEST_ROOT/ci-events")" = provision ]
      fi
    fi
  done
}

@test "versions rejects unknown commands" {
  run bash "$REPO_ROOT/libexec/versions" unknown
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
  run rg -n 'Lazy![[:space:]]+restore' "$REPO_ROOT/bin/dot-install"
  [ "$status" -eq 0 ]
  run rg -n 'Lazy![[:space:]]+(sync|update)' "$REPO_ROOT/bin/dot-install"
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
  *neovim/neovim*) printf '{"tag_name":"v0.12.4"}\n' ;;
  *tree-sitter/tree-sitter*) printf '{"tag_name":"v0.26.11"}\n' ;;
  *gambtho/herdr-devcontainer*) printf '{"tag_name":"v0.2.0"}\n' ;;
  *tmustier/pi-queue-steer*|*registry.npmjs.org/pi-web-access/*|*registry.npmjs.org/@narumitw/pi-lsp/*|*registry.npmjs.org/@gotgenes/pi-subagents/*|*registry.npmjs.org/@gotgenes/pi-permission-system/*) exit 91 ;;
  *registry.npmjs.org/@getpaseo/cli/latest) printf '{"version":"0.11.2"}\n' ;;
  *registry.npmjs.org*) exit 92 ;;
esac
SCRIPT
  chmod +x "$STUB_BIN/curl"

  run env PATH="$PATH" bash "$REPO_ROOT/libexec/versions" check

  [ "$status" -eq 0 ]
  [[ "$output" == *"current artifact mise v2026.7.18"* ]]
  [[ "$output" == *"current artifact krew v0.5.0"* ]]
  [[ "$output" == *"current artifact yq v4.45.1"* ]]
  [[ "$output" == *"current artifact win32yank v0.1.1"* ]]
  [[ "$output" == *"current artifact herdr v0.8.0"* ]]
  [[ "$output" == *"current artifact neovim v0.12.4"* ]]
  [[ "$output" == *"current artifact tree-sitter-cli v0.26.11"* ]]
  [[ "$output" == *"current git herdr-devcontainer v0.2.0"* ]]
  [[ "$output" == *"current artifact nerd-fonts v3.4.0"* ]]
  [[ "$output" == *"current npm pi-paseo-runtime $PASEO_VERSION"* ]]
  [[ "$output" != *"pi-webui-runtime"* ]]
  [[ "$output" != *"pi-queue-steer"* ]]
  [[ "$output" != *"pi-web-access"* ]]
  [[ "$output" != *"pi-lsp"* ]]
  [[ "$output" != *"pi-subagents"* ]]
  [[ "$output" != *"pi-permission-system"* ]]
  [[ "$output" != *"pi-sandbox"* ]]
}

@test "versions check reports new pin drift and lookup failures" {
  stub_command mise 'exit 0'
  stub_command git 'printf "0000000000000000000000000000000000000000\tHEAD\n"'
  stub_command curl '
    url="${@: -1}"
    case "$url" in
      "https://api.github.com/repos/$PIN_LOOKUP_REPO/releases/latest")
        case "$PIN_LOOKUP_RESULT" in
          outdated) printf "{\"tag_name\":\"v9.9.9\"}\n" ;;
          transport) exit 22 ;;
          response) printf "{}\n" ;;
        esac
        ;;
      *dl.k8s.io*) printf "v1.37.0\n" ;;
      *registry.npmjs.org/@getpaseo/cli/latest) printf "{\"version\":\"0.11.2\"}\n" ;;
      *registry.npmjs.org*) exit 92 ;;
      *api.github.com*) printf "{\"tag_name\":\"v0.0.0\"}\n" ;;
      *) exit 91 ;;
    esac
  '

  local name repository kind current result
  while read -r name repository kind current; do
    for result in outdated transport response; do
      run bash -c 'export PIN_LOOKUP_REPO="$1" PIN_LOOKUP_RESULT="$2"; bash "$3/libexec/versions" check' \
        _ "$repository" "$result" "$REPO_ROOT"
      if [[ "$result" == outdated ]]; then
        [ "$status" -eq 0 ]
        [[ "$output" == *"outdated $kind $name $current -> v9.9.9"* ]]
      else
        [ "$status" -ne 0 ]
        [[ "$output" == *"error $kind $name: unable to query latest release for $repository"* ]]
        [[ "$output" != *"outdated $kind $name"* ]]
      fi
    done
  done <<'PINS'
neovim neovim/neovim artifact v0.12.4
tree-sitter-cli tree-sitter/tree-sitter artifact v0.26.11
herdr-devcontainer gambtho/herdr-devcontainer git v0.2.0
PINS
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
    run env PATH="$PATH" VERSION_LOOKUP_FAILURE="$failure" bash "$REPO_ROOT/libexec/versions" check

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

  run env PATH="$PATH" bash "$REPO_ROOT/libexec/versions" check

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

  run env PATH="$PATH" bash "$REPO_ROOT/libexec/versions" check

  [ "$status" -ne 0 ]
  [[ "$output" == *"error channel kubernetes: unable to query upstream stable channel"* ]]
  [[ "$output" != *"outdated channel kubernetes"* ]]
}

@test "versions update writes no pins when the Kubernetes channel lookup fails" {
  local fixture="$TEST_ROOT/fixture"
  mkdir -p "$fixture"
  cp -R "$REPO_ROOT/libexec" "$fixture/libexec"
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

  run bash "$fixture/libexec/versions" update

  [ "$status" -ne 0 ]
  [[ "$output" == *"no pins were updated"* ]]
  # The Git pins are written after the lookup, so an unnoticed failure would
  # show up here as a repo half-updated against an unverified channel.
  [ "$(grep '^PREZTO_REF=' "$fixture/config/versions.env")" = "PREZTO_REF=$PREZTO_REF" ]
  [ "$(grep '^ZSH_DEFER_REF=' "$fixture/config/versions.env")" = "ZSH_DEFER_REF=$ZSH_DEFER_REF" ]
}

@test "versions update keeps artifact bumps behind checksum review" {
  run rg -n 'checksum-reviewed manual update required' "$REPO_ROOT/libexec/versions"

  [ "$status" -eq 0 ]
}

@test "versions update leaves the Kubernetes channel operator-owned" {
  local fixture="$TEST_ROOT/fixture"
  # Copy whole directories rather than a hand-maintained file list: libexec/versions
  # sources siblings, and naming them individually makes an unrelated new
  # dependency fail this test for a reason that has nothing to do with the
  # Kubernetes channel.
  mkdir -p "$fixture"
  cp -R "$REPO_ROOT/libexec" "$fixture/libexec"
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

  run bash "$fixture/libexec/versions" update

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
  cp -R "$REPO_ROOT/libexec" "$fixture/libexec"
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

  run bash "$fixture/libexec/versions" update

  [ "$status" -ne 0 ]
  [[ "$output" == *"no pins were updated"* ]]
  # Neither pin may move: PREZTO_REF resolved fine, but writing it alone leaves
  # versions.env half-advanced with ZSH_DEFER_REF blank.
  [ "$(grep '^PREZTO_REF=' "$fixture/config/versions.env")" = "PREZTO_REF=$PREZTO_REF" ]
  [ "$(grep '^ZSH_DEFER_REF=' "$fixture/config/versions.env")" = "ZSH_DEFER_REF=$ZSH_DEFER_REF" ]
}
