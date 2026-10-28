import AppKit
import SwiftTerm
import SwiftUI

/// A shell under the page, in Quill's type and colors, for running command-line tools (an AI
/// agent, say) over your notes. Each note has its own, started in the note's folder with the
/// note in `$QUILL_FILE`, and the library has one; the switch at the top picks between the
/// open note's and the library's. Opened by hand only, and it slides away once you start
/// writing, as the sidebar does.
struct TerminalPane: View {
    @EnvironmentObject var state: AppState
    @StateObject private var shells = Shells()
    @AppStorage("terminalHeight") private var height = 220.0
    /// The height when the drag began.
    @State private var dragStart: Double?

    /// The open note's shell, or the library's when that's picked or no note is open.
    private var note: URL? { state.terminalOnLibrary ? nil : state.openFile }

    var body: some View {
        let place = note ?? state.root
        VStack(spacing: 0) {
            Divider().overlay { resizeHandle }
            HStack(spacing: 8) {
                if shells.installed.count > 1 {
                    AgentSwitch(agents: shells.installed, running: shells.agents[place]) { agent in
                        state.terminalAgent = agent
                        shells.restart(place)
                    }
                }
                Spacer()
                ContextSwitch(note: state.openFile, onLibrary: note == nil) { library in
                    state.terminalOnLibrary = library
                }
            }
            .appFont(12)
            .padding(.horizontal, 14)
            .frame(height: 26)
            TerminalHost(shells: shells, place: place, file: note, root: state.root,
                         agent: state.terminalAgent, shown: state.terminalShown,
                         exited: { withAnimation { state.terminalShown = false } },
                         focusEditor: state.focusEditor)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
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

/// What the terminal starts on its own. Picked in the View menu, or with the switch at the top
/// of the pane when both agents are installed.
enum TerminalAgent: String, CaseIterable, Identifiable {
    case claude = "Claude Code", codex = "Codex", none = "Nothing"
    var id: String { rawValue }

    /// Its command, which is also how the shell names it to Quill.
    var command: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .none: nil
        }
    }

    init?(command: Substring) {
        guard let agent = Self.allCases.first(where: { $0.command == String(command) }) else { return nil }
        self = agent
    }
}

/// "Claude Code · Codex", the one this shell started lit in the accent; click the other to
/// quit this one and start that in its place, there and in shells to come.
private struct AgentSwitch: View {
    let agents: [TerminalAgent]
    let running: TerminalAgent?
    let pick: (TerminalAgent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(agents.enumerated()), id: \.element) { index, agent in
                if index > 0 { Text("·").foregroundStyle(.tertiary) }
                Choice(title: agent.rawValue, lit: agent == running) {
                    if agent != running { pick(agent) }
                }
                .help("Start \(agent.rawValue) Here")
            }
        }
    }
}

/// The open note's name and "Library", the one whose shell is showing lit in the accent;
/// click the other to switch. Just "Library" with no note open.
private struct ContextSwitch: View {
    let note: URL?
    let onLibrary: Bool
    let pick: (_ library: Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Choice(title: FileNode.displayName(note), lit: !onLibrary) { pick(false) }
                    .help("Talk About This Note")
                Text("·").foregroundStyle(.tertiary)
            }
            Choice(title: "Library", lit: onLibrary) { pick(true) }
                .help("Talk About the Whole Library")
        }
    }
}

/// A word at the top of the pane, lit in the accent when it's the one in use.
private struct Choice: View {
    let title: String
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .foregroundStyle(lit ? Color.accentColor : Color.secondary)
    }
}

/// Shows the shell for the open note, or the library's, starting it the first time it's shown.
private struct TerminalHost: NSViewRepresentable {
    let shells: Shells
    /// The note, or the library when no note is open: whose shell to show.
    let place: URL
    let file: URL?
    let root: URL
    /// What a new shell starts.
    let agent: TerminalAgent
    let shown: Bool
    /// The shell on show quit, as when you type `exit`.
    let exited: () -> Void
    let focusEditor: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        shells.exited = exited
        let wasShown = shells.shown
        shells.shown = shown
        guard shown else {
            // Back to writing, rather than typing into a pane that's gone.
            if wasShown, host.window?.firstResponder is TerminalView { focusEditor() }
            return
        }
        let terminal = shells.terminal(for: place, file: file, root: root, agent: agent, size: host.bounds)
        // Typing carries over to the shell switched to; a note picked in the sidebar
        // doesn't pull the typing down here.
        var focus = !wasShown
        if terminal.superview !== host {
            focus = focus || host.subviews.contains { $0 === host.window?.firstResponder }
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = host.bounds
            terminal.autoresizingMask = [.width, .height]
            host.addSubview(terminal)
        }
        if focus {
            DispatchQueue.main.async { host.window?.makeFirstResponder(terminal) }
        }
    }
}

/// The shells started so far, by the note or library they belong to, and what they've said
/// about the agents. Each lives until it quits, it's restarted, or Quill quits.
private final class Shells: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    private var terminals: [URL: QuillTerminal] = [:]
    /// The agents installed, as the latest shell found them.
    @Published private(set) var installed: [TerminalAgent] = []
    /// The agent each shell started, by its note or library.
    @Published private(set) var agents: [URL: TerminalAgent] = [:]
    var shown = false
    var exited: () -> Void = {}

    func terminal(for place: URL, file: URL?, root: URL, agent: TerminalAgent, size: NSRect) -> QuillTerminal {
        if let terminal = terminals[place] { return terminal }
        let terminal = QuillTerminal(frame: size)
        terminal.processDelegate = self
        terminal.reported = { [weak self] installed, started in
            self?.installed = installed
            self?.agents[place] = started
        }
        terminal.start(in: file?.deletingLastPathComponent() ?? root, file: file, root: root, agent: agent)
        terminals[place] = terminal
        return terminal
    }

    /// Ends the place's shell and whatever's running in it, as closing a Terminal window does.
    /// A new one, with the agent now picked, takes its place in the pane, and the typing with it.
    func restart(_ place: URL) {
        guard let old = terminals.removeValue(forKey: place) else { return }
        old.processDelegate = nil
        kill(old.process.shellPid, SIGHUP)
        old.terminate()
        agents[place] = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in
            if let place = terminals.first(where: { $0.value === source })?.key {
                terminals[place] = nil
                agents[place] = nil
            }
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
        // "claude,codex;claude": the agents installed, then the one started, if any.
        getTerminal().registerOscHandler(code: ZshIntegration.reportCode) { [weak self] data in
            let parts = String(decoding: data, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            let installed = (parts.first?.split(separator: ",") ?? []).compactMap(TerminalAgent.init(command:))
            let started = parts.count > 1 ? TerminalAgent(command: parts[1]) : nil
            DispatchQueue.main.async { self?.reported(installed, started) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What the shell found as it started: the agents installed, and the one it started.
    var reported: (_ installed: [TerminalAgent], _ started: TerminalAgent?) -> Void = { _, _ in }

    /// Starts your login shell, so it has the PATH and settings it has in Terminal. It gets
    /// the session's basics rather than all of Quill's environment, which can carry
    /// whatever launched Quill (another terminal, say) into the shell.
    func start(in dir: URL, file: URL?, root: URL, agent: TerminalAgent) {
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
        env["QUILL_START"] = "1"
        env["QUILL_AGENT"] = agent.command ?? ""
        if (shell as NSString).lastPathComponent == "zsh", let zdotdir = ZshIntegration.install() {
            env["QUILL_USER_ZDOTDIR"] = inherited["ZDOTDIR"] ?? inherited["HOME"] ?? NSHomeDirectory()
            env["ZDOTDIR"] = zdotdir.path
        }
        startProcess(executable: shell, environment: env.map { "\($0.key)=\($0.value)" },
                     execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir.path)
    }

    /// The program's output, less the queries SwiftTerm misreads (see `QuerySifter`).
    private var sifter = QuerySifter()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let sifted = sifter.sift(slice)
        if !sifted.isEmpty { super.dataReceived(slice: sifted[...]) }
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

/// Drops the kitty keyboard sequences (`CSI ? u`, `CSI > 1 u` and the like) and the version
/// query (`CSI > q`) from a program's output. SwiftTerm 1.11 reads any `CSI … u` as "restore
/// the cursor" and any `CSI … q` as "set the cursor's shape", whatever comes before them, so
/// Claude Code asking what the terminal supports sent the cursor back to the top left. They're
/// questions about things SwiftTerm doesn't do, so going unanswered is the right answer.
struct QuerySifter {
    /// The end of the last chunk, when it might be the start of a sequence to drop.
    private var held: [UInt8] = []

    mutating func sift(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = held + chunk
        held = []
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1b else {
                out.append(bytes[i])
                i += 1
                continue
            }
            // ESC [, then one of ? > < =, then digits and semicolons, then the final byte.
            var j = i + 1
            guard j < bytes.count else { held = Array(bytes[i...]); break }
            guard bytes[j] == UInt8(ascii: "[") else { out.append(bytes[i]); i += 1; continue }
            j += 1
            guard j < bytes.count else { held = Array(bytes[i...]); break }
            let prefix = bytes[j]
            guard [UInt8(ascii: "?"), UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "=")].contains(prefix)
            else { out.append(bytes[i]); i += 1; continue }
            j += 1
            while j < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[j]) || bytes[j] == UInt8(ascii: ";") {
                j += 1
            }
            guard j < bytes.count else { held = Array(bytes[i...]); break }
            let final = bytes[j]
            if final == UInt8(ascii: "u") || (final == UInt8(ascii: "q") && prefix == UInt8(ascii: ">")) {
                i = j + 1
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}

/// Startup files that zsh reads in place of yours (through `ZDOTDIR`), as VS Code's terminal
/// does: each reads your own, then Quill's additions follow. The additions: `claude` and
/// `codex`, which tell Claude Code and Codex the note that's open (so you can ask about
/// "this") or, in the library's shell, that the folder is your library; and starting one.
enum ZshIntegration {
    /// The private OSC code by which a shell tells Quill which agents are installed, and which
    /// it started. Quill can't look for itself: their folders are often on the PATH only once
    /// your .zshrc has run.
    static let reportCode = 7701

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

            unalias claude codex 2>/dev/null
            # What the agents are told on top of their own instructions.
            function _quill_context {
              if [[ -n $QUILL_FILE ]]; then
                print -r -- "You were started from the terminal in Quill, a Markdown editor, where the \\
            user has the note \\"$QUILL_FILE\\" open. Their library of notes is \\"$QUILL_LIBRARY\\". When \\
            they say \\"this\\", \\"my note\\" or the like without naming a file, they mean the open note: \\
            read it before answering, as they may have changed it since you last did."
              else
                print -r -- "You were started from the terminal in Quill, a Markdown editor, to talk \\
            about the user's whole library of notes: the folder you're in, \\"$QUILL_LIBRARY\\". When they \\
            say \\"my notes\\", \\"my library\\" or the like, they mean its Markdown files; look through \\
            them before answering."
              fi
            }

            # In a note's shell, which starts in the note's folder, the agents may also reach the
            # rest of the library. A lone word is a subcommand (claude mcp, codex login): passed
            # on as is.
            function claude {
              if [[ $# -gt 0 && $1 != -* && $1 != *' '* ]]; then
                command claude "$@"
                return
              fi
              local library=()
              [[ -n $QUILL_FILE ]] && library=(--add-dir "$QUILL_LIBRARY")
              command claude $library --append-system-prompt "$(_quill_context)" "$@"
            }
            function codex {
              if [[ $# -gt 0 && $1 != -* && $1 != *' '* ]]; then
                command codex "$@"
                return
              fi
              local library=()
              [[ -n $QUILL_FILE ]] && library=(--add-dir "$QUILL_LIBRARY")
              # Not TOML, so Codex takes it as the literal string.
              command codex $library -c "developer_instructions=$(_quill_context)" "$@"
            }

            # The agent starts on its own at the first prompt, once all your startup files have
            # run, and leaves you at the prompt when it quits: the one picked in Quill if it's
            # installed, or else whichever is. Quill hears which are installed, for the switch
            # at the top of the pane. Shells started from this one don't do it again.
            if [[ -n $QUILL_START ]]; then
              unset QUILL_START
              autoload -Uz add-zsh-hook
              function _quill_start {
                add-zsh-hook -d precmd _quill_start
                local installed=() agent= a
                for a in claude codex; do (( $+commands[$a] )) && installed+=($a); done
                if [[ -n $QUILL_AGENT ]]; then
                  for a in $QUILL_AGENT $installed; do (( $+commands[$a] )) && agent=$a && break; done
                fi
                unset QUILL_AGENT
                printf '\\e]\(reportCode);%s;%s\\a' "${(j:,:)installed}" "$agent"
                [[ -n $agent ]] && $agent
              }
              add-zsh-hook precmd _quill_start
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
        .pointingHandCursor()
        .foregroundStyle(Color.accentColor)
        .help(state.terminalShown ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
    }
}
