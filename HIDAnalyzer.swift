#!/usr/bin/env swift

import Foundation
import IOKit
import IOKit.hid

// ============================================
// Configuration for the Corsair Xeneon Edge
// ============================================
let TOUCHSCREEN_VENDOR_ID: Int = 0x27c0
let TOUCHSCREEN_PRODUCT_ID: Int = 0x0859

// ============================================
// Globals holding the current state
// ============================================
var lastX: Int = 0
var lastY: Int = 0
var isTouching: Bool = false
var reportCount: Int = 0

// ============================================
// Called for every HID value received
// ============================================
func hidInputCallback(context: UnsafeMutableRawPointer?,
                      result: IOReturn,
                      sender: UnsafeMutableRawPointer?,
                      value: IOHIDValue) {
    
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    let logicalMin = IOHIDElementGetLogicalMin(element)
    let logicalMax = IOHIDElementGetLogicalMax(element)
    
    // Show only the interesting data.
    // Usage Page 0x0D = Digitizer (touchscreens)
    // Usage Page 0x01 = Generic Desktop (mice, coordinates)
    
    let usagePageName: String
    let usageName: String
    
    switch usagePage {
    case 0x0D: // Digitizer
        usagePageName = "Digitizer"
        switch usage {
        case 0x22: usageName = "Finger"
        case 0x42: usageName = "Tip Switch (toucher)"
        case 0x47: usageName = "Confidence"
        case 0x48: usageName = "Width"
        case 0x49: usageName = "Height"
        case 0x51: usageName = "Contact ID"
        case 0x54: usageName = "Contact Count"
        case 0x55: usageName = "Contact Count Max"
        default: usageName = "Unknown (0x\(String(usage, radix: 16)))"
        }
        
    case 0x01: // Generic Desktop
        usagePageName = "Generic Desktop"
        switch usage {
        case 0x30:
            usageName = "X"
            lastX = Int(intValue)
        case 0x31:
            usageName = "Y"
            lastY = Int(intValue)
        case 0x32: usageName = "Z"
        default: usageName = "Unknown (0x\(String(usage, radix: 16)))"
        }
        
    case 0x09: // Button
        usagePageName = "Button"
        usageName = "Button \(usage)"
        
    default:
        usagePageName = "Page 0x\(String(usagePage, radix: 16))"
        usageName = "Usage 0x\(String(usage, radix: 16))"
    }
    
    // Detect the touch via Tip Switch
    if usagePage == 0x0D && usage == 0x42 {
        let wasTouching = isTouching
        isTouching = intValue != 0
        
        if isTouching && !wasTouching {
            reportCount += 1
            print("\n" + String(repeating: "=", count: 60))
            print("🖐️  TOUCH #\(reportCount) DÉTECTÉ!")
            print(String(repeating: "=", count: 60))
        } else if !isTouching && wasTouching {
            print("👆 RELÂCHÉ à X=\(lastX), Y=\(lastY)")
            print(String(repeating: "-", count: 60))
        }
    }
    
    // Print any non-zero value, and the coordinates
    let isCoordinate = (usagePage == 0x01 && (usage == 0x30 || usage == 0x31))
    let isTipSwitch = (usagePage == 0x0D && usage == 0x42)
    
    if intValue != 0 || isCoordinate || isTipSwitch {
        let rangeInfo = (logicalMax > 0) ? " [min:\(logicalMin), max:\(logicalMax)]" : ""
        print("  \(usagePageName) / \(usageName): \(intValue)\(rangeInfo)")
    }
}

// ============================================
// Called for every raw HID report
// ============================================
func hidReportCallback(context: UnsafeMutableRawPointer?,
                       result: IOReturn,
                       sender: UnsafeMutableRawPointer?,
                       type: IOHIDReportType,
                       reportID: UInt32,
                       report: UnsafeMutablePointer<UInt8>,
                       reportLength: CFIndex) {
    
    // Print the raw report as hex
    var hexString = ""
    for i in 0..<reportLength {
        hexString += String(format: "%02X ", report[i])
    }
    print("📦 RAW [ID:\(reportID), len:\(reportLength)]: \(hexString)")
}

// ============================================
// Main
// ============================================
func main() {
    print("""
    ╔════════════════════════════════════════════════════════════╗
    ║     HID Analyzer - Corsair Xeneon Edge Touchscreen         ║
    ║     VendorID: 0x27c0  ProductID: 0x0859                    ║
    ╚════════════════════════════════════════════════════════════╝
    
    Touche ton écran pour voir les rapports HID...
    (Ctrl+C pour quitter)
    
    """)
    
    // Create the HID manager
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    
    // Match only our touchscreen
    let deviceMatch: [String: Any] = [
        kIOHIDVendorIDKey as String: TOUCHSCREEN_VENDOR_ID,
        kIOHIDProductIDKey as String: TOUCHSCREEN_PRODUCT_ID
    ]
    
    IOHIDManagerSetDeviceMatching(manager, deviceMatch as CFDictionary)
    
    // Open the manager
    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        print("❌ Erreur: Impossible d'ouvrir IOHIDManager (code: \(openResult))")
        print("   → Vérifie que l'écran est bien branché")
        print("   → Tu devras peut-être autoriser l'accès dans Préférences Système")
        exit(1)
    }
    
    // Confirm the device was found
    guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
        print("❌ Erreur: Écran tactile non trouvé!")
        print("   VendorID attendu: 0x\(String(TOUCHSCREEN_VENDOR_ID, radix: 16))")
        print("   ProductID attendu: 0x\(String(TOUCHSCREEN_PRODUCT_ID, radix: 16))")
        exit(1)
    }
    
    print("✅ Écran tactile trouvé! (\(deviceSet.count) périphérique(s))")
    
    // Print the device info
    for device in deviceSet {
        if let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) {
            print("   Fabricant: \(manufacturer)")
        }
        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) {
            print("   Produit: \(product)")
        }
    }
    print("")
    
    // Register the parsed-value callback
    IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, nil)
    
    // Optional: also register the raw-report callback
    // (uncomment to see the raw bytes)
    // IOHIDManagerRegisterInputReportCallback(manager, hidReportCallback, nil)
    
    // Planifier sur le RunLoop principal
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    
    print("🎧 En écoute... Touche l'écran!")
    print(String(repeating: "-", count: 60))
    
    // Lancer le RunLoop
    CFRunLoopRun()
}

// Unbuffered, so output appears as it happens
setbuf(stdout, nil)

// Lancer le programme
main()
