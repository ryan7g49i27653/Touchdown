#!/bin/bash

# Builds a signed Touchdown.app.
#
#   ./build.sh <output-dir>
#
# Shared by install.sh and release.sh so the installed app and the released
# app are byte-for-byte the same recipe. Override SIGN_IDENTITY to change the
# signing identity, or set it to "-" for ad-hoc (permissions will then break
# on every update -- see the note in install.sh).

set -e

OUT_DIR="${1:?usage: build.sh <output-dir>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/version.sh"

APP="$OUT_DIR/$APP_NAME.app"
EXEC_PATH="$APP/Contents/MacOS/$APP_NAME"
SPARKLE="$SCRIPT_DIR/vendor/sparkle/Sparkle.framework"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Benjamin Colson (99L757HY7N)}"

"$SCRIPT_DIR/fetch-sparkle.sh"

if [ ! -d "$SPARKLE" ]; then
    echo "❌ Sparkle.framework missing at $SPARKLE"
    exit 1
fi

echo "🔨 Compiling $APP_NAME $VERSION..."
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

# @executable_path/../Frameworks so the embedded Sparkle is found at runtime.
swiftc TouchscreenDriver.swift -o "$OUT_DIR/.$APP_NAME.bin" \
    -target "$TARGET" \
    -framework IOKit \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework AppKit \
    -F "$SCRIPT_DIR/vendor/sparkle" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -O
echo "✅ Compiled"

echo "📦 Building app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
mv "$OUT_DIR/.$APP_NAME.bin" "$EXEC_PATH"
chmod +x "$EXEC_PATH"

# -R preserves the framework's symlink farm, which codesign requires intact.
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

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
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SUFeedURL</key>
    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

# Hardened runtime and a secure timestamp are required for notarization, but
# both are rejected for ad-hoc signatures -- so CI (SIGN_IDENTITY=-) omits them.
SIGN_FLAGS=(--force)
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Sign inside-out: nested code first, then the framework, then the app.
# --deep is unreliable for Sparkle's XPC services and Updater.app.
echo "🔐 Signing with: $SIGN_IDENTITY"
SP="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SP/Versions/B/XPCServices/Downloader.xpc" \
    "$SP/Versions/B/XPCServices/Installer.xpc" \
    "$SP/Versions/B/Updater.app" \
    "$SP/Versions/B/Autoupdate"
do
    [ -e "$nested" ] || continue
    codesign "${SIGN_FLAGS[@]}" -s "$SIGN_IDENTITY" "$nested"
done
codesign "${SIGN_FLAGS[@]}" -s "$SIGN_IDENTITY" "$SP"
codesign "${SIGN_FLAGS[@]}" -s "$SIGN_IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"
echo "✅ Signed and verified: $APP"
