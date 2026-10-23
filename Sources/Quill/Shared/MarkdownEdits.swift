import Foundation

/// One replacement for a text view to make, and where the selection lands afterwards
/// (nil: wherever typing the replacement leaves it).
struct TextEdit {
    let range: NSRange
    let text: String
    var selection: NSRange?
}

/// Markdown-aware editing commands, as pure functions of the text and the selection so
/// each platform's text view applies them its own way (with undo).
enum MarkdownEdits {
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))[ \t]+(\[[ xX]\][ \t]+)?|^([ \t]*>[ \t]?)"#)
    private static let headingPrefix = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    private static let bulletPrefix = try! NSRegularExpression(pattern: #"^[ \t]*[-*+][ \t]+"#)

    /// Return inside a list or quote: continues it, or ends it on an empty item.
    /// Nil means an ordinary newline.
    static func newline(in string: String, selection sel: NSRange) -> TextEdit? {
        let ns = string as NSString
        let (lineRange, line) = self.line(in: ns, at: sel.location)

        guard sel.length == 0,
              let m = listPrefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              sel.location >= lineRange.location + m.range.length
        else { return nil }

        if m.range.length == line.length {
            return TextEdit(range: NSRange(location: lineRange.location, length: m.range.length), text: "")
        }

        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : line.substring(with: r)
        }
        let next: String
        if let quote = group(6) {
            next = quote
        } else {
            let marker = group(2) ?? "\((Int(group(3) ?? "") ?? 0) + 1)\(group(4) ?? ".")"
            next = (group(1) ?? "") + marker + " " + (group(5) != nil ? "[ ] " : "")
        }
        return TextEdit(range: sel, text: "\n" + next)
    }

    /// Wraps the selection in `marker`, or unwraps it if it is already wrapped.
    static func toggleWrap(_ marker: String, in string: String, selection sel: NSRange) -> TextEdit {
        let ns = string as NSString
        let m = (marker as NSString).length
        let inner = ns.substring(with: sel)

        if sel.length >= 2 * m, inner.hasPrefix(marker), inner.hasSuffix(marker) {
            let unwrapped = (inner as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return TextEdit(range: sel, text: unwrapped,
                            selection: NSRange(location: sel.location, length: sel.length - 2 * m))
        } else if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
                  ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            return TextEdit(range: NSRange(location: sel.location - m, length: sel.length + 2 * m), text: inner,
                            selection: NSRange(location: sel.location - m, length: sel.length))
        } else {
            return TextEdit(range: sel, text: marker + inner + marker,
                            selection: NSRange(location: sel.location + m, length: sel.length))
        }
    }

    static func link(in string: String, selection sel: NSRange) -> TextEdit {
        let text = (string as NSString).substring(with: sel)
        let caret = text.isEmpty ? sel.location + 1 : sel.location + (text as NSString).length + 3
        return TextEdit(range: sel, text: "[\(text)]()", selection: NSRange(location: caret, length: 0))
    }

    // MARK: Wikilinks

    /// Brackets typed around a `[[link]]`, as Obsidian handles them: a second `[` closes the
    /// link (`[[|]]`), and `]` in front of a closing bracket steps over it. Nil means type
    /// the character as usual.
    static func bracket(_ typed: String, in string: String, selection sel: NSRange) -> TextEdit? {
        guard sel.length == 0 else { return nil }
        let ns = string as NSString
        func char(_ i: Int) -> unichar? { i >= 0 && i < ns.length ? ns.character(at: i) : nil }
        let open: unichar = 91, close: unichar = 93
        if typed == "[", char(sel.location - 1) == open {
            // However many of the closing pair are already there.
            let closing = char(sel.location) == close ? (char(sel.location + 1) == close ? 2 : 1) : 0
            return TextEdit(range: sel, text: "[" + String(repeating: "]", count: 2 - closing),
                            selection: NSRange(location: sel.location + 1, length: 0))
        }
        if typed == "]", char(sel.location) == close, openLink(in: ns, before: sel.location) != nil {
            return TextEdit(range: NSRange(location: sel.location, length: 0), text: "",
                            selection: NSRange(location: sel.location + 1, length: 0))
        }
        return nil
    }

    /// Backspace between a pair of brackets takes out both, so `[[|]]` steps back to `[|]`
    /// and then to nothing. Nil means delete as usual.
    static func backspace(in string: String, selection sel: NSRange) -> TextEdit? {
        let ns = string as NSString
        guard sel.length == 0, sel.location > 0, sel.location < ns.length,
              ns.character(at: sel.location - 1) == 91, ns.character(at: sel.location) == 93 else { return nil }
        return TextEdit(range: NSRange(location: sel.location - 1, length: 2), text: "")
    }

    /// The name typed so far in a `[[link]]` the caret is in: from just after `[[` to the
    /// caret. Nil once the name is followed by a heading (`#`) or shown text (`|`), or
    /// outside a link.
    static func linkQuery(in string: String, caret: Int) -> NSRange? {
        let ns = string as NSString
        guard let start = openLink(in: ns, before: caret) else { return nil }
        let query = NSRange(location: start, length: caret - start)
        guard ns.rangeOfCharacter(from: afterName, range: query).location == NSNotFound else { return nil }
        return query
    }

    /// What ends a link's note name: a heading, a block, or the text shown in its place.
    private static let afterName = CharacterSet(charactersIn: "|#^")

    /// Puts `link` in place of the name being typed (`query`, from `linkQuery`), closes the
    /// link if it isn't yet, and leaves the caret after it.
    static func completeLink(_ link: String, in string: String, query: NSRange) -> TextEdit {
        let ns = string as NSString
        // Whatever of the old name runs on past the caret goes too, up to the link's end.
        var end = NSMaxRange(query)
        while end < ns.length, !"]|#^\n[".utf16.contains(ns.character(at: end)) { end += 1 }
        let range = NSRange(location: query.location, length: end - query.location)
        let closed = end + 1 < ns.length && ns.substring(with: NSRange(location: end, length: 2)) == "]]"
        let length = (link as NSString).length
        if closed {
            return TextEdit(range: range, text: link, selection: NSRange(location: query.location + length + 2, length: 0))
        }
        let atEnd = end >= ns.length || ns.character(at: end) == 10
        let text = atEnd ? link + "]]" : link
        return TextEdit(range: range, text: text,
                        selection: NSRange(location: query.location + (text as NSString).length, length: 0))
    }

    /// Where the name starts in a `[[` opened before `caret` on its line and not yet closed.
    private static func openLink(in ns: NSString, before caret: Int) -> Int? {
        guard caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = NSRange(location: lineStart, length: caret - lineStart)
        let open = ns.range(of: "[[", options: .backwards, range: before)
        guard open.location != NSNotFound else { return nil }
        let start = NSMaxRange(open)
        let inside = NSRange(location: start, length: caret - start)
        guard ns.range(of: "]]", range: inside).location == NSNotFound else { return nil }
        return start
    }

    /// Steps the caret's line through # → ## → ### → plain text.
    static func cycleHeading(in string: String, selection sel: NSRange) -> TextEdit {
        let ns = string as NSString
        let (lineRange, line) = self.line(in: ns, at: sel.location)
        let existing = headingPrefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        let old = existing.map { line.substring(with: $0.range) } ?? ""
        let level = old.filter { $0 == "#" }.count
        let new = level >= 3 ? "" : String(repeating: "#", count: level + 1) + " "
        return replacingPrefix(old, with: new, at: lineRange.location, selection: sel)
    }

    /// Turns the caret's line into a bullet, or back into plain text.
    static func toggleBullet(in string: String, selection sel: NSRange) -> TextEdit {
        let ns = string as NSString
        let (lineRange, line) = self.line(in: ns, at: sel.location)
        let existing = bulletPrefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        let old = existing.map { line.substring(with: $0.range) } ?? ""
        return replacingPrefix(old, with: old.isEmpty ? "- " : "", at: lineRange.location, selection: sel)
    }

    /// Swaps a line's leading marker, keeping the caret on the same text.
    private static func replacingPrefix(_ old: String, with new: String, at start: Int, selection sel: NSRange) -> TextEdit {
        let oldLength = (old as NSString).length
        let delta = (new as NSString).length - oldLength
        let location = sel.location >= start + oldLength ? sel.location + delta : start + (new as NSString).length
        return TextEdit(range: NSRange(location: start, length: oldLength), text: new,
                        selection: NSRange(location: location, length: sel.length))
    }

    /// The line holding `location`, without its newline.
    private static func line(in ns: NSString, at location: Int) -> (range: NSRange, text: NSString) {
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let range = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
        return (range, ns.substring(with: range) as NSString)
    }
}
