#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// On a `[[wikilink]]`, the note it names, as written.
    static let noteLink = NSAttributedString.Key("QuillNoteLink")
}

/// Styles Markdown in place, iA-style: markup characters are greyed out but stay visible,
/// headings stay the body size and hang their `#`s into the left margin. Links are the
/// exception: their markup is marked for MarkdownLayoutManager to hide until the caret comes.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var fonts = FontSet(.sans, size: Fonts.defaultSize) { didSet { rebuildBase() } }
    /// Off where the screen is too narrow to give up a margin to heading marks.
    var hangsHeadings = true { didSet { rebuildBase() } }
    /// Whether a `[[link]]`'s note exists; links to notes not yet written are drawn fainter,
    /// as in Obsidian.
    var linkExists: ((String) -> Bool)?
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var baseParagraph = NSParagraphStyle()
    private var codeAttributes: [NSAttributedString.Key: Any] = [:]
    private var fenceCount = -1

    override init() {
        super.init()
        rebuildBase()
    }

    private var hang: CGFloat { hangsHeadings ? fonts.hang : 0 }

    private func rebuildBase() {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = round(fonts.size * 0.55)
        p.firstLineHeadIndent = hang
        p.headIndent = hang
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

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: TextEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        let ns = storage.string as NSString
        let fences = fenceLines(storage.string)
        var target = ns.paragraphRange(for: range)
        // The lines on either side too: an underline (`===`, `---`) makes the line above
        // it a heading.
        if NSMaxRange(target) < ns.length {
            target = NSUnionRange(target, ns.paragraphRange(for: NSRange(location: NSMaxRange(target), length: 0)))
        }
        if target.location > 0 {
            target = NSUnionRange(target, ns.paragraphRange(for: NSRange(location: target.location - 1, length: 0)))
        }
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
    private static let underline = re(#"^[ \t]{0,3}(?:=+|-{2,})[ \t]*$"#, .anchorsMatchLines)
    private static let taskBox = re(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\])[ \t]"#, .anchorsMatchLines)
    private static let checkedTask = re(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[[xX]\][ \t]+(.*)$"#, .anchorsMatchLines)
    // Not `****`, though: that's Bold pressed with nothing selected, waiting for its text.
    private static let rule = re(#"^[ \t]{0,3}(?!\*{4}[ \t]*$)([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    private static let fence = re(#"^[ \t]{0,3}(?:```|~~~).*$"#, .anchorsMatchLines)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    // Each marker may touch the other kind, so bold and italic nest: `**_both_**`, `_**both**_`.
    private static let italic = re(#"(?<![*\w])(\*)(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])|(?<!\w)(_)(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)"#)
    private static let boldItalic = re(#"(?<![*_\w])(\*\*\*|___)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
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
            paragraph({ $0.firstLineHeadIndent = max(0, hang - markWidth) }, m.range)
        }
        each(Self.listMarker) { m in
            dim(m.range)
            let markerWidth = fonts.width(ns.substring(with: m.range))
            paragraph({ $0.headIndent = hang + markerWidth }, m.range)
        }
        each(Self.taskBox) { m in ts.addAttribute(.markdownTaskBox, value: true, range: m.range(at: 1)) }
        each(Self.quote) { m in
            dim(m.range(at: 1))
            addTraits(ts, m.range(at: 2), italic: true)
        }
        each(Self.underline) { m in
            guard let above = paragraphAbove(m.range, ns) else { return }
            ts.addAttribute(.font, value: fonts.bold, range: above)
            dim(m.range)
        }
        each(Self.rule) { m in
            dim(m.range)
            let underlines = ns.substring(with: m.range(at: 1)) == "-" && paragraphAbove(m.range, ns) != nil
            if !underlines {
                ts.addAttribute(.markdownRule, value: true, range: m.range)
                paragraph({ $0.alignment = .center }, m.range)
            }
        }
        each(Self.bold) { m in
            addTraits(ts, m.range(at: 2), bold: true)
            dimMarkers(m, dim)
        }
        each(Self.italic) { m in
            // Whichever of the two alternatives matched: `*` in groups 1–2, `_` in 3–4.
            let text = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 4)
            addTraits(ts, text, italic: true)
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(Self.boldItalic) { m in
            addTraits(ts, m.range(at: 2), bold: true, italic: true)
            dimMarkers(m, dim)
        }
        each(Self.strike) { m in
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            dimMarkers(m, dim)
        }
        each(Self.link) { m in
            dim(m.range)
            let text = m.range(at: 1)
            ts.addAttribute(.foregroundColor, value: Theme.text, range: text)
            // Out of the way until the caret comes to it, leaving the text underlined.
            // An image, or a link with no text, has nothing to show in its place.
            guard text.length > 0, ns.character(at: m.range.location) != 0x21 else { return }
            ts.addAttribute(.markdownLink, value: m.range.location, range: m.range)
            ts.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Theme.markup],
                             range: text)
            ts.addAttribute(.markdownConceal, value: true, range: NSRange(location: m.range.location, length: 1))
            ts.addAttribute(.markdownConceal, value: true,
                            range: NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)))
        }
        each(LinkResolver.wikiLink) { m in
            dim(m.range)
            let target = ns.substring(with: m.range(at: 1))
            let alias = m.range(at: 2)
            let shown = alias.location != NSNotFound && alias.length > 0 ? alias : m.range(at: 1)
            let written = linkExists?(target) ?? true
            ts.addAttribute(.foregroundColor, value: written ? Theme.link : Theme.unwritten, range: shown)
            ts.addAttribute(.noteLink, value: target, range: m.range)
            // Everything around the shown text is out of the way until the caret comes to it,
            // as with other links (and as Obsidian does): `[[Note|these words]]` reads "these words".
            ts.addAttribute(.markdownLink, value: m.range.location, range: m.range)
            ts.addAttribute(.markdownConceal, value: true,
                            range: NSRange(location: m.range.location, length: shown.location - m.range.location))
            ts.addAttribute(.markdownConceal, value: true,
                            range: NSRange(location: NSMaxRange(shown), length: NSMaxRange(m.range) - NSMaxRange(shown)))
        }
        each(Self.code) { m in
            // A link written in code is only text.
            for key in [NSAttributedString.Key.markdownLink, .markdownConceal, .underlineStyle, .noteLink] {
                ts.removeAttribute(key, range: m.range)
            }
            ts.addAttributes(codeAttributes, range: m.range)
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        // Done items fade back and are struck through, links and code included.
        each(Self.checkedTask) { m in
            dim(m.range)
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
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
        #if os(macOS)
        // Restore fallback fonts for characters the editor font lacks (e.g. ⌘, emoji).
        // (UIKit falls back at draw time.)
        ts.fixAttributes(in: range)
        #endif
    }

    /// The line above `range` if it's plain text, which an underline (`===`, `---`) beneath
    /// turns into a heading. Excludes the newline.
    private func paragraphAbove(_ range: NSRange, _ ns: NSString) -> NSRange? {
        guard range.location > 0 else { return nil }
        let above = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
        let line = ns.substring(with: above)
        let text = line.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let all = NSRange(location: 0, length: (line as NSString).length)
        guard [Self.heading, Self.listMarker, Self.quote, Self.rule, Self.underline, Self.fence]
            .allSatisfy({ $0.firstMatch(in: line, range: all) == nil }) else { return nil }
        return NSRange(location: above.location, length: (text as NSString).length)
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
            let f = value as? PlatformFont ?? fonts.regular
            let isBold = bold || f == fonts.bold || f == fonts.boldItalic
            let isItalic = italic || f == fonts.italic || f == fonts.boldItalic
            ts.addAttribute(.font, value: fonts.variant(bold: isBold, italic: isItalic), range: sub)
        }
    }
}
