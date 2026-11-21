// Draws the MidiPress app icon (1024×1024 PNG): a drum pad joined by a cable to a keyboard key, on an
// amber-to-coral rounded square. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: the shape is inset from the canvas and has rounded corners.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(CGColor(red: 0.55, green: 0.22, blue: 0.10, alpha: 1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 1.00, green: 0.71, blue: 0.20, alpha: 1), CGColor(red: 0.94, green: 0.32, blue: 0.30, alpha: 1)] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(background, start: CGPoint(x: inset, y: size - inset), end: CGPoint(x: size - inset, y: inset), options: [])
let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(shine, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: size / 2), options: [])
cg.restoreGState()

let white = CGColor(gray: 1, alpha: 0.97)
let ink = CGColor(red: 0.80, green: 0.30, blue: 0.20, alpha: 1)

// The pad (upper left) and the key (lower right).
let pad = CGRect(x: 230, y: 560, width: 250, height: 250)
let key = CGRect(x: 520, y: 220, width: 290, height: 290)

// Cable from the pad's right edge to the key's top, behind both.
cg.move(to: CGPoint(x: pad.maxX - 10, y: pad.midY))
cg.addCurve(to: CGPoint(x: key.midX, y: key.maxY - 10), control1: CGPoint(x: key.midX + 40, y: pad.midY),
            control2: CGPoint(x: key.midX, y: key.maxY + 130))
cg.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
cg.setLineWidth(34)
cg.setLineCap(.round)
cg.strokePath()

// Pad: a rounded square with a glowing centre, as on a pad controller.
cg.addPath(CGPath(roundedRect: pad, cornerWidth: 46, cornerHeight: 46, transform: nil))
cg.setFillColor(white)
cg.fillPath()
let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.62, blue: 0.25, alpha: 0.95),
                                                   CGColor(red: 1, green: 0.62, blue: 0.25, alpha: 0)] as CFArray, locations: [0, 1])!
cg.saveGState()
cg.addPath(CGPath(roundedRect: pad.insetBy(dx: 28, dy: 28), cornerWidth: 30, cornerHeight: 30, transform: nil))
cg.clip()
cg.drawRadialGradient(glow, startCenter: CGPoint(x: pad.midX, y: pad.midY), startRadius: 0,
                      endCenter: CGPoint(x: pad.midX, y: pad.midY), endRadius: 130, options: [])
cg.restoreGState()

// Key: a keycap with a deeper base, and a ⌘ on top.
cg.addPath(CGPath(roundedRect: key, cornerWidth: 58, cornerHeight: 58, transform: nil))
cg.setFillColor(CGColor(gray: 0.86, alpha: 1))
cg.fillPath()
let top = CGRect(x: key.minX + 22, y: key.minY + 46, width: key.width - 44, height: key.height - 64)
cg.addPath(CGPath(roundedRect: top, cornerWidth: 44, cornerHeight: 44, transform: nil))
cg.setFillColor(white)
cg.fillPath()
let symbol = NSAttributedString(string: "⌘", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .semibold),
    .foregroundColor: NSColor(cgColor: ink)!,
])
let bounds = symbol.size()
symbol.draw(at: CGPoint(x: top.midX - bounds.width / 2, y: top.midY - bounds.height / 2 + 4))

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
