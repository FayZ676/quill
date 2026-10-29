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
    /// The heading it's listed under.
    var section = ""

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

/// Every entry, under its heading.
private let entries = sections.flatMap { section in
    section.entries.map { entry in
        var entry = entry
        entry.section = section.title
        return entry
    }
}

/// The button by the word count; opens the cheat sheet.
struct CheatSheetButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.showingCheatSheet = true } label: {
            Image(systemName: "textformat")
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 18)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .foregroundStyle(Color.accentColor)
        .help("Markdown Cheat Sheet")
        // Back to writing once the sheet is put away.
        .onChange(of: state.showingCheatSheet) { if !$0 { state.focusEditor() } }
    }
}

/// How to write each kind of formatting, searchable.
struct CheatSheet: View {
    var body: some View {
        SearchPanel(prompt: "Search, like “bold” or “list”", matches: matches, section: \.section) {
            EntryRow(entry: $0)
        }
    }

    /// The entries that hold every word typed.
    private func matches(_ query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ")
        return entries.filter { entry in
            let haystack = [entry.title, entry.markdown ?? "", entry.also, entry.section].joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }
}

private struct EntryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.title).appFont(14)
            Spacer(minLength: 12)
            if let markdown = entry.markdown {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: 4))
            }
            // Held open when empty, so the Markdown lines up down the sheet.
            Text(entry.shortcut ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }
}
