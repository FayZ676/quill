import AppKit
import SwiftUI

/// Finding and replacing text in the open note, as VS Code's find box does: every match lit
/// on the page, the current one brighter, stepped through with Return or the arrows.
final class Finder: ObservableObject {
    enum Field { case find, replace }

    @Published private(set) var shown = false
    @Published var replacing = false
    @Published var query = "" {
        didSet { if query != oldValue { search(); reveal() } }
    }
    @Published var replacement = ""
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var current: Int?
    /// The field to put the caret in, for the bar to take up.
    @Published var focus: Field?
    weak var textView: NSTextView?

    /// Opens the bar on what's selected, if it's on one line, as VS Code does.
    func show(replacing: Bool) {
        if replacing { self.replacing = true }
        if let tv = textView, tv.selectedRange().length > 0 {
            let selected = (tv.string as NSString).substring(with: tv.selectedRange())
            if !selected.contains(where: \.isNewline) { query = selected }
        }
        shown = true
        search()
        reveal()
        focus = replacing && !query.isEmpty ? .replace : .find
    }

    /// Puts the bar away and the caret back in the note, on the match it was showing.
    func hide() {
        shown = false
        search()
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }

    /// Searches for what's selected, without opening the bar.
    func useSelection() {
        guard let tv = textView, tv.selectedRange().length > 0 else { return }
        query = (tv.string as NSString).substring(with: tv.selectedRange())
    }

    /// The next match (1) or the one before (-1), round from the end to the start.
    func step(_ by: Int) {
        if !shown {
            shown = true
            search()
            // The match after the caret is already the next one.
            if by > 0 { return reveal() }
        }
        let count = matches.count
        guard count > 0 else { return }
        current = current.map { ($0 + by + count) % count } ?? (by > 0 ? 0 : count - 1)
        highlight()
        reveal()
    }

    func replace() {
        guard let tv = textView, let current, tv.shouldChangeText(in: matches[current], replacementString: replacement)
        else { return }
        let range = matches[current]
        tv.replaceCharacters(in: range, with: replacement)
        // After what was put in, so the search picks up at the next match.
        tv.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        tv.didChangeText()
        reveal()
    }

    /// Replaces every match as one change, to undo in one go.
    func replaceAll() {
        guard let tv = textView, !matches.isEmpty,
              tv.shouldChangeText(inRanges: matches.map { NSValue(range: $0) },
                                  replacementStrings: matches.map { _ in replacement }),
              let storage = tv.textStorage else { return }
        storage.beginEditing()
        for range in matches.reversed() { storage.replaceCharacters(in: range, with: replacement) }
        storage.endEditing()
        tv.didChangeText()
    }

    /// Finds the matches afresh, as the note or what's typed changes. The current one is the
    /// first at or after the caret.
    func search() {
        // Nothing lit and nothing to light, as on every keystroke while the bar is away.
        guard let tv = textView, shown || !matches.isEmpty else { return }
        let text = tv.string as NSString
        var found: [NSRange] = []
        if shown, !query.isEmpty {
            var rest = NSRange(location: 0, length: text.length)
            while true {
                let match = text.range(of: query, options: .caseInsensitive, range: rest)
                if match.location == NSNotFound { break }
                found.append(match)
                rest = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
            }
        }
        matches = found
        let caret = tv.selectedRange().location
        current = found.isEmpty ? nil : found.firstIndex { $0.location >= caret } ?? 0
        highlight()
    }

    /// Selects the current match and scrolls to it.
    private func reveal() {
        guard let tv = textView, let current else { return }
        tv.setSelectedRange(matches[current])
        tv.scrollRangeToVisible(matches[current])
    }

    /// Lights the matches on the page, so they show while the caret is in the bar.
    private func highlight() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        lm.removeTemporaryAttribute(.backgroundColor,
                                   forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        for (i, range) in matches.enumerated() {
            lm.addTemporaryAttribute(.backgroundColor, value: i == current ? Theme.currentMatch : Theme.match,
                                     forCharacterRange: range)
        }
    }
}

/// The find box over the top right of the page: the search, how many it found, the arrows
/// and a close button, and a row under it for replacing, opened from the chevron.
struct FindBar: View {
    @ObservedObject var finder: Finder
    @FocusState private var focus: Finder.Field?

    var body: some View {
        if finder.shown {
            HStack(alignment: .top, spacing: 6) {
                icon(finder.replacing ? "chevron.down" : "chevron.right", help: "Toggle Replace") {
                    finder.replacing.toggle()
                    focus = finder.replacing ? .replace : .find
                }
                .frame(height: 30)
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        field("Find", text: $finder.query, as: .find) {
                            finder.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                        }
                        Text(count)
                            .appFont(12)
                            .foregroundStyle(finder.query.isEmpty || !finder.matches.isEmpty ? .secondary : Color.red)
                            .frame(minWidth: 64)
                        icon("chevron.up", help: "Previous Match (\(Shortcuts.findPrevious.label))") { finder.step(-1) }
                            .disabled(finder.matches.isEmpty)
                        icon("chevron.down", help: "Next Match (\(Shortcuts.findNext.label))") { finder.step(1) }
                            .disabled(finder.matches.isEmpty)
                        icon("xmark", help: "Close (⎋)") { finder.hide() }
                    }
                    if finder.replacing {
                        HStack(spacing: 4) {
                            field("Replace", text: $finder.replacement, as: .replace) { finder.replace() }
                            textButton("Replace") { finder.replace() }
                            textButton("All") { finder.replaceAll() }
                        }
                        .disabled(finder.matches.isEmpty)
                    }
                }
            }
            .padding(8)
            .frame(width: 440)
            .background(Color(nsColor: Theme.titleBar), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .onExitCommand { finder.hide() }
            .onAppear(perform: takeFocus)
            .onChange(of: finder.focus) { _ in takeFocus() }
        }
    }

    private var count: String {
        guard !finder.query.isEmpty else { return "" }
        guard let current = finder.current else { return "No results" }
        return "\(current + 1) of \(finder.matches.count)"
    }

    private func takeFocus() {
        guard let field = finder.focus else { return }
        focus = field
        finder.focus = nil
    }

    private func field(_ prompt: String, text: Binding<String>, as field: Finder.Field,
                       submit: @escaping () -> Void) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .appFont(14)
            .focused($focus, equals: field)
            .onSubmit(submit)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color(nsColor: Theme.background), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focus == field ? Color.accentColor : Color.secondary.opacity(0.3)))
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .appFont(13)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
