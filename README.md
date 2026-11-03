# Touchdown

A macOS driver that converts touch input from the Corsair Xeneon Edge (14.5" touch bar, 2560x720) into mouse clicks at the correct absolute screen position.

Without it, macOS ignores the panel's HID digitizer interface (usage page `0x0D`, usage `0x04`) entirely and falls back to its Generic Desktop Mouse interface, which it reads as *relative* deltas. A tap becomes "click wherever the cursor already is" instead of "click here."

> Fork of [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver), originally co-authored by [Yves-Marie Lainé](https://github.com/ymlaine) and Claude.

> ⚠️ **This working copy carries local patches not present in the published v1.5.0 release.** Two bugs fixed — the `IOHIDManager` being released on return from `attachDriver()` (driver reported "Active" while receiving no events at all), and `findXeneonDisplayID()` selecting the wrong display when three or more are connected. Per-touch logging is also now off by default behind `LogTouchPoints`. See `CLAUDE.md` → *First hardware bring-up* for the full detail. Installing the published release over this copy reverts all of it.

## What this fork changes

**Installs as a signed `.app` bundle, not a bare binary.** macOS TCC will not register a raw Mach-O executable for Accessibility — it never appears in the Privacy & Security list, so the permission can't be granted and clicks can never be injected. `tccutil reset Accessibility` on the installed binary confirms it: *"No such bundle identifier."* There was no record to toggle. Only a code-signed bundle with a `CFBundleIdentifier` gets a TCC record.

**No more permission-dialog storm.** Upstream calls `AXIsProcessTrustedWithOptions` with `prompt: true` and then `exit(1)` when the grant is missing. Combined with the LaunchAgent's `KeepAlive { SuccessfulExit = false }`, launchd relaunches on every failure and each launch throws a fresh dialog — an unbounded loop of stacked prompts. This fork prompts once, then polls `AXIsProcessTrusted()` silently every 2s and proceeds the moment you grant it. No relaunch, no second dialog, no restart needed.

**No sudo.** Installs to `~/Applications` and `~/Library/LaunchAgents` instead of `/usr/local/bin`, which is root-owned. Nothing root-owned to clean up.

**A menu bar icon** (`hand.rays`), so the driver's state is visible instead of log-only. Upstream runs completely invisibly — if it's stuck waiting on a permission or can't find the panel, there's no way to tell without `tail`ing a file in `/tmp`. The icon dims while waiting, goes solid when active, and turns red on failure. Its menu shows the target display and offers redetect / open log / quit.

**Survives failure instead of exiting.** Upstream calls `exit(1)` when the HID open is refused or the panel isn't found — which, under `KeepAlive`, is the same relaunch-loop trap as the permission bug. This fork reports the failure in the menu bar and stays up; a missing panel retries every 3s, so unplugging and replugging the Xeneon just works.

**`LSUIElement`** plus `.accessory` activation policy so it stays out of the Dock and ⌘-Tab, and `uninstall.sh` clears the TCC records so a later reinstall prompts cleanly.

Released builds are Developer ID signed and notarized, so the designated requirement pins the bundle ID and team rather than a hash — **permission grants survive updates**. Only ad-hoc local builds (`SIGN_IDENTITY=-`) are hash-pinned and void the grants on every rebuild.

## Menu bar

The status item uses the `hand.rays` SF Symbol as a template image. The app icon uses `hand.tap.fill` instead — an outlined glyph with thin rays is right for a monochrome menu bar mark and turns to mush when rendered as icon art, so the two are drawn from different symbols on purpose.

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
- Xcode Command Line Tools (`xcode-select --install`) — **only** to build from source; installing the release needs nothing

> **Minimum OS is pinned, not inherited.** `build.sh` passes `-target $(uname -m)-apple-macos11.0`, so the binary's `LC_BUILD_VERSION` matches what `Info.plist` advertises regardless of which macOS the build host runs. Without that flag `swiftc` stamps the *host's* version instead — a build produced on macOS 27 would report `minos 27.2` and refuse to launch on anything earlier, installing cleanly and then doing nothing. The vendored Sparkle 2.9.6 is itself `minos 11.0`, so 11.0 is the real floor; raise one without the other and the feed advertises a build some machines cannot run. Check with `vtool -show-build <binary>`.

## Installation

### From the release (recommended)

No Xcode, no clone, no signing identity:

```bash
curl -fsSL https://raw.githubusercontent.com/bencolson/Touchdown/main/install-release.sh | bash
```

This reads the same appcast Sparkle reads, downloads the published build, and
**refuses to install it unless it passes three checks**: an intact signature,
team `99L757HY7N`, and Gatekeeper acceptance (i.e. genuinely notarized). It then
installs to `~/Applications`, registers the LaunchAgent, and starts it. No sudo.

`--dry-run` verifies the current release and installs nothing.

Note that `codesign --verify` alone is not sufficient — an ad-hoc signature is
internally valid too. The team and Gatekeeper checks are what make a substituted
build fail.

### From source

Needs a Developer ID Application certificate for the team, so in practice this
is the build machine only:

```bash
git clone https://github.com/bencolson/Touchdown.git
cd Touchdown
./install.sh
```

Compiles, signs, installs to `~/Applications`, registers the LaunchAgent, and
starts it. Without that certificate it fails at `codesign` with *"no identity
found"* — use the release installer above instead.

To hack on the driver without the Developer ID, override the identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./install.sh
```

Prefer that over ad-hoc (`SIGN_IDENTITY=-`). Ad-hoc pins the designated
requirement to a `cdhash`, so **every rebuild voids both permission grants** and
this driver does nothing at all until both are re-granted. An Apple Development
identity produces a hash-free requirement, so the grants survive rebuilds.

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
pgrep -f Touchdown && echo "Running" || echo "Stopped"

# Logs
tail -f /tmp/touchdown.log

# Stop
launchctl unload ~/Library/LaunchAgents/com.bencolson.touchdown.plist

# Start
launchctl load ~/Library/LaunchAgents/com.bencolson.touchdown.plist
```

## Updating

Releases are published through [Sparkle](https://sparkle-project.org) 2.9.6, fed by `appcast.xml` in this repo.

> **This fork does not start the updater.** `StatusController` creates no `SPUStandardUpdaterController`, and the menu has no **Check for Updates…** item, so a build from this source never polls the feed and never installs an update — on purpose. The framework is still vendored and embedded, so restoring both is a one-commit revert. `appcast.xml`, `release.sh` and `install-release.sh` are untouched and still work; updating an installed copy means running `install-release.sh` or `install.sh` again.

### Why this needs a Developer ID

TCC keys permissions differently depending on how the app is signed:

| Signing | TCC keys on | Effect on updates |
|---|---|---|
| Ad-hoc | `cdhash` of the binary | **Every update voids Accessibility and Input Monitoring** |
| Developer ID | bundle ID + team ID | Permissions survive every update |

An ad-hoc signed auto-updater breaks itself: each update installs a binary with a new hash, TCC no longer recognises it, and the driver silently stops injecting clicks until you re-grant both permissions by hand. `build.sh` therefore signs with a Developer ID by default. Verify the designated requirement has no hash in it:

```bash
codesign -d --requirements - ~/Applications/Touchdown.app
# designated => identifier "com.bencolson.touchdown" and anchor apple generic
#   and certificate leaf[subject.OU] = "99L757HY7N"
```

### Notarization is required, not optional

Sparkle downloads updates over the network, so macOS applies the quarantine attribute. Gatekeeper rejects an unnotarized Developer ID app, which means an unnotarized update installs and then refuses to launch. `release.sh` refuses to publish without a notarytool profile.

Set one up once:

```bash
xcrun notarytool store-credentials touchdown-notary \
  --apple-id <your-apple-id> \
  --team-id 99L757HY7N \
  --password <app-specific-password>   # appleid.apple.com → App-Specific Passwords
```

### Cutting a release

```bash
# 1. bump VERSION in version.sh
# 2. rehearse: builds, archives, signs, renders the appcast item, publishes nothing
./release.sh --dry-run "What changed."

# 3. ship it
NOTARY_PROFILE=touchdown-notary ./release.sh "What changed."
```

`release.sh` builds via `build.sh`, archives with `ditto` (plain `zip` mangles the signed bundle's symlinks and invalidates the signature), notarizes and staples, signs the archive with the Sparkle EdDSA key, publishes a GitHub release, prepends the item to `appcast.xml`, and pushes. It refuses to run against a dirty tree or a tag that already exists.

### Keys

Two private keys matter, both in the login Keychain and neither in this repo:

- **Developer ID certificate** — code signing.
- **Sparkle EdDSA key**, stored as *"Private key for signing Sparkle updates"*. Its public half is `SUPublicEDKey` in the app's `Info.plist`. **Back this up.** Lose it and no installed copy will ever accept another update, because signatures will stop matching the embedded public key — you would have to reinstall every client by hand.

Export it for backup with `vendor/sparkle/bin/generate_keys -x`.

### Setting up a build machine

Releases are cut from one designated machine that holds the keys; every other Mac is just a client running the driver. On the build machine:

```bash
git clone https://github.com/bencolson/Touchdown.git
cd Touchdown
./setup-release-machine.sh
```

It audits the toolchain, the Developer ID cert, `gh` auth, the notarytool profile, and the Sparkle key, then does a test build and prints the resulting designated requirement.

What actually has to move between machines is narrower than it looks:

| | Migrate? | Why |
|---|---|---|
| Developer ID certificate | **No** | The designated requirement pins `subject.OU` — the *team* — not a specific certificate. Any Developer ID Application cert from the same team satisfies it, so issue a fresh one in Xcode and existing TCC grants still hold. |
| Sparkle EdDSA key | **Yes, after the first release** | Its public half is embedded in every installed copy's `Info.plist`. Sparkle rejects signatures that don't match, and there is no recovery path. |
| notarytool profile | No | Re-run `store-credentials`. |
| `gh` auth | No | Re-run `gh auth login`. |

Before the first release there is no installed base to honour, so the simplest move is to generate a fresh Sparkle key on the build machine, update `PUBLIC_ED_KEY` in `version.sh`, and reinstall once on each client. After the first release that option is gone — export and import the original instead:

```bash
# machine that has the key
vendor/sparkle/bin/generate_keys -x sparkle-key.txt
# build machine
vendor/sparkle/bin/generate_keys -f sparkle-key.txt
rm -P sparkle-key.txt
```

### Why releases are cut locally, not in CI

`.github/workflows/build.yml` verifies that the driver compiles, bundles, signs ad-hoc, and links Sparkle via `@rpath` — but it does not release. Publishing needs both private keys, and putting them in GitHub secrets would place the signing identity for every future update on a shared runner. Releases are cut from a machine that already holds the keys.

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
| `version.sh` | Single source of truth for version, bundle ID, feed URL, public key |
| `build.sh` | Builds and signs `Touchdown.app` into a given directory |
| `install.sh` | Builds, installs to `~/Applications`, registers the LaunchAgent |
| `uninstall.sh` | Removes app, LaunchAgent, Sparkle caches, TCC records, legacy layouts |
| `release.sh` | Cuts a release: archive, notarize, sign, publish, update appcast |
| `fetch-sparkle.sh` | Downloads Sparkle and verifies its SHA-256 |
| `appcast.xml` | The Sparkle update feed clients poll |
| `run_driver.sh` | Build and run the driver in the foreground |
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
