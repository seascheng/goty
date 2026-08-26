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
        drawsBackground = false
        borderType = .noBorder
        contentView.backgroundColor = Chrome.theme.hoverFill
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
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.delegate = self
        textView.onFocusChange = { [weak self] _ in self?.updatePlaceholder() }
        documentView = textView

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = Chrome.theme.secondaryText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        // Anchored to the scroll view itself, never the clip view — the
        // clip view scrolls under the document view.
        placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9).isActive = true
        placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 8).isActive = true

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.pad * 2 + Self.line)
        heightConstraint.isActive = true
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

    private func fitHeight() {
        let lines = max(1, textView.string.split(separator: "\n", omittingEmptySubsequences: false).count)
        heightConstraint.constant = Self.pad * 2 + Self.line * CGFloat(min(lines, Self.maxLines))
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

final class ScmGroupHeaderView: NSView, KeyedRow {
    var onToggle: (() -> Void)?
    var rowKey: String = "hdr"

    private let chevron = NSImageView()
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

        chevron.image = NSImage(systemSymbolName: "chevron.down",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = Chrome.theme.secondaryText
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        countField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            // tty7: title and count at the row's text inset…
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            // …the chevron in the badge column at the right edge, so it
            // and the status letters stack into one column down the panel.
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        b.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.isHidden = !isHovered
        actionButtons.append(b)
    }

    private func toggle() {
        isOpen.toggle()
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        onToggle?()
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

// MARK: - One changed file (status letter + path + hover verbs)

final class ScmEntryRow: NSView, KeyedRow {
    var rowKey: String = "row"
    private var actionButtons: [IconButton] = []
    /// tty7 action_strip: an opaque trailing strip covering the tail of
    /// the path — hovering a row must not move a single pixel of it, and
    /// the buttons must stay legible over text. Fully constraint-driven:
    /// a frame-driven subview inside an autolayout row synthesizes its
    /// own zero-size constraints and crushes whatever is tied to it
    /// (the empty-rows bug).
    private let actionStrip = NSView()
    private var stripWidth: NSLayoutConstraint!
    private var isHovered = false {
        didSet {
            needsDisplay = true
            actionStrip.isHidden = !isHovered || actionButtons.isEmpty
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

        actionStrip.wantsLayer = true
        actionStrip.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        actionStrip.isHidden = true
        actionStrip.translatesAutoresizingMaskIntoConstraints = false
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
        stripWidth = actionStrip.widthAnchor.constraint(equalToConstant: 0)
        stripWidth.isActive = true

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    /// Buttons are appended right-to-left inside the strip; the strip's
    /// width grows with them.
    func addAction(symbol: String, tip: String, onClick: @escaping () -> Void) {
        let b = IconButton.make(symbol, pointSize: 11, onClick: onClick)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        actionStrip.addSubview(b)
        if let first = actionButtons.first {
            b.trailingAnchor.constraint(equalTo: first.leadingAnchor).isActive = true
        } else {
            b.trailingAnchor.constraint(equalTo: actionStrip.trailingAnchor, constant: -1).isActive = true
        }
        b.centerYAnchor.constraint(equalTo: actionStrip.centerYAnchor).isActive = true
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        actionButtons.append(b)
        stripWidth.constant = 22 * CGFloat(actionButtons.count) + 1
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
    private var actionButtons: [IconButton] = []
    private let actionStrip = NSView()
    private var stripWidth: NSLayoutConstraint!
    private var isHovered = false {
        didSet {
            needsDisplay = true
            actionStrip.isHidden = !isHovered || actionButtons.isEmpty
        }
    }

    init(record: WorktreeRecord, isCurrent: Bool) {
        super.init(frame: .zero)

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "arrow.triangle.branch",
                              accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        glyph.contentTintColor = isCurrent
        ? Chrome.theme.gitAdded : Chrome.theme.secondaryText
        glyph.translatesAutoresizingMaskIntoConstraints = false
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

        actionStrip.wantsLayer = true
        actionStrip.layer?.backgroundColor = Chrome.theme.topBarBackground.cgColor
        actionStrip.isHidden = true
        actionStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStrip)

        NSLayoutConstraint.activate([
            // Two text lines (branch + path): 32pt clipped the path into
            // the row below — the reported overflow.
            heightAnchor.constraint(equalToConstant: 42),
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
        stripWidth = actionStrip.widthAnchor.constraint(equalToConstant: 0)
        stripWidth.isActive = true

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways,
                                                              .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder: not implemented") }

    /// Buttons are appended right-to-left inside the strip; the strip's
    /// width grows with them (identical to `ScmEntryRow.addAction`).
    func addAction(symbol: String, tip: String, onClick: @escaping () -> Void) {
        let b = IconButton.make(symbol, pointSize: 11, onClick: onClick)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        actionStrip.addSubview(b)
        if let first = actionButtons.first {
            b.trailingAnchor.constraint(equalTo: first.leadingAnchor).isActive = true
        } else {
            b.trailingAnchor.constraint(equalTo: actionStrip.trailingAnchor, constant: -1).isActive = true
        }
        b.centerYAnchor.constraint(equalTo: actionStrip.centerYAnchor).isActive = true
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        actionButtons.append(b)
        stripWidth.constant = 22 * CGFloat(actionButtons.count) + 1
    }

    /// Verb buttons in addAction order, plus the count — the headless
    /// harness fires them without touching the private list.
    var buttonsForTest: [IconButton] { actionButtons }

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

