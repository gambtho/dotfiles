#!/usr/bin/env bash
# Unprivileged preparation only: no root publication or live daemon takeover.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec /usr/bin/python3 -I -B "$SCRIPT_DIR/prepare.py" "$@"
