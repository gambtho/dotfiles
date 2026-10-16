#!/usr/bin/env bash
# Explicit guided setup only; never called by ordinary installation/update.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec /usr/bin/python3 -I -B "$SCRIPT_DIR/onboard.py" "$@"
