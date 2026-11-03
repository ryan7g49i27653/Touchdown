#!/usr/bin/env swift

// Generates Touchdown.icns.
//
//   ./make-icon.swift [output-dir]
//
// The result is committed, so a normal build does not run this -- build.sh
// just copies the .icns in. Re-run it only to change the artwork.
//
// The glyph is the `hand.tap.fill` SF Symbol -- Apple-drawn, so it stays
// correct at every size rather than being a hand-rolled path that falls apart
// when small.
//
// Deliberately NOT `hand.rays`, which the menu bar status item uses. That
// symbol is outlined with thin rays: correct for a template image rendered at
// menu bar size on a plain background, and illegible as icon art. Rendered
// into this icon it turns to mush by 32px and is an unreadable smudge at 16px.
// The two places have different constraints, so they get different symbols; a
// filled glyph is what survives being scaled down.
//
// 32px is the size that actually matters. The Privacy & Security lists this
// icon appears in lay out at 16pt, which on any Retina display draws the @2x
// asset -- so legibility was judged at 32px first and 16px second.

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Apple's icon grid: the body occupies 824 of a 1024 canvas, leaving the rest
// as the margin the system expects. Hard-coding 0.8047 keeps that ratio at
// every size instead of guessing a corner radius per size.
let bodyRatio: CGFloat = 0.8047

// Corner shape. macOS uses a superellipse, not a rounded rectangle -- circular
// corners read subtly wrong next to real system icons. n=5 matches closely.
func squircle(in rect: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

// Indigo to violet. Deliberately not blue: the Privacy lists this icon shows up
// in already contain several blue-and-white app icons, and at 16px hue is most
// of what distinguishes one row from another.
let topColor = color(0x8B5CF6)
let bottomColor = color(0x4338CA)

func tintedWhite(_ image: NSImage) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("could not allocate \(pixels)px bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let body = NSRect(x: (s - s * bodyRatio) / 2, y: (s - s * bodyRatio) / 2,
                      width: s * bodyRatio, height: s * bodyRatio)
    let shape = squircle(in: body)

    // Body gradient, top-left to bottom-right.
    shape.addClip()
    NSGradient(starting: topColor, ending: bottomColor)?
        .draw(in: body, angle: -55)

    // Highlight across the top third, so the icon has some depth instead of
    // reading as a flat sticker at large sizes.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
              angle: -90)

    NSGraphicsContext.current?.cgContext.resetClip()

    // Hairline edge. Keeps the silhouette crisp against a dark sidebar.
    NSColor(white: 1, alpha: 0.16).setStroke()
    shape.lineWidth = max(1, s * 0.004)
    shape.stroke()

    // Small sizes get a heavier weight and slightly more of the body, because
    // the thin strokes of the tap arc are the first thing to vanish.
    let small = pixels <= 32
    let weight: NSFont.Weight = small ? .bold : .medium
    let config = NSImage.SymbolConfiguration(pointSize: s * (small ? 0.46 : 0.42), weight: weight)
    guard let symbol = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: "Touchdown")?
        .withSymbolConfiguration(config) else {
        fatalError("hand.tap.fill unavailable")
    }

    let glyph = tintedWhite(symbol)
    let g = glyph.size

    // Optical rather than geometric centring. The glyph's mass is not evenly
    // distributed -- the tap arc is light and sits top-left, the hand is solid
    // and sits bottom-right -- so centring the bounding box leaves it looking
    // low and right of centre. Nudge back against the weight.
    let origin = NSPoint(x: (s - g.width) / 2 - s * 0.010,
                         y: (s - g.height) / 2 + s * 0.018)

    // Drop shadow seats the mark on the body the way system icons do -- but
    // only above 32px. At icon sizes the blur is wider than the strokes it
    // sits under, so it reads as a smudge rather than depth.
    if !small {
        NSGraphicsContext.current?.cgContext.setShadow(
            offset: CGSize(width: 0, height: -s * 0.008),
            blur: s * 0.022,
            color: NSColor(white: 0, alpha: 0.28).cgColor)
    }
    glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(pixels)px PNG")
    }
    return data
}

// name -> pixel size. Both members of each @1x/@2x pair are rendered natively
// rather than downscaled, which is what keeps 16px and 32px sharp.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = (outDir as NSString).appendingPathComponent("Touchdown.iconset")
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in variants {
    let path = (iconset as NSString).appendingPathComponent("\(name).png")
    try render(pixels: px).write(to: URL(fileURLWithPath: path))
}

print("✅ wrote \(iconset)")
print("   now: iconutil -c icns \(iconset)")
