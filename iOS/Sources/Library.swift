import SwiftUI
import UIKit

/// One screen on the navigation stack: a folder or a document. A reference type, so a
/// rename can move it to its new URL without the stack rebuilding the screen.
final class Page: ObservableObject, Hashable {
    @Published var url: URL

    init(_ url: URL) { self.url = url }

    static func == (a: Page, b: Page) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard
    private static let localLibrary = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    @Published private(set) var root: URL
    @Published private(set) var tree: [FileNode] = []
    /// iCloud files still on their way down; the library refreshes until they've all arrived.
    @Published private(set) var downloading = 0
    /// Files iCloud hasn't brought to the device yet.
    @Published private(set) var syncStates: [URL: SyncState] = [:]
    @Published var pages: [Page] = [] { didSet { rememberLocation() } }

    @Published var focusEnabled: Bool { didSet { defaults.set(focusEnabled, forKey: "focusEnabled") } }
    @Published var focusStyle: FocusStyle { didSet { defaults.set(focusStyle.rawValue, forKey: "focusStyle") } }
    @Published var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "typewriter") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var editorFont: EditorFont { didSet { defaults.set(editorFont.rawValue, forKey: "editorFont") } }
    @Published var textInput: TextInput { didSet { textInput.save(defaults) } }

    @Published var renameTarget: URL?
    @Published var renameText = ""
    /// The rename is naming a just-created document; the editor takes over once it's done.
    @Published private(set) var namingNewFile = false
    @Published var deleteTarget: URL?
    @Published var errorMessage: String?
    /// First launch: Quill asks where the library lives before anything else.
    @Published var choosingLibrary: Bool

    weak var textView: FocusTextView?
    /// Installed by the open editor; writes any unsaved text to disk.
    var flushSave: () -> Void = {}
    /// The library's notes by name, for following and suggesting `[[links]]`.
    private(set) var links = LinkResolver([], root: URL(fileURLWithPath: "/"))
    /// The heading a followed `[[Note#Heading]]` link points into, for the editor to show.
    var pendingHeading: String?
    /// Posted when Quill rewrites a note's links, with the note's old and new URLs as
    /// `"old"` and `"new"`, so an editor showing it can take the change in.
    static let noteRewritten = Notification.Name("QuillNoteRewritten")

    private var children: [URL: [FileNode]] = [:]
    /// The picked folder, kept open for the life of the app (iOS sandbox access).
    private var scopedRoot: URL?
    private var recheck: DispatchWorkItem?

    private init() {
        focusEnabled = defaults.bool(forKey: "focusEnabled")
        focusStyle = FocusStyle(rawValue: defaults.string(forKey: "focusStyle") ?? "") ?? .sentence
        typewriter = defaults.bool(forKey: "typewriter")
        let size = defaults.double(forKey: "fontSize")
        fontSize = size > 0 ? size : Fonts.defaultSize
        editorFont = EditorFont(rawValue: defaults.string(forKey: "editorFont") ?? "") ?? .duo
        textInput = TextInput.load(defaults)
        choosingLibrary = !defaults.bool(forKey: "libraryChosen")
        root = Self.localLibrary

        if let bookmark = defaults.data(forKey: "rootBookmark"), let url = Self.resolve(bookmark) {
            open(url)
        }
        reloadTree()
        restoreLocation()
    }

    var isExternalLibrary: Bool { scopedRoot != nil }

    var libraryName: String { isExternalLibrary ? root.lastPathComponent : "Quill" }

    func children(of dir: URL) -> [FileNode] { children[dir] ?? [] }

    /// Every folder in the library, depth-first, with its depth (the library itself is 0).
    var folders: [(url: URL, depth: Int)] {
        func walk(_ nodes: [FileNode], _ depth: Int) -> [(URL, Int)] {
            nodes.filter(\.isDirectory).flatMap { [($0.url, depth)] + walk($0.children ?? [], depth + 1) }
        }
        return [(root, 0)] + walk(tree, 1)
    }

    // MARK: Library

    func reloadTree() {
        var placeholders = 0
        let fresh = FileNode.scan(root, placeholders: &placeholders)
        if fresh != tree || links.root != root {
            links = LinkResolver(fresh, root: root)
            tree = fresh
            var map: [URL: [FileNode]] = [root: fresh]
            func index(_ nodes: [FileNode]) {
                for node in nodes where node.isDirectory {
                    map[node.url] = node.children ?? []
                    index(node.children ?? [])
                }
            }
            index(fresh)
            children = map
        }
        if downloading != placeholders { downloading = placeholders }
        // Screens for things deleted elsewhere go away.
        if let gone = pages.firstIndex(where: { !FileManager.default.fileExists(atPath: $0.url.path) }) {
            pages.removeSubrange(gone...)
        }
        let states = SyncState.of(tree)
        if states != syncStates { syncStates = states }

        recheck?.cancel()
        if placeholders > 0 || states.values.contains(.downloading) {
            let work = DispatchWorkItem { [weak self] in self?.reloadTree() }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Makes a folder picked in Files (e.g. the Mac library in iCloud Drive) the library.
    func setRoot(_ url: URL) {
        flushSave()
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Quill wasn't given access to “\(url.lastPathComponent)”."
            return
        }
        do {
            defaults.set(try url.bookmarkData(), forKey: "rootBookmark")
        } catch {
            url.stopAccessingSecurityScopedResource()
            return present(error)
        }
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
        open(url)
        libraryChosen()
    }

    func useLocalLibrary() {
        flushSave()
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
        defaults.removeObject(forKey: "rootBookmark")
        root = Self.localLibrary
        let fm = FileManager.default
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true {
            try? Self.welcomeText.write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        }
        libraryChosen()
    }

    func goBack() {
        if !pages.isEmpty { pages.removeLast() }
    }

    // MARK: File operations

    func newFile(in dir: URL) {
        let url = uniqueURL(in: dir, base: "Untitled", ext: "md", isDirectory: false)
        do { try Coordinated.createFile(url) } catch { return present(error) }
        reloadTree()
        pages.append(Page(url))
        // After the editor has slid in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.beginRename(url)
            self?.namingNewFile = true
        }
    }

    func newFolder(in dir: URL) {
        let url = uniqueURL(in: dir, base: "New Folder", ext: nil, isDirectory: true)
        do { try Coordinated.createDirectory(url) } catch { return present(error) }
        reloadTree()
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
        do { try Coordinated.move(old, to: new) } catch { return present(error) }
        relocate(old, to: new)
        updateLinks(before, moved: old, to: new)
        reloadTree()
    }

    func move(_ item: URL, into dir: URL) {
        let dest = dir.appendingPathComponent(item.lastPathComponent, isDirectory: item.hasDirectoryPath)
        flushSave()
        let before = links
        do { try Coordinated.move(item, to: dest) } catch { return present(error) }
        relocate(item, to: dest)
        updateLinks(before, moved: item, to: dest)
        reloadTree()
    }

    // MARK: Links

    /// Opens the note a `[[link]]` in `source` names, at the heading it names if any, over
    /// the note it's in. A note that doesn't exist yet is created, as Obsidian does: at the
    /// top of the library, or in the folder the link names. Links within `source` are the
    /// editor's to follow.
    func openLink(_ target: String, from source: URL) {
        flushSave()
        let name = LinkResolver.split(target).name
        pendingHeading = LinkResolver.heading(in: target)
        guard !name.isEmpty else { return }
        if let url = links.resolve(target, from: source) {
            if url != source { pages.append(Page(url)) }
            return
        }
        let path = FileNode.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) ? name : name + ".md"
        let url = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard isInside(url, root) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Coordinated.createFile(url)
        } catch { return present(error) }
        pendingHeading = nil
        reloadTree()
        pages.append(Page(url))
    }

    /// After a note or folder moves from `old` to `new`, points every link at where its note
    /// is now, as Obsidian does. `before` is the library as it was.
    private func updateLinks(_ before: LinkResolver, moved old: URL, to new: URL) {
        var moves: [URL: URL] = [:]
        for note in before.notes {
            if let moved = rebase(note, from: old, to: new) { moves[note] = moved }
        }
        guard !moves.isEmpty else { return }
        for note in before.notes {
            let now = moves[note] ?? note
            guard let text = try? Coordinated.read(now) else { continue }
            let rewritten = before.rewrite(text, of: note, movedTo: now, moves: moves)
            guard rewritten != text else { continue }
            do {
                try Coordinated.write(rewritten, to: now)
            } catch {
                NSLog("Quill: couldn't update links in \(now.path): \(error)")
                continue
            }
            NotificationCenter.default.post(name: Self.noteRewritten, object: self, userInfo: ["old": note, "new": now])
        }
    }

    /// Folders `item` can move to: not where it already is, and not into itself.
    func moveTargets(for item: URL) -> [(url: URL, depth: Int)] {
        folders.filter { $0.url != item.deletingLastPathComponent() && $0.url != item && !isInside($0.url, item) }
    }

    func delete(_ url: URL) {
        flushSave()
        do { try Coordinated.delete(url) } catch { return present(error) }
        reloadTree()
    }

    /// Has the file provider look over the whole library for changes it missed.
    func announceLibrary() {
        func urls(_ nodes: [FileNode]) -> [URL] { nodes.flatMap { [$0.url] + urls($0.children ?? []) } }
        let all = urls(tree)
        DispatchQueue.global(qos: .utility).async { Coordinated.announce(all) }
    }

    func focusEditor() {
        textView?.becomeFirstResponder()
    }

    // MARK: Private

    private func open(_ url: URL) {
        scopedRoot = url
        root = URL(fileURLWithPath: url.path, isDirectory: true)
        pages = []
        reloadTree()
    }

    private func libraryChosen() {
        defaults.set(true, forKey: "libraryChosen")
        choosingLibrary = false
        pages = []
        reloadTree()
    }

    private func renameEnded() {
        guard namingNewFile else { return }
        namingNewFile = false
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    private func rememberLocation() {
        defaults.set(pages.last?.url.path, forKey: "lastLocation")
    }

    /// Reopens the folder or document Quill was showing, with the folders above it.
    private func restoreLocation() {
        guard let path = defaults.string(forKey: "lastLocation") else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        let target = URL(fileURLWithPath: path, isDirectory: isDir.boolValue)
        guard isInside(target, root) else { return }
        var chain = [target]
        var dir = target.deletingLastPathComponent()
        while isInside(dir, root) {
            chain.insert(dir, at: 0)
            dir = dir.deletingLastPathComponent()
        }
        pages = chain.map(Page.init)
    }

    /// Follows a renamed or moved item with the screens showing it or anything inside it.
    private func relocate(_ old: URL, to new: URL) {
        for page in pages {
            if let moved = rebase(page.url, from: old, to: new) { page.url = moved }
        }
        // A screen for something moved out of the folder above it no longer fits the stack.
        // (Above a note there can be another note, followed from a link in it.)
        if let i = pages.indices.dropFirst().first(where: {
            pages[$0 - 1].url.hasDirectoryPath && !isInside(pages[$0].url, pages[$0 - 1].url)
        }) {
            pages.removeSubrange(i...)
        }
        if let first = pages.first, !isInside(first.url, root) { pages = [] }
        rememberLocation()
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
        errorMessage = error.localizedDescription
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: "rootBookmark")
        }
        return url
    }

    private static let welcomeText = """
    # Welcome to Quill

    Quill is a quiet place to write. Your documents are plain **Markdown** files, so they're yours forever. Find them in the Files app under On My iPhone › Quill.

    ## Focus

    Tap the eye to turn on _Focus Mode_. Everything except the sentence you're writing fades away. Choose between sentence and paragraph focus in the ⋯ menu.

    _Typewriter Scrolling_, also in the ⋯ menu, keeps the line you're writing in the middle of the screen.

    ## Library

    - Tap ✎ to start a new document
    - Touch and hold a document to rename, move, share or delete it
    - Tap a document's title to rename it
    - To write in the same files as Quill on your Mac, open the library settings and choose its folder in iCloud Drive

    Everything saves automatically.

    ## Markdown

    - The bar above the keyboard adds **bold**, _italic_, `code`, [links](https://example.com), headings and lists
    - With a keyboard: ⌘B, ⌘I, ⌘K, ⇧⌘C and ⇧⌘X

    > Lists continue when you press Return. Press Return on an empty item to end the list.

    """
}
