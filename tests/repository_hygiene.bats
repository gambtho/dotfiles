#!/usr/bin/env bats

load test_helper

setup() {
  setup_dotfiles_test
}

@test "every bash executable declares uniform strict mode" {
  # Without -u a misspelled variable expands to empty in the scripts that build
  # $HOME paths, rm symlinks, and drive sudo apt; without pipefail every
  # `cmd | filter` pipeline reports the filter's status. The exemptions are
  # deliberate, not backlog:
  #   sourced libraries    run in the caller's shell and must not mutate its
  #                        options (bin/common.sh, bin/log-helper, bin/lib/*,
  #                        core/git/identity-lib.sh)
  #   status-branching CLIs  bin/gh and bin/git-identity branch on non-zero
  #                        statuses throughout and pin `set -uo pipefail`
  local file lax=""
  while IFS= read -r -d '' file; do
    case "$file" in
      bin/common.sh | bin/log-helper | core/git/identity-lib.sh) continue ;;
      bin/lib/*) continue ;;
      bin/gh | bin/git-identity)
        grep -q '^set -uo pipefail$' "$REPO_ROOT/$file" || lax="$lax $file"
        continue
        ;;
    esac
    grep -q '^set -euo pipefail$' "$REPO_ROOT/$file" || lax="$lax $file"
  done < <(cd "$REPO_ROOT" && bin/list-check-files bash)
  [ -z "$lax" ] || {
    printf 'missing strict mode:%s\n' "$lax"
    false
  }
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
  # Retired per-project overlays contain details about non-public codebases.
  # This repo is public, so anything tracked under projects/ is a leak -- whether it arrives via
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

@test "every core/git example template is actually tracked" {
  # A local .git/info/exclude pattern of "git/" once matched core/git/ as well
  # as the legacy top-level git/, so new templates there were silently dropped:
  # `git add` refuses an ignored path but still exits 0, so `git add -A &&
  # git commit` succeeded without the file and only CI noticed.
  local f
  for f in "$REPO_ROOT"/core/git/*.example; do
    [ -e "$f" ] || continue
    run git -C "$REPO_ROOT" ls-files --error-unmatch "${f#"$REPO_ROOT/"}"
    [ "$status" -eq 0 ]
  done
}

@test "no bin/dev wrapper is reintroduced" {
  # `dev` collides with the "run the dev server" meaning in every repo it is
  # typed in, so no workspace tool gets that name. bin/pm (the ProjectMux
  # wrapper this assertion used to also pin) went with the ProjectMux
  # installer; Herdr is invoked as `herdr` and needs no wrapper.
  # -L alongside -e because -e follows the link: a dangling bin/dev symlink is
  # invisible to -e alone, and a leftover link pointing at a deleted wrapper
  # is precisely the state this assertion exists to catch.
  [ ! -e "$REPO_ROOT/bin/dev" ]
  [ ! -L "$REPO_ROOT/bin/dev" ]
  [ ! -e "$REPO_ROOT/bin/pm" ]
  [ ! -L "$REPO_ROOT/bin/pm" ]
  run rg -n 'bin/dev' "$REPO_ROOT/tools" "$REPO_ROOT/bin" "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]
}
