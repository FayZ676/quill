import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var sidebarShownForRename = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    /// The height of the window buttons' strip above Quill's bar; none in full screen.
    @State private var buttonStripHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // Stacked rather than inset: the list scrolls under an inset and its top rows
            // would be stuck there.
            VStack(spacing: 0) {
                // In the sidebar, so they come and go with it. In the iPhone library's order.
                HStack(spacing: 6) {
                    GraphToggle()
                    Spacer()
                    GoToButton()
                    NewButton()
                }
                .modifier(TitleBar(chrome: state.chrome))
                BarDivider(chrome: state.chrome)
                SidebarView()
            }
            // Laid out at its full width and uncovered as it slides, so the list isn't laid
            // out again on every frame of the slide.
            .frame(width: sidebarWidth)
            .frame(width: state.sidebarShown ? sidebarWidth : 0, alignment: .trailing)
            .clipped()
            .overlay(alignment: .trailing) { SidebarEdge(width: $sidebarWidth) }

            ZStack(alignment: .bottom) {
                EditorView(state: state)
                // Over the editor rather than in its place, so the open document keeps its
                // caret and undo history for when you come back.
                if state.showingGraph {
                    GraphView(graph: state.graph, current: state.openFile, open: state.openNote)
                } else {
                    if state.openFile == nil {
                        EmptyEditor()
                    }
                    WordCount(stats: state.stats, chrome: state.chrome)
                }
            }
            // Gives way to the sidebar rather than pushing it off the window.
            .frame(minWidth: 0, maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    DetailBar().modifier(TitleBar(chrome: state.chrome))
                    BarDivider(chrome: state.chrome)
                }
            }
        }
        // The window buttons' strip: a shade darker than the page, with a line under it like
        // the one under Quill's bar. Over the content, as the editor reaches up under it; it
        // takes no clicks, so the strip still moves the window. Gives way to the page while
        // you write.
        .overlay(alignment: .top) {
            if buttonStripHeight > 0 {
                VStack(spacing: 0) {
                    Color(nsColor: Theme.titleBar).frame(height: buttonStripHeight)
                    Divider()
                }
                .modifier(FadesWithChrome(chrome: state.chrome))
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { buttonStripHeight = geometry.safeAreaInsets.top }
                .onChange(of: geometry.safeAreaInsets.top) { buttonStripHeight = $0 }
        })
        .background(Color(nsColor: Theme.background).ignoresSafeArea())
        .sheet(isPresented: $state.goingTo) {
            PathPanel(prompt: "Type a document or folder", empty: "Nothing Matches", items: state.items) { state.goTo($0) }
        }
        .sheet(item: $state.newItem) { NewItemPanel(item: $0) }
        // Like iA Writer, the library slides away once you start typing and stays put
        // until you bring it back. A turn later, as `$hidden` fires before `hidden` changes:
        // sliding the sidebar right away redraws the bars while they still read as shown,
        // and they'd stay that way.
        .onReceive(state.chrome.$hidden) { hidden in
            guard hidden else { return }
            DispatchQueue.main.async {
                if state.chrome.hidden && state.sidebarShown {
                    withAnimation { state.sidebarShown = false }
                }
            }
        }
        // The sidebar's buttons fade with the chrome, so a sidebar brought back from the
        // keyboard mid-sentence would come back without them.
        .onChange(of: state.sidebarShown) { shown in
            if shown { state.chrome.reveal() }
        }
        // Names the window in the Window menu and Mission Control; the visible title is the
        // centered, renamable one in Quill's bar.
        .navigationTitle(state.openFile.map(FileNode.displayName) ?? "Quill")
        // Renaming happens in the sidebar, so bring it out for the occasion and put it
        // back afterwards.
        .onChange(of: state.renameTarget) { target in
            if target != nil, !state.sidebarShown {
                sidebarShownForRename = true
                withAnimation { state.sidebarShown = true }
            } else if target == nil, sidebarShownForRename {
                sidebarShownForRename = false
                withAnimation { state.sidebarShown = false }
            }
        }
    }
}

/// The writing column's half of Quill's bar. The title centers over the text, like the word
/// count below it; the sidebar toggle sits at its leading edge.
private struct DetailBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            SidebarToggle()
            Spacer()
            if !state.showingGraph {
                FocusToggle()
                MoreButton()
            }
        }
        // Keeps the bar its height with the buttons gone.
        .frame(minHeight: 30)
        .overlay {
            if state.showingGraph {
                Text("Graph").appFont(15, bold: true)
            } else if let file = state.openFile {
                TitleField(file: file)
            }
        }
    }
}

/// Quill's bar, one half over each column, under the window buttons' strip in a window and
/// at the top of the screen in full screen.
private struct TitleBar: ViewModifier {
    @ObservedObject var chrome: ChromeFader

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color(nsColor: Theme.background))
            .modifier(FadesWithChrome(chrome: chrome))
    }
}

/// Fades with the rest of the chrome while you write.
private struct FadesWithChrome: ViewModifier {
    @ObservedObject var chrome: ChromeFader

    func body(content: Content) -> some View {
        content
            .opacity(chrome.hidden ? 0 : 1)
            .animation(.easeInOut(duration: chrome.hidden ? 0.5 : 0.2), value: chrome.hidden)
            .allowsHitTesting(!chrome.hidden)
    }
}

/// Row icons in the accent color, as a split view's sidebar draws them, and white on the
/// selected row.
private struct AccentIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            if #available(macOS 14.0, *) {
                Icon(icon: configuration.icon)
            } else {
                configuration.icon.foregroundStyle(.tint)
            }
        }
    }

    @available(macOS 14.0, *)
    private struct Icon: View {
        let icon: LabelStyleConfiguration.Icon
        @Environment(\.backgroundProminence) private var prominence

        var body: some View {
            icon.foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        }
    }
}

/// The sidebar's right edge: a line, and a handle a little wider than it that resizes the
/// sidebar.
private struct SidebarEdge: View {
    @Binding var width: Double
    /// The width when the drag began.
    @State private var dragStart: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // In window coordinates: the handle moves with the drag.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? width
                            dragStart = start
                            width = min(420, max(180, start + drag.translation.width))
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }
}

/// The line under the top bar, like the one beside the sidebar. Goes with the bar while you write.
private struct BarDivider: View {
    @ObservedObject var chrome: ChromeFader

    var body: some View {
        Divider()
            .opacity(chrome.hidden ? 0 : 1)
            .animation(.easeInOut(duration: chrome.hidden ? 0.5 : 0.2), value: chrome.hidden)
    }
}

private struct SidebarToggle: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            withAnimation { state.sidebarShown.toggle() }
        } label: {
            Image(systemName: "sidebar.left").toolbarIcon()
        }
        .buttonStyle(.bare)
        .help("Show or Hide Sidebar (⌃⌘S)")
    }
}

/// Drops down New File and New Folder.
private struct NewButton: View {
    @EnvironmentObject var state: AppState
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            NewMenu.make(state).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
        } label: {
            Image(systemName: "plus").toolbarIcon()
        }
        .buttonStyle(.bare)
        .background(MenuAnchorView(anchor: anchor))
        .help("New File or Folder")
    }
}

private struct GoToButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.goingTo = true } label: { Image(systemName: "magnifyingglass").toolbarIcon() }
            .buttonStyle(.bare)
            .help("Go To (⇧⌘O)")
    }
}

/// Names a new file or folder and says where it goes: the folder picked out in the sidebar,
/// to begin with, or any other, found by typing part of its path.
private struct NewItemPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let item: NewItem
    @State private var name = ""
    @State private var dir: URL
    @State private var choosingFolder = false
    @FocusState private var naming: Bool

    init(item: NewItem) {
        self.item = item
        _dir = State(initialValue: item.dir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.isFolder ? "New Folder" : "New File").appFont(15, bold: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").appFont(13).foregroundStyle(.secondary)
                TextField(item.placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .appFont(14)
                    .focused($naming)
                    .onSubmit(create)
                    .modifier(FieldBox(lit: naming))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Location").appFont(13).foregroundStyle(.secondary)
                Button { choosingFolder = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Color.accentColor)
                        Text(PathMatch.path(of: dir, in: state.root))
                            .appFont(14)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .modifier(FieldBox(lit: false))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose a Folder")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color(nsColor: Theme.background))
        .sheet(isPresented: $choosingFolder) {
            PathPanel(prompt: "Type a folder", empty: "No Matching Folder", items: state.folders.map(\.url)) { dir = $0 }
        }
        // Back from choosing a folder, the name is still to type.
        .onChange(of: choosingFolder) { choosing in if !choosing { naming = true } }
        .onAppear { naming = true }
    }

    private func create() {
        dismiss()
        state.create(item, named: name, in: dir)
    }
}

/// The New sheet's boxes: the name field and the location, alike so they line up.
private struct FieldBox: ViewModifier {
    /// Ringed in the accent, as a focused field is.
    let lit: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: lit ? 2 : 1))
    }
}

/// Finds a document or folder by typing part of its path.
private struct PathPanel: View {
    @EnvironmentObject var state: AppState
    let prompt: String
    let empty: String
    let items: [URL]
    let pick: (URL) -> Void

    private struct Found: Identifiable {
        let url: URL
        let path: String
        var id: URL { url }
    }

    var body: some View {
        SearchPanel(prompt: prompt, empty: empty, matches: matches, pick: { pick($0.url) }) { item in
            Label {
                Text(item.path)
                    .appFont(14)
                    .lineLimit(1)
                    .truncationMode(.head)
            } icon: {
                Image(systemName: item.url.hasDirectoryPath ? "folder" : "doc.text")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func matches(_ query: String) -> [Found] {
        PathMatch.filter(items.map { (url: $0, path: PathMatch.path(of: $0, in: state.root)) }, by: query)
            .map { Found(url: $0.url, path: $0.path) }
    }
}

/// Shows the graph of notes where the editor goes; lit while it's there, like the focus eye.
private struct GraphToggle: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.toggleGraph() } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .toolbarIcon()
                .foregroundStyle(state.showingGraph ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.bare)
        .help(state.showingGraph ? "Hide Graph (⌥⌘G)" : "Show Graph (⌥⌘G)")
    }
}

private struct FocusToggle: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.focusEnabled.toggle() } label: {
            Image(systemName: state.focusEnabled ? "eye.fill" : "eye")
                .toolbarIcon()
                .foregroundStyle(state.focusEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.bare)
        .help("Focus Mode (⇧⌘D)")
    }
}

/// Opens the ⋯ menu (see MoreMenu) under itself.
private struct MoreButton: View {
    @EnvironmentObject var state: AppState
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            MoreMenu.make(state).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
        } label: {
            Image(systemName: "ellipsis").toolbarIcon()
        }
        .buttonStyle(.bare)
        .background(MenuAnchorView(anchor: anchor))
        .help("More")
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                TreeRows(nodes: state.tree)
            }
            .listStyle(.sidebar)
            .labelStyle(AccentIcon())
            .scrollContentBackground(.hidden)
            // Roomy rows, like Finder's large sidebar setting, so files are easy to hit.
            .environment(\.sidebarRowSize, .large)
            // One menu for rows and the empty space around them, which gets library-wide actions.
            .contextMenu(forSelectionType: URL.self) { items in
                if let url = items.first {
                    itemMenu(url)
                } else {
                    Button("New File") { state.newFile(in: state.root) }
                    Button("New Folder") { state.newFolder(in: state.root) }
                    Divider()
                    Button("Collapse All Folders") { state.expanded = [] }
                        .disabled(state.expanded.isEmpty)
                    Button("Reveal Library in Finder") { state.reveal(state.root) }
                }
            }
            // Drops that miss every row land at the top of the library.
            .onDrop(of: [.fileURL], isTargeted: nil) { state.drop($0, into: state.root) }
            .onChange(of: state.renameTarget) { target in
                if let target { withAnimation { proxy.scrollTo(target) } }
            }
            // A folder picked in Go To, once the folders above it have opened.
            .onChange(of: state.selection) { selection in
                guard let selection else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(selection) } }
            }
            // A new file or folder gets its row once the library's rescan lands.
            .onChange(of: state.tree) { _ in
                if let target = state.renameTarget { withAnimation { proxy.scrollTo(target) } }
            }
        }
        .overlay {
            if state.tree.isEmpty && !state.loading {
                Text("No documents").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ url: URL) -> some View {
        if url.hasDirectoryPath {
            Button("New File") { state.newFile(in: url) }
            Button("New Folder") { state.newFolder(in: url) }
            Divider()
        }
        Button("Rename…") { state.beginRename(url) }
        Button("Reveal in Finder") { state.reveal(url) }
        Divider()
        Button("Move to Trash") { state.trash(url) }
    }
}

private struct TreeRows: View {
    @EnvironmentObject var state: AppState
    let nodes: [FileNode]

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: expansion(of: node.url)) {
                    TreeRows(nodes: children)
                } label: {
                    NodeRow(node: node)
                }
            } else {
                NodeRow(node: node)
            }
        }
    }

    private func expansion(of url: URL) -> Binding<Bool> {
        Binding(get: { state.expanded.contains(url) },
                set: { open in
                    if open { state.expanded.insert(url) } else { state.expanded.remove(url) }
                })
    }
}

private struct NodeRow: View {
    @EnvironmentObject var state: AppState
    let node: FileNode
    @FocusState private var editing: Bool
    @State private var dropTargeted = false

    private var symbol: String { node.isDirectory ? "folder" : "doc.text" }

    var body: some View {
        Group {
            if state.renameTarget == node.url {
                Label {
                    TextField("Name", text: $state.renameText)
                        .textFieldStyle(.plain)
                        .appFont(14)
                        .focused($editing)
                        .onSubmit { state.commitRename() }
                        .onExitCommand { state.cancelRename() }
                        .onAppear { DispatchQueue.main.async { editing = true } }
                        // Clicking away keeps the name typed so far, as in Finder.
                        .onChange(of: editing) { focused in
                            if !focused && state.renameTarget == node.url { state.commitRename() }
                        }
                } icon: {
                    Image(systemName: symbol)
                }
            } else {
                Label {
                    HStack {
                        Text(node.name)
                            // Set on the row itself: the sidebar's own font would win over one
                            // inherited from the window.
                            .appFont(14)
                            .lineLimit(1)
                            .foregroundStyle(state.syncStates[node.url] == .notDownloaded ? .secondary : .primary)
                        Spacer()
                        if state.syncStates[node.url] == nil {
                            if node.isDirectory {
                                ItemCount(count: node.children?.count).appFont(12)
                            }
                        } else {
                            SyncBadge(sync: state.syncStates[node.url])
                        }
                    }
                } icon: {
                    Image(systemName: symbol)
                }
            }
        }
        // Fill the row so drops anywhere along it count, not just over the name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(node.url)
        // itemProvider, not onDrag: onDrag swallows the clicks that select a List row.
        .itemProvider { NSItemProvider(object: node.url as NSURL) }
        // Dropping on a file files it next to that file, like Obsidian.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) {
            state.drop($0, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
        }
        .background {
            if dropTargeted && node.isDirectory {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2)).padding(-4)
            }
        }
    }
}

/// The open file's name, centered in the title bar; click it to rename the file.
private struct TitleField: View {
    @EnvironmentObject var state: AppState
    let file: URL
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { finish(save: true) }
                    .onExitCommand { finish(save: false) }
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) { if !$0 && editing { finish(save: true) } }
            } else {
                Text(FileNode.displayName(file))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        text = FileNode.displayName(file)
                        editing = true
                    }
                    .help("Click to rename")
            }
        }
        .appFont(15, bold: true)
        .frame(minWidth: 160, maxWidth: 420)
        .onChange(of: file) { _ in editing = false }
    }

    private func finish(save: Bool) {
        editing = false
        if save { state.rename(file, to: text) }
        state.focusEditor()
    }
}

private struct EmptyEditor: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Nothing open").appFont(17)
            Text("Press ⌘N to start writing").appFont(15).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }
}

private struct WordCount: View {
    @ObservedObject var stats: Stats
    @ObservedObject var chrome: ChromeFader

    var body: some View {
        let minutes = max(1, Int((Double(stats.words) / 230).rounded()))
        HStack(spacing: 8) {
            Text("\(stats.words) words · \(minutes) min read ·")
                .appFont(13)
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            CheatSheetButton()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: Theme.background), in: Capsule())
        .padding(.bottom, 12)
        .modifier(FadesWithChrome(chrome: chrome))
    }
}

private extension Image {
    /// Toolbar symbols at a size that's easy to see and hit; the stock ones are tiny.
    /// `nudge` lifts a symbol whose pencil or badge pushes its body down, so the shapes
    /// line up by eye rather than by bounding box.
    func toolbarIcon(nudge: CGFloat = 0) -> some View {
        font(.system(size: 20, weight: .regular))
            .offset(y: nudge)
            .frame(minWidth: 34, minHeight: 30)
    }
}

/// Bar buttons as bare symbols on the page color: no bezel, no hover plate.
private struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

private extension ButtonStyle where Self == BareButtonStyle {
    static var bare: BareButtonStyle { BareButtonStyle() }
}
