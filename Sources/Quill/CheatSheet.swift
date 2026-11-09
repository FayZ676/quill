import SwiftUI

/// Every shortcut, and how to write each kind of formatting, for the button in the bar at the bottom
/// and ⌘/. The iPhone has its Markdown toolbar for this; the Mac has only the page. The
/// shortcuts come from `Shortcuts`, as the menus' do.
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
    EntrySection(title: "Writing", entries: [
        Entry(title: "Bold", markdown: "**text**", shortcut: Shortcuts.bold.label, also: "strong heavy format"),
        Entry(title: "Italic", markdown: "_text_", shortcut: Shortcuts.italic.label, also: "emphasis slanted format"),
        Entry(title: "Strikethrough", markdown: "~~text~~", shortcut: Shortcuts.strikethrough.label, also: "cross out format"),
        Entry(title: "Code", markdown: "`text`", shortcut: Shortcuts.code.label, also: "inline monospace backtick format"),
        Entry(title: "Link", markdown: "[text](url)", shortcut: Shortcuts.link.label, also: "web hyperlink"),
        Entry(title: "Open a Link", shortcut: "⌘-click", also: "wiki link follow go jump"),
    ]),
    EntrySection(title: "Markdown", entries: [
        Entry(title: "Heading", markdown: "# Heading", also: "title header h1"),
        Entry(title: "Smaller Heading", markdown: "## Heading", also: "subheading subtitle header h2 h3"),
        Entry(title: "Bulleted List", markdown: "- item", also: "bullet unordered dash"),
        Entry(title: "Numbered List", markdown: "1. item", also: "ordered"),
        Entry(title: "Task", markdown: "- [ ] task", also: "todo checkbox checklist tick done"),
        Entry(title: "Quote", markdown: "> quote", also: "blockquote citation"),
        Entry(title: "Divider", markdown: "---", also: "rule line separator horizontal"),
        Entry(title: "Code Block", markdown: "```", also: "fence monospace"),
        Entry(title: "Link to a Note", markdown: "[[Note]]", also: "wiki link wikilink backlink connect"),
        Entry(title: "Link to a Heading", markdown: "[[Note#Heading]]", also: "wiki link section anchor"),
        Entry(title: "Show Other Text", markdown: "[[Note|text]]", also: "wiki link alias label"),
    ]),
    EntrySection(title: "Find", entries: [
        Entry(title: "Find", shortcut: Shortcuts.find.label, also: "search note text"),
        Entry(title: "Find and Replace", shortcut: Shortcuts.replace.label, also: "search substitute change"),
        Entry(title: "Find Next", shortcut: Shortcuts.findNext.label, also: "search again"),
        Entry(title: "Find Previous", shortcut: Shortcuts.findPrevious.label, also: "search back"),
        Entry(title: "Use Selection for Find", shortcut: Shortcuts.useSelection.label, also: "search selected"),
    ]),
    EntrySection(title: "Notes and Folders", entries: [
        Entry(title: "New File", shortcut: Shortcuts.newFile.label, also: "note document create"),
        Entry(title: "New Folder", shortcut: Shortcuts.newFolder.label, also: "create directory"),
        Entry(title: "Save", shortcut: Shortcuts.save.label),
        Entry(title: "Open Folder", shortcut: Shortcuts.openFolder.label, also: "library vault choose"),
        Entry(title: "Reveal in Finder", shortcut: Shortcuts.reveal.label, also: "show"),
        Entry(title: "Move to Trash", shortcut: Shortcuts.trash.label, also: "delete remove bin"),
    ]),
    EntrySection(title: "Getting Around", entries: [
        Entry(title: "Go To", shortcut: Shortcuts.goTo.label, also: "navigation open find switch jump quick"),
        Entry(title: "Back", shortcut: Shortcuts.back.label, also: "navigation previous history mouse"),
        Entry(title: "Forward", shortcut: Shortcuts.forward.label, also: "navigation next history mouse"),
    ]),
    EntrySection(title: "View", entries: [
        Entry(title: "Explorer", shortcut: Shortcuts.explorer.label, also: "sidebar show hide library files folders tree"),
        Entry(title: "Search All Notes", shortcut: Shortcuts.search.label, also: "sidebar find text every documents library"),
        Entry(title: "Graph", shortcut: Shortcuts.graph.label, also: "show hide links map"),
        Entry(title: "Terminal", shortcut: Shortcuts.terminal.label, also: "show hide agent chat ai claude"),
        Entry(title: "Focus Mode", shortcut: Shortcuts.focus.label, also: "sentence paragraph dim"),
        Entry(title: "Typewriter Scrolling", shortcut: Shortcuts.typewriter.label, also: "center middle"),
        Entry(title: "Bigger Text", shortcut: Shortcuts.bigger.label, also: "font size zoom in larger"),
        Entry(title: "Smaller Text", shortcut: Shortcuts.smaller.label, also: "font size zoom out"),
        Entry(title: "Actual Size", shortcut: Shortcuts.actualSize.label, also: "font size zoom reset"),
    ]),
    EntrySection(title: "Search Lists", entries: [
        Entry(title: "Cheat Sheet", shortcut: Shortcuts.cheatSheet.label, also: "help keyboard shortcuts"),
        Entry(title: "Move Up or Down", shortcut: "↑ ↓", also: "arrow select go to"),
        Entry(title: "Pick", shortcut: "↩", also: "return enter choose open"),
        Entry(title: "Close", shortcut: "⎋", also: "escape dismiss"),
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

/// The button in the bar at the bottom; opens the cheat sheet.
struct CheatSheetButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.showingCheatSheet = true } label: {
            Image(systemName: "command")
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 18)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .foregroundStyle(Color.accentColor)
        .help("Cheat Sheet (\(Shortcuts.cheatSheet.label))")
        // Back to writing once the sheet is put away.
        .onChange(of: state.showingCheatSheet) { if !$0 { state.focusEditor() } }
    }
}

/// How to write each kind of formatting, searchable.
struct CheatSheet: View {
    var body: some View {
        SearchPanel(prompt: "Search, like “bold”, “list” or “sidebar”", matches: matches, section: \.section) {
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
