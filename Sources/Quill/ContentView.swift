import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var sidebarShownForRename = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(showsActions: columns != .detailOnly)
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
                if let file = state.openFile { TitleField(file: file) }
            }
            ToolbarItemGroup {
                Button { state.focusEnabled.toggle() } label: {
                    Image(systemName: state.focusEnabled ? "eye.circle.fill" : "eye.circle")
                        .foregroundStyle(state.focusEnabled ? Color.accentColor : Color.secondary)
                }
                .help("Focus Mode (⇧⌘D)")
            }
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

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    /// The toolbar keeps a collapsed sidebar's items around, so they go when it does.
    let showsActions: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                Section(state.root.lastPathComponent) {
                    TreeRows(nodes: state.tree)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
        .toolbar {
            ToolbarItemGroup {
                if showsActions {
                    Spacer()
                    Button { state.newFile() } label: { Image(systemName: "square.and.pencil") }
                        .help("New File (⌘N)")
                    Button { state.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                        .help("New Folder (⇧⌘N)")
                }
            }
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
        .font(.system(size: 13, weight: .semibold))
        .frame(minWidth: 160, maxWidth: 360)
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
            Text("Nothing open").font(.title3)
            Text("Press ⌘N to start writing").foregroundStyle(.secondary)
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
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: Theme.background), in: Capsule())
            .padding(.bottom, 8)
            .opacity(chrome.hidden ? 0 : 1)
            .animation(.easeInOut(duration: chrome.hidden ? 0.5 : 0.2), value: chrome.hidden)
            .allowsHitTesting(false)
    }
}
