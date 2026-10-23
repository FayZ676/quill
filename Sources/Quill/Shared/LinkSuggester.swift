import SwiftUI

/// The notes offered while a `[[link]]` is typed, as in Obsidian: a short list that narrows
/// with each letter. Up and down move through it, Return or Tab takes a note, Escape closes it.
final class LinkSuggester {
    struct Item: Equatable {
        let url: URL
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
            return Item(url: url, link: resolver.linkText(for: url), name: FileNode.displayName(url),
                        folder: folder.isEmpty || folder.hasPrefix("..") ? "" : folder)
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

/// The suggestions as a small floating list under the link being typed.
struct LinkSuggestionList: View {
    let items: [LinkSuggester.Item]
    let selected: Int
    let font: EditorFont
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 12) {
                    Text(item.name)
                        .font(.quill(font, size: 13))
                        .foregroundStyle(Color(platform: Theme.text))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !item.folder.isEmpty {
                        Text(item.folder)
                            .font(.quill(font, size: 11))
                            .foregroundStyle(Color(platform: Theme.markup))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(i == selected ? Color(platform: Theme.accent).opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { pick(i) }
            }
        }
        .padding(4)
        .frame(width: 300, alignment: .leading)
        .background(Color(platform: Theme.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(platform: Theme.markup).opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(12)
    }

    /// Height of the list for `count` items, its margin for the shadow included.
    static func height(for count: Int) -> CGFloat { CGFloat(count) * 26 + 8 + 24 }
    static let width: CGFloat = 300 + 24
}
