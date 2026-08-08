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

var seed: UInt64 = 7
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(Double(seed >> 33) / Double(UInt64(1) << 31))
}

/// Draw the icon at `S` points into the current graphics context.
func drawIcon(_ S: CGFloat) {
    let k = S / 512
    seed = 7
    let corner = S * 0.2237
    let base = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: S, height: S),
                            xRadius: corner, yRadius: corner)
    // Baby-blue sky, palest at the top.
    gradient([(0, c(0x6FB4F0)), (0.45, c(0x92CCF9)), (0.8, c(0xBFE3FF)), (1, c(0xE8F6FF))])
        .draw(in: base, angle: 90)
    base.addClip()

    // Glints — tiny bright sparks in the upper sky.
    for _ in 0..<40 {
        let x = rnd() * S, y = (140 + rnd() * (512 - 160)) * k
        c(0xFFFFFF, 0.25 + rnd() * 0.45).setFill()
        let d = (rnd() < 0.85 ? 2.2 : 3.6) * k
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
    }

    // A soft stream of light drifting across the pane.
    let aur = NSBezierPath()
    aur.move(to: NSPoint(x: 40 * k, y: 300 * k))
    aur.curve(to: NSPoint(x: 480 * k, y: 400 * k),
              controlPoint1: NSPoint(x: 190 * k, y: 430 * k),
              controlPoint2: NSPoint(x: 330 * k, y: 300 * k))
    aur.lineWidth = 60 * k
    c(0xFFFFFF, 0.22).setStroke()
    aur.stroke()
    aur.lineWidth = 26 * k
    c(0xF2FBFF, 0.30).setStroke()
    aur.stroke()

    // Glass pane inset + mullions.
    let inset = 64 * k
    let pane = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
                                                width: S - inset * 2, height: S - inset * 2),
                            xRadius: 72 * k, yRadius: 72 * k)
    c(0xFFFFFF, 0.12).setFill()
    pane.fill()
    pane.lineWidth = max(1, 2.5 * k)
    c(0xFFFFFF, 0.85).setStroke()
    pane.stroke()
    let m = NSBezierPath()
    m.move(to: NSPoint(x: S / 2, y: 66 * k)); m.line(to: NSPoint(x: S / 2, y: S - 66 * k))
    m.move(to: NSPoint(x: 66 * k, y: S / 2)); m.line(to: NSPoint(x: S - 66 * k, y: S / 2))
    m.lineWidth = max(1, 2.5 * k)
    c(0xFFFFFF, 0.6).setStroke()
    m.stroke()

    // The prompt, deep navy with a soft white glow, lower-left pane.
    let f = NSFont.monospacedSystemFont(ofSize: 84 * k, weight: .semibold)
    let sh = NSShadow()
    sh.shadowColor = c(0xFFFFFF, 0.9)
    sh.shadowBlurRadius = 18 * k
    (">" as NSString).draw(at: NSPoint(x: 118 * k, y: 118 * k),
        withAttributes: [.font: f, .foregroundColor: c(0x17406B), .shadow: sh])
    ("_" as NSString).draw(at: NSPoint(x: 172 * k, y: 124 * k),
        withAttributes: [.font: f, .foregroundColor: c(0x2A6DAF), .shadow: sh])

    // Lit top edge.
    NSGraphicsContext.current?.saveGraphicsState()
    base.addClip()
    NSGradient(starting: c(0xFFFFFF, 0.55), ending: c(0xFFFFFF, 0.0))!
        .draw(in: NSRect(x: 0, y: S - 90 * k, width: S, height: 90 * k), angle: -90)
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
