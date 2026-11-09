import AppKit
import SwiftUI

/// What the sidebar beside the strip shows, as VS Code's activity bar switches its side bar.
enum SidebarPanel { case explorer, search }

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

/// The sidebar's search: a box, and under it the notes and folders whose names hold what's
/// typed, as Go To finds them, then every line in the library holding it, by note. The arrow
/// keys move down through both, Return or a click opens what's picked, Escape goes back to
/// the page.
struct NoteSearchView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var search: NoteSearch
    /// The names that match, at most `fileLimit`: past that, the name wants more typing.
    @State private var files: [(url: URL, path: String)] = []
    private static let fileLimit = 10
    /// Which row is picked: the files first, then the lines after them.
    @State private var picked = 0
    @State private var keys: Any?
    @FocusState private var typing: Bool

    var body: some View {
        let matches = search.results.flatMap(\.matches)
        VStack(spacing: 0) {
            TextField("Search names and text", text: $search.query)
                .textFieldStyle(.plain)
                .appFont(14)
                .focused($typing)
                .onSubmit {
                    if files.indices.contains(picked) { state.goTo(files[picked].url) }
                    else if matches.indices.contains(picked - files.count) { open(matches[picked - files.count]) }
                }
                .onExitCommand { state.closeSidebar() }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(typing ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: typing ? 2 : 1))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if !search.query.isEmpty, files.isEmpty, search.results.isEmpty {
                Text("No results")
                    .appFont(12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !files.isEmpty {
                            SectionTitle(title: "Files", symbol: "doc.on.doc", detail: files.count.formatted())
                            ForEach(Array(files.enumerated()), id: \.element.url) { i, file in
                                Button {
                                    picked = i
                                    state.goTo(file.url)
                                } label: {
                                    FileRow(url: file.url, path: file.path, picked: i == picked)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .id(i)
                            }
                        }
                        if !search.results.isEmpty {
                            SectionTitle(title: "In Notes", symbol: "text.magnifyingglass", detail: summary)
                        }
                        ForEach(search.results) { result in
                            ResultHeader(result: result)
                            ForEach(result.matches) { match in
                                let row = files.count + match.id
                                Button {
                                    picked = row
                                    open(match)
                                } label: {
                                    MatchRow(match: match, picked: row == picked)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .id(row)
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
            findFiles()
            run()
        }
        // The library changed: what it holds may have too.
        .onChange(of: state.tree) { _ in
            findFiles()
            run()
        }
        .onChange(of: state.searchFocus) { _ in typing = true }
        .onAppear {
            findFiles()
            run()
            if state.sidebarShown { typing = true }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard state.panel == .search, state.typingInSidebar else { return event }
                let count = files.count + search.count
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
        let more = count >= NoteSearch.limit ? "+" : ""
        return "\(count.formatted())\(more) in \(notes) note\(notes == 1 ? "" : "s")"
    }

    /// Names are few and short, so they're matched at once, on the main thread, as Go To does.
    private func findFiles() {
        guard !search.query.trimmingCharacters(in: .whitespaces).isEmpty else { return files = [] }
        let items = state.items.filter { $0 != state.root }.map { (url: $0, path: PathMatch.path(of: $0, in: state.root)) }
        files = Array(PathMatch.filter(items, by: search.query).prefix(Self.fileLimit))
    }

    private func run() {
        let open = state.openFile.flatMap { url in state.textView.map { (url: url, text: $0.string) } }
        search.run(notes: state.links.notes, root: state.root, open: open)
    }

    private func open(_ match: NoteMatch) {
        state.openMatch(match.url, at: match.range)
    }
}

/// A group's name and icon, small and quiet, with how much it holds.
private struct SectionTitle: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(title).appFont(12, bold: true)
            Spacer(minLength: 4)
            Text(detail).appFont(12).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A note or folder whose name matches, with the folder it's in.
private struct FileRow: View {
    let url: URL
    let path: String
    let picked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: url.hasDirectoryPath ? "folder" : "doc.text").foregroundStyle(Color.accentColor)
            Text(FileNode.displayName(url))
                .appFont(13)
                .lineLimit(1)
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .appFont(12)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.secondary.opacity(0.18) : .clear))
        .contentShape(Rectangle())
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
