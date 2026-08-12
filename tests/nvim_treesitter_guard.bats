#!/usr/bin/env bats

# Coverage for the tree-sitter CLI guard in config/nvim/init.lua.
#
# nvim-treesitter's `main` branch shells out to the `tree-sitter` CLI for every
# parser build, with no fallback to a bare `cc`. Without a working CLI each
# build emits `Error during "tree-sitter build": ... ENOENT ... 'tree-sitter'`,
# so the config must not ask for a build it cannot get, and must degrade to
# regex highlighting instead.
#
# This file exists because a real regression shipped without it: the startup
# install was guarded while the per-filetype auto-install was not, which moved
# the error wall from "11 errors at startup" to "one error per new filetype"
# rather than removing it. Hence the structural test below, which fails if any
# install call site is left ungated.

load test_helper

setup() {
  # Resolve the real nvim BEFORE setup_dotfiles_test narrows PATH to
  # /usr/bin:/bin. Distros ship an older nvim there — Debian bookworm has 0.9.5,
  # which predates vim.system() (added in 0.10) — so a bare `nvim` would probe a
  # binary that reports every stub as broken and make this suite pass vacuously.
  NVIM_BIN="$(command -v nvim || true)"

  setup_dotfiles_test
  INIT_LUA="$REPO_ROOT/config/nvim/init.lua"
  export INIT_LUA
}

# Extract the guard verbatim from init.lua and run it against a stubbed
# `tree-sitter`, so the assertions are about shipped code rather than a copy.
guard_verdict() {
  local guard="$TEST_ROOT/guard.lua"
  sed -n '/local ts_min = /,/^      end$/p' "$INIT_LUA" >"$guard"
  # Fail loudly rather than silently testing an empty chunk if the surrounding
  # code is reindented or the function renamed.
  grep -q 'function tree_sitter_cli_works' "$guard" ||
    {
      echo "could not extract tree_sitter_cli_works from $INIT_LUA" >&2
      return 2
    }
  echo 'io.write(tostring(tree_sitter_cli_works()))' >>"$guard"

  PATH="$STUB_BIN:/usr/bin:/bin" "$NVIM_BIN" --clean --headless \
    -c "luafile $guard" -c "qa!" 2>&1 | tr -d '\r'
}

@test "the CLI guard accepts only a version nvim-treesitter can build with" {
  [ -n "$NVIM_BIN" ] || skip "nvim not available"

  # nvim-treesitter's health.lua pins TREE_SITTER_MIN_VER = 0.26.1 and fails
  # every build below it. Debian still ships 0.20.x as `tree-sitter-cli`, so an
  # exit-code-only check would wave through a CLI that reproduces exactly the
  # error wall this guard exists to prevent.
  for v in 0.26.1 0.26.11 0.27.0 1.0.0; do
    stub_command tree-sitter "echo 'tree-sitter $v'"
    run guard_verdict
    [ "$output" = true ] || {
      echo "expected $v accepted, got: $output"
      false
    }
  done

  for v in 0.20.8 0.25.9 0.26.0; do
    stub_command tree-sitter "echo 'tree-sitter $v'"
    run guard_verdict
    [ "$output" = false ] || {
      echo "expected $v rejected, got: $output"
      false
    }
  done
}

@test "the CLI guard rejects a binary that is present but cannot run" {
  [ -n "$NVIM_BIN" ] || skip "nvim not available"

  # The bookworm case: upstream's binaries need glibc 2.39, the image has 2.36,
  # so the file is present and executable and still dies at exec time. An
  # executable() check alone passes here — running it is the check.
  stub_command tree-sitter \
    "echo 'tree-sitter: /lib/x86_64-linux-gnu/libc.so.6: version GLIBC_2.39 not found' >&2; exit 1"
  run guard_verdict
  [ "$output" = false ]
}

@test "the CLI guard rejects unparseable version output" {
  [ -n "$NVIM_BIN" ] || skip "nvim not available"

  stub_command tree-sitter "echo 'hello'"
  run guard_verdict
  [ "$output" = false ]
}

@test "the CLI guard gives up on a binary that never exits" {
  [ -n "$NVIM_BIN" ] || skip "nvim not available"

  # An unbounded wait() would hang nvim forever on the startup path. The guard
  # bounds it, so this must return rather than time the test out.
  stub_command tree-sitter "sleep 30"
  run guard_verdict
  [ "$output" = false ]
}

@test "the CLI guard rejects an absent binary" {
  [ -n "$NVIM_BIN" ] || skip "nvim not available"

  rm -f "$STUB_BIN/tree-sitter"
  run guard_verdict
  [ "$output" = false ]
}

@test "every nvim-treesitter install call site is gated on the CLI probe" {
  # The regression this file was written for: install() is called from two
  # places — once at startup for the base parser set, once from the FileType
  # autocmd to auto-install the parser for the buffer being opened. Guarding
  # only the first leaves the second re-downloading and failing the build on
  # every new filetype. Assert the property directly, since a behaviour test
  # for the autocmd would need a full plugin install to run.
  run awk '
    /require\(.nvim-treesitter.\)\.install\(/ {
      sites++
      guarded = 0
      for (i = 1; i <= 4; i++) if (prev[i] ~ /ts_cli_ok/) guarded = 1
      if ($0 ~ /ts_cli_ok/) guarded = 1
      if (!guarded) print "UNGATED install at line " NR ": " $0
    }
    { for (i = 4; i > 1; i--) prev[i] = prev[i-1]; prev[1] = $0 }
    END { print "sites=" sites }
  ' "$INIT_LUA"

  [ "$status" -eq 0 ]
  [[ "$output" != *UNGATED* ]] || {
    echo "$output"
    false
  }
  # Pin the count: a new, unnoticed call site should fail here rather than be
  # silently accepted by a check that only looks at the ones it knows about.
  [[ "$output" == *"sites=2"* ]] || {
    echo "expected 2 install sites, got: $output"
    false
  }
}
