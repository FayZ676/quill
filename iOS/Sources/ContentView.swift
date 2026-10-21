import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack(path: $state.pages) {
            FolderView(url: state.root, isLibrary: true)
                .navigationDestination(for: Page.self) { PageView(page: $0) }
        }
        // onChange misses the first activation at launch.
        .task { state.announceLibrary() }
        .onChange(of: phase) { _, phase in
            if phase == .active {
                state.reloadTree()
                state.announceLibrary()
            } else {
                state.flushSave()
            }
        }
        .alert(state.namingNewFile ? "Name Your Document" : "Rename", isPresented: Binding(
            get: { state.renameTarget != nil },
            set: { if !$0 { state.cancelRename() } }
        )) {
            TextField("Name", text: $state.renameText)
            Button("Cancel", role: .cancel) { state.cancelRename() }
            Button(state.namingNewFile ? "Done" : "Rename") { state.commitRename() }
        }
        .confirmationDialog(state.deleteTarget.map { "Delete “\(name(of: $0))”?" } ?? "",
                            isPresented: Binding(get: { state.deleteTarget != nil },
                                                 set: { if !$0 { state.deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = state.deleteTarget { state.delete(target) }
            }
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { state.errorMessage != nil },
                                                       set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .sheet(isPresented: $state.choosingLibrary) {
            LibraryChoice().interactiveDismissDisabled()
        }
    }

    private func name(of url: URL) -> String {
        url.hasDirectoryPath ? url.lastPathComponent : FileNode.displayName(url)
    }
}

private struct PageView: View {
    @ObservedObject var page: Page

    var body: some View {
        if page.url.hasDirectoryPath {
            FolderView(url: page.url, isLibrary: false)
        } else {
            EditorScreen(page: page)
        }
    }
}

// MARK: Library

private struct FolderView: View {
    @EnvironmentObject var state: AppState
    let url: URL
    let isLibrary: Bool
    @State private var showingSettings = false

    var body: some View {
        let nodes = state.children(of: url)
        List {
            ForEach(nodes) { node in
                NavigationLink(value: Page(node.url)) {
                    Label {
                        HStack {
                            Text(node.name)
                                .lineLimit(1)
                                .foregroundStyle(state.syncStates[node.url] == .notDownloaded ? .secondary : .primary)
                            Spacer()
                            SyncBadge(sync: state.syncStates[node.url])
                        }
                    } icon: {
                        Image(systemName: node.isDirectory ? "folder" : "doc.text")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                    }
                }
                .contextMenu { ItemMenu(url: node.url) }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { state.deleteTarget = node.url }
                    Button("Rename", systemImage: "pencil") { state.beginRename(node.url) }
                }
                .listRowBackground(Color(uiColor: Theme.background))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: Theme.background).ignoresSafeArea())
        .refreshable { state.reloadTree() }
        // Back from the editor, the file just opened has downloaded.
        .onAppear { state.reloadTree() }
        .overlay {
            if nodes.isEmpty {
                if state.downloading > 0 && isLibrary {
                    ContentUnavailableView("Downloading from iCloud…", systemImage: "icloud.and.arrow.down")
                } else {
                    ContentUnavailableView("No Documents", systemImage: "doc.text",
                                           description: Text("Tap \(Image(systemName: "square.and.pencil")) to start writing."))
                }
            }
        }
        .navigationTitle(isLibrary ? state.libraryName : url.lastPathComponent)
        .toolbar {
            if isLibrary {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Folder", systemImage: "folder.badge.plus") { state.newFolder(in: url) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Document", systemImage: "square.and.pencil") { state.newFile(in: url) }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

/// Everything you can do to a document or folder, for its context menu and the editor's ⋯ menu.
private struct ItemMenu: View {
    @EnvironmentObject var state: AppState
    let url: URL

    var body: some View {
        Button("Rename", systemImage: "pencil") { state.beginRename(url) }
        Menu {
            ForEach(state.moveTargets(for: url), id: \.url) { folder in
                Button {
                    state.move(url, into: folder.url)
                } label: {
                    Text(String(repeating: "    ", count: max(0, folder.depth - 1))
                         + (folder.depth == 0 ? state.libraryName : folder.url.lastPathComponent))
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
        if !url.hasDirectoryPath {
            ShareLink(item: url)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { state.deleteTarget = url }
    }
}

/// Marks files iCloud hasn't brought to the device yet; downloaded files show nothing.
private struct SyncBadge: View {
    let sync: SyncState?

    var body: some View {
        Group {
            switch sync {
            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.tertiary)
                    .accessibilityLabel("Not downloaded")
            case .downloading:
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Downloading")
            case nil:
                EmptyView()
            }
        }
        .font(.footnote)
    }
}

// MARK: Editor

private struct EditorScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var page: Page
    @StateObject private var chrome = EditorChrome()

    var body: some View {
        EditorView(state: state, page: page, chrome: chrome)
            // The text runs up under the bars, so they can go without the page jumping:
            // UIKit folds their height into the scroll insets instead.
            .ignoresSafeArea(.container, edges: .top)
            .background(Color(uiColor: Theme.background).ignoresSafeArea())
            .toolbar(chrome.hidden ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(chrome.hidden)
            .overlay {
                if chrome.downloading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Downloading from iCloud").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        .navigationTitle(Binding(get: { FileNode.displayName(page.url) },
                                 set: { state.rename(page.url, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        // The title becomes a menu with Rename.
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    state.focusEnabled.toggle()
                } label: {
                    Image(systemName: state.focusEnabled ? "eye.fill" : "eye")
                }
                .accessibilityLabel("Focus Mode")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    ViewOptions()
                    ControlGroup {
                        Button("Smaller", systemImage: "textformat.size.smaller") {
                            state.fontSize = max(11, state.fontSize - 1)
                        }
                        Button("Bigger", systemImage: "textformat.size.larger") {
                            state.fontSize = min(32, state.fontSize + 1)
                        }
                    }
                    Divider()
                    ItemMenu(url: page.url)
                }
            }
        }
    }
}

// MARK: Settings

/// Writing options, shared by the editor's ⋯ menu and Settings.
private struct ViewOptions: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Toggle("Focus Mode", isOn: $state.focusEnabled)
        Picker("Focus On", selection: $state.focusStyle) {
            ForEach(FocusStyle.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        Toggle("Typewriter Scrolling", isOn: $state.typewriter)
        Picker("Font", selection: $state.editorFont) {
            ForEach(EditorFont.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder", value: state.isExternalLibrary ? state.root.lastPathComponent : "On My iPhone")
                    ChooseFolderButton(title: "Choose Folder…")
                    if state.isExternalLibrary {
                        Button("Use On My iPhone") { state.useLocalLibrary() }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("To write in the same files as Quill on your Mac, choose its library in iCloud Drive (Documents › Quill). Changes sync through iCloud.")
                }
                Section("Writing") {
                    ViewOptions()
                    Stepper("Text Size: \(Int(state.fontSize))", value: $state.fontSize, in: 11...32)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// First launch: where the writing lives.
private struct LibraryChoice: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Where's your writing?")
                .font(.title.bold())
            Text("Quill edits plain Markdown files in a folder. To share them with Quill on your Mac, choose its library in iCloud Drive: Documents › Quill.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            ChooseFolderButton(title: "Choose a Folder…")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Keep It on This iPhone") { state.useLocalLibrary() }
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}

private struct ChooseFolderButton: View {
    @EnvironmentObject var state: AppState
    let title: String
    @State private var picking = false

    var body: some View {
        Button(title) { picking = true }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): state.setRoot(url)
                case .failure(let error): state.errorMessage = error.localizedDescription
                }
            }
    }
}
