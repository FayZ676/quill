import AppKit

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }

    static let background = dynamic(light: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.965, alpha: 1),
                                     dark: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.110, alpha: 1))
    /// The strip holding the window buttons, a shade darker than the page.
    static let titleBar = dynamic(light: NSColor(srgbRed: 0.886, green: 0.886, blue: 0.878, alpha: 1),
                                   dark: NSColor(srgbRed: 0.047, green: 0.051, blue: 0.055, alpha: 1))
    static let text = dynamic(light: gray(0.15), dark: gray(0.86))
    static let markup = dynamic(light: gray(0.66), dark: gray(0.42))
    /// A `[[link]]` to a note not written yet: between the text and its markup.
    static let unwritten = dynamic(light: gray(0.45), dark: gray(0.62))
    static let dimmed = dynamic(light: gray(0.80), dark: gray(0.30))
    static let codeBackground = dynamic(light: gray(0, 0.045), dark: gray(1, 0.06))
    /// The app accent (vermilion). Defined once, as AccentColor in Resources/Assets.xcassets;
    /// AppKit serves it as the control accent color, so the caret, selection, sidebar and
    /// system controls all stay in step.
    static let accent = NSColor.controlAccentColor
    static let selection = dynamic(light: accent.withAlphaComponent(0.28),
                                    dark: accent.withAlphaComponent(0.45))
}
