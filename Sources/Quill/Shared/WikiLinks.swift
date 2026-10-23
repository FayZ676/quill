import Foundation

/// The library's notes by name, for following `[[links]]` the way Obsidian does: `[[Name]]`
/// matches a note of that name anywhere in the library, the nearest one if there are
/// several; `[[Folder/Name]]` and relative Markdown links (`[text](Other.md)`) match by path.
struct LinkResolver {
    let root: URL
    let notes: [URL]
    private let byName: [String: [URL]]

    init(_ tree: [FileNode], root: URL) {
        func walk(_ nodes: [FileNode]) -> [URL] {
            nodes.flatMap { $0.isDirectory ? walk($0.children ?? []) : [$0.url] }
        }
        self.root = root
        notes = walk(tree)
        byName = Dictionary(grouping: notes) { FileNode.displayName($0).lowercased() }
    }

    /// The note `target` names, as written in a link in `source`.
    func resolve(_ target: String, from source: URL?) -> URL? {
        let name = Self.split(target).name
        guard !name.isEmpty else { return nil }

        if name.contains("/") || FileNode.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let base = name.hasPrefix("/") ? root : (source?.deletingLastPathComponent() ?? root)
            let direct = base.appendingPathComponent(name).standardizedFileURL
            let fromRoot = root.appendingPathComponent(name).standardizedFileURL
            for candidate in [direct, direct.appendingPathExtension("md"), fromRoot, fromRoot.appendingPathExtension("md")] {
                if let match = notes.first(where: { $0.standardizedFileURL.path == candidate.path }) { return match }
            }
        }
        let leaf = FileNode.displayName(URL(fileURLWithPath: name)).lowercased()
        guard let matches = byName[leaf], !matches.isEmpty else { return nil }
        // Several notes of one name: the one closest to the linking note, else the first.
        guard let source, matches.count > 1 else { return matches.first }
        let here = source.deletingLastPathComponent().pathComponents
        var best = matches[0]
        for match in matches.dropFirst() where shared(here, match) > shared(here, best) { best = match }
        return best
    }

    private func shared(_ a: [String], _ b: URL) -> Int {
        zip(a, b.deletingLastPathComponent().pathComponents).prefix { $0 == $1 }.count
    }

    /// How a link to `note` is written: its name, or, when another note shares the name,
    /// its path from the library, as Obsidian writes them.
    func linkText(for note: URL) -> String {
        let name = FileNode.displayName(note)
        guard (byName[name.lowercased()]?.count ?? 0) > 1 else { return name }
        return (Self.relativePath(note, from: root) as NSString).deletingPathExtension
    }

    // MARK: Suggestions

    /// Notes for a `[[link]]` being typed, best match first: names starting with `query`,
    /// then with a word starting with it, then containing it, then holding its letters in order.
    func suggestions(for query: String, limit: Int = 8) -> [URL] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        func rank(_ url: URL) -> Int? {
            let name = FileNode.displayName(url).lowercased()
            if q.isEmpty || name.hasPrefix(q) { return 0 }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 1 }
            if name.contains(q) { return 2 }
            var rest = Substring(q)
            for c in name where c == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty ? 3 : nil
        }
        return notes.compactMap { url in rank(url).map { (url, $0) } }
            .sorted { a, b in
                a.1 != b.1 ? a.1 < b.1
                    : FileNode.displayName(a.0).localizedStandardCompare(FileNode.displayName(b.0)) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: Moves

    /// The text of a note once notes have moved, with every link to a moved note, and every
    /// relative link from this note if it moved itself, pointing at where things are now.
    /// The resolver is the library from before the move; `moves` maps old note URLs to new.
    func rewrite(_ text: String, of oldSource: URL, movedTo newSource: URL, moves: [URL: URL]) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let code = Self.codeSpan.matches(in: text, range: all).map(\.range)
        func inCode(_ r: NSRange) -> Bool { code.contains { NSIntersectionRange($0, r).length > 0 } }
        var edits: [(NSRange, String)] = []

        for m in Self.wikiLink.matches(in: text, range: all) where !inCode(m.range) {
            let targetRange = m.range(at: 1)
            let (name, suffix) = Self.split(ns.substring(with: targetRange))
            guard let old = resolve(name, from: oldSource), let new = moves[old] else { continue }
            var written: String
            if name.contains("/") {
                written = (Self.relativePath(new, from: root) as NSString).deletingPathExtension
            } else {
                written = FileNode.displayName(new)
            }
            if !(name as NSString).pathExtension.isEmpty { written += "." + new.pathExtension }
            edits.append((targetRange, written + suffix))
        }
        for m in Self.markdownLink.matches(in: text, range: all) where !inCode(m.range) {
            let destRange = m.range(at: 1)
            let dest = ns.substring(with: destRange)
            guard let path = Self.localPath(dest), let old = resolve(path, from: oldSource) else { continue }
            let new = moves[old] ?? old
            guard new != old || newSource != oldSource else { continue }
            var written = Self.relativePath(new, from: newSource.deletingLastPathComponent())
            // Spaces as the link was written: encoded, or left bare if they were.
            if dest.contains("%") || (written.contains(" ") && !dest.contains(" ")) {
                written = written.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? written
            }
            if let hash = dest.firstIndex(of: "#") { written += dest[hash...] }
            edits.append((destRange, written))
        }

        guard !edits.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out as String
    }

    // MARK: Parsing

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `[[Target]]`, `[[Target|Shown]]` and `![[Embed]]`. Group 1 is the target, group 2
    /// the text shown in its place, if any.
    static let wikiLink = re(#"!?\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]*))?\]\]"#)
    /// Group 1 is the destination.
    static let markdownLink = re(#"\[[^\]\n]*\]\(<?([^)>\n]+?)>?(?:\s+"[^"\n]*")?\)"#)
    private static let codeSpan = re(#"^[ \t]{0,3}(```|~~~).*?(?:^[ \t]{0,3}\1[^\n]*$|\z)|`[^`\n]+`"#,
                                     [.anchorsMatchLines, .dotMatchesLineSeparators])

    /// A link's target split into the note's name and the heading or block after it
    /// (`Note#Part`, `Note^id`), which still mean the note.
    static func split(_ target: String) -> (name: String, suffix: String) {
        guard let cut = target.firstIndex(where: { $0 == "#" || $0 == "^" }) else {
            return (target.trimmingCharacters(in: .whitespaces), "")
        }
        return (target[..<cut].trimmingCharacters(in: .whitespaces), String(target[cut...]))
    }

    /// The heading a link's target points into, if any: "Part" for `Note#Part`.
    static func heading(in target: String) -> String? {
        let suffix = split(target).suffix
        guard suffix.hasPrefix("#") else { return nil }
        let heading = suffix.dropFirst().trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// The note path in a Markdown link's destination, if it points at a note rather than
    /// the web: decoded, without any `#part`.
    private static func localPath(_ dest: String) -> String? {
        guard !dest.contains(":"), let decoded = dest.removingPercentEncoding,
              let path = decoded.split(separator: "#", maxSplits: 1).first.map(String.init),
              FileNode.markdownExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return path
    }

    /// What each link in `text` points at, as written, leaving out code and web links.
    static func targets(in text: String) -> [String] {
        let ns = text as NSString
        let plain = codeSpan.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: "")
        let range = NSRange(location: 0, length: (plain as NSString).length)
        func captures(_ regex: NSRegularExpression) -> [String] {
            regex.matches(in: plain, range: range).map { (plain as NSString).substring(with: $0.range(at: 1)) }
        }
        return captures(wikiLink) + captures(markdownLink).compactMap(localPath)
    }

    /// The line of the heading called `name` in `text`, ignoring case, for opening a
    /// `[[Note#Heading]]` link at it.
    static func headingRange(_ name: String, in text: String) -> NSRange? {
        let pattern = #"^#{1,6}[ \t]+"# + NSRegularExpression.escapedPattern(for: name) + #"[ \t#]*$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
        return regex?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
    }

    /// `url`'s path from the folder `base`, with `..` steps where it lies outside it.
    static func relativePath(_ url: URL, from base: URL) -> String {
        let to = url.standardizedFileURL.pathComponents
        let from = base.standardizedFileURL.pathComponents
        let common = zip(to, from).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }
}
