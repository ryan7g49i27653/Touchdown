#!/usr/bin/env swift

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import AppKit

// ============================================
// Configuration pour Corsair Xeneon Edge
// À AJUSTER après analyse des rapports HID
// ============================================
let TOUCHSCREEN_VENDOR_ID: Int = 0x27c0
let TOUCHSCREEN_PRODUCT_ID: Int = 0x0859

// Plages de coordonnées du touchscreen (calibrées via HIDAnalyzer)
var touchscreenMaxX: CGFloat = 16383
var touchscreenMaxY: CGFloat = 9599
var touchscreenMinX: CGFloat = 0
var touchscreenMinY: CGFloat = 0

// ============================================
// Configuration écran cible
// ============================================
var targetScreen: NSScreen?
var screenOffsetX: CGFloat = 0
var screenOffsetY: CGFloat = 0
var screenWidth: CGFloat = 2560
var screenHeight: CGFloat = 720

// ============================================
// État du toucher
// ============================================
var currentX: CGFloat = 0
var currentY: CGFloat = 0
var isTouching: Bool = false
var lastClickTime: Date = Date.distantPast
let debounceInterval: TimeInterval = 0.05 // 50ms debounce

// Journalisation des points de contact. Coupée par défaut: elle écrit une
// ligne par toucher dans /tmp, sans rotation ni purge, ce qui finit par
// constituer une trace détaillée de l'usage de l'écran. Réactivable sans
// recompiler — un rebuild ad-hoc révoquant les autorisations TCC:
//   defaults write com.bencolson.touchdown LogTouchPoints -bool true
// puis relancer le driver.
let logTouchPoints = UserDefaults.standard.bool(forKey: "LogTouchPoints")

// ============================================
// Mode de fonctionnement
// ============================================
enum ClickMode {
    case moveCursorAndClick  // Téléporte le curseur puis clique
    case clickInPlace        // Clique sans bouger le curseur (peut ne pas marcher avec toutes les apps)
}
var clickMode: ClickMode = .moveCursorAndClick

// ============================================
// Mode de capture HID
// ============================================
enum CaptureMode {
    case shared      // Écoute les événements sans les bloquer (peut causer des doubles clics)
    case exclusive   // Capture exclusive - bloque les événements système (recommandé)
}
var captureMode: CaptureMode = .exclusive

// ============================================
// Fonctions utilitaires
// ============================================

func convertToScreenCoordinates(rawX: Int, rawY: Int) -> CGPoint {
    // Normaliser les coordonnées brutes en 0.0 - 1.0
    let normalizedX = (CGFloat(rawX) - touchscreenMinX) / (touchscreenMaxX - touchscreenMinX)
    let normalizedY = (CGFloat(rawY) - touchscreenMinY) / (touchscreenMaxY - touchscreenMinY)
    
    // Convertir en coordonnées écran
    let screenX = screenOffsetX + (normalizedX * screenWidth)
    let screenY = screenOffsetY + (normalizedY * screenHeight)
    
    return CGPoint(x: screenX, y: screenY)
}

func injectClick(at point: CGPoint) {
    // Vérifier le debounce
    let now = Date()
    guard now.timeIntervalSince(lastClickTime) > debounceInterval else { return }
    lastClickTime = now

    // Sauvegarder la position actuelle du curseur
    let originalPosition = NSEvent.mouseLocation
    // Convertir de NSScreen (origine bas-gauche) vers CG (origine haut-gauche)
    let mainScreenHeight = NSScreen.screens[0].frame.height
    let originalCGPosition = CGPoint(x: originalPosition.x, y: mainScreenHeight - originalPosition.y)

    switch clickMode {
    case .moveCursorAndClick:
        // Cacher le curseur pour éviter le curseur fantôme
        CGDisplayHideCursor(CGMainDisplayID())

        // Téléporter le curseur
        CGWarpMouseCursorPosition(point)

        // Petit délai pour que le système enregistre la position
        usleep(10000) // 10ms

    case .clickInPlace:
        break // Ne pas bouger le curseur
    }

    // Créer et poster les événements souris
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

    // Poster les événements
    mouseDown.post(tap: .cghidEventTap)
    usleep(20000) // 20ms entre down et up
    mouseUp.post(tap: .cghidEventTap)

    // Restaurer la position originale du curseur
    if clickMode == .moveCursorAndClick {
        usleep(10000) // 10ms avant de restaurer
        CGWarpMouseCursorPosition(originalCGPosition)

        // Réafficher le curseur
        CGDisplayShowCursor(CGMainDisplayID())
    }

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

    // Toujours mettre à jour la géométrie de l'écran (NSScreen peut changer à tout moment)
    updateScreenFromCurrentList()

    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    
    // Mettre à jour les coordonnées
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
    
    // Détecter le toucher (Tip Switch OU Button 1)
    // Le Xeneon Edge utilise Button 1 (usagePage 0x09, usage 0x01) au lieu de Tip Switch
    let isTouchEvent = (usagePage == 0x0D && usage == 0x42) || (usagePage == 0x09 && usage == 0x01)

    if isTouchEvent {
        let wasTouching = isTouching
        isTouching = intValue != 0

        if isTouching && !wasTouching {
            // Nouveau toucher → clic
            let screenPoint = convertToScreenCoordinates(rawX: Int(currentX), rawY: Int(currentY))
            injectClick(at: screenPoint)
        } else if isTouching && wasTouching {
            // Glissement → drag
            let screenPoint = convertToScreenCoordinates(rawX: Int(currentX), rawY: Int(currentY))
            injectDrag(to: screenPoint)
        }
        // Si relâché, on ne fait rien (le mouseUp a déjà été envoyé)
    }
}

// ============================================
// Configuration de l'écran
// ============================================

func setupScreen() {
    // Trouver l'écran Corsair Xeneon Edge
    // Par défaut on prend l'écran principal, mais tu peux ajuster
    
    let screens = NSScreen.screens
    print("📺 Displays detected:")
    
    for (index, screen) in screens.enumerated() {
        let frame = screen.frame
        let name = screen.localizedName
        print("   [\(index)] \(name): \(Int(frame.width))x\(Int(frame.height)) @ (\(Int(frame.origin.x)), \(Int(frame.origin.y)))")
    }
    
    // Chercher l'écran Corsair (ou prendre le principal)
    // Tu peux ajuster cette logique selon ta configuration
    if let xeneonScreen = screens.first(where: { $0.localizedName.contains("XENEON") || $0.localizedName.contains("Corsair") }) {
        targetScreen = xeneonScreen
        print("✅ Xeneon Edge display found")
    } else if screens.count > 1 {
        // Prendre le deuxième écran (souvent l'externe)
        targetScreen = screens[1]
        print("⚠️  Xeneon not identified by name, falling back to the secondary display")
    } else {
        targetScreen = NSScreen.main
        print("⚠️  Only one display detected, using the main display")
    }
    
    updateScreenGeometry()
}

var xeneonDisplayID: CGDirectDisplayID = 0

func findXeneonDisplayID() {
    // setupScreen() a déjà retenu le bon écran, par nom quand c'est possible.
    // On en dérive directement le CGDirectDisplayID: « le premier écran qui
    // n'est pas le principal » se trompe dès qu'il y en a trois, et écrase
    // ensuite la bonne géométrie à chaque événement HID.
    if let screen = targetScreen,
       let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        xeneonDisplayID = id
        return
    }

    // Repli: le premier écran qui n'est pas le principal.
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

    // Utiliser CGDisplayBounds qui se met à jour en temps réel (contrairement à NSScreen.screens)
    let bounds = CGDisplayBounds(xeneonDisplayID)

    // CGDisplayBounds utilise le système de coordonnées avec origine en haut à gauche
    screenOffsetX = bounds.origin.x
    screenOffsetY = bounds.origin.y
    screenWidth = bounds.width
    screenHeight = bounds.height
}

func updateScreenGeometry() {
    if let screen = targetScreen {
        let frame = screen.frame
        let scaleFactor = screen.backingScaleFactor

        // NSScreen utilise l'origine en bas à gauche, mais CGEvent utilise l'origine en haut à gauche
        // On doit convertir les coordonnées Y
        let mainScreenHeight = NSScreen.screens[0].frame.height

        screenOffsetX = frame.origin.x
        // Convertir Y: cgY = mainHeight - nsY - screenHeight
        screenOffsetY = mainScreenHeight - frame.origin.y - frame.height

        // CGEvent utilise les coordonnées en points logiques
        // frame.size donne déjà la taille logique, c'est ce qu'on veut
        screenWidth = frame.width
        screenHeight = frame.height

        print("📐 Target display: \(Int(screenWidth))x\(Int(screenHeight)) points")
        print("   Backing scale factor: \(scaleFactor)x (HiDPI: \(scaleFactor > 1 ? "yes" : "no"))")
        print("   NSScreen origin: (\(Int(frame.origin.x)), \(Int(frame.origin.y)))")
        print("   CGEvent origin:  (\(Int(screenOffsetX)), \(Int(screenOffsetY)))")
    }
}

// ============================================
// Observer pour les changements d'écran
// ============================================

// Sauvegarde de la dernière géométrie connue pour détecter les changements
var lastKnownScreenOriginX: CGFloat = 0
var lastKnownScreenOriginY: CGFloat = 0
var lastKnownScreenWidth: CGFloat = 0
var lastKnownScreenHeight: CGFloat = 0

class ScreenChangeObserver {
    var timer: DispatchSourceTimer?

    init() {
        // Observer les changements de configuration d'écran (connexion/déconnexion)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("\n🔄 Display configuration changed, updating...")
            setupScreen()
            findXeneonDisplayID()
            saveCurrentGeometry()
        }

        // Timer GCD pour vérifier les changements de position
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer?.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer?.setEventHandler {
            checkForGeometryChanges()
        }
        timer?.resume()
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
    // Chercher l'écran Xeneon dans la liste actuelle (qui est mise à jour par le système)
    guard let currentXeneon = NSScreen.screens.first(where: {
        $0.localizedName.contains("XENEON") || $0.localizedName.contains("Corsair")
    }) ?? (NSScreen.screens.count > 1 ? NSScreen.screens[1] : nil) else {
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

        // Mettre à jour la référence à l'écran
        targetScreen = currentXeneon
        findXeneonDisplayID()
        updateScreenGeometry()
        saveCurrentGeometry()
    }
}

var screenObserver: ScreenChangeObserver?

// ============================================
// Vérification des permissions
// ============================================

func checkAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// ============================================
// Icône de la barre de menus
// ============================================

let logPath = "/tmp/touchdown.log"

// NSObject: les NSMenuItem ont besoin d'une cible Objective-C pour leurs actions.
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

    // Pas de mise à jour automatique: ce fork ne publie rien. Sparkle a été
    // entièrement retiré — plus de framework embarqué, plus de flux, plus
    // d'entrée « Check for Updates… » dans le menu. Mettre à jour, ici, c'est
    // relancer ./install.sh.

    // À appeler sur le thread principal avant NSApplication.run(), pour que
    // l'état « en attente de permission » soit déjà visible.
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
        // Toute mutation d'AppKit doit se faire sur le thread principal.
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
        // .accessory ne passe pas au premier plan tout seul: sans ça, le
        // panneau s'ouvre derrière les autres applications.
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

        // Le panneau prend sinon NSApp.applicationIconImage, qui reste
        // générique tant que LaunchServices n'a pas indexé le bundle — cas
        // courant juste après une installation. On charge donc l'icône
        // directement depuis Resources. Le nom vient de l'Info.plist pour
        // rester aligné sur ce que build.sh y écrit.
        let iconName = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String ?? "Touchdown"
        if let url = Bundle.main.url(forResource: iconName, withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            options[.applicationIcon] = icon
        }

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quitDriver() {
        // exit(0): avec KeepAlive { SuccessfulExit = false }, launchd ne
        // relance pas après une sortie propre.
        exit(0)
    }
}

// ============================================
// Programme principal
// ============================================

// Référence forte sur le manager HID. attachDriver() rend la main avant que
// NSApplication.run() ne serve la runloop: sans ce global, ARC libère le
// manager au retour, la source runloop disparaît avec lui et plus aucun
// événement n'arrive — alors que l'ouverture et la saisie ont réussi, donc
// le driver s'annonce « actif » sans rien capter.
var hidManager: IOHIDManager?

// Attache le HID et démarre la capture. Doit tourner sur le thread principal:
// le callback est planifié sur CFRunLoopGetMain(), servi par NSApplication.run().
func attachDriver() {
    // Configurer l'écran cible
    setupScreen()
    findXeneonDisplayID()
    saveCurrentGeometry()

    // Initialiser l'observer pour les changements d'écran
    screenObserver = ScreenChangeObserver()

    print("""

    📊 Current configuration:
       Touchscreen: X=[0, \(Int(touchscreenMaxX))], Y=[0, \(Int(touchscreenMaxY))]
       Click mode: \(clickMode == .moveCursorAndClick ? "Move cursor + click" : "Click in place")
       Capture mode: \(captureMode == .exclusive ? "EXCLUSIVE (blocks system events)" : "SHARED (may cause double clicks)")

    ⚠️  If clicks land in the wrong place, adjust touchscreenMaxX/Y in the
       source after running HIDAnalyzer.

    """)

    // Créer le HID Manager
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager

    // Filtrer pour notre écran tactile
    let deviceMatch: [String: Any] = [
        kIOHIDVendorIDKey as String: TOUCHSCREEN_VENDOR_ID,
        kIOHIDProductIDKey as String: TOUCHSCREEN_PRODUCT_ID
    ]

    IOHIDManagerSetDeviceMatching(manager, deviceMatch as CFDictionary)

    // Ouvrir le manager avec le mode approprié
    // kIOHIDOptionsTypeSeizeDevice = 0x01 - prend le contrôle exclusif du périphérique
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
        // Rester en vie et signaler dans la barre de menus. Un exit() ici
        // déclencherait la boucle de relance de launchd.
        StatusController.shared.setState(.failed("HID open refused"))
        return
    }

    // Vérifier le périphérique. Absent = probablement débranché, donc on
    // réessaie au lieu de sortir: le Xeneon peut arriver après le driver.
    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
        print("⏳ Touchscreen not found, retrying in 3s...")
        StatusController.shared.setState(.waitingDevice)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { attachDriver() }
        return
    }

    print("✅ Touchscreen connected")

    // Enregistrer le callback
    IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    StatusController.shared.setState(.active)

    print("""

    🎯 Driver active. Touch the screen to click.

    """)
}

// ============================================
// Programme principal
// ============================================

// install.sh relance le LaunchAgent alors qu'une copie lancée à la main peut
// encore tourner. Deux instances en mode exclusif se disputeraient le seize
// HID, donc la plus récente s'efface.
func ensureSingleInstance() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    guard !others.isEmpty else { return }

    let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
    print("⚠️  Another instance is already running (pid \(pids)), exiting.")
    // exit(0): sortie propre, donc KeepAlive { SuccessfulExit = false } ne relance pas.
    exit(0)
}

func main() {
    print("""
    ╔════════════════════════════════════════════════════════════╗
    ║   Touchdown - Corsair Xeneon Edge               v1.5.0     ║
    ║   Maps touches to absolute clicks                          ║
    ╚════════════════════════════════════════════════════════════╝

    """)

    ensureSingleInstance()

    // L'icône avant tout le reste: c'est elle qui rend visible l'attente
    // de permission, sinon l'utilisateur n'a que le journal.
    StatusController.shared.install()

    // Le dialogue de permission doit être demandé depuis le thread principal.
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

        // Polling silencieux, hors du thread principal pour ne pas figer la
        // barre de menus. Un seul dialogue a été montré, pas de re-demande.
        // Et pas d'exit(): sinon KeepAlive relance en boucle et empile les
        // dialogues système.
        DispatchQueue.global(qos: .utility).async {
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 2.0)
            }
            print("✅ Accessibility permission granted")
            DispatchQueue.main.async { attachDriver() }
        }
    }

    // NSApplication fournit la boucle d'événements (mode par défaut), donc les
    // sources CFRunLoop du HID sont servies. .accessory = pas d'icône du Dock.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}

// Désactiver le buffering pour voir la sortie en temps réel
setbuf(stdout, nil)

// Point d'entrée
main()
