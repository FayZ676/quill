import AppKit
import Sparkle
import SwiftUI

@main
struct QuillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared
    // Checks the release feed daily (see SUFeedURL in Info.plist) and offers to install.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                       userDriverDelegate: nil)

    var body: some Scene {
        Window("Quill", id: "main") {
            ContentView()
                .environmentObject(state)
                // All of Quill's own text in the chosen font, not just the page.
                .environment(\.editorFont, state.editorFont)
                .appFont(13)
                .tint(Color(nsColor: Theme.accent))
                .frame(minWidth: 640, minHeight: 420)
        }
        // No title (Quill's bar has its own) and no title bar fill: the window buttons sit in
        // a strip of the page above Quill's bar.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            QuillCommands(state: state)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Fonts.registerBundled()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppState.shared.openExternal(url) }
    }
}

struct QuillCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { state.newFile() }
                .keyboardShortcut("n")
            Button("New Folder") { state.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Folder…") { state.chooseRoot() }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { state.flushSave() }
                .keyboardShortcut("s")
            Button("Rename…") { state.currentItem.map(state.beginRename) }
                .disabled(state.currentItem == nil)
            Button("Reveal in Finder") { state.currentItem.map(state.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.currentItem == nil)
            Divider()
            Button("Move to Trash") { state.currentItem.map(state.trash) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(state.currentItem == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { state.textView?.toggleWrap("**") }
                .keyboardShortcut("b")
            Button("Italic") { state.textView?.toggleWrap("_") }
                .keyboardShortcut("i")
            Button("Strikethrough") { state.textView?.toggleWrap("~~") }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Inline Code") { state.textView?.toggleWrap("`") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Link") { state.textView?.insertLink() }
                .keyboardShortcut("k")
        }

        CommandGroup(before: .toolbar) {
            Button(state.sidebarShown ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation { state.sidebarShown.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Button(state.showingGraph ? "Hide Graph" : "Show Graph") { state.toggleGraph() }
                .keyboardShortcut("g", modifiers: [.option, .command])
            Divider()
            Toggle("Focus Mode", isOn: $state.focusEnabled)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Picker("Focus On", selection: $state.focusStyle) {
                ForEach(FocusStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Typewriter Scrolling", isOn: $state.typewriter)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Collapse All Folders") { state.expanded = [] }
                .disabled(state.expanded.isEmpty)
            Divider()
            Picker("Font", selection: $state.editorFont) {
                ForEach(EditorFont.allCases) { Text($0.rawValue).tag($0) }
            }
            Button("Bigger") { state.fontSize = min(32, state.fontSize + 1) }
                .keyboardShortcut("=")
            Button("Smaller") { state.fontSize = max(11, state.fontSize - 1) }
                .keyboardShortcut("-")
            Button("Actual Size") { state.fontSize = AppState.defaultFontSize }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
