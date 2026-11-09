import AppKit
import SwiftUI

/// What the sidebar beside the strip shows, as VS Code's activity bar switches its side bar.
enum SidebarPanel { case explorer, search }

/// The parts of the strip and sidebar the mouse can rest on, for the sidebar to show over the
/// page while it's there.
enum HoverArea: Hashable {
    case strip, sidebar
    case icon(SidebarPanel)
}

/// A line of a note holding what was searched for.
struct NoteMatch: Identifiable {
    let id: Int
    let url: URL
    /// Where the match is in the note's text.
    let range: NSRange
    /// The line around it, trimmed to fit the sidebar, and where in that the match is.
    let line: String
    let lit: Range<String.Index>
}

/// A note with matches, and the matches in it.
struct NoteResult: Identifiable {
    let url: URL
    let path: String
    let matches: [NoteMatch]
    var id: URL { url }
}

/// Searches the text of every note, as VS Code's search does: ignoring case and accents, a
/// moment after you stop typing, off the main thread, so a large library doesn't hold up
/// the box.
final class NoteSearch: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [NoteResult] = []
    /// Matches beyond this aren't listed: past it, the search wants narrowing.
    static let limit = 2000
    private var pending: DispatchWorkItem?
    private static let queue = DispatchQueue(label: "Quill.search", qos: .userInitiated)

    var count: Int { results.reduce(0) { $0 + $1.matches.count } }

    /// Searches `notes` for the query. The open note is searched as it is on the page, which
    /// may be ahead of what's saved.
    func run(notes: [URL], root: URL, open: (url: URL, text: String)?) {
        pending?.cancel()
        let query = query
        guard !query.isEmpty else { return results = [] }
        var work: DispatchWorkItem?
        work = DispatchWorkItem { [weak self] in
            // A newer search cancels this one, while it runs or once it's done.
            let stale = { [weak work] in work?.isCancelled ?? true }
            var found: [NoteResult] = []
            var total = 0
            for url in notes {
                if stale() { return }
                let text = url == open?.url ? open?.text : try? String(contentsOf: url, encoding: .utf8)
                guard let text else { continue }
                let matches = Self.matches(of: query, in: text, url: url, from: total)
                guard !matches.isEmpty else { continue }
                found.append(NoteResult(url: url, path: PathMatch.path(of: url, in: root), matches: matches))
                total += matches.count
                if total >= Self.limit { break }
            }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async {
                if !stale() { self?.results = found }
            }
        }
        pending = work
        Self.queue.asyncAfter(deadline: .now() + 0.15, execute: work!)
    }

    private static func matches(of query: String, in text: String, url: URL, from first: Int) -> [NoteMatch] {
        let ns = text as NSString
        var found: [NoteMatch] = []
        var rest = NSRange(location: 0, length: ns.length)
        while first + found.count < limit {
            let range = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            if range.location == NSNotFound { break }
            let lineRange = ns.lineRange(for: range)
            // Some of the line before the match, so it isn't cut off at the sidebar's edge.
            // Whole characters only, so an emoji isn't cut in two.
            let start = ns.rangeOfComposedCharacterSequence(at: max(lineRange.location, range.location - 30)).location
            let before = ns.substring(with: NSRange(location: start, length: range.location - start))
            var end = min(NSMaxRange(lineRange), NSMaxRange(range) + 120)
            if end < ns.length { end = ns.rangeOfComposedCharacterSequence(at: end).location }
            let after = ns.substring(with: NSRange(location: NSMaxRange(range), length: max(0, end - NSMaxRange(range))))
            let prefix = (start > lineRange.location ? "…" : "") + before.drop { $0 == " " || $0 == "\t" }
            let match = ns.substring(with: range)
            let line = prefix + match + after.trimmingCharacters(in: .newlines)
            let lit = line.index(line.startIndex, offsetBy: prefix.count)..<line.index(line.startIndex, offsetBy: prefix.count + match.count)
            found.append(NoteMatch(id: first + found.count, url: url, range: range, line: line, lit: lit))
            rest = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
        }
        return found
    }
}

/// The sidebar's search: a box, and under it every line in the library holding what's typed,
/// by note. The arrow keys move through the lines, Return or a click opens the note there,
/// Escape goes back to the page.
struct NoteSearchView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var search: NoteSearch
    @State private var picked = 0
    @State private var keys: Any?
    @FocusState private var typing: Bool

    var body: some View {
        let matches = search.results.flatMap(\.matches)
        VStack(spacing: 0) {
            TextField("Search all notes", text: $search.query)
                .textFieldStyle(.plain)
                .appFont(14)
                .focused($typing)
                .onSubmit { if matches.indices.contains(picked) { open(matches[picked]) } }
                .onExitCommand { state.closeSidebar() }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(typing ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: typing ? 2 : 1))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if !search.query.isEmpty {
                Text(summary)
                    .appFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(search.results) { result in
                            ResultHeader(result: result)
                            ForEach(result.matches) { match in
                                Button {
                                    picked = match.id
                                    open(match)
                                } label: {
                                    MatchRow(match: match, picked: match.id == picked)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .id(match.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: picked) { proxy.scrollTo($0) }
            }
        }
        .onChange(of: search.query) { _ in
            picked = 0
            run()
        }
        // The library changed: what it holds may have too.
        .onChange(of: state.tree) { _ in run() }
        .onChange(of: state.searchFocus) { _ in typing = true }
        // A search typed over the page stays out to work through.
        .onChange(of: typing) { if $0 { state.keepPeek() } }
        .onAppear {
            run()
            if state.sidebarShown { typing = true }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard state.panel == .search, state.typingInSidebar else { return event }
                let count = search.results.reduce(0) { $0 + $1.matches.count }
                switch event.keyCode {
                case 125: picked = min(picked + 1, max(count - 1, 0))
                case 126: picked = max(picked - 1, 0)
                default: return event
                }
                return nil
            }
        }
        .onDisappear { keys.map(NSEvent.removeMonitor) }
    }

    private var summary: String {
        let count = search.count, notes = search.results.count
        if count == 0 { return "No results" }
        let more = count >= NoteSearch.limit ? "+" : ""
        return "\(count.formatted())\(more) result\(count == 1 ? "" : "s") in \(notes) note\(notes == 1 ? "" : "s")"
    }

    private func run() {
        let open = state.openFile.flatMap { url in state.textView.map { (url: url, text: $0.string) } }
        search.run(notes: state.links.notes, root: state.root, open: open)
    }

    private func open(_ match: NoteMatch) {
        state.openMatch(match.url, at: match.range)
    }
}

/// A note's name over its matches, with the folder it's in.
private struct ResultHeader: View {
    let result: NoteResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
            Text(FileNode.displayName(result.url))
                .appFont(13, bold: true)
                .lineLimit(1)
            let folder = (result.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .appFont(12)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            ItemCount(count: result.matches.count).appFont(12)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

/// A line holding a match, the match lit as find lights it on the page.
private struct MatchRow: View {
    let match: NoteMatch
    let picked: Bool

    var body: some View {
        Text(text)
            .appFont(13)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.secondary.opacity(0.18) : .clear))
            .contentShape(Rectangle())
    }

    private var text: AttributedString {
        var text = AttributedString(match.line)
        if let lit = Range(match.lit, in: text) {
            text[lit].backgroundColor = Color(nsColor: Theme.currentMatch)
        }
        return text
    }
}
