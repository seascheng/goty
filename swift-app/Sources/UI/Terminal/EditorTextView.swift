// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Text view (Esc back, ⌘S save, ⌘±0 zoom)

final class EditorTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onSave: (() -> Void)?
    var onZoom: ((_ delta: CGFloat, _ reset: Bool) -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // tty7 TabSize { tab_size: 4, hard_tabs: false }: Tab types four
    // spaces (undo-coalesced as typing).
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange)
    }

    /// Current-line fill (Zed/tty7 current-line highlight): the
    /// caret's paragraph fragments painted edge-to-edge BEFORE glyphs.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager else { return }
        let sel = selectedRange
        guard sel.length == 0, sel.location <= (string as NSString).length else { return }
        let ns = string as NSString
        var lineStart = 0, lineEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: sel)
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: lineStart,
                                                                length: lineEnd - lineStart),
                                      actualCharacterRange: nil)
        let origin = textContainerOrigin
        let fill = Chrome.theme.lineHighlight
        var glyph = glyphRange.location
        while glyph < NSMaxRange(glyphRange) {
            var frag = NSRange()
            let fragRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &frag,
                                               withoutAdditionalLayout: true)
            // Full bleed: view's left edge to its right edge, the
            // paragraph's fragment height.
            let r = NSRect(x: -origin.x, y: fragRect.minY + origin.y,
                           width: bounds.width, height: fragRect.height)
            fill.setFill()
            r.fill()
            glyph = NSMaxRange(frag)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers ?? "" {
        case "s":
            onSave?()
            return true
        case "+", "=":
            onZoom?(1, false)
            return true
        case "-", "_":
            onZoom?(-1, false)
            return true
        case "0":
            onZoom?(0, true)
            return true
        case "f":
            performFinder(.showFindInterface)
            return true
        case "g":
            performFinder(shift ? .previousMatch : .nextMatch)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Drive the system find bar (usesFindBar + incremental search are
    /// set by EditorPanelView) — NSTextView implements the action; the
    /// item's tag selects which one.
    private func performFinder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = action.rawValue
        performTextFinderAction(item)
    }
}


// MARK: - Line-number gutter (tty7 Input line_number(true))

/// One number per LOGICAL line, right-aligned, synced to the clip
/// view's scroll and the layout manager's finished layouts. Wrapped
/// continuation fragments draw nothing (Xcode rule).
final class EditorLineNumberGutter: NSView {
    override var isFlipped: Bool { true }

    /// Width grows with the digit count of the last line number.
    var onWidthChange: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Character offset of every logical line's first character.
    private(set) var lineStarts: [Int] = [0]

    func attach(to scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        // Relayout (edit, wrap toggle, zoom) moves fragments without a
        // scroll; the manager announces every finished layout pass.
        // (Raw name: this SDK doesn't surface the Swift constant.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw),
            name: Notification.Name("NSLayoutManagerDidLayoutNotification"),
            object: textView.layoutManager)
        invalidate()
    }

    /// Width for the current digit count (min two digits).
    var requiredWidth: CGFloat {
        let digits = max(2, String(lineStarts.count).count)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        return max(34, CGFloat(digits) * advance + 16)
    }

    /// Recompute line starts + width; every text change calls this.
    func invalidate() {
        guard let text = textView?.string else { return }
        let ns = text as NSString
        var starts: [Int] = [0]
        var scan = 0
        while scan < ns.length {
            let hit = ns.range(of: "\n", range: NSRange(location: scan, length: ns.length - scan))
            guard hit.location != NSNotFound else { break }
            starts.append(hit.location + 1)
            scan = hit.location + 1
        }
        lineStarts = starts
        needsDisplay = true
        if abs(requiredWidth - frame.width) > 0.5 { onWidthChange?(requiredWidth) }
    }

    /// 0-based logical line containing `offset` (binary search over
    /// the cached starts — the cursor label rides this too).
    func lineIndex(forCharacterAt offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // Hairline on the editor-facing edge, the separator every
        // tty7 scroll column carries.
        Chrome.theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
              let clip = scrollView?.contentView else { return }
        let textLength = (tv.string as NSString).length
        let visible = clip.bounds
        let origin = tv.textContainerOrigin
        let probe = NSRect(x: visible.minX - origin.x, y: visible.minY - origin.y,
                           width: visible.width, height: visible.height)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: probe, in: container)
        guard visibleGlyphs.length > 0 else { return }
        let firstChar = lm.characterRange(forGlyphRange: visibleGlyphs,
                                          actualGlyphRange: nil).location
        var line = lineIndex(forCharacterAt: firstChar)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Chrome.theme.secondaryText]
        while line < lineStarts.count {
            let start = lineStarts[line]
            guard start < textLength else { break }
            let glyph = lm.glyphRange(forCharacterRange: NSRange(location: start, length: 0),
                                      actualCharacterRange: nil).location
            var frag = NSRange()
            let fragRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &frag,
                                               withoutAdditionalLayout: true)
            let y = fragRect.minY + origin.y - visible.minY
            if y > bounds.height { break }
            if y + fragRect.height >= 0 {
                let label = "\(line + 1)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: bounds.width - size.width - 7,
                                       y: y + (fragRect.height - size.height) / 2),
                           withAttributes: attrs)
            }
            line += 1
        }
    }
}

