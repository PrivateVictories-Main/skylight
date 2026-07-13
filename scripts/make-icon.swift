// Renders the Skylight app icon: a soft sky gradient in a macOS squircle with
// a minimal four-pane skylight frame. Run: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Canvas is transparent; macOS squircle shape with margin (Big Sur style).
let margin: CGFloat = size * 0.098
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
squircle.addClip()

// Sky gradient: deep indigo dusk at bottom → bright sky at top.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.23, green: 0.42, blue: 0.78, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.76, blue: 0.97, alpha: 1),
])!
gradient.draw(in: rect, angle: 90)

// Soft glow near the top, like daylight through glass.
let glow = NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.55),
                      ending: NSColor(calibratedWhite: 1, alpha: 0))!
glow.draw(in: CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.45,
                     width: rect.width, height: rect.height * 0.45), angle: -90)

// Skylight frame: white rounded square with a 2×2 pane grid.
let frameSide = rect.width * 0.52
let frameRect = CGRect(x: rect.midX - frameSide / 2, y: rect.midY - frameSide / 2,
                       width: frameSide, height: frameSide)
let bar = frameSide * 0.075
let paneRadius = frameSide * 0.14

NSColor.white.setStroke()
let outline = NSBezierPath(roundedRect: frameRect, xRadius: paneRadius, yRadius: paneRadius)
outline.lineWidth = bar
outline.stroke()

let cross = NSBezierPath()
cross.move(to: NSPoint(x: frameRect.midX, y: frameRect.minY + bar / 2))
cross.line(to: NSPoint(x: frameRect.midX, y: frameRect.maxY - bar / 2))
cross.move(to: NSPoint(x: frameRect.minX + bar / 2, y: frameRect.midY))
cross.line(to: NSPoint(x: frameRect.maxX - bar / 2, y: frameRect.midY))
cross.lineWidth = bar
cross.stroke()

image.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
