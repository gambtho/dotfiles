#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/../../libexec/common.sh"

if [ "$(uname)" == "Darwin" ]; then
  log_info "Updating macOS software..."
  softwareupdate -i -a
  log_success "macOS software update completed."
fi
