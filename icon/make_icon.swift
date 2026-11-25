// Draws the MidiPress app icon (1024×1024 PNG): a pad pressing a keycap with ⌘ on it, on a charcoal tile.
// Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// MARK: Family style
// The sibling apps' icon scripts share this part word for word: a solid colour tile shaded slightly lighter at the
// top and one bold cream symbol with a gold accent. Only `tile` and the symbol differ between apps. Change all of them
// together.

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
/// `hex` moved `amount` of the way towards white (positive) or black (negative).
func shade(_ hex: UInt32, _ amount: CGFloat) -> CGColor {
    let c = rgb(hex).components!
    let target: CGFloat = amount > 0 ? 1 : 0
    let t = abs(amount)
    return CGColor(red: c[0] + (target - c[0]) * t, green: c[1] + (target - c[1]) * t, blue: c[2] + (target - c[2]) * t, alpha: 1)
}
let cream = rgb(0xf6f0e4)
let gold = rgb(0xe2b552)
let tile: UInt32 = 0x2a2724  // charcoal

// The tile, on the macOS icon grid: inset from the canvas, with rounded corners and a drop shadow.
let inset: CGFloat = 100
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                   cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(rgb(tile)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let tileShade = CGGradient(colorsSpace: space, colors: [shade(tile, 0.10), rgb(tile), shade(tile, -0.10)] as CFArray,
                           locations: [0, 0.5, 1])!
cg.drawLinearGradient(tileShade, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
cg.restoreGState()

/// Draws `body` with a soft shadow under it, so the symbol sits just above the tile.
func raised(_ body: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.18))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    cg.endTransparencyLayer()
    cg.restoreGState()
}

// MARK: Symbol

// A pad pressing down on a keycap with ⌘ on it; gold lines on both sides show the press.

let edge = CGColor(red: 0.85, green: 0.81, blue: 0.74, alpha: 1)  // the cream's shaded side

raised {
    // The pad: a rounded square with a shaded lower edge.
    let pad = CGRect(x: 397, y: 626, width: 230, height: 190)
    cg.addPath(CGPath(roundedRect: pad, cornerWidth: 44, cornerHeight: 44, transform: nil))
    cg.setFillColor(edge); cg.fillPath()
    cg.addPath(CGPath(roundedRect: CGRect(x: pad.minX, y: pad.minY + 22, width: pad.width, height: pad.height - 22),
                      cornerWidth: 44, cornerHeight: 44, transform: nil))
    cg.setFillColor(cream); cg.fillPath()

    // The keycap, seen from the front and a little above: a rounded base whose shaded sides show most at the front,
    // and the flat top set into it.
    let base = CGRect(x: 324, y: 204, width: 376, height: 336)
    cg.addPath(CGPath(roundedRect: base, cornerWidth: 70, cornerHeight: 70, transform: nil))
    cg.setFillColor(edge); cg.fillPath()
    let top = CGRect(x: 364, y: 286, width: 296, height: 234)
    cg.addPath(CGPath(roundedRect: top, cornerWidth: 48, cornerHeight: 48, transform: nil))
    cg.setFillColor(cream); cg.fillPath()
    let symbol = NSAttributedString(string: "⌘", attributes: [
        .font: NSFont.systemFont(ofSize: 150, weight: .bold),
        .foregroundColor: NSColor(cgColor: rgb(tile))!,
    ])
    let bounds = symbol.size()
    symbol.draw(at: CGPoint(x: size / 2 - bounds.width / 2, y: top.midY - bounds.height / 2))

    // Press lines: three on each side of the pad's lower edge, fanning out over the key.
    cg.setStrokeColor(gold); cg.setLineWidth(22); cg.setLineCap(.round)
    for side: CGFloat in [-1, 1] {
        for (from, to) in [((150, 692), (196, 724)), ((156, 646), (216, 646)), ((150, 600), (196, 568))]
            as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
            cg.move(to: CGPoint(x: size / 2 + side * from.0, y: from.1))
            cg.addLine(to: CGPoint(x: size / 2 + side * to.0, y: to.1))
        }
    }
    cg.strokePath()
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))
