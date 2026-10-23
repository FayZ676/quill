import AppKit
import SwiftUI

struct EditorView: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 1 stack: focus dimming relies on layout-manager temporary attributes.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.delegate = context.coordinator.markupHider
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
        tv.textInput = state.textInput
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

/// Clicks anywhere on the page reach the text, not just those on the text column itself:
/// the margins, the space below the last line, and whatever the clip view shows around
/// the text view. Only the scroller keeps its own clicks.
final class PageScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let tv = documentView as? NSTextView, tv.isEditable,
              !hit.isDescendant(of: verticalScroller ?? hit), !(hit is NSScroller) else { return hit }
        return hit.isDescendant(of: tv) ? hit : tv
    }
}

/// Owns the open document: loading, debounced autosave, reloading external edits, and
/// pushing view settings from `AppState` into the text view.
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    let state: AppState
    let highlighter = MarkdownHighlighter()
    let markupHider = LinkMarkupHider()
    private weak var textView: FocusTextView?
    private var url: URL?
    private var dirty = false
    private var pendingSave: DispatchWorkItem?
    private var diskDate: Date?
    private var fontKey = ""
    /// The notes links were last styled against, to restyle them as notes come and go.
    private var linkedNotes: [URL] = []

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
        // Edit › Spelling and Grammar and Substitutions change the text view directly.
        tv.textInputChanged = { [weak self] in self?.state.textInput = $0 }
        tv.openNoteLink = { [weak self] in self?.state.openLink($0) }
        tv.linkResolver = { [weak self] in self?.state.links }
        highlighter.linkExists = { [weak self] in self?.state.links.exists($0, from: self?.url) ?? true }
        state.showPendingHeading = { [weak self] in self?.showPendingHeading() }
        state.reloadEditor = { [weak self] in self?.reload($0) }
    }

    func sync() {
        guard let tv = textView else { return }
        let key = "\(state.editorFont.rawValue)-\(state.fontSize)"
        if key != fontKey {
            fontKey = key
            let fonts = FontSet(state.editorFont, size: CGFloat(state.fontSize))
            highlighter.fonts = fonts
            tv.fonts = fonts
            tv.editorFont = state.editorFont
            tv.typingAttributes = highlighter.baseAttributes
            if let storage = tv.textStorage { highlighter.highlightAll(storage) }
            tv.updateLayout()
        }
        if state.links.notes != linkedNotes {
            linkedNotes = state.links.notes
            if let storage = tv.textStorage { highlighter.highlightAll(storage) }
        }
        tv.typewriter = state.typewriter
        if tv.textInput != state.textInput { tv.textInput = state.textInput }
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
        showPendingHeading()
    }

    /// Puts the caret on the heading a `[[Note#Heading]]` link pointed into.
    private func showPendingHeading() {
        guard let heading = state.pendingHeading, let tv = textView else { return }
        state.pendingHeading = nil
        guard let line = LinkResolver.headingRange(heading, in: tv.string) else { return }
        tv.setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
        tv.scrollRangeToVisible(line)
    }

    /// Takes in a change Quill made to the open note's file (its links pointed at notes that
    /// moved, or the note itself moved to `newURL`), keeping the caret where it was.
    private func reload(_ newURL: URL) {
        guard let text = read(newURL) else { return }
        url = newURL
        diskDate = modificationDate(newURL)
        if let tv = textView, text != tv.string { load(text, keepSelection: true) }
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
        textView?.updateSuggestions()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView?.updateFocus()
        textView?.centerCaret()
        textView?.updateSuggestions()
        if let tv = textView, let layout = tv.layoutManager { markupHider.reveal(at: tv.selectedRange(), in: layout) }
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
