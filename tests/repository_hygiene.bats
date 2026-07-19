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

@test "tracked files do not contain editor or generated backups" {
  run git -C "$REPO_ROOT" ls-files '*backup*' '*.bak' '*.orig'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tracked blobs stay below five megabytes" {
  run bash -c '
    root="$1"
    while IFS=$'\''\t'\'' read -r -d "" metadata path; do
      object="${metadata#* }"
      object="${object%% *}"
      size=$(git -C "$root" cat-file -s "$object")
      if [ "$size" -gt 5242880 ]; then
        echo "$size $path"
      fi
    done < <(git -C "$root" ls-files -s -z)
  ' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
