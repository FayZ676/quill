import Foundation

/// The notes most recently opened, newest first. They're kept in the library itself, in
/// `.quill/recents.json`, so every device writing in the same library (through iCloud
/// Drive, say) shares them: Go To lists notes in the same order on each, and a note opened
/// on one opens on the others too.
///
/// Each note carries the time it was last opened, so two devices' lists merge into one
/// whichever order they reach the disk in, and iCloud's conflicting copies merge the same way.
final class Recents {
    struct Entry: Codable, Equatable {
        /// The note's path inside the library.
        let note: String
        let opened: Date
    }

    private struct List: Codable { var recent: [Entry] }

    private static let limit = 500
    private static let queue = DispatchQueue(label: "Quill.recents", qos: .utility)
    /// Where each device used to keep its own recents, by full path.
    private static let legacyKey = "recentNotes"
    /// When the newest note this device opened, or followed another device to, was opened.
    private static let seenKey = "recentsSeen"

    let root: URL
    /// Opens a note opened more recently on another device. Returns whether it could:
    /// one iCloud hasn't brought down yet is offered again on a later reload.
    var follow: (URL) -> Bool = { _ in false }

    private let file: URL
    private let defaults: UserDefaults
    private var entries: [Entry] = []
    /// Opened here but not yet written to the library.
    private var pending: [Entry] = []

    private var seen: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Self.seenKey)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Self.seenKey) }
    }

    init(root: URL, defaults: UserDefaults) {
        self.root = root
        self.defaults = defaults
        file = root.appendingPathComponent(".quill/recents.json", isDirectory: false)

        // Bring the old list into the library it belongs to, behind anything opened since.
        let legacy = (defaults.stringArray(forKey: Self.legacyKey) ?? []).compactMap { Self.relative($0, in: root) }
        guard !legacy.isEmpty else { return }
        defaults.removeObject(forKey: Self.legacyKey)
        pending = legacy.enumerated().map { Entry(note: $1, opened: Date(timeIntervalSince1970: Double(legacy.count - $0))) }
        entries = pending
        save()
    }

    func viewed(_ note: URL) {
        guard let path = Self.relative(note.path, in: root), entries.first?.note != path else { return }
        let entry = Entry(note: path, opened: Date())
        seen = entry.opened
        pending = Self.merge(pending, [entry])
        entries = Self.merge(entries, [entry])
        save()
    }

    /// Follows notes that were renamed or moved; `rebase` gives a note's new URL, or nil
    /// when it didn't move.
    func relocate(_ rebase: @escaping (URL) -> URL?) {
        let root = root
        let move: (String) -> String? = { note in
            rebase(root.appendingPathComponent(note, isDirectory: false)).flatMap { Self.relative($0.path, in: root) }
        }
        let moved = Self.moving(entries, move)
        guard moved != entries else { return }
        entries = moved
        pending = Self.moving(pending, move)
        save(moving: move)
    }

    /// Takes in what other devices have opened since the last look.
    func reload() {
        let file = file
        Self.queue.async { [weak self] in
            let (disk, conflicted) = Self.read(file)
            DispatchQueue.main.async {
                guard let self else { return }
                if conflicted { self.save() } else { self.apply(disk) }
            }
        }
    }

    /// `items` with the notes opened most recently first, the rest in the order given.
    func ordered(_ items: [URL]) -> [URL] {
        let rank = Dictionary(entries.enumerated().map { ($1.note, $0) }, uniquingKeysWith: min)
        let ranked = items.map { (url: $0, rank: Self.relative($0.path, in: root).flatMap { rank[$0] }) }
        let recent = ranked.filter { $0.rank != nil }.sorted { $0.rank! < $1.rank! }.map(\.url)
        return recent + ranked.filter { $0.rank == nil }.map(\.url)
    }

    // MARK: Private

    private func apply(_ list: [Entry]) {
        entries = Self.merge(list, pending)
        guard let latest = entries.first, latest.opened > seen,
              follow(root.appendingPathComponent(latest.note, isDirectory: false)) else { return }
        seen = latest.opened
    }

    /// Writes what's pending into the list on disk, first applying `move` to the notes there.
    private func save(moving move: ((String) -> String?)? = nil) {
        let file = file, mine = pending
        Self.queue.async { [weak self] in
            let written = Self.write(file) { disk in Self.merge(move.map { Self.moving(disk, $0) } ?? disk, mine) }
            DispatchQueue.main.async {
                guard let self, let written else { return }
                self.pending.removeAll { mine.contains($0) }
                self.apply(written)
            }
        }
    }

    /// One entry per note, at the latest time it was opened, newest first.
    private static func merge(_ a: [Entry], _ b: [Entry]) -> [Entry] {
        var latest: [String: Date] = [:]
        for entry in a + b { latest[entry.note] = max(latest[entry.note] ?? .distantPast, entry.opened) }
        let sorted = latest.map { Entry(note: $0.key, opened: $0.value) }
            .sorted { $0.opened != $1.opened ? $0.opened > $1.opened : $0.note < $1.note }
        return Array(sorted.prefix(limit))
    }

    private static func moving(_ entries: [Entry], _ move: (String) -> String?) -> [Entry] {
        merge(entries.map { Entry(note: move($0.note) ?? $0.note, opened: $0.opened) }, [])
    }

    private static func relative(_ path: String, in root: URL) -> String? {
        let prefix = root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    // Coordinated, so iCloud brings the file down before a read and uploads it after a write.

    private static func read(_ file: URL) -> (entries: [Entry], conflicted: Bool) {
        var entries: [Entry] = []
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { entries = decode($0) }
        let conflicted = !(NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).isEmpty
        return (entries, conflicted)
    }

    /// Writes `change` of the list on disk, with any copies iCloud couldn't reconcile merged
    /// in and then cleared away. Returns what was written, or nil if it couldn't be.
    private static func write(_ file: URL, _ change: @escaping ([Entry]) -> [Entry]) -> [Entry]? {
        var written: [Entry]?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { url in
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            let list = change(conflicts.reduce(decode(url)) { merge($0, decode($1.url)) })
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .secondsSince1970
                try encoder.encode(List(recent: list)).write(to: url, options: .atomic)
            } catch {
                NSLog("Quill: couldn't save recent notes to \(url.path): \(error)")
                return
            }
            conflicts.forEach { $0.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            written = list
        }
        return written
    }

    private static func decode(_ url: URL) -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url),
              let list = try? decoder.decode(List.self, from: data) else { return [] }
        return list.recent
    }
}
