import AppKit
import SwiftTerm
import SwiftUI

/// A shell under the page, in Quill's type and colors, for running command-line tools (an AI
/// agent, say) over your notes. Each note has its own, started in the note's folder with the
/// note in `$QUILL_FILE`; with nothing open, the library has one. Opened by hand only, and it
/// slides away once you start writing, as the sidebar does.
struct TerminalPane: View {
    @EnvironmentObject var state: AppState
    @AppStorage("terminalHeight") private var height = 220.0
    /// The height when the drag began.
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay { resizeHandle }
            TerminalHost(place: state.openFile ?? state.root, file: state.openFile, root: state.root,
                         shown: state.terminalShown,
                         exited: { withAnimation { state.terminalShown = false } },
                         focusEditor: state.focusEditor)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: Theme.background))
        // Laid out at its full height and uncovered as it slides, so the shell isn't told
        // of a new size on every frame of the slide.
        .frame(height: height)
        .frame(height: state.terminalShown ? height : 0, alignment: .top)
        .clipped()
    }

    /// A strip a little taller than the line above the pane; drag it to resize the pane.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(640, max(100, start - drag.translation.height))
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// Shows the shell for the open note, or the library's, starting it the first time it's shown.
private struct TerminalHost: NSViewRepresentable {
    /// The note, or the library when no note is open: whose shell to show.
    let place: URL
    let file: URL?
    let root: URL
    let shown: Bool
    /// The shell on show quit, as when you type `exit`.
    let exited: () -> Void
    let focusEditor: () -> Void

    func makeCoordinator() -> Shells { Shells() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        let shells = context.coordinator
        shells.exited = exited
        let wasShown = shells.shown
        shells.shown = shown
        guard shown else {
            // Back to writing, rather than typing into a pane that's gone.
            if wasShown, host.window?.firstResponder is TerminalView { focusEditor() }
            return
        }
        let terminal = shells.terminal(for: place, file: file, root: root, size: host.bounds)
        if terminal.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = host.bounds
            terminal.autoresizingMask = [.width, .height]
            host.addSubview(terminal)
        }
        if !wasShown {
            DispatchQueue.main.async { host.window?.makeFirstResponder(terminal) }
        }
    }
}

/// The shells started so far, by the note or library they belong to. Each lives until it
/// quits or Quill does.
private final class Shells: NSObject, LocalProcessTerminalViewDelegate {
    private var terminals: [URL: QuillTerminal] = [:]
    var shown = false
    var exited: () -> Void = {}

    func terminal(for place: URL, file: URL?, root: URL, size: NSRect) -> QuillTerminal {
        if let terminal = terminals[place] { return terminal }
        let terminal = QuillTerminal(frame: size)
        terminal.processDelegate = self
        terminal.start(in: file?.deletingLastPathComponent() ?? root, file: file, root: root)
        terminals[place] = terminal
        return terminal
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            terminals = terminals.filter { $0.value !== source }
            // The next time this note's pane is opened, it gets a new shell.
            if source.superview != nil {
                source.removeFromSuperview()
                exited()
            }
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// A terminal in the page's colors and iA Writer Mono.
private final class QuillTerminal: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = NSFont(name: "iAWriterMonoS-Regular", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Starts your login shell, so it has the PATH and settings it has in Terminal.
    func start(in dir: URL, file: URL?, root: URL) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Quill"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["QUILL_LIBRARY"] = root.path
        env["QUILL_FILE"] = file?.path
        startProcess(executable: shell, environment: env.map { "\($0.key)=\($0.value)" },
                     execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir.path)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Theme's colors follow light and dark, but the terminal takes fixed ones; so they're
    /// read in the view's appearance, and again when it changes.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Theme.background
            nativeForegroundColor = Theme.text
            caretColor = Theme.accent
            selectedTextBackgroundColor = Theme.selection
        }
    }
}

/// The button by the word count; opens and closes the terminal.
struct TerminalButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { withAnimation { state.terminalShown.toggle() } } label: {
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .frame(minWidth: 20, minHeight: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(state.terminalShown ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
    }
}
