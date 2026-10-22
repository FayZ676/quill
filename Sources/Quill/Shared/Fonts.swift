import CoreText
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum EditorFont: String, CaseIterable, Identifiable {
    case mono = "Mono", duo = "Duo", quattro = "Quattro"
    var id: String { rawValue }
}

extension Font {
    /// One face of the chosen editor font, for the app's own text. Fixed at `size` unless
    /// `style` is given, in which case it scales with Dynamic Type like that style. SwiftUI
    /// falls back to the system font when the bundled fonts aren't registered.
    static func quill(_ choice: EditorFont, size: CGFloat, bold: Bool = false,
                      relativeTo style: Font.TextStyle? = nil) -> Font {
        let name = "iAWriter\(choice.rawValue)S-\(bold ? "Bold" : "Regular")"
        if let style { return .custom(name, size: size, relativeTo: style) }
        return .custom(name, fixedSize: size)
    }
}

private struct EditorFontKey: EnvironmentKey {
    static let defaultValue = EditorFont.duo
}

extension EnvironmentValues {
    /// The chosen editor font, so the app's own text can follow it; set once at the root.
    var editorFont: EditorFont {
        get { self[EditorFontKey.self] }
        set { self[EditorFontKey.self] = newValue }
    }
}

/// Sets text in the chosen editor font, so labels and bars match the page.
private struct AppFont: ViewModifier {
    @Environment(\.editorFont) private var choice
    let size: CGFloat
    let bold: Bool
    let style: Font.TextStyle?

    func body(content: Content) -> some View {
        content.font(.quill(choice, size: size, bold: bold, relativeTo: style))
    }
}

extension View {
    func appFont(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle? = nil) -> some View {
        modifier(AppFont(size: size, bold: bold, style: style))
    }
}

enum Fonts {
    static let defaultSize = 17.0

    /// Registers the iA Writer fonts shipped in the bundle's Resources/Fonts.
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
    let regular, bold, italic, boldItalic: PlatformFont
    let size: CGFloat

    init(_ choice: EditorFont, size: CGFloat) {
        let family = "iAWriter\(choice.rawValue)S"
        if let r = PlatformFont(name: "\(family)-Regular", size: size) {
            regular = r
            bold = PlatformFont(name: "\(family)-Bold", size: size) ?? r
            italic = PlatformFont(name: "\(family)-Italic", size: size) ?? r
            boldItalic = PlatformFont(name: "\(family)-BoldItalic", size: size) ?? bold
        } else {
            let base = choice == .quattro
                ? PlatformFont.systemFont(ofSize: size)
                : PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
            regular = base
            bold = Self.withTraits(base, bold: true, italic: false)
            italic = Self.withTraits(base, bold: false, italic: true)
            boldItalic = Self.withTraits(base, bold: true, italic: true)
        }
        self.size = size
    }

    private static func withTraits(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return PlatformFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return PlatformFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    func variant(bold b: Bool, italic i: Bool) -> PlatformFont {
        b ? (i ? boldItalic : bold) : (i ? italic : regular)
    }

    func width(_ string: String, font: PlatformFont? = nil) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font ?? regular]).width
    }

    /// Room in the left margin that heading markers hang into, iA-style.
    var hang: CGFloat { width("#### ", font: bold) }
}
