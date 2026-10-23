import Foundation

/// The notes offered while a `[[link]]` is typed, as in Obsidian: a short list that narrows
/// with each letter. Up and down move through it, Return or Tab takes a note, Escape closes it.
final class LinkSuggester {
    struct Item: Equatable {
        /// What goes between the brackets.
        let link: String
        let name: String
        /// The folder it's in, from the library; empty at the top.
        let folder: String
    }

    private(set) var items: [Item] = []
    private(set) var selected = 0
    /// The name typed so far.
    private(set) var query: NSRange?
    /// Escape shuts the list for the link it was in until the caret leaves that link.
    private var dismissedAt: Int?

    var isShowing: Bool { !items.isEmpty }

    func update(text: String, caret: NSRange, resolver: LinkResolver?) {
        guard caret.length == 0, let resolver,
              let query = MarkdownEdits.linkQuery(in: text, caret: caret.location) else { return close() }
        self.query = query
        guard dismissedAt != query.location else {
            items = []
            return
        }
        dismissedAt = nil
        let typed = (text as NSString).substring(with: query)
        let fresh = resolver.suggestions(for: typed).map { url in
            let folder = LinkResolver.relativePath(url.deletingLastPathComponent(), from: resolver.root)
            return Item(link: resolver.linkText(for: url), name: FileNode.displayName(url),
                        folder: folder.hasPrefix("..") ? "" : folder)
        }
        if fresh != items {
            items = fresh
            selected = 0
        }
    }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + step + items.count) % items.count
    }

    func dismiss() {
        dismissedAt = query?.location
        items = []
    }

    /// The edit that takes the note at `index` (the selected one by default) into the link.
    func choose(_ index: Int? = nil, in text: String) -> TextEdit? {
        let i = index ?? selected
        guard let query, items.indices.contains(i) else { return nil }
        let link = items[i].link
        close()
        return MarkdownEdits.completeLink(link, in: text, query: query)
    }

    private func close() {
        items = []
        query = nil
        dismissedAt = nil
    }
}
