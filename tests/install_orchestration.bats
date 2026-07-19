#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
  source "$REPO_ROOT/bin/common.sh"
}

@test "required phase failure makes summary fail" {
  run bash -c 'source "$1/bin/common.sh"; run_phase required packages false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED: packages"* ]]
}

@test "optional phase failure is reported without failing install" {
  run bash -c 'source "$1/bin/common.sh"; run_phase optional fonts false; finish_phases' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: fonts"* ]]
}

@test "remote installer is denied without explicit consent" {
  run bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
}

@test "remote installer is allowed with explicit consent" {
  run env ALLOW_REMOTE_INSTALLERS=1 bash -c 'source "$1/bin/common.sh"; require_remote_installers' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "remote installer passes arguments after the downloaded script" {
  local fake_bin="$TEST_ROOT/fake-bin"
  local result="$TEST_ROOT/remote-installer-args"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
while (($# > 0)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cat >"$output" <<'INSTALLER'
printf '%s\n' "$*" >"$REMOTE_INSTALLER_RESULT"
INSTALLER
SCRIPT
  chmod +x "$fake_bin/curl"

  run env ALLOW_REMOTE_INSTALLERS=1 PATH="$fake_bin:$PATH" REMOTE_INSTALLER_RESULT="$result" \
    bash -c 'source "$1/bin/common.sh"; run_remote_installer https://example.test/install.sh sh "{}" --yes' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(cat "$result")" = "--yes" ]
}

@test "remote scripts are never piped directly to a shell" {
  run rg -n 'curl.*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh|/bin/bash[[:space:]]+-c[[:space:]]+"\$\(curl' "$REPO_ROOT" \
    --glob '*.sh' \
    --glob 'bootstrap'
  [ "$status" -eq 1 ]
}

@test "non-interactive bootstrap requires an explicit profile" {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; parse_bootstrap_args --non-interactive; validate_bootstrap_options' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile is required"* ]]
}

@test "non-interactive bootstrap requires existing git identity" {
  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; parse_bootstrap_args --non-interactive --profile personal; validate_bootstrap_options' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git user.name and user.email are required"* ]]
}

@test "bootstrap flags enable remote installers without prompting" {
  git config --global user.name "Dotfiles Test"
  git config --global user.email "dotfiles@example.com"

  run env BOOTSTRAP_SOURCE_ONLY=1 HOME="$HOME" bash -c \
    'source "$1/bin/bootstrap"; parse_bootstrap_args --non-interactive --profile work --allow-remote-installers; validate_bootstrap_options; printf "%s %s %s\n" "$NON_INTERACTIVE" "$BOOTSTRAP_PROFILE" "$ALLOW_REMOTE_INSTALLERS"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "true work 1" ]
}

@test "work kubectl shortcuts use maintained krew plugins" {
  run rg -n 'raw\.githubusercontent\.com/blendle/kns' "$REPO_ROOT/work"
  [ "$status" -eq 1 ]

  run rg -n 'kubectl krew install ctx ns' "$REPO_ROOT/work/install.sh"
  [ "$status" -eq 0 ]

  run rg -n "alias ktx='kubectl ctx'|alias kns='kubectl ns'" "$REPO_ROOT/work/k8s-aliases.zsh"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
}
