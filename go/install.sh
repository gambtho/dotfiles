#!/usr/bin/env bash

set -e

source "$(dirname "$0")/../bin/common.sh"

export GO_VERSION=1.23.3

install_or_update "go" "$GO_VERSION" "go version | awk '{print \$3}' | sed 's/go//'"
