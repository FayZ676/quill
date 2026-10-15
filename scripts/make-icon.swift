// Draws Quill's app icon: a paper-white tile with dimmed text lines, one focused line,
// and a caret in the accent color. Usage: swift make-icon.swift <output.png> <RRGGBB>
import AppKit

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
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0, 0, 0, 0.28)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
color(250, 250, 247).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(starting: color(255, 255, 253), ending: color(238, 238, 234))!
gradient.draw(in: shape, angle: -90)

// Text lines: dimmed, dimmed, focused + caret, dimmed, dimmed.
let left: CGFloat = 230
let lineHeight: CGFloat = 46
let lines: [(y: CGFloat, width: CGFloat, focused: Bool)] = [
    (680, 520, false), (590, 440, false), (500, 380, true), (410, 500, false), (320, 300, false),
]
for line in lines {
    let rect = NSRect(x: left, y: line.y - lineHeight / 2, width: line.width, height: lineHeight)
    (line.focused ? color(38, 38, 40) : color(208, 208, 204)).setFill()
    NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
}
let caret = NSRect(x: left + 380 + 22, y: 500 - 52, width: 22, height: 104)
let hex = Int(CommandLine.arguments[2], radix: 16)!
color(CGFloat(hex >> 16 & 0xFF), CGFloat(hex >> 8 & 0xFF), CGFloat(hex & 0xFF)).setFill()
NSBezierPath(roundedRect: caret, xRadius: 11, yRadius: 11).fill()

NSGraphicsContext.restoreGraphicsState()
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: out)
