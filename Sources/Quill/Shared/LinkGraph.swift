import Foundation

/// The notes in a library and the links between them, for the graph view.
struct LinkGraph: Equatable {
    /// Every note, in library order.
    var notes: [URL] = []
    /// Pairs of indexes into `notes`, each pair once, whichever way it was written.
    var links: [Pair] = []

    struct Pair: Hashable {
        let a, b: Int
    }

    /// Reads every note in `resolver`'s library and gathers the links between them. Reads
    /// the disk, so call it off the main thread.
    static func build(_ resolver: LinkResolver) -> LinkGraph {
        let notes = resolver.notes
        let index = Dictionary(notes.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var links = Set<Pair>()
        for (i, url) in notes.enumerated() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for target in LinkResolver.targets(in: text) {
                guard let dest = resolver.resolve(target, from: url), let j = index[dest], j != i else { continue }
                links.insert(Pair(a: min(i, j), b: max(i, j)))
            }
        }
        return LinkGraph(notes: notes, links: links.sorted { ($0.a, $0.b) < ($1.a, $1.b) })
    }
}
