import AppKit
import CoreText

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }

    static let background = dynamic(light: NSColor(srgbRed: 0.973, green: 0.973, blue: 0.965, alpha: 1),
                                     dark: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.110, alpha: 1))
    static let text = dynamic(light: gray(0.15), dark: gray(0.86))
    static let markup = dynamic(light: gray(0.66), dark: gray(0.42))
    static let dimmed = dynamic(light: gray(0.80), dark: gray(0.30))
    static let codeBackground = dynamic(light: gray(0, 0.045), dark: gray(1, 0.06))
    /// The app accent (vermilion). Defined once, as AccentColor in Resources/Assets.xcassets;
    /// AppKit serves it as the control accent color, so the caret, selection, sidebar and
    /// system controls all stay in step.
    static let accent = NSColor.controlAccentColor
    static let selection = dynamic(light: accent.withAlphaComponent(0.28),
                                    dark: accent.withAlphaComponent(0.45))
}

enum EditorFont: String, CaseIterable, Identifiable {
    case mono = "Mono", duo = "Duo", quattro = "Quattro"
    var id: String { rawValue }
}

enum Fonts {
    /// Registers the iA Writer fonts shipped in Contents/Resources/Fonts.
    static func registerBundled() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

/// The four faces of one editor font at one size. Falls back to system fonts when the
/// bundled iA fonts are unavailable (e.g. when run with `swift run`).
struct FontSet {
    let regular, bold, italic, boldItalic: NSFont
    let size: CGFloat

    init(_ choice: EditorFont, size: CGFloat) {
        let family = "iAWriter\(choice.rawValue)S"
        if let r = NSFont(name: "\(family)-Regular", size: size) {
            regular = r
            bold = NSFont(name: "\(family)-Bold", size: size) ?? r
            italic = NSFont(name: "\(family)-Italic", size: size) ?? r
            boldItalic = NSFont(name: "\(family)-BoldItalic", size: size) ?? bold
        } else {
            let base = choice == .quattro
                ? NSFont.systemFont(ofSize: size)
                : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            regular = base
            bold = Self.withTraits(base, .bold)
            italic = Self.withTraits(base, .italic)
            boldItalic = Self.withTraits(base, [.bold, .italic])
        }
        self.size = size
    }

    private static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }

    func variant(bold b: Bool, italic i: Bool) -> NSFont {
        b ? (i ? boldItalic : bold) : (i ? italic : regular)
    }

    func width(_ string: String, font: NSFont? = nil) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font ?? regular]).width
    }

    /// Room in the left margin that heading markers hang into, iA-style.
    var hang: CGFloat { width("#### ", font: bold) }
}
