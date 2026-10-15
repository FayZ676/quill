import AppKit

/// Styles Markdown in place, iA-style: markup characters are greyed out but stay visible,
/// headings stay the body size and hang their `#`s into the left margin.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var fonts = FontSet(.duo, size: AppState.defaultFontSize) { didSet { rebuildBase() } }
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var baseParagraph = NSParagraphStyle()
    private var codeAttributes: [NSAttributedString.Key: Any] = [:]
    private var fenceCount = -1

    override init() {
        super.init()
        rebuildBase()
    }

    private func rebuildBase() {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = round(fonts.size * 0.55)
        p.firstLineHeadIndent = fonts.hang
        p.headIndent = fonts.hang
        baseParagraph = p
        baseAttributes = [.font: fonts.regular, .foregroundColor: Theme.text, .paragraphStyle: p]
        codeAttributes = baseAttributes.merging([.backgroundColor: Theme.codeBackground]) { $1 }
    }

    func highlightAll(_ storage: NSTextStorage) {
        let fences = fenceLines(storage.string)
        fenceCount = fences.count
        storage.beginEditing()
        apply(storage, in: NSRange(location: 0, length: storage.length), fences: fences)
        storage.endEditing()
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        let ns = storage.string as NSString
        let fences = fenceLines(storage.string)
        var target = ns.paragraphRange(for: range)
        // Opening or closing a code fence restyles everything after it.
        let edited = ns.substring(with: target)
        if fences.count != fenceCount || edited.contains("```") || edited.contains("~~~") {
            target = NSRange(location: 0, length: ns.length)
        }
        fenceCount = fences.count
        apply(storage, in: target, fences: fences)
    }

    // MARK: Styling

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = re(#"^(#{1,6}[ \t]+)(.*)$"#, .anchorsMatchLines)
    private static let listMarker = re(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#, .anchorsMatchLines)
    private static let quote = re(#"^([ \t]*>[ \t]?)(.*)$"#, .anchorsMatchLines)
    private static let rule = re(#"^[ \t]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    private static let fence = re(#"^[ \t]{0,3}(?:```|~~~).*$"#, .anchorsMatchLines)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = re(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let strike = re(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = re(#"`[^`\n]+`"#)
    private static let link = re(#"!?\[([^\]\n]*)\]\([^)\n]*\)"#)

    private func fenceLines(_ s: String) -> [NSRange] {
        Self.fence.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    private func apply(_ ts: NSTextStorage, in range: NSRange, fences: [NSRange]) {
        guard range.length > 0 else { return }
        let s = ts.string
        let ns = s as NSString
        ts.setAttributes(baseAttributes, range: range)

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: s, range: range) { m, _, _ in if let m { body(m) } }
        }
        func dim(_ r: NSRange) { ts.addAttribute(.foregroundColor, value: Theme.markup, range: r) }
        func paragraph(_ edit: (NSMutableParagraphStyle) -> Void, _ r: NSRange) {
            let p = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            edit(p)
            ts.addAttribute(.paragraphStyle, value: p, range: r)
        }

        each(Self.heading) { m in
            let marks = m.range(at: 1)
            ts.addAttribute(.font, value: fonts.bold, range: m.range)
            dim(marks)
            let markWidth = fonts.width(ns.substring(with: marks), font: fonts.bold)
            paragraph({ $0.firstLineHeadIndent = max(0, fonts.hang - markWidth) }, m.range)
        }
        each(Self.listMarker) { m in
            dim(m.range)
            let markerWidth = fonts.width(ns.substring(with: m.range))
            paragraph({ $0.headIndent = fonts.hang + markerWidth }, m.range)
        }
        each(Self.quote) { m in
            dim(m.range(at: 1))
            addTraits(ts, m.range(at: 2), italic: true)
        }
        each(Self.rule) { m in dim(m.range) }
        each(Self.bold) { m in
            addTraits(ts, m.range(at: 2), bold: true)
            dimMarkers(m, dim)
        }
        each(Self.italic) { m in
            addTraits(ts, m.range(at: 2), italic: true)
            dimMarkers(m, dim)
        }
        each(Self.strike) { m in
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            dimMarkers(m, dim)
        }
        each(Self.link) { m in
            dim(m.range)
            ts.addAttribute(.foregroundColor, value: Theme.text, range: m.range(at: 1))
        }
        each(Self.code) { m in
            ts.addAttributes(codeAttributes, range: m.range)
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        // Fenced blocks win over everything matched inside them.
        var i = 0
        while i < fences.count {
            let open = fences[i]
            let end = i + 1 < fences.count ? NSMaxRange(fences[i + 1]) : ns.length
            let block = NSRange(location: open.location, length: end - open.location)
            let r = NSIntersectionRange(block, range)
            if r.length > 0 {
                ts.setAttributes(codeAttributes, range: r)
                for f in [open] + (i + 1 < fences.count ? [fences[i + 1]] : []) {
                    let fr = NSIntersectionRange(f, range)
                    if fr.length > 0 { dim(fr) }
                }
            }
            i += 2
        }
        // Restore fallback fonts for characters the editor font lacks (e.g. ⌘, emoji).
        ts.fixAttributes(in: range)
    }

    /// Dims the opening and closing marker (capture group 1) of an inline span.
    private func dimMarkers(_ m: NSTextCheckingResult, _ dim: (NSRange) -> Void) {
        let len = m.range(at: 1).length
        dim(NSRange(location: m.range.location, length: len))
        dim(NSRange(location: NSMaxRange(m.range) - len, length: len))
    }

    /// Adds bold/italic on top of whatever face a range already has (e.g. italic inside a heading).
    private func addTraits(_ ts: NSTextStorage, _ range: NSRange, bold: Bool = false, italic: Bool = false) {
        guard range.length > 0 else { return }
        ts.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = value as? NSFont ?? fonts.regular
            let isBold = bold || f == fonts.bold || f == fonts.boldItalic
            let isItalic = italic || f == fonts.italic || f == fonts.boldItalic
            ts.addAttribute(.font, value: fonts.variant(bold: isBold, italic: isItalic), range: sub)
        }
    }
}
