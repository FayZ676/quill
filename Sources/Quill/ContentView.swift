import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var sidebarShownForRename = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    /// The height of the window buttons' strip above Quill's bar; none in full screen.
    @State private var buttonStripHeight: CGFloat = 0
    /// Where the page is in the window, under the bars and beside the sidebar and terminal,
    /// for Go To and the cheat sheet to open in the middle of.
    @State private var page = CGRect.zero

    var body: some View {
        HStack(spacing: 0) {
            ActivityStrip(chrome: state.chrome)
            ZStack(alignment: .leading) {
                pageColumn
                    // The sidebar takes its room from the page.
                    .padding(.leading, state.sidebarShown ? sidebarWidth : 0)
                sidebar
            }
            .clipped()
        }
        // The strip's box, which takes in the sidebar as it comes out rather than the sidebar
        // having one of its own. Over both, so the sidebar slides out under its border.
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
                .frame(width: ActivityStrip.width + (state.sidebarShown ? sidebarWidth : 0))
                .frame(maxHeight: .infinity)
                .padding(Boxed.inset)
                .allowsHitTesting(false)
                .modifier(FadesWithChrome(chrome: state.chrome))
        }
        // With each box's own, as far from the window's edges as the boxes are from each other.
        .padding(Boxed.inset)
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
        // Over the page rather than the whole window, as the bars and sidebar would push them
        // off its middle.
        .searchPanel(isPresented: $state.goingTo, over: page) {
            PathPanel(prompt: "Type a document or folder", empty: "Nothing Matches", items: state.items,
                      pickAlternate: state.goTo) { state.openInNewTab($0) }
        }
        // From here rather than the button, so it opens just as Go To does.
        .searchPanel(isPresented: $state.showingCheatSheet, over: page) { CheatSheet() }
        .sheet(item: $state.newItem) { NewItemPanel(item: $0) }
        // Like iA Writer, the library slides away once you start typing and stays put
        // until you bring it back, and so does the terminal. A turn later, as `$hidden`
        // fires before `hidden` changes: sliding the sidebar right away redraws the bars
        // while they still read as shown, and they'd stay that way.
        .onReceive(state.chrome.$hidden) { hidden in
            guard hidden else { return }
            DispatchQueue.main.async {
                guard state.chrome.hidden else { return }
                if state.sidebarShown {
                    withAnimation { state.sidebarShown = false }
                }
                if state.terminalShown {
                    withAnimation { state.terminalShown = false }
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
            if target != nil { state.panel = .explorer }
            if target != nil, !state.sidebarShown {
                sidebarShownForRename = true
                withAnimation { state.sidebarShown = true }
            } else if target == nil, sidebarShownForRename {
                sidebarShownForRename = false
                withAnimation { state.sidebarShown = false }
            }
        }
    }

    /// The page, with its bar above and the terminal and status bar below.
    private var pageColumn: some View {
        VStack(spacing: 0) {
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
                }
            }
            .overlay(alignment: .topTrailing) {
                if !state.showingGraph {
                    FindBar(finder: state.finder).padding(12)
                }
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { page = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { page = $0 }
            })
            // A box of its own, as the bars have, whose border goes with theirs while you
            // write, leaving the words alone on the page.
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
                    .modifier(FadesWithChrome(chrome: state.chrome))
                    .allowsHitTesting(false)
            }
            .padding(Boxed.inset)
            // The bar at the bottom's box, which takes in the terminal as it opens rather than
            // the terminal having one of its own, as the strip's takes in the sidebar.
            VStack(spacing: 0) {
                // Always there, if folded away, so its shells keep running while it's closed.
                TerminalPane()
                // Under the page and the terminal, as in VS Code, but beside the sidebar, so it
                // runs the full width only when the sidebar is away.
                StatusBar(stats: state.stats, chrome: state.chrome)
            }
            .background(Color(nsColor: Theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
                    .modifier(FadesWithChrome(chrome: state.chrome))
                    .allowsHitTesting(false)
            }
            .padding(Boxed.inset)
        }
        // Gives way to the sidebar rather than pushing it off the window.
        .frame(minWidth: 0, maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .safeAreaInset(edge: .top, spacing: 0) {
            DetailBar().modifier(TitleBar(chrome: state.chrome, boxed: true))
        }
    }

    /// The sidebar: out beside the page, or away behind the strip.
    private var sidebar: some View {
        let shown = state.sidebarShown
        // Stacked rather than inset: the list scrolls under an inset and its top rows
        // would be stuck there.
        return VStack(spacing: 0) {
            // In the sidebar's box rather than one of its own: its controls are the panel's.
            PanelHeader().modifier(TitleBar(chrome: state.chrome))
                // Over the space the list leaves above its first row, so the rows sit close
                // under the buttons, which stay level with the page's bar. Rows scrolled up
                // go under it.
                .padding(.bottom, -10)
                .zIndex(1)
            switch state.panel {
            case .explorer: SidebarView()
            case .search: NoteSearchView(search: state.noteSearch)
            }
        }
        .background(SidebarAnchor())
        // Parts it from the strip's icons, set in from the box's ends, as the line between
        // Search's groups is set in from the sidebar's sides. In a row, so it stands upright.
        .overlay(alignment: .leading) {
            HStack(spacing: 0) { Divider() }.padding(.vertical, 14)
        }
        // Inside the strip's box, whose border is drawn over the two of them.
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .trailing) { SidebarEdge(width: $sidebarWidth) }
        .padding([.vertical, .trailing], Boxed.inset)
        .background(Color(nsColor: Theme.background))
        // Laid out at its full width and uncovered as it slides, so the list isn't laid
        // out again on every frame of the slide.
        .frame(width: sidebarWidth)
        .offset(x: shown ? 0 : -sidebarWidth - 20)
        .allowsHitTesting(shown)
        .onExitCommand { state.closeSidebar() }
    }
}

/// The writing column's half of Quill's bar, kept for tabs, as VS Code's is: Back and Forward,
/// small and fixed at its leading edge, then a tab for each note open. The page's other
/// controls are in the bar at the bottom.
private struct DetailBar: View {
    var body: some View {
        HStack(spacing: 8) {
            HistoryButtons()
            TabStrip()
        }
        .frame(minHeight: 30)
    }
}

/// The tabs open, from the leading edge, sharing the room between them once they fill it,
/// and a button for another at the trailing edge, across from Back and Forward. Drag a tab along to move it: it follows the pointer, and the
/// others slide out of its way.
private struct TabStrip: View {
    @EnvironmentObject var state: AppState
    /// Where each tab is along the strip.
    @State private var frames: [NoteTab.ID: CGRect] = [:]
    /// The tab being dragged, where on it it was taken, and where the pointer is now.
    @State private var drag: (id: NoteTab.ID, grab: CGFloat, x: CGFloat)?
    /// A note from the sidebar is held over the tabs.
    @State private var dropping = false

    var body: some View {
        // The one tab left with no note in it isn't shown: with nothing open, there are no tabs.
        let shown = state.tabs.count == 1 && state.tabs[0].note == nil ? [] : state.tabs
        HStack(spacing: 4) {
            ForEach(shown) { tab in
                // Well short of the bar's top and bottom: in a bar this low, a line the tabs'
                // height would look to touch its edges.
                if tab.id != shown.first?.id {
                    Divider().frame(height: 20)
                }
                TabItem(tab: tab, dragging: drag != nil, lifted: drag?.id == tab.id)
                    // Under the pointer, wherever the tabs have moved its place to.
                    .offset(x: drag.flatMap { $0.id == tab.id ? $0.x - $0.grab - (frames[tab.id]?.minX ?? 0) : nil } ?? 0)
                    // The tab's place, measured outside the offset: measured inside it, the
                    // offset would move the place it's worked out from, on and on, and hang.
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TabFrames.self, value: [tab.id: geometry.frame(in: .named("tabs"))])
                    })
                    .zIndex(drag?.id == tab.id ? 1 : 0)
                    // The others slide out of its way, but it stays with the pointer.
                    .transaction { if drag?.id == tab.id { $0.animation = nil } }
                    // Alongside the tab's clicks, which a drag's first few points don't cancel.
                    .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("tabs"))
                        .onChanged { moved(tab.id, $0) }
                        .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { drag = nil } })
            }
            Spacer(minLength: 0)
            Button(action: state.newTab) {
                Image(systemName: "plus").toolbarIcon()
            }
            .buttonStyle(.bare)
            .help("New Tab (\(Shortcuts.newTab.label))")
        }
        .coordinateSpace(name: "tabs")
        .onPreferenceChange(TabFrames.self) { frames = $0 }
        // A note dragged here from the sidebar opens in a new tab, anywhere along the tabs.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $dropping) { state.dropInTabs($0) }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(dropping ? 0.08 : 0)))
    }

    /// Follows the pointer with the dragged tab, and moves it to the place of the tab under it.
    private func moved(_ id: NoteTab.ID, _ value: DragGesture.Value) {
        if drag == nil {
            drag = (id, value.startLocation.x - (frames[id]?.minX ?? 0), value.location.x)
        }
        drag?.x = value.location.x
        guard let target = state.tabs.first(where: { $0.id != id && frames[$0.id]?.contains(CGPoint(x: value.location.x, y: frames[$0.id]!.midY)) == true }) else { return }
        // Where the dragged tab's place goes, ahead of its being measured there a frame on:
        // a frame with its offset worked out from the old place would flash the tab away.
        if let from = state.tabs.firstIndex(where: { $0.id == id }), let place = frames[id], let over = frames[target.id] {
            let rightward = state.tabs.firstIndex(where: { $0.id == target.id })! > from
            frames[id] = CGRect(x: rightward ? over.maxX - place.width : over.minX, y: place.minY,
                                width: place.width, height: place.height)
        }
        withAnimation(.easeInOut(duration: 0.15)) { state.moveTab(id, to: target.id) }
    }
}

private struct TabFrames: PreferenceKey {
    static var defaultValue: [NoteTab.ID: CGRect] = [:]
    static func reduce(value: inout [NoteTab.ID: CGRect], nextValue: () -> [NoteTab.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A tab: its note's name, bold while it's on show and dimmed while it isn't. Click it to go
/// to it, and click the one on show to rename its note. A close button comes up at its end
/// under the pointer.
private struct TabItem: View {
    @EnvironmentObject var state: AppState
    let tab: NoteTab
    /// A tab's being dragged, so the pointer passing over this one doesn't light it.
    let dragging: Bool
    /// This is the tab being dragged, which stays lit while it moves.
    let lifted: Bool
    @State private var hovering = false

    /// On show, with the graph not over it.
    private var current: Bool { tab.id == state.activeTab && !state.showingGraph }

    var body: some View {
        Group {
            if current, let note = tab.note {
                TitleField(file: note, inTab: true)
            } else {
                Text(tab.note.map(FileNode.displayName) ?? "New Tab")
                    .appFont(13)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(current ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { state.showTab(tab.id) }
            }
        }
        // As much room either side of the name, and more at the end, eased open, only while
        // the pointer is over the tab and its close button is there.
        .padding(.leading, 12)
        .padding(.trailing, hovering && !dragging ? 28 : 12)
        // As wide as its name, up to a cap past which the name is cut short; the bar's
        // height, less as much above and below as there is between two tabs.
        .frame(maxWidth: 180, minHeight: 40)
        .fixedSize(horizontal: true, vertical: false)
        // No plate to say which tab is on show, its bold name says so. A faint one under the
        // pointer shows how far the tab reaches, for its close button and for dragging it.
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity((hovering && !dragging) || lifted ? 0.1 : 0)))
        // Solid under that, in the bar's own color, so a tab dragged over another hides it.
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Theme.background)))
        .overlay(alignment: .trailing) {
            if hovering && !dragging {
                Button { state.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bare)
                .padding(.trailing, 5)
                .help("Close Tab (\(Shortcuts.closeTab.label))")
            }
        }
        .onHover { inside in
            // Eased, so the tabs beside it slide over for its close button rather than jump.
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside {
                state.hoveredTab = tab.id
            } else if state.hoveredTab == tab.id {
                state.hoveredTab = nil
            }
        }
        .contextMenu {
            Button("Close Tab") { state.closeTab(tab.id) }
            Button("Close Other Tabs") {
                for other in state.tabs where other.id != tab.id { state.closeTab(other.id) }
            }
        }
    }
}

/// Quill's bar, one half over each column, under the window buttons' strip in a window and
/// at the top of the screen in full screen.
private struct TitleBar: ViewModifier {
    @ObservedObject var chrome: ChromeFader
    /// In a box of its own, as the page's bar is; the sidebar's sits in the sidebar's box.
    var boxed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color(nsColor: Theme.background))
            .modifier(Boxed(on: boxed))
            .modifier(FadesWithChrome(chrome: chrome))
    }
}

/// A part of the window in a box of its own, as VS Code draws its bars: a rounded border all
/// the way round, set in from the parts beside it so no two touch.
struct Boxed: ViewModifier {
    var on = true
    /// Half the room between two boxes, which each take this much round them.
    static let inset: CGFloat = 2

    @ViewBuilder func body(content: Content) -> some View {
        if on {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            content
                .background(Color(nsColor: Theme.background))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
                .padding(Self.inset)
        } else {
            content
        }
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

/// Row icons in the accent color, as a split view's sidebar draws them.
private struct AccentIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(.tint)
        }
    }
}

private struct SidebarFocusedKey: EnvironmentKey { static let defaultValue = false }

private extension EnvironmentValues {
    /// You're typing in the sidebar, rather than the page or the terminal.
    var sidebarFocused: Bool {
        get { self[SidebarFocusedKey.self] }
        set { self[SidebarFocusedKey.self] = newValue }
    }
}

/// The sidebar's right edge, which its box draws: a handle over it that resizes the sidebar.
private struct SidebarEdge: View {
    @Binding var width: Double
    /// The width when the drag began.
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 1)
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

/// A strip of icons down the window's left edge, as VS Code's activity bar is: Explorer and
/// Search bring out their panel in the sidebar, and Graph shows the graph where the page goes.
/// Each is lit while it's showing, and a click on it again puts it away.
private struct ActivityStrip: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var chrome: ChromeFader
    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 6) {
            panel(.explorer, symbol: "doc.on.doc", help: "Explorer (\(Shortcuts.explorer.label))")
            panel(.search, symbol: "magnifyingglass", help: "Search (\(Shortcuts.search.label))")
            icon("point.3.connected.trianglepath.dotted", lit: state.showingGraph,
                 help: "\(state.showingGraph ? "Hide" : "Show") Graph (\(Shortcuts.graph.label))",
                 action: state.toggleGraph)
            Spacer()
        }
        // The first icon level with the buttons in Quill's bar.
        .padding(.top, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Its box is drawn over it and the sidebar both, so it can take the sidebar in.
        .padding(Boxed.inset)
        .modifier(FadesWithChrome(chrome: chrome))
    }

    private func panel(_ panel: SidebarPanel, symbol: String, help: String) -> some View {
        icon(symbol, lit: state.sidebarShown && state.panel == panel, help: help) { state.clickPanel(panel) }
    }

    private func icon(_ symbol: String, lit: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .toolbarIcon(width: 40)
                .frame(height: 36)
                .foregroundStyle(lit ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.bare)
        .help(help)
    }
}

/// The top of the sidebar: what the panel is, and its buttons.
private struct PanelHeader: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            switch state.panel {
            case .explorer:
                LibraryButton()
                Spacer()
                // Go To has no button: its magnifying glass would read as Search's, in the
                // strip beside it. It's ⌘P and in the File menu.
                new("doc", help: "New File (\(Shortcuts.newFile.label))") { state.newFile() }
                new("folder", help: "New Folder (\(Shortcuts.newFolder.label))") { state.newFolder() }
                // Closes every folder, as VS Code's Collapse Folders in Explorer does.
                Button { state.expanded = [] } label: {
                    Image(systemName: "rectangle.compress.vertical").toolbarIcon()
                }
                .buttonStyle(.bare)
                .disabled(state.expanded.isEmpty)
                .opacity(state.expanded.isEmpty ? 0.35 : 1)
                .help("Collapse All")
            case .search:
                Text("Search")
                    .appFont(13, bold: true)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minHeight: 30)
    }

    /// A document or folder with a plus at its bottom right, the same place on both, as VS
    /// Code draws them. The system's own badged symbols put the plus in different corners.
    private func new(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        // Cut out of the symbol under it, as a badge is.
                        .background(Circle().fill(Color(nsColor: Theme.background)).padding(-1.2))
                        .offset(x: 3, y: 2)
                }
                .frame(minWidth: 28, minHeight: 30)
        }
        .buttonStyle(.bare)
        .help(help)
    }
}

/// The library's name; click it to open another folder as the library.
private struct LibraryButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.chooseRoot() } label: {
            HStack(spacing: 4) {
                Text(state.root.lastPathComponent)
                    .appFont(13, bold: true)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Open Another Folder (\(Shortcuts.openFolder.label))")
    }
}

/// Tells AppState where the sidebar is in the window, to tell whether you're typing there.
private struct SidebarAnchor: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        state.sidebarView = view
    }
}

/// Back and Forward through the notes opened, as in a browser; faded when there's nowhere to go.
/// Close together, so they read as a pair.
private struct HistoryButtons: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            step("chevron.left", help: "Back (\(Shortcuts.back.label))", enabled: !state.backStack.isEmpty, state.goBack)
            step("chevron.right", help: "Forward (\(Shortcuts.forward.label))", enabled: !state.forwardStack.isEmpty, state.goForward)
        }
    }

    private func step(_ symbol: String, help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).toolbarIcon(width: 24)
        }
        .buttonStyle(.bare)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
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
                .pointingHandCursor()
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
    /// What ⌘Return does instead of `pick`.
    var pickAlternate: ((URL) -> Void)?
    let pick: (URL) -> Void

    private struct Found: Identifiable {
        let url: URL
        let path: String
        var id: URL { url }
    }

    var body: some View {
        SearchPanel(prompt: prompt, empty: empty, matches: matches, pick: { pick($0.url) },
                    pickAlternate: pickAlternate.map { open in { open($0.url) } }) { item in
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

/// Opens the ⋯ menu (see MoreMenu) over itself, as it's in the bar at the bottom.
private struct MoreButton: View {
    @EnvironmentObject var state: AppState
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = MoreMenu.make(state)
            // The point is where the menu's top left goes.
            let top = menu.size.height + 4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? -top : view.bounds.height + top), in: view)
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
    @State private var focused = false

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
            .background(SidebarFocus(focused: $focused))
            .environment(\.sidebarFocused, focused)
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
            // The note gone to from elsewhere (a tab, Go To, a link, Back), or a folder picked in
            // Go To once the folders above it have opened: in the middle at once, not scrolled to
            // the edge. One picked in the list itself stays where it was clicked or stepped to.
            .onChange(of: state.selection) { selection in
                guard let selection, !state.typingInSidebar else { return }
                DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) }
            }
            // Back from search, at the open note.
            .onAppear {
                if let selection = state.selection { DispatchQueue.main.async { proxy.scrollTo(selection, anchor: .center) } }
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
        } else {
            Button("Open in New Tab") { state.openInNewTab(url) }
            Divider()
        }
        Button("Add to Chat") { state.addToChat(url) }
        Divider()
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
    @Environment(\.sidebarFocused) private var sidebarFocused
    let node: FileNode
    @FocusState private var editing: Bool
    @State private var dropTargeted = false
    @State private var hovering = false

    private var symbol: String { node.isDirectory ? "folder" : "doc.text" }
    private var selected: Bool { state.selection == node.url }
    /// A faint fill, as a tab has, to show how far the row reaches: under the pointer, and on
    /// the picked row while the arrow keys move through the list.
    private var filled: Bool { hovering || (selected && sidebarFocused) }

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
                        // Picked out as the tab on show is: bold, the rest dimmed, no plate.
                        Text(node.name)
                            // Set on the row itself: the sidebar's own font would win over one
                            // inherited from the window.
                            .appFont(14, bold: selected)
                            .lineLimit(1)
                            .foregroundStyle(selected ? .primary
                                             : state.syncStates[node.url] == .notDownloaded ? .tertiary : .secondary)
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
        // For ⌘-click and the middle button to open it in a new tab.
        .onHover { inside in
            hovering = inside
            if inside {
                state.hoveredRow = node.url
            } else if state.hoveredRow == node.url {
                state.hoveredRow = nil
            }
        }
        // Dropping on a file files it next to that file, like Obsidian.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) {
            state.drop($0, into: node.isDirectory ? node.url : node.url.deletingLastPathComponent())
        }
        .background {
            if dropTargeted && node.isDirectory {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2)).padding(-4)
            }
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(filled ? 0.1 : 0))
                .padding(.horizontal, 10))
    }
}

/// Turns off AppKit's highlight of the sidebar's selected row, which `NodeRow` marks its own
/// way, and says whether you're typing in the sidebar.
private struct SidebarFocus: NSViewRepresentable {
    @Binding var focused: Bool

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ watcher: Watcher, context: Context) {
        watcher.changed = { focused = $0 }
        watcher.update()
    }

    final class Watcher: NSView {
        var changed: (Bool) -> Void = { _ in }
        private weak var list: NSOutlineView?
        private var focused: Bool?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder) { [weak self] _, _ in
                DispatchQueue.main.async { self?.update() }
            }
            DispatchQueue.main.async { [weak self] in self?.update() }
        }

        func update() {
            if list == nil {
                list = findList()
                // For ⇧⌘E to put you in it.
                if let list { DispatchQueue.main.async { AppState.shared.sidebarList = list } }
            }
            guard let list else { return }
            if list.selectionHighlightStyle != .none { list.selectionHighlightStyle = .none }
            let now = window?.firstResponder === list
            guard now != focused else { return }
            focused = now
            // Not while SwiftUI is updating the view.
            DispatchQueue.main.async { [self] in changed(now) }
        }

        /// The List's outline view: beside this view, under the nearest view above that holds one.
        private func findList() -> NSOutlineView? {
            var ancestor = superview
            while let view = ancestor {
                if let list = Self.outline(in: view) { return list }
                ancestor = view.superview
            }
            return nil
        }

        private static func outline(in view: NSView) -> NSOutlineView? {
            if let list = view as? NSOutlineView { return list }
            for child in view.subviews {
                if let list = outline(in: child) { return list }
            }
            return nil
        }
    }
}

/// The open file's name, centered in the title bar or in its tab; click it to rename the file.
private struct TitleField: View {
    @EnvironmentObject var state: AppState
    let file: URL
    var inTab = false
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
                    .pointingHandCursor()
                    .help("Click to rename")
            }
        }
        .appFont(inTab ? 13 : 15, bold: true)
        .frame(minWidth: inTab ? 0 : 160, maxWidth: inTab ? .infinity : 420)
        .onChange(of: file) { _ in editing = false }
    }

    private func finish(save: Bool) {
        editing = false
        if save { state.rename(file, to: text) }
        state.focusEditor()
    }
}

/// The page with no note open: start a note, or go to one, as VS Code's empty editor offers.
private struct EmptyEditor: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Text("Nothing open").appFont(17)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                choice("New Note", Shortcuts.newFile.label) { state.newFile() }
                choice("Go To Note", Shortcuts.goTo.label) { state.goingTo = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }

    private func choice(_ title: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        GridRow {
            Button(title, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .pointingHandCursor()
            Text(shortcut).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        }
        .appFont(15)
    }
}

/// A thin bar under the page, as in VS Code: the open note's length in the middle, and Focus,
/// the cheat sheet, the terminal and the ⋯ menu on the right.
private struct StatusBar: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var stats: Stats
    @ObservedObject var chrome: ChromeFader

    var body: some View {
        // As tall as the top bar, with its icons and its text's size, as the strip is wide.
        HStack(spacing: 6) {
            Spacer()
            // Moved down from the top bar, which is the tabs'.
            if !state.showingGraph { FocusToggle() }
            CheatSheetButton()
            TerminalButton()
            if !state.showingGraph { MoreButton() }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        // Centered under the page, whatever the buttons beside it.
        .overlay {
            if state.openFile != nil, !state.showingGraph {
                let minutes = max(1, Int((Double(stats.words) / 230).rounded()))
                Text("\(stats.words) words · \(minutes) min read")
                    .appFont(13)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: Theme.background))
        .modifier(FadesWithChrome(chrome: chrome))
    }
}

extension Image {
    /// The symbols in the strip and the bars, all one size, small enough to stay out of the way.
    /// `nudge` lifts a symbol whose pencil or badge pushes its body down, so the shapes
    /// line up by eye rather than by bounding box. A narrow symbol in a pair takes a
    /// narrower `width`, so the two sit close.
    func toolbarIcon(size: CGFloat = 15, nudge: CGFloat = 0, width: CGFloat = 28) -> some View {
        font(.system(size: size, weight: .regular))
            .offset(y: nudge)
            .frame(minWidth: width, minHeight: 30)
    }
}

/// Bar buttons as bare symbols on the page color: no bezel, no hover plate.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .pointingHandCursor()
    }
}

extension ButtonStyle where Self == BareButtonStyle {
    static var bare: BareButtonStyle { BareButtonStyle() }
}
