import SwiftUI

/// Whether an iCloud file is on the device yet. Downloaded files, and files not in
/// iCloud at all, have no state.
enum SyncState: Equatable {
    case notDownloaded, downloading

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
    ]

    init?(of url: URL) {
        var url = url
        url.removeAllCachedResourceValues()
        guard let v = try? url.resourceValues(forKeys: Self.keys), v.isUbiquitousItem == true,
              v.ubiquitousItemDownloadingStatus == .notDownloaded else { return nil }
        self = v.ubiquitousItemIsDownloading == true ? .downloading : .notDownloaded
    }

    /// The state of every file under `nodes` that has one.
    static func of(_ nodes: [FileNode]) -> [URL: SyncState] {
        var states: [URL: SyncState] = [:]
        func check(_ nodes: [FileNode]) {
            for node in nodes {
                if node.isDirectory { check(node.children ?? []) } else { states[node.url] = SyncState(of: node.url) }
            }
        }
        check(nodes)
        return states
    }
}

/// Marks files iCloud hasn't brought to the device yet; downloaded files show nothing.
struct SyncBadge: View {
    let sync: SyncState?

    var body: some View {
        Group {
            switch sync {
            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.tertiary)
                    .accessibilityLabel("Not downloaded")
            case .downloading:
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Downloading")
            case nil:
                EmptyView()
            }
        }
        .font(.footnote)
    }
}
