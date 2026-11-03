#!/bin/bash

# Builds a signed Touchdown.app.
#
#   ./build.sh <output-dir>
#
# Used by install.sh. This fork builds from source only -- it ships no
# releases and has no auto-updater -- so there is no second consumer to keep
# byte-for-byte identical.
#
# Ad-hoc is the default signing identity. Upstream defaults to a Developer ID
# because an ad-hoc signed *auto-updater* breaks itself: every update lands a
# new cdhash, TCC stops recognising the app and the driver silently stops
# injecting clicks. With no updater that reasoning no longer applies, and the
# upstream maintainer's certificate is not on this machine, so defaulting to
# it only produced "no identity found". Override SIGN_IDENTITY to sign with a
# real certificate; an Apple Development cert is the one worth having, since
# its designated requirement is hash-free and the TCC grants then survive a
# rebuild.

set -e

OUT_DIR="${1:?usage: build.sh <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/version.sh"

APP="$OUT_DIR/$APP_NAME.app"
EXEC_PATH="$APP/Contents/MacOS/$APP_NAME"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# CFBundleVersion is a build number, distinct from the marketing version in
# version.sh. Deriving it from the commit count makes it monotonic without
# anyone having to remember to bump it, and the short SHA pins the exact
# source -- with two machines and ad-hoc builds, "which build is this?" is
# otherwise unanswerable. Falls back gracefully: the second machine was
# deployed by copying source, which may arrive without a .git directory.
if BUILD_NUMBER="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null)" \
   && [ -n "$BUILD_NUMBER" ]; then
    SOURCE_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)"
    git -C "$SCRIPT_DIR" diff --quiet HEAD 2>/dev/null || SOURCE_COMMIT="$SOURCE_COMMIT-dirty"
else
    BUILD_NUMBER="0"
    SOURCE_COMMIT="unknown"
fi

echo "🔨 Compiling $APP_NAME $VERSION (build $BUILD_NUMBER, $SOURCE_COMMIT)..."
# swiftc writes straight into OUT_DIR, so it has to exist first or ld fails
# with a bare errno=2 that looks nothing like a missing directory.
mkdir -p "$OUT_DIR"
cd "$SCRIPT_DIR"
# Pin the deployment target. Without -target, swiftc stamps LC_BUILD_VERSION
# with the *build host's* OS, so a build made on macOS 27 gets minos 27.2 and
# refuses to launch on anything older -- while Info.plist still advertises
# LSMinimumSystemVersion 11.0. To a user on an older OS that looks like
# "installs cleanly, then does nothing", with nothing in the log to explain it.
#
# 11.0 to match the plist. Keep the two in step: the vendored Sparkle sets the
# real floor (2.9.6 is minos 11.0), so raising either without checking that
# floor ships a binary the feed advertises to machines that cannot run it.
#
# uname -m rather than a literal arm64, so an Intel host still builds natively.
TARGET="$(uname -m)-apple-macos11.0"

swiftc TouchscreenDriver.swift main.swift -o "$OUT_DIR/.$APP_NAME.bin" \
    -target "$TARGET" \
    -framework IOKit \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework AppKit \
    -O
echo "✅ Compiled"

echo "📦 Building app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$OUT_DIR/.$APP_NAME.bin" "$EXEC_PATH"
chmod +x "$EXEC_PATH"

# The icon is committed rather than generated here: make-icon.swift needs a
# full AppKit render and the artwork changes far less often than the code.
# Without Contents/Resources and the CFBundleIconFile key below, macOS falls
# back to the generic placeholder everywhere the app is listed -- most visibly
# the Privacy & Security panes, which is where a driver is actually looked at.
if [ -f "$SCRIPT_DIR/$APP_NAME.icns" ]; then
    cp "$SCRIPT_DIR/$APP_NAME.icns" "$APP/Contents/Resources/"
else
    echo "⚠️  $APP_NAME.icns missing -- building with the generic icon."
    echo "   Regenerate it with: swift make-icon.swift . && iconutil -c icns $APP_NAME.iconset -o $APP_NAME.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>TDSourceCommit</key>
    <string>$SOURCE_COMMIT</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# A hardened runtime and a secure timestamp are rejected for ad-hoc
# signatures, so they only go on when signing with a real certificate.
SIGN_FLAGS=(--force)
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

# One call: the bundle holds no nested code now that Sparkle's framework, its
# two XPC services and Updater.app are gone, so there is nothing to sign
# inside-out and nothing for --deep to get wrong.
echo "🔐 Signing with: $SIGN_IDENTITY"
codesign "${SIGN_FLAGS[@]}" -s "$SIGN_IDENTITY" "$APP"

codesign --verify --strict "$APP"
echo "✅ Signed and verified: $APP"
