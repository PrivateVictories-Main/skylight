// Generates Sources/Skylight/Resources/AppIcon.icns — the "Day Skylight" icon:
// a baby-blue sky behind a glass skylight pane grid, drifting light, and a
// glowing terminal prompt. Every size renders natively (no resampling).
// Run: swift scripts/make-icon.swift
import AppKit

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, NSColor)]) -> NSGradient {
    NSGradient(colors: stops.map { $0.1 },
               atLocations: stops.map { $0.0 },
               colorSpace: .deviceRGB)!
}

/// Draw the icon at `S` points into the current graphics context.
/// "Ribbon" — Ryan's pick (2026-08-08): a bold folded prompt chevron with
/// VS-Code-style depth on the baby-blue field, coral underscore, lit rim.
/// Original mark; borrows brand DNA (fold depth, burst energy), never marks.
func drawIcon(_ S: CGFloat) {
    let k = S / 512
    let corner = S * 0.2237
    let base = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                            xRadius: corner, yRadius: corner)
    // Baby-blue field, palest at the top.
    gradient([(0, c(0x6FB4F0)), (0.5, c(0x9BD0FA)), (1, c(0xE4F4FF))])
        .draw(in: base, angle: 90)
    base.addClip()

    func softShadow() {
        let sh = NSShadow()
        sh.shadowColor = c(0x1B3E6E, 0.30)
        sh.shadowBlurRadius = 18 * k
        sh.shadowOffset = NSSize(width: 0, height: -8 * k)
        sh.set()
    }

    // The folded chevron: deep-blue base pass, lighter upper arm = the fold.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 150 * k, y: 388 * k))
    chevron.line(to: NSPoint(x: 330 * k, y: 262 * k))
    chevron.line(to: NSPoint(x: 150 * k, y: 136 * k))
    chevron.lineWidth = 96 * k
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSGraphicsContext.current?.saveGraphicsState()
    softShadow()
    c(0x1F5E9E).setStroke()
    chevron.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    let upper = NSBezierPath()
    upper.move(to: NSPoint(x: 150 * k, y: 388 * k))
    upper.line(to: NSPoint(x: 330 * k, y: 262 * k))
    upper.lineWidth = 96 * k
    upper.lineCapStyle = .round
    c(0x3E8AD6).setStroke()
    upper.stroke()

    // Sheen along the upper arm.
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: 158 * k, y: 372 * k))
    sheen.line(to: NSPoint(x: 306 * k, y: 268 * k))
    sheen.lineWidth = 26 * k
    sheen.lineCapStyle = .round
    c(0xFFFFFF, 0.28).setStroke()
    sheen.stroke()

    // Coral underscore — the cursor.
    NSGraphicsContext.current?.saveGraphicsState()
    softShadow()
    c(0xE86A4C).setFill()
    NSBezierPath(roundedRect: NSRect(x: 300 * k, y: 122 * k, width: 128 * k, height: 44 * k),
                 xRadius: 22 * k, yRadius: 22 * k).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Lit top edge — the glisten.
    NSGraphicsContext.current?.saveGraphicsState()
    base.addClip()
    NSGradient(starting: c(0xFFFFFF, 0.5), ending: c(0xFFFFFF, 0.0))!
        .draw(in: NSRect(x: 0, y: S - 84 * k, width: S, height: 84 * k), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
}

func renderPNG(_ px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    renderPNG(px, to: iconset.appendingPathComponent("\(name).png"))
}

let out = root.appendingPathComponent("Sources/Skylight/Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
precondition(task.terminationStatus == 0, "iconutil failed")
print("wrote \(out.path)")
