// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Commit message box (⌘⏎ commits; tty7: soft fill, one line at
// MARK: - rest, grows to six)


// MARK: - Commit message box (⌘⏎ commits; tty7: soft fill, one line at
// MARK: - rest, grows to six)

final class CommitMessageView: NSScrollView {
    var onCommandEnter: (() -> Void)?

    private let textView = CommitTextView()
    private let placeholder = NSTextField(labelWithString: "Message (⌘⏎ to commit)")
    private var heightConstraint: NSLayoutConstraint!

    /// tty7's arithmetic: pad 5 + one 20pt line + pad 5 at rest, ceiling
    /// six bare lines. A box that stands four lines tall before anything
    /// has been typed pushes the file list off a 260pt column.
    private static let pad: CGFloat = 5
    private static let line: CGFloat = 20
    private static let maxLines = 6

    var text: String {
        textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : textView.string
    }

    func clear() { textView.string = ""; updatePlaceholder(); fitHeight() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = false
        // The box must DRAW its own soft fill: with drawsBackground =
        // false the clip-view background assignment is ignored and only
        // the panel surface (near-black) showed — the input vanished.
        drawsBackground = true
        backgroundColor = Chrome.theme.hoverFill
        borderType = .noBorder
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        textView.font = .systemFont(ofSize: 12, weight: .regular)
        textView.textColor = Chrome.theme.foreground
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: Self.pad)
        textView.delegate = self
        textView.onFocusChange = { [weak self] _ in self?.updatePlaceholder() }
        documentView = textView

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = Chrome.theme.secondaryText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        // Anchored to the scroll view itself, never the clip view — the
        // clip view scrolls under the document view. Top follows the
        // text block's centered inset (fitHeight keeps both in step).
        placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9).isActive = true
        placeholderTop = placeholder.topAnchor.constraint(equalTo: topAnchor,
                                                            constant: Self.pad + 1)
        placeholderTop.isActive = true

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.pad * 2 + Self.line)
        heightConstraint.isActive = true
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.specialKey == .carriageReturn {
            onCommandEnter?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Placeholder shows only when unfocused AND empty — a caret sitting
    /// on top of the hint reads as one broken string.
    private func updatePlaceholder() {
        let focused = window?.firstResponder === textView
        placeholder.isHidden = focused || !textView.string.isEmpty
    }

    private var placeholderTop: NSLayoutConstraint!

    /// Box height AND text vertical centering, computed together (one
    /// truth): the document block sits mid-viewport at every line
    /// count — the caret must sit where the eye expects it, not pinned
    /// to the clip view's top edge.
    private func fitHeight() {
        let lines = max(1, textView.string.split(separator: "\n",
                                                  omittingEmptySubsequences: false).count)
        let n = CGFloat(min(lines, Self.maxLines))
        let viewport = Self.pad * 2 + Self.line * n
        let oneLine = textView.font.map { font in
            ceil((font.ascender - font.descender + font.leading).rounded())
        } ?? Self.line * 0.75
        let insetV = max(Self.pad, (viewport - oneLine * n) / 2)
        heightConstraint.constant = viewport
        textView.textContainerInset = NSSize(width: 4, height: insetV)
        placeholderTop.constant = insetV + 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePlaceholder()
    }
}

extension CommitMessageView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        fitHeight()
    }
}

/// Reports focus transitions to the owning scroll view.
final class CommitTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

/// tty7 action_strip, shared by every row with hover verbs: an opaque
/// strip covering the tail of the row — hovering must not move a pixel
/// of it, and buttons stay legible over text (same fill the row paints
/// on hover; a darker strip read as a black block over the wash).
/// Buttons append right-to-left; the width grows with them.
final class ActionStripView: NSView {
    private(set) var buttons: [IconButton] = []
    var hasActions: Bool { !buttons.isEmpty }
    private var widthConstraint: NSLayoutConstraint!

    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Chrome.theme.hoverFill.cgColor
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func add(symbol: String, tip: String, onClick: @escaping () -> Void) {
        let b = IconButton.make(symbol, pointSize: 11, onClick: onClick)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        if let last = buttons.last {
            b.trailingAnchor.constraint(equalTo: last.leadingAnchor).isActive = true
        } else {
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1).isActive = true
        }
        b.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        buttons.append(b)
        widthConstraint.constant = 22 * CGFloat(buttons.count) + 1
    }
}

final class ScmGroupHeaderView: NSView, KeyedRow {
    var onToggle: (() -> Void)?
    var rowKey: String = "hdr"

    /// Section band, TALLER than a row with the title pinned low: the
    /// air above the title is what separates groups — rows inside a
    /// group sit flush, so a 26pt centered title read as just another
    /// row (the low-distinction report).
    static let height: CGFloat = 36
    var rowHeight: CGFloat { Self.height }

    private let chevron = IconLabel("chevron.down", pointSize: 9, weight: .semibold,
                                    tint: Chrome.theme.secondaryText)
    private var actionButtons: [IconButton] = []
    private var isOpen = true
    private var isHovered = false {
        didSet {
            needsDisplay = true
            for b in actionButtons { b.isHidden = !isHovered }
        }
    }

    init(title: String, count: Int, truncated: Bool) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = Chrome.theme.secondaryText
        let countField = NSTextField(labelWithString: truncated ? "\(count)+" : "\(count)")
        countField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countField.textColor = Chrome.theme.secondaryText
        super.init(frame: .zero)

        addSubview(chevron)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        countField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            // tty7: title and count at the row's text inset, pinned to
            // the BOTTOM of the band (air above = the group break)…
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            countField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
            countField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            // …the chevron in the badge column at the right edge, so it
            // and the status letters stack into one column down the panel.
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            chevron.widthAnchor.constraint(equalToConstant: 14),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
        addGestureRecognizer(ActionClickRecognizer { [weak self] in self?.toggle() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    /// Buttons are laid out left-to-right from a fixed trailing anchor,
    /// clear of the chevron column at the right edge. Overlapping the
    /// count is fine — they only exist on hover, and the count is what
    /// they are about to change.
    func addAction(symbol: String, tip: String, onClick: @escaping () -> Void) {
        let b = IconButton.make(symbol, pointSize: 11, onClick: onClick)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        if let first = actionButtons.first {
            b.trailingAnchor.constraint(equalTo: first.leadingAnchor, constant: -2).isActive = true
        } else {
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26).isActive = true
        }
        b.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5).isActive = true
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.isHidden = !isHovered
        actionButtons.append(b)
    }

    private func toggle() {
        isOpen.toggle()
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        // symbolConfiguration/tint stay from init — only the glyph swaps.
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            // A band, not a block: the tall row is mostly air — fill
            // only the title strip at the bottom.
            Chrome.theme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 6),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: - One changed file (status letter + path + hover verbs)

final class ScmEntryRow: NSView, KeyedRow {
    var rowKey: String = "row"
    /// tty7 action_strip: constraint-driven, not frame-driven — a
    /// frame-driven subview inside an autolayout row synthesizes its
    /// own zero-size constraints and crushes whatever is tied to it
    /// (the empty-rows bug).
    private let actionStrip = ActionStripView(height: 22)
    private var isHovered = false {
        didSet {
            needsDisplay = true
            actionStrip.isHidden = !isHovered || !actionStrip.hasActions
        }
    }

    init(path: String, origPath: String?, letter: String, letterColor: NSColor) {
        super.init(frame: .zero)

        let badge = NSTextField(labelWithString: letter)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = letterColor
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        let text = origPath.map { "\(path)  ←  \($0)" } ?? path
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Chrome.theme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        // Stretch to the strip, truncate when the path is long — never
        // push the layout apart.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        actionStrip.isHidden = true
        addSubview(actionStrip)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // tty7 BADGE_W: fixed 14pt cell so letters stack into one
            // column down the right edge.
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
            // Strip sits left of the badge column.
            actionStrip.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -2),
            actionStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStrip.heightAnchor.constraint(equalToConstant: 22),
            // The label must clear the strip even while the strip is
            // hidden — hover may reveal buttons, never shift text.
            label.trailingAnchor.constraint(lessThanOrEqualTo: actionStrip.leadingAnchor,
                                            constant: -4),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func addAction(symbol: String, tip: String, onClick: @escaping () -> Void) {
        actionStrip.add(symbol: symbol, tip: tip, onClick: onClick)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Chrome.theme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: - One worktree (branch + path + hover verbs)

/// Same hover-strip contract as `ScmEntryRow` — verbs appear over an
/// opaque strip covering the tail of the row, zero layout shift. Two
/// text lines (branch, muted path) instead of the status letter.
final class WorktreeRowView: NSView, KeyedRow {
    var rowKey: String = "wt"
    /// Two text lines (branch + path) — taller than the container's
    /// 26pt default; reported via `rowHeight` so the list lays the row
    /// out at full height instead of crushing it.
    static let height: CGFloat = 42
    var rowHeight: CGFloat { Self.height }
    private let actionStrip = ActionStripView(height: 26)
    private var isHovered = false {
        didSet {
            needsDisplay = true
            actionStrip.isHidden = !isHovered || !actionStrip.hasActions
        }
    }

    init(record: WorktreeRecord, isCurrent: Bool) {
        super.init(frame: .zero)

        let glyph = IconLabel("arrow.triangle.branch", pointSize: 10,
                              tint: isCurrent ? Chrome.theme.gitAdded
                                              : Chrome.theme.secondaryText)
        addSubview(glyph)

        let title = record.branch
            ?? (record.path as NSString).lastPathComponent
        let label = NSTextField(labelWithString: isCurrent ? "\(title)  ·  this" : title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Chrome.theme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        let path = NSTextField(labelWithString: record.path)
        path.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        path.textColor = Chrome.theme.secondaryText
        path.lineBreakMode = .byTruncatingMiddle
        path.cell?.truncatesLastVisibleLine = true
        path.cell?.wraps = false
        path.maximumNumberOfLines = 1
        path.translatesAutoresizingMaskIntoConstraints = false
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(path)

        actionStrip.isHidden = true
        addSubview(actionStrip)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            path.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            path.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            actionStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionStrip.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStrip.heightAnchor.constraint(equalToConstant: 26),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actionStrip.leadingAnchor,
                                            constant: -4),
            path.trailingAnchor.constraint(lessThanOrEqualTo: actionStrip.leadingAnchor,
                                           constant: -4),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    func addAction(symbol: String, tip: String, onClick: @escaping () -> Void) {
        actionStrip.add(symbol: symbol, tip: tip, onClick: onClick)
    }

    /// Verb buttons in addAction order — the headless harness fires
    /// them without touching the private list.
    var buttonsForTest: [IconButton] { actionStrip.buttons }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Chrome.theme.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1),
                         xRadius: 6, yRadius: 6).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

