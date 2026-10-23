import SwiftUI

/// How to write each kind of formatting, for the button by the word count. The iPhone has its
/// Markdown toolbar for this; the Mac has only the page. A shortcut is listed only where
/// there's a familiar one in the Format menu; keep those in step with QuillCommands.
private struct Entry: Identifiable {
    let title: String
    /// The Markdown to type, if any.
    var markdown: String?
    var shortcut: String?
    /// Other words someone might search for it by.
    var also = ""

    var id: String { title }
}

private struct EntrySection: Identifiable {
    let title: String
    let entries: [Entry]

    var id: String { title }
}

private let sections = [
    EntrySection(title: "Text", entries: [
        Entry(title: "Bold", markdown: "**text**", shortcut: "⌘B", also: "strong heavy"),
        Entry(title: "Italic", markdown: "_text_", shortcut: "⌘I", also: "emphasis slanted"),
        Entry(title: "Strikethrough", markdown: "~~text~~", shortcut: "⇧⌘X", also: "cross out"),
        Entry(title: "Code", markdown: "`text`", shortcut: "⇧⌘C", also: "inline monospace backtick"),
        Entry(title: "Link", markdown: "[text](url)", shortcut: "⌘K", also: "web hyperlink"),
    ]),
    EntrySection(title: "Lines", entries: [
        Entry(title: "Heading", markdown: "# Heading", also: "title header h1"),
        Entry(title: "Smaller Heading", markdown: "## Heading", also: "subheading subtitle header h2 h3"),
        Entry(title: "Bulleted List", markdown: "- item", also: "bullet unordered dash"),
        Entry(title: "Numbered List", markdown: "1. item", also: "ordered"),
        Entry(title: "Task", markdown: "- [ ] task", also: "todo checkbox checklist tick done"),
        Entry(title: "Quote", markdown: "> quote", also: "blockquote citation"),
        Entry(title: "Divider", markdown: "---", also: "rule line separator horizontal"),
        Entry(title: "Code Block", markdown: "```", also: "fence monospace"),
    ]),
    EntrySection(title: "Links Between Notes", entries: [
        Entry(title: "Link to a Note", markdown: "[[Note]]", also: "wiki link wikilink backlink connect"),
        Entry(title: "Link to a Heading", markdown: "[[Note#Heading]]", also: "wiki link section anchor"),
        Entry(title: "Show Other Text", markdown: "[[Note|text]]", also: "wiki link alias label"),
        Entry(title: "Open a Link", shortcut: "⌘-click", also: "wiki link follow go jump"),
    ]),
]

/// The button by the word count; opens the cheat sheet above it.
struct CheatSheetButton: View {
    @EnvironmentObject var state: AppState
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "textformat")
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Markdown Cheat Sheet")
        .popover(isPresented: $showing, arrowEdge: .top) {
            CheatSheet()
        }
        // Back to writing once the sheet is put away.
        .onChange(of: showing) { if !$0 { state.focusEditor() } }
    }
}

private struct CheatSheet: View {
    @State private var query = ""
    @FocusState private var searching: Bool

    /// The sections with only the entries that hold every word typed.
    private var matches: [EntrySection] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter { entry in
                let haystack = [entry.title, entry.markdown ?? "", entry.also, section.title].joined(separator: " ").lowercased()
                return words.allSatisfy(haystack.contains)
            }
            return entries.isEmpty ? nil : EntrySection(title: section.title, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search, like “bold” or “list”", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
            }
            .appFont(14)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(12)

            Divider()

            let matches = matches
            if matches.isEmpty {
                Text("Nothing Matches")
                    .appFont(13)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(matches) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section.title)
                                    .appFont(11, bold: true)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                ForEach(section.entries) { EntryRow(entry: $0) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(width: 360, height: 440)
        .background(Color(nsColor: Theme.background))
        .onAppear { searching = true }
    }
}

private struct EntryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.title).appFont(13)
            Spacer(minLength: 12)
            if let markdown = entry.markdown {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: 4))
            }
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }
}
