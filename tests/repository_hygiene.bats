#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "system package manifests do not install mise-owned runtimes" {
  run rg -n '^(go|node|ruby|python(@.*)?|openjdk(@.*)?|openjdk-[0-9].*|neovim)$|^brew "(go|node|ruby|python(@.*)?|openjdk(@.*)?|neovim)"$' \
    "$REPO_ROOT/platforms/macos/brewfile" \
    "$REPO_ROOT/platforms/linux/ubuntu_apt" \
    "$REPO_ROOT/platforms/linux/wsl_apt" \
    "$REPO_ROOT/platforms/linux/server_apt"
  [ "$status" -eq 1 ]
}

@test "mise versions are concrete" {
  run rg -n '= "(latest|stable)"' "$REPO_ROOT/config/mise/config.toml"
  [ "$status" -eq 1 ]
}

@test "custom mise version dispatchers are removed" {
  [ ! -e "$REPO_ROOT/bin/mise-helper" ]
  [ ! -e "$REPO_ROOT/languages/mise/lang.sh" ]
  run rg -n 'mise-helper|install_or_update|get_version_from_mise|languages/mise/lang.sh' \
    "$REPO_ROOT/bin" "$REPO_ROOT/languages" --glob '!docs/**'
  [ "$status" -eq 1 ]
}

@test "dot-update delegates without manipulating mise versions" {
  run rg -n 'mise (upgrade|outdated|latest|use)' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 1 ]
  run rg -n 'exec .*bin/install|exec .*dirname.*install' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 0 ]
}
