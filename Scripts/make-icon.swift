// Renders the app icon (1024×1024) with Core Graphics. Usage: swift Scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// macOS icon grid: 824 pt rounded square centered on a 1024 canvas.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let colors = [NSColor(srgbRed: 0.17, green: 0.56, blue: 0.98, alpha: 1).cgColor,
              NSColor(srgbRed: 0.05, green: 0.27, blue: 0.70, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: size / 2, y: rect.maxY), end: CGPoint(x: size / 2, y: rect.minY), options: [])
// Soft top highlight.
let highlight = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
let hg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: highlight, locations: [0, 1])!
ctx.drawLinearGradient(hg, start: CGPoint(x: size / 2, y: rect.maxY), end: CGPoint(x: size / 2, y: rect.midY), options: [])
ctx.restoreGState()

// Arrow and tray in white.
ctx.setFillColor(NSColor.white.cgColor)
ctx.setStrokeColor(NSColor.white.cgColor)
let cx = size / 2
let shaftWidth: CGFloat = 112
let shaftTop: CGFloat = 760
let headBase: CGFloat = 520
let tip: CGFloat = 340
ctx.fill(CGRect(x: cx - shaftWidth / 2, y: headBase - 4, width: shaftWidth, height: shaftTop - headBase + 4).insetBy(dx: 0, dy: 0))
let head = CGMutablePath()
head.move(to: CGPoint(x: cx - 220, y: headBase))
head.addLine(to: CGPoint(x: cx + 220, y: headBase))
head.addLine(to: CGPoint(x: cx, y: tip))
head.closeSubpath()
ctx.addPath(head)
ctx.fillPath()
// Tray
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let tray = CGMutablePath()
tray.move(to: CGPoint(x: 268, y: 380))
tray.addLine(to: CGPoint(x: 268, y: 262))
tray.addLine(to: CGPoint(x: size - 268, y: 262))
tray.addLine(to: CGPoint(x: size - 268, y: 380))
ctx.addPath(tray)
ctx.strokePath()

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
