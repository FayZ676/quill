#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// On the markup around a `[[link]]`'s shown text: the brackets, and the note's name
    /// when the link shows other text in its place.
    static let linkMarkup = NSAttributedString.Key("QuillLinkMarkup")
}

/// Hides the markup of `[[links]]`, as Obsidian's Live Preview does, so `[[Note|these words]]`
/// reads "these words" and `[[Note]]` reads "Note". The link the caret is in shows in full,
/// to be edited. Only the drawing changes: the text keeps every character.
final class LinkMarkupHider: NSObject, NSLayoutManagerDelegate {
    /// The link shown in full.
    private var revealed: NSRange?

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>, font: PlatformFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var hidden: [Int] = []
        for i in 0..<glyphRange.length {
            let c = characterIndexes[i]
            guard c < storage.length, revealed.map({ !NSLocationInRange(c, $0) }) ?? true,
                  storage.attribute(.linkMarkup, at: c, effectiveRange: nil) != nil else { continue }
            hidden.append(i)
        }
        guard !hidden.isEmpty else { return 0 }
        let kept = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { kept.deallocate() }
        kept.initialize(from: properties, count: glyphRange.length)
        for i in hidden { kept[i] = .null }
        layoutManager.setGlyphs(glyphs, properties: kept, characterIndexes: characterIndexes, font: font,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// Shows the link the caret is in (or at either end of) in full, and hides the one shown
    /// before. Call when the selection moves.
    func reveal(at selection: NSRange, in layoutManager: NSLayoutManager) {
        guard let storage = layoutManager.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        var link: NSRange?
        for i in [selection.location, selection.location - 1] where i >= 0 && i < storage.length {
            var range = NSRange()
            if storage.attribute(.noteLink, at: i, longestEffectiveRange: &range, in: all) != nil {
                link = range
                break
            }
        }
        guard link != revealed else { return }
        let old = revealed
        revealed = link
        for range in [old, link].compactMap({ $0 }) where NSMaxRange(range) <= storage.length {
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }
}
