// Tests for the pure logic in TouchscreenDriver.swift.
//
// Run with ./run_tests.sh, which compiles this file together with
// TouchscreenDriver.swift -- the same declarations the driver ships, not a
// copy. Swift allows top-level code only in a file called main.swift, so this
// one and the driver's own main.swift are never compiled together; picking one
// or the other is what selects "test binary" or "driver".
//
// No XCTest and no SwiftPM on purpose. The project builds with a bare swiftc
// invocation and has no package manifest; adding one to get a test runner
// would be a far larger change than the handful of assertions below justify.
//
// Nothing here touches hardware, AppKit state or TCC, so it is safe in CI.

import AppKit

var failures: [String] = []
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        let d = detail()
        print("  ❌ \(label)\(d.isEmpty ? "" : " — \(d)")")
        failures.append(label)
    }
}

func checkClose(_ label: String, _ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.5) {
    check(label, abs(a - b) <= tolerance, "expected \(b), got \(a)")
}

// ---------------------------------------------------------------------------
// Coordinate mapping
//
// These lock the calibration constants and the mapping arithmetic together.
// The constants were verified against physical corner taps (see the table in
// CLAUDE.md); without a test, a change to either silently un-verifies that
// work, and the only way to notice is to tap all four corners again.
// ---------------------------------------------------------------------------
print("\nCalibration constants")

// Assert the DECLARED defaults before anything below overwrites them.
//
// This block exists because mutation testing found the gap: changing
// touchscreenMaxY in the source passed the whole suite, since the mapping
// tests set the globals themselves and so never saw the declared value. The
// constants are the most likely thing to be edited by hand and the most
// expensive to re-verify -- it means tapping all four physical corners again.
check("touchscreenMinX is 0", touchscreenMinX == 0, "got \(touchscreenMinX)")
check("touchscreenMinY is 0", touchscreenMinY == 0, "got \(touchscreenMinY)")
check("touchscreenMaxX is 16383 (verified by corner taps 2026-08-21)",
      touchscreenMaxX == 16383, "got \(touchscreenMaxX)")
check("touchscreenMaxY is 9599 (verified by corner taps 2026-08-21)",
      touchscreenMaxY == 9599, "got \(touchscreenMaxY)")

print("\nCoordinate mapping")

// The panel as it sits on the dev machine: 2560x720 at CG origin (855, 1440).
screenOffsetX = 855
screenOffsetY = 1440
screenWidth = 2560
screenHeight = 720
touchscreenMinX = 0
touchscreenMaxX = 16383
touchscreenMinY = 0
touchscreenMaxY = 9599

let topLeft = convertToScreenCoordinates(rawX: 0, rawY: 0)
checkClose("raw (0,0) maps to the panel's top-left corner, x", topLeft.x, 855)
checkClose("raw (0,0) maps to the panel's top-left corner, y", topLeft.y, 1440)

let bottomRight = convertToScreenCoordinates(rawX: 16383, rawY: 9599)
checkClose("raw max maps to the panel's bottom-right corner, x", bottomRight.x, 3415)
checkClose("raw max maps to the panel's bottom-right corner, y", bottomRight.y, 2160)

let centre = convertToScreenCoordinates(rawX: 8191, rawY: 4799)
checkClose("raw midpoint maps to the panel centre, x", centre.x, 855 + 1280, tolerance: 1)
checkClose("raw midpoint maps to the panel centre, y", centre.y, 1440 + 360, tolerance: 1)

// The four corner taps recorded on 2026-11-03, reverse-mapped in CLAUDE.md.
// Offsets are relative to the panel's own top-left, so they hold wherever the
// panel sits in the desktop arrangement.
let recorded: [(name: String, rawX: Int, rawY: Int, offX: CGFloat, offY: CGFloat)] = [
    ("top-left",     224,  787,   35,  59),
    ("bottom-left",  160,  9466,  25,  710),
    ("bottom-right", 16242, 9306, 2538, 698),
    ("top-right",    16121, 800,  2519, 60),
]
for r in recorded {
    let p = convertToScreenCoordinates(rawX: r.rawX, rawY: r.rawY)
    checkClose("measured \(r.name) tap round-trips, x", p.x - 855, r.offX, tolerance: 1)
    checkClose("measured \(r.name) tap round-trips, y", p.y - 1440, r.offY, tolerance: 1)
}

// Anything inside the raw range must land on the panel. A sign flip or a
// swapped axis would show up here even if the corners happened to survive.
var escaped = 0
for rx in stride(from: 0, through: 16383, by: 523) {
    for ry in stride(from: 0, through: 9599, by: 311) {
        let p = convertToScreenCoordinates(rawX: rx, rawY: ry)
        if p.x < 855 - 0.5 || p.x > 3415 + 0.5 || p.y < 1440 - 0.5 || p.y > 2160 + 0.5 {
            escaped += 1
        }
    }
}
check("every in-range raw coordinate lands on the panel", escaped == 0,
      "\(escaped) points fell outside")

// Monotonic in both axes: larger raw X must never map further left.
let a = convertToScreenCoordinates(rawX: 1000, rawY: 1000)
let b = convertToScreenCoordinates(rawX: 2000, rawY: 2000)
check("mapping is monotonic in x", b.x > a.x)
check("mapping is monotonic in y", b.y > a.y)

// ---------------------------------------------------------------------------
// Banner alignment
//
// The banner reads the version from the Info.plist, so its length is no longer
// fixed. A misaligned box is cosmetic, but it is also the first thing printed
// to the log and the cheapest possible smoke signal that something changed.
// ---------------------------------------------------------------------------
print("\nBanner alignment")

let boxWidth = "╔════════════════════════════════════════════════════════════╗".count
for v in ["dev", "1.6.0", "1.10.12", "2.0.0-rc1"] {
    let line = "║   Touchdown - Corsair Xeneon Edge               \(bannerVersionField(v))║"
    check("version \"\(v)\" keeps the box square", line.count == boxWidth,
          "line is \(line.count), box is \(boxWidth)")
}

// ---------------------------------------------------------------------------
// Panel name matching
// ---------------------------------------------------------------------------
print("\nPanel name matching")

check("matches the name this unit reports", isXeneonName("XENEON EDGE"))
check("matches a Corsair-branded name", isXeneonName("Corsair Xeneon Edge"))
check("does not match the other monitors here", !isXeneonName("LG HDR DQHD"))
check("does not match the other monitors here (2)", !isXeneonName("HP 27mq"))

// Documents a known gap rather than asserting it is correct: CLAUDE.md records
// that some units report as "Type-C", which this predicate does NOT match. Such
// a unit falls through to the elimination fallback. If that is ever made to
// match by name, this assertion is the thing that should fail and be updated.
check("\"Type-C\" is NOT matched by name (known gap, handled by fallback)",
      !isXeneonName("Type-C"))

// ---------------------------------------------------------------------------
print("\n\(checks - failures.count)/\(checks) checks passed")
if failures.isEmpty {
    print("✅ all good")
    exit(0)
} else {
    print("❌ failed: \(failures.joined(separator: "; "))")
    exit(1)
}
