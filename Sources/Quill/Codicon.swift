import SwiftUI

/// One of VS Code's Codicons, drawn from its SVG path on the icons' 16-point grid and scaled
/// to fit, so it takes the color of the button it's in. Codicons © Microsoft, under Creative
/// Commons Attribution 4.0 (https://github.com/microsoft/vscode-codicons).
struct Codicon: Shape {
    static let newFile = Codicon("M9.5 1.1l3.4 3.5.1.4v2h-1V6H8V2H3v11h4v1H2.5l-.5-.5v-12l.5-.5h6.7l.3.1zM9 2v3h2.9L9 2zm4 14h-1v-3H9v-1h3V9h1v3h3v1h-3v3z")
    static let newFolder = Codicon("M14.5 2H7.71l-.85-.85L6.51 1h-5l-.5.5v11l.5.5H7v-1H1.99V6h4.49l.35-.15.86-.86H14v1.5l-.001.51h1.011V2.5L14.5 2zm-.51 2h-6.5l-.35.15-.86.86H2v-3h4.29l.85.85.36.15H14l-.01.99zM13 16h-1v-3H9v-1h3V9h1v3h3v1h-3v3z")

    private let outline: Path

    private init(_ d: String) { outline = Self.parse(d) }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        return outline.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 8 * scale, y: rect.midY - 8 * scale)))
    }

    /// The straight-line commands Codicons use (M, L, H, V and Z, absolute or relative), as
    /// in an SVG path's `d`.
    private static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens: [String] = []
        var number = ""
        func endNumber() { if !number.isEmpty { tokens.append(number); number = "" } }
        for c in d {
            if c.isLetter { endNumber(); tokens.append(String(c)) }
            else if c == "-" { endNumber(); number = "-" }
            // A second point starts a new number: ".85.85" is two.
            else if c == ".", number.contains(".") { endNumber(); number = "." }
            else if c.isNumber || c == "." { number.append(c) }
            else { endNumber() }
        }
        endNumber()

        var at = CGPoint.zero, start = CGPoint.zero
        var command = "M"
        var i = 0
        func next() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            let relative = command == command.lowercased()
            switch command.uppercased() {
            case "M", "L":
                let x = next(), y = next()
                at = relative ? CGPoint(x: at.x + x, y: at.y + y) : CGPoint(x: x, y: y)
                if command.uppercased() == "M" {
                    path.move(to: at)
                    start = at
                    // Pairs after a move are lines, as in SVG.
                    command = relative ? "l" : "L"
                } else {
                    path.addLine(to: at)
                }
            case "H":
                let x = next()
                at.x = relative ? at.x + x : x
                path.addLine(to: at)
            case "V":
                let y = next()
                at.y = relative ? at.y + y : y
                path.addLine(to: at)
            case "Z":
                path.closeSubpath()
                at = start
            default:
                i += 1
            }
        }
        return path
    }
}
