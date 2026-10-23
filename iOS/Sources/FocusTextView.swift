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
        // One tap for both, so neither waits on the other: it ticks a task's box or opens a link.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedLink))
        linkTapDelegate.isOnLink = { [weak self, weak tap] in
            guard let self, let tap else { return false }
            let point = tap.location(in: self)
            return self.taskBox(at: point) != nil || self.noteLink(at: point) != nil
        }
        tap.delegate = linkTapDelegate
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
        updateCaret()
    }

    // MARK: Caret

    private static let caretWidth: CGFloat = 2.5
    private let caretView = CaretView()

    /// UIKit's caret blinks on its own clock and runs the full line height, line spacing
    /// included. Like the Mac app's, this one is a glowing layer that fades. UIKit still
    /// shows and hides its own cursor view as it likes, so that view is masked out entirely.
    private func hideSystemCaret() {
        func cursors(in view: UIView) -> [UIView] {
            view.subviews.flatMap { $0 is any UITextCursorView ? [$0] : cursors(in: $0) }
        }
        for cursor in cursors(in: self) where cursor.layer.mask == nil {
            cursor.layer.mask = CALayer()
        }
    }

    /// Puts the caret where the selection is, or hides it when there's a selection or no focus.
    func updateCaret() {
        hideSystemCaret()
        guard isFirstResponder, selectedRange.length == 0, let end = selectedTextRange?.end else {
            return caretView.hide()
        }
        var caret = caretRect(for: end)
        guard !caret.isNull, !caret.isInfinite else { return caretView.hide() }
        caret.size.width = Self.caretWidth
        caret.size.height = min(caret.height, fonts.regular.lineHeight)
        if caretView.superview == nil { addSubview(caretView) }
        caretView.show(at: caret)
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { updateCaret() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { caretView.hide() }
        return resigned
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

    /// Dims everything but the sentence or paragraph being written. The dimming happens as
    /// the text is drawn (see FocusLayoutManager), never in the text storage: an edit there,
    /// even to colors alone, would wipe iOS's spelling marks.
    func updateFocus(force: Bool = false) {
        guard let manager = layoutManager as? FocusLayoutManager else { return }
        manager.reveal(around: selectedRange)
        let focus = focusEnabled && textStorage.length > 0 ? focusRange() : nil
        guard force || focus != litFocus else { return }
        litFocus = focus
        manager.focus = focus
        manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
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

    /// UIKit scrolls just enough to keep the caret visible, leaving the line being written
    /// flush against the keyboard; this keeps a couple of lines clear around it instead.
    /// Typewriter mode keeps it centered.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        if typewriter { return centerCaret(animated: animated) }
        let room = fonts.regular.lineHeight * 2
        super.scrollRectToVisible(rect.insetBy(dx: 0, dy: -room), animated: animated)
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

    // MARK: Tasks

    /// The task box under `point` (in this view's coordinates), if any.
    private func taskBox(at point: CGPoint) -> NSRange? {
        guard let manager = layoutManager as? MarkdownLayoutManager else { return nil }
        return manager.taskBox(at: CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top),
                               in: textContainer)
    }


    @objc func bold() { apply(MarkdownEdits.toggleWrap("**", in: text, selection: selectedRange)) }
    @objc func italic() { apply(MarkdownEdits.toggleWrap("_", in: text, selection: selectedRange)) }
    @objc func strikethrough() { apply(MarkdownEdits.toggleWrap("~~", in: text, selection: selectedRange)) }
    @objc func inlineCode() { apply(MarkdownEdits.toggleWrap("`", in: text, selection: selectedRange)) }
    @objc func link() { apply(MarkdownEdits.link(in: text, selection: selectedRange)) }
    @objc func heading() { apply(MarkdownEdits.cycleHeading(in: text, selection: selectedRange)) }
    @objc func bullet() { apply(MarkdownEdits.toggleList(ordered: false, in: text, selection: selectedRange)) }
    @objc func task() { apply(MarkdownEdits.toggleTask(in: text, selection: selectedRange)) }
    @objc func divider() { apply(MarkdownEdits.divider(in: text, selection: selectedRange)) }
    @objc func numbered() { apply(MarkdownEdits.toggleList(ordered: true, in: text, selection: selectedRange)) }
    @objc private func toggleFocus() { AppState.shared.focusEnabled.toggle() }
    @objc private func toggleTypewriter() { AppState.shared.typewriter.toggle() }

    /// For a hardware keyboard, matching the Mac app.
    override var keyCommands: [UIKeyCommand]? {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        // Arrows, Tab and Escape work the note suggestions while they're up.
        let suggesting = isSuggesting ? [
            command("Previous Note", UIKeyCommand.inputUpArrow, [], #selector(previousSuggestion)),
            command("Next Note", UIKeyCommand.inputDownArrow, [], #selector(nextSuggestion)),
            command("Choose Note", "\t", [], #selector(chooseSelectedSuggestion)),
            command("Close Suggestions", UIKeyCommand.inputEscape, [], #selector(dismissSuggestions)),
        ] : []
        return suggesting + [
            command("Bold", "b", .command, #selector(bold)),
            command("Italic", "i", .command, #selector(italic)),
            command("Link", "k", .command, #selector(link)),
            command("Inline Code", "c", [.command, .shift], #selector(inlineCode)),
            command("Strikethrough", "x", [.command, .shift], #selector(strikethrough)),
            command("Focus Mode", "d", [.command, .shift], #selector(toggleFocus)),
            command("Typewriter Scrolling", "t", [.command, .shift], #selector(toggleTypewriter)),
        ]
    }

    /// Markdown shortcuts above the on-screen keyboard: a flat strip of icons on the page color.
    private func makeKeyBar() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        bar.autoresizingMask = .flexibleWidth
        bar.backgroundColor = Theme.background

        let rule = UIView()
        rule.backgroundColor = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(rule)

        func button(_ symbol: String, _ label: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal)
            b.tintColor = .secondaryLabel
            b.accessibilityLabel = label
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return b
        }
        // More than fit across a phone, so the formatting buttons scroll; Hide Keyboard stays put.
        // The everyday ones come first, to fit before the edge; the rarer ones scroll in.
        let stack = UIStackView(arrangedSubviews: [
            button("number", "Heading", #selector(heading)),
            button("bold", "Bold", #selector(bold)),
            button("italic", "Italic", #selector(italic)),
            button("link", "Link", #selector(link)),
            button("list.bullet", "Bulleted List", #selector(bullet)),
            button("list.number", "Numbered List", #selector(numbered)),
            button("checklist", "Task", #selector(task)),
            button("chevron.left.forwardslash.chevron.right", "Code", #selector(inlineCode)),
            button("strikethrough", "Strikethrough", #selector(strikethrough)),
            button("minus", "Divider", #selector(divider)),
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = FadingScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        bar.addSubview(scroll)
        let hide = button("keyboard.chevron.compact.down", "Hide Keyboard", #selector(resignFirstResponder))
        hide.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(hide)
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(divider)
        shortcutRow = scroll

        // In the shortcuts' place while a `[[link]]` is typed: the notes it could be.
        suggestionRow.axis = .horizontal
        suggestionRow.spacing = 4
        suggestionRow.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.showsHorizontalScrollIndicator = false
        suggestionBar.isHidden = true
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.addSubview(suggestionRow)
        bar.addSubview(suggestionBar)

        let guide = bar.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: bar.topAnchor),
            suggestionBar.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            suggestionBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 6),
            suggestionBar.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            suggestionRow.topAnchor.constraint(equalTo: suggestionBar.contentLayoutGuide.topAnchor),
            suggestionRow.bottomAnchor.constraint(equalTo: suggestionBar.contentLayoutGuide.bottomAnchor),
            suggestionRow.leadingAnchor.constraint(equalTo: suggestionBar.contentLayoutGuide.leadingAnchor),
            suggestionRow.trailingAnchor.constraint(equalTo: suggestionBar.contentLayoutGuide.trailingAnchor),
            suggestionRow.heightAnchor.constraint(equalTo: suggestionBar.frameLayoutGuide.heightAnchor),
            rule.topAnchor.constraint(equalTo: bar.topAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            hide.topAnchor.constraint(equalTo: bar.topAnchor),
            hide.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            hide.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
            divider.trailingAnchor.constraint(equalTo: hide.leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            divider.heightAnchor.constraint(equalToConstant: 20),
        ])
        return bar
    }

    // MARK: Links

    /// Called with the note a tapped `[[link]]` names.
    var openNoteLink: ((String) -> Void)?
    /// The library's notes, for suggesting them as a link is typed.
    var linkResolver: () -> LinkResolver? = { nil }
    private let suggester = LinkSuggester()
    private let linkTapDelegate = LinkTapDelegate()
    private weak var shortcutRow: UIView?
    private let suggestionBar = UIScrollView()
    private let suggestionRow = UIStackView()

    var isSuggesting: Bool { suggester.isShowing }

    /// Taps on a link open it, as in Obsidian; taps anywhere else place the caret as usual.
    /// A tap on a task's box ticks it, without moving the caret or raising the keyboard.
    @objc private func tappedLink(_ tap: UITapGestureRecognizer) {
        if let box = taskBox(at: tap.location(in: self)) {
            return apply(MarkdownEdits.tick(box, in: text, selection: selectedRange))
        }
        if let target = noteLink(at: tap.location(in: self)) { openNoteLink?(target) }
    }

    private func noteLink(at point: CGPoint) -> String? {
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        // The nearest glyph can lie well away from the tap, past the end of a line.
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                .insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        let i = layoutManager.characterIndexForGlyph(at: glyph)
        guard i < textStorage.length else { return nil }
        return textStorage.attribute(.noteLink, at: i, effectiveRange: nil) as? String
    }

    /// Offers notes while a `[[link]]` is being typed; call when the text or selection changes.
    func updateSuggestions() {
        suggester.update(text: text, caret: selectedRange, resolver: linkResolver())
        showSuggestions()
    }

    func chooseSuggestion(_ index: Int? = nil) {
        guard let edit = suggester.choose(index, in: text) else { return }
        apply(edit)
        showSuggestions()
    }

    @objc private func chooseSelectedSuggestion() { chooseSuggestion() }
    @objc private func previousSuggestion() { suggester.move(-1); showSuggestions() }
    @objc private func nextSuggestion() { suggester.move(1); showSuggestions() }
    @objc private func dismissSuggestions() { suggester.dismiss(); showSuggestions() }

    private func showSuggestions() {
        let showing = suggester.isShowing
        suggestionBar.isHidden = !showing
        shortcutRow?.isHidden = showing
        suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard showing else { return }
        for (i, item) in suggester.items.enumerated() {
            var config = UIButton.Configuration.plain()
            config.attributedTitle = AttributedString(item.name, attributes: AttributeContainer([
                .font: fonts.regular.withSize(15),
                .foregroundColor: Theme.text,
            ]))
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.background.cornerRadius = 6
            config.background.backgroundColor = i == suggester.selected ? Theme.accent.withAlphaComponent(0.18) : .clear
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.chooseSuggestion(i)
            })
            button.accessibilityLabel = item.folder.isEmpty ? item.name : "\(item.name), in \(item.folder)"
            suggestionRow.addArrangedSubview(button)
        }
        suggestionBar.setContentOffset(.zero, animated: false)
    }

    // MARK: Text input

    var textInput: TextInput {
        get {
            var input = TextInput()
            input.checkSpelling = spellCheckingType == .yes
            input.correctSpelling = autocorrectionType == .yes
            input.predictive = inlinePredictionType == .yes
            input.smartCopyPaste = smartInsertDeleteType == .yes
            input.smartQuotes = smartQuotesType == .yes
            input.smartDashes = smartDashesType == .yes
            return input
        }
        set {
            spellCheckingType = newValue.checkSpelling ? .yes : .no
            autocorrectionType = newValue.correctSpelling ? .yes : .no
            inlinePredictionType = newValue.predictive ? .yes : .no
            smartInsertDeleteType = newValue.smartCopyPaste ? .yes : .no
            smartQuotesType = newValue.smartQuotes ? .yes : .no
            smartDashesType = newValue.smartDashes ? .yes : .no
            // The keyboard reads these when it comes up; one already up needs telling.
            if isFirstResponder { reloadInputViews() }
        }
    }
}

/// Lets the link tap go first, and only on a link or a task's box: the text view's own taps wait to see
/// whether it was one before placing the caret.
private final class LinkTapDelegate: NSObject, UIGestureRecognizerDelegate {
    var isOnLink: () -> Bool = { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { isOnLink() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UITapGestureRecognizer
    }
}

/// Draws the text outside `focus` in the dimmed gray, as the Mac app does with temporary
/// attributes, which TextKit on iOS doesn't have.
final class FocusLayoutManager: MarkdownLayoutManager {
    /// The characters drawn in their own colors; nil draws everything that way.
    var focus: NSRange?
    private var dimming = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let focus else { return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin) }
        let lit = glyphRange(forCharacterRange: focus, actualCharacterRange: nil)
        let start = glyphsToShow.location, end = NSMaxRange(glyphsToShow)
        let litStart = min(max(lit.location, start), end), litEnd = min(max(NSMaxRange(lit), litStart), end)
        for (range, dim) in [(NSRange(location: start, length: litStart - start), true),
                             (NSRange(location: litStart, length: litEnd - litStart), false),
                             (NSRange(location: litEnd, length: end - litEnd), true)] where range.length > 0 {
            dimming = dim
            super.drawGlyphs(forGlyphRange: range, at: origin)
        }
        dimming = false
    }

    override func ruleColor(at index: Int) -> UIColor {
        guard let focus, !NSLocationInRange(index, focus) else { return super.ruleColor(at: index) }
        return Theme.dimmed
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int,
                               font: UIFont, textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any] = [:], in context: CGContext) {
        var attributes = attributes
        if dimming {
            attributes[.foregroundColor] = Theme.dimmed
            context.setFillColor(Theme.dimmed.cgColor)
        }
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: context)
    }
}

/// A horizontal scroller whose edges fade out wherever there's more to scroll to, so a
/// clipped button reads as "swipe for more" rather than a mistake.
private final class FadingScrollView: UIScrollView {
    private static let fade: CGFloat = 28
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        layer.mask = gradient
    }

    required init?(coder: NSCoder) { fatalError() }

    // Runs on every scroll step too, so the fades follow the position.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let more = contentSize.width - width
        let left = contentOffset.x > 1 ? Self.fade / width : 0
        let right = contentOffset.x < more - 1 ? Self.fade / width : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds  // In scrolled coordinates, so it stays on screen.
        gradient.locations = [0, left, 1 - right, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
    }
}

/// The caret: a glowing bar that holds steady while the writer types or moves, then
/// breathes in and out, as in the Mac app.
private final class CaretView: UIView {
    private static let glow: CGFloat = 4
    private static let pad: CGFloat = 12
    private let bar = UIView()

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        bar.backgroundColor = Theme.accent
        bar.layer.cornerRadius = 1
        bar.layer.shadowOffset = .zero
        bar.layer.shadowRadius = Self.glow
        bar.layer.shadowOpacity = 0.85
        addSubview(bar)
        applyColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CaretView, _) in view.applyColor() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the caret at `caret`. A move (every keystroke is one) holds it solid for a beat again.
    func show(at caret: CGRect) {
        // The view is padded so the glow isn't clipped at its edges.
        let frame = caret.insetBy(dx: -Self.pad, dy: -Self.pad)
        guard isHidden || frame != self.frame else { return }
        UIView.performWithoutAnimation {
            self.frame = frame
            bar.frame = CGRect(x: Self.pad, y: Self.pad, width: caret.width, height: caret.height)
        }
        isHidden = false
        superview?.bringSubviewToFront(self)
        restartPulse()
    }

    func hide() {
        isHidden = true
        layer.removeAnimation(forKey: "pulse")
    }

    /// Solid for a beat, then a slow fade out and back in, forever.
    private func restartPulse() {
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

    /// CGColors don't follow light and dark mode on their own, so resolve the glow's per appearance.
    private func applyColor() {
        bar.layer.shadowColor = Theme.accent.resolvedColor(with: traitCollection).cgColor
    }
}
