import AppKit
import Sparkle
import SwiftTerm
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
                // All of Quill's own text in the chosen font, not just the page. The font
                // goes inside the choice, so it reads the choice rather than the default.
                .appFont(13)
                .environment(\.editorFont, state.editorFont)
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
        // A mouse's back and forward buttons step through the notes opened, as in a browser.
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: AppState.shared.goBack()
            case 4: AppState.shared.goForward()
            default: return event
            }
            return nil
        }
        Fonts.registerBundled()
        AppState.shared.appearance.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppState.shared.openExternal(url) }
    }
}

struct QuillCommands: Commands {
    @ObservedObject var state: AppState

    /// The editor, if you're typing in it: formatting shortcuts typed in the terminal
    /// shouldn't land in the note.
    private var editor: FocusTextView? {
        state.textView.flatMap { $0.window?.firstResponder === $0 ? $0 : nil }
    }

    /// Makes the text you're typing in, the terminal's or the page's, a point bigger or
    /// smaller; 0 puts it back to its usual size.
    private func resizeText(_ step: Double) {
        if NSApp.keyWindow?.firstResponder is TerminalView {
            state.terminalFontSize = step == 0 ? AppState.defaultTerminalFontSize
                : min(32, max(9, state.terminalFontSize + step))
        } else {
            state.fontSize = step == 0 ? AppState.defaultFontSize : min(32, max(11, state.fontSize + step))
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { state.newFile() }
                .keyboardShortcut(Shortcuts.newFile)
            Button("New Folder") { state.newFolder() }
                .keyboardShortcut(Shortcuts.newFolder)
            Button("Go To…") { state.goingTo = true }
                .keyboardShortcut(Shortcuts.goTo)
            Divider()
            Button("Open Folder…") { state.chooseRoot() }
                .keyboardShortcut(Shortcuts.openFolder)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { state.flushSave() }
                .keyboardShortcut(Shortcuts.save)
            Button("Rename…") { state.currentItem.map(state.beginRename) }
                .disabled(state.currentItem == nil)
            Button("Reveal in Finder") { state.currentItem.map(state.reveal) }
                .keyboardShortcut(Shortcuts.reveal)
                .disabled(state.currentItem == nil)
            Divider()
            Button("Move to Trash") { state.currentItem.map(state.trash) }
                .keyboardShortcut(Shortcuts.trash)
                .disabled(state.currentItem == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { editor?.toggleWrap("**") }
                .keyboardShortcut(Shortcuts.bold)
            Button("Italic") { editor?.toggleWrap("_") }
                .keyboardShortcut(Shortcuts.italic)
            Button("Strikethrough") { editor?.toggleWrap("~~") }
                .keyboardShortcut(Shortcuts.strikethrough)
            Button("Inline Code") { editor?.toggleWrap("`") }
                .keyboardShortcut(Shortcuts.code)
            Button("Link") { editor?.insertLink() }
                .keyboardShortcut(Shortcuts.link)
        }

        CommandGroup(before: .toolbar) {
            Button("Back") { state.goBack() }
                .keyboardShortcut(Shortcuts.back)
                .disabled(state.backStack.isEmpty)
            Button("Forward") { state.goForward() }
                .keyboardShortcut(Shortcuts.forward)
                .disabled(state.forwardStack.isEmpty)
            Divider()
            Button(state.sidebarShown ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation { state.sidebarShown.toggle() }
            }
            .keyboardShortcut(Shortcuts.sidebar)
            Button(state.showingGraph ? "Hide Graph" : "Show Graph") { state.toggleGraph() }
                .keyboardShortcut(Shortcuts.graph)
            Button(state.terminalShown ? "Hide Terminal" : "Show Terminal") {
                withAnimation { state.terminalShown.toggle() }
            }
            .keyboardShortcut(Shortcuts.terminal)
            Picker("Start in Terminal", selection: $state.terminalAgent) {
                ForEach(TerminalAgent.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Toggle("Focus Mode", isOn: $state.focusEnabled)
                .keyboardShortcut(Shortcuts.focus)
            Picker("Focus On", selection: $state.focusStyle) {
                ForEach(FocusStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Typewriter Scrolling", isOn: $state.typewriter)
                .keyboardShortcut(Shortcuts.typewriter)
            Divider()
            Button("Collapse All Folders") { state.expanded = [] }
                .disabled(state.expanded.isEmpty)
            Divider()
            Picker("Font", selection: $state.editorFont) {
                ForEach(EditorFont.allCases) { Text($0.rawValue).tag($0) }
            }
            Button("Bigger") { resizeText(1) }
                .keyboardShortcut(Shortcuts.bigger)
            Button("Smaller") { resizeText(-1) }
                .keyboardShortcut(Shortcuts.smaller)
            Button("Actual Size") { resizeText(0) }
                .keyboardShortcut(Shortcuts.actualSize)
            Divider()
            Picker("Appearance", selection: $state.appearance) {
                ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
        }

        CommandGroup(before: .help) {
            Button("Cheat Sheet") { state.showingCheatSheet.toggle() }
                .keyboardShortcut(Shortcuts.cheatSheet)
        }
    }
}
