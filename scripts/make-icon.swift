// Zeichnet das App-Icon (neutrales Schloss, kein TU-Branding) und schreibt Resources/AppIcon.icns.
// Aufruf: swift scripts/make-icon.swift   (nur nötig, wenn sich das Icon ändern soll)

import AppKit

func drawIcon(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let scale = size / 1024
        // macOS-Icon-Raster: 824er Fläche mit 100er Rand
        let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let background = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
        NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.30, alpha: 1),
                            NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 1)])!
            .draw(in: background, angle: -90)

        // Bügel
        let shackle = NSBezierPath()
        shackle.lineWidth = 64 * scale
        shackle.lineCapStyle = .round
        shackle.move(to: NSPoint(x: 392 * scale, y: 470 * scale))
        shackle.line(to: NSPoint(x: 392 * scale, y: 590 * scale))
        shackle.appendArc(withCenter: NSPoint(x: 512 * scale, y: 590 * scale), radius: 120 * scale,
                          startAngle: 180, endAngle: 0, clockwise: true)
        shackle.line(to: NSPoint(x: 632 * scale, y: 470 * scale))
        NSColor(calibratedWhite: 0.93, alpha: 1).setStroke()
        shackle.stroke()

        // Körper
        let body = NSBezierPath(roundedRect: NSRect(x: 322 * scale, y: 250 * scale, width: 380 * scale, height: 290 * scale),
                                xRadius: 56 * scale, yRadius: 56 * scale)
        NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.62, alpha: 1),
                            NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.46, alpha: 1)])!
            .draw(in: body, angle: -90)

        // Schlüsselloch
        let keyhole = NSBezierPath(ovalIn: NSRect(x: 482 * scale, y: 400 * scale, width: 60 * scale, height: 60 * scale))
        keyhole.append(NSBezierPath(roundedRect: NSRect(x: 497 * scale, y: 320 * scale, width: 30 * scale, height: 100 * scale),
                                    xRadius: 15 * scale, yRadius: 15 * scale))
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 0.85).setFill()
        keyhole.fill()
        return true
    }
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return representation.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! drawIcon(size: CGFloat(base * factor)).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns geschrieben" : "iconutil fehlgeschlagen")
