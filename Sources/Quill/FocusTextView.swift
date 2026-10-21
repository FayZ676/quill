import AppKit

/// The writing surface: a centered column with hanging heading marks, focus dimming,
/// typewriter scrolling and Markdown-aware editing commands.
final class FocusTextView: NSTextView {
    var fonts = FontSet(.duo, size: AppState.defaultFontSize)
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

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))[ \t]+(\[[ xX]\][ \t]+)?|^([ \t]*>[ \t]?)"#)

    /// Continues lists and quotes on Return; Return on an empty item ends the list.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location)) as NSString

        guard sel.length == 0,
              let m = Self.listPrefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              sel.location >= lineRange.location + m.range.length
        else { return super.insertNewline(sender) }

        if m.range.length == line.length {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: m.range.length))
            return
        }

        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : line.substring(with: r)
        }
        let next: String
        if let quote = group(6) {
            next = quote
        } else {
            let marker = group(2) ?? "\((Int(group(3) ?? "") ?? 0) + 1)\(group(4) ?? ".")"
            next = (group(1) ?? "") + marker + " " + (group(5) != nil ? "[ ] " : "")
        }
        insertText("\n" + next, replacementRange: sel)
    }

    /// Wraps the selection in `marker`, or unwraps it if it is already wrapped.
    func toggleWrap(_ marker: String) {
        let ns = string as NSString
        let sel = selectedRange()
        let m = (marker as NSString).length
        let inner = ns.substring(with: sel)

        if sel.length >= 2 * m, inner.hasPrefix(marker), inner.hasSuffix(marker) {
            let unwrapped = (inner as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            replace(sel, with: unwrapped, select: NSRange(location: sel.location, length: sel.length - 2 * m))
        } else if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
                  ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            replace(NSRange(location: sel.location - m, length: sel.length + 2 * m), with: inner,
                    select: NSRange(location: sel.location - m, length: sel.length))
        } else {
            replace(sel, with: marker + inner + marker, select: NSRange(location: sel.location + m, length: sel.length))
        }
    }

    func insertLink() {
        let sel = selectedRange()
        let text = (string as NSString).substring(with: sel)
        let caret = text.isEmpty ? sel.location + 1 : sel.location + (text as NSString).length + 3
        replace(sel, with: "[\(text)]()", select: NSRange(location: caret, length: 0))
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        insertText(text, replacementRange: range)
        setSelectedRange(select)
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

