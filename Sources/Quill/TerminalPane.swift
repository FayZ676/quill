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

    /// Starts your login shell, so it has the PATH and settings it has in Terminal. It gets
    /// the session's basics rather than all of Quill's environment, which can carry
    /// whatever launched Quill (another terminal, say) into the shell.
    func start(in dir: URL, file: URL?, root: URL) {
        let inherited = ProcessInfo.processInfo.environment
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        var env = inherited.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"].contains(key)
                || key == "LANG" || key.hasPrefix("LC_")
        }
        // The login shell builds the rest, as it does in Terminal.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Quill"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["QUILL_LIBRARY"] = root.path
        env["QUILL_FILE"] = file?.path
        if (shell as NSString).lastPathComponent == "zsh", let zdotdir = ZshIntegration.install() {
            env["QUILL_USER_ZDOTDIR"] = inherited["ZDOTDIR"] ?? inherited["HOME"] ?? NSHomeDirectory()
            env["ZDOTDIR"] = zdotdir.path
        }
        startProcess(executable: shell, environment: env.map { "\($0.key)=\($0.value)" },
                     execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir.path)
    }

    // MARK: Scrolling

    /// SwiftTerm scrolls its own history on the wheel and nothing else, and a full-screen
    /// program like Claude Code has none there. So, as Terminal does, the wheel goes to a
    /// program that asks for the mouse, and moves the cursor keys in one that took over
    /// the screen without it. SwiftTerm's handler can't be overridden from here, so the
    /// window's wheel events are watched instead.
    private var wheelMonitor: Any?
    /// Wheel travel not yet sent, in lines.
    private var pendingLines: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.wheel(event) ?? event
        }
    }

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }

    /// Takes the event if it's for the program running here; lets it through otherwise.
    private func wheel(_ event: NSEvent) -> NSEvent? {
        let point = convert(event.locationInWindow, from: nil)
        guard event.window === window, !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return event }
        let reports = allowMouseReporting && terminal.mouseMode != .off
        guard reports || terminal.isCurrentBufferAlternate else { return event }

        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        pendingLines += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / lineHeight : event.scrollingDeltaY
        let lines = Int(pendingLines)
        pendingLines -= CGFloat(lines)
        // Up the page, toward what came earlier, for a positive delta.
        let up = lines > 0
        for _ in 0..<abs(lines) {
            if reports {
                let col = min(terminal.cols - 1, max(0, Int(point.x / bounds.width * CGFloat(terminal.cols))))
                let row = min(terminal.rows - 1, max(0, Int((bounds.height - point.y) / bounds.height * CGFloat(terminal.rows))))
                let flags = terminal.encodeButton(button: up ? 4 : 5, release: false,
                                                  shift: event.modifierFlags.contains(.shift),
                                                  meta: event.modifierFlags.contains(.option),
                                                  control: event.modifierFlags.contains(.control))
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            } else if terminal.applicationCursor {
                send(up ? EscapeSequences.moveUpApp : EscapeSequences.moveDownApp)
            } else {
                send(up ? EscapeSequences.moveUpNormal : EscapeSequences.moveDownNormal)
            }
        }
        return nil
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

/// Startup files that zsh reads in place of yours (through `ZDOTDIR`), as VS Code's terminal
/// does: each reads your own, then Quill's additions follow. The one addition so far is
/// `claude`, which tells Claude Code the note that's open, so you can ask about "this".
enum ZshIntegration {
    /// Your file of the same name, read with `ZDOTDIR` where zsh would have had it.
    private static func yours(_ name: String) -> String {
        """
        ZDOTDIR=$QUILL_USER_ZDOTDIR
        [[ -r $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)
        """
    }

    private static let files = [
        ".zshenv": """
            QUILL_ZDOTDIR=$ZDOTDIR
            \(yours(".zshenv"))
            # Your .zshenv may have moved your startup files.
            QUILL_USER_ZDOTDIR=$ZDOTDIR
            ZDOTDIR=$QUILL_ZDOTDIR
            """,
        ".zprofile": """
            \(yours(".zprofile"))
            ZDOTDIR=$QUILL_ZDOTDIR
            """,
        ".zshrc": """
            # macOS's /etc/zshrc put history beside these files.
            [[ $HISTFILE == $QUILL_ZDOTDIR/.zsh_history ]] && HISTFILE=$QUILL_USER_ZDOTDIR/.zsh_history
            \(yours(".zshrc"))

            if [[ -n $QUILL_FILE ]]; then
              unalias claude 2>/dev/null
              function claude {
                # A lone word is a subcommand (claude mcp, claude update): passed on as is.
                if [[ $# -gt 0 && $1 != -* && $1 != *' '* ]]; then
                  command claude "$@"
                  return
                fi
                command claude --add-dir "$QUILL_LIBRARY" --append-system-prompt "You were started \\
            from the terminal in Quill, a Markdown editor, where the user has the note \\"$QUILL_FILE\\" \\
            open. Their library of notes is \\"$QUILL_LIBRARY\\". When they say \\"this\\", \\"my note\\" or \\
            the like without naming a file, they mean the open note: read it before answering, as \\
            they may have changed it since you last did." "$@"
              }
            fi

            if [[ -o login ]]; then
              ZDOTDIR=$QUILL_ZDOTDIR
            else
              unset QUILL_ZDOTDIR QUILL_USER_ZDOTDIR
            fi
            """,
        ".zlogin": """
            \(yours(".zlogin"))
            unset QUILL_ZDOTDIR QUILL_USER_ZDOTDIR
            """,
    ]

    /// Writes the files if they've changed, and says where they are.
    static func install() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("Quill/zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, text) in files {
                let url = dir.appendingPathComponent(name)
                let contents = "# Written by Quill for its terminal; see ZshIntegration.\n" + text + "\n"
                if (try? String(contentsOf: url, encoding: .utf8)) != contents {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            return nil
        }
        return dir
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
