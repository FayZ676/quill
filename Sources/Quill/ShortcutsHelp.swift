import SwiftUI

/// What you can press or type while writing, for the keyboard button by the word count. The
/// iPhone has its Markdown toolbar for this; the Mac has only menus. Keep the shortcuts in
/// step with QuillCommands.
private struct Shortcut: Identifiable {
    let title: String
    /// Keys to press (⌘B) or Markdown to type (`**bold**`).
    let keys: String
    var typed = false
    /// Other words someone might search for it by.
    var also = ""

    var id: String { title }
}

private struct ShortcutSection: Identifiable {
    let title: String
    let shortcuts: [Shortcut]

    var id: String { title }
}

private let sections = [
    ShortcutSection(title: "Format", shortcuts: [
        Shortcut(title: "Bold", keys: "⌘B", also: "strong heavy **"),
        Shortcut(title: "Italic", keys: "⌘I", also: "emphasis slanted _ *"),
        Shortcut(title: "Strikethrough", keys: "⇧⌘X", also: "cross out delete ~~"),
        Shortcut(title: "Inline Code", keys: "⇧⌘C", also: "monospace backtick `"),
        Shortcut(title: "Link", keys: "⌘K", also: "url web hyperlink"),
    ]),
    ShortcutSection(title: "Markdown", shortcuts: [
        Shortcut(title: "Bold", keys: "**text**", typed: true, also: "strong"),
        Shortcut(title: "Italic", keys: "_text_", typed: true, also: "emphasis"),
        Shortcut(title: "Heading", keys: "# ", typed: true, also: "title header h1 hash"),
        Shortcut(title: "Smaller Heading", keys: "## ", typed: true, also: "subheading subtitle header h2 h3"),
        Shortcut(title: "Bulleted List", keys: "- ", typed: true, also: "bullet unordered dash"),
        Shortcut(title: "Numbered List", keys: "1. ", typed: true, also: "ordered"),
        Shortcut(title: "Task", keys: "- [ ] ", typed: true, also: "todo checkbox checklist tick"),
        Shortcut(title: "Quote", keys: "> ", typed: true, also: "blockquote citation"),
        Shortcut(title: "Divider", keys: "---", typed: true, also: "rule line separator horizontal"),
        Shortcut(title: "Code Block", keys: "```", typed: true, also: "fence monospace"),
        Shortcut(title: "Link", keys: "[text](url)", typed: true, also: "url web hyperlink"),
        Shortcut(title: "Next List Item", keys: "↩", also: "continue list bullet return; on an empty item, ends the list"),
    ]),
    ShortcutSection(title: "Links Between Notes", shortcuts: [
        Shortcut(title: "Link to a Note", keys: "[[", typed: true, also: "wiki link wikilink backlink connect"),
        Shortcut(title: "Choose a Suggestion", keys: "↩ or ⇥", also: "wiki link autocomplete pick tab"),
        Shortcut(title: "Link to a Heading", keys: "[[Note#Heading]]", typed: true, also: "wiki link section anchor"),
        Shortcut(title: "Show Other Text", keys: "[[Note|text]]", typed: true, also: "wiki link alias label rename"),
        Shortcut(title: "Open a Link", keys: "⌘-click", also: "wiki link follow go jump"),
    ]),
    ShortcutSection(title: "Documents", shortcuts: [
        Shortcut(title: "New File", keys: "⌘N", also: "document note create"),
        Shortcut(title: "New Folder", keys: "⇧⌘N", also: "create directory"),
        Shortcut(title: "Go To", keys: "⇧⌘O", also: "find search jump open quick"),
        Shortcut(title: "Open Folder", keys: "⌘O", also: "library vault"),
        Shortcut(title: "Save", keys: "⌘S"),
        Shortcut(title: "Reveal in Finder", keys: "⌥⌘R", also: "show"),
        Shortcut(title: "Move to Trash", keys: "⌥⌘⌫", also: "delete remove"),
    ]),
    ShortcutSection(title: "View", shortcuts: [
        Shortcut(title: "Sidebar", keys: "⌃⌘S", also: "library hide show"),
        Shortcut(title: "Graph", keys: "⌥⌘G", also: "links map"),
        Shortcut(title: "Focus Mode", keys: "⇧⌘D", also: "dim distraction sentence paragraph"),
        Shortcut(title: "Typewriter Scrolling", keys: "⇧⌘T", also: "center caret"),
        Shortcut(title: "Bigger Text", keys: "⌘=", also: "font size zoom in larger"),
        Shortcut(title: "Smaller Text", keys: "⌘-", also: "font size zoom out"),
        Shortcut(title: "Actual Size", keys: "⌘0", also: "font size reset default"),
    ]),
]

/// The keyboard button by the word count; opens the list of shortcuts above it.
struct ShortcutsButton: View {
    @EnvironmentObject var state: AppState
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Keyboard Shortcuts")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ShortcutsList()
        }
        // Back to writing once the list is put away.
        .onChange(of: showing) { if !$0 { state.focusEditor() } }
    }
}

private struct ShortcutsList: View {
    @State private var query = ""
    @FocusState private var searching: Bool

    /// The sections with only the shortcuts that hold every word typed.
    private var matches: [ShortcutSection] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            let shortcuts = section.shortcuts.filter { shortcut in
                let haystack = "\(shortcut.title) \(shortcut.keys) \(shortcut.also) \(section.title)".lowercased()
                return words.allSatisfy(haystack.contains)
            }
            return shortcuts.isEmpty ? nil : ShortcutSection(title: section.title, shortcuts: shortcuts)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search, like “bold” or “link”", text: $query)
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
                Text("No Shortcuts Match")
                    .appFont(13)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(matches) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .appFont(11, bold: true)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                ForEach(section.shortcuts) { ShortcutRow(shortcut: $0) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(width: 340, height: 440)
        .background(Color(nsColor: Theme.background))
        .onAppear { searching = true }
    }
}

private struct ShortcutRow: View {
    let shortcut: Shortcut

    var body: some View {
        HStack {
            Text(shortcut.title).appFont(13)
            Spacer(minLength: 12)
            if shortcut.typed {
                Text(shortcut.keys)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text(shortcut.keys)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
