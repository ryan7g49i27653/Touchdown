# Touchdown — working notes

Context for anyone (human or agent) picking this up. `README.md` is the user-facing doc; this file is the state of play and the reasoning that is expensive to rediscover.

## What this is

A macOS driver that makes taps on a Corsair Xeneon Edge (14.5", 2560×720) land where you touch. Fork of [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver).

The hardware exposes two USB HID interfaces:

| Usage page / usage | Meaning | What macOS does |
|---|---|---|
| `0x0D` / `0x04` | Digitizer, Touch Screen | **Ignored** — macOS has no HID digitizer support |
| `0x01` / `0x02` | Generic Desktop, Mouse | Used, but read as *relative* deltas |

So out of the box a tap clicks wherever the cursor already sits. The driver seizes the digitizer interface exclusively, maps its coordinates to absolute screen space, and injects `CGEvent` clicks.

Controller is `wch.cn` VID `0x27c0` / PID `0x0859`.

## Machine roles

- **Client** — where the panel is plugged in and the driver runs. Needs only `./install.sh`.
- **Build machine** — holds the Developer ID certificate and the Sparkle signing key, and is the only machine that cuts releases. Run `./setup-release-machine.sh` there to audit readiness.

Keep the signing keys on the build machine only. Nothing needs to be exported to a client.

## Status — client bring-up complete (2026-08-21)

Both items that were outstanding here are cleared. The driver has now run against real touch input for the first time: permissions granted, taps landing under the finger across the full 2560×720, and the inherited calibration confirmed correct.

Getting there required fixing two real bugs — see *First hardware bring-up* below. Neither was visible until the driver was actually receiving events, which is why both survived into a shipped release.

> **Whose machine is this?** The sections on the build machine, Sparkle keys and release cutting describe the **upstream maintainer's** setup. This working copy is a downstream fork run by a user who does not hold those keys and does not cut releases. Read them as inherited context, not as a description of this machine.

### Deployment on this machine

- `~/Applications/Touchdown.app`, **ad-hoc signed** (`SIGN_IDENTITY=-`), built from locally patched source — *not* the published release.
- Sparkle auto-update **disabled**: `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` are both false under `com.bencolson.touchdown`. Menu bar → *Check for Updates…* still works on demand. These prefs are per-user and per-machine, so they do **not** travel with a copied bundle.
- Per-touch coordinate logging **off by default** — see `LogTouchPoints` below.
- Ad-hoc means **every rebuild revokes both permissions**. Budget a re-grant *and* a driver restart per rebuild. An Apple Development certificate would remove this cost entirely; none is installed here.

### Second machine

A second Mac (same Apple Silicon architecture, same panel) runs the same patched build. It was deployed by copying **source**, not the `.app` bundle, and building there with `SIGN_IDENTITY=- ./install.sh`.

Prefer that over copying the bundle, for three reasons that all disappear when you build locally: the binary gets that machine's architecture; `minos` is stamped with *that* machine's OS rather than this one's (see the rough edge below); and a locally compiled app never acquires a quarantine attribute, so Gatekeeper never has to weigh in on an ad-hoc signature.

Two things do **not** travel and must be redone per machine: the TCC grants, and the Sparkle auto-update prefs — both `defaults` keys are per-user and per-machine, so a copied bundle silently arrives with auto-update *enabled*.

### Where the patched source lives

This directory is **not a git checkout** — no `.git`, so the local patches have no history and there is no way to diff against upstream or pull his changes. The canonical copy of the patch is the PR above. `vendor/` (107 MB) is fetched by `fetch-sparkle.sh` and is regenerable; upstream's `.gitignore` excludes it along with `dist/`.

## First hardware bring-up (2026-08-21)

Two bugs, both fixed in this fork's `TouchscreenDriver.swift`, neither fixed upstream as of v1.5.0.

**Submitted upstream** as [bencolson/Touchdown#1](https://github.com/bencolson/Touchdown/pull/1) on 2026-08-21 — both fixes plus the `LogTouchPoints` gate, as three independent hunks touching only `TouchscreenDriver.swift`. Note the repo has **Issues disabled** (GitHub's default for forks, almost certainly unintentional), so the PR body carries the full bug reports; there is nowhere else to file them. Two further findings are described there but deliberately *not* fixed, because both need a maintainer decision: the no-retry behaviour after a refused HID open, and the `minos` mismatch below.

If that PR is merged and released, this working copy's patches become redundant — but do not re-enable auto-update on the strength of that alone. Check that the shipped build actually contains the fixes first.

### 1. The `IOHIDManager` died as soon as `attachDriver()` returned

**Symptom:** every step reports success — device found, exclusive seize granted, menu bar `Active`, log prints `🎯 Driver active` — and then zero HID events arrive, ever. Touching the screen does nothing and logs nothing.

**Cause:** `manager` was a local constant in `attachDriver()` and the only strong reference to it. The function returns *before* `NSApplication.run()` begins servicing the run loop, so ARC released the manager and tore down its run loop source before any callback could fire.

This is a regression from the fork's own restructuring, not an upstream bug. Upstream created the manager inside `main()` and ended with `CFRunLoopRun()`, so the local lived as long as the process; splitting the work into a function that returns orphaned it.

**Fix:** a `var hidManager: IOHIDManager?` global, assigned immediately after `IOHIDManagerCreate`. The codebase already used this exact pattern for `screenObserver` to keep its `DispatchSourceTimer` alive — same hazard, handled correctly a few dozen lines earlier.

**Generalisable lesson:** a successful `IOHIDManagerOpen` and a successful seize tell you *nothing* about whether callbacks will arrive. They are independent, and the failure mode between them is completely silent.

### 2. `findXeneonDisplayID()` picked the wrong display, then overwrote the right answer

**Symptom:** on a three-display setup every tap mapped onto a different monitor entirely — while the startup log looked perfectly correct.

**Cause:** two functions disagreed, and the wrong one won. `setupScreen()` matches the panel **by name** and got it right. `findXeneonDisplayID()` independently took "the first display that is not the main one", ignoring the name. `updateScreenFromCurrentList()` then runs on *every* HID event and recomputes geometry from `xeneonDisplayID` — so the correct startup geometry was discarded on the very first touch.

Observed here with three displays attached: the main display was `id=3`, elimination picked an unrelated secondary monitor at `id=1`, and the Xeneon was `id=2` — so the panel was never the one selected, and every tap mapped onto the wrong monitor.

**Fix:** derive the ID from `targetScreen` via its `NSScreenNumber` device description, keeping elimination only as a fallback. Also added the missing `findXeneonDisplayID()` calls to the two paths that reassign `targetScreen` without refreshing the ID — the `didChangeScreenParametersNotification` handler and `checkForGeometryChanges()` — which otherwise leave it stale after any display rearrangement, even with only two displays.

### Grant both permissions *before* the driver attaches

The two permissions are checked at different times and only one recovers on its own:

- **Accessibility** is polled every 2s, so granting it mid-run is picked up without a restart, as the README promises.
- **Input Monitoring** is only evaluated inside `IOHIDManagerOpen()`. That path sets `.failed("HID open refused")` and **returns without scheduling a retry** — unlike the device-not-found path, which retries every 3s.

So granting Accessibility first lets the driver run straight at the HID open while Input Monitoring is still missing, fail with `kIOReturnNotPermitted` (`-536870174` / `0xE00002E2`), and park there permanently. Grant **both** before it attaches, or restart it after:

```bash
launchctl unload ~/Library/LaunchAgents/com.bencolson.touchdown.plist; sleep 2; launchctl load ~/Library/LaunchAgents/com.bencolson.touchdown.plist
```

After an ad-hoc rebuild the old TCC entry still appears in the Privacy list but points at the previous `cdhash`, so it looks granted while being inert. Clear it rather than toggling:

```bash
tccutil reset Accessibility com.bencolson.touchdown && tccutil reset ListenEvent com.bencolson.touchdown
```

### Calibration is confirmed correct

`touchscreenMaxX` / `touchscreenMaxY` = `16383` / `9599` are **right** for this unit. Verified by tapping all four physical corners and reverse-mapping the injected coordinates back to raw HID values. Offsets are given relative to the panel's own top-left origin, so they hold regardless of where the panel sits in the desktop arrangement:

| Corner | Offset within panel | Raw X | Raw Y |
|---|---|---|---|
| top-left | `+20, +21` | 128 | 280 |
| bottom-left | `+33, +698` | 211 | 9306 |
| top-right | `+2531, +30` | 16197 | 400 |
| bottom-right | `+2532, +709` | 16204 | 9452 |

Panel is 2560×720, so a perfect corner tap would read `+0, +0` through `+2560, +720`. Raw X spanned `128..16204` of `0..16383`; raw Y spanned `280..9452` of `0..9599`.

The ~1–3% inset at every edge is finger contact area, not a scaling error. **The test that distinguishes the two:** a wrong maximum produces an *asymmetric* result, because raw 0 maps to the origin edge regardless of scale — inset would be ~0% at one end and large at the other. Symmetric insets at both ends of both axes mean the scale is right. No `run_analyzer.sh` pass needed.

Also confirmed: 4 taps produced exactly 4 clicks, so the 50ms debounce holds under exclusive capture.

### `LogTouchPoints`

`injectClick()` logged a line per touch to `/tmp/touchdown.log` with no rotation and no purge, accumulating a detailed record of screen usage. Now gated behind a runtime flag, off by default:

```bash
defaults write com.bencolson.touchdown LogTouchPoints -bool true
```

Restart the driver to pick it up. Runtime rather than compile-time deliberately: ad-hoc rebuilds cost two permission re-grants, and debugging calibration should not require paying that.

## Provenance of the published v1.5.0 build

Independently audited before install (2026-08-21). Recorded so it is not redone from scratch.

- Fetched from the appcast's own enclosure URL. Length matched (`1107060`). SHA-256 `db6dee97df87ea2e54a22dbd898021bcf8627ca0fec22aea3b1d67de7ae12add`.
- The live feed's `edSignature` **verifies** against that zip under `PUBLIC_ED_KEY` — checked with an independent Ed25519 implementation rather than the bundled `sign_update`, so the result does not depend on the project's own tooling.
- `codesign` valid, team `99L757HY7N`, hardened runtime, secure timestamp. `spctl` reports `accepted` / `source=Notarized Developer ID`; stapled ticket validates.
- Designated requirement contains **no `cdhash`** — it pins bundle ID and team, which is what makes grants survive updates.
- The main binary imports **zero networking symbols** — no `URLSession`, no `CFNetwork`, no sockets. Its only path string is `/tmp/touchdown.log`. No `CGEventTapCreate` (so it cannot read keystrokes despite holding Accessibility), and no `posix_spawn` / `dlopen` / `system`. Imported symbols match the reviewed source one-to-one.
- Bundle contains one binary plus stock Sparkle. No extra executables, no scripts, no entitlements.
- `build.sh` **re-signs** the vendored Sparkle with the project's own certificate, so its signature cannot prove it unmodified. Checked directly instead: with signatures stripped, the shipped `Sparkle` binary and all four helpers (`Autoupdate`, `Downloader`, `Installer`, `Updater`) are **byte-identical** to the official 2.9.6 release — whose tarball hash also matches the pin in `fetch-sparkle.sh`.

v1.5.0 is clean. This covers **that build only**: the auto-updater makes every future release a fresh trust decision, inheriting TCC grants automatically because the designated requirement pins team rather than hash. That is precisely why auto-update is disabled here.

## Installing, and the three ways to sign

`install-release.sh` is the client path: it reads the appcast, downloads the published build, and installs it with no Xcode, no clone and no signing identity. It is deliberately self-contained so it works over `curl | bash`, which is why it duplicates the LaunchAgent plist and a few constants from `install.sh` — **keep the two in step**. `uninstall.sh` has the same standalone fallback for the same reason.

It refuses to install unless the build passes three checks: intact signature, team `99L757HY7N`, and Gatekeeper acceptance. All three are needed — `codesign --verify` **passes on an ad-hoc build**, so on its own it would not catch a substituted one. Verified by running an ad-hoc build against all three: signature passed, team and Gatekeeper both rejected.

`install.sh` builds from source and needs the Developer ID cert, so it is effectively build-machine-only. For development elsewhere, override the identity — and prefer an Apple Development cert over ad-hoc:

| `SIGN_IDENTITY` | Designated requirement | Grants survive rebuild? |
|---|---|---|
| unset (Developer ID) | `identifier` + `subject.OU` | yes — and survives updates |
| `Apple Development: …` | `identifier` + `subject.CN` | yes |
| `-` (ad-hoc) | `cdhash H"…"` | **no** — new hash every compile |

Both non-ad-hoc requirements were confirmed hash-free by building with each. Since the driver does nothing at all without Accessibility *and* Input Monitoring, ad-hoc costs two re-grants per rebuild. Note a dev-signed build holds TCC grants separately from a release build, so switching between them costs one re-grant.

## Release state — v1.5.0 is live

Shipped 2026-08-17. The feed is live and Sparkle will offer this to any install that polls it.

- Release: `https://github.com/bencolson/Touchdown/releases/tag/v1.5.0`
- Feed: `https://raw.githubusercontent.com/bencolson/Touchdown/main/appcast.xml`

Verified against the artifact **GitHub actually serves**, fetched fresh from the feed's own enclosure URL — not against the local build: byte length matches the enclosure (1107060), the live feed's `edSignature` verifies against the downloaded zip, `spctl` reports `accepted` / `source=Notarized Developer ID`, the stapled ticket survives the `ditto` round-trip, and the embedded `SUFeedURL` / `SUPublicEDKey` are correct.

The release machine, its Developer ID certificate, its notarization profile and the Sparkle signing key all belong to the **upstream maintainer** — not to this working copy, which holds none of them.

> **Redacted here.** Upstream's version of this file records his key-backup location and restore procedure, his Apple ID, and his certificate identity. That has been removed from this copy: it is third-party operational detail, unusable without his private keys, and it does not belong in a fork that may be pushed publicly. It remains in upstream's own `CLAUDE.md` if ever needed.

The parts worth keeping, because they are general engineering facts rather than his infrastructure:

- **The Sparkle key can no longer be regenerated**, only migrated. `PUBLIC_ED_KEY` is embedded in a published build, so if every copy of the private half is lost, no installed client can ever accept another update — there is no recovery path.
- **Cut releases from a GUI login session.** `codesign` and `sign_update` reach private keys only with the login keychain unlocked in an `Aqua` session. Over SSH the keychain returns *"User interaction is not allowed"* and signing fails with `errSecInternalComponent`; run `security unlock-keychain` first if you must work remotely.
- **`release.sh --no-push`** publishes the GitHub release and commits the appcast while leaving the push to you. Sparkle reads the feed from `main`, so an unpushed appcast means no installed copy sees the update yet — that gap is the review window. `--dry-run` publishes nothing but still notarizes when `NOTARY_PROFILE` is set.

## Established facts, so they are not re-derived

### TCC and signing

macOS keys Accessibility and Input Monitoring differently depending on signature type:

| Signing | TCC keys on | Consequence |
|---|---|---|
| None (bare Mach-O) | nothing — **no TCC record at all** | Never appears in the permission list; permission can never be granted |
| Ad-hoc | `cdhash` | Every rebuild revokes both permissions |
| Developer ID | bundle ID + team ID | Grants survive rebuilds and updates |

This is why the app is a bundle and why it is Developer ID signed. Both were bugs in the original: a bare binary in `/usr/local/bin` could not be granted Accessibility at all (`tccutil reset` reported *"No such bundle identifier"* — there was no record to toggle), and ad-hoc signing would have made every Sparkle update silently break the driver.

Verify the requirement contains no hash:

```bash
codesign -d --requirements - ~/Applications/Touchdown.app
# designated => identifier "com.bencolson.touchdown" and anchor apple generic
#   and certificate leaf[subject.OU] = "99L757HY7N"
```

Because it pins `subject.OU` — the **team** — and not a certificate, any Developer ID Application cert from the same team satisfies it. Issue a fresh one on a new build machine rather than exporting a private key.

### Notarization is mandatory, not cosmetic

Sparkle downloads updates over the network, so macOS quarantines them, and Gatekeeper rejects unnotarized Developer ID apps. An unnotarized update installs and then refuses to launch. `release.sh` therefore refuses to publish without `NOTARY_PROFILE`; `ALLOW_UNNOTARIZED=1` exists only for local testing.

### Archive with `ditto`, never `zip`

`zip` mangles a signed bundle's symlink farm and the signature stops validating. Verified by extracting a `ditto` archive and re-checking: *"valid on disk"*, *"satisfies its Designated Requirement"*.

### Never call `exit()` on a recoverable failure

The LaunchAgent uses `KeepAlive { SuccessfulExit = false }`, so any non-zero exit is relaunched. The original called `AXIsProcessTrustedWithOptions(prompt: true)` then `exit(1)`, producing an unbounded loop of stacked system dialogs — 14 before it was stopped. Missing permission, a refused HID open, and an absent device now all report state and stay resident. A clean `exit(0)` is the only correct exit, and is what the single-instance guard and the Quit menu item use.

### Single instance matters

Sparkle relaunches the app itself after installing while launchd may also start one. Two instances would both attempt an exclusive HID seize and fight over the device, so the newer one exits.

### Sparkle key is account-scoped

`SPARKLE_KEY_ACCOUNT="touchdown"` in `version.sh` keeps this key distinct from other Sparkle keys that may exist on the build machine. Sparkle's own advice is that one key can serve all your apps, which holds only when they are equally trusted — this repo and its release pipeline are public, so a shared key would let a leak here forge updates for a private app. `--account` also means generating this key cannot clobber an existing one.

### Releases are cut locally, not in CI

`.github/workflows/build.yml` verifies compilation, bundle layout, ad-hoc signing and `@rpath` linkage. It deliberately does not release: that needs both private keys, and putting them in GitHub secrets would place the signing identity for all future updates on a shared runner. Ad-hoc builds skip `--options runtime` and `--timestamp`, which `codesign` rejects for ad-hoc signatures.

## Known rough edges

- **Display naming varies by unit.** This file used to state flatly that the panel reports as `Type-C`, so the name match in `setupScreen()` always fails and selection is by elimination. On the unit tested 2026-08-21 it reports **`XENEON EDGE`** and the name match succeeds. Treat `Type-C` as one possible name rather than the rule — and note that the disagreement between name-matching and elimination is exactly what produced the display bug documented above.
- **Comments are still French.** Upstream is French throughout; user-facing strings were translated but ~109 comment lines were not, to keep the diff against upstream reviewable. Translating them is mechanical if desired.
- **Swift 6 language mode is not enabled.** `swiftc` defaults to Swift 5 mode, which is why the mutable globals mutated from the C HID callback compile without concurrency errors. Do not add `-swift-version 6` expecting a no-op.
- **`touchscreenMaxX/Y` are verified** as of 2026-08-21 — `16383` / `9599` are correct on this unit. See the calibration table above for the method and the raw numbers.
- **A build's minimum OS is the build host's, not `LSMinimumSystemVersion`.** `build.sh` never passes `-target`, so `swiftc` stamps the host's version into `LC_BUILD_VERSION`. A build made on macOS 26 reports `minos 26.0` and will not launch on anything older, while `Info.plist` still advertises `LSMinimumSystemVersion 11.0`. To a user on an older OS this looks like "installs cleanly, then does nothing". Probably affects the published release too, depending on the maintainer's build host. Building on the target machine sidesteps it entirely — which is the main reason to prefer shipping source over a copied `.app`.
- **Upstream attribution is intentional.** `README.md` credits the original author and notes the project's AI co-authorship. That describes upstream's work, not this fork's, and should not be stripped.
