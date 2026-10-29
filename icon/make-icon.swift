// Draws the TapWatch app icon to icon/icon.png (1024×1024).
// Run from the project folder: swift icon/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1),
                        NSColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185), angle: -90)

    // Shield.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 820))
    shield.curve(to: NSPoint(x: 270, y: 720), controlPoint1: NSPoint(x: 430, y: 760), controlPoint2: NSPoint(x: 340, y: 730))
    shield.line(to: NSPoint(x: 270, y: 520))
    shield.curve(to: NSPoint(x: 512, y: 200), controlPoint1: NSPoint(x: 270, y: 360), controlPoint2: NSPoint(x: 400, y: 260))
    shield.curve(to: NSPoint(x: 754, y: 520), controlPoint1: NSPoint(x: 624, y: 260), controlPoint2: NSPoint(x: 754, y: 360))
    shield.line(to: NSPoint(x: 754, y: 720))
    shield.curve(to: NSPoint(x: 512, y: 820), controlPoint1: NSPoint(x: 684, y: 730), controlPoint2: NSPoint(x: 594, y: 760))
    shield.close()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.85, blue: 0.62, alpha: 1),
                        NSColor(red: 0.10, green: 0.55, blue: 0.85, alpha: 1)])!.draw(in: shield, angle: -90)

    // Keyboard keys on the shield.
    NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 0.85).setFill()
    let key: CGFloat = 70, gap: CGFloat = 18
    for row in 0..<2 {
        let count = 4
        let width = CGFloat(count) * key + CGFloat(count - 1) * gap
        for column in 0..<count {
            let x = 512 - width / 2 + CGFloat(column) * (key + gap)
            let y = 560 - CGFloat(row) * (key + gap)
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: key, height: key), xRadius: 14, yRadius: 14).fill()
        }
    }
    // Space bar.
    NSBezierPath(roundedRect: NSRect(x: 512 - 150, y: 560 - 2 * (key + gap), width: 300, height: key),
                 xRadius: 14, yRadius: 14).fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon/icon.png"))
print("Wrote icon/icon.png")
