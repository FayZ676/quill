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
        VStack(spacing: 0) {
            // A folder is named in the bar, like a document, with a slash to mark it a folder.
            // The library needs no name.
            Header(title: isLibrary ? "" : url.lastPathComponent + " /",
                   titleAction: isLibrary ? nil : { state.beginRename(url) }) {
                if isLibrary {
                    BarButton("Settings", "gearshape") { showingSettings = true }
                } else {
                    BarButton("Back", "chevron.left") { state.goBack() }
                }
            } trailing: {
                BarButton("New Folder", "folder.badge.plus") { state.newFolder(in: url) }
                BarButton("New Document", "square.and.pencil") { state.newFile(in: url) }
            }
            list(nodes)
        }
        .background(Color(uiColor: Theme.background).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    private func list(_ nodes: [FileNode]) -> some View {
        List {
            rows(nodes)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: Theme.background).ignoresSafeArea())
        .refreshable { state.reloadTree() }
        // Back from the editor, the file just opened has downloaded.
        .onAppear { state.reloadTree() }
        .overlay {
            if nodes.isEmpty {
                // Their text set here: the view's own fonts would win over inherited ones.
                if state.downloading > 0 && isLibrary {
                    ContentUnavailableView {
                        Label { Text("Downloading from iCloud…").appFont(20, bold: true, relativeTo: .title3) }
                              icon: { Image(systemName: "icloud.and.arrow.down") }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("No Documents").appFont(20, bold: true, relativeTo: .title3) }
                              icon: { Image(systemName: "doc.text") }
                    } description: {
                        Text("Tap \(Image(systemName: "square.and.pencil")) to start writing.")
                            .appFont(17, relativeTo: .body)
                    }
                }
            }
        }
    }

    private func rows(_ nodes: [FileNode]) -> some View {
        ForEach(nodes) { node in
            // A plain button rather than a NavigationLink: no chevron, like the Mac sidebar.
            Button { state.pages.append(Page(node.url)) } label: {
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
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
                .background(PageColorRow())
            }
            .foregroundStyle(.primary)
            .contextMenu { ItemMenu(url: node.url) }
            .swipeActions {
                // Icons alone: with their names too, iOS pads them into wide, fat pills.
                Button("Delete", systemImage: "trash", role: .destructive) { state.deleteTarget = node.url }
                    .labelStyle(.iconOnly)
                    .tint(.red)
                Button("Rename", systemImage: "pencil") { state.beginRename(node.url) }
                    .labelStyle(.iconOnly)
                    .tint(.gray)
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// Gives a row the page color while keeping the rounded fill iOS draws behind a swiped row,
/// as in Messages. A SwiftUI row background would paint over that fill, so this sets the
/// list cell's own background instead.
private struct PageColorRow: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let v = view, !(v is UICollectionViewCell) { view = v.superview }
            guard let cell = view as? UICollectionViewCell else { return }
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listPlainCell().updated(for: state)
                if !state.isSwiped && !state.isHighlighted && !state.isSelected {
                    background.backgroundColor = Theme.background
                }
                cell.backgroundConfiguration = background
            }
            cell.setNeedsUpdateConfiguration()
        }
    }
}

/// Everything you can do to a document or folder, for its context menu in the library.
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

// MARK: Editor

private struct EditorScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var page: Page
    @StateObject private var chrome = EditorChrome()

    var body: some View {
        VStack(spacing: 0) {
            Header(title: FileNode.displayName(page.url), titleAction: { state.beginRename(page.url) }) {
                BarButton("Back", "chevron.left") { state.goBack() }
            } trailing: {
                BarButton("Focus Mode", state.focusEnabled ? "eye.fill" : "eye", active: state.focusEnabled) {
                    state.focusEnabled.toggle()
                }
                Menu {
                    OptionsMenu(url: page.url)
                } label: {
                    BarIcon(symbol: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("More")
            }
            // It fades but keeps its room, so the page doesn't jump.
            .opacity(chrome.hidden ? 0 : 1)
            .allowsHitTesting(!chrome.hidden)

            EditorView(state: state, page: page, chrome: chrome)
                .overlay {
                    if chrome.downloading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Downloading from iCloud").appFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .background(Color(uiColor: Theme.background).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The editor's ⋯ menu, laid out like the Mac app's: the same sections and options, as far
/// as iOS has them.
private struct OptionsMenu: View {
    @EnvironmentObject var state: AppState
    let url: URL

    var body: some View {
        Section("Focus") {
            Toggle("Focus Mode", isOn: $state.focusEnabled)
            Picker("Focus On", selection: $state.focusStyle) {
                ForEach(FocusStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Typewriter Scrolling", isOn: $state.typewriter)
        }
        Section("Font") {
            Picker("Typeface", selection: $state.editorFont) {
                ForEach(EditorFont.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Button("Smaller") { state.fontSize = max(11, state.fontSize - 1) }
            Button("Bigger") { state.fontSize = min(32, state.fontSize + 1) }
        }
        Section("Spelling and Grammar") {
            Toggle("Auto-Correction", isOn: $state.textInput.correctSpelling)
            Toggle("Check Spelling", isOn: $state.textInput.checkSpelling)
            Toggle("Predictive", isOn: $state.textInput.predictive)
            checkAll(TextInput.spelling)
        }
        Section("Substitutions") {
            Toggle("Smart Copy/Paste", isOn: $state.textInput.smartCopyPaste)
            Toggle("Smart Quotes", isOn: $state.textInput.smartQuotes)
            Toggle("Smart Dashes", isOn: $state.textInput.smartDashes)
            checkAll(TextInput.substitutions)
        }
        Section("File") {
            Button("Rename…") { state.beginRename(url) }
            Menu("Move To") {
                ForEach(state.moveTargets(for: url), id: \.url) { folder in
                    Button(String(repeating: "    ", count: max(0, folder.depth - 1))
                           + (folder.depth == 0 ? state.libraryName : folder.url.lastPathComponent)) {
                        state.move(url, into: folder.url)
                    }
                }
            }
            // Text alone: an icon would give the whole section an icon column, unlike the rest.
            ShareLink(item: url) { Text("Share…") }
        }
        Section {
            Button("Delete", role: .destructive) { state.deleteTarget = url }
        }
    }

    private func checkAll(_ group: TextInput.Group) -> some View {
        Button(state.textInput.allOn(group) ? "Uncheck All" : "Check All") { state.textInput.toggleAll(group) }
    }
}

// MARK: Header

/// A slim, flat bar in place of the navigation bar: controls at the edges, the title between.
private struct Header<Leading: View, Trailing: View>: View {
    var title = ""
    var titleAction: (() -> Void)? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
        }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) { leading }
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let titleAction {
                    Button(action: titleAction) { titleText }.buttonStyle(.plain)
                } else {
                    titleText
                }
            }
            .layoutPriority(1)
            HStack(spacing: 0) { trailing }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: 44)
    }

    private var titleText: some View {
        Text(title)
            .appFont(15, bold: true)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct BarIcon: View {
    let symbol: String
    /// Drawn in the accent while its mode is on, as the Mac app's focus eye is.
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct BarButton: View {
    let label: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    init(_ label: String, _ symbol: String, active: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) { BarIcon(symbol: symbol, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

// MARK: Settings

/// The Focus and Font sections, as in the Mac app's ⋯ menu: for the editor's ⋯ panel and
/// Settings.
private struct WritingSections: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section {
            Toggle("Focus Mode", isOn: $state.focusEnabled)
            LabeledContent("Focus On") {
                Picker("Focus On", selection: $state.focusStyle) {
                    ForEach(FocusStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Toggle("Typewriter Scrolling", isOn: $state.typewriter)
        } header: {
            Text("Focus").appFont(13, relativeTo: .footnote)
        }
        Section {
            LabeledContent("Typeface") {
                Picker("Typeface", selection: $state.editorFont) {
                    ForEach(EditorFont.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Stepper("Size: \(Int(state.fontSize))", value: $state.fontSize, in: 11...32)
        } header: {
            Text("Font").appFont(13, relativeTo: .footnote)
        }
    }
}

/// Spelling and typing aids, in iA Writer's order, grouped as on the Mac: for the editor's
/// ⋯ panel and Settings.
private struct TextInputSections: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section {
            Toggle("Auto-Correction", isOn: $state.textInput.correctSpelling)
            Toggle("Check Spelling", isOn: $state.textInput.checkSpelling)
            Toggle("Predictive", isOn: $state.textInput.predictive)
            toggleAll(TextInput.spelling)
        } header: {
            Text("Spelling and Grammar").appFont(13, relativeTo: .footnote)
        }
        Section {
            Toggle("Smart Copy/Paste", isOn: $state.textInput.smartCopyPaste)
            Toggle("Smart Quotes", isOn: $state.textInput.smartQuotes)
            Toggle("Smart Dashes", isOn: $state.textInput.smartDashes)
            toggleAll(TextInput.substitutions)
        } header: {
            Text("Substitutions").appFont(13, relativeTo: .footnote)
        }
    }

    private func toggleAll(_ group: TextInput.Group) -> some View {
        Button(state.textInput.allOn(group) ? "Uncheck All" : "Check All") { state.textInput.toggleAll(group) }
    }
}

private struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Settings") {
                EmptyView()
            } trailing: {
                // In line with the form's rows, clear of the sheet's rounded corner.
                Button("Done") { dismiss() }
                    .appFont(15, bold: true, relativeTo: .subheadline)
                    .padding(.horizontal, 16)
            }
            // Room above the bar, so it doesn't crowd the top of the sheet.
            .padding(.top, 8)
            Form {
                Section {
                    LabeledContent("Folder", value: state.isExternalLibrary ? state.root.lastPathComponent : "On My iPhone")
                    ChooseFolderButton(title: "Choose Folder…")
                    if state.isExternalLibrary {
                        Button("Use On My iPhone") { state.useLocalLibrary() }
                    }
                } header: {
                    // Headers and footers set here: the form's own fonts would win.
                    Text("Library").appFont(13, relativeTo: .footnote)
                } footer: {
                    Text("To write in the same files as Quill on your Mac, choose its library in iCloud Drive (Documents › Quill). Changes sync through iCloud.")
                        .appFont(13, relativeTo: .footnote)
                }
                WritingSections()
                TextInputSections()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
                .appFont(28, bold: true, relativeTo: .title)
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

/// With the navigation bar hidden, UIKit turns off the swipe back from the edge; this keeps it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
