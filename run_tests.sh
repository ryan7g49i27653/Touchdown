#!/bin/bash

# Runs the test suite.
#
#   ./run_tests.sh
#
# Compiles tests/main.swift against the driver's own TouchscreenDriver.swift --
# the real declarations, not a copy -- and runs the result. The driver's
# main.swift is deliberately excluded: Swift allows top-level code in exactly
# one file per module, so choosing which main.swift to compile is what selects
# "test binary" or "driver".
#
# No -target pin here. Tests run on the build host and are never shipped, so
# they should use whatever the host offers; the deployment target only matters
# for the binary that gets installed.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "🔨 Building tests..."
swiftc TouchscreenDriver.swift tests/main.swift -o "$OUT/tests" \
    -framework IOKit \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework AppKit

"$OUT/tests"
