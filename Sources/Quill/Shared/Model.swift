import Combine
import Foundation
#if os(macOS)
import AppKit
#endif

struct FileNode: Identifiable, Hashable {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let textExtensions = markdownExtensions.union(["txt", "text"])

    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }

    var name: String { FileNode.displayName(url) }

    static func displayName(_ url: URL) -> String {
        markdownExtensions.contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
    }

    /// Folders and text files under `dir`, folders first. Directory URLs always carry a
    /// trailing slash so they compare equal to URLs built elsewhere in the app.
    static func scan(_ dir: URL) -> [FileNode] {
        var placeholders = 0
        return scan(dir, depth: 0, placeholders: &placeholders)
    }

    /// Like `scan(_:)`, also counting text files that iCloud hasn't downloaded yet. Those
    /// are left out, and asked for, until they arrive.
    static func scan(_ dir: URL, depth: Int = 0, placeholders: inout Int) -> [FileNode] {
        let fm = FileManager.default
        guard depth < 8, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var nodes: [FileNode] = []
        for name in names {
            if name.hasPrefix(".") {
                // iCloud stands in for an undownloaded "Note.md" with a hidden ".Note.md.icloud".
                let real = String(name.dropFirst().dropLast(".icloud".count))
                if name.hasSuffix(".icloud"), textExtensions.contains((real as NSString).pathExtension.lowercased()) {
                    try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(real, isDirectory: false))
                    placeholders += 1
                }
                continue
            }
            let path = (dir.path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                #if os(macOS)
                guard !NSWorkspace.shared.isFilePackage(atPath: path) else { continue }
                #endif
                let url = dir.appendingPathComponent(name, isDirectory: true)
                nodes.append(FileNode(url: url, isDirectory: true,
                                      children: scan(url, depth: depth + 1, placeholders: &placeholders)))
            } else {
                let url = dir.appendingPathComponent(name, isDirectory: false)
                guard textExtensions.contains(url.pathExtension.lowercased()) else { continue }
                nodes.append(FileNode(url: url, isDirectory: false, children: nil))
            }
        }
        return nodes.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum FocusStyle: String, CaseIterable, Identifiable {
    case sentence = "Sentence", paragraph = "Paragraph"
    var id: String { rawValue }
}

/// Light or dark for Quill alone, or whatever the device is set to. Each app's Theme applies it.
enum Appearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

final class Stats: ObservableObject {
    @Published private(set) var words = 0

    func update(_ text: String) {
        let count = Stats.words(in: text)
        if count != words { words = count }
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }
}
