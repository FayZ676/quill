import Foundation

/// Finding a document or folder by typing part of its path, as Obsidian does.
enum PathMatch {
    /// Where `url` sits under `root`, as a path: "journal/2025", or "/" for `root` itself.
    /// A document leaves off its Markdown extension, as the library names it.
    static func path(of url: URL, in root: URL) -> String {
        let base = root.standardizedFileURL.path, full = url.standardizedFileURL.path
        guard full != base else { return "/" }
        let path = String(full.dropFirst(base.count + 1))
        guard !url.hasDirectoryPath, FileNode.markdownExtensions.contains(url.pathExtension.lowercased()) else { return path }
        return String(path.dropLast(url.pathExtension.count + 1))
    }

    /// The items that match `query`: those whose path holds it as typed first, then those
    /// holding its letters in order (“jo25” finds journal/2025). All of them, for nothing typed.
    static func filter(_ items: [(url: URL, path: String)], by query: String) -> [(url: URL, path: String)] {
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return items }
        let exact = items.filter { $0.path.lowercased().contains(typed) }
        let loose = items.filter { !$0.path.lowercased().contains(typed) && inOrder(typed, in: $0.path.lowercased()) }
        return exact + loose
    }

    private static func inOrder(_ letters: String, in text: String) -> Bool {
        var rest = Substring(letters)
        for c in text where c == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }
}
