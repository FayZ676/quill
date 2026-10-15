import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
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
        .navigationTitle(state.openFile.map(FileNode.displayName) ?? "Quill")
        .toolbar {
            ToolbarItemGroup {
                Button { state.focusEnabled.toggle() } label: {
                    Image(systemName: state.focusEnabled ? "eye.circle.fill" : "eye.circle")
                        .foregroundStyle(state.focusEnabled ? Color.accentColor : Color.secondary)
                }
                .help("Focus Mode (⇧⌘D)")
                Button { state.newFile() } label: { Image(systemName: "square.and.pencil") }
                    .help("New File (⌘N)")
            }
        }
        .alert("Rename", isPresented: Binding(get: { state.renameTarget != nil },
                                              set: { if !$0 { state.renameTarget = nil } })) {
            TextField("Name", text: $state.renameText)
            Button("Rename") { state.commitRename() }
            Button("Cancel", role: .cancel) { state.renameTarget = nil }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: $state.selection) {
            Section(state.root.lastPathComponent) {
                OutlineGroup(state.tree, children: \.children) { node in
                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                        .lineLimit(1)
                        .tag(node.url)
                        .contextMenu { menu(for: node) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if state.tree.isEmpty {
                Text("No documents").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        if node.isDirectory {
            Button("New File") { state.newFile(in: node.url) }
            Button("New Folder") { state.newFolder(in: node.url) }
            Divider()
        }
        Button("Rename…") { state.beginRename(node.url) }
        Button("Reveal in Finder") { state.reveal(node.url) }
        Divider()
        Button("Move to Trash") { state.trash(node.url) }
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
