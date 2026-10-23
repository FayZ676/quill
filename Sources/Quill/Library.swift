import AppKit
import CoreServices
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()
    static let defaultFontSize = Fonts.defaultSize

    private let defaults = UserDefaults.standard

    @Published private(set) var root: URL
    @Published private(set) var tree: [FileNode] = []
    /// The library's first scan hasn't landed yet.
    @Published private(set) var loading = true
    /// Files iCloud hasn't brought to this Mac yet.
    @Published private(set) var syncStates: [URL: SyncState] = [:]
    @Published var selection: URL? { didSet { if selection != oldValue { selectionChanged() } } }
    @Published private(set) var openFile: URL?
    /// The graph of notes stands in for the editor.
    @Published private(set) var showingGraph = false
    @Published private(set) var graph = LinkGraph()

    @Published var focusEnabled: Bool { didSet { defaults.set(focusEnabled, forKey: "focusEnabled") } }
    @Published var focusStyle: FocusStyle { didSet { defaults.set(focusStyle.rawValue, forKey: "focusStyle") } }
    @Published var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "typewriter") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var editorFont: EditorFont { didSet { defaults.set(editorFont.rawValue, forKey: "editorFont") } }
    @Published var textInput: TextInput { didSet { textInput.save(defaults) } }
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); appearance.apply() }
    }

    /// Whether the library sidebar is out. Animate changes so it slides.
    @Published var sidebarShown = true
    /// The Go To panel, for finding a document or folder by its path.
    @Published var goingTo = false
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
    /// The library's notes by name, for following and suggesting `[[links]]`.
    private(set) var links = LinkResolver([], root: URL(fileURLWithPath: "/"))
    /// The heading a followed `[[Note#Heading]]` link points into, for the editor to show.
    var pendingHeading: String?
    /// Installed by the editor; puts the caret on `pendingHeading` in the open note.
    var showPendingHeading: () -> Void = {}
    /// Installed by the editor; rereads the open note, now at the given URL, after Quill
    /// has rewritten it.
    var reloadEditor: (URL) -> Void = { _ in }
    /// A just-created file is being named; the editor takes over once that's done.
    private var namingNewFile = false
    private var watcher: FolderWatcher?
    private var recheck: DispatchWorkItem?
    private static let scanQueue = DispatchQueue(label: "Quill.scan", qos: .userInitiated)
    private var scanning = false
    /// Another scan was asked for while one ran.
    private var rescan = false
    /// Counts graph builds, so a slow one can't land after a newer one.
    private var graphBuild = 0

    private init() {
        focusEnabled = defaults.bool(forKey: "focusEnabled")
        focusStyle = FocusStyle(rawValue: defaults.string(forKey: "focusStyle") ?? "") ?? .sentence
        typewriter = defaults.bool(forKey: "typewriter")
        let size = defaults.double(forKey: "fontSize")
        fontSize = size > 0 ? size : Self.defaultFontSize
        editorFont = EditorFont(rawValue: defaults.string(forKey: "editorFont") ?? "") ?? .duo
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        textInput = TextInput.load(defaults)
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

    /// Rescans the library in the background; the tree and everything built from it update
    /// when the scan lands. A large library (an Obsidian vault, say) takes a while to walk,
    /// and the folder watcher asks for a scan on every save, so this never holds up typing.
    func reloadTree() {
        if let open = openFile, !FileManager.default.fileExists(atPath: open.path) {
            openFile = nil
        }
        recheck?.cancel()
        // One scan at a time; asks made during one get a single scan after it.
        guard !scanning else { return rescan = true }
        scanning = true
        let root = root, tree = tree, links = links
        Self.scanQueue.async {
            let fresh = FileNode.scan(root)
            let changed = fresh != tree || links.root != root
            let scan = Scan(root: root, tree: fresh, changed: changed,
                            links: changed ? LinkResolver(fresh, root: root) : links,
                            syncStates: SyncState.of(fresh))
            DispatchQueue.main.async { [weak self] in self?.apply(scan) }
        }
    }

    private struct Scan {
        let root: URL
        let tree: [FileNode]
        let changed: Bool
        let links: LinkResolver
        let syncStates: [URL: SyncState]
    }

    private func apply(_ scan: Scan) {
        scanning = false
        // The library changed under the scan: it's out of date.
        guard scan.root == root else { return reloadTree() }
        if scan.changed {
            links = scan.links
            tree = scan.tree
        }
        if loading { loading = false }
        if scan.syncStates != syncStates { syncStates = scan.syncStates }

        if rescan {
            rescan = false
            reloadTree()
        } else if scan.syncStates.values.contains(.downloading) {
            // A finished download doesn't always reach the folder watcher, so look again
            // until every download has landed.
            let work = DispatchWorkItem { [weak self] in self?.reloadTree() }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        rebuildGraph()
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
        loading = true
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

    // MARK: Graph

    func toggleGraph() {
        if showingGraph { closeGraph() } else { showGraph() }
    }

    func showGraph() {
        flushSave()
        // Keys would otherwise still type into the document behind the graph.
        textView?.window?.makeFirstResponder(nil)
        selection = nil
        showingGraph = true
        chrome.reveal()
        rebuildGraph()
    }

    /// Back to the note that was open.
    func closeGraph() {
        guard showingGraph else { return }
        showingGraph = false
        selection = openFile
        focusEditor()
    }

    private func rebuildGraph() {
        guard showingGraph else { return }
        graphBuild += 1
        let build = graphBuild, links = links
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = LinkGraph.build(links)
            DispatchQueue.main.async { [weak self] in
                guard let self, build == self.graphBuild, fresh != self.graph else { return }
                self.graph = fresh
            }
        }
    }

    // MARK: Links

    /// Opens the note a `[[link]]` names, at the heading it names if any. A note that
    /// doesn't exist yet is created, as Obsidian does: at the top of the library, or in the
    /// folder the link names.
    func openLink(_ target: String) {
        flushSave()
        pendingHeading = LinkResolver.heading(in: target)
        // `[[#Heading]]` points into this note.
        if LinkResolver.split(target).name.isEmpty { return showPendingHeading() }
        if let url = links.resolve(target, from: openFile) {
            return url == openFile ? showPendingHeading() : openNote(url)
        }
        guard let url = links.newNote(for: target) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
        } catch { return present(error) }
        pendingHeading = nil
        reloadTree()
        expandAncestors(of: url)
        openNote(url)
    }

    /// Opens a note, ready to write in.
    func openNote(_ url: URL) {
        selection = url
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    /// After a note or folder moves from `old` to `new`, points every link at where its note
    /// is now, as Obsidian does. `before` is the library as it was.
    private func updateLinks(_ before: LinkResolver, moved old: URL, to new: URL) {
        let moves = before.moves(from: old, to: new)
        guard !moves.isEmpty else { return }
        for note in before.notes {
            let now = moves[note] ?? note
            guard let text = try? String(contentsOf: now, encoding: .utf8) else { continue }
            let rewritten = before.rewrite(text, of: note, movedTo: now, moves: moves)
            guard rewritten != text else { continue }
            do {
                try rewritten.write(to: now, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Quill: couldn't update links in \(now.path): \(error)")
                continue
            }
            if now == openFile { reloadEditor(now) }
        }
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
        let before = links
        do { try FileManager.default.moveItem(at: old, to: new) } catch { return present(error) }
        relocate(old, to: new)
        updateLinks(before, moved: old, to: new)
        reloadTree()
    }

    /// Moves a library item into `dir`, or copies it in when it comes from outside the library.
    /// Every folder in the library, depth-first, with its depth (the library itself is 0).
    var folders: [(url: URL, depth: Int)] {
        func walk(_ nodes: [FileNode], _ depth: Int) -> [(URL, Int)] {
            nodes.filter(\.isDirectory).flatMap { [($0.url, depth)] + walk($0.children ?? [], depth + 1) }
        }
        return [(root, 0)] + walk(tree, 1)
    }

    /// Every folder and document in the library, depth-first, the library itself first.
    var items: [URL] {
        func walk(_ nodes: [FileNode]) -> [URL] { nodes.flatMap { [$0.url] + walk($0.children ?? []) } }
        return [root] + walk(tree)
    }

    /// Opens a document, or picks out a folder in the sidebar with the folders above it open.
    func goTo(_ url: URL) {
        guard url.hasDirectoryPath else { return openNote(url) }
        withAnimation { sidebarShown = true }
        guard url != root else { return }
        expandAncestors(of: url)
        selection = url
    }

    func moveTargets(for item: URL) -> [(url: URL, depth: Int)] {
        folders.filter { $0.url != item.deletingLastPathComponent() && $0.url != item && !isInside($0.url, item) }
    }

    func move(_ item: URL, into dir: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { return }
        let src = URL(fileURLWithPath: item.path, isDirectory: isDir.boolValue)
        let dest = dir.appendingPathComponent(src.lastPathComponent, isDirectory: isDir.boolValue)
        guard src.deletingLastPathComponent().path != dir.path, src.path != dir.path, !isInside(dir, src) else { return }
        flushSave()
        let external = !isInside(src, root)
        let before = links
        do {
            if external {
                try FileManager.default.copyItem(at: src, to: dest)
            } else {
                try FileManager.default.moveItem(at: src, to: dest)
            }
        } catch { return present(error) }
        if !external {
            relocate(src, to: dest)
            updateLinks(before, moved: src, to: dest)
        }
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
        guard let url = selection, !url.hasDirectoryPath else { return }
        // Picking a note, even the one that was open, leaves the graph for the editor.
        showingGraph = false
        guard url != openFile else { return }
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

    ## Links

    Type `[[` to link to another document, picking it from the list that appears. ⌘-click a link to open it; a link to a document you haven't written yet creates it. Renaming or moving a document updates the links to it. ⌥⌘G shows all your documents and the links between them as a graph.

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
