// No hashbang: this file is no longer runnable on its own. The entry point
// lives in main.swift (driver) or tests/main.swift (tests), and Swift reserves
// the hashbang for the module's main file.

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import AppKit

// ============================================
// Configuration for the Corsair Xeneon Edge
// ADJUST after analysing the HID reports
// ============================================
let TOUCHSCREEN_VENDOR_ID: Int = 0x27c0
let TOUCHSCREEN_PRODUCT_ID: Int = 0x0859

// Touchscreen coordinate ranges (calibrated with HIDAnalyzer)
var touchscreenMaxX: CGFloat = 16383
var touchscreenMaxY: CGFloat = 9599
var touchscreenMinX: CGFloat = 0
var touchscreenMinY: CGFloat = 0

// ============================================
// Target display configuration
// ============================================
var targetScreen: NSScreen?
var screenOffsetX: CGFloat = 0
var screenOffsetY: CGFloat = 0
var screenWidth: CGFloat = 2560
var screenHeight: CGFloat = 720

// ============================================
// Touch state
// ============================================
var currentX: CGFloat = 0
var currentY: CGFloat = 0
var isTouching: Bool = false
var lastClickTime: Date = Date.distantPast
let debounceInterval: TimeInterval = 0.05 // 50ms debounce

// Per-touch logging. Off by default: it writes a line per touch with no
// rotation and no purge, which accumulates into a detailed record of how the
// screen is used. Toggled at runtime rather than compile time because an
// ad-hoc rebuild revokes both TCC grants, and debugging calibration should
// not cost that:
//   defaults write com.bencolson.touchdown LogTouchPoints -bool true
// then restart the driver.
let logTouchPoints = UserDefaults.standard.bool(forKey: "LogTouchPoints")

// ============================================
// Click mode
// ============================================
enum ClickMode {
    case moveCursorAndClick  // Téléporte le curseur puis clique
    case clickInPlace        // Clique sans bouger le curseur (peut ne pas marcher avec toutes les apps)
}
var clickMode: ClickMode = .moveCursorAndClick

// ============================================
// HID capture mode
// ============================================
enum CaptureMode {
    case shared      // Écoute les événements sans les bloquer (peut causer des doubles clics)
    case exclusive   // Capture exclusive - bloque les événements système (recommandé)
}
var captureMode: CaptureMode = .exclusive

// ============================================
// Helpers
// ============================================

// Width of the version field in the ASCII banner, out to the frame edge.
// Pulled out so the tests can check alignment without launching the driver:
// the banner now reads its version from the Info.plist, so the string length
// varies and a misaligned frame would otherwise go unnoticed.
let bannerVersionFieldWidth = 11

func bannerVersionField(_ version: String) -> String {
    "v\(version)".padding(toLength: bannerVersionFieldWidth, withPad: " ", startingAt: 0)
}

func convertToScreenCoordinates(rawX: Int, rawY: Int) -> CGPoint {
    // Normalise the raw coordinates to 0.0 - 1.0
    let normalizedX = (CGFloat(rawX) - touchscreenMinX) / (touchscreenMaxX - touchscreenMinX)
    let normalizedY = (CGFloat(rawY) - touchscreenMinY) / (touchscreenMaxY - touchscreenMinY)
    
    // Convert to screen coordinates
    let screenX = screenOffsetX + (normalizedX * screenWidth)
    let screenY = screenOffsetY + (normalizedY * screenHeight)
    
    return CGPoint(x: screenX, y: screenY)
}

func injectClick(at point: CGPoint) {
    // Debounce
    let now = Date()
    guard now.timeIntervalSince(lastClickTime) > debounceInterval else { return }
    lastClickTime = now

    // Save the cursor's current position
    let originalPosition = NSEvent.mouseLocation
    // NSScreen's origin is bottom-left, CGEvent's is top-left
    let mainScreenHeight = NSScreen.screens[0].frame.height
    let originalCGPosition = CGPoint(x: originalPosition.x, y: mainScreenHeight - originalPosition.y)

    // CGDisplayHideCursor/ShowCursor are reference counted: every hide without
    // a matching show raises the count permanently, and the cursor never comes
    // back until the driver restarts. The two `guard`s below used to return
    // between the hide and the show, so a failed CGEvent allocation -- rare,
    // but possible under memory pressure -- lost the cursor for good. The
    // defer guarantees the pair.
    var cursorHidden = false
    defer {
        if cursorHidden {
            usleep(10000) // 10ms avant de restaurer
            CGWarpMouseCursorPosition(originalCGPosition)
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    switch clickMode {
    case .moveCursorAndClick:
        // Hide the cursor so it does not ghost at the old position
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true

        // Warp the cursor
        CGWarpMouseCursorPosition(point)

        // Brief pause so the system registers the new position
        usleep(10000) // 10ms

    case .clickInPlace:
        break // Leave the cursor alone
    }

    // Build and post the mouse events
    guard let mouseDown = CGEvent(mouseEventSource: nil,
                                   mouseType: .leftMouseDown,
                                   mouseCursorPosition: point,
                                   mouseButton: .left) else {
        print("❌ Failed to create mouseDown event")
        return
    }

    guard let mouseUp = CGEvent(mouseEventSource: nil,
                                 mouseType: .leftMouseUp,
                                 mouseCursorPosition: point,
                                 mouseButton: .left) else {
        print("❌ Failed to create mouseUp event")
        return
    }

    // Post them
    mouseDown.post(tap: .cghidEventTap)
    usleep(20000) // 20ms entre down et up
    mouseUp.post(tap: .cghidEventTap)

    if logTouchPoints {
        print("🖱️  Click injected at (\(Int(point.x)), \(Int(point.y)))")
    }
}

func injectDrag(to point: CGPoint) {
    guard let dragEvent = CGEvent(mouseEventSource: nil,
                                   mouseType: .leftMouseDragged,
                                   mouseCursorPosition: point,
                                   mouseButton: .left) else {
        return
    }
    
    if clickMode == .moveCursorAndClick {
        CGWarpMouseCursorPosition(point)
    }
    
    dragEvent.post(tap: .cghidEventTap)
}

// ============================================
// Callback HID
// ============================================

func hidInputCallback(context: UnsafeMutableRawPointer?,
                      result: IOReturn,
                      sender: UnsafeMutableRawPointer?,
                      value: IOHIDValue) {

    // Always refresh the screen geometry (NSScreen can change at any moment)
    updateScreenFromCurrentList()

    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    
    // Update the coordinates
    if usagePage == 0x01 { // Generic Desktop
        switch usage {
        case 0x30: // X
            currentX = CGFloat(intValue)
        case 0x31: // Y
            currentY = CGFloat(intValue)
        default:
            break
        }
    }
    
    // Detect the touch (Tip Switch OR Button 1).
    // The Xeneon Edge reports Button 1 (usagePage 0x09, usage 0x01) rather
    // than a Tip Switch.
    let isTouchEvent = (usagePage == 0x0D && usage == 0x42) || (usagePage == 0x09 && usage == 0x01)

    if isTouchEvent {
        let wasTouching = isTouching
        isTouching = intValue != 0

        if isTouching && !wasTouching {
            // New touch -> click
            let screenPoint = convertToScreenCoordinates(rawX: Int(currentX), rawY: Int(currentY))
            injectClick(at: screenPoint)
        } else if isTouching && wasTouching {
            // Still touching -> drag
            let screenPoint = convertToScreenCoordinates(rawX: Int(currentX), rawY: Int(currentY))
            injectDrag(to: screenPoint)
        }
        // On release there is nothing to do: mouseUp was already sent
    }
}

// ============================================
// Screen configuration
// ============================================

// How a screen is recognised as the panel. One place only: setupScreen() and
// checkForGeometryChanges() each used to carry their own copy, and two
// independent predicates that can disagree is exactly what produced the
// display bug in August -- the name match won at startup, elimination won on
// every HID event afterwards.
enum ScreenMatch {
    case byName(NSScreen)
    case bySecondaryFallback(NSScreen)
    case byMainFallback(NSScreen)

    var screen: NSScreen {
        switch self {
        case .byName(let s), .bySecondaryFallback(let s), .byMainFallback(let s): return s
        }
    }
}

// The name test, isolated so it is checkable with no panel attached. Note
// that some units report as "Type-C" and therefore match nothing here -- that
// is intended, the elimination fallback catches them. See the tests.
func isXeneonName(_ name: String) -> Bool {
    name.contains("XENEON") || name.contains("Corsair")
}

func locateXeneonScreen() -> ScreenMatch? {
    let screens = NSScreen.screens

    if let named = screens.first(where: { isXeneonName($0.localizedName) }) {
        return .byName(named)
    }
    // Fallback: the second screen, usually the external one.
    if screens.count > 1 {
        return .bySecondaryFallback(screens[1])
    }
    guard let main = NSScreen.main else { return nil }
    return .byMainFallback(main)
}

func setupScreen() {
    let screens = NSScreen.screens
    print("📺 Displays detected:")

    for (index, screen) in screens.enumerated() {
        let frame = screen.frame
        let name = screen.localizedName
        print("   [\(index)] \(name): \(Int(frame.width))x\(Int(frame.height)) @ (\(Int(frame.origin.x)), \(Int(frame.origin.y)))")
    }

    switch locateXeneonScreen() {
    case .byName(let screen):
        targetScreen = screen
        print("✅ Xeneon Edge display found")
    case .bySecondaryFallback(let screen):
        targetScreen = screen
        print("⚠️  Xeneon not identified by name, falling back to the secondary display")
    case .byMainFallback(let screen):
        targetScreen = screen
        print("⚠️  Only one display detected, using the main display")
    case nil:
        print("⚠️  No displays detected")
    }

    updateScreenGeometry()
}

var xeneonDisplayID: CGDirectDisplayID = 0

func findXeneonDisplayID() {
    // setupScreen() has already picked the right screen, by name where it can.
    // Derive the CGDirectDisplayID straight from it: "the first screen that is
    // not the main one" gets it wrong as soon as there are three, and then
    // overwrites the correct geometry on every HID event.
    if let screen = targetScreen,
       let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        xeneonDisplayID = id
        return
    }

    // Fallback: the first screen that is not the main one.
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displays, &displayCount)

    for display in displays {
        if display != CGMainDisplayID() {
            xeneonDisplayID = display
            break
        }
    }
}

func updateScreenFromCurrentList() {
    guard xeneonDisplayID != 0 else { return }

    // CGDisplayBounds updates in real time, unlike NSScreen.screens
    let bounds = CGDisplayBounds(xeneonDisplayID)

    // CGDisplayBounds uses a top-left origin
    screenOffsetX = bounds.origin.x
    screenOffsetY = bounds.origin.y
    screenWidth = bounds.width
    screenHeight = bounds.height
}

func updateScreenGeometry() {
    if let screen = targetScreen {
        let frame = screen.frame
        let scaleFactor = screen.backingScaleFactor

        // NSScreen's origin is bottom-left, CGEvent's is top-left, so Y has
        // to be converted
        let mainScreenHeight = NSScreen.screens[0].frame.height

        screenOffsetX = frame.origin.x
        // cgY = mainHeight - nsY - screenHeight
        screenOffsetY = mainScreenHeight - frame.origin.y - frame.height

        // CGEvent works in logical points, and frame.size is already logical
        screenWidth = frame.width
        screenHeight = frame.height

        print("📐 Target display: \(Int(screenWidth))x\(Int(screenHeight)) points")
        print("   Backing scale factor: \(scaleFactor)x (HiDPI: \(scaleFactor > 1 ? "yes" : "no"))")
        print("   NSScreen origin: (\(Int(frame.origin.x)), \(Int(frame.origin.y)))")
        print("   CGEvent origin:  (\(Int(screenOffsetX)), \(Int(screenOffsetY)))")
    }
}

// ============================================
// Screen-change observer
// ============================================

// Last known geometry, kept so changes can be detected
var lastKnownScreenOriginX: CGFloat = 0
var lastKnownScreenOriginY: CGFloat = 0
var lastKnownScreenWidth: CGFloat = 0
var lastKnownScreenHeight: CGFloat = 0

class ScreenChangeObserver {
    private var timer: DispatchSourceTimer?
    private var observerToken: NSObjectProtocol?

    init() {
        // addObserver(forName:object:queue:using:) returns a token that
        // NotificationCenter retains until removeObserver. Discarding it left
        // the observation outliving the object: attachDriver() built a fresh
        // observer on every device retry (each 3s), so a single display change
        // ended up replaying setupScreen() hundreds of times and drowning the
        // log.
        observerToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("\n🔄 Display configuration changed, updating...")
            setupScreen()
            findXeneonDisplayID()
            saveCurrentGeometry()
        }

        // GCD timer that watches for position changes
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler {
            checkForGeometryChanges()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
        timer?.cancel()
    }
}

func saveCurrentGeometry() {
    if let screen = targetScreen {
        lastKnownScreenOriginX = screen.frame.origin.x
        lastKnownScreenOriginY = screen.frame.origin.y
        lastKnownScreenWidth = screen.frame.width
        lastKnownScreenHeight = screen.frame.height
    }
}

func checkForGeometryChanges() {
    // Same selection rule as at startup, via locateXeneonScreen().
    guard let currentXeneon = locateXeneonScreen()?.screen else {
        return
    }

    let frame = currentXeneon.frame
    if frame.origin.x != lastKnownScreenOriginX ||
       frame.origin.y != lastKnownScreenOriginY ||
       frame.width != lastKnownScreenWidth ||
       frame.height != lastKnownScreenHeight {

        print("\n🔄 Display layout change detected")
        print("   Before: (\(Int(lastKnownScreenOriginX)), \(Int(lastKnownScreenOriginY))) \(Int(lastKnownScreenWidth))x\(Int(lastKnownScreenHeight))")
        print("   After: (\(Int(frame.origin.x)), \(Int(frame.origin.y))) \(Int(frame.width))x\(Int(frame.height))")

        // Update the screen reference
        targetScreen = currentXeneon
        findXeneonDisplayID()
        updateScreenGeometry()
        saveCurrentGeometry()
    }
}

var screenObserver: ScreenChangeObserver?

// ============================================
// Permission checks
// ============================================

func checkAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// ============================================
// Menu bar icon
// ============================================

// ~/Library/Logs rather than /tmp: /tmp is 1777 and the log was 0644 there,
// so any process on the machine could read it -- display names and geometry,
// and every touch coordinate while LogTouchPoints is on. ~/Library and
// ~/Library/Logs are both 0700, so the directory protects the file whatever
// its own mode is.
// Must stay in step with StandardOutPath/StandardErrorPath in the plist.
let logPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/Touchdown.log")

// NSObject: NSMenuItem needs an Objective-C target for its actions.
final class StatusController: NSObject {
    static let shared = StatusController()

    enum State {
        case waitingPermission
        case waitingDevice
        case active
        case failed(String)
    }

    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "…", action: nil, keyEquivalent: "")

    // No auto-update: this fork publishes nothing. Sparkle was removed
    // outright -- no embedded framework, no feed, no "Check for Updates..."
    // menu entry. Updating here means running ./install.sh again.

    // Call on the main thread before NSApplication.run(), so the
    // "waiting for permission" state is visible straight away.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if #available(macOS 11.0, *) {
            let icon = NSImage(systemSymbolName: "hand.rays", accessibilityDescription: "Touchdown")
            icon?.isTemplate = true  // suit le thème clair/sombre de la barre
            item.button?.image = icon
        } else {
            item.button?.title = "✋"
        }

        let menu = NSMenu()
        for line in [stateItem, displayItem] {
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())

        let redetect = NSMenuItem(title: "Redetect Display",
                                  action: #selector(redetectScreen),
                                  keyEquivalent: "")
        redetect.target = self
        menu.addItem(redetect)

        let openLog = NSMenuItem(title: "Open Log",
                                 action: #selector(openLogFile),
                                 keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Touchdown",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Touchdown",
                              action: #selector(quitDriver),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        setState(.waitingPermission)
    }

    func setState(_ state: State) {
        // Every AppKit mutation has to happen on the main thread.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setState(state) }
            return
        }

        guard let button = statusItem?.button else { return }

        switch state {
        case .waitingPermission:
            stateItem.title = "Waiting for Accessibility permission"
            button.appearsDisabled = true
            button.contentTintColor = nil
        case .waitingDevice:
            stateItem.title = "Waiting for Xeneon Edge…"
            button.appearsDisabled = true
            button.contentTintColor = nil
        case .active:
            stateItem.title = "Active"
            button.appearsDisabled = false
            button.contentTintColor = nil
        case .failed(let reason):
            stateItem.title = "Error: \(reason)"
            button.appearsDisabled = false
            button.contentTintColor = .systemRed
        }

        refreshDisplayLine()
    }

    func refreshDisplayLine() {
        if let screen = targetScreen {
            displayItem.title = "Display: \(screen.localizedName) — \(Int(screenWidth))×\(Int(screenHeight))"
        } else {
            displayItem.title = "Display: not detected"
        }
    }

    @objc private func redetectScreen() {
        setupScreen()
        findXeneonDisplayID()
        saveCurrentGeometry()
        refreshDisplayLine()
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func showAbout() {
        // An .accessory app does not come forward by itself: without this the
        // panel opens behind whatever is frontmost.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let credits = NSAttributedString(
            string: """
                Touch support for the Corsair Xeneon Edge on macOS.

                macOS ignores the panel's HID digitizer interface, so a tap \
                clicks wherever the cursor already sits. Touchdown seizes that \
                interface and injects a click at the point you touched.
                """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])

        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]

        // The panel shows "Version <CFBundleShortVersionString>
        // (<CFBundleVersion>)". Enrich the parenthesised part with the source
        // commit that build.sh stamps into TDSourceCommit: with two machines
        // and ad-hoc builds, "which one is running what" has no other answer.
        let info = Bundle.main.infoDictionary
        if let build = info?["CFBundleVersion"] as? String,
           let commit = info?["TDSourceCommit"] as? String {
            options[.version] = "\(build) · \(commit)"
        }

        // Otherwise the panel takes NSApp.applicationIconImage, which stays
        // generic until LaunchServices has indexed the bundle -- common right
        // after an install. So load the icon straight out of Resources. The
        // name comes from the Info.plist to stay aligned with what build.sh
        // writes there.
        let iconName = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String ?? "Touchdown"
        if let url = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            options[.applicationIcon] = icon
        }

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quitDriver() {
        // exit(0): with KeepAlive { SuccessfulExit = false }, launchd does
        // not relaunch after a clean exit.
        exit(0)
    }
}

// ============================================
// Main program
// ============================================

// Strong reference to the HID manager. attachDriver() returns before
// NSApplication.run() starts servicing the run loop: without this global, ARC
// releases the manager on return, its run loop source goes with it and no
// event ever arrives -- while the open and the seize both succeeded, so the
// driver advertises itself as "active" while capturing nothing.
var hidManager: IOHIDManager?

// Attaches the HID and starts capture. Must run on the main thread: the
// callback is scheduled on CFRunLoopGetMain(), serviced by NSApplication.run().
func attachDriver() {
    // Set up the target screen
    setupScreen()
    findXeneonDisplayID()
    saveCurrentGeometry()

    // Once only. attachDriver() is re-entered every 3s while the panel is
    // missing, and each call used to install another observer.
    if screenObserver == nil {
        screenObserver = ScreenChangeObserver()
    }

    print("""

    📊 Current configuration:
       Touchscreen: X=[0, \(Int(touchscreenMaxX))], Y=[0, \(Int(touchscreenMaxY))]
       Click mode: \(clickMode == .moveCursorAndClick ? "Move cursor + click" : "Click in place")
       Capture mode: \(captureMode == .exclusive ? "EXCLUSIVE (blocks system events)" : "SHARED (may cause double clicks)")

    ⚠️  If clicks land in the wrong place, adjust touchscreenMaxX/Y in the
       source after running HIDAnalyzer.

    """)

    // Create the HID manager
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager

    // Match only our touchscreen
    let deviceMatch: [String: Any] = [
        kIOHIDVendorIDKey as String: TOUCHSCREEN_VENDOR_ID,
        kIOHIDProductIDKey as String: TOUCHSCREEN_PRODUCT_ID
    ]

    IOHIDManagerSetDeviceMatching(manager, deviceMatch as CFDictionary)

    // Open the manager in the appropriate mode.
    // kIOHIDOptionsTypeSeizeDevice = 0x01 - takes exclusive control
    let openOptions: IOOptionBits
    if captureMode == .exclusive {
        openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        print("🔒 Opening in EXCLUSIVE mode (seize device)...")
    } else {
        openOptions = IOOptionBits(kIOHIDOptionsTypeNone)
        print("🔓 Opening in SHARED mode...")
    }

    let openResult = IOHIDManagerOpen(manager, openOptions)
    if openResult != kIOReturnSuccess {
        print("❌ Error: could not open IOHIDManager (code: \(openResult))")
        if captureMode == .exclusive {
            print("""

            💡 Exclusive mode can fail if:
               - Another program already holds the device
               - Permissions are insufficient

            You can try SHARED mode by changing:
               var captureMode: CaptureMode = .shared

            """)
        }
        // Stay alive and report in the menu bar. An exit() here would trip
        // launchd's relaunch loop.
        StatusController.shared.setState(.failed("HID open refused"))
        return
    }

    // Check for the device. Absent probably means unplugged, so retry rather
    // than exit: the Xeneon can show up after the driver does.
    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
        print("⏳ Touchscreen not found, retrying in 3s...")
        StatusController.shared.setState(.waitingDevice)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { attachDriver() }
        return
    }

    print("✅ Touchscreen connected")

    // Register the callback
    IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    StatusController.shared.setState(.active)

    print("""

    🎯 Driver active. Touch the screen to click.

    """)
}

// ============================================
// Main program
// ============================================

// install.sh reloads the LaunchAgent while a hand-launched copy may still be
// running. Two instances in exclusive mode would fight over the HID seize, so
// the newer one bows out.
func ensureSingleInstance() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    guard !others.isEmpty else { return }

    let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
    print("⚠️  Another instance is already running (pid \(pids)), exiting.")
    // exit(0): a clean exit, so KeepAlive { SuccessfulExit = false } does not relaunch.
    exit(0)
}

func main() {
    // Read from the Info.plist rather than hard-coded: the banner used to
    // repeat "v1.5.0" as a literal while version.sh fed the plist separately
    // -- two independent sources that diverge the moment the version changes.
    // "dev" covers running the binary outside a bundle, where there is no
    // Info.plist to read.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let versionField = bannerVersionField(version)

    print("""
    ╔════════════════════════════════════════════════════════════╗
    ║   Touchdown - Corsair Xeneon Edge               \(versionField)║
    ║   Maps touches to absolute clicks                          ║
    ╚════════════════════════════════════════════════════════════╝

    """)

    ensureSingleInstance()

    // The icon before anything else: it is what makes the wait for permission
    // visible, otherwise all the user has is the log.
    StatusController.shared.install()

    // The permission dialog has to be requested from the main thread.
    print("🔐 Checking Accessibility permission...")
    if checkAccessibilityPermission() {
        print("✅ Accessibility permission granted")
        DispatchQueue.main.async { attachDriver() }
    } else {
        print("""

        ⚠️  PERMISSION REQUIRED

        To inject clicks, this app must be added to:
        System Settings → Privacy & Security → Accessibility

        Waiting for the grant (no need to relaunch)...

        """)
        StatusController.shared.setState(.waitingPermission)

        // Silent polling, off the main thread so the menu bar does not
        // freeze. One dialog was already shown; do not ask again. And no
        // exit(), or KeepAlive relaunches in a loop and stacks up system
        // dialogs.
        DispatchQueue.global(qos: .utility).async {
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 2.0)
            }
            print("✅ Accessibility permission granted")
            DispatchQueue.main.async { attachDriver() }
        }
    }

    // NSApplication provides the event loop (default mode), so the HID's
    // CFRunLoop sources get serviced. .accessory = no Dock icon.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}

// The entry point lives in main.swift: Swift allows top-level code only in a
// file of that name, and keeping it here made it impossible to add any second
// file to the module -- which made tests impossible.
