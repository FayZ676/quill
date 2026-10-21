import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var sidebarShownForRename = false
    @State private var fullScreen = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Stacked rather than inset: the list scrolls under an inset and its top rows
            // would be stuck there.
            VStack(spacing: 0) {
                if fullScreen {
                    HStack(spacing: 6) {
                        SidebarToggle(columns: $columns)
                        SidebarActions()
                        Spacer()
                    }
                    .modifier(FullScreenBar(chrome: state.chrome))
                }
                SidebarView(columns: $columns, showsActions: columns != .detailOnly && !fullScreen)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
            // The page color, not the translucent sidebar material, so the whole window
            // reads as one surface.
            .background(Color(nsColor: Theme.background).ignoresSafeArea())
        } detail: {
            ZStack(alignment: .bottom) {
                EditorView(state: state)
                if state.openFile == nil {
                    EmptyEditor()
                }
                WordCount(stats: state.stats, chrome: state.chrome)
            }
            .background(Color(nsColor: Theme.background).ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                if fullScreen {
                    DetailBar(columns: $columns).modifier(FullScreenBar(chrome: state.chrome))
                }
            }
            // Let the page color run up through the toolbar, so the faded title bar leaves no band.
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
        // Like iA Writer, the library slides away once you start typing and stays put
        // until you bring it back.
        .onReceive(state.chrome.$hidden) { hidden in
            if hidden && columns != .detailOnly {
                withAnimation { columns = .detailOnly }
            }
        }
        // Still names the window in the Window menu and Mission Control; the visible title
        // is the centered, renamable one below.
        .navigationTitle(state.openFile.map(FileNode.displayName) ?? "Quill")
        .modifier(HideSystemTitle())
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let file = state.openFile, !fullScreen { TitleField(file: file) }
            }
            .withoutGlass()
            ToolbarItemGroup {
                if !fullScreen { FocusToggle() }
            }
            .withoutGlass()
        }
        // A toolbar shares its bar with the window buttons, and in full screen they'd hide
        // together. So there the toolbar goes, macOS gives the window buttons their own bar
        // that drops down with the menu bar, and Quill's controls stay put in a bar of its own.
        // (SwiftUI's .toolbar(.hidden) would take the window buttons with it.)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) {
            ($0.object as? NSWindow)?.toolbar?.isVisible = false
            fullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) {
            ($0.object as? NSWindow)?.toolbar?.isVisible = true
            fullScreen = false
        }
        // Renaming happens in the sidebar, so bring it out for the occasion and put it
        // back afterwards.
        .onChange(of: state.renameTarget) { target in
            if target != nil, columns == .detailOnly {
                sidebarShownForRename = true
                withAnimation { columns = .all }
            } else if target == nil, sidebarShownForRename {
                sidebarShownForRename = false
                withAnimation { columns = .detailOnly }
            }
        }
    }
}

/// The writing column's half of the full-screen bar. The title centers over the text, like
/// the word count below it; the sidebar toggle moves here when the sidebar is away.
private struct DetailBar: View {
    @EnvironmentObject var state: AppState
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 6) {
            if columns == .detailOnly { SidebarToggle(columns: $columns) }
            Spacer()
            FocusToggle()
        }
        .overlay {
            if let file = state.openFile { TitleField(file: file) }
        }
    }
}

/// Quill's toolbar, drawn in the window for full screen, one half over each column.
private struct FullScreenBar: ViewModifier {
    @ObservedObject var chrome: ChromeFader

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color(nsColor: Theme.background))
            // Fades with the rest of the chrome while you write.
            .opacity(chrome.hidden ? 0 : 1)
            .animation(.easeInOut(duration: chrome.hidden ? 0.5 : 0.2), value: chrome.hidden)
            .allowsHitTesting(!chrome.hidden)
    }
}

/// Stands in for the system sidebar button, which can't be made bigger to match the others.
private struct SidebarToggle: View {
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        Button {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        } label: {
            Image(systemName: "sidebar.left").toolbarIcon()
        }
        .buttonStyle(.bare)
        .help("Show or Hide Sidebar (⌃⌘S)")
    }
}

/// Swaps the system sidebar button for SidebarToggle where macOS allows it (14 and later).
private struct OwnSidebarToggle: ViewModifier {
    @Binding var columns: NavigationSplitViewVisibility

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .navigation) { SidebarToggle(columns: $columns) }
                        .withoutGlass()
                }
        } else {
            content
        }
    }
}

private struct SidebarActions: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.newFile() } label: { Image(systemName: "square.and.pencil").toolbarIcon(nudge: -1) }
            .buttonStyle(.bare)
            .help("New File (⌘N)")
        Button { state.newFolder() } label: { Image(systemName: "folder.badge.plus").toolbarIcon(nudge: -1) }
            .buttonStyle(.bare)
            .help("New Folder (⇧⌘N)")
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

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Binding var columns: NavigationSplitViewVisibility
    /// The toolbar keeps a collapsed sidebar's items around, so they go when it does.
    let showsActions: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                TreeRows(nodes: state.tree)
            }
            .listStyle(.sidebar)
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
        }
        // Sits in the sidebar's half of the title bar, beside the sidebar toggle.
        .modifier(OwnSidebarToggle(columns: $columns))
        .toolbar {
            ToolbarItemGroup {
                if showsActions {
                    Spacer()
                    SidebarActions()
                }
            }
            .withoutGlass()
        }
        .overlay {
            if state.tree.isEmpty {
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
                Label(node.name, systemImage: symbol).lineLimit(1)
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
        .font(.system(size: 15, weight: .semibold))
        .frame(minWidth: 160, maxWidth: 420)
        .onChange(of: file) { _ in editing = false }
    }

    private func finish(save: Bool) {
        editing = false
        if save { state.rename(file, to: text) }
        state.focusEditor()
    }
}

/// Hides the left-aligned window title, which TitleField replaces.
private struct HideSystemTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.background(TitleHider())
        }
    }
}

private struct TitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hider() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Hider: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
}

private struct EmptyEditor: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Nothing open").font(.title2)
            Text("Press ⌘N to start writing").font(.title3).foregroundStyle(.secondary)
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
        Text("\(stats.words) words · \(minutes) min read")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: Theme.background), in: Capsule())
            .padding(.bottom, 12)
            .opacity(chrome.hidden ? 0 : 1)
            .animation(.easeInOut(duration: chrome.hidden ? 0.5 : 0.2), value: chrome.hidden)
            .allowsHitTesting(false)
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

private extension ToolbarContent {
    /// Drops the glass capsule macOS 26 puts behind toolbar items.
    @ToolbarContentBuilder
    func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
