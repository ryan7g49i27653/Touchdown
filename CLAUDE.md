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

## Break-glass: taps stopped working

Read the log first — it is the diagnosis, and every branch below is a line from it:

```bash
pgrep -x Touchdown; tail -20 ~/Library/Logs/Touchdown.log
```

Then match the symptom. After a macOS upgrade it is almost always **1** or **2**.

**1. `PERMISSION REQUIRED` → Accessibility is missing.** Major OS upgrades can clear TCC. This build is ad-hoc, so grants are pinned to the binary's `cdhash`; a stale entry stays visible in the Privacy list while being completely inert, so it looks granted when it is not. Clear rather than toggle, then re-add `~/Applications/Touchdown.app` to **both** lists, then restart (step 5):

```bash
tccutil reset Accessibility com.bencolson.touchdown && tccutil reset ListenEvent com.bencolson.touchdown
```

**2. `could not open IOHIDManager (code: -536870174)` → Input Monitoring is missing.** That is `0xE00002E2`, `kIOReturnNotPermitted`. This path does **not** retry, so the driver parks there permanently. Granting alone is not enough — you must restart it afterwards.

**3. `Touchscreen not found`, retrying every 3s → the panel is not visible on USB.**

```bash
ioreg -c IOHIDDevice -r -l | grep -c '"ProductID" = 2137'
```

Zero means macOS cannot see it at all — cable, port, or hardware. Non-zero while the driver still retries means something else holds the device; iCUE is the usual culprit.

**4. `Driver active` but nothing happens → the HID-manager fix has been lost.** This is the exact signature of the bug documented below: open and seize both succeed, so it advertises itself as working while receiving nothing. Verify the fix is still in the source, and that only one instance is running (two would fight over the exclusive seize):

```bash
grep -c hidManager ~/Projects/touchdown/TouchscreenDriver.swift   # expect 2
```

**5. Restart — required after any permission change:**

```bash
launchctl unload ~/Library/LaunchAgents/com.bencolson.touchdown.plist; sleep 2; launchctl load ~/Library/LaunchAgents/com.bencolson.touchdown.plist
```

**6. Taps land on the wrong monitor → the display fix has been lost.** `grep -c deviceDescription ~/Projects/touchdown/TouchscreenDriver.swift` should be `1`.

**7. Still broken — rebuild from source.** Costs one re-grant of both permissions, because ad-hoc signing produces a new `cdhash` every compile:

```bash
cd ~/Projects/touchdown && ./install.sh
```

If **4** or **6** ever fires, suspect the patched build was replaced — a stock build reports `Active` and silently does nothing. The fastest tell is the menu: this fork's build has **no *Check for Updates…* and no *Version* line, and does have *About Touchdown***. Confirm from the shell:

```bash
# This fork embeds no frameworks at all. A stock build has Sparkle in both.
test -d ~/Applications/Touchdown.app/Contents/Frameworks && echo "STOCK BUILD" || echo "this fork"
otool -L ~/Applications/Touchdown.app/Contents/MacOS/Touchdown | grep -c '@rpath/'   # expect 0
```

Nothing can replace it automatically — there is no updater and no feed — so a swapped build means someone copied a bundle in by hand.

## Machine roles

Both machines are clients: the panel is plugged in and the driver runs, installed with `./install.sh`. There is no build machine, because this fork publishes nothing.

Everything about Developer ID certificates, notarization profiles, Sparkle signing keys and release cutting was **upstream maintainer** infrastructure. It was removed on 2026-11-03 along with Sparkle itself — see *Sparkle removed* below. If you are reading an older commit and wondering where `release.sh`, `setup-release-machine.sh`, `install-release.sh`, `fetch-sparkle.sh` or `appcast.xml` went, that is where.

## Status — macOS 27.2 verified (2026-11-03)

The client was upgraded to macOS 27.2 (build 26B123, Xcode 27.2, Swift 6.4.2). **Nothing about the upgrade broke the driver**, and one assumption in this file turned out to be wrong in a good way.

- **TCC grants survived the OS upgrade.** The break-glass section warns that a major upgrade can clear TCC; it did not. The binary was untouched, so the `cdhash` the grants pin to was unchanged and both held. A major upgrade is not by itself a reason to re-grant — read the log first, as always.
- **Compiles clean against the 27.2 SDK**: zero warnings, no new deprecations. `IOHIDManagerOpen` with `kIOHIDOptionsTypeSeizeDevice`, `CGEvent.post(tap: .cghidEventTap)`, `CGWarpMouseCursorPosition`, `CGDisplayHideCursor` and `AXIsProcessTrustedWithOptions` are all unchanged.
- **Swift 5 language mode is still the default** under the Swift 6.4.2 toolchain — the mutable globals mutated from the C HID callback still compile. The rough edge below still stands.
- **Display selection still matches by name.** Three displays attached; `XENEON EDGE` matched directly and geometry survived six reconfiguration events.

### Calibration re-confirmed on macOS 27

Corner taps reverse-mapped through the injected coordinates, same method as the 2026-08-21 table. Panel at CGEvent origin `(855, 1440)`, so the panel spans `x: 855..3415`, `y: 1440..2160`.

| Corner | Injected | Offset within panel | Raw X | Raw Y |
|---|---|---|---|---|
| top-left | `(890, 1499)` | `+35, +59` | 224 | 787 |
| bottom-left | `(880, 2150)` | `+25, +710` | 160 | 9466 |
| bottom-right | `(3393, 2138)` | `+2538, +698` | 16242 | 9306 |
| top-right | `(3374, 1500)` | `+2519, +60` | 16121 | 800 |

Raw X spanned `160..16242` (insets 0.98% / 0.86% — symmetric). Raw Y spanned `787..9466` (insets 8.19% / 1.39%).

**The 8.19% top inset is not a scale error, and the asymmetry does not contradict the symmetry test below.** Raw 0 maps to the origin edge regardless of scale, so top and left insets measure *tap placement only* and carry no information about calibration — that round of taps simply landed ~8mm below the top edge. The informative ends are bottom and right, and because sloppy tapping can only ever *enlarge* an inset, those two figures are **upper bounds** on scale error at the far edge: `maxY` cannot be too large by more than ~1.4%. Nothing overflowed past the panel edge either (710 of 720, 2538 of 2560), which rules out the max being too *small*. So the test bounds the error rather than measuring it, which is all a regression check needs — the 2026-08-21 taps were tighter and pinned it more precisely, and no constant has changed since.

Four taps produced exactly four clicks, so the 50ms debounce still holds under exclusive capture on 27.

### Code review — five fixes (2026-11-03)

A hygiene/performance/security pass over the whole fork. The security half came out clean: the installed binary has **zero** networking symbols, links no network-capable framework, has no `CGEventTapCreate` (so it cannot read keystrokes despite holding Accessibility), no `system` / `posix_spawn` / `dlopen` / `NSTask`, no entitlements, and exactly one embedded path. That is a stronger result than the August audit of upstream's v1.5.0, because Sparkle — the only third-party code and the only route to the network — is gone.

Five things were fixed.

**1. The cursor could be hidden permanently.** `injectClick()` called `CGDisplayHideCursor`, then two `guard … else { return }` paths sat between it and the matching `CGDisplayShowCursor`. Those calls are *reference counted*, so each unbalanced hide raises the count for good and the cursor never comes back until the driver restarts. A `defer` now guarantees the pair. Verified with a control-flow harness: the old shape leaked 2 of 4 hides, the new one leaks none.

**2. A `NotificationCenter` observer accumulated every 3 seconds.** `addObserver(forName:object:queue:using:)` returns a token the centre retains until `removeObserver`; it was being discarded. Because `attachDriver()` built a fresh `ScreenChangeObserver` and the device-not-found path re-enters `attachDriver()` every 3s, an unplugged panel added one observation per retry — after an hour, ~1200 of them, each replaying `setupScreen()` (≈6 printed lines) on any display change. Fixed at both ends: the token is now stored and released in `deinit`, and `attachDriver()` only builds the observer when `screenObserver == nil`. Reproduced before (3 handler calls for one notification) and verified after (1). The GCD timers, incidentally, did *not* meaningfully leak — superseded objects were being collected.

**3. `pkill -f "$APP_NAME"` could kill unrelated processes.** `-f` matches the whole command line, so it matched any shell or editor whose arguments merely contained "Touchdown" — demonstrably including the shell running `install.sh`. Both scripts now use `pgrep -x` / `pkill -x`, which match the process name only.

**4. The log sat in `/tmp`.** `/tmp` is `1777` and the file was `0644`, so any process on the machine could read display names, geometry, and — with `LogTouchPoints` on — every touch coordinate. The `LogTouchPoints` gate protected the content but not the location. It now lives at `~/Library/Logs/Touchdown.log`; `~/Library` and `~/Library/Logs` are both `0700`, so the directory protects the file whatever its own mode is. `install.sh` deletes the old `/tmp` copy on upgrade. **`logPath` in the source and `StandardOutPath`/`StandardErrorPath` in the plist must stay in step** — the *Open Log* menu item uses the former.

**5. The panel-matching predicate existed twice.** `setupScreen()` and `checkForGeometryChanges()` each had their own copy of the `XENEON`/`Corsair` name test plus fallbacks. Two independent predicates that can disagree is *precisely* what produced the display bug below. There is now one `locateXeneonScreen()` returning a `ScreenMatch`, so the two callers cannot drift. A side effect: with a single display attached, `checkForGeometryChanges()` used to bail out entirely while `setupScreen()` fell back to `NSScreen.main`; they now agree.

Two things were looked at and deliberately **not** changed:

- **`updateScreenFromCurrentList()` on every HID event is not a performance problem.** Measured: `CGDisplayBounds` is ~11.2 µs, about 0.22% of one core at 200 events/s. It is redundant with the notification and the 2s timer, but it is not slow, and removing a geometry path has a worse track record here than leaving one.
- **The ~40 ms of `usleep` per click is load-bearing.** The HID callback runs on the main run loop, so `injectClick()` blocks it for 10+20+10 ms, which caps click throughput and briefly stalls the menu bar. Those sleeps exist to let the system register the cursor warp before the click lands; removing them risks clicks going to the wrong place. Left alone deliberately.

Also note `clickMode` and `captureMode` are never reassigned but are correctly `var`: they are source-level escape hatches (the HID-failure message tells you to edit `captureMode`), and `let` would raise dead-code warnings on the unused branch.

### App icon added (2026-11-03)

The bundle had no `Contents/Resources` and no `CFBundleIconFile`, so macOS drew the generic placeholder everywhere the app is listed — most visibly the Privacy & Security panes, which for a driver that needs two grants is exactly where it gets looked at.

`Touchdown.icns` is committed and `build.sh` copies it in; `make-icon.swift` regenerates it and is **not** run by the build:

```bash
swift make-icon.swift . && iconutil -c icns Touchdown.iconset -o Touchdown.icns
```

Two things worth not rediscovering:

- **32px is the size to design for, not 16px.** The Privacy lists lay out at 16pt, which on any Retina display draws the `@2x` asset. Judging the art at 16px leads you to over-simplify.
- **Outlined SF Symbols do not survive as icon art.** The first attempt reused `hand.rays` from the menu bar status item for continuity. It was an unreadable smudge at 16px and mush at 32px — the rays are hairlines. `hand.tap.fill` is filled and holds up. The menu bar keeps `hand.rays`, because a template image at menu bar size has the opposite constraint. Same reason the glyph drop shadow is skipped at or below 32px: the blur ends up wider than the strokes it sits under.

The glyph is nudged off geometric centre (`-1.0%` x, `+1.8%` y) because its mass sits bottom-right while the tap arc is light and top-left.

### About panel added (2026-11-03)

*About Touchdown* in the menu opens `NSApp.orderFrontStandardAboutPanel` — the system panel, so it inherits dark mode, layout and localisation rather than being a hand-built window. It carries the app icon, name, version and a one-paragraph description passed as `.credits`.

Two things in it are not obvious:

- **`.accessory` apps do not come forward on their own.** Without an explicit `NSApp.activate…` first, the panel opens *behind* whatever is frontmost and looks like nothing happened. The removed *Check for Updates…* item had exactly the same hazard and the same fix. `activate(ignoringOtherApps:)` is deprecated from macOS 14, so it is behind an `#available` check — the plain `activate()` on 14+, the old call below that. Without the check the build warns, and the deployment target is 11.0 so the old path is still reachable.
- **The icon is loaded explicitly, not inherited.** The panel otherwise takes `NSApp.applicationIconImage`, which stays generic until LaunchServices has indexed the bundle — common right after an install, which is exactly when someone opens About to check the build. So it reads `CFBundleIconFile` from the Info.plist and loads that `.icns` out of `Resources` directly. Taking the name from the plist rather than hard-coding it keeps it aligned with what `build.sh` writes.

Note the panel *does* show the version, which the menu deliberately no longer does. That was about menu clutter; About is where a version belongs.

A verification wrinkle: `strings` on the binary will not find `About Touchdown`, `Quit Touchdown` or `Open Log`. Swift stores string literals of 15 UTF-8 bytes or fewer inline in the `String` struct rather than in `__cstring`, so short menu titles are invisible to `strings` while `Redetect Display` (16 bytes) shows up. Grep for the `showAbout` selector instead.

### Sparkle removed entirely (2026-11-03)

Done in two steps on the same day, which is why the git history shows it twice.

**Step one — the update UI.** The menu lost *Check for Updates…* and the *Version* line, and `StatusController` stopped building an `SPUStandardUpdaterController`. Removing only the menu items would have left the updater running with no interface to reach it: `startingUpdater: true` schedules background checks independently of the menu, and `Info.plist` set `SUEnableAutomaticChecks` true while the pref that disables it is per-user and per-machine, so it never travelled with a bundle.

**Step two — everything else**, once it was clear the fork has no interest in maintaining an updater. Gone: the vendored framework (123 MB on disk), `-framework Sparkle` and the `@rpath` linker flag, `Contents/Frameworks`, the four `SU*` Info.plist keys, `FEED_URL` / `PUBLIC_ED_KEY` / `SPARKLE_KEY_ACCOUNT` / `REPO` from `version.sh`, and the files `fetch-sparkle.sh`, `appcast.xml`, `release.sh`, `setup-release-machine.sh` and `install-release.sh`.

Three consequences worth knowing:

- **The bundle embeds no third-party code**, and the build touches the network at no point. `Contents/` is now just `MacOS/`, `Resources/`, `Info.plist` and `_CodeSignature/`.
- **Signing is one `codesign` call.** The inside-out loop existed only because `--deep` is unreliable for Sparkle's two XPC services and `Updater.app`. With no nested code there is nothing for it to get wrong.
- **`build.sh` defaults to ad-hoc** (`SIGN_IDENTITY=-`) instead of the upstream maintainer's Developer ID. That default existed because an ad-hoc signed *auto-updater* breaks itself — each update lands a new `cdhash` and TCC stops recognising the app. With no updater the reasoning is gone, and the certificate was never on this machine, so the old default only ever produced "no identity found".

Verify a build is this fork's:

```bash
test -d ~/Applications/Touchdown.app/Contents/Frameworks && echo "STOCK BUILD" || echo "this fork"
```

`build.sh` also pins `-target $(uname -m)-apple-macos11.0`. This became load-bearing rather than theoretical: the first rebuild on 27.2 stamped `minos 27.2`, which would have refused to launch on the second machine. See the rough edge below.

## Status — client bring-up complete (2026-08-21)

Both items that were outstanding here are cleared. The driver has now run against real touch input for the first time: permissions granted, taps landing under the finger across the full 2560×720, and the inherited calibration confirmed correct.

Getting there required fixing two real bugs — see *First hardware bring-up* below. Neither was visible until the driver was actually receiving events, which is why both survived into a shipped release.

### Deployment on this machine

- `~/Applications/Touchdown.app`, **ad-hoc signed**, built from locally patched source. Ad-hoc is now `build.sh`'s default, so plain `./install.sh` is correct — the `SIGN_IDENTITY=-` prefix in older notes is no longer needed, though it is still honoured.
- **No updater of any kind** since 2026-11-03. Updating is `git pull && ./install.sh`.
- Per-touch coordinate logging **off by default** — see `LogTouchPoints` below.
- Ad-hoc means **every rebuild revokes both permissions**. Budget a re-grant *and* a driver restart per rebuild. An Apple Development certificate would remove this cost entirely; none is installed here. Stale `SU*` keys may linger in the preference domain from older builds; they are inert, and `uninstall.sh` clears them.

### Second machine

A second Mac (same Apple Silicon architecture, same panel) runs the same patched build. It was deployed by copying **source**, not the `.app` bundle, and building there with `./install.sh`.

Prefer that over copying the bundle, for two reasons that both disappear when you build locally: the binary gets that machine's architecture, and a locally compiled app never acquires a quarantine attribute, so Gatekeeper never has to weigh in on an ad-hoc signature. `minos` used to be a third reason; `build.sh` now pins it, so it no longer varies by host.

The **TCC grants** do not travel and must be redone per machine. That is now the only thing that does not — the Sparkle prefs that used to be the other half of this warning no longer exist.

### Where the patched source lives

This **is** a git checkout now — it was not when the note above was first written, and the claim that it had no history is stale. Layout:

```
main (7031ea1, pure upstream v1.5.0 -- every commit authored by the maintainer)
├── 5cae4e4  pin-deployment-target
└── 9e9540e  fix-hid-lifetime-and-display-selection   <- PR #1 head
    └── ... → local
```

- **`local`** — the working branch, and what is deployed here. Carries the fork's patches *plus* the local working notes, so it is deliberately not a branch to push upstream.
- **`main`** — pure upstream. It is **not** "the fork's branch"; it holds none of this fork's work and exists as the reference point the other branches sit on.
- **`fix-hid-lifetime-and-display-selection`** — the two bring-up fixes as clean, upstream-shaped hunks, and the head of [bencolson/Touchdown#1](https://github.com/bencolson/Touchdown/pull/1) (open as of 2026-11-03). It is an **ancestor of `local`**, so it holds no content `local` lacks — but deleting it would close the PR, so leave it while that is open.
- **`pin-deployment-target`** — kept on purpose. `main`'s `build.sh` still has no `-target` flag, so **upstream still has the `minos` bug**, and this is the only upstream-shaped copy of the fix. It cannot be cherry-picked out of `local`: `local`'s `build.sh` has no Sparkle and has diverged structurally, so recovering it would mean re-deriving the hunk against `main`.

`sparkle-2.10.0` was deleted on 2026-11-03 (was `9f2af27`, a Sparkle 2.9.6 → 2.10.0 bump plus a macOS 12 floor, sitting on top of `pin-deployment-target`). It was useful only to upstream, trivially redone there, and actively misleading on a fork with no Sparkle.

**The Sparkle removal is a `local`-only decision.** `main` and `fix-hid…` still carry Sparkle because that is what upstream should receive. Do not "tidy" them to match `local`.

There is no `upstream` remote configured, so pulling the maintainer's changes means adding one. Expect conflicts in `build.sh` and `version.sh` — `local` has diverged structurally, not just by a patch or two.

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

`injectClick()` logged a line per touch to `~/Library/Logs/Touchdown.log` with no rotation and no purge, accumulating a detailed record of screen usage. Now gated behind a runtime flag, off by default:

```bash
defaults write com.bencolson.touchdown LogTouchPoints -bool true
```

Restart the driver to pick it up. Runtime rather than compile-time deliberately: ad-hoc rebuilds cost two permission re-grants, and debugging calibration should not require paying that.

## Installing, and how to sign

`./install.sh` is the only install path. It builds from source, signs ad-hoc by
default, installs to `~/Applications` and registers the LaunchAgent. No sudo, no
certificate, no network.

| `SIGN_IDENTITY` | Designated requirement | Grants survive rebuild? |
|---|---|---|
| unset / `-` (ad-hoc, the default) | `cdhash H"…"` | **no** — new hash every compile |
| `Apple Development: …` | `identifier` + `subject.CN` | yes |
| `Developer ID Application: …` | `identifier` + `subject.OU` | yes |

Both non-ad-hoc requirements were confirmed hash-free by building with each.
Since the driver does nothing at all without Accessibility *and* Input
Monitoring, ad-hoc costs two re-grants per rebuild. A dev-signed build holds TCC
grants separately from an ad-hoc one, so switching between them costs one
re-grant either way.

An Apple Development certificate is the single change that would most improve
day-to-day work here, and nothing about the fork prevents it — there just is not
one installed.

### What was audited before all this was removed

The published v1.5.0 build was independently audited on 2026-08-21, before it
was ever installed. That audit is now **historical**: this fork no longer
installs a published build, and `install-release.sh` is gone. The full detail is
in the git history; the findings that still matter are general ones.

- The shipped binary imported **zero networking symbols** — no `URLSession`, no
  `CFNetwork`, no sockets — and no `CGEventTapCreate`, so it could not read
  keystrokes despite holding Accessibility. Imported symbols matched the
  reviewed source one-to-one. The same is worth re-checking on any binary that
  holds these two permissions, including the ones built here.
- `build.sh` **re-signed** the vendored Sparkle with the project's own
  certificate, which meant its signature could not prove it unmodified. The way
  round that was to strip signatures and compare bytes against the official
  release. Any vendored, re-signed dependency has this property — the signature
  you end up checking is your own.
- A designated requirement that pins **team rather than hash** is what lets TCC
  grants survive an update. It is also what makes every future release a fresh
  trust decision inherited automatically, which was the actual argument against
  running the auto-updater at all.

## Established facts, so they are not re-derived

### TCC and signing

macOS keys Accessibility and Input Monitoring differently depending on signature type:

| Signing | TCC keys on | Consequence |
|---|---|---|
| None (bare Mach-O) | nothing — **no TCC record at all** | Never appears in the permission list; permission can never be granted |
| Ad-hoc | `cdhash` | Every rebuild revokes both permissions |
| Developer ID | bundle ID + team ID | Grants survive rebuilds and updates |

**This is why the app is a bundle at all**, and it was a real bug in the original: a bare binary in `/usr/local/bin` could not be granted Accessibility (`tccutil reset` reported *"No such bundle identifier"* — there was no record to toggle), so the driver could never inject anything.

The second row is the trade this fork accepts. It is ad-hoc signed, so every rebuild revokes both permissions. That was unacceptable while an auto-updater could rebuild the app behind your back; with updates only ever happening because you ran `./install.sh` yourself, a re-grant you were already expecting is a fair price for depending on no certificate.

Inspect what a given build pins with:

```bash
codesign -d --requirements - ~/Applications/Touchdown.app
# designated => cdhash H"..."        <- ad-hoc, grants die on rebuild
```

### Never call `exit()` on a recoverable failure

The LaunchAgent uses `KeepAlive { SuccessfulExit = false }`, so any non-zero exit is relaunched. The original called `AXIsProcessTrustedWithOptions(prompt: true)` then `exit(1)`, producing an unbounded loop of stacked system dialogs — 14 before it was stopped. Missing permission, a refused HID open, and an absent device now all report state and stay resident. A clean `exit(0)` is the only correct exit, and is what the single-instance guard and the Quit menu item use.

### Single instance matters

`install.sh` reloads the LaunchAgent while a hand-launched copy may still be running. Two instances would both attempt an exclusive HID seize and fight over the device, so the newer one exits. This used to matter more, when Sparkle could relaunch the app itself after installing an update.

### What CI checks

`.github/workflows/build.yml` compiles, bundles, signs ad-hoc, and asserts three things that are otherwise invisible until something breaks on another machine: that the bundle embeds **no** frameworks and links nothing via `@rpath`, that the icon is present, and that `minos` is `11.0` rather than the runner's OS. It publishes nothing, because this fork releases nothing. Ad-hoc builds skip `--options runtime` and `--timestamp`, which `codesign` rejects for ad-hoc signatures.

## Known rough edges

- **Display naming varies by unit.** This file used to state flatly that the panel reports as `Type-C`, so the name match in `setupScreen()` always fails and selection is by elimination. On the unit tested 2026-08-21 it reports **`XENEON EDGE`** and the name match succeeds. Treat `Type-C` as one possible name rather than the rule — and note that the disagreement between name-matching and elimination is exactly what produced the display bug documented above.
- **Comments are still French.** Upstream is French throughout; user-facing strings were translated but ~109 comment lines were not, to keep the diff against upstream reviewable. Translating them is mechanical if desired.
- **Swift 6 language mode is not enabled.** `swiftc` defaults to Swift 5 mode, which is why the mutable globals mutated from the C HID callback compile without concurrency errors. Do not add `-swift-version 6` expecting a no-op.
- **`touchscreenMaxX/Y` are verified** as of 2026-08-21 — `16383` / `9599` are correct on this unit. See the calibration table above for the method and the raw numbers.
- **A build's minimum OS was the build host's — now pinned.** `build.sh` passes `-target $(uname -m)-apple-macos11.0` as of 2026-11-03, so `LC_BUILD_VERSION` matches the `LSMinimumSystemVersion 11.0` in `Info.plist`. Without it `swiftc` stamps the host's version, and the macOS 27 upgrade turned that from theory into a live hazard: the first rebuild here produced `minos 27.2`, which would have refused to launch on the second machine had it still been on 26. To a user on an older OS that looks like "installs cleanly, then does nothing", with nothing in the log. The **published release is still affected**, depending on the maintainer's build host — the pin lives only on this fork. 11.0 used to be forced by the vendored Sparkle, which was itself `minos 11.0`; with Sparkle gone the only constraint left is the `LSMinimumSystemVersion` in `Info.plist`, so keep the two in step if you ever raise it. CI asserts the pin; verify by hand with `vtool -show-build <binary>`.
- **`Warning: Window move completed without beginning` in the log is harmless.** AppKit emits it when the About panel is ordered front, and it lands in `~/Library/Logs/Touchdown.log` because the LaunchAgent sends stderr there. Observed once per panel open, 32s after launch on 2026-11-03, i.e. exactly when About was clicked. Nothing in this app positions that window — it is the system panel — so there is nothing to fix. Worth knowing only because this log is the app's whole diagnostic surface, and an unexplained warning in it invites a hunt.
- **Upstream attribution is intentional.** `README.md` credits the original author and notes the project's AI co-authorship. That describes upstream's work, not this fork's, and should not be stripped.
