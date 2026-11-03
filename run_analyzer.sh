#!/bin/bash

# Builds and runs the HID analyzer.
#
# This produces a BARE BINARY, not a bundle, so it has no TCC identity of its
# own: macOS attributes its HID access to the terminal you run it from. That
# means Input Monitoring has to be granted to Terminal for the analyzer to see
# anything -- a broad, persistent privilege for a shell to hold. Revoke it
# when you are done.
#
# The driver never needs this. It runs as a signed bundle with its own TCC
# record, which is the whole reason this fork ships an .app rather than a
# binary in /usr/local/bin.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Compiling HIDAnalyzer.swift..."
swiftc HIDAnalyzer.swift -o HIDAnalyzer \
    -framework IOKit \
    -framework CoreFoundation \
    -O

echo "✅ Compiled"
echo ""
echo "🚀 Starting the analyzer..."
echo "   (Ctrl+C to quit)"
echo ""

./HIDAnalyzer
