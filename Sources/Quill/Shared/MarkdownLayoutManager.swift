#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks a thematic break (`---`) for MarkdownLayoutManager to draw a line beside.
    static let markdownRule = NSAttributedString.Key("QuillMarkdownRule")
    /// Marks a task's box (`[ ]`, `[x]`), which a click or tap ticks.
    static let markdownTaskBox = NSAttributedString.Key("QuillMarkdownTaskBox")
    /// Spans a whole link, with a value of its own so links side by side stay apart.
    static let markdownLink = NSAttributedString.Key("QuillMarkdownLink")
    /// Marks a link's brackets and address, hidden until the caret comes to the link.
    static let markdownConceal = NSAttributedString.Key("QuillMarkdownConceal")
}

/// Draws what Markdown means but the characters don't show: a hairline running out from
/// either side of a centered `---` to the edges of the column. Also hides a link's
/// brackets and address, leaving its text, until the caret comes to it.
class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Links touching this range show their markup.
    private var selection = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the markup of the links the selection touches, and hides the rest again.
    func reveal(around sel: NSRange) {
        let before = links(touching: selection)
        selection = sel
        let after = links(touching: sel)
        guard before != after else { return }
        for range in before + after {
            invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    private func links(touching sel: NSRange) -> [NSRange] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let start = max(0, min(sel.location, storage.length) - 1)
        let end = min(storage.length, NSMaxRange(sel) + 1)
        var found: [NSRange] = []
        storage.enumerateAttribute(.markdownLink, in: NSRange(location: start, length: end - start)) { value, range, _ in
            guard value != nil else { return }
            var link = NSRange()
            _ = storage.attribute(.markdownLink, at: range.location, longestEffectiveRange: &link,
                                  in: NSRange(location: 0, length: storage.length))
            if touches(link, sel) { found.append(link) }
        }
        return found
    }

    private func touches(_ link: NSRange, _ sel: NSRange) -> Bool {
        sel.location <= NSMaxRange(link) && NSMaxRange(sel) >= link.location
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: PlatformFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        let count = glyphRange.length
        let hidden = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { hidden.deallocate() }
        var changed = false
        for i in 0..<count {
            hidden[i] = props[i]
            let c = charIndexes[i]
            guard c < storage.length, storage.attribute(.markdownConceal, at: c, effectiveRange: nil) != nil
            else { continue }
            var link = NSRange()
            guard storage.attribute(.markdownLink, at: c, effectiveRange: &link) != nil,
                  !touches(link, selection) else { continue }
            hidden[i] = .null
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: hidden, characterIndexes: charIndexes, font: aFont,
                                forGlyphRange: glyphRange)
        return count
    }
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let context = currentContext else { return }
        let ns = storage.string as NSString
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownRule, in: chars) { value, range, _ in
            // The marks alone, without spaces around them.
            let marks = ns.rangeOfCharacter(from: Self.markChars, range: range)
            let lastMark = ns.rangeOfCharacter(from: Self.markChars, options: .backwards, range: range)
            guard value != nil, marks.location != NSNotFound else { return }
            let first = glyphIndexForCharacter(at: marks.location)
            let last = glyphIndexForCharacter(at: lastMark.location)
            guard let container = textContainer(forGlyphAt: last, effectiveRange: nil) else { return }
            let line = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let span = boundingRect(forGlyphRange: NSRange(location: first, length: last - first + 1), in: container)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
            let size = font?.pointSize ?? 16
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.headIndent ?? 0

            // Level with the middle of the marks themselves, measured from the glyph.
            let baseline = line.minY + location(forGlyphAt: last).y
            var y = baseline - (font?.xHeight ?? size / 2) / 2
            if let font {
                var glyph = cgGlyph(at: last)
                var bounds = CGRect.zero
                CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyph, &bounds, 1)
                if !bounds.isEmpty { y = baseline - bounds.midY }
            }
            let gap = round(size * 0.6)
            ruleColor(at: range.location).setFill()
            for (from, to) in [(line.minX + indent, span.minX - gap), (span.maxX + gap, line.maxX)] where to > from {
                context.fill(CGRect(x: origin.x + from, y: origin.y + y - 0.5, width: to - from, height: 1))
            }
        }
    }

    private static let markChars = CharacterSet(charactersIn: "-*_")

    /// The task box under `point` (in container coordinates), give or take a little, so a
    /// finger needn't land on the brackets exactly.
    func taskBox(at point: CGPoint, in container: NSTextContainer) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForGlyph(at: glyphIndex(for: point, in: container))
        var box = NSRange()
        guard index < storage.length,
              storage.attribute(.markdownTaskBox, at: index, effectiveRange: &box) != nil else { return nil }
        let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: box, actualCharacterRange: nil), in: container)
        return rect.insetBy(dx: -6, dy: -2).contains(point) ? box : nil
    }

    /// The rule's color: the markup gray, or whatever focus dimming has made the text there.
    func ruleColor(at index: Int) -> PlatformColor {
        #if os(macOS)
        if let dimmed = temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor {
            return dimmed
        }
        #endif
        return Theme.markup
    }

    private var currentContext: CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }
}
