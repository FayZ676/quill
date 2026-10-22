// Draws Quill's app icon: a paper-white tile with fading text lines, one focused line,
// and a glowing caret in the accent color. Usage: swift make-icon.swift <output.png> <RRGGBB> [ios]
// With "ios", the tile fills the whole square, unrounded and unshadowed: iOS masks it itself.
import AppKit

let fullBleed = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "ios"

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Tile with a soft shadow, sized to Apple's icon grid (824pt on a 1024 canvas).
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
if fullBleed {
    // Draw the same design, scaled up so the tile covers the canvas.
    let t = NSAffineTransform()
    t.scale(by: CGFloat(px) / tile.width)
    t.translateX(by: -tile.minX, yBy: -tile.minY)
    t.concat()
}
let shape = fullBleed ? NSBezierPath(rect: tile) : NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
if !fullBleed {
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
}
color(250, 250, 247).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(starting: color(255, 255, 253), ending: color(238, 238, 234))!
gradient.draw(in: shape, angle: -90)

let left: CGFloat = 230
let lineHeight: CGFloat = 46
let caret = NSRect(x: left + 380 + 22, y: 500 - 52, width: 22, height: 104)
let hex = Int(CommandLine.arguments[2], radix: 16)!
let accent = color(CGFloat(hex >> 16 & 0xFF), CGFloat(hex >> 8 & 0xFF), CGFloat(hex & 0xFF))
let caretPath = NSBezierPath(roundedRect: caret, xRadius: 11, yRadius: 11)
// The caret glows: a soft halo in the accent, taller than wide like the caret, drawn under the
// lines so they stay crisp.
NSGraphicsContext.saveGraphicsState()
let halo = NSAffineTransform()
halo.translateX(by: caret.midX, yBy: caret.midY)
halo.scaleX(by: 1, yBy: 1.5)
halo.concat()
NSGradient(colors: [accent.withAlphaComponent(0.42), accent.withAlphaComponent(0.14), accent.withAlphaComponent(0)],
           atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
    .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: 130, options: [])
NSGraphicsContext.restoreGraphicsState()

// Text lines around the focused one, with the caret. The dimmed lines fade away with their
// distance from the focused line, as text does in the app.
let focusY: CGFloat = 500
let lineGap: CGFloat = 90
let lines: [(y: CGFloat, width: CGFloat)] = [
    (770, 470), (680, 520), (590, 440), (500, 380), (410, 500), (320, 300), (230, 420),
]
let dimOpacity: [CGFloat] = [1, 1, 0.55, 0.22]
for line in lines {
    let rect = NSRect(x: left, y: line.y - lineHeight / 2, width: line.width, height: lineHeight)
    let distance = Int((abs(line.y - focusY) / lineGap).rounded())
    (distance == 0 ? color(38, 38, 40) : color(200, 200, 196, dimOpacity[distance])).setFill()
    NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
}
// Then a tight bright rim. Shadows ignore the full-bleed scale, so it's scaled by hand.
NSGraphicsContext.saveGraphicsState()
let rim = NSShadow()
rim.shadowColor = accent.withAlphaComponent(0.9)
rim.shadowOffset = .zero
rim.shadowBlurRadius = 24 * (fullBleed ? CGFloat(px) / tile.width : 1)
rim.set()
accent.setFill()
caretPath.fill()
NSGraphicsContext.restoreGraphicsState()
accent.setFill()
caretPath.fill()

NSGraphicsContext.restoreGraphicsState()
// The App Store rejects iOS icons with an alpha channel, even a fully opaque one.
var output = rep
if fullBleed {
    let opaque = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: px, height: px))
    output = NSBitmapImageRep(cgImage: opaque.makeImage()!)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! output.representation(using: .png, properties: [:])!.write(to: out)
