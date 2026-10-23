import SwiftUI
import UIKit

/// Like the Mac app, the chrome (the header) fades away once you start
/// typing, and comes back when you scroll or put the keyboard away.
final class EditorChrome: ObservableObject {
    @Published private(set) var hidden = false
    /// The document is slow to arrive (iCloud is fetching it), so the page says so.
    @Published var downloading = false

    func setHidden(_ hide: Bool) {
        guard hide != hidden else { return }
        withAnimation(.easeInOut(duration: hide ? 0.5 : 0.25)) { hidden = hide }
    }
}

struct EditorView: UIViewRepresentable {
    @ObservedObject var state: AppState
    @ObservedObject var page: Page
    let chrome: EditorChrome

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(state: state, chrome: chrome) }

    func makeUIView(context: Context) -> FocusTextView {
        // Explicit TextKit 1 stack, as on the Mac: the highlighter styles the storage directly.
        let storage = NSTextStorage()
        let layout = FocusLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = FocusTextView(frame: .zero, textContainer: container)
        tv.backgroundColor = Theme.background
        tv.tintColor = Theme.accent
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.textInput = state.textInput
        tv.highlighter = context.coordinator.highlighter
        storage.delegate = context.coordinator.highlighter
        tv.delegate = context.coordinator

        context.coordinator.attach(tv)
        context.coordinator.sync(url: page.url)
        return tv
    }

    func updateUIView(_ tv: FocusTextView, context: Context) {
        context.coordinator.sync(url: page.url)
    }

    static func dismantleUIView(_ tv: FocusTextView, coordinator: EditorCoordinator) {
        coordinator.save()
    }
}

/// Owns the open document: loading, debounced autosave, reloading edits made elsewhere
/// (e.g. on the Mac, through iCloud), and pushing view settings into the text view.
final class EditorCoordinator: NSObject, UITextViewDelegate {
    let state: AppState
    let chrome: EditorChrome
    let highlighter = MarkdownHighlighter()
    private weak var textView: FocusTextView?
    private var url: URL?
    private var dirty = false
    private var pendingSave: DispatchWorkItem?
    private var diskDate: Date?
    private var fontKey = ""
    /// The notes links were last styled against, to restyle them as notes come and go.
    private var linkedNotes: [URL] = []

    init(state: AppState, chrome: EditorChrome) {
        self.state = state
        self.chrome = chrome
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(flush), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(noteRewritten), name: AppState.noteRewritten, object: nil)
        highlighter.linkExists = { [weak self] target in
            guard let self else { return true }
            // `[[#Heading]]` points into this note.
            return LinkResolver.split(target).name.isEmpty || self.state.links.resolve(target, from: self.url) != nil
        }
    }

    func attach(_ tv: FocusTextView) {
        textView = tv
        state.textView = tv
        state.flushSave = { [weak self] in self?.save() }
        tv.openNoteLink = { [weak self] in self?.follow($0) }
        tv.linkResolver = { [weak self] in self?.state.links }
    }

    /// Opens the note a tapped `[[link]]` names; one into this note moves the caret to it.
    private func follow(_ target: String) {
        guard let url else { return }
        let name = LinkResolver.split(target).name
        guard name.isEmpty || state.links.resolve(target, from: url) == url else {
            return state.openLink(target, from: url)
        }
        state.pendingHeading = LinkResolver.heading(in: target)
        showPendingHeading()
    }

    /// Puts the caret on the heading a `[[Note#Heading]]` link pointed into.
    private func showPendingHeading() {
        guard let heading = state.pendingHeading, let tv = textView else { return }
        state.pendingHeading = nil
        guard let line = LinkResolver.headingRange(heading, in: tv.text) else { return }
        tv.selectedRange = NSRange(location: NSMaxRange(line), length: 0)
        tv.scrollRangeToVisible(line)
    }

    /// Takes in links Quill rewrote in this note after notes moved, keeping the caret.
    @objc private func noteRewritten(_ note: Notification) {
        guard let old = note.userInfo?["old"] as? URL, let new = note.userInfo?["new"] as? URL,
              url == old || url == new, let text = try? Coordinated.read(new) else { return }
        url = new
        diskDate = modificationDate(new)
        if let tv = textView, text != tv.text { load(text, keepSelection: true) }
    }

    func sync(url newURL: URL) {
        guard let tv = textView else { return }
        let key = "\(state.editorFont.rawValue)-\(state.fontSize)"
        if key != fontKey {
            fontKey = key
            let fonts = FontSet(state.editorFont, size: CGFloat(state.fontSize))
            highlighter.fonts = fonts
            tv.fonts = fonts
            tv.updateLayout(force: true)
            tv.typingAttributes = highlighter.baseAttributes
            highlighter.highlightAll(tv.textStorage)
            tv.updateFocus(force: true)
        }
        if state.links.notes != linkedNotes {
            linkedNotes = state.links.notes
            highlighter.highlightAll(tv.textStorage)
            tv.updateFocus(force: true)
        }
        tv.typewriter = state.typewriter
        if tv.textInput != state.textInput { tv.textInput = state.textInput }
        if tv.focusEnabled != state.focusEnabled || tv.focusStyle != state.focusStyle {
            tv.focusEnabled = state.focusEnabled
            tv.focusStyle = state.focusStyle
            tv.updateFocus(force: true)
        }
        open(newURL)
    }

    private func open(_ newURL: URL) {
        guard newURL != url, let tv = textView else { return }
        // A rename moves the open file without changing it: keep caret and undo history.
        if url != nil {
            url = newURL
            diskDate = modificationDate(newURL)
            return
        }
        url = newURL
        // Read off the main thread: a file iCloud hasn't downloaded yet arrives only as the
        // read waits for it. Editing stays off until it's in.
        tv.isEditable = false
        let slow = DispatchWorkItem { [weak self] in self?.chrome.downloading = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: slow)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = try? Coordinated.read(newURL)
            DispatchQueue.main.async {
                slow.cancel()
                guard let self, self.url == newURL else { return }
                self.chrome.downloading = false
                // Never let an unreadable file be saved over.
                guard let text else { return }
                self.diskDate = self.modificationDate(newURL)
                self.load(text)
                tv.isEditable = true
                self.showPendingHeading()
            }
        }
    }

    private func load(_ text: String, keepSelection: Bool = false) {
        guard let tv = textView else { return }
        let previous = tv.selectedRange
        tv.text = text
        tv.undoManager?.removeAllActions()
        let length = (text as NSString).length
        tv.selectedRange = keepSelection ? NSRange(location: min(previous.location, length), length: 0)
                                         : NSRange(location: 0, length: 0)
        tv.updateFocus(force: true)
        tv.centerCaret(animated: false)
    }

    @objc private func flush() { save() }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let tv = textView else { return }
        if dirty, let url {
            do {
                try Coordinated.write(tv.text, to: url)
                dirty = false
                diskDate = modificationDate(url)
            } catch {
                NSLog("Quill: failed to save \(url.path): \(error)")
            }
        }
    }

    /// Picks up edits made elsewhere while Quill was in the background.
    @objc private func appBecameActive() {
        guard !dirty, let url, let date = modificationDate(url), date != diskDate else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = try? Coordinated.read(url)
            DispatchQueue.main.async {
                guard let self, let text, self.url == url, !self.dirty, let tv = self.textView else { return }
                self.diskDate = date
                if text != tv.text { self.load(text, keepSelection: true) }
            }
        }
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let tv = textView as? FocusTextView else { return true }
        let edit: TextEdit?
        switch text {
        case "\n" where tv.isSuggesting:
            tv.chooseSuggestion()
            return false
        case "\n":
            edit = MarkdownEdits.newline(in: tv.text, selection: range)
        case "[", "]":
            edit = MarkdownEdits.bracket(text, in: tv.text, selection: range)
        case "" where range.length == 1 && tv.selectedRange.length == 0:
            // Backspace: the caret sits just after the character going.
            edit = MarkdownEdits.backspace(in: tv.text, selection: NSRange(location: NSMaxRange(range), length: 0))
        default:
            edit = nil
        }
        guard let edit else { return true }
        tv.apply(edit)
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        dirty = true
        chrome.setHidden(true)
        self.textView?.updateFocus(force: true)
        self.textView?.centerCaret()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
        self.textView?.updateSuggestions()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        self.textView?.updateFocus()
        self.textView?.centerCaret()
        self.textView?.updateCaret()
        self.textView?.updateSuggestions()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        chrome.setHidden(false)
        save()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        chrome.setHidden(false)
    }

    // MARK: Files

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
