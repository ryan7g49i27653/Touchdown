# Touchdown

A macOS driver that converts touch input from the Corsair Xeneon Edge (14.5" touch bar, 2560x720) into mouse clicks at the correct absolute screen position.

Without it, macOS ignores the panel's HID digitizer interface (usage page `0x0D`, usage `0x04`) entirely and falls back to its Generic Desktop Mouse interface, which it reads as *relative* deltas. A tap becomes "click wherever the cursor already is" instead of "click here."

> Fork of [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver), originally co-authored by [Yves-Marie Lainé](https://github.com/ymlaine) and Claude.

> ⚠️ **This working copy carries local patches not present in the published v1.5.0 release.** Two bugs fixed — the `IOHIDManager` being released on return from `attachDriver()` (driver reported "Active" while receiving no events at all), and `findXeneonDisplayID()` selecting the wrong display when three or more are connected. Per-touch logging is also now off by default behind `LogTouchPoints`. See `CLAUDE.md` → *First hardware bring-up* for the full detail. Installing the published release over this copy reverts all of it.

## What this fork changes

**Installs as a signed `.app` bundle, not a bare binary.** macOS TCC will not register a raw Mach-O executable for Accessibility — it never appears in the Privacy & Security list, so the permission can't be granted and clicks can never be injected. `tccutil reset Accessibility` on the installed binary confirms it: *"No such bundle identifier."* There was no record to toggle. Only a code-signed bundle with a `CFBundleIdentifier` gets a TCC record.

**No more permission-dialog storm.** Upstream calls `AXIsProcessTrustedWithOptions` with `prompt: true` and then `exit(1)` when the grant is missing. Combined with the LaunchAgent's `KeepAlive { SuccessfulExit = false }`, launchd relaunches on every failure and each launch throws a fresh dialog — an unbounded loop of stacked prompts. This fork prompts once, then polls `AXIsProcessTrusted()` silently every 2s and proceeds the moment you grant it. No relaunch, no second dialog, no restart needed.

**No sudo.** Installs to `~/Applications` and `~/Library/LaunchAgents` instead of `/usr/local/bin`, which is root-owned. Nothing root-owned to clean up.

**A menu bar icon** (`hand.rays`), so the driver's state is visible instead of log-only. Upstream runs completely invisibly — if it's stuck waiting on a permission or can't find the panel, there's no way to tell without `tail`ing a file in `/tmp`. The icon dims while waiting, goes solid when active, and turns red on failure. Its menu shows the target display and offers redetect / open log / about / quit.

**Survives failure instead of exiting.** Upstream calls `exit(1)` when the HID open is refused or the panel isn't found — which, under `KeepAlive`, is the same relaunch-loop trap as the permission bug. This fork reports the failure in the menu bar and stays up; a missing panel retries every 3s, so unplugging and replugging the Xeneon just works.

**`LSUIElement`** plus `.accessory` activation policy so it stays out of the Dock and ⌘-Tab, and `uninstall.sh` clears the TCC records so a later reinstall prompts cleanly.

**No auto-updater.** Upstream bundles Sparkle and polls an appcast daily. This fork removed it outright — no framework, no feed, no *Check for Updates…*, no update UI of any kind. It builds from source only, so updating means pulling and re-running `./install.sh`. That also means the bundle embeds no third-party code at all.

## Menu bar

The status item uses the `hand.rays` SF Symbol as a template image. The app icon uses `hand.tap.fill` instead — an outlined glyph with thin rays is right for a monochrome menu bar mark and turns to mush when rendered as icon art, so the two are drawn from different symbols on purpose.

The menu shows the current state and target display, then offers **Redetect Display**, **Open Log**, **About Touchdown** and **Quit Touchdown**. About opens the standard macOS panel with the app icon, name, version and a one-paragraph description.

| Icon | Meaning |
|---|---|
| Dimmed | Waiting on Accessibility permission, or waiting for the panel to appear |
| Solid | Active — taps are being mapped to clicks |
| Red | HID open refused (usually Input Monitoring missing, or another app holds the device) |

## Features

- Converts touch events to mouse clicks at the touched position
- Exclusive HID capture (no double clicks)
- Multi-monitor support with automatic screen detection
- Cursor returns to original position after click
- Adapts to resolution changes (including HiDPI/scaled modes)
- Dynamic reconfiguration when displays are rearranged

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Touchscreen    │────▶│  Driver          │────▶│  macOS          │
│  (USB HID)      │     │  (exclusive)     │     │  (CGEvent)      │
└─────────────────┘     └──────────────────┘     └─────────────────┘
   Raw X, Y coords        Convert & map          Click at absolute
   Button events          to screen space        position
```

## Requirements

- macOS 11+ (Big Sur or later)
- Corsair Xeneon Edge connected via USB-C
- Xcode Command Line Tools (`xcode-select --install`)

> **Minimum OS is pinned, not inherited.** `build.sh` passes `-target $(uname -m)-apple-macos11.0`, so the binary's `LC_BUILD_VERSION` matches what `Info.plist` advertises regardless of which macOS the build host runs. Without that flag `swiftc` stamps the *host's* version instead — a build produced on macOS 27 would report `minos 27.2` and refuse to launch on anything earlier, installing cleanly and then doing nothing. Check with `vtool -show-build <binary>`; CI asserts it.

## Installation

This fork builds from source. There is no published build to download.

```bash
git clone https://github.com/bencolson/Touchdown.git
cd Touchdown
./install.sh
```

Compiles, signs ad-hoc, installs to `~/Applications`, registers the LaunchAgent,
and starts it. No sudo, no Developer ID, no network access during the build.

Ad-hoc pins the designated requirement to a `cdhash`, so **every rebuild voids
both permission grants** and the driver does nothing at all until both are
re-granted. If you rebuild often, an Apple Development certificate is worth
having — its requirement is hash-free, so the grants survive:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./install.sh
```

### Uninstall

```bash
./uninstall.sh
```

Or, if you installed from the release and have no clone:

```bash
curl -fsSL https://raw.githubusercontent.com/bencolson/Touchdown/main/uninstall.sh | bash
```

### Manual

```bash
git clone https://github.com/bencolson/Touchdown.git
cd Touchdown
chmod +x run_driver.sh run_analyzer.sh
./run_driver.sh
```

### Grant Permissions

Grant both to **`Touchdown.app`** — not to Terminal, and not to a bare binary:

1. **Accessibility** — to inject mouse clicks
   - System Settings → Privacy & Security → Accessibility
2. **Input Monitoring** — to capture HID events (exclusive seize)
   - System Settings → Privacy & Security → Input Monitoring

**Grant both before the driver attaches, or restart it afterwards.** The two permissions are not checked the same way. Accessibility is polled every 2 seconds, so granting it mid-run is picked up without a restart. Input Monitoring is only evaluated inside `IOHIDManagerOpen()`, and that path does not retry — so if Accessibility is granted first, the driver runs straight at the HID open while Input Monitoring is still missing, fails with `kIOReturnNotPermitted`, and stays parked there until restarted:

```bash
launchctl unload ~/Library/LaunchAgents/com.bencolson.touchdown.plist; sleep 2; launchctl load ~/Library/LaunchAgents/com.bencolson.touchdown.plist
```

If the app doesn't appear in the list, drag `~/Applications/Touchdown.app` in directly.

### Control Commands

```bash
# Status
pgrep -x Touchdown && echo "Running" || echo "Stopped"

# Logs
tail -f ~/Library/Logs/Touchdown.log

# Stop
launchctl unload ~/Library/LaunchAgents/com.bencolson.touchdown.plist

# Start
launchctl load ~/Library/LaunchAgents/com.bencolson.touchdown.plist
```

## Updating

There is no updater. Pull and reinstall:

```bash
git pull && ./install.sh
```

Budget a re-grant of both permissions afterwards: an ad-hoc signature pins the
designated requirement to a `cdhash`, and recompiling changes it. See
[Installation](#installation) for the Apple Development certificate that avoids
this.

### What was removed, and why it is not coming back

Upstream ships [Sparkle](https://sparkle-project.org) and polls an appcast once
a day. This fork removed the framework, the feed, the release pipeline and the
signing keys outright. The reasoning, in case it is ever revisited:

- **An ad-hoc signed auto-updater breaks itself.** Every update lands a binary
  with a new `cdhash`, TCC stops recognising the app, and the driver silently
  stops injecting clicks until both permissions are re-granted by hand. Keeping
  Sparkle therefore forces a Developer ID certificate, notarization, and a
  release pipeline to go with it.
- **That pipeline needs two private keys** — a Developer ID certificate and a
  Sparkle EdDSA key — neither of which this fork holds. The EdDSA key in
  particular has no recovery path: its public half is embedded in every
  installed copy, so losing it means no client can ever accept another update.
- **None of it bought anything here.** This is a two-machine, build-from-source
  fork. `git pull && ./install.sh` is the whole update story.

A consequence worth stating plainly: the bundle now embeds **no third-party
code at all**, and the build touches the network at no point.

## Calibration

The driver is pre-calibrated for the Xeneon Edge touchscreen:
- X range: 0 - 16383
- Y range: 0 - 9599
- Touch detection: Button 1 (HID Usage Page 0x09)

These were confirmed correct on real hardware (2026-08-21) by tapping all four physical corners and reverse-mapping the injected coordinates to raw HID values — see `CLAUDE.md` for the data. Note that a small inset at each edge is finger contact area, not a calibration error: a genuinely wrong maximum shows up as an *asymmetric* result, near-zero inset at the origin end and large at the far end.

### Re-calibrate (if needed)

If touch positions are incorrect, use the analyzer:

```bash
./run_analyzer.sh
```

Touch the screen corners and note the X/Y max values, then update `TouchscreenDriver.swift`:

```swift
var touchscreenMaxX: CGFloat = 16383  // Your X max
var touchscreenMaxY: CGFloat = 9599   // Your Y max
```

## Hardware Info

```
Touchscreen Controller:
  Vendor ID:  0x27c0
  Product ID: 0x0859
  Manufacturer: wch.cn

Display:
  Native resolution: 2560x720 (32:9 ratio)
  Recommended: 1920x540 scaled (better readability)
```

## Files

| File | Description |
|------|-------------|
| `TouchscreenDriver.swift` | Main driver: HID capture, CGEvent injection, menu bar |
| `HIDAnalyzer.swift` | Diagnostic tool to inspect raw HID reports |
| `make-icon.swift` | Regenerates `Touchdown.icns`; not run by the build |
| `Touchdown.icns` | App icon, committed so builds need no render step |
| `version.sh` | Single source of truth for app name, bundle ID and version |
| `build.sh` | Builds and signs `Touchdown.app` into a given directory |
| `install.sh` | Builds, installs to `~/Applications`, registers the LaunchAgent |
| `uninstall.sh` | Removes app, LaunchAgent, caches, TCC records, legacy layouts |
| `run_driver.sh` | Build and run the driver in the foreground, unbundled |
| `run_analyzer.sh` | Build and run the analyzer |

## Troubleshooting

### "Touchscreen not found"
- Ensure the Xeneon Edge is connected via USB-C
- Check USB connection in System Information → USB
- Verify Vendor/Product IDs match

### "Cannot open IOHIDManager"
- Grant Input Monitoring permission to Terminal
- Restart Terminal after granting permissions
- Close other apps using the touchscreen (iCUE, etc.)

### Clicks at wrong position
1. Run `./run_analyzer.sh` and touch screen corners
2. Update touchscreenMaxX/Y values in the code
3. Rebuild with `./run_driver.sh`

### Exclusive mode fails
Another app may be using the touchscreen. Either:
- Close conflicting apps (iCUE, etc.)
- Switch to shared mode (edit `TouchscreenDriver.swift`):
  ```swift
  var captureMode: CaptureMode = .shared
  ```
  Note: Shared mode may cause double clicks.

## Resolution Tips

The native 2560x720 resolution can make text hard to read. For better readability:

1. Go to **System Settings → Displays**
2. Select the Xeneon Edge
3. Choose **1920x540** (maintains 32:9 ratio, larger text)

The driver automatically adapts to any resolution.

## License

MIT License - Feel free to use and modify.

## Credits

Created by **Yves-Marie Lainé** in collaboration with **Claude** (Anthropic).

Built with Swift using IOKit HID and CoreGraphics frameworks.
