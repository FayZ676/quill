import AppKit
import SwiftUI

/// The writing surface: a centered column with hanging heading marks, focus dimming,
/// typewriter scrolling and Markdown-aware editing commands.
final class FocusTextView: NSTextView {
    var fonts = FontSet(.sans, size: Fonts.defaultSize)
    var focusEnabled = false
    var focusStyle: FocusStyle = .sentence
    var typewriter = false {
        didSet {
            guard typewriter != oldValue else { return }
            updateLayout()
            centerCaret(animated: false)
        }
    }

    private var originX: CGFloat = 0
    private var observingClip = false
    private static let margin: CGFloat = 32
    private static let verticalInset: CGFloat = 72

    private static let caretWidth: CGFloat = 2.5
    private let caretView = CaretView()

    /// AppKit's caret blinks hard on and off; this one is a layer that fades. AppKit still
    /// says where the caret goes, through this call, but never gets to draw it. The rect
    /// covers the whole line fragment, including the line spacing below the text, so it's
    /// trimmed to the font's own line height to match the glyphs.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caret = rect
        caret.size.width = Self.caretWidth
        if let lm = layoutManager {
            caret.size.height = min(rect.height, lm.defaultLineHeight(for: fonts.regular))
        }
        if caretView.superview == nil { addSubview(caretView) }
        caretView.show(at: caret, color: color)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        if !shouldDrawInsertionPoint || selectedRange().length > 0 {
            caretView.hide()
        } else if restartFlag {
            caretView.restartPulse()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { caretView.hide() }
        return resigned
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: originX, y: textContainerInset.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !observingClip, let clip = enclosingScrollView?.contentView {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                                   name: NSView.frameDidChangeNotification, object: clip)
            observingClip = true
        }
        updateLayout()
    }

    @objc private func clipResized() {
        updateLayout()
        centerCaret(animated: false)
    }

    /// Sizes the text column to a comfortable line length and centers it, leaving the
    /// heading hang in the left margin.
    func updateLayout() {
        guard let clip = enclosingScrollView?.contentView, let container = textContainer else { return }
        let size = clip.bounds.size
        let hang = fonts.hang
        let maxText = fonts.width("0") * 68
        let textWidth = max(120, min(maxText, size.width - 2 * Self.margin - hang))
        originX = max(Self.margin, floor((size.width - textWidth) / 2) - hang)
        container.containerSize = NSSize(width: hang + textWidth, height: .greatestFiniteMagnitude)

        let inset = typewriter ? max(Self.verticalInset, floor(size.height / 2)) : Self.verticalInset
        if textContainerInset.height != inset { textContainerInset = NSSize(width: 0, height: inset) }
        minSize = NSSize(width: 0, height: size.height)
        invalidateTextContainerOrigin()
        sizeToFit()
        needsDisplay = true
    }

    // MARK: Focus mode

    func updateFocus() {
        guard let lm = layoutManager else { return }
        (lm as? MarkdownLayoutManager)?.reveal(around: selectedRange())
        let length = (string as NSString).length
        let all = NSRange(location: 0, length: length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard focusEnabled, length > 0 else { return }
        let focus = focusRange()
        if focus.location > 0 {
            lm.addTemporaryAttribute(.foregroundColor, value: Theme.dimmed,
                                     forCharacterRange: NSRange(location: 0, length: focus.location))
        }
        let end = NSMaxRange(focus)
        if end < length {
            lm.addTemporaryAttribute(.foregroundColor, value: Theme.dimmed,
                                     forCharacterRange: NSRange(location: end, length: length - end))
        }
    }

    private func focusRange() -> NSRange {
        let ns = string as NSString
        let sel = selectedRange()
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
        guard typewriter, let lm = layoutManager, let container = textContainer,
              let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let location = selectedRange().location
        lm.ensureLayout(for: container)

        let glyph = lm.glyphIndexForCharacter(at: location)
        let line: NSRect
        if glyph >= lm.numberOfGlyphs, lm.extraLineFragmentTextContainer != nil {
            line = lm.extraLineFragmentRect
        } else if lm.numberOfGlyphs > 0 {
            line = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        } else {
            line = .zero
        }

        let maxY = max(0, frame.height - clip.bounds.height)
        let y = min(maxY, max(0, line.midY + textContainerOrigin.y - clip.bounds.height / 2))
        let target = NSPoint(x: clip.bounds.origin.x, y: y)
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if typewriter { centerCaret() } else { super.scrollRangeToVisible(range) }
    }

    // MARK: Markdown editing

    /// Continues lists and quotes on Return; Return on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        if suggester.isShowing { return chooseSuggestion() }
        guard let edit = MarkdownEdits.newline(in: string, selection: selectedRange())
        else { return super.insertNewline(sender) }
        apply(edit)
    }

    /// Wraps the selection in `marker`, or unwraps it if it is already wrapped.
    func toggleWrap(_ marker: String) {
        apply(MarkdownEdits.toggleWrap(marker, in: string, selection: selectedRange()))
    }

    func insertLink() {
        apply(MarkdownEdits.link(in: string, selection: selectedRange()))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if taskBox(at: event) != nil { NSCursor.pointingHand.set() }
    }

    private func taskBox(at event: NSEvent) -> NSRange? {
        guard let lm = layoutManager as? MarkdownLayoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return lm.taskBox(at: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
                          in: container)
    }

    private func apply(_ edit: TextEdit) {
        insertText(edit.text, replacementRange: edit.range)
        if let selection = edit.selection { setSelectedRange(selection) }
    }

    // MARK: Links

    /// Called with the note a `[[link]]` names when it's ⌘-clicked.
    var openNoteLink: ((String) -> Void)?
    /// The library's notes, for suggesting them as a link is typed.
    var linkResolver: () -> LinkResolver? = { nil }
    /// The font chosen for the page, for the suggestion list to match.
    var editorFont = EditorFont.sans
    private let suggester = LinkSuggester()
    /// Made the first time there are notes to suggest.
    private var suggestionView: NSHostingView<LinkSuggestionList>?

    /// A click on a task's box ticks it, without moving the caret; ⌘-click opens a link.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let box = taskBox(at: event) {
            return apply(MarkdownEdits.tick(box, in: string, selection: selectedRange()))
        }
        if event.modifierFlags.contains(.command),
           let target = noteLink(at: convert(event.locationInWindow, from: nil)) {
            openNoteLink?(target)
            return
        }
        super.mouseDown(with: event)
    }

    private func noteLink(at point: NSPoint) -> String? {
        guard let storage = textStorage else { return nil }
        let i = characterIndexForInsertion(at: point)
        // The insertion point nearest a click can fall just after the character clicked.
        for index in [i, i - 1] where index >= 0 && index < storage.length {
            if let target = storage.attribute(.noteLink, at: index, effectiveRange: nil) as? String { return target }
        }
        return nil
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        // Typed brackets only; edits made through `apply` name their range.
        if replacementRange.location == NSNotFound, let typed = text as? String,
           let edit = MarkdownEdits.bracket(typed, in: string, selection: selectedRange()) {
            return apply(edit)
        }
        super.insertText(text, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let edit = MarkdownEdits.backspace(in: string, selection: selectedRange()) else {
            return super.deleteBackward(sender)
        }
        apply(edit)
    }

    override func moveUp(_ sender: Any?) {
        guard suggester.isShowing else { return super.moveUp(sender) }
        suggester.move(-1)
        showSuggestions()
    }

    override func moveDown(_ sender: Any?) {
        guard suggester.isShowing else { return super.moveDown(sender) }
        suggester.move(1)
        showSuggestions()
    }

    override func insertTab(_ sender: Any?) {
        guard suggester.isShowing else { return super.insertTab(sender) }
        chooseSuggestion()
    }

    /// Escape.
    override func cancelOperation(_ sender: Any?) {
        guard suggester.isShowing else { return super.cancelOperation(sender) }
        suggester.dismiss()
        showSuggestions()
    }

    /// Offers notes while a `[[link]]` is being typed; call when the text or selection changes.
    func updateSuggestions() {
        suggester.update(text: string, caret: selectedRange(), resolver: linkResolver())
        showSuggestions()
    }

    private func chooseSuggestion(_ index: Int? = nil) {
        guard let edit = suggester.choose(index, in: string) else { return }
        // A click on the list may have taken the keyboard.
        window?.makeFirstResponder(self)
        apply(edit)
        showSuggestions()
    }

    /// Puts the list just under the start of the name being typed, or takes it away.
    private func showSuggestions() {
        guard suggester.isShowing, let query = suggester.query, let lm = layoutManager, let container = textContainer else {
            suggestionView?.removeFromSuperview()
            return
        }
        let list = LinkSuggestionList(items: suggester.items, selected: suggester.selected, font: editorFont) {
            [weak self] i in self?.chooseSuggestion(i)
        }
        let view = suggestionView ?? NSHostingView(rootView: list)
        suggestionView = view
        view.rootView = list
        // The `[[` opening the link.
        let glyph = lm.glyphIndexForCharacter(at: query.location - 2)
        var line = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        line.origin.x += textContainerOrigin.x
        line.origin.y += textContainerOrigin.y
        let size = LinkSuggestionList.size(for: suggester.items.count)
        // The shadow margin sits outside the card, so line the card up with the text.
        let margin = LinkSuggestionList.margin
        let x = min(line.minX - margin, bounds.width - size.width)
        view.frame = NSRect(x: max(0, x), y: line.maxY + 6 - margin, width: size.width, height: size.height)
        if view.superview == nil { addSubview(view) }
    }

    // MARK: Text input

    /// Called when the Edit menu's spelling and substitution items change a setting.
    var textInputChanged: ((TextInput) -> Void)?

    var textInput: TextInput {
        get {
            var input = TextInput()
            input.checkSpelling = isContinuousSpellCheckingEnabled
            input.checkGrammar = isGrammarCheckingEnabled
            input.correctSpelling = isAutomaticSpellingCorrectionEnabled
            if #available(macOS 14.0, *) { input.predictive = inlinePredictionType == .yes }
            input.smartCopyPaste = smartInsertDeleteEnabled
            input.smartQuotes = isAutomaticQuoteSubstitutionEnabled
            input.smartDashes = isAutomaticDashSubstitutionEnabled
            input.textReplacement = isAutomaticTextReplacementEnabled
            return input
        }
        set {
            isContinuousSpellCheckingEnabled = newValue.checkSpelling
            isGrammarCheckingEnabled = newValue.checkGrammar
            isAutomaticSpellingCorrectionEnabled = newValue.correctSpelling
            if #available(macOS 14.0, *) { inlinePredictionType = newValue.predictive ? .yes : .no }
            smartInsertDeleteEnabled = newValue.smartCopyPaste
            isAutomaticQuoteSubstitutionEnabled = newValue.smartQuotes
            isAutomaticDashSubstitutionEnabled = newValue.smartDashes
            isAutomaticTextReplacementEnabled = newValue.textReplacement
            // Turning a check on only covers what's typed next; mark what's already there.
            // Spelling and grammar only, so nothing on the page is corrected or replaced.
            var types: NSTextCheckingTypes = 0
            if newValue.checkSpelling { types |= NSTextCheckingResult.CheckingType.spelling.rawValue }
            if newValue.checkGrammar { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
            if types != 0 {
                checkText(in: NSRange(location: 0, length: (string as NSString).length), types: types, options: [:])
            }
        }
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        textInputChanged?(textInput)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        textInputChanged?(textInput)
    }

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        super.toggleAutomaticSpellingCorrection(sender)
        textInputChanged?(textInput)
    }

    override func toggleSmartInsertDelete(_ sender: Any?) {
        super.toggleSmartInsertDelete(sender)
        textInputChanged?(textInput)
    }

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
        super.toggleAutomaticQuoteSubstitution(sender)
        textInputChanged?(textInput)
    }

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {
        super.toggleAutomaticDashSubstitution(sender)
        textInputChanged?(textInput)
    }

    override func toggleAutomaticTextReplacement(_ sender: Any?) {
        super.toggleAutomaticTextReplacement(sender)
        textInputChanged?(textInput)
    }
}

/// The caret: a glowing bar that holds steady while the writer types or moves, then
/// breathes in and out.
private final class CaretView: NSView {
    private static let glow: CGFloat = 4
    private static let pad: CGFloat = 12
    private let bar = CALayer()
    private var color = NSColor.controlAccentColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        bar.cornerRadius = 1
        bar.shadowOffset = .zero
        bar.shadowRadius = Self.glow
        bar.shadowOpacity = 0.85
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(at caret: NSRect, color: NSColor) {
        // The view is padded so the glow isn't clipped at its edges.
        let frame = caret.insetBy(dx: -Self.pad, dy: -Self.pad)
        guard isHidden || frame != self.frame || color != self.color else { return }
        self.color = color
        self.frame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = NSRect(x: Self.pad, y: Self.pad, width: caret.width, height: caret.height)
        applyColor()
        CATransaction.commit()
        isHidden = false
        restartPulse()
    }

    func hide() {
        isHidden = true
        layer?.removeAnimation(forKey: "pulse")
    }

    /// Solid for a beat, then a slow fade out and back in, forever.
    func restartPulse() {
        guard let layer, !isHidden else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0
        pulse.duration = 0.55
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.beginTime = CACurrentMediaTime() + 0.5
        pulse.fillMode = .backwards
        layer.add(pulse, forKey: "pulse")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    /// CGColors don't follow light and dark mode on their own, so resolve them per appearance.
    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = color.cgColor
            bar.shadowColor = color.cgColor
        }
    }
}

