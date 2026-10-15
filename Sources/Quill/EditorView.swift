import AppKit
import SwiftUI

struct EditorView: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 1 stack: focus dimming relies on layout-manager temporary attributes.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = FocusTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = false
        if #available(macOS 14.0, *) { tv.inlinePredictionType = .no }
        tv.drawsBackground = true
        tv.backgroundColor = Theme.background
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 0, height: 72)
        storage.delegate = context.coordinator.highlighter
        tv.delegate = context.coordinator

        let scroll = PageScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.documentView = tv
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)

        context.coordinator.attach(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: EditorCoordinator) {
        coordinator.save()
    }
}

/// Clicks anywhere on the page reach the text, not just those on the text column itself.
final class PageScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        guard let tv = documentView as? NSTextView, tv.isEditable else { return super.mouseDown(with: event) }
        tv.mouseDown(with: event)
    }
}

/// Owns the open document: loading, debounced autosave, reloading external edits, and
/// pushing view settings from `AppState` into the text view.
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    let state: AppState
    let highlighter = MarkdownHighlighter()
    private weak var textView: FocusTextView?
    private var url: URL?
    private var dirty = false
    private var pendingSave: DispatchWorkItem?
    private var diskDate: Date?
    private var fontKey = ""

    init(state: AppState) {
        self.state = state
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(flush), name: NSApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(flush), name: NSApplication.willTerminateNotification, object: nil)
    }

    func attach(_ tv: FocusTextView) {
        textView = tv
        state.textView = tv
        state.flushSave = { [weak self] in self?.save() }
    }

    func sync() {
        guard let tv = textView else { return }
        let key = "\(state.editorFont.rawValue)-\(state.fontSize)"
        if key != fontKey {
            fontKey = key
            let fonts = FontSet(state.editorFont, size: CGFloat(state.fontSize))
            highlighter.fonts = fonts
            tv.fonts = fonts
            tv.typingAttributes = highlighter.baseAttributes
            if let storage = tv.textStorage { highlighter.highlightAll(storage) }
            tv.updateLayout()
        }
        tv.typewriter = state.typewriter
        if tv.focusEnabled != state.focusEnabled || tv.focusStyle != state.focusStyle {
            tv.focusEnabled = state.focusEnabled
            tv.focusStyle = state.focusStyle
            tv.updateFocus()
        }
        open(state.openFile)
    }

    private func open(_ newURL: URL?) {
        guard newURL != url, let tv = textView else { return }
        save()
        let hadDocument = url != nil
        url = newURL
        guard let newURL else {
            tv.string = ""
            tv.isEditable = false
            diskDate = nil
            state.stats.update("")
            return
        }
        let text = read(newURL) ?? ""
        diskDate = modificationDate(newURL)
        tv.isEditable = true
        // A rename moves the open file without changing it: keep caret and undo history.
        if hadDocument && text == tv.string { return }
        load(text)
    }

    private func load(_ text: String, keepSelection: Bool = false) {
        guard let tv = textView else { return }
        let previous = tv.selectedRange()
        tv.string = text
        tv.undoManager?.removeAllActions()
        let length = (text as NSString).length
        tv.setSelectedRange(keepSelection ? NSRange(location: min(previous.location, length), length: 0)
                                          : NSRange(location: 0, length: 0))
        if !keepSelection { tv.scroll(.zero) }
        state.stats.update(text)
        tv.updateFocus()
        tv.centerCaret(animated: false)
    }

    @objc private func flush() { save() }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let tv = textView else { return }
        if dirty, let url {
            do {
                try tv.string.write(to: url, atomically: true, encoding: .utf8)
                dirty = false
                diskDate = modificationDate(url)
            } catch {
                NSLog("Quill: failed to save \(url.path): \(error)")
            }
        }
        state.stats.update(tv.string)
    }

    /// Picks up edits made by other apps while Quill was in the background.
    @objc private func appBecameActive() {
        guard !dirty, let url, let tv = textView,
              let date = modificationDate(url), date != diskDate,
              let text = read(url) else { return }
        diskDate = date
        if text != tv.string { load(text, keepSelection: true) }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        dirty = true
        state.chrome.typingStarted(in: textView?.window)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView?.updateFocus()
        textView?.centerCaret()
    }

    // MARK: Files

    private func read(_ url: URL) -> String? {
        var encoding = String.Encoding.utf8
        return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, usedEncoding: &encoding))
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
