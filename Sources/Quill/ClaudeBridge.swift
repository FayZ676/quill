import AppKit
import Network

/// Quill as an editor Claude Code can talk to, as it talks to VS Code: whatever you've selected
/// in the open note reaches Claude in the terminal without your typing it, and the changes it
/// proposes to a file come up on the page for you to accept or reject.
///
/// Claude Code finds editors by a lockfile in `~/.claude/ide` named for a port, and connects
/// to the one whose port the terminal hands it in `CLAUDE_CODE_SSE_PORT`: a WebSocket on the
/// Mac alone, behind the token in the lockfile, speaking MCP's JSON-RPC. Quill tells it of
/// each new selection (`selection_changed`), and answers its `openDiff` once you've decided.
final class ClaudeBridge: ObservableObject {
    static let shared = ClaudeBridge()

    /// The changes Claude is waiting on, oldest first; the page shows the first.
    @Published private(set) var changes: [ProposedChange] = []
    /// Installed by the editor: the open note, its text and the selection in it.
    var selection: () -> (file: URL, text: String, range: NSRange)? = { nil }

    private let token = UUID().uuidString
    private var listener: NWListener?
    private var port: UInt16?
    /// Shells waiting for the port to start with.
    private var waiting: [(UInt16?) -> Void] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var library: URL?
    private var lockFile: URL?
    /// The last `selection_changed` sent, so the same one isn't sent again.
    private var lastSelection: String?
    private var pendingSelection: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.removeLockFile() }
    }

    // MARK: Starting

    /// Opens the door, the first time a shell starts, and hands over the port for the shell to
    /// pass on to Claude Code; nil if it couldn't be opened, and Claude Code goes without.
    func start(library: URL, ready: @escaping (UInt16?) -> Void) {
        if self.library != library {
            self.library = library
            if port != nil { writeLockFile() }
        }
        if let port { return ready(port) }
        waiting.append(ready)
        guard listener == nil else { return }

        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        // Only Claude Code, which has read the token from the lockfile, gets in.
        socket.setClientRequestHandler(.main) { [token] subprotocols, headers in
            let allowed = headers.contains {
                $0.name.caseInsensitiveCompare("X-Claude-Code-Ide-Authorization") == .orderedSame && $0.value == token
            }
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject,
                                                subprotocol: subprotocols.contains("mcp") ? "mcp" : nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        // Reachable from this Mac alone.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return opened(nil) }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.opened(listener?.port?.rawValue)
            case .failed: self?.opened(nil)
            default: break
            }
        }
        listener.start(queue: .main)
        // A shell shouldn't wait on it for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, port == nil else { return }
            let late = waiting
            waiting = []
            late.forEach { $0(nil) }
        }
    }

    private func opened(_ port: UInt16?) {
        self.port = port
        if port != nil {
            writeLockFile()
        } else {
            listener?.cancel()
            listener = nil
        }
        let ready = waiting
        waiting = []
        ready.forEach { $0(port) }
    }

    private func writeLockFile() {
        guard let port, let library else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide", isDirectory: true)
        let file = dir.appendingPathComponent("\(port).lock")
        let lock: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": [library.path],
            "ideName": "Quill",
            "transport": "ws",
            "authToken": token,
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: lock, options: .withoutEscapingSlashes).write(to: file, options: .atomic)
            // The token is a key to the door.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lockFile = file
        } catch {
            NSLog("Quill: couldn't write \(file.path): \(error)")
        }
    }

    private func removeLockFile() {
        if let lockFile { try? FileManager.default.removeItem(at: lockFile) }
    }

    // MARK: Talking

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        client.receive { [weak self, weak client] message in
            guard let self, let client else { return }
            handle(message, from: client)
        }
        connection.start(queue: .main)
    }

    /// Claude Code quit, or the connection broke: the changes it was waiting on go too.
    private func drop(_ id: ObjectIdentifier) {
        guard clients.removeValue(forKey: id) != nil else { return }
        changes.removeAll { $0.client == id }
    }

    private func handle(_ data: Data, from client: Client) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        // A notification wants no answer.
        guard let id = message["id"] else {
            // Claude Code listens for the selection a moment after it says it's connected.
            if method == "ide_connected" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak client] in
                    if let client { self?.sendSelection(to: client) }
                }
            }
            return
        }
        let reply = { (result: [String: Any]) in client.send(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch method {
        case "initialize":
            reply([
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Quill", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
            ])
        case "ping":
            reply([:])
        case "tools/list":
            reply(["tools": Self.tools])
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case "openDiff":
                propose(args, from: client, reply: reply)
            case "close_tab":
                let tab = args["tab_name"] as? String
                changes.removeAll { $0.client == ObjectIdentifier(client) && $0.tab == tab }
                reply(Self.text("TAB_CLOSED"))
            case "closeAllDiffTabs":
                changes.removeAll { $0.client == ObjectIdentifier(client) }
                reply(Self.text("OK"))
            default:
                // Diagnostics, opening files and the rest are VS Code's; Claude Code goes on without.
                client.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Quill doesn't do that"]])
            }
        default:
            client.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]])
        }
    }

    /// The tools Claude Code calls on an editor that Quill takes up. It calls them by name, so
    /// listing them is a courtesy.
    private static let tools: [[String: Any]] = ["openDiff", "close_tab", "closeAllDiffTabs"].map {
        ["name": $0, "description": "", "inputSchema": ["type": "object"]]
    }

    private static func text(_ parts: String...) -> [String: Any] {
        ["content": parts.map { ["type": "text", "text": $0] }]
    }

    // MARK: Changes

    /// Claude Code proposes new contents for a file and waits, as long as it takes, for you to
    /// accept or reject them on the page. You can answer in the terminal instead; it then
    /// closes the change here with `close_tab`.
    private func propose(_ args: [String: Any], from client: Client, reply: @escaping ([String: Any]) -> Void) {
        guard let path = args["new_file_path"] as? String ?? args["old_file_path"] as? String,
              let proposed = args["new_file_contents"] as? String else { return reply(Self.text("DIFF_REJECTED")) }
        let tab = args["tab_name"] as? String ?? path
        let file = URL(fileURLWithPath: path)
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        changes.append(ProposedChange(file: file, tab: tab, old: current, new: proposed,
                                      client: ObjectIdentifier(client), answer: reply))
    }

    /// Lets Claude Code go ahead and write the change, which the page then takes in.
    func accept(_ change: ProposedChange) {
        guard changes.contains(where: { $0.id == change.id }) else { return }
        changes.removeAll { $0.id == change.id }
        change.answer(Self.text("FILE_SAVED", change.new))
    }

    func reject(_ change: ProposedChange) {
        guard changes.contains(where: { $0.id == change.id }) else { return }
        changes.removeAll { $0.id == change.id }
        change.answer(Self.text("DIFF_REJECTED", change.tab))
    }

    // MARK: Selection

    /// The selection moved, or the note did: Claude Code hears of it once it settles.
    func selectionChanged() {
        guard !clients.isEmpty else { return }
        pendingSelection?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSelection() }
        pendingSelection = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// To one newly connected, or to all of them if it changed. With nothing selected, Claude
    /// Code still hears which note is open; with no note open, of none.
    private func sendSelection(to client: Client? = nil) {
        var params: [String: Any] = ["text": "", "filePath": "", "selection": Self.selection(from: (0, 0), to: (0, 0))]
        if let (file, text, range) = selection() {
            let string = text as NSString
            let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
            params = [
                "text": string.substring(with: range),
                "filePath": file.path,
                "fileUrl": file.absoluteString,
                "selection": Self.selection(from: Self.position(range.location, in: string),
                                            to: Self.position(NSMaxRange(range), in: string)),
            ]
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": "selection_changed", "params": params]
        if let client { return client.send(message) }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8), json != lastSelection else { return }
        lastSelection = json
        clients.values.forEach { $0.send(message) }
    }

    private static func selection(from start: (Int, Int), to end: (Int, Int)) -> [String: Any] {
        [
            "start": ["line": start.0, "character": start.1],
            "end": ["line": end.0, "character": end.1],
            "isEmpty": start == end,
        ]
    }

    /// The line, from 0, and the place along it, in UTF-16 as VS Code counts.
    private static func position(_ location: Int, in string: NSString) -> (Int, Int) {
        var line = 0, lineStart = 0
        for i in 0..<location where string.character(at: i) == 0x0A {
            line += 1
            lineStart = i + 1
        }
        return (line, location - lineStart)
    }
}

/// New contents Claude Code proposes for a file, waiting on your answer.
struct ProposedChange: Identifiable {
    let id = UUID()
    let file: URL
    /// Claude Code's name for it, by which it closes it.
    let tab: String
    let old: String
    let new: String
    fileprivate let client: ObjectIdentifier
    fileprivate let answer: ([String: Any]) -> Void
}

/// A connected Claude Code, sent and read as whole JSON messages.
private final class Client {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func receive(_ handle: @escaping (Data) -> Void) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty { handle(data) }
            if error == nil { self?.receive(handle) } else { self?.connection.cancel() }
        }
    }
}
