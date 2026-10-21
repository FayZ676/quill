import UIKit

/// The writing surface: a centered column, focus dimming, typewriter scrolling and
/// Markdown-aware editing commands.
final class FocusTextView: UITextView {
    var fonts = FontSet(.duo, size: Fonts.defaultSize)
    weak var highlighter: MarkdownHighlighter?
    var focusEnabled = false
    var focusStyle: FocusStyle = .sentence
    var typewriter = false {
        didSet {
            guard typewriter != oldValue else { return }
            updateLayout(force: true)
            centerCaret(animated: false)
        }
    }

    private var layoutKey = ""
    /// The focus range last left undimmed, so a caret move inside it changes nothing.
    private var litFocus: NSRange?
    private static let verticalInset: CGFloat = 24

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        inputAccessoryView = makeKeyBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
    }

    /// Sizes the text column to a comfortable line length and centers it. Heading marks
    /// hang into the left margin when there's room to spare for them.
    func updateLayout(force: Bool = false) {
        let size = bounds.size
        let key = "\(size.width)x\(size.height)-\(fonts.size)-\(fonts.regular.fontName)-\(typewriter)-\(safeAreaInsets)"
        guard force || key != layoutKey, size.width > 0 else { return }
        layoutKey = key

        let width = size.width - safeAreaInsets.left - safeAreaInsets.right
        let margin: CGFloat = width < 500 ? 20 : 32
        let char = fonts.width("0")
        let hangs = width - 2 * margin - fonts.hang >= 45 * char
        if let highlighter, highlighter.hangsHeadings != hangs {
            highlighter.hangsHeadings = hangs
            highlighter.highlightAll(textStorage)
            typingAttributes = highlighter.baseAttributes
            updateFocus(force: true)
        }
        let hang = hangs ? fonts.hang : 0
        let textWidth = max(120, min(char * 68, width - 2 * margin - hang))
        let left = safeAreaInsets.left + max(margin, floor((width - textWidth) / 2) - hang)
        let right = max(0, size.width - left - hang - textWidth)
        let inset = UIEdgeInsets(top: Self.verticalInset, left: left, bottom: Self.verticalInset, right: right)
        if textContainerInset != inset { textContainerInset = inset }

        // Room to scroll the first and last lines up to the middle.
        let half = typewriter ? max(0, floor(size.height / 2) - Self.verticalInset) : 0
        if contentInset.top != half || contentInset.bottom != half {
            contentInset = UIEdgeInsets(top: half, left: 0, bottom: half, right: 0)
        }
    }

    // MARK: Focus mode

    /// Dims everything but the sentence or paragraph being written. TextKit on iOS has no
    /// temporary attributes, so the dimming goes into the text storage: the focus paragraph
    /// is restyled to bring its colors back, and the rest is greyed over.
    func updateFocus(force: Bool = false) {
        guard let highlighter else { return }
        let length = textStorage.length
        guard focusEnabled, length > 0 else {
            if litFocus != nil {
                litFocus = nil
                highlighter.highlightAll(textStorage)
            }
            return
        }
        let focus = focusRange()
        guard force || focus != litFocus else { return }
        litFocus = focus
        let ns = textStorage.string as NSString
        textStorage.beginEditing()
        highlighter.restyle(textStorage, in: ns.paragraphRange(for: focus))
        if focus.location > 0 {
            textStorage.addAttribute(.foregroundColor, value: Theme.dimmed,
                                     range: NSRange(location: 0, length: focus.location))
        }
        let end = NSMaxRange(focus)
        if end < length {
            textStorage.addAttribute(.foregroundColor, value: Theme.dimmed,
                                     range: NSRange(location: end, length: length - end))
        }
        textStorage.endEditing()
    }

    private func focusRange() -> NSRange {
        let ns = textStorage.string as NSString
        let sel = selectedRange
        let paragraph = ns.paragraphRange(for: sel)
        guard focusStyle == .sentence, sel.length == 0 else { return paragraph }
        var found: NSRange?
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, stop in
            if sel.location >= enclosing.location && sel.location < NSMaxRange(enclosing) {
                found = enclosing
                stop.pointee = true
            } else if sel.location == NSMaxRange(enclosing) {
                found = enclosing  // caret at the very end of the paragraph
            }
        }
        return found ?? paragraph
    }

    // MARK: Typewriter scrolling

    func centerCaret(animated: Bool = true) {
        guard typewriter, let end = selectedTextRange?.end else { return }
        layoutManager.ensureLayout(for: textContainer)
        let caret = caretRect(for: end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height + adjustedContentInset.bottom - bounds.height)
        let y = min(maxY, max(minY, caret.midY - bounds.height / 2))
        guard abs(contentOffset.y - y) > 0.5 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated)
    }

    /// UIKit scrolls just enough to keep the caret visible; typewriter mode keeps it centered.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if typewriter { centerCaret(animated: animated) } else { super.scrollRectToVisible(rect, animated: animated) }
    }

    // MARK: Markdown editing

    func apply(_ edit: TextEdit) {
        guard let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length),
              let range = textRange(from: start, to: end) else { return }
        // Through UITextInput, so the edit lands on the undo stack.
        replace(range, withText: edit.text)
        if let selection = edit.selection { selectedRange = selection }
        // Mark it unsaved even where UIKit doesn't report programmatic edits (a repeat is harmless).
        delegate?.textViewDidChange?(self)
    }

    @objc func bold() { apply(MarkdownEdits.toggleWrap("**", in: text, selection: selectedRange)) }
    @objc func italic() { apply(MarkdownEdits.toggleWrap("_", in: text, selection: selectedRange)) }
    @objc func strikethrough() { apply(MarkdownEdits.toggleWrap("~~", in: text, selection: selectedRange)) }
    @objc func inlineCode() { apply(MarkdownEdits.toggleWrap("`", in: text, selection: selectedRange)) }
    @objc func link() { apply(MarkdownEdits.link(in: text, selection: selectedRange)) }
    @objc func heading() { apply(MarkdownEdits.cycleHeading(in: text, selection: selectedRange)) }
    @objc func bullet() { apply(MarkdownEdits.toggleBullet(in: text, selection: selectedRange)) }
    @objc private func toggleFocus() { AppState.shared.focusEnabled.toggle() }
    @objc private func toggleTypewriter() { AppState.shared.typewriter.toggle() }

    /// For a hardware keyboard, matching the Mac app.
    override var keyCommands: [UIKeyCommand]? {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            command("Bold", "b", .command, #selector(bold)),
            command("Italic", "i", .command, #selector(italic)),
            command("Link", "k", .command, #selector(link)),
            command("Inline Code", "c", [.command, .shift], #selector(inlineCode)),
            command("Strikethrough", "x", [.command, .shift], #selector(strikethrough)),
            command("Focus Mode", "d", [.command, .shift], #selector(toggleFocus)),
            command("Typewriter Scrolling", "t", [.command, .shift], #selector(toggleTypewriter)),
        ]
    }

    /// Markdown shortcuts above the on-screen keyboard.
    private func makeKeyBar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func item(_ symbol: String, _ label: String, _ action: Selector) -> UIBarButtonItem {
            let b = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
            b.accessibilityLabel = label
            return b
        }
        // Adjacent items share one glass capsule; a flexible space would split each into its
        // own, too wide for a phone.
        bar.items = [
            item("number", "Heading", #selector(heading)),
            item("bold", "Bold", #selector(bold)),
            item("italic", "Italic", #selector(italic)),
            item("list.bullet", "List", #selector(bullet)),
            item("link", "Link", #selector(link)),
            item("chevron.left.forwardslash.chevron.right", "Code", #selector(inlineCode)),
            UIBarButtonItem(systemItem: .flexibleSpace),
            item("keyboard.chevron.compact.down", "Hide Keyboard", #selector(resignFirstResponder)),
        ]
        bar.tintColor = Theme.accent
        bar.sizeToFit()
        return bar
    }
}
