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
