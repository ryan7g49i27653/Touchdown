#!/bin/bash

# Touchdown installer — Corsair Xeneon Edge touchscreen driver for macOS
#
# Builds via build.sh, installs to ~/Applications, registers a LaunchAgent.
# No sudo at any point.
#
# Why a bundle and not a bare binary in /usr/local/bin:
# macOS TCC will not register a raw Mach-O executable for Accessibility.
# A bare binary never appears in the Privacy & Security list at all, so the
# permission can never be granted and the driver can never inject clicks.
# Only a code-signed .app with a CFBundleIdentifier gets a TCC record.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/version.sh"

APP="$HOME/Applications/$APP_NAME.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="$BUNDLE_ID.plist"
EXEC_PATH="$APP/Contents/MacOS/$APP_NAME"
# Must match logPath in TouchscreenDriver.swift, which the Open Log menu opens.
# ~/Library/Logs is 0700, so the log is not readable by other users -- unlike
# /tmp, which is 1777 and where this used to live.
LOG_PATH="$HOME/Library/Logs/$APP_NAME.log"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Touchdown — Xeneon Edge touch driver for macOS           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Stop the running copy before replacing the bundle on disk.
if launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
    echo "⏹️  Unloading existing LaunchAgent..."
    launchctl unload "$LAUNCH_AGENTS_DIR/$PLIST_NAME" 2>/dev/null || true
fi
# -x, not -f: -f matches the whole command line, so "pkill -f Touchdown"
# also matches any shell or editor whose arguments merely contain the word --
# including the shell running this script. -x matches the process name only.
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "⏹️  Stopping existing driver..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

# Build into a staging dir, then swap into place, so a failed compile leaves
# the working install untouched.
"$SCRIPT_DIR/build.sh" "$STAGE"

echo "📦 Installing to $APP..."
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$STAGE/$APP_NAME.app" "$APP"

echo "📦 Installing LaunchAgent..."
mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$LAUNCH_AGENTS_DIR/$PLIST_NAME" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXEC_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
</dict>
</plist>
PLIST
echo "✅ LaunchAgent installed"

echo "🚀 Starting..."
mkdir -p "$(dirname "$LOG_PATH")"
rm -f "$LOG_PATH"
# Builds before 2026-11-03 logged to /tmp, which is world-readable. Clear the
# old file on upgrade rather than leaving its contents sitting there.
rm -f /tmp/touchdown.log
launchctl load "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Installed $APP_NAME $VERSION. Starts automatically at login."
echo ""
echo "⚠️  Grant two permissions to $APP_NAME.app:"
echo "   → Privacy & Security → Accessibility"
echo "   → Privacy & Security → Input Monitoring"
echo ""
echo "   Developer ID signed, so these survive future updates."
echo "   You only do this once."
echo ""
echo "Commands:"
echo "  Stop:    launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
echo "  Start:   launchctl load ~/Library/LaunchAgents/$PLIST_NAME"
echo "  Status:  pgrep -x $APP_NAME && echo Running || echo Stopped"
echo "  Logs:    tail -f $LOG_PATH"
echo "════════════════════════════════════════════════════════════"
