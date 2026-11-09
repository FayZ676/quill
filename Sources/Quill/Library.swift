import AppKit
import CoreServices
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()
    static let defaultFontSize = Fonts.defaultSize
    static let defaultTerminalFontSize = 13.0

    private let defaults = UserDefaults.standard

    @Published private(set) var root: URL
    @Published private(set) var tree: [FileNode] = []
    /// The library's first scan hasn't landed yet.
    @Published private(set) var loading = true
    /// Files iCloud hasn't brought to this Mac yet.
    @Published private(set) var syncStates: [URL: SyncState] = [:]
    @Published var selection: URL? { didSet { if selection != oldValue { selectionChanged() } } }
    /// The tabs open, in order, never none. Each note is open in one tab at most.
    @Published private(set) var tabs: [NoteTab] { didSet { saveTabs() } }
    /// The tab on show.
    @Published private(set) var activeTab: NoteTab.ID { didSet { saveTabs() } }
    /// The tab, or the sidebar row, under the pointer: what a middle-click acts on.
    var hoveredTab: NoteTab.ID?
    var hoveredRow: URL?
    /// The graph of notes stands in for the editor.
    @Published private(set) var showingGraph = false
    /// The note opening is a step back or forward, not a new place in the history.
    private var steppingHistory = false
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

    /// Whether the sidebar is out beside the page. Animate changes so it slides.
    @Published var sidebarShown = true
    /// What the sidebar shows.
    @Published var panel = SidebarPanel.explorer
    /// Installed by the sidebar: the view it's drawn in, to tell whether you're typing there.
    weak var sidebarView: NSView?
    /// Installed by the explorer: its list, for ⇧⌘E to put you in.
    weak var sidebarList: NSOutlineView? { didSet { if wantsList { enterPanel() } } }
    /// ⇧⌘E came before the explorer's list was in the window.
    private var wantsList = false
    /// Counts the times search's box was asked for, for the box to take the caret.
    @Published private(set) var searchFocus = 0
    /// Searching the text of every note, from the sidebar.
    let noteSearch = NoteSearch()
    /// Where in a note just opened from search the caret goes, for the editor to show.
    var pendingRange: NSRange?
    /// The Go To panel, for finding a document or folder by its path.
    @Published var goingTo = false
    /// The cheat sheet of shortcuts and Markdown, opened from the button in the bar at the bottom or ⌘/.
    @Published var showingCheatSheet = false
    /// The terminal under the page. Animate changes so it slides.
    @Published var terminalShown = false
    /// The terminal shows the library's shell, rather than the open note's.
    @Published var terminalOnLibrary = false
    /// Types a file or folder's path at the prompt of the shell on show; set by the terminal.
    var mentionInTerminal: (URL) -> Void = { _ in }
    /// What a new shell in the terminal starts on its own.
    @Published var terminalAgent: TerminalAgent {
        didSet { defaults.set(terminalAgent.rawValue, forKey: "terminalAgent") }
    }
    /// The terminal's text size, apart from the page's.
    @Published var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") }
    }
    /// The file or folder the New sheet is naming and placing.
    @Published var newItem: NewItem?
    @Published var renameTarget: URL?
    @Published var renameText = ""
    /// Folders open in the sidebar.
    @Published var expanded: Set<URL> { didSet { defaults.set(expanded.map(\.path), forKey: "expanded") } }

    /// Kept separate so per-keystroke word counts don't re-render the sidebar.
    let stats = Stats()
    /// Find and replace in the open note.
    let finder = Finder()
    let chrome = ChromeFader()
    private var recents: Recents
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
        editorFont = EditorFont(saved: defaults.string(forKey: "editorFont"))
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        textInput = TextInput.load(defaults)
        terminalAgent = TerminalAgent(rawValue: defaults.string(forKey: "terminalAgent") ?? "") ?? .claude
        let terminalSize = defaults.double(forKey: "terminalFontSize")
        terminalFontSize = terminalSize > 0 ? terminalSize : Self.defaultTerminalFontSize
        expanded = Set((defaults.stringArray(forKey: "expanded") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) })
        // The tabs open when Quill last quit, on this Mac alone; or the note open before there
        // were tabs.
        let saved = defaults.stringArray(forKey: "tabs") ?? defaults.string(forKey: "lastFile").map { [$0] } ?? []
        var restored = saved.compactMap { path -> NoteTab? in
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return NoteTab(note: URL(fileURLWithPath: path, isDirectory: false))
        }
        if restored.isEmpty { restored = [NoteTab()] }
        tabs = restored
        activeTab = restored[min(max(defaults.integer(forKey: "activeTab"), 0), restored.count - 1)].id

        let root = if let path = defaults.string(forKey: "root"), FileManager.default.fileExists(atPath: path) {
            URL(fileURLWithPath: path, isDirectory: true)
        } else {
            Self.createDefaultLibrary()
        }
        self.root = root
        recents = Recents(root: root, defaults: defaults)
        startRecents()
        startWatching()
        reloadTree()
        // A Mac in iCloud Drive doesn't always bring down a changed file it hasn't been using.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.recents.reload() }

        defaults.removeObject(forKey: "lastFile")
        if let url = openFile {
            selection = url
            expandAncestors(of: url)
        }
        saveTabs()
    }

    var currentItem: URL? { selection ?? openFile }

    private var active: Int { tabs.firstIndex { $0.id == activeTab } ?? 0 }

    /// The note in the tab on show.
    private(set) var openFile: URL? {
        get { tabs[active].note }
        set { tabs[active].note = newValue }
    }
    /// The notes opened before the open one in its tab, the latest last, for Back; and the ones
    /// gone back from, for Forward. As in a browser, opening a note clears Forward.
    private(set) var backStack: [URL] {
        get { tabs[active].back }
        set { tabs[active].back = newValue }
    }
    private(set) var forwardStack: [URL] {
        get { tabs[active].forward }
        set { tabs[active].forward = newValue }
    }

    private var targetDirectory: URL {
        guard let s = selection else { return root }
        return s.hasDirectoryPath ? s : s.deletingLastPathComponent()
    }

    // MARK: Library

    /// Rescans the library in the background; the tree and everything built from it update
    /// when the scan lands. A large library (an Obsidian vault, say) takes a while to walk,
    /// and the folder watcher asks for a scan on every save, so this never holds up typing.
    func reloadTree() {
        closeTabs { !FileManager.default.fileExists(atPath: $0.path) }
        recents.reload()
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
        closeTabs { !isInside($0, root) }
        for i in tabs.indices {
            tabs[i].back = []
            tabs[i].forward = []
        }
        selection = openFile
        startRecents()
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
    func openLink(_ target: String, inNewTab: Bool = false) {
        flushSave()
        pendingHeading = LinkResolver.heading(in: target)
        // `[[#Heading]]` points into this note.
        if LinkResolver.split(target).name.isEmpty { return showPendingHeading() }
        if let url = links.resolve(target, from: openFile) {
            if url == openFile { return showPendingHeading() }
            return inNewTab ? openInNewTab(url) : openNote(url)
        }
        guard let url = links.newNote(for: target) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
        } catch { return present(error) }
        pendingHeading = nil
        reloadTree()
        expandAncestors(of: url)
        if inNewTab { openInNewTab(url) } else { openNote(url) }
    }

    /// Opens a note, ready to write in.
    func openNote(_ url: URL) {
        selection = url
        DispatchQueue.main.async { [weak self] in self?.focusEditor() }
    }

    // MARK: Tabs

    /// Opens a note in a tab of its own, after the one you're on, or goes to the tab it's
    /// already open in. A folder is picked out in the sidebar, as Go To does.
    func openInNewTab(_ url: URL) {
        guard !url.hasDirectoryPath else { return goTo(url) }
        if let tab = tabs.first(where: { $0.note == url }) { return showTab(tab.id) }
        // An empty tab, as ⌘T leaves, takes the note rather than another tab opening beside it.
        if openFile == nil { return openNote(url) }
        let tab = NoteTab(note: url)
        tabs.insert(tab, at: active + 1)
        showTab(tab.id)
    }

    /// An empty tab after the one you're on, with Go To open to pick its note.
    func newTab() {
        let tab = NoteTab()
        tabs.insert(tab, at: active + 1)
        showTab(tab.id, focus: false)
        goingTo = true
    }

    /// Shows a tab's note where it was left, ready to write in, or with the caret left where
    /// it is (in the sidebar, say) without `focus`.
    func showTab(_ id: NoteTab.ID, focus: Bool = true) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if id != activeTab {
            flushSave()
            activeTab = id
        }
        showingGraph = false
        selection = openFile
        if let open = openFile {
            recents.viewed(open)
            expandAncestors(of: open)
        }
        if focus { DispatchQueue.main.async { [weak self] in self?.focusEditor() } }
    }

    /// The next tab along, or the one before with a negative `step`, wrapping around.
    func stepTab(_ step: Int) {
        guard tabs.count > 1 else { return }
        showTab(tabs[(active + step + tabs.count) % tabs.count].id)
    }

    /// The tab at a place along the bar, from 0; past the end goes to the last, so ⌘9 always
    /// does, as in Safari.
    func showTab(at index: Int) {
        guard tabs.count > 1 else { return }
        showTab(tabs[min(index, tabs.count - 1)].id)
    }

    /// Closes a tab, going to the one after it, or before it at the end. The last tab stays.
    func closeTab(_ id: NoteTab.ID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        // The pointer leaving a tab that's gone isn't always heard.
        if hoveredTab == id { hoveredTab = nil }
        guard id == activeTab else {
            tabs.remove(at: i)
            return
        }
        flushSave()
        let next = tabs[i + 1 < tabs.count ? i + 1 : i - 1].id
        activeTab = next
        tabs.remove(at: i)
        showTab(next)
    }

    /// Puts a dragged tab where another one is.
    func moveTab(_ id: NoteTab.ID, to target: NoteTab.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    /// Closes the tabs on notes that are gone, and takes them out of every tab's history.
    /// The last tab stays, with nothing open.
    private func closeTabs(on gone: (URL) -> Bool) {
        for i in tabs.indices {
            tabs[i].back.removeAll(where: gone)
            tabs[i].forward.removeAll(where: gone)
        }
        for tab in tabs where tab.note.map(gone) == true {
            if tabs.count > 1 {
                closeTab(tab.id)
            } else {
                openFile = nil
            }
        }
    }

    private func saveTabs() {
        defaults.set(tabs.map { $0.note?.path ?? "" }, forKey: "tabs")
        defaults.set(active, forKey: "activeTab")
    }

    // MARK: History

    func goBack() { step(from: \.backStack, to: \.forwardStack) }
    func goForward() { step(from: \.forwardStack, to: \.backStack) }

    /// Opens the latest note in one list, leaving the open one at the end of the other.
    private func step(from: ReferenceWritableKeyPath<AppState, [URL]>, to: ReferenceWritableKeyPath<AppState, [URL]>) {
        // Notes deleted since, and notes open in other tabs, are skipped.
        while let url = self[keyPath: from].popLast() {
            guard url != openFile, FileManager.default.fileExists(atPath: url.path),
                  !tabs.contains(where: { $0.note == url }) else { continue }
            if let open = openFile { self[keyPath: to].append(open) }
            steppingHistory = true
            openNote(url)
            steppingHistory = false
            return
        }
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

    func newFile(in dir: URL? = nil) { newItem = NewItem(isFolder: false, dir: dir ?? targetDirectory) }

    func newFolder(in dir: URL? = nil) { newItem = NewItem(isFolder: true, dir: dir ?? targetDirectory) }

    /// Makes the New sheet's file or folder, named `typed`, in `dir`, and picks it out in the
    /// sidebar. A file opens, ready to write in.
    func create(_ item: NewItem, named typed: String, in dir: URL) {
        let name = item.fileName(typed)
        let url = uniqueURL(in: dir, base: name.base, ext: name.ext, isDirectory: item.isFolder)
        do {
            if item.isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url)
            }
        } catch { return present(error) }
        reloadTree()
        expandAncestors(of: url)
        selection = url
        guard !item.isFolder else { return }
        // Once the sheet has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.focusEditor() }
    }

    func beginRename(_ url: URL) {
        renameText = url.hasDirectoryPath ? url.lastPathComponent : FileNode.displayName(url)
        renameTarget = url
    }

    func cancelRename() {
        guard renameTarget != nil else { return }
        renameTarget = nil
    }

    func commitRename() {
        guard let old = renameTarget else { return }
        renameTarget = nil
        rename(old, to: renameText)
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

    /// Every folder and document in the library: the notes opened most recently first, then
    /// the rest depth-first, the library itself first.
    var items: [URL] {
        func walk(_ nodes: [FileNode]) -> [URL] { nodes.flatMap { [$0.url] + walk($0.children ?? []) } }
        return recents.ordered([root] + walk(tree))
    }

    /// Opens a document, or picks out a folder in the sidebar with the folders above it open.
    func goTo(_ url: URL) {
        guard url.hasDirectoryPath else { return openNote(url) }
        panel = .explorer
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
        if let sel = selection, isInside(sel, url) || sel == url { selection = nil }
        closeTabs { $0 == url || isInside($0, url) }
        reloadTree()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Points the agent in the terminal at a note or folder, as `@path` at its prompt, for
    /// you to finish the question. Opens the terminal if it's hidden.
    func addToChat(_ url: URL) {
        withAnimation { terminalShown = true }
        mentionInTerminal(url)
    }

    func focusEditor() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Opens a note from search with the caret on the match, as found in its text then.
    func openMatch(_ url: URL, at range: NSRange) {
        if url == openFile, let tv = textView {
            if NSMaxRange(range) <= (tv.string as NSString).length {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
            }
        } else {
            pendingRange = range
        }
        openNote(url)
    }

    // MARK: Sidebar

    /// The panel's key, ⇧⌘E or ⇧⌘F: brings it out and puts you in it, or, when you're
    /// already in it, puts it away and you back on the page.
    func togglePanel(_ panel: SidebarPanel) {
        if sidebarShown, self.panel == panel, typingInSidebar { return closeSidebar() }
        showPanel(panel)
    }

    /// A click on the panel's icon in the strip: out, or away when it's out already.
    func clickPanel(_ panel: SidebarPanel) {
        if sidebarShown, self.panel == panel { return closeSidebar() }
        showPanel(panel)
    }

    /// Puts the sidebar away and you back on the page, as Escape in it does.
    func closeSidebar() {
        withAnimation { sidebarShown = false }
        focusEditor()
    }

    private func showPanel(_ panel: SidebarPanel) {
        self.panel = panel
        withAnimation { sidebarShown = true }
        // Once a panel just switched to is in the window.
        DispatchQueue.main.async { [weak self] in self?.enterPanel() }
    }

    private func enterPanel() {
        switch panel {
        case .explorer:
            guard let list = sidebarList, let window = list.window else { return wantsList = true }
            wantsList = false
            window.makeFirstResponder(list)
        case .search:
            searchFocus += 1
        }
    }

    /// You're typing in the sidebar, in its list or its search box, rather than the page,
    /// the terminal or a box over the page.
    var typingInSidebar: Bool {
        guard let sidebar = sidebarView, let window = sidebar.window,
              let responder = window.firstResponder as? NSView, responder !== textView else { return false }
        // What shows of it: a long list runs far past the sidebar.
        let at = responder.convert(responder.visibleRect, to: nil)
        return sidebar.convert(sidebar.bounds, to: nil).contains(CGPoint(x: at.midX, y: at.midY))
    }

    // MARK: Private

    private func expandAncestors(of url: URL) {
        var folders: [URL] = []
        var dir = url.deletingLastPathComponent()
        while isInside(dir, root) {
            folders.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        expanded.formUnion(folders)
    }

    /// Follows a renamed or moved item with the tabs, selection and open folders.
    private func relocate(_ old: URL, to new: URL) {
        let moved = { [self] (url: URL) in rebase(url, from: old, to: new) ?? url }
        for i in tabs.indices {
            tabs[i].note = tabs[i].note.map(moved)
            tabs[i].back = tabs[i].back.map(moved)
            tabs[i].forward = tabs[i].forward.map(moved)
        }
        if let sel = selection, let moved = rebase(sel, from: old, to: new) { selection = moved }
        expanded = Set(expanded.map { rebase($0, from: old, to: new) ?? $0 })
        recents.relocate { [self] in rebase($0, from: old, to: new) }
    }

    private func selectionChanged() {
        guard let url = selection, !url.hasDirectoryPath else { return }
        // Picking a note, even the one that was open, leaves the graph for the editor.
        showingGraph = false
        recents.viewed(url)
        guard url != openFile else { return }
        // A note open in another tab is shown there, not opened twice.
        if let tab = tabs.first(where: { $0.note == url }) { return showTab(tab.id, focus: false) }
        flushSave()
        if !steppingHistory {
            if let open = openFile { backStack.append(open) }
            forwardStack = []
        }
        openFile = url
        // Shows where the note lives, as VS Code's explorer does; the sidebar scrolls to it.
        expandAncestors(of: url)
    }

    /// Shares the notes opened most recently with every device using this library, and
    /// opens here a note just opened on another of them.
    private func startRecents() {
        if recents.root != root { recents = Recents(root: root, defaults: defaults) }
        recents.follow = { [weak self] note in
            guard let self, FileManager.default.fileExists(atPath: note.path) else { return false }
            if note != self.openFile || self.showingGraph { self.openNote(note) }
            return true
        }
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

    Quill is a quiet place to write. Your documents are plain **Markdown** files in a folder on your Mac, so they're yours forever. Everything saves automatically.

    Press ⌘/ at any time for every shortcut and all the Markdown, or click ⌘ in the bar at the bottom.

    ## Focus

    Press ⇧⌘D to turn on _Focus Mode_. Everything except the sentence you're writing fades away. Choose between sentence and paragraph focus in the View menu.

    Press ⇧⌘T for _Typewriter Scrolling_, which keeps the line you're writing in the middle of the screen.

    ## Getting Around

    - ⌘P jumps to any document or folder as you type part of its name, the ones you opened last first
    - ⌃- and ⌃⇧- go back and forward through the documents you've opened
    - ⌘T opens a new tab, and ⌘-clicking a document in the library opens it in one
    - ⇧⌘E shows or hides the library, where you can drag files to move them or right-click one for more
    - ⇧⌘F searches the names and text of every document
    - ⌘F finds and ⌥⌘F replaces text in the document you're on
    - ⌘N creates a new document, and ⌘O picks a different folder as your library

    ## Links

    Type `[[` to link to another document, picking it from the list that appears. ⌘-click a link to open it; a link to a document you haven't written yet creates it. Renaming or moving a document updates the links to it. ⇧⌘G shows all your documents and the links between them as a graph.

    ## Writing with AI

    Press ⌘` to open a terminal under the page. It starts Claude Code or Codex in the open document's folder and tells it which document you're on, so you can ask it to edit, research or reorganize. Switch it to your whole library at the top of the pane, and right-click a document in the library and choose _Add to Chat_ to bring it into the conversation.

    ## Make It Yours

    Choose Light or Dark appearance and a Sans, Serif or Mono typeface from the View menu. ⌘= and ⌘- change the text size.

    > Lists continue when you press Return. Press Return on an empty item to end the list.

    """
}

/// A place to write in: a note, and the notes opened there before and after it, for Back and
/// Forward. Each tab keeps its own, as a browser's do.
struct NoteTab: Identifiable, Equatable {
    let id = UUID()
    var note: URL?
    var back: [URL] = []
    var forward: [URL] = []
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
