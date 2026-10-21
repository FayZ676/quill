import Foundation

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
}
