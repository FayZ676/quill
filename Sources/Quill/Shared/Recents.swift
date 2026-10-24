import Foundation

/// The notes most recently opened, newest first, kept across launches so Go To can offer
/// them before the rest of the library.
struct Recents {
    private static let key = "recentNotes"
    private static let limit = 500

    private let defaults: UserDefaults
    private var paths: [String] { didSet { defaults.set(paths, forKey: Self.key) } }

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: Self.key) ?? []
    }

    mutating func viewed(_ note: URL) {
        guard paths.first != note.path else { return }
        paths = Array(([note.path] + paths.filter { $0 != note.path }).prefix(Self.limit))
    }

    /// Follows notes that were renamed or moved; `rebase` gives a note's new URL, or nil
    /// when it didn't move.
    mutating func relocate(_ rebase: (URL) -> URL?) {
        let moved = paths.map { rebase(URL(fileURLWithPath: $0, isDirectory: false))?.path ?? $0 }
        if moved != paths { paths = moved }
    }

    /// `items` with the notes opened most recently first, the rest in the order given.
    func ordered(_ items: [URL]) -> [URL] {
        let rank = Dictionary(paths.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let recent = items.filter { rank[$0.path] != nil }.sorted { rank[$0.path]! < rank[$1.path]! }
        return recent + items.filter { rank[$0.path] == nil }
    }
}
