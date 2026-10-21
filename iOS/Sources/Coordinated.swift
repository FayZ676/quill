import Foundation

/// File operations through NSFileCoordinator. iOS syncs iCloud Drive (and other file
/// providers) by watching coordinated access: a file written without it can sit on the
/// device and never upload.
enum Coordinated {
    static func read(_ url: URL) throws -> String {
        var text: String?
        try coordinate { c, error, failed in
            c.coordinate(readingItemAt: url, options: [], error: error) { url in
                do {
                    var encoding = String.Encoding.utf8
                    text = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, usedEncoding: &encoding)
                } catch { failed(error) }
            }
        }
        return text ?? ""
    }

    static func write(_ text: String, to url: URL) throws {
        try writing(url) { try text.write(to: $0, atomically: true, encoding: .utf8) }
    }

    static func createFile(_ url: URL) throws {
        try writing(url) { try Data().write(to: $0, options: .withoutOverwriting) }
    }

    static func createDirectory(_ url: URL) throws {
        try writing(url) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }
    }

    static func move(_ source: URL, to destination: URL) throws {
        try coordinate { c, error, failed in
            c.coordinate(writingItemAt: source, options: .forMoving,
                         writingItemAt: destination, options: .forReplacing, error: error) { from, to in
                do {
                    c.item(at: from, willMoveTo: to)
                    try FileManager.default.moveItem(at: from, to: to)
                    c.item(at: from, didMoveTo: to)
                } catch { failed(error) }
            }
        }
    }

    /// To the trash where there is one (iCloud Drive's Recently Deleted), gone otherwise.
    static func delete(_ url: URL) throws {
        try coordinate { c, error, failed in
            c.coordinate(writingItemAt: url, options: .forDeleting, error: error) { url in
                do {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch { failed(error) }
            }
        }
    }

    /// Tells the file provider to look at files changed without coordination (as Quill
    /// 1.0.0 wrote them), so any it never noticed get uploaded. Changes nothing on disk.
    static func announce(_ urls: [URL]) {
        for url in urls {
            try? coordinate { c, error, _ in
                c.coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: error) { _ in }
            }
        }
    }

    private static func writing(_ url: URL, _ body: @escaping (URL) throws -> Void) throws {
        try coordinate { c, error, failed in
            c.coordinate(writingItemAt: url, options: [], error: error) { url in
                do { try body(url) } catch { failed(error) }
            }
        }
    }

    /// Runs one coordinated access, throwing the coordinator's error or the body's.
    private static func coordinate(_ access: (NSFileCoordinator, NSErrorPointer, (Error) -> Void) -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        access(NSFileCoordinator(), &coordinationError) { bodyError = $0 }
        if let error = coordinationError ?? bodyError { throw error }
    }
}
