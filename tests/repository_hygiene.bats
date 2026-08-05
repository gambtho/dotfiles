#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "system package manifests do not install mise-owned runtimes" {
  run rg -n '^(go|node|ruby|python(@.*)?|openjdk(@.*)?|openjdk-[0-9].*|neovim)$|^brew "(go|node|ruby|python(@.*)?|openjdk(@.*)?|neovim)"$' \
    "$REPO_ROOT/platforms/macos/brewfile" \
    "$REPO_ROOT/platforms/linux/packages" \
    "$REPO_ROOT/profiles/packages"
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

@test "README Quick Start uses the canonical repository owner" {
  run rg -n 'git clone .*github\.com[:/]gambtho/dotfiles' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "README documents pristine macOS bootstrap consent" {
  run rg -n 'ALLOW_REMOTE_INSTALLERS=1' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  run rg -n 'review.*Homebrew|Homebrew.*script' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "README does not claim dot-update advances Neovim plugins" {
  run rg -n 'dot-update.*(update|advance)s? [Nn]eovim [Pp]lugin|update packages, language runtimes, neovim plugins' "$REPO_ROOT/README.md"
  [ "$status" -eq 1 ]
  run rg -n 'restore.*lazy-lock\.json|lazy-lock\.json.*restore' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "README documents manual lazy.nvim lockfile advancement" {
  run rg -n ':Lazy (sync|update)' "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
}

@test "dot-update delegates without manipulating mise versions" {
  run rg -n 'mise (upgrade|outdated|latest|use)' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 1 ]
  run rg -n 'exec .*bin/install|exec .*dirname.*install' "$REPO_ROOT/bin/dot-update"
  [ "$status" -eq 0 ]
}

@test "the public repository tracks nothing under projects/" {
  # Per-project Claude overlays describe non-public codebases and live in a
  # separate private repo cloned to ~/.dotfiles/projects. This repo is public,
  # so anything tracked under projects/ is a leak -- whether it arrives via
  # `git add -f`, a mistaken merge-conflict resolution, or a future .gitignore
  # edit that reopens the path.
  run git -C "$REPO_ROOT" ls-files projects/
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tracked files do not contain editor or generated backups" {
  run git -C "$REPO_ROOT" ls-files '*backup*' '*.bak' '*.orig'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tracked files do not contain Python bytecode" {
  run git -C "$REPO_ROOT" ls-files '*.pyc' '*.pyo' '*.pyd' '*/__pycache__/*'
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
