#!/usr/bin/env bash
# Aggregator kept for the ~20 scripts that `source bin/common.sh`. The library
# itself lives in bin/lib/, split by concern so a reader (or a new script that
# needs only one slice) can see which functions form which contract:
#
#   bin/lib/system.sh       command_exists, detect_os
#   bin/lib/phases.sh       run_phase / finish_phases install-phase runner
#   bin/lib/links.sh        the managed-symlink contract and shared link loop
#   bin/lib/artifacts.sh    pinned, digest-verified artifact acquisition
#   bin/lib/stable-root.sh  /opt/dotfiles stable root + worktree-aware slugs
#
# Vekil-specific auth checks moved out entirely: ai/vekil/token-lib.sh is
# sourced only by the Vekil tooling, so unrelated installers no longer load it.
#
# Each lib file is self-contained (sources its own dependencies) and safe to
# source directly; this file exists so existing consumers keep working and new
# top-level scripts can keep taking the whole library in one line.

source "$(dirname "${BASH_SOURCE[0]}")/log-helper"
source "$(dirname "${BASH_SOURCE[0]}")/lib/system.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/phases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/links.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/artifacts.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/stable-root.sh"
