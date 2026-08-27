// goty — see CLAUDE.md for the working principles.
import AppKit


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

