import SwiftUI

/// Counts the words in every note in the library, for the sidebar. A note is read again only
/// when it changes, so a large library is read once and then kept up cheaply. Use from one
/// queue at a time.
final class WordCounter {
    private var cache: [URL: (modified: Date, words: Int)] = [:]

    /// Words in each note under `nodes`. Notes iCloud hasn't downloaded are left out: reading
    /// one would download it.
    func counts(_ nodes: [FileNode], syncStates: [URL: SyncState]) -> [URL: Int] {
        var fresh: [URL: (modified: Date, words: Int)] = [:]
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                if node.isDirectory {
                    walk(node.children ?? [])
                    continue
                }
                guard syncStates[node.url] == nil,
                      let modified = (try? FileManager.default.attributesOfItem(atPath: node.url.path))?[.modificationDate] as? Date
                else { continue }
                if let cached = cache[node.url], cached.modified == modified {
                    fresh[node.url] = cached
                } else if let text = try? String(contentsOf: node.url, encoding: .utf8) {
                    fresh[node.url] = (modified, Stats.words(in: text))
                }
            }
        }
        walk(nodes)
        // Notes that are gone drop out.
        cache = fresh
        return fresh.mapValues(\.words)
    }
}

/// A sidebar row's count, on its right: the items in a folder, or the words in a note.
struct RowCount: View {
    let count: Int?
    let unit: String

    var body: some View {
        if let count {
            Text(count >= 10_000 ? count.formatted(.number.notation(.compactName)) : count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) \(unit)\(count == 1 ? "" : "s")")
        }
    }
}
