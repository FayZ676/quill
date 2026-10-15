import AppKit
import CoreServices
import SwiftUI

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
    static func scan(_ dir: URL, depth: Int = 0) -> [FileNode] {
        let fm = FileManager.default
        guard depth < 8, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var nodes: [FileNode] = []
        for name in names where !name.hasPrefix(".") {
            let path = (dir.path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard !NSWorkspace.shared.isFilePackage(atPath: path) else { continue }
                let url = dir.appendingPathComponent(name, isDirectory: true)
                nodes.append(FileNode(url: url, isDirectory: true, children: scan(url, depth: depth + 1)))
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

final class Stats: ObservableObject {
    @Published private(set) var words = 0

    func update(_ text: String) {
        let count = text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
        if count != words { words = count }
    }
}

final class AppState: ObservableObject {
    static let shared = AppState()
    static let defaultFontSize = 17.0

    private let defaults = UserDefaults.standard

    @Published private(set) var root: URL
    @Published private(set) var tree: [FileNode] = []
    @Published var selection: URL? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published private(set) var openFile: URL?

    @Published var focusEnabled: Bool { didSet { defaults.set(focusEnabled, forKey: "focusEnabled") } }
    @Published var focusStyle: FocusStyle { didSet { defaults.set(focusStyle.rawValue, forKey: "focusStyle") } }
    @Published var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "typewriter") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var editorFont: EditorFont { didSet { defaults.set(editorFont.rawValue, forKey: "editorFont") } }

    @Published var renameTarget: URL?
    @Published var renameText = ""
    /// Folders open in the sidebar.
    @Published var expanded: Set<URL> { didSet { defaults.set(expanded.map(\.path), forKey: "expanded") } }

    /// Kept separate so per-keystroke word counts don't re-render the sidebar.
    let stats = Stats()
    let chrome = ChromeFader()
    weak var textView: FocusTextView?
    /// Installed by the editor; writes any unsaved text to disk.
    var flushSave: () -> Void = {}
    /// A just-created file is being named; the editor takes over once that's done.
    private var namingNewFile = false
    private var watcher: FolderWatcher?

    private init() {
        focusEnabled = defaults.bool(forKey: "focusEnabled")
        focusStyle = FocusStyle(rawValue: defaults.string(forKey: "focusStyle") ?? "") ?? .sentence
        typewriter = defaults.bool(forKey: "typewriter")
        let size = defaults.double(forKey: "fontSize")
        fontSize = size > 0 ? size : Self.defaultFontSize
        editorFont = EditorFont(rawValue: defaults.string(forKey: "editorFont") ?? "") ?? .duo
        expanded = Set((defaults.stringArray(forKey: "expanded") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })

        if let path = defaults.string(forKey: "root"), FileManager.default.fileExists(atPath: path) {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            root = Self.createDefaultLibrary()
        }
        startWatching()
        reloadTree()

        if let last = defaults.string(forKey: "lastFile"), FileManager.default.fileExists(atPath: last) {
            let url = URL(fileURLWithPath: last, isDirectory: false)
            selection = url
            openFile = url
        }
    }

    var currentItem: URL? { selection ?? openFile }

    private var targetDirectory: URL {
        guard let s = selection else { return root }
        return s.hasDirectoryPath ? s : s.deletingLastPathComponent()
    }

    // MARK: Library

    func reloadTree() {
        let fresh = FileNode.scan(root)
        if fresh != tree { tree = fresh }
        if let open = openFile, !FileManager.default.fileExists(atPath: open.path) {
            openFile = nil
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder to use as your library"
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { setRoot(url) }
    }

    func setRoot(_ url: URL) {
        flushSave()
        root = URL(fileURLWithPath: url.path, isDirectory: true)
        defaults.set(root.path, forKey: "root")
        if let open = openFile, !isInside(open, root) {
            selection = nil
            openFile = nil
        }
        startWatching()
        reloadTree()
    }

    /// Files or folders opened from Finder or the Dock icon.
    func openExternal(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { return setRoot(url) }
        let file = URL(fileURLWithPath: url.path, isDirectory: false)
        if !isInside(file, root) { setRoot(file.deletingLastPathComponent()) }
        selection = file
    }

    // MARK: File operations

    func newFile(in dir: URL? = nil) {
        let url = uniqueURL(in: dir ?? targetDirectory, base: "Untitled", ext: "md", isDirectory: false)
        do { try Data().write(to: url) } catch { return present(error) }
        reloadTree()
        expandAncestors(of: url)
        selection = url
        beginRename(url)
        namingNewFile = true
    }

    func newFolder(in dir: URL? = nil) {
        let url = uniqueURL(in: dir ?? targetDirectory, base: "New Folder", ext: nil, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch { return present(error) }
        reloadTree()
        expandAncestors(of: url)
        selection = url
        beginRename(url)
    }

    func beginRename(_ url: URL) {
        namingNewFile = false
        renameText = url.hasDirectoryPath ? url.lastPathComponent : FileNode.displayName(url)
        renameTarget = url
    }

    func cancelRename() {
        guard renameTarget != nil else { return }
        renameTarget = nil
        renameEnded()
    }

    func commitRename() {
        guard let old = renameTarget else { return }
        renameTarget = nil
        rename(old, to: renameText)
        renameEnded()
    }

    func rename(_ old: URL, to newName: String) {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        let isDir = old.hasDirectoryPath
        if !isDir, (name as NSString).pathExtension.isEmpty, !old.pathExtension.isEmpty {
            name += "." + old.pathExtension
        }
        let new = old.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isDir)
        guard new != old else { return }
        flushSave()
        do { try FileManager.default.moveItem(at: old, to: new) } catch { return present(error) }
        relocate(old, to: new)
        reloadTree()
    }

    /// Moves a library item into `dir`, or copies it in when it comes from outside the library.
    func move(_ item: URL, into dir: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { return }
        let src = URL(fileURLWithPath: item.path, isDirectory: isDir.boolValue)
        let dest = dir.appendingPathComponent(src.lastPathComponent, isDirectory: isDir.boolValue)
        guard src.deletingLastPathComponent().path != dir.path, src.path != dir.path, !isInside(dir, src) else { return }
        flushSave()
        let external = !isInside(src, root)
        do {
            if external {
                try FileManager.default.copyItem(at: src, to: dest)
            } else {
                try FileManager.default.moveItem(at: src, to: dest)
            }
        } catch { return present(error) }
        if !external { relocate(src, to: dest) }
        expandAncestors(of: dest)
        reloadTree()
    }

    /// Handles file URLs dropped on the sidebar.
    func drop(_ providers: [NSItemProvider], into dir: URL) -> Bool {
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self.move(url, into: dir) }
            }
        }
        return !files.isEmpty
    }

    func trash(_ url: URL) {
        flushSave()
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { return present(error) }
        if let open = openFile, isInside(open, url) || open == url { openFile = nil }
        if let sel = selection, isInside(sel, url) || sel == url { selection = nil }
        reloadTree()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func focusEditor() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Private

    private func renameEnded() {
        guard namingNewFile else { return }
        namingNewFile = false
        // Let the sidebar drop its text field before the editor takes focus.
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    private func expandAncestors(of url: URL) {
        var folders: [URL] = []
        var dir = url.deletingLastPathComponent()
        while isInside(dir, root) {
            folders.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        expanded.formUnion(folders)
    }

    /// Follows a renamed or moved item with the open file, selection and open folders.
    private func relocate(_ old: URL, to new: URL) {
        if let open = openFile, let moved = rebase(open, from: old, to: new) {
            openFile = moved
            defaults.set(moved.path, forKey: "lastFile")
        }
        if let sel = selection, let moved = rebase(sel, from: old, to: new) { selection = moved }
        expanded = Set(expanded.map { rebase($0, from: old, to: new) ?? $0 })
    }

    private func selectionChanged() {
        guard let url = selection, !url.hasDirectoryPath, url != openFile else { return }
        flushSave()
        openFile = url
        defaults.set(url.path, forKey: "lastFile")
    }

    private func startWatching() {
        watcher = FolderWatcher(url: root) { [weak self] in self?.reloadTree() }
    }

    private func isInside(_ url: URL, _ dir: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/")
    }

    private func rebase(_ url: URL, from old: URL, to new: URL) -> URL? {
        if url == old { return new }
        let prefix = old.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return new.appendingPathComponent(String(url.path.dropFirst(prefix.count)), isDirectory: url.hasDirectoryPath)
    }

    private func uniqueURL(in dir: URL, base: String, ext: String?, isDirectory: Bool) -> URL {
        for i in 1... {
            let name = (i == 1 ? base : "\(base) \(i)") + (ext.map { ".\($0)" } ?? "")
            let url = dir.appendingPathComponent(name, isDirectory: isDirectory)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        fatalError("unreachable")
    }

    private func present(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private static func createDefaultLibrary() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Quill", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? welcomeText.write(to: dir.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private static let welcomeText = """
    # Welcome to Quill

    Quill is a quiet place to write. Your documents are plain **Markdown** files in a folder on your Mac, so they're yours forever.

    ## Focus

    Press ⇧⌘D to turn on _Focus Mode_. Everything except the sentence you're writing fades away. Choose between sentence and paragraph focus in the View menu.

    Press ⇧⌘T for _Typewriter Scrolling_, which keeps the line you're writing in the middle of the screen.

    ## Library

    - ⌘N creates a new document, ⇧⌘N a new folder
    - ⌘O picks a different folder as your library
    - Drag files and folders in the sidebar to move them
    - Right-click a file in the sidebar to rename, reveal or trash it
    - ⌃⌘S shows or hides the library

    Everything saves automatically.

    ## Markdown

    - ⌘B for **bold**, ⌘I for _italic_, ⌘K for a [link](https://example.com)
    - ⇧⌘C for `inline code`, ⇧⌘X for ~~strikethrough~~
    - ⌘= and ⌘- change the text size

    > Lists continue when you press Return. Press Return on an empty item to end the list.

    """
}

/// Calls back on the main queue whenever anything under a folder changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
